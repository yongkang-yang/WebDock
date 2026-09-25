import AppKit
import Combine
import SwiftUI
import WebKit

/// The panel content: a rail of site icons on the left, a header and the active web page on the right.
///
/// The panel opens on the start page (home) after launch; later opens return to the last page.
///
/// Web view lifecycle: a site only gets a web view once it's opened. The page on screen is never
/// released; any page that goes off screen (switched away, or the panel closed) is released after
/// `releaseDelay`, and reopening it resumes the last URL.
final class PanelViewController: NSViewController {
    private let lastURLsKey = "lastURLs"
    private let releaseDelay: TimeInterval = 3 * 60
    // Safari UA so Google sign-in doesn't reject the embedded browser.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    /// Sites known to have a desktop layout that can't shrink, whose mobile web version is good.
    private let knownMobileHosts: Set<String> = ["mail.google.com"]
    private let resolvedLayoutsKey = "resolvedLayouts"
    /// What .auto settled on per site ("desktop" / "mobile"), so detection runs once.
    private var resolvedLayouts: [String: String] = [:]
    private var loadedMobile: [UUID: Bool] = [:]
    /// Sites just switched to mobile by .auto, whose first mobile page still needs checking.
    private var autoMobileProbes: Set<UUID> = []
    /// Sites known to stay light whatever the system appearance.
    private let knownForceDarkHosts: Set<String> = ["mail.google.com"]
    private let resolvedDarkModesKey = "resolvedDarkModes"
    /// What .auto dark mode settled on per site ("force" / "native").
    private var resolvedDarkModes: [String: String] = [:]
    private var loadedForceDark: [UUID: Bool] = [:]

    var onOpenSettings: (() -> Void)?

    private let model = PanelModel()
    private let webCard = NSView()
    private var startPage: NSHostingView<StartPageView>!
    private let homeID = PanelModel.homeID
    private let recentsKey = "recentPages"
    private let railPinnedKey = "railPinned"
    private var rail: NSHostingView<RailView>!
    private let railHotZone = HoverZoneView()
    private var pinnedRailConstraints: [NSLayoutConstraint] = []
    private var floatingRailConstraints: [NSLayoutConstraint] = []
    private var isRailHovered = false
    private var isHotZoneHovered = false
    private var hideRailWork: DispatchWorkItem?
    private var sites: [Site] = []
    private var webViews: [UUID: WKWebView] = [:]
    private var webViewObservations: [UUID: [NSKeyValueObservation]] = [:]
    private var loadedURLs: [UUID: URL] = [:]
    /// When each live web view last went off screen.
    private var hiddenSince: [UUID: Date] = [:]
    private var lastURLs: [String: String] = [:]
    private var popupWindows: [NSWindow] = []
    private var selectedID: UUID?
    private var isPanelVisible = false
    private var storeSubscription: AnyCancellable?
    private var releaseTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var appearanceObservation: NSKeyValueObservation?

    override func loadView() {
        let (root, content) = makeGlassBackground()
        root.frame = NSRect(origin: .zero, size: Metrics.panelSize)
        view = root

        rail = NSHostingView(rootView: RailView(model: model))
        let header = NSHostingView(rootView: HeaderView(model: model))
        header.sizingOptions = []

        webCard.wantsLayer = true
        webCard.layer?.cornerRadius = Metrics.cardRadius
        webCard.layer?.cornerCurve = .continuous
        webCard.layer?.masksToBounds = true
        // The chrome follows the page's appearance, but the page itself follows the system,
        // so pin the card to the system appearance rather than inheriting the chrome's.
        webCard.appearance = NSApp.effectiveAppearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            self?.webCard.appearance = app.effectiveAppearance
            self?.syncNavigationState()  // force-darkened pages flip without a color change to observe
        }

        startPage = NSHostingView(rootView: StartPageView(model: model))
        startPage.frame = webCard.bounds
        startPage.autoresizingMask = [.width, .height]
        webCard.addSubview(startPage)

        railHotZone.onHoverChange = { [weak self] inside in self?.railHoverChanged(inside, fromHotZone: true) }

        // Order matters: the floating rail sits over the page, the hot zone over everything.
        for subview in [header, webCard, rail, railHotZone] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }

        let padding = Metrics.panelPadding
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            webCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            webCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            webCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),

            // The panel's left margin plus a sliver of the page; it never takes clicks.
            railHotZone.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            railHotZone.widthAnchor.constraint(equalToConstant: padding + 6),
            railHotZone.topAnchor.constraint(equalTo: webCard.topAnchor),
            railHotZone.bottomAnchor.constraint(equalTo: webCard.bottomAnchor),
        ])

        pinnedRailConstraints = [
            rail.topAnchor.constraint(equalTo: webCard.topAnchor),
            rail.bottomAnchor.constraint(equalTo: webCard.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding - 6),
            rail.widthAnchor.constraint(equalToConstant: Metrics.railWidth),
            webCard.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Metrics.gap - 4),
        ]
        floatingRailConstraints = [
            rail.topAnchor.constraint(equalTo: webCard.topAnchor, constant: 8),
            rail.bottomAnchor.constraint(lessThanOrEqualTo: webCard.bottomAnchor, constant: -8),
            rail.leadingAnchor.constraint(equalTo: webCard.leadingAnchor, constant: 6),
            webCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
        ]
        model.isRailPinned = UserDefaults.standard.bool(forKey: railPinnedKey)
        applyRailMode()

        model.onSelect = { [weak self] id in
            self?.select(id: id)
            if self?.model.isRailPinned == false {
                self?.hideRailWork?.cancel()
                self?.isRailHovered = false
                self?.setFloatingRailShown(false, animated: true)
            }
        }
        model.onCloseSite = { [weak self] id in self?.closeSite(id: id) }
        model.onOpenInBrowser = { [weak self] id in self?.openInBrowser(id: id) }
        model.onBack = { [weak self] in self?.goBack() }
        model.onSearch = { [weak self] text in self?.search(text) }
        model.onReload = { [weak self] in self?.reload(nil) }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        model.onToggleRailPin = { [weak self] in self?.toggleRailPin() }
        model.onSetLayout = { id, layout in
            guard let index = SiteStore.shared.sites.firstIndex(where: { $0.id == id }) else { return }
            SiteStore.shared.sites[index].layout = layout
        }
        resolvedLayouts = UserDefaults.standard.dictionary(forKey: resolvedLayoutsKey) as? [String: String] ?? [:]
        resolvedDarkModes = UserDefaults.standard.dictionary(forKey: resolvedDarkModesKey) as? [String: String] ?? [:]
        model.onSetDarkMode = { id, mode in
            guard let index = SiteStore.shared.sites.firstIndex(where: { $0.id == id }) else { return }
            SiteStore.shared.sites[index].darkMode = mode
        }
        model.onRailHover = { [weak self] inside in self?.railHoverChanged(inside, fromHotZone: false) }

        selectedID = homeID
        lastURLs = UserDefaults.standard.dictionary(forKey: lastURLsKey) as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let saved = try? JSONDecoder().decode([RecentPage].self, from: data) {
            model.recents = saved
        }

        // @Published emits the current value on subscribe, then every change (before it's stored).
        storeSubscription = SiteStore.shared.$sites.sink { [weak self] sites in
            self?.apply(sites)
        }

        releaseTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.rememberURLs()
            self?.releaseOffscreenWebViews(olderThan: self?.releaseDelay ?? 0)
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.releaseOffscreenWebViews(olderThan: 0)
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Panel visibility

    func panelDidShow() {
        isPanelVisible = true
        if let id = selectedID {
            hiddenSince[id] = nil
        }
        select(id: selectedID)  // recreates the current page if it was released
    }

    func panelDidHide() {
        isPanelVisible = false
        if !model.isRailPinned {
            setFloatingRailShown(false, animated: false)
        }
        if let id = selectedID, webViews[id] != nil {
            hiddenSince[id] = Date()
        }
        rememberURLs()
    }

    // MARK: - Rail

    private func toggleRailPin() {
        model.isRailPinned.toggle()
        UserDefaults.standard.set(model.isRailPinned, forKey: railPinnedKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            applyRailMode()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyRailMode() {
        hideRailWork?.cancel()
        isRailHovered = false
        isHotZoneHovered = false
        if model.isRailPinned {
            NSLayoutConstraint.deactivate(floatingRailConstraints)
            NSLayoutConstraint.activate(pinnedRailConstraints)
            rail.sizingOptions = []
            railHotZone.isEnabled = false
            rail.isHidden = false
            rail.alphaValue = 1
        } else {
            NSLayoutConstraint.deactivate(pinnedRailConstraints)
            NSLayoutConstraint.activate(floatingRailConstraints)
            rail.sizingOptions = [.intrinsicContentSize]
            railHotZone.isEnabled = true
            setFloatingRailShown(false, animated: false)
        }
    }

    /// Hovering the left edge or the rail itself keeps the floating rail out; leaving both hides it.
    private func railHoverChanged(_ inside: Bool, fromHotZone: Bool) {
        guard !model.isRailPinned else { return }
        if fromHotZone {
            isHotZoneHovered = inside
        } else {
            isRailHovered = inside
        }
        hideRailWork?.cancel()
        if isRailHovered || isHotZoneHovered {
            setFloatingRailShown(true, animated: true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isRailHovered, !self.isHotZoneHovered else { return }
                self.setFloatingRailShown(false, animated: true)
            }
            hideRailWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func setFloatingRailShown(_ shown: Bool, animated: Bool) {
        if shown {
            rail.isHidden = false
        }
        guard animated else {
            rail.alphaValue = shown ? 1 : 0
            rail.isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            rail.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !shown, self.rail.alphaValue == 0 else { return }
            self.rail.isHidden = true
        })
    }

    // MARK: - Sites

    private func apply(_ newSites: [Site]) {
        // A changed URL or layout setting means auto-detection starts over.
        for site in newSites {
            if let old = sites.first(where: { $0.id == site.id }), old.url != site.url || old.layout != site.layout {
                resolvedLayouts[site.id.uuidString] = nil
            }
            if let old = sites.first(where: { $0.id == site.id }), old.url != site.url || old.darkMode != site.darkMode {
                resolvedDarkModes[site.id.uuidString] = nil
            }
        }
        sites = newSites

        // Drop web views whose site was removed, or whose URL or layout changed.
        for id in webViews.keys where id != homeID {
            let site = newSites.first { $0.id == id }
            if site == nil || site?.url != loadedURLs[id] || site.map(isMobile) != loadedMobile[id]
                || site.map(forcesDark) != loadedForceDark[id] {
                releaseWebView(id: id)
                lastURLs[id.uuidString] = nil
            }
        }
        let validKeys = Set(newSites.map(\.id.uuidString) + [homeID.uuidString])
        lastURLs = lastURLs.filter { validKeys.contains($0.key) }
        resolvedLayouts = resolvedLayouts.filter { validKeys.contains($0.key) }
        resolvedDarkModes = resolvedDarkModes.filter { validKeys.contains($0.key) }
        UserDefaults.standard.set(resolvedDarkModes, forKey: resolvedDarkModesKey)
        UserDefaults.standard.set(lastURLs, forKey: lastURLsKey)
        UserDefaults.standard.set(resolvedLayouts, forKey: resolvedLayoutsKey)

        model.sites = newSites
        let recents = model.recents.filter { recent in newSites.contains { $0.id == recent.siteID } }
        if recents != model.recents {
            model.recents = recents
            saveRecents()
        }

        let keep = selectedID == homeID || newSites.contains { $0.id == selectedID }
        select(id: keep ? selectedID : homeID)
    }

    private func select(id: UUID?) {
        if let previous = selectedID, previous != id, webViews[previous] != nil {
            hiddenSince[previous] = Date()
        }
        selectedID = id
        model.selectedID = id

        guard let id, let site = site(for: id), id != homeID || webViews[homeID] != nil else {
            webViews.values.forEach { $0.isHidden = true }
            syncNavigationState()
            if isPanelVisible {
                focusCurrentWebView()  // the start page's search field
            }
            return
        }

        // Don't spin up a web view while the panel is closed; panelDidShow will.
        guard isPanelVisible else { return }

        hiddenSince[id] = nil
        let webView = webViews[id] ?? makeWebView(for: site)
        for (otherID, other) in webViews {
            other.isHidden = otherID != id
        }
        webView.isHidden = false
        syncNavigationState()
        focusCurrentWebView()
    }

    private func site(for id: UUID) -> Site? {
        id == homeID ? PanelModel.homeSite : sites.first { $0.id == id }
    }

    private func makeWebView(for site: Site, url: URL? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent cookies => stay logged in
        let forceDark = forcesDark(site)
        if forceDark {
            config.userContentController.addUserScript(Self.forceDarkScript)
        }

        let mobile = isMobile(site)
        if mobile {
            config.userContentController.addUserScript(Self.wheelScrollScript)
        }

        let webView = WKWebView(frame: webCard.bounds, configuration: config)
        webView.customUserAgent = mobile ? mobileUserAgent : userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.autoresizingMask = [.width, .height]
        webCard.addSubview(webView)
        webView.load(URLRequest(url: url ?? resumeURL(for: site)))

        let id = site.id
        webViewObservations[id] = [
            webView.observe(\.isLoading) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.themeColor) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in self?.syncNavigationState() },
            // Chat apps retitle the page as a conversation gets named, without navigating.
            webView.observe(\.title) { [weak self] webView, _ in self?.recordRecent(id: id, webView: webView) },
        ]
        webViews[id] = webView
        loadedURLs[id] = site.url
        loadedMobile[id] = mobile
        loadedForceDark[id] = forceDark
        model.liveIDs = Set(webViews.keys)
        return webView
    }

    private func syncNavigationState() {
        let webView = currentWebView
        var pageColor: NSColor? = webView.flatMap { $0.themeColor ?? $0.underPageBackgroundColor }
        // The page is inverted by CSS; WebKit still reports its original, light color.
        if let id = selectedID, loadedForceDark[id] == true, isSystemDark {
            pageColor = pageColor.flatMap(Self.inverted)
        }
        applyChromeColor(pageColor)
        let isLoading = webView?.isLoading ?? false
        // On home, "back" past the first search result returns to the start page.
        let canGoBack = (webView?.canGoBack ?? false) || (selectedID == homeID && webView != nil)
        startPage.isHidden = !(selectedID == homeID && webView == nil)
        if model.isLoading != isLoading { model.isLoading = isLoading }
        if model.canGoBack != canGoBack { model.canGoBack = canGoBack }
    }

    /// Tints the glass with the page's own color and matches the chrome's light/dark to it,
    /// so the frame reads as an extension of the page instead of a separate pane.
    private func applyChromeColor(_ pageColor: NSColor?) {
        let color = pageColor?.usingColorSpace(.sRGB)
        if model.pageColor != color { model.pageColor = color }
        let tint = color?.withAlphaComponent(0.78)
        if #available(macOS 26, *), let glass = view.subviews.first as? NSGlassEffectView {
            glass.tintColor = tint
        } else {
            view.layer?.backgroundColor = tint?.cgColor
        }
        webCard.layer?.backgroundColor = color?.cgColor

        if let color {
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            view.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
        } else {
            view.appearance = nil
        }
    }

    // MARK: - Layout

    private func isMobile(_ site: Site) -> Bool {
        switch site.layout {
        case .desktop: return false
        case .mobile: return true
        case .auto:
            if let resolved = resolvedLayouts[site.id.uuidString] {
                return resolved == Site.Layout.mobile.rawValue
            }
            return site.url.host.map(knownMobileHosts.contains) ?? false
        }
    }

    /// For .auto sites: a desktop page wider than the panel switches the site to mobile; a
    /// mobile site that answers with an app-download page instead switches it back.
    private func checkAutoLayout(of webView: WKWebView, site: Site) {
        guard site.layout == .auto else { return }
        let key = site.id.uuidString

        if autoMobileProbes.remove(site.id) != nil {
            let path = webView.url?.path.lowercased() ?? ""
            let requested = site.url.path.lowercased()
            let bounced = ["guide", "download", "/app"].contains { path.contains($0) && !requested.contains($0) }
            if bounced {
                resolve(site, as: .desktop, reload: true)
            }
            return
        }
        guard resolvedLayouts[key] == nil, loadedMobile[site.id] == false else { return }

        // Give client-rendered pages a moment to lay out before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView, self.webViews[site.id] === webView else { return }
            let script = "Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0) - window.innerWidth"
            webView.evaluateJavaScript(script) { result, _ in
                guard self.resolvedLayouts[key] == nil, let overflow = (result as? NSNumber)?.doubleValue else { return }
                if overflow > 8 {
                    self.autoMobileProbes.insert(site.id)
                    self.resolve(site, as: .mobile, reload: true)
                } else {
                    self.resolve(site, as: .desktop, reload: false)
                }
            }
        }
    }

    /// Phone layouts often scroll an overflow: hidden box with their own touch handlers
    /// (mobile Gmail's conversation view does), which a trackpad or mouse wheel never reaches.
    /// This scrolls such boxes from wheel events, but only when nothing under the pointer
    /// scrolls natively, so a clipped card on an ordinary page doesn't move along with it.
    private static let wheelScrollScript = WKUserScript(source: """
        (() => {
          const canMove = (el, dx, dy) => dy
            ? (dy > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 1 : el.scrollTop > 0)
            : (dx > 0 ? el.scrollLeft + el.clientWidth < el.scrollWidth - 1 : el.scrollLeft > 0);
          addEventListener('wheel', e => {
            if (e.defaultPrevented || e.ctrlKey) return;
            const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? innerHeight : 1;
            let dx = e.deltaX * unit, dy = e.deltaY * unit;
            if (Math.abs(dy) >= Math.abs(dx)) dx = 0; else dy = 0;
            if (!dx && !dy) return;
            const html = document.documentElement, body = document.body;
            const prop = dy ? 'overflowY' : 'overflowX';
            let target = null;
            for (const node of e.composedPath()) {
              if (!(node instanceof Element) || node === html || node === body) continue;
              if (!canMove(node, dx, dy)) continue;
              const overflow = getComputedStyle(node)[prop];
              if (overflow === 'auto' || overflow === 'scroll') return;
              if (overflow === 'hidden') target ??= node;
            }
            // The viewport takes html's overflow, or body's when html's is visible.
            let overflow = getComputedStyle(html)[prop];
            if (overflow === 'visible' && body) overflow = getComputedStyle(body)[prop];
            const root = document.scrollingElement;
            if (root && canMove(root, dx, dy)) {
              if (overflow !== 'hidden') return;
              target ??= root;
            }
            target?.scrollBy(dx, dy);
          }, { passive: true });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private func resolve(_ site: Site, as layout: Site.Layout, reload: Bool) {
        resolvedLayouts[site.id.uuidString] = layout.rawValue
        UserDefaults.standard.set(resolvedLayouts, forKey: resolvedLayoutsKey)
        guard reload else { return }
        releaseWebView(id: site.id)
        lastURLs[site.id.uuidString] = nil  // the other layout's URL may not exist on this one
        if site.id == selectedID {
            select(id: site.id)
        }
    }

    // MARK: - Dark mode

    /// Inverts the page, then re-inverts media so photos look normal. Only while the system is
    /// dark, and it follows the system live, so it needs no reload when the appearance flips.
    private static let forceDarkScript = WKUserScript(source: """
        (() => {
          const css = `html { filter: invert(1) hue-rotate(180deg) !important; background: #fff !important; }
            img, video, picture, canvas, iframe, embed, object, [style*="background-image"] {
              filter: invert(1) hue-rotate(180deg) !important; }`;
          const dark = matchMedia('(prefers-color-scheme: dark)');
          const style = document.createElement('style');
          style.id = 'webdock-force-dark';
          style.textContent = css;
          const apply = () => {
            if (dark.matches) {
              if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
            } else {
              style.remove();
            }
          };
          apply();
          dark.addEventListener('change', apply);
          document.addEventListener('DOMContentLoaded', apply);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)

    private var isSystemDark: Bool {
        webCard.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func forcesDark(_ site: Site) -> Bool {
        switch site.darkMode {
        case .force: return true
        case .off: return false
        case .auto:
            if let resolved = resolvedDarkModes[site.id.uuidString] {
                return resolved == Site.DarkMode.force.rawValue
            }
            return site.url.host.map(knownForceDarkHosts.contains) ?? false
        }
    }

    /// For .auto sites: a page that stays light while the system is dark gets force-darkened,
    /// right away and on every later load.
    private func checkAutoDarkMode(of webView: WKWebView, site: Site) {
        let key = site.id.uuidString
        guard site.darkMode == .auto, resolvedDarkModes[key] == nil,
              loadedForceDark[site.id] == false, isSystemDark else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak webView] in
            guard let self, let webView, self.webViews[site.id] === webView else { return }
            let script = """
                (() => {
                  const parse = el => (getComputedStyle(el).backgroundColor.match(/[\\d.]+/g) || []).map(Number);
                  let c = parse(document.body);
                  if (c.length < 3 || c[3] === 0) c = parse(document.documentElement);
                  if (c.length < 3 || c[3] === 0) return 1;
                  return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255;
                })()
                """
            webView.evaluateJavaScript(script) { result, _ in
                guard self.resolvedDarkModes[key] == nil, self.isSystemDark,
                      let luminance = (result as? NSNumber)?.doubleValue else { return }
                let light = luminance > 0.6
                self.resolvedDarkModes[key] = light ? Site.DarkMode.force.rawValue : "native"
                UserDefaults.standard.set(self.resolvedDarkModes, forKey: self.resolvedDarkModesKey)
                guard light else { return }
                // Darken this page now; the script also covers the web view's later navigations.
                webView.configuration.userContentController.addUserScript(Self.forceDarkScript)
                webView.evaluateJavaScript(Self.forceDarkScript.source)
                self.loadedForceDark[site.id] = true
                self.syncNavigationState()
            }
        }
    }

    private static func inverted(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return NSColor(srgbRed: 1 - rgb.redComponent, green: 1 - rgb.greenComponent,
                       blue: 1 - rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    // MARK: - Releasing

    /// The last page seen for this site, if it's still on the site's own host.
    private func resumeURL(for site: Site) -> URL {
        guard let string = lastURLs[site.id.uuidString],
              let url = URL(string: string),
              url.host == site.url.host else { return site.url }
        return url
    }

    private func rememberURLs() {
        for (id, webView) in webViews {
            if let url = webView.url {
                lastURLs[id.uuidString] = url.absoluteString
            }
        }
        UserDefaults.standard.set(lastURLs, forKey: lastURLsKey)
    }

    private func releaseWebView(id: UUID) {
        if let url = webViews[id]?.url {
            lastURLs[id.uuidString] = url.absoluteString
            UserDefaults.standard.set(lastURLs, forKey: lastURLsKey)
        }
        webViewObservations[id] = nil
        webViews[id]?.removeFromSuperview()
        webViews[id] = nil
        loadedURLs[id] = nil
        loadedMobile[id] = nil
        loadedForceDark[id] = nil
        hiddenSince[id] = nil
        model.liveIDs = Set(webViews.keys)
    }

    /// Releases every web view that's off screen and has been for at least `age` seconds.
    private func releaseOffscreenWebViews(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        for id in webViews.keys {
            let onScreen = isPanelVisible && id == selectedID
            if !onScreen, let since = hiddenSince[id], since <= cutoff {
                releaseWebView(id: id)
            }
        }
    }

    /// Closing the page on screen goes back to home (otherwise the next panel open would
    /// recreate it); closing home's search page goes back to the start page.
    private func closeSite(id: UUID) {
        releaseWebView(id: id)
        if id == selectedID, id != homeID {
            select(id: homeID)
        } else {
            syncNavigationState()
            focusCurrentWebView()
        }
    }

    private var currentWebView: WKWebView? { selectedID.flatMap { webViews[$0] } }

    func focusCurrentWebView() {
        if let webView = currentWebView {
            view.window?.makeFirstResponder(webView)
        } else if selectedID == homeID {
            view.window?.makeFirstResponder(startPage)
            model.searchFocusRequest += 1
        }
    }

    // MARK: - Recents

    private func recordRecent(id: UUID, webView: WKWebView) {
        guard id != homeID, let site = site(for: id),
              let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let url = webView.url, Site.isSameSite(url.host, site.url.host) else { return }
        var recents = model.recents.filter { $0.siteID != id }
        recents.insert(RecentPage(siteID: id, title: title, url: url, date: Date()), at: 0)
        model.recents = Array(recents.prefix(12))
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(model.recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    // MARK: - Home

    /// A query goes to Google; something that looks like an address opens directly.
    private func search(_ text: String) {
        let looksLikeURL = !text.contains(" ") && (text.contains("://") || text.contains("."))
        let url: URL
        if looksLikeURL, let direct = Site.normalizedURL(from: text) {
            url = direct
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            url = components.url!
        }

        if let webView = webViews[homeID] {
            webView.load(URLRequest(url: url))
        } else {
            _ = makeWebView(for: PanelModel.homeSite, url: url)
        }
        select(id: homeID)
    }

    private func goBack() {
        guard let webView = currentWebView else { return }
        if webView.canGoBack {
            webView.goBack()
        } else if selectedID == homeID {
            closeSite(id: homeID)
        }
    }

    /// ⌘T: a fresh start page, like a new tab.
    @objc func newTab(_ sender: Any?) {
        if webViews[homeID] != nil {
            releaseWebView(id: homeID)
        }
        select(id: homeID)
    }

    // MARK: - Actions

    @objc func reload(_ sender: Any?) {
        if let webView = currentWebView {
            webView.reload()
        } else if isPanelVisible {
            select(id: selectedID)
        }
    }

    /// ⌘1–⌘9 from the main menu; the menu item's tag is the site's index.
    @objc func selectSiteByNumber(_ sender: NSMenuItem) {
        guard sites.indices.contains(sender.tag) else { return }
        select(id: sites[sender.tag].id)
    }

    private func openInBrowser(id: UUID?) {
        guard let id = id ?? selectedID, let site = site(for: id) else { return }
        NSWorkspace.shared.open(webViews[id]?.url ?? (id == homeID ? site.url : resumeURL(for: site)))
    }
}

// MARK: - WKNavigationDelegate

extension PanelViewController: WKNavigationDelegate {
    /// Hands the icons the page declares to the favicon store, apple-touch-icon first, then largest.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = webViews.first(where: { $0.value === webView })?.key,
              let site = site(for: id),
              let host = site.url.host,
              Site.isSameSite(webView.url?.host, host) else { return }
        checkAutoLayout(of: webView, site: site)
        checkAutoDarkMode(of: webView, site: site)

        let script = """
        [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')]
          .map(l => {
            const size = Math.max(0, ...(l.sizes ? [...l.sizes].map(s => parseInt(s) || 0) : [0]));
            const touch = l.rel.includes('apple-touch-icon') ? 1 : 0;
            return { href: l.href, score: touch * 1000 + size };
          })
          .sort((a, b) => b.score - a.score)
          .map(i => i.href)
        """
        webView.evaluateJavaScript(script) { result, _ in
            let urls = (result as? [String] ?? []).compactMap(URL.init(string:))
            FaviconStore.shared.offer(urls, host: host)
        }
    }
}

// MARK: - WKUIDelegate

extension PanelViewController: NSWindowDelegate {
    /// Every popup close lands here, whether from its close button or from the page.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let index = popupWindows.firstIndex(where: { $0 === window }) else { return }
        (window.contentView as? WKWebView)?.stopLoading()
        window.contentView = nil
        window.delegate = nil
        popupWindows.remove(at: index)
    }
}

extension PanelViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Plain target=_blank links go to the default browser.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            return nil
        }
        // Script-opened windows (e.g. OAuth sign-in) get a real popup that keeps window.opener.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
        popup.customUserAgent = userAgent
        popup.uiDelegate = self

        let window = NSWindow(contentRect: popup.frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = popup
        window.isReleasedWhenClosed = false
        // The close button is the usual way out, and without this the popup stayed in
        // popupWindows with its page (and web content process) alive until quit.
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)
        return popup
    }

    /// The page called window.close(); closing the window releases it in windowWillClose.
    func webViewDidClose(_ webView: WKWebView) {
        popupWindows.first { $0.contentView === webView }?.close()
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

// MARK: - Hover zone

/// An invisible strip that reports the mouse entering and leaving, without ever taking clicks.
final class HoverZoneView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var isEnabled = true

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { onHoverChange?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        if isEnabled { onHoverChange?(false) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
