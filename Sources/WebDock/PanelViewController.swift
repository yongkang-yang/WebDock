import AppKit
import Combine
import SwiftUI
import WebKit

/// The panel content: a rail of site icons on the left, a header and the active web page on the right.
///
/// The panel opens on the start page (home) after launch; later opens return to the last page.
///
/// Web view lifecycle: a site only gets a web view once it's opened. The page on screen is never
/// released, nor is a pinned one; any other page that goes off screen (switched away, or the panel
/// closed) is released after `releaseDelay`, and reopening it resumes the last URL. Unpinning an
/// off-screen page starts its countdown then.
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
    /// CSS hiding "get the app" banners that sites show to their phone layout.
    private static let hiddenBanners: [String: String] = ["mail.google.com": "#speedbump"]
    private let resolvedDarkModesKey = "resolvedDarkModes"
    /// What .auto dark mode settled on per site ("force" / "native").
    private var resolvedDarkModes: [String: String] = [:]
    private var loadedForceDark: [UUID: Bool] = [:]
    private let pageZoomsKey = "pageZooms"
    /// Zoom per site, when it isn't 100%.
    private var pageZooms: [String: Double] = [:]
    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private let downloads = DownloadManager()
    private var toastWork: DispatchWorkItem?
    /// See `recentUsername(for:)`.
    fileprivate var typedUsernames: [String: (username: String, date: Date)] = [:]
    /// Which site each web view, sign-in popups included, belongs to, for its saved logins.
    fileprivate let webViewSites = NSMapTable<WKWebView, NSUUID>.weakToStrongObjects()
    fileprivate var pendingLogin: (login: LoginKeychain.Login, password: String)?
    /// Web views whose current page has had its layout, dark mode and icons looked at.
    fileprivate var settledPages: Set<ObjectIdentifier> = []
    /// Pages moved out of the panel into windows of their own.
    private var detachedWindows: [(window: NSWindow, observation: NSKeyValueObservation)] = []
    /// The page whose video is fullscreen, its window, and how to put it back where it was.
    private var fullscreen: (webView: WKWebView, window: FullscreenWindow, restore: () -> Void)?
    /// Pages playing picture in picture.
    private var pictureInPicture: Set<ObjectIdentifier> = []

    var onOpenSettings: (() -> Void)?
    var onClosePanel: (() -> Void)?
    /// How many detached windows are open, so the app can show in the Dock while there are any.
    var onDetachedWindowsChanged: ((Int) -> Void)?

    private let model = PanelModel()
    private let webCard = NSView()
    private var startPage: NSHostingView<StartPageView>!
    private let homeID = PanelModel.homeID
    private let recentsKey = "recentPages"
    /// Whether the rail shows; the key is from when it could also float over the page.
    private let railShownKey = "railPinned"
    private var rail: PassThroughHostingView<RailView>!
    private var findBar: PassThroughHostingView<FindBarView>!
    private var shownRailConstraints: [NSLayoutConstraint] = []
    private var hiddenRailConstraints: [NSLayoutConstraint] = []
    private var sites: [Site] = []
    private var webViews: [UUID: WKWebView] = [:]
    /// WebKit interaction states are kept only in memory: they may contain private form data.
    private var interactionStates: [UUID: Data] = [:]
    private var interactionStateOrder: [UUID] = []
    private let maxInteractionStateBytes = 2 * 1024 * 1024
    private let totalInteractionStateBudget = 8 * 1024 * 1024
    private var restoringIDs: Set<UUID> = []
    private var pendingPreload: DispatchWorkItem?
    private var pendingPreloadID: UUID?
    private var preloadedID: UUID?
    private var preloadExpiryWork: DispatchWorkItem?
    private let speculativeLifetime: TimeInterval = 12
    private var overviewMemoryTimer: Timer?
    private var webViewObservations: [UUID: [NSKeyValueObservation]] = [:]
    private var loadedURLs: [UUID: URL] = [:]
    /// When each live web view last went off screen.
    private var hiddenSince: [UUID: Date] = [:]
    private var lastURLs: [String: String] = [:]
    private var popupWindows: [NSWindow] = []
    private var selectedID: UUID?
    /// The Touch ID sheet takes the focus away; that shouldn't close the panel under it.
    var keepsPanelOpen: Bool { PasswordGate.isAuthenticating }
    private var isPanelVisible = false
    private var storeSubscription: AnyCancellable?
    private var folderSubscription: AnyCancellable?
    private var releaseTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var appearanceObservation: NSKeyValueObservation?
    private var pinchMonitor: Any?
    private var overviewHost: OverviewHostingView!
    /// Pages in the order they were last on screen, oldest first, for the overview.
    private var pageOrder: [UUID] = []
    /// The last picture of each open page, taken as it goes off screen, for the overview.
    private var snapshots: [UUID: NSImage] = [:]

    override func loadView() {
        let (root, content) = makeGlassBackground(size: PanelSize.saved)
        root.frame = NSRect(origin: .zero, size: PanelSize.saved)
        view = root

        rail = PassThroughHostingView(rootView: RailView(model: model))
        findBar = PassThroughHostingView(rootView: FindBarView(model: model))
        findBar.sizingOptions = [.intrinsicContentSize]
        let toast = PassThroughHostingView(rootView: ToastView(model: model))
        toast.sizingOptions = [.intrinsicContentSize]
        let loginPrompt = PassThroughHostingView(rootView: LoginPromptView(model: model))
        loginPrompt.sizingOptions = [.intrinsicContentSize]
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

        overviewHost = OverviewHostingView(rootView: OverviewView(model: model))
        overviewHost.sizingOptions = []
        overviewHost.isHidden = true

        // Order matters: the overview goes over everything.
        for subview in [header, webCard, findBar, toast, loginPrompt, rail, overviewHost] as [NSView] {
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

            findBar.topAnchor.constraint(equalTo: webCard.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: webCard.trailingAnchor, constant: -10),

            loginPrompt.centerXAnchor.constraint(equalTo: webCard.centerXAnchor),
            loginPrompt.topAnchor.constraint(equalTo: webCard.topAnchor, constant: 12),
            loginPrompt.widthAnchor.constraint(lessThanOrEqualTo: webCard.widthAnchor, constant: -24),
            toast.centerXAnchor.constraint(equalTo: webCard.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: webCard.bottomAnchor, constant: -14),
            toast.widthAnchor.constraint(lessThanOrEqualTo: webCard.widthAnchor, constant: -24),

            overviewHost.topAnchor.constraint(equalTo: webCard.topAnchor),
            overviewHost.bottomAnchor.constraint(equalTo: webCard.bottomAnchor),
            overviewHost.leadingAnchor.constraint(equalTo: webCard.leadingAnchor),
            overviewHost.trailingAnchor.constraint(equalTo: webCard.trailingAnchor),
        ])

        shownRailConstraints = [
            rail.topAnchor.constraint(equalTo: webCard.topAnchor),
            rail.bottomAnchor.constraint(equalTo: webCard.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding - 6),
            rail.widthAnchor.constraint(equalToConstant: Metrics.railWidth),
            webCard.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Metrics.gap - 4),
        ]
        hiddenRailConstraints = [
            webCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
        ]
        model.isRailShown = UserDefaults.standard.bool(forKey: railShownKey)
        applyRailMode()

        model.onSelect = { [weak self] id in self?.select(id: id) }
        model.onHoverSite = { [weak self] id, inside in self?.schedulePreload(id: id, inside: inside) }
        model.onCloseSite = { [weak self] id in self?.closeSite(id: id) }
        model.onOpenInBrowser = { [weak self] id in self?.openInBrowser(id: id) }
        model.onOpenInWindow = { [weak self] id in self?.openInWindow(id: id) }
        model.onAddSite = { [weak self] site in self?.addSite(site) }
        model.onMoveSite = { id, target in SiteStore.shared.move(id, to: target) }
        model.onMergeSite = { id, target, name in SiteStore.shared.merge(id, into: target, newFolderName: name) }
        model.onRemoveFromFolder = { id in SiteStore.shared.removeFromFolder(id) }
        model.onUngroupFolder = { id in SiteStore.shared.ungroup(id) }
        model.onRenameFolder = { id, name in SiteStore.shared.renameFolder(id, to: name) }
        model.pageForAdding = { [weak self] in self?.pageForAdding() ?? ("", "") }
        model.onShowFind = { [weak self] in self?.showFind(nil) }
        model.onFind = { [weak self] query, backwards, restart in
            self?.find(query, backwards: backwards, restart: restart)
        }
        model.onCloseFind = { [weak self] in self?.closeFind() }
        model.onToggleOverview = { [weak self] in self?.toggleOverview(nil) }
        model.onCloseOverview = { [weak self] id in self?.closeOverview(selecting: id) }
        model.onCloseOverviewPage = { [weak self] id in self?.closeOverviewPage(id) }
        model.onZoom = { [weak self] change in self?.zoom(change) }
        model.onTogglePin = { [weak self] id in self?.togglePin(id: id) }
        model.onBack = { [weak self] in self?.goBack() }
        model.onGoHome = { [weak self] in self?.goHome(nil) }
        model.onSearch = { [weak self] text in self?.search(text) }
        model.onReload = { [weak self] in self?.reload(nil) }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        model.onToggleRail = { [weak self] in self?.toggleRail() }
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
        model.onAnswerLoginPrompt = { [weak self] save in self?.answerLoginPrompt(save: save) }
        PasswordGate.startObserving()
        pageZooms = UserDefaults.standard.dictionary(forKey: pageZoomsKey) as? [String: Double] ?? [:]
        UserDefaults.standard.removeObject(forKey: "siteUsage")
        downloads.onEvent = { [weak self] event in self?.downloadEvent(event) }

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
        folderSubscription = SiteStore.shared.$folders.sink { [weak self] folders in
            self?.model.folders = folders
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

        // A trackpad pinch in shows the overview, as it shows all tabs in Safari. The pinch still
        // reaches the page, since maps and the like zoom with it.
        var pinch: CGFloat = 0
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.view.window, self.model.overview == nil else { return event }
            if event.phase == .began { pinch = 0 }
            pinch += event.magnification
            if pinch < -0.2 {
                pinch = .infinity  // once per pinch
                self.toggleOverview(nil)
            }
            return event
        }
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
        pendingPreload?.cancel()
        pendingPreload = nil
        pendingPreloadID = nil
        if let id = preloadedID {
            releaseWebView(id: id)
        }
        if model.overview != nil {
            closeOverview(selecting: nil)
        }
        if let id = selectedID, webViews[id] != nil {
            hiddenSince[id] = Date()
        }
        rememberURLs()
    }

    // MARK: - Rail

    private func toggleRail() {
        model.isRailShown.toggle()
        UserDefaults.standard.set(model.isRailShown, forKey: railShownKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            applyRailMode()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyRailMode() {
        if model.isRailShown {
            NSLayoutConstraint.deactivate(hiddenRailConstraints)
            NSLayoutConstraint.activate(shownRailConstraints)
        } else {
            NSLayoutConstraint.deactivate(shownRailConstraints)
            NSLayoutConstraint.activate(hiddenRailConstraints)
        }
        rail.isHidden = !model.isRailShown
    }

    // MARK: - Sites

    private func apply(_ newSites: [Site]) {
        // A changed URL or layout setting means auto-detection starts over.
        for site in newSites {
            if let old = sites.first(where: { $0.id == site.id }), old.url != site.url || old.layout != site.layout {
                resolvedLayouts[site.id.uuidString] = nil
                // Never restore an interaction state into a different site or layout.
                discardInteractionState(for: site.id)
            }
            if let old = sites.first(where: { $0.id == site.id }), old.url != site.url || old.darkMode != site.darkMode {
                resolvedDarkModes[site.id.uuidString] = nil
            }
        }
        sites = newSites
        LoginKeychain.removeAll(except: Set(newSites.map(\.id) + [homeID]))

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
        pageOrder.removeAll { !validKeys.contains($0.uuidString) }
        snapshots = snapshots.filter { validKeys.contains($0.key.uuidString) }
        lastURLs = lastURLs.filter { validKeys.contains($0.key) }
        interactionStates = interactionStates.filter { validKeys.contains($0.key.uuidString) }
        interactionStateOrder.removeAll { !validKeys.contains($0.uuidString) }
        resolvedLayouts = resolvedLayouts.filter { validKeys.contains($0.key) }
        resolvedDarkModes = resolvedDarkModes.filter { validKeys.contains($0.key) }
        pageZooms = pageZooms.filter { validKeys.contains($0.key) }
        UserDefaults.standard.set(pageZooms, forKey: pageZoomsKey)
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
            takeSnapshot(of: previous)
        }
        if id != selectedID, model.isFindVisible {
            closeFind(refocus: false)
        }
        selectedID = id
        model.selectedID = id
        if preloadedID == id {
            preloadedID = nil
            preloadExpiryWork?.cancel()
            preloadExpiryWork = nil
            publishLiveIDs()
        }

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
        // Auto-layout detection is postponed until an explicitly selected page.
        checkAutoLayout(of: webView, site: site)
        checkAutoDarkMode(of: webView, site: site)
        recordRecent(id: id, webView: webView)
        pageOrder.removeAll { $0 == id }
        pageOrder.append(id)
        syncNavigationState()
        focusCurrentWebView()
    }

    private func site(for id: UUID) -> Site? {
        id == homeID ? PanelModel.homeSite : sites.first { $0.id == id }
    }

    private func makeWebView(for site: Site, url: URL? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // persistent cookies => stay logged in
        VideoPresentation.enablePictureInPicture(config.preferences)
        config.userContentController.addUserScript(VideoPresentation.script)
        config.userContentController.add(WeakScriptMessageHandler(self), name: VideoPresentation.messageName)
        config.userContentController.addUserScript(Autofill.script)
        config.userContentController.add(WeakScriptMessageHandler(self), contentWorld: Autofill.world,
                                         name: Autofill.messageName)
        let forceDark = forcesDark(site)
        if forceDark {
            config.userContentController.addUserScript(Self.forceDarkScript)
        }

        let mobile = isMobile(site)
        if mobile {
            config.userContentController.addUserScript(Self.wheelScrollScript)
        }
        if let selector = site.url.host.flatMap({ Self.hiddenBanners[$0] }) {
            config.userContentController.addUserScript(Self.hideScript(selector))
        }

        let webView = WKWebView(frame: webCard.bounds, configuration: config)
        webView.customUserAgent = mobile ? mobileUserAgent : userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = pageZooms[site.id.uuidString] ?? 1
        webView.autoresizingMask = [.width, .height]
        webCard.addSubview(webView)
        // Keep the recovery data until WebKit commits a restored navigation. A state
        // that never starts navigation must not strand the page on an empty view.
        if url == nil, let state = interactionStates[site.id] {
            restoringIDs.insert(site.id)
            webView.interactionState = state
            let id = site.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak webView] in
                guard let self, let webView, self.webViews[id] === webView,
                      self.restoringIDs.contains(id) else { return }
                self.fallbackFromFailedRestore(id: id, webView: webView)
            }
        } else {
            webView.load(URLRequest(url: url ?? resumeURL(for: site)))
        }

        let id = site.id
        webViewObservations[id] = [
            webView.observe(\.isLoading) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.themeColor) { [weak self] _, _ in self?.syncNavigationState() },
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in self?.syncNavigationState() },
            // Chat apps retitle the page as a conversation gets named, without navigating.
            webView.observe(\.title) { [weak self] webView, _ in
                self?.recordRecent(id: id, webView: webView)
                self?.updateBadge(id: id, title: webView.title)
            },
        ]
        webViews[id] = webView
        webViewSites.setObject(id as NSUUID, forKey: webView)
        loadedURLs[id] = site.url
        loadedMobile[id] = mobile
        loadedForceDark[id] = forceDark
        publishLiveIDs()
        return webView
    }

    /// Stored interaction data can contain form content. Keep only a small, bounded
    /// in-memory cache and remove the oldest entries when it exceeds its budget.
    private func discardInteractionState(for id: UUID) {
        interactionStates[id] = nil
        interactionStateOrder.removeAll { $0 == id }
    }

    private func saveInteractionState(_ state: Data, for id: UUID) {
        discardInteractionState(for: id)
        guard !state.isEmpty, state.count <= maxInteractionStateBytes else { return }
        interactionStates[id] = state
        interactionStateOrder.append(id)
        var total = interactionStates.values.reduce(0) { $0 + $1.count }
        while total > totalInteractionStateBudget, !interactionStateOrder.isEmpty {
            let oldest = interactionStateOrder[0]
            total -= interactionStates[oldest]?.count ?? 0
            discardInteractionState(for: oldest)
        }
    }

    private func fallbackFromFailedRestore(id: UUID, webView: WKWebView) {
        guard restoringIDs.remove(id) != nil, webViews[id] === webView,
              let site = site(for: id) else { return }
        // Only one normal URL load. Do not retry a broken interaction state.
        discardInteractionState(for: id)
        webView.load(URLRequest(url: resumeURL(for: site)))
    }

    /// Start loading a hovered site after a short delay. At most one speculative page is kept.
    /// A mouse pass over the rail must not start several network requests.
    private func schedulePreload(id: UUID, inside: Bool) {
        if pendingPreloadID == id || inside {
            pendingPreload?.cancel()
            pendingPreload = nil
            pendingPreloadID = nil
        }
        if preloadedID == id {
            preloadExpiryWork?.cancel()
            preloadExpiryWork = nil
            if !inside { expirePreload(id: id) }
            return
        }
        guard inside, isPanelVisible, id != selectedID, site(for: id) != nil,
              id != homeID, webViews[id] == nil else { return }
        pendingPreloadID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPanelVisible, self.pendingPreloadID == id,
                  let site = self.site(for: id), self.webViews[id] == nil else { return }
            self.pendingPreload = nil
            self.pendingPreloadID = nil
            if let previous = self.preloadedID, previous != id, self.webViews[previous] != nil {
                self.releaseWebView(id: previous)
            }
            self.preloadedID = id
            let webView = self.makeWebView(for: site)
            webView.isHidden = true
            self.hiddenSince[id] = Date()
            self.expirePreload(id: id)
        }
        pendingPreload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func expirePreload(id: UUID) {
        preloadExpiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.preloadedID == id else { return }
            self.releaseWebView(id: id)
        }
        preloadExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + speculativeLifetime, execute: work)
    }

    private func isSpeculative(_ webView: WKWebView) -> Bool {
        guard let id = preloadedID else { return false }
        return webViews[id] === webView
    }

    /// A speculative page uses memory but is not a page the user deliberately opened.
    private func publishLiveIDs() {
        var ids = Set(webViews.keys)
        if let preloadedID { ids.remove(preloadedID) }
        model.liveIDs = ids
    }

    private func togglePin(id: UUID?) {
        guard let id = id ?? selectedID, webViews[id] != nil else { return }
        if model.pinnedIDs.remove(id) == nil {
            model.pinnedIDs.insert(id)
        } else if !(isPanelVisible && id == selectedID) {
            hiddenSince[id] = Date()  // the full countdown starts now, not when it went off screen
        }
    }

    private func syncNavigationState() {
        let webView = currentWebView
        var pageColor: NSColor? = webView.flatMap(Self.pageColor(of:))
        // The page is inverted by CSS; WebKit still reports its original, light color.
        if let id = selectedID, loadedForceDark[id] == true, isSystemDark {
            pageColor = pageColor.flatMap(Self.inverted)
        }
        applyChromeColor(pageColor)
        let isLoading = webView?.isLoading ?? false
        // On home, "back" past the first search result returns to the start page.
        let canGoBack = (webView?.canGoBack ?? false) || (selectedID == homeID && webView != nil)
        startPage.isHidden = !(selectedID == homeID && webView == nil)
        let zoom = webView?.pageZoom ?? 1
        if model.zoom != zoom { model.zoom = zoom }
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
            view.appearance = NSAppearance(named: Self.isDark(color) ? .darkAqua : .aqua)
        } else {
            view.appearance = nil
        }
    }

    /// The page's theme color, unless it's light over a dark page: a theme-color declared once,
    /// without a dark-mode variant, stays white when the page turns dark (Rednote does this).
    /// A dark theme color over a light page is left alone; that's usually a deliberate dark header.
    private static func pageColor(of webView: WKWebView) -> NSColor? {
        let background = webView.underPageBackgroundColor
        guard let theme = webView.themeColor else { return background }
        if let background, !isDark(theme), isDark(background) { return background }
        return theme
    }

    private static func isDark(_ color: NSColor) -> Bool {
        guard let color = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.5
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

    private static func hideScript(_ selector: String) -> WKUserScript {
        WKUserScript(source: """
            (() => {
              const style = document.createElement('style');
              style.textContent = '\(selector) { display: none !important; }';
              (document.head || document.documentElement).appendChild(style);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

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

    private func releaseWebView(id: UUID, preserveInteraction: Bool = false) {
        if preserveInteraction, let webView = webViews[id],
           let state = webView.interactionState as? Data {
            saveInteractionState(state, for: id)
        } else {
            discardInteractionState(for: id)
        }
        restoringIDs.remove(id)
        if preloadedID == id {
            preloadedID = nil
            preloadExpiryWork?.cancel()
            preloadExpiryWork = nil
        }
        if id == homeID {  // home's search page is gone for good; a site reopens where it was
            pageOrder.removeAll { $0 == homeID }
            snapshots[homeID] = nil
        }
        if let webView = webViews[id] {
            webView.removeFromSuperview()
            Self.closePage(of: webView)
            settledPages.remove(ObjectIdentifier(webView))
        }
        forgetWebView(id: id)
    }

    /// AppKit's tooltip manager and Writing Tools' affordance hold on to the last web view that
    /// used them, which kept its page, and the site's web content process, alive after the
    /// panel let go. Closing the page ends the process whoever still has the view.
    static func closePage(of webView: WKWebView) {
        webView.stopLoading()
        webView.removeAllToolTips()
        let close = NSSelectorFromString("_close")
        if webView.responds(to: close) {
            webView.perform(close)
        }
    }

    /// Drops the panel's hold on a site's web view, remembering where it was.
    private func forgetWebView(id: UUID) {
        if let url = webViews[id]?.url {
            lastURLs[id.uuidString] = url.absoluteString
            UserDefaults.standard.set(lastURLs, forKey: lastURLsKey)
        }
        if let webView = webViews[id] {
            pictureInPicture.remove(ObjectIdentifier(webView))
        }
        webViewObservations[id] = nil
        webViews[id] = nil
        restoringIDs.remove(id)
        if preloadedID == id {
            preloadedID = nil
            preloadExpiryWork?.cancel()
            preloadExpiryWork = nil
        }
        snapshots[id] = nil
        model.badges[id] = nil
        loadedURLs[id] = nil
        loadedMobile[id] = nil
        loadedForceDark[id] = nil
        hiddenSince[id] = nil
        model.pinnedIDs.remove(id)
        publishLiveIDs()
    }

    /// Releases every web view that's off screen and has been for at least `age` seconds.
    private func releaseOffscreenWebViews(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        for id in webViews.keys {
            let onScreen = isPanelVisible && id == selectedID
            if !onScreen, !model.pinnedIDs.contains(id), !isPlayingElsewhere(id: id),
               let since = hiddenSince[id], since <= cutoff {
                releaseWebView(id: id, preserveInteraction: true)
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

    // MARK: - Overview

    /// ⇧⌘\: every recent page as a card, like the iPhone's app switcher.
    @objc func toggleOverview(_ sender: Any?) {
        guard isPanelVisible else { return }
        if model.overview != nil {
            closeOverview(selecting: selectedID.flatMap { webViews[$0] != nil ? $0 : nil })
            return
        }
        if model.isFindVisible {
            closeFind(refocus: false)
        }
        // The page on screen shrinks into its card, so it needs a fresh picture first.
        let current = selectedID.flatMap { webViews[$0] != nil ? $0 : nil }
        guard let current else {
            showOverview(currentID: nil)
            return
        }
        takeSnapshot(of: current) { [weak self] in self?.showOverview(currentID: current) }
    }

    private func showOverview(currentID: UUID?) {
        guard isPanelVisible, model.overview == nil else { return }
        // Only pages that are open; a released one has no page left to go back to.
        let processes = webViews.compactMapValues { WebProcessMemory.processID(for: $0) }
        var processUse: [Int32: Int] = [:]
        for pid in processes.values { processUse[pid, default: 0] += 1 }
        let pages = pageOrder.compactMap { id -> OverviewPage? in
            guard webViews[id] != nil, let site = site(for: id) else { return nil }
            let pid = processes[id]
            return OverviewPage(site: site, snapshot: snapshots[id],
                                memoryBytes: pid.flatMap(WebProcessMemory.residentBytes(for:)),
                                sharedProcess: pid.map { processUse[$0, default: 0] > 1 } ?? false)
        }
        model.overview = OverviewSession(pages: pages, currentID: currentID)
        overviewHost.isHidden = false
        view.window?.makeFirstResponder(overviewHost)
        // Pages never pictured yet get one now.
        for page in pages where page.snapshot == nil {
            takeSnapshot(of: page.id) { [weak self] in
                guard let self, let image = self.snapshots[page.id],
                      let index = self.model.overview?.pages.firstIndex(where: { $0.id == page.id }) else { return }
                self.model.overview?.pages[index].snapshot = image
            }
        }
    }

    /// The picked card has grown to fill the page's place; the page itself takes over from it.
    private func closeOverview(selecting id: UUID?) {
        guard model.overview != nil else { return }
        if let id, site(for: id) != nil {
            select(id: id)
        } else {
            focusCurrentWebView()
        }
        // A frame later, so a page brought back from hiding has drawn before the card goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.model.overview = nil
            self.overviewHost.isHidden = true
        }
    }

    private func closeOverviewPage(_ id: UUID) {
        model.overview?.pages.removeAll { $0.id == id }
        pageOrder.removeAll { $0 == id }
        snapshots[id] = nil
        if webViews[id] != nil {
            closeSite(id: id)
        }
        if model.overview?.currentID == id {
            model.overview?.currentID = nil
        }
    }

    private func takeSnapshot(of id: UUID, completion: (() -> Void)? = nil) {
        guard let webView = webViews[id], webView.bounds.width > 0 else {
            completion?()
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 720)))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image, self?.webViews[id] === webView {
                self?.snapshots[id] = image
            }
            completion?()
        }
    }

    // MARK: - Recents

    private func recordRecent(id: UUID, webView: WKWebView) {
        guard isPanelVisible, selectedID == id, id != homeID, let site = site(for: id),
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

    /// ⇧⌘H and the header's house: back to home, as it was left; from home itself, to the start page.
    @objc func goHome(_ sender: Any?) {
        if model.overview != nil {
            closeOverview(selecting: nil)
        }
        if selectedID == homeID {
            newTab(nil)
        } else {
            select(id: homeID)
        }
    }

    /// ⌘W: closes the page on screen, as its close button does, or leaves the overview.
    /// False when there's no page to close (the start page), so the panel closes instead.
    func closeCurrentPage() -> Bool {
        if model.overview != nil {
            closeOverview(selecting: selectedID.flatMap { webViews[$0] != nil ? $0 : nil })
            return true
        }
        guard let id = selectedID, webViews[id] != nil else { return false }
        closeSite(id: id)
        return true
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

    // MARK: - Video

    /// Fullscreen and picture in picture video carry on outside the panel, so the page stays.
    private func isPlayingElsewhere(id: UUID) -> Bool {
        guard let webView = webViews[id] else { return false }
        return fullscreen?.webView === webView || pictureInPicture.contains(ObjectIdentifier(webView))
    }

    /// Moves the page into a window over the screen below the menu bar; the page has already
    /// pinned its fullscreen element over the viewport.
    private func enterFullscreen(_ webView: WKWebView) {
        guard fullscreen == nil, let hostWindow = webView.window else { return }
        let screen = hostWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let restore: () -> Void
        if hostWindow.contentView === webView {  // a page in its own window
            hostWindow.contentView = NSView()
            restore = { [weak hostWindow, weak webView] in hostWindow?.contentView = webView }
        } else if let superview = webView.superview {  // the panel
            let frame = webView.frame
            webView.removeFromSuperview()
            restore = { [weak superview, weak webView] in
                guard let webView else { return }
                webView.frame = frame
                superview?.addSubview(webView)
            }
        } else {
            return
        }

        let window = FullscreenWindow(screen: screen)
        window.contentView = webView
        window.onExit = { [weak self, weak webView] in
            guard let webView else { return }
            webView.evaluateJavaScript("window.__webdockFullscreen && window.__webdockFullscreen()")
            // A page that navigated away no longer knows it was fullscreen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.exitFullscreen(webView) }
        }
        fullscreen = (webView, window, restore)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    private func exitFullscreen(_ webView: WKWebView) {
        guard let current = fullscreen, current.webView === webView else { return }
        fullscreen = nil
        current.window.contentView = NSView()
        current.restore()
        current.window.orderOut(nil)
        if let window = webView.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        }
    }

    // MARK: - Find

    /// ⌘F. Pressing it again with the bar open goes back into its field.
    @objc func showFind(_ sender: Any?) {
        guard currentWebView != nil else { return }
        model.isFindVisible = true
        view.window?.makeFirstResponder(findBar)
        model.findFocusRequest += 1
        if !model.findQuery.isEmpty {
            find(model.findQuery, backwards: false, restart: false)
        }
    }

    @objc func findNext(_ sender: Any?) {
        findAgain(backwards: false)
    }

    @objc func findPrevious(_ sender: Any?) {
        findAgain(backwards: true)
    }

    private func findAgain(backwards: Bool) {
        if model.isFindVisible, !model.findQuery.isEmpty {
            find(model.findQuery, backwards: backwards, restart: false)
        } else {
            showFind(nil)
        }
    }

    /// Finds from the current match; `restart` (the query changed) searches from the top instead.
    private func find(_ query: String, backwards: Bool, restart: Bool) {
        guard let webView = currentWebView, !query.isEmpty else {
            model.findNotFound = false
            return
        }
        let search = { [weak self, weak webView] in
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            webView?.find(query, configuration: configuration) { result in
                self?.model.findNotFound = !result.matchFound
            }
        }
        if restart {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()") { _, _ in search() }
        } else {
            search()
        }
    }

    private func closeFind(refocus: Bool = true) {
        model.isFindVisible = false
        model.findNotFound = false
        if refocus {
            focusCurrentWebView()
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { zoom(.zoomIn) }
    @objc func zoomOut(_ sender: Any?) { zoom(.zoomOut) }
    @objc func actualSize(_ sender: Any?) { zoom(.reset) }

    /// Steps through Safari's zoom levels; the level sticks to the site.
    private func zoom(_ change: PanelModel.ZoomChange) {
        guard let id = selectedID, let webView = currentWebView else { return }
        let current = webView.pageZoom
        let steps = Self.zoomSteps
        let zoom: Double = switch change {
        case .zoomIn: steps.first { $0 > current + 0.001 } ?? steps.last!
        case .zoomOut: steps.last { $0 < current - 0.001 } ?? steps.first!
        case .reset: 1
        }
        webView.pageZoom = zoom
        pageZooms[id.uuidString] = abs(zoom - 1) < 0.001 ? nil : zoom
        UserDefaults.standard.set(pageZooms, forKey: pageZoomsKey)
        syncNavigationState()
        showToast(Toast(symbol: "plus.magnifyingglass", message: "Zoom \(Int((zoom * 100).rounded()))%"), for: 1.2)
    }

    // MARK: - Badges

    /// "(3) Home / X", "[3] …", or "Inbox (3) - … - Gmail".
    private static let badgePattern = try! NSRegularExpression(
        pattern: #"^\s*[(\[](\d{1,5})\+?[)\]]|\b(?:Inbox|收件箱)\s*\((\d{1,5})\+?\)"#,
        options: [.caseInsensitive])

    static func unreadCount(in title: String) -> Int? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = badgePattern.firstMatch(in: title, range: range) else { return nil }
        for group in 1...2 {
            if let groupRange = Range(match.range(at: group), in: title), let count = Int(title[groupRange]) {
                return count > 0 ? count : nil
            }
        }
        return nil
    }

    private func updateBadge(id: UUID, title: String?) {
        guard id != homeID else { return }
        let count = title.flatMap(Self.unreadCount)
        if model.badges[id] != count {
            model.badges[id] = count
        }
    }

    // MARK: - Toasts

    private func showToast(_ toast: Toast, for duration: TimeInterval = 4) {
        toastWork?.cancel()
        model.toast = toast
        let work = DispatchWorkItem { [weak self] in self?.model.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func downloadEvent(_ event: DownloadManager.Event) {
        switch event {
        case .started(let name):
            showToast(Toast(symbol: "arrow.down.circle", message: "Downloading \(name)…"), for: 2.5)
        case .finished(let file):
            showToast(Toast(symbol: "checkmark.circle", message: file.lastPathComponent,
                            actionTitle: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }, for: 6)
        case .failed(let name):
            showToast(Toast(symbol: "exclamationmark.triangle", message: "Couldn’t download \(name)"))
        }
    }

    // MARK: - Adding sites

    private func pageForAdding() -> (url: String, name: String) {
        guard let webView = currentWebView, let url = webView.url else { return ("", "") }
        let title = webView.title.map(SiteTitle.brand(fromTitle:)) ?? ""
        return (url.absoluteString, title.isEmpty ? SiteTitle.fromHost(url) : title)
    }

    private func addSite(_ site: Site) {
        SiteStore.shared.sites.append(site)
        showToast(Toast(symbol: "plus.circle", message: "Added \(site.name)"), for: 2)
    }

    // MARK: - Separate windows

    /// Moves the page, as it is, into a window of its own; the panel starts afresh for the site.
    private func openInWindow(id: UUID?) {
        guard let id = id ?? selectedID, let site = site(for: id) else { return }
        let webView = webViews[id] ?? makeWebView(for: site)
        let wasMobile = loadedMobile[id] == true
        webView.removeFromSuperview()
        discardInteractionState(for: id)
        forgetWebView(id: id)
        webView.isHidden = false
        // A phone layout looks lost in a big window.
        if wasMobile {
            webView.customUserAgent = userAgent
            webView.reload()
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = Self.windowTitle(webView.title, fallback: site.name)
        window.setFrameAutosaveName("WebDockPage")
        if let last = detachedWindows.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        let observation = webView.observe(\.title) { [weak window] webView, _ in
            window?.title = Self.windowTitle(webView.title, fallback: site.name)
        }
        detachedWindows.append((window, observation))
        onDetachedWindowsChanged?(detachedWindows.count)

        if id == selectedID {
            select(id: homeID)
        } else {
            syncNavigationState()
        }
        onClosePanel?()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func windowTitle(_ title: String?, fallback: String) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return fallback }
        return title
    }
}

// MARK: - WKNavigationDelegate

extension PanelViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Autofill.messageName {
            handleAutofill(message)
            return
        }
        guard message.name == VideoPresentation.messageName,
              let body = message.body as? [String: Any], let webView = message.webView else { return }
        if let on = body["fullscreen"] as? Bool, message.frameInfo.isMainFrame {
            on ? enterFullscreen(webView) : exitFullscreen(webView)
        }
        if let on = body["pictureInPicture"] as? Bool {
            if on {
                pictureInPicture.insert(ObjectIdentifier(webView))
            } else {
                pictureInPicture.remove(ObjectIdentifier(webView))
            }
        }
    }
}

// MARK: - Autofill

extension PanelViewController {
    /// A login belongs to the site whose page (or sign-in popup) the form is in, and to the exact
    /// host of the frame; only https frames take part.
    fileprivate func handleAutofill(_ message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https", !origin.host.isEmpty, let webView = message.webView,
              let siteID = webViewSites.object(forKey: webView) as UUID?,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let host = origin.host.lowercased()
        let key = "\(siteID)\n\(host)"
        let username = (body["username"] as? String) ?? ""
        Autofill.log.notice("\(type, privacy: .public) from \(host, privacy: .public)")
        switch type {
        case "fields":
            // A username just typed on a first sign-in step goes first.
            let typed = recentUsername(for: key)
            let accounts = LoginKeychain.logins(siteID: siteID, host: host).map(\.account)
                .sorted { $0 == typed && $1 != typed }
            let siteName = site(for: siteID)?.name ?? host
            Autofill.offer(accounts: accounts, siteName: siteName, to: message.frameInfo, in: webView)
        case "choose":
            let login = LoginKeychain.Login(siteID: siteID, host: host, account: username)
            let frame = message.frameInfo
            let siteName = site(for: siteID)?.name ?? host
            PasswordGate.authenticate(reason: "fill in your saved password for \(siteName)") { [weak webView] allowed in
                guard allowed, let webView, let password = LoginKeychain.password(for: login) else { return }
                Autofill.fill(username: username, password: password, in: frame, of: webView)
            }
        case "username":
            typedUsernames[key] = (username, Date())
        case "submit":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            let account = username.isEmpty ? recentUsername(for: key) ?? "" : username
            offerToSaveLogin(LoginKeychain.Login(siteID: siteID, host: host, account: account), password: password)
        default:
            break
        }
    }

    /// A username typed on a sign-in's first step, for the password step that follows.
    private func recentUsername(for key: String) -> String? {
        guard let typed = typedUsernames[key], Date().timeIntervalSince(typed.date) < 10 * 60 else { return nil }
        return typed.username
    }

    /// Asks in a banner over the top of the page, which stays until answered, like Safari's.
    /// The password waits here, not in the model the views read.
    private func offerToSaveLogin(_ login: LoginKeychain.Login, password: String) {
        let saved = LoginKeychain.password(for: login)
        guard saved != password else { return }
        pendingLogin = (login, password)
        let siteName = site(for: login.siteID)?.name ?? login.host
        withAnimation(.easeOut(duration: 0.2)) {
            model.loginPrompt = LoginPrompt(siteName: siteName, account: login.account, isUpdate: saved != nil)
        }
    }

    fileprivate func answerLoginPrompt(save: Bool) {
        if save, let (login, password) = pendingLogin {
            LoginKeychain.save(login, password: password)
            showToast(Toast(symbol: "checkmark.circle", message: "Password saved"), for: 2)
        }
        pendingLogin = nil
        withAnimation(.easeOut(duration: 0.2)) { model.loginPrompt = nil }
    }
}

extension PanelViewController: WKNavigationDelegate {
    /// A new page loses the old one's fullscreen state.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let id = webViews.first(where: { $0.value === webView })?.key,
           restoringIDs.remove(id) != nil {
            discardInteractionState(for: id)
        }
        exitFullscreen(webView)
        // Some pages never finish loading (a request that hangs, such as an ad or a stream), and
        // their layout, dark mode and icons would never be looked at; after a while, look anyway.
        let page = ObjectIdentifier(webView)
        settledPages.remove(page)
        let url = webView.url
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak webView] in
            guard let self, let webView, webView.isLoading, webView.url == url else { return }
            self.pageDidSettle(webView)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        if let id = webViews.first(where: { $0.value === webView })?.key,
           restoringIDs.contains(id) {
            fallbackFromFailedRestore(id: id, webView: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        if let id = webViews.first(where: { $0.value === webView })?.key,
           restoringIDs.contains(id) {
            fallbackFromFailedRestore(id: id, webView: webView)
        }
    }

    /// `<a download>` links download; links to other apps (mailto:, zoommtg:, …) open those apps.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(isSpeculative(webView) ? .cancel : .download)
            return
        }
        let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), !webSchemes.contains(scheme) {
            if !isSpeculative(webView),
               navigationAction.navigationType == .linkActivated || (!isSpeculative(webView) && navigationAction.targetFrame?.isMainFrame == true) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// What the page can't show (a zip, a .dmg) or marks as an attachment is saved instead.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")
        let wouldDownload = !navigationResponse.canShowMIMEType || isAttachment
        decisionHandler(wouldDownload ? (isSpeculative(webView) ? .cancel : .download) : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.track(download)
    }

    /// Hands the icons the page declares, in its links and its web app manifest, to the favicon
    /// store, largest first.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageDidSettle(webView)
    }

    /// Once per page: when it finishes loading, or has been loading for a while.
    private func pageDidSettle(_ webView: WKWebView) {
        guard settledPages.insert(ObjectIdentifier(webView)).inserted,
              let id = webViews.first(where: { $0.value === webView })?.key,
              let site = site(for: id),
              let url = webView.url, Site.isSameSite(url.host, site.url.host),
              FaviconStore.key(for: site.url)?.contains("/") != true
                  || url.pathComponents.dropFirst().first == site.url.pathComponents.dropFirst().first
        else { return }
        // Speculative pages must not resolve layouts or trigger a reload behind the user.
        if !isSpeculative(webView) {
            checkAutoLayout(of: webView, site: site)
            checkAutoDarkMode(of: webView, site: site)
        }

        // Links without sizes count as small, except touch icons, which are usually 180px.
        // Manifest icons only meant for masking or monochrome use rank below the rest.
        let script = """
        const sizeOf = sizes => Math.max(0, ...String(sizes || '').split(/\\s+/).map(s => parseInt(s) || 0));
        const icons = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')]
          .map(l => {
            const touch = l.rel.includes('apple-touch-icon');
            return { href: l.href, score: sizeOf(l.getAttribute('sizes')) || (touch ? 180 : 0) };
          });
        const manifest = document.querySelector('link[rel="manifest"]');
        if (manifest) {
          try {
            const response = await fetch(manifest.href, { credentials: 'include', signal: AbortSignal.timeout(5000) });
            const text = await response.text();
            for (const icon of JSON.parse(text.slice(text.indexOf('{'))).icons || []) {
              if (!icon.src || /svg/.test(icon.type || icon.src)) continue;
              const general = (icon.purpose || 'any').split(/\\s+/).includes('any');
              icons.push({ href: new URL(icon.src, response.url).href, score: sizeOf(icon.sizes) / (general ? 1 : 4) });
            }
          } catch {}
        }
        return [...new Set(icons.sort((a, b) => b.score - a.score).map(i => i.href))];
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
            let urls = ((try? result.get()) as? [String] ?? []).compactMap(URL.init(string:))
            FaviconStore.shared.offer(urls, for: site)
        }
    }
}

// MARK: - WKUIDelegate

extension PanelViewController: NSWindowDelegate {
    /// Every popup close lands here, whether from its close button or from the page, and so
    /// does every separate page window's.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let index = detachedWindows.firstIndex(where: { $0.window === window }) {
            detachedWindows.remove(at: index)
            (window.contentView as? WKWebView).map(Self.closePage)
            window.contentView = nil
            window.delegate = nil
            onDetachedWindowsChanged?(detachedWindows.count)
            return
        }
        guard let index = popupWindows.firstIndex(where: { $0 === window }) else { return }
        (window.contentView as? WKWebView).map(Self.closePage)
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
        // Off-screen speculative navigation must not open a popup or launch the browser.
        guard !isSpeculative(webView) else { return nil }
        // Plain target=_blank links go to the default browser, except ones that stay on the
        // page's own site or go through Google's account chooser (e.g. switching to another
        // signed-in account), which load in place so the switch happens here.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if Site.isSameSite(url.host, webView.url?.host) || url.host == "accounts.google.com" {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
        // Script-opened windows (e.g. OAuth sign-in) get a real popup that keeps window.opener.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
        popup.customUserAgent = userAgent
        if let siteID = webViewSites.object(forKey: webView) {
            webViewSites.setObject(siteID, forKey: popup)
        }
        popup.uiDelegate = self
        popup.navigationDelegate = self  // for downloads

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
        guard !isSpeculative(webView) else {
            completionHandler(nil)
            return
        }
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
        guard !isSpeculative(webView) else {
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard !isSpeculative(webView) else {
            completionHandler(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard !isSpeculative(webView) else {
            completionHandler(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// Voice modes (ChatGPT, Gemini) need the microphone. The site itself gets it without
    /// WebKit asking every time; macOS still asks once for the app. Other origins, such as
    /// embedded frames, get WebKit's usual prompt.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Never authorize camera or microphone just because the pointer hovered an icon.
        guard !isSpeculative(webView) else {
            decisionHandler(.deny)
            return
        }
        let isSelected = isPanelVisible && selectedID.flatMap { webViews[$0] } === webView
        let isDetached = detachedWindows.contains { $0.window.contentView === webView }
        guard isSelected || isDetached else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(Site.isSameSite(origin.host, webView.url?.host) ? .grant : .prompt)
    }
}

// MARK: - Rail host

/// NSHostingView hit-tests its SwiftUI content even while hidden, so a hidden view over the page
/// went on swallowing clicks meant for it. The find bar and toasts float over the page.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}

/// The overview takes the click that brings the panel forward, like the iPhone's switcher
/// takes the first tap, instead of the click only making the panel key.
final class OverviewHostingView: NSHostingView<OverviewView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}
