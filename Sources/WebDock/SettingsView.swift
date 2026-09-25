import ServiceManagement
import SwiftUI

/// A preferences window with toolbar tabs, like the system's own apps.
func makeSettingsWindow() -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", GeneralSettingsView()))
    tabs.addTabViewItem(settingsTab("Sites", symbol: "square.grid.2x2", SitesSettingsView()))
    tabs.addTabViewItem(settingsTab("Shortcuts", symbol: "keyboard", ShortcutsSettingsView()))

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
}

private func settingsTab<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = .preferredContentSize
    controller.title = label
    let item = NSTabViewItem(viewController: controller)
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    return item
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var panelSize = PanelSize.saved
    @AppStorage(StartPageView.sortsByUsageKey) private var sortsByUsage = true

    var body: some View {
        Form {
            Section {
                Toggle("Open WebDock at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Text("\(Int(panelSize.width)) × \(Int(panelSize.height))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Reset") {
                            PanelSize.saved = PanelSize.standard
                            panelSize = PanelSize.standard
                        }
                        .disabled(panelSize == PanelSize.standard)
                    }
                }
            } header: {
                Text("Panel")
            } footer: {
                Text("Drag the panel's left, right or bottom edge to resize it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Start Page") {
                Toggle("Put the sites you use most first", isOn: $sortsByUsage)
            }

            Section("Downloads") {
                LabeledContent("Saved to") {
                    HStack(spacing: 10) {
                        Text("Downloads")
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(DownloadManager.folder)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .onAppear {
            panelSize = PanelSize.saved
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Sites

private struct SitesSettingsView: View {
    @ObservedObject private var store = SiteStore.shared
    @ObservedObject private var favicons = FaviconStore.shared
    @State private var selection: Site.ID?
    @State private var isAdding = false
    @State private var confirmingReset = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.sites) { site in
                        HStack(spacing: 8) {
                            SiteGlyph(site: site, icon: favicons.icon(for: site),
                                      plateColor: favicons.plateColor(for: site), size: 18)
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.name)
                                    .lineLimit(1)
                                Text(Self.shortAddress(site.url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(site.id)
                        .onAppear { favicons.load(for: site) }
                    }
                    .onMove { store.sites.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { store.sites.remove(atOffsets: $0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))

                Divider()
                HStack(spacing: 0) {
                    footerButton("plus", help: "Add Site") { isAdding = true }
                    Divider().frame(height: 16)
                    footerButton("minus", help: "Delete Site") { deleteSelected() }
                        .disabled(selection == nil)
                    Spacer()
                    Menu {
                        Button("Restore Default Sites…") { confirmingReset = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 8)
                }
                .frame(height: 26)
                .background(.background)
            }
            .frame(width: 230)

            Divider()

            Group {
                if let selection, store.sites.contains(where: { $0.id == selection }) {
                    SiteEditor(siteID: selection)
                        .id(selection)
                } else {
                    VStack(spacing: 6) {
                        Text("No Site Selected")
                            .font(.headline)
                        Text("Select a site to edit it, or click + to add one.\nDrag sites to change their order.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 420)
        .sheet(isPresented: $isAdding) {
            AddSiteForm { site in
                store.sites.append(site)
                selection = site.id
                isAdding = false
            } onCancel: {
                isAdding = false
            }
            .padding(20)
            .frame(width: 360)
        }
        .confirmationDialog("Restore the default site list?", isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive) {
                selection = nil
                store.resetToDefaults()
            }
        } message: {
            Text("Sites you added or edited will be removed.")
        }
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// "chatgpt.com", or "www.google.com/finance" for a site under a path.
    private static func shortAddress(_ url: URL) -> String {
        let path = url.path == "/" ? "" : url.path
        return (url.host ?? url.absoluteString) + path
    }

    private func deleteSelected() {
        guard let index = store.sites.firstIndex(where: { $0.id == selection }) else { return }
        store.sites.remove(at: index)
        selection = nil
    }
}

/// Edits one site in place: the name, layout and dark mode save as they change; the address
/// saves on Return or when the field loses focus, and only if it's valid.
private struct SiteEditor: View {
    let siteID: UUID
    @ObservedObject private var store = SiteStore.shared
    @State private var name = ""
    @State private var urlText = ""
    @State private var urlError: String?
    @FocusState private var isURLFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onChange(of: name) { newName in
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { update { $0.name = trimmed } }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("URL", text: $urlText)
                        .focused($isURLFocused)
                        .onSubmit(commitURL)
                    if let urlError {
                        Text(urlError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                Picker("Layout", selection: binding(\.layout)) {
                    ForEach(Site.Layout.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                Picker("Dark Mode", selection: binding(\.darkMode)) {
                    ForEach(Site.DarkMode.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Auto layout switches to the site's phone version when its desktop page doesn't fit the panel. Auto dark mode darkens pages that stay light while the system is dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard let site else { return }
            name = site.name
            urlText = site.url.absoluteString
        }
        .onChange(of: isURLFocused) { focused in
            if !focused { commitURL() }
        }
    }

    private var site: Site? {
        store.sites.first { $0.id == siteID }
    }

    private func update(_ change: (inout Site) -> Void) {
        guard let index = store.sites.firstIndex(where: { $0.id == siteID }) else { return }
        change(&store.sites[index])
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Site, Value>) -> Binding<Value> {
        let fallback = site![keyPath: keyPath]
        return Binding(get: { site?[keyPath: keyPath] ?? fallback },
                       set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func commitURL() {
        guard let url = Site.normalizedURL(from: urlText) else {
            urlError = "Invalid URL. It must be an http(s) address."
            return
        }
        urlError = nil
        urlText = url.absoluteString
        if site?.url != url {
            update { $0.url = url }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsView: View {
    private let panelShortcuts: [(String, String)] = [
        ("⌘1 – ⌘9", "Switch to a site"),
        ("⌘T", "Start page"),
        ("⌘R", "Reload"),
        ("⌘F", "Find on page"),
        ("⌘G  /  ⇧⌘G", "Next / previous match"),
        ("⌘+  /  ⌘−  /  ⌘0", "Zoom in / out / actual size"),
        ("Esc  /  ⌘W", "Close the panel"),
        ("⌘,", "Settings"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("Show or hide WebDock") {
                    ShortcutRecorder()
                }
            } header: {
                Text("Global")
            } footer: {
                Text("Works from any app. Click the shortcut, then press the new keys; Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("In the Panel") {
                ForEach(panelShortcuts, id: \.0) { keys, action in
                    LabeledContent(action) {
                        Text(keys)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
    }
}
