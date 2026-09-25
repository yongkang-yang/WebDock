import AppKit
import SwiftUI

/// The latest page seen on a site, for the start page's "Jump back in" list.
struct RecentPage: Codable, Identifiable, Equatable {
    var siteID: UUID
    var title: String
    var url: URL
    var date: Date

    var id: UUID { siteID }
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

    var onSelect: (UUID) -> Void = { _ in }
    var onCloseSite: (UUID) -> Void = { _ in }
    var onOpenInBrowser: (UUID?) -> Void = { _ in }
    /// nil means the page on screen.
    var onTogglePin: (UUID?) -> Void = { _ in }
    var onBack: () -> Void = {}
    var onReload: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onToggleRailPin: () -> Void = {}
    var onSetLayout: (UUID, Site.Layout) -> Void = { _, _ in }
    var onSetDarkMode: (UUID, Site.DarkMode) -> Void = { _, _ in }
    var onSearch: (String) -> Void = { _ in }
    /// Bumped to move keyboard focus into the start page's search field.
    @Published var searchFocusRequest = 0
    var onRailHover: (Bool) -> Void = { _ in }

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
                               isLive: model.liveIDs.contains(PanelModel.homeID)) {
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
                        isLive: model.liveIDs.contains(site.id)
                    ) {
                        model.onSelect(site.id)
                    }
                    .contextMenu {
                        Button("Open in Browser") { model.onOpenInBrowser(site.id) }
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
    let action: () -> Void

    var body: some View {
        RailIconButton(help: shortcut.map { "\(site.name) (⌘\($0))" } ?? site.name,
                       isSelected: isSelected, isLive: isLive, action: action) {
            SiteGlyph(site: site, icon: icon, plateColor: plateColor, size: 20)
        }
    }
}

/// One rail slot: a glass squircle with a dock-style dot when its page is running.
private struct RailIconButton<Glyph: View>: View {
    let help: String
    let isSelected: Bool
    let isLive: Bool
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
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .padding(.trailing, 6)  // balances the dot so the icon sits centered
    }
}

/// A site's favicon, on a contrasting plate if it's a bare glyph; its initial when there's no icon.
struct SiteGlyph: View {
    let site: Site
    let icon: NSImage?
    let plateColor: NSColor?
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(plateColor == nil ? 0 : size * 0.12)
                .frame(width: size, height: size)
                .background(plateColor.map { Color(nsColor: $0) } ?? .clear)
                .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
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
            Spacer()
            if model.selectedSite != nil || model.liveIDs.contains(PanelModel.homeID) && model.isHomeSelected {
                GlassGroup {
                    HStack(spacing: 6) {
                        GlassIconButton(symbol: "chevron.left", help: "Back", dimmed: !model.canGoBack) {
                            model.onBack()
                        }
                        .disabled(!model.canGoBack)
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
                    }
                }
            }
        }
        .frame(height: Metrics.headerHeight)
    }
}

/// What the panel shows on launch and on ⌘T: a greeting, a search box, the user's sites,
/// and the pages they were last on.
struct StartPageView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var favicons = FaviconStore.shared
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 26) {
                    greeting(at: context.date)
                    searchField
                    if model.sites.isEmpty {
                        Text("Add sites in Settings (⌘,)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        siteGrid
                    }
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
            Text("\(Self.salutation(at: date))\(Self.firstName.map { ", \($0)" } ?? "")")
                .font(.system(size: 15, weight: .medium))
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private static func salutation(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
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
            TextField("Search Google or enter a URL", text: $query)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 16) {
            ForEach(model.sites) { site in
                Button {
                    model.onSelect(site.id)
                } label: {
                    VStack(spacing: 7) {
                        SiteGlyph(site: site, icon: favicons.icon(for: site),
                                  plateColor: favicons.plateColor(for: site), size: 28)
                            .frame(width: 58, height: 58)
                            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                                          tint: favicons.accentColor(for: site).map { Color(nsColor: $0).opacity(0.28) },
                                          interactive: true)
                            .overlay(alignment: .topTrailing) {
                                if model.liveIDs.contains(site.id) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                        .offset(x: -5, y: 5)
                                }
                            }
                        Text(site.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear { favicons.load(for: site) }
            }
        }
    }

    // MARK: Recents

    private var recentPages: [(RecentPage, Site)] {
        model.recents.prefix(4).compactMap { recent in
            model.sites.first { $0.id == recent.siteID }.map { (recent, $0) }
        }
    }

    private func recentList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jump back in")
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
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
