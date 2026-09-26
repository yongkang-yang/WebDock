import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The latest page seen on a site, for the start page's "Jump back in" list.
struct RecentPage: Codable, Identifiable, Equatable {
    var siteID: UUID
    var title: String
    var url: URL
    var date: Date

    var id: UUID { siteID }
}

/// A short message over the bottom of the page: a finished download, a zoom change.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// State the SwiftUI chrome reads; PanelViewController owns the web views and fills this in.
final class PanelModel: ObservableObject {
    /// The start page: a Google search box plus the site grid; searching turns it into a Google page.
    static let homeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let homeSite: Site = {
        var site = Site(name: "Google", url: URL(string: "https://www.google.com")!, layout: .mobile)
        site.id = homeID
        return site
    }()

    @Published var sites: [Site] = []
    /// Newest first, one per site.
    @Published var recents: [RecentPage] = []
    @Published var selectedID: UUID?
    @Published var liveIDs: Set<UUID> = []
    /// Pinned pages are never released, and while one is on screen the panel stays open.
    @Published var pinnedIDs: Set<UUID> = []
    @Published var isLoading = false
    @Published var canGoBack = false
    /// Pinned: the rail sits beside the page. Unpinned: it floats over the page on hover.
    @Published var isRailPinned = false
    /// The current page's color, used to tint glass that sits over the page.
    @Published var pageColor: NSColor?
    /// Unread counts that live pages show in their titles, e.g. "Inbox (3)" or "(3) Home / X".
    @Published var badges: [UUID: Int] = [:]
    /// The current page's zoom; 1 is actual size.
    @Published var zoom: Double = 1
    @Published var toast: Toast?
    @Published var isFindVisible = false
    @Published var findQuery = ""
    @Published var findNotFound = false
    @Published var findFocusRequest = 0

    var onSelect: (UUID) -> Void = { _ in }
    var onCloseSite: (UUID) -> Void = { _ in }
    var onOpenInBrowser: (UUID?) -> Void = { _ in }
    /// nil means the page on screen.
    var onOpenInWindow: (UUID?) -> Void = { _ in }
    /// nil means the page on screen.
    var onTogglePin: (UUID?) -> Void = { _ in }
    var onBack: () -> Void = {}
    /// To the start page: from a site, or from home's own search results.
    var onGoHome: () -> Void = {}
    var onReload: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onToggleRailPin: () -> Void = {}
    var onSetLayout: (UUID, Site.Layout) -> Void = { _, _ in }
    var onSetDarkMode: (UUID, Site.DarkMode) -> Void = { _, _ in }
    var onSearch: (String) -> Void = { _ in }
    var onAddSite: (Site) -> Void = { _ in }
    /// Moves the first site to where the second one is, as a drag over it does.
    var onMoveSite: (UUID, UUID) -> Void = { _, _ in }
    /// The page on screen as an address and a suggested name, for "Add Page as Site".
    var pageForAdding: () -> (url: String, name: String) = { ("", "") }
    var onShowFind: () -> Void = {}
    /// Query, backwards, and whether to start over from the top (the query changed).
    var onFind: (String, Bool, Bool) -> Void = { _, _, _ in }
    var onCloseFind: () -> Void = {}
    var onZoom: (ZoomChange) -> Void = { _ in }
    /// Bumped to move keyboard focus into the start page's search field.
    @Published var searchFocusRequest = 0
    var onRailHover: (Bool) -> Void = { _ in }

    enum ZoomChange { case zoomIn, zoomOut, reset }

    var selectedSite: Site? { sites.first { $0.id == selectedID } }
    var isHomeSelected: Bool { selectedID == Self.homeID }
}

/// The strip of site icons. Docked beside the page when pinned, a floating glass plate otherwise.
struct RailView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var favicons = FaviconStore.shared

    var body: some View {
        Group {
            if model.isRailPinned {
                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        siteButtons.padding(.vertical, 2)
                    }
                    Spacer(minLength: Metrics.gap)
                    settingsButton
                }
            } else {
                VStack(spacing: 8) {
                    siteButtons
                    settingsButton
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .glassSurface(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous),
                              tint: model.pageColor.map { Color(nsColor: $0).opacity(0.85) })
            }
        }
        .onHover { model.onRailHover($0) }
    }

    private var siteButtons: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                RailIconButton(help: "Home (⌘T)",
                               isSelected: model.isHomeSelected,
                               isLive: model.liveIDs.contains(PanelModel.homeID),
                               badge: nil) {
                    model.onSelect(PanelModel.homeID)
                } glyph: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                    RailButton(
                        site: site,
                        icon: favicons.icon(for: site),
                        plateColor: favicons.plateColor(for: site),
                        shortcut: index < 9 ? index + 1 : nil,
                        isSelected: site.id == model.selectedID,
                        isLive: model.liveIDs.contains(site.id),
                        badge: model.badges[site.id]
                    ) {
                        model.onSelect(site.id)
                    }
                    .contextMenu {
                        Button("Open in Browser") { model.onOpenInBrowser(site.id) }
                        Button("Open in Window") { model.onOpenInWindow(site.id) }
                        Button(model.pinnedIDs.contains(site.id) ? "Unpin Page" : "Pin Page") {
                            model.onTogglePin(site.id)
                        }
                        .disabled(!model.liveIDs.contains(site.id))
                        Button("Close Page") { model.onCloseSite(site.id) }
                            .disabled(!model.liveIDs.contains(site.id))
                        Divider()
                        Picker("Layout", selection: Binding(
                            get: { site.layout },
                            set: { model.onSetLayout(site.id, $0) }
                        )) {
                            ForEach(Site.Layout.allCases, id: \.self) { Text($0.title) }
                        }
                        Picker("Dark Mode", selection: Binding(
                            get: { site.darkMode },
                            set: { model.onSetDarkMode(site.id, $0) }
                        )) {
                            ForEach(Site.DarkMode.allCases, id: \.self) { Text($0.title) }
                        }
                    }
                    .onAppear { favicons.load(for: site) }
                }
            }
        }
    }

    private var settingsButton: some View {
        GlassIconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.onOpenSettings() }
    }
}

private struct RailButton: View {
    let site: Site
    let icon: NSImage?
    let plateColor: NSColor?
    let shortcut: Int?
    let isSelected: Bool
    let isLive: Bool
    let badge: Int?
    let action: () -> Void

    var body: some View {
        RailIconButton(help: shortcut.map { "\(site.name) (⌘\($0))" } ?? site.name,
                       isSelected: isSelected, isLive: isLive, badge: badge, action: action) {
            SiteGlyph(site: site, icon: icon, plateColor: plateColor, size: 20)
        }
    }
}

/// One rail slot: a glass squircle with a dock-style dot when its page is running.
private struct RailIconButton<Glyph: View>: View {
    let help: String
    let isSelected: Bool
    let isLive: Bool
    let badge: Int?
    let action: () -> Void
    @ViewBuilder let glyph: Glyph

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.railIconRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(isLive ? Color.primary.opacity(0.55) : .clear)
                .frame(width: 4, height: 4)

            Button(action: action) {
                glyph
                    .frame(width: Metrics.railIcon, height: Metrics.railIcon)
                    .contentShape(shape)
                    .glassSurface(in: shape, tint: isSelected ? Color.accentColor.opacity(0.35) : nil, interactive: true)
                    .opacity(isSelected || isLive ? 1 : 0.7)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            BadgeView(count: badge).offset(x: 5, y: -4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .padding(.trailing, 6)  // balances the dot so the icon sits centered
    }
}

/// A red unread-count capsule, like the Dock's.
struct BadgeView: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(Color.red))
            .fixedSize()
    }
}

/// A site's favicon, on a contrasting plate if it's a bare glyph; its initial when there's no icon.
struct SiteGlyph: View {
    let site: Site
    let icon: NSImage?
    let plateColor: NSColor?
    let size: CGFloat
    var cornerRadius: CGFloat?
    /// How far a bare glyph sits in from its plate's edge, as a fraction of the size.
    var plateInset: CGFloat = 0.12

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(plateColor == nil ? 0 : size * plateInset)
                .frame(width: size, height: size)
                .background(plateColor.map { Color(nsColor: $0) } ?? .clear)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size / 4, style: .continuous))
        } else {
            Text(site.name.prefix(1).uppercased())
                .font(.system(size: size * 0.75, weight: .semibold, design: .rounded))
        }
    }
}

/// The strip above the web page: rail toggle, current site, loading state, navigation buttons.
struct HeaderView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var favicons = FaviconStore.shared
    @State private var addingPage: (url: String, name: String)?

    var body: some View {
        HStack(spacing: 8) {
            GlassIconButton(symbol: "sidebar.left",
                            help: model.isRailPinned ? "Auto-hide Sidebar" : "Pin Sidebar") {
                model.onToggleRailPin()
            }
            if let site = model.selectedSite {
                SiteGlyph(site: site, icon: favicons.icon(for: site),
                          plateColor: favicons.plateColor(for: site), size: 16)
                Text(site.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            } else if model.isHomeSelected {
                let searching = model.liveIDs.contains(PanelModel.homeID)
                Image(systemName: searching ? "magnifyingglass" : "house.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(searching ? "Google" : "Home")
                    .font(.system(size: 13, weight: .semibold))
            }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if hasPage, abs(model.zoom - 1) > 0.001 {
                Button {
                    model.onZoom(.reset)
                } label: {
                    Text("\(Int((model.zoom * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .contentShape(Capsule())
                        .glassSurface(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Actual Size (⌘0)")
            }
            Spacer()
            if hasPage {
                GlassGroup {
                    HStack(spacing: 6) {
                        GlassIconButton(symbol: "chevron.left", help: "Back", dimmed: !model.canGoBack) {
                            model.onBack()
                        }
                        .disabled(!model.canGoBack)
                        GlassIconButton(symbol: "house", help: "Home (⌘T)") {
                            model.onGoHome()
                        }
                        GlassIconButton(symbol: "arrow.clockwise", help: "Reload (⌘R)") {
                            model.onReload()
                        }
                        GlassIconButton(symbol: "safari", help: "Open in Browser") {
                            model.onOpenInBrowser(nil)
                        }
                        let pinned = model.selectedID.map(model.pinnedIDs.contains) ?? false
                        GlassIconButton(symbol: pinned ? "pin.fill" : "pin",
                                        help: pinned ? "Unpin Page" : "Pin Page (keeps the panel open and the page loaded)") {
                            model.onTogglePin(nil)
                        }
                        moreMenu
                    }
                }
                // Set apart from the other buttons, and it takes a second click, so a stray
                // click never throws away the page.
                if let id = model.selectedID {
                    ConfirmCloseButton { model.onCloseSite(id) }
                        .padding(.leading, 6)
                        .id(id)
                }
            }
        }
        .frame(height: Metrics.headerHeight)
    }

    private var hasPage: Bool {
        model.selectedSite != nil || model.liveIDs.contains(PanelModel.homeID) && model.isHomeSelected
    }

    private var moreMenu: some View {
        Menu {
            Button("Add Page as Site…") { addingPage = model.pageForAdding() }
            Button("Open in Window") { model.onOpenInWindow(nil) }
            Divider()
            Button("Find on Page…") { model.onShowFind() }
            Button("Zoom In") { model.onZoom(.zoomIn) }
            Button("Zoom Out") { model.onZoom(.zoomOut) }
            Button("Actual Size") { model.onZoom(.reset) }
                .disabled(abs(model.zoom - 1) < 0.001)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: Metrics.iconButton, height: Metrics.iconButton)
        .contentShape(Circle())
        .glassSurface(in: Circle(), interactive: true)
        .help("More")
        .popover(isPresented: Binding(get: { addingPage != nil }, set: { if !$0 { addingPage = nil } }),
                 arrowEdge: .bottom) {
            AddSiteForm(initialURL: addingPage?.url ?? "", initialName: addingPage?.name ?? "") { site in
                model.onAddSite(site)
                addingPage = nil
            } onCancel: {
                addingPage = nil
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// Closes the page on screen, like "Close Page": the first click arms it, turning it into a red
/// "Close Page?" capsule, and only a second click within a few seconds closes. Leaving it disarms.
private struct ConfirmCloseButton: View {
    let action: () -> Void
    @State private var isArmed = false
    @State private var disarmWork: DispatchWorkItem?

    var body: some View {
        Button {
            if isArmed {
                disarm()
                action()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { isArmed = true }
                let work = DispatchWorkItem { disarm() }
                disarmWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                if isArmed {
                    Text("Close Page?")
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(isArmed ? Color.white : Color.primary)
            .padding(.horizontal, isArmed ? 10 : 0)
            .frame(minWidth: Metrics.iconButton, minHeight: Metrics.iconButton)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), tint: isArmed ? Color.red.opacity(0.85) : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .help(isArmed ? "Click again to close the page" : "Close Page (click twice)")
        .onHover { inside in
            if !inside, isArmed { disarm() }
        }
    }

    private func disarm() {
        disarmWork?.cancel()
        disarmWork = nil
        withAnimation(.easeOut(duration: 0.15)) { isArmed = false }
    }
}

/// ⌘F: a capsule over the top right of the page.
struct FindBarView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var isFocused: Bool

    var body: some View {
        if model.isFindVisible {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Find on Page", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 160)
                    .focused($isFocused)
                    .onSubmit { model.onFind(model.findQuery, false, false) }
                    .onExitCommand { model.onCloseFind() }
                if model.findNotFound, !model.findQuery.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                findButton("chevron.up", help: "Previous (⇧⌘G)") { model.onFind(model.findQuery, true, false) }
                findButton("chevron.down", help: "Next (⌘G)") { model.onFind(model.findQuery, false, false) }
                findButton("xmark", help: "Done (Esc)") { model.onCloseFind() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 34)
            .glassSurface(in: Capsule(), tint: model.pageColor.map { Color(nsColor: $0).opacity(0.85) })
            .onAppear { isFocused = true }
            .onChange(of: model.findFocusRequest) { _ in isFocused = true }
            .onChange(of: model.findQuery) { query in model.onFind(query, false, true) }
        }
    }

    private func findButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(model.findQuery.isEmpty && symbol != "xmark")
    }
}

/// A transient capsule over the bottom of the page.
struct ToastView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(toast.message)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let title = toast.actionTitle, let action = toast.action {
                    Button(title, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .frame(maxWidth: 360)
            .glassSurface(in: Capsule(), tint: model.pageColor.map { Color(nsColor: $0).opacity(0.85) })
            .fixedSize()
        }
    }
}

/// Start page text in the system's language; the rest of the app is English only.
private enum StartText {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }
}

/// What the panel shows on launch and on ⌘T: a greeting, a search box, the user's sites,
/// and the pages they were last on.
struct StartPageView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var favicons = FaviconStore.shared
    @State private var query = ""
    @State private var isAdding = false
    @State private var draggingID: UUID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 26) {
                    greeting(at: context.date)
                    searchField
                    siteGrid
                    if !recentPages.isEmpty {
                        recentList(now: context.date)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: model.searchFocusRequest) { _ in isSearchFocused = true }
    }

    // MARK: Greeting

    private func greeting(at date: Date) -> some View {
        VStack(spacing: 4) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(Self.greetingLine(at: date))
                .font(.system(size: 15, weight: .medium))
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private static func greetingLine(at date: Date) -> String {
        let salutation = switch Calendar.current.component(.hour, from: date) {
        case 5..<12: StartText.t("Good morning", "早上好")
        case 12..<18: StartText.t("Good afternoon", "下午好")
        case 18..<23: StartText.t("Good evening", "晚上好")
        default: StartText.t("Good night", "夜深了")
        }
        guard let firstName else { return salutation }
        return salutation + StartText.t(", ", "，") + firstName
    }

    private static let firstName: String? = NSFullUserName()
        .split(separator: " ").first.map(String.init)

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Text("G")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField(StartText.t("Search Google or enter a URL", "搜索 Google 或输入网址"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFocused)
                .onSubmit(submit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .glassSurface(in: Capsule(), interactive: true)
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.onSearch(text)
        query = ""
    }

    // MARK: Sites

    private var siteGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
            // The user's own order, the same as the rail's; drag a tile to move it.
            ForEach(model.sites) { site in
                tile(label: site.name, isLive: model.liveIDs.contains(site.id)) {
                    model.onSelect(site.id)
                } glyph: {
                    siteTileGlyph(site)
                } tint: {
                    favicons.accentColor(for: site).map { Color(nsColor: $0).opacity(0.28) }
                } corner: {
                    if let badge = model.badges[site.id] {
                        BadgeView(count: badge).offset(x: 4, y: -4)
                    }
                }
                .onAppear { favicons.load(for: site) }
                .onDrag {
                    draggingID = site.id
                    return NSItemProvider(object: site.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: TileDropDelegate(target: site.id, dragging: $draggingID,
                                                                move: model.onMoveSite))
            }
            tile(label: StartText.t("Add Site", "添加网站")) {
                isAdding = true
            } glyph: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            } tint: {
                nil
            } corner: {
                EmptyView()
            }
            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                AddSiteForm { site in
                    model.onAddSite(site)
                    isAdding = false
                } onCancel: {
                    isAdding = false
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }

    /// An icon fills the whole tile, like an app icon; a site without one shows its initial.
    @ViewBuilder
    private func siteTileGlyph(_ site: Site) -> some View {
        if let icon = favicons.icon(for: site) {
            SiteGlyph(site: site, icon: icon, plateColor: favicons.plateColor(for: site),
                      size: Self.tileSize, cornerRadius: Self.tileCornerRadius, plateInset: 0.22)
        } else {
            SiteGlyph(site: site, icon: nil, plateColor: nil, size: 28)
        }
    }

    private static let tileSize: CGFloat = 58
    private static let tileCornerRadius: CGFloat = 18

    /// A running site gets a dock-style dot under its name, like its rail slot; on the icon
    /// itself the dot would vanish into icons of its own color.
    private func tile<Glyph: View, Corner: View>(label: String,
                                                 isLive: Bool = false,
                                                 action: @escaping () -> Void,
                                                 @ViewBuilder glyph: () -> Glyph,
                                                 tint: () -> Color?,
                                                 @ViewBuilder corner: () -> Corner) -> some View {
        // Not a Button: a button keeps tracking the mouse after the press, so dragging a tile
        // to rearrange it would never start.
        VStack(spacing: 7) {
            glyph()
                .frame(width: Self.tileSize, height: Self.tileSize)
                .glassSurface(in: RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous),
                              tint: tint(), interactive: true)
                .overlay(alignment: .topTrailing, content: corner)
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Circle()
                    .fill(isLive ? Color.primary.opacity(0.55) : .clear)
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }

    // MARK: Recents

    private var recentPages: [(RecentPage, Site)] {
        model.recents.prefix(4).compactMap { recent in
            model.sites.first { $0.id == recent.siteID }.map { (recent, $0) }
        }
    }

    private func recentList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StartText.t("Jump back in", "继续浏览"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(recentPages.enumerated()), id: \.element.0.id) { index, pair in
                    let (recent, site) = pair
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    Button {
                        model.onSelect(site.id)
                    } label: {
                        HStack(spacing: 12) {
                            SiteGlyph(site: site, icon: favicons.icon(for: site),
                                      plateColor: favicons.plateColor(for: site), size: 20)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recent.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Text("\(site.name) · \(Self.relative(recent.date, now: now))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return StartText.t("just now", "刚刚") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Reorders start page tiles live while one is dragged over another, like icons in the Dock.
private struct TileDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.2)) { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
