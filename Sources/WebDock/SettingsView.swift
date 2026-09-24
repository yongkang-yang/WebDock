import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SiteStore.shared

    @State private var selection: Site.ID?
    @State private var name = ""
    @State private var urlText = ""
    @State private var layout: Site.Layout = .auto
    @State private var darkMode: Site.DarkMode = .auto
    @State private var errorMessage: String?
    @State private var confirmingReset = false

    private var selectedIndex: Int? {
        store.sites.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sites (drag to reorder)")
                .font(.headline)

            List(selection: $selection) {
                ForEach(store.sites) { service in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                        Text(service.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(service.id)
                }
                .onMove { store.sites.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.sites.remove(atOffsets: $0) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)

            HStack {
                Button("Delete") { deleteSelected() }
                    .disabled(selectedIndex == nil)
                Button("Move Up") { moveSelected(by: -1) }
                    .disabled((selectedIndex ?? 0) == 0)
                Button("Move Down") { moveSelected(by: 1) }
                    .disabled(selectedIndex.map { $0 >= store.sites.count - 1 } ?? true)
                Spacer()
                Button("Restore Defaults…") { confirmingReset = true }
            }

            Divider()

            Text(selection == nil ? "Add Site" : "Edit Site")
                .font(.headline)

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. X"))
                TextField("URL", text: $urlText, prompt: Text("e.g. x.com"))
                Picker("Layout", selection: $layout) {
                    ForEach(Site.Layout.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                Picker("Dark Mode", selection: $darkMode) {
                    ForEach(Site.DarkMode.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if selection != nil {
                    Button("Cancel") { selection = nil }
                }
                Spacer()
                Button(selection == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 620)
        .onChange(of: selection) { _ in fillForm() }
        .confirmationDialog("Restore the default site list?", isPresented: $confirmingReset) {
            Button("Restore Defaults", role: .destructive) {
                selection = nil
                store.resetToDefaults()
            }
        } message: {
            Text("Sites you added or edited will be removed.")
        }
    }

    private func fillForm() {
        errorMessage = nil
        if let index = selectedIndex {
            name = store.sites[index].name
            urlText = store.sites[index].url.absoluteString
            layout = store.sites[index].layout
            darkMode = store.sites[index].darkMode
        } else {
            name = ""
            urlText = ""
            layout = .auto
            darkMode = .auto
        }
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Please enter a name."
            return
        }
        guard let url = Site.normalizedURL(from: urlText) else {
            errorMessage = "Invalid URL. It must be an http(s) address."
            return
        }

        if let index = selectedIndex {
            store.sites[index].name = trimmedName
            store.sites[index].url = url
            store.sites[index].layout = layout
            store.sites[index].darkMode = darkMode
        } else {
            store.sites.append(Site(name: trimmedName, url: url, layout: layout, darkMode: darkMode))
            name = ""
            urlText = ""
            layout = .auto
            darkMode = .auto
        }
        errorMessage = nil
    }

    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        store.sites.remove(at: index)
        selection = nil
    }

    private func moveSelected(by offset: Int) {
        guard let index = selectedIndex else { return }
        let target = index + offset
        guard store.sites.indices.contains(target) else { return }
        store.sites.swapAt(index, target)
    }
}
