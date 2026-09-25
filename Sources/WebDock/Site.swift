import Foundation

struct Site: Codable, Identifiable, Equatable {
    /// Desktop: a Mac Safari user agent. Mobile: an iPhone one, so the site serves its phone
    /// layout, which fits the narrow panel. Auto: desktop unless the page turns out too wide.
    enum Layout: String, Codable, CaseIterable {
        case auto, desktop, mobile

        var title: String {
            switch self {
            case .auto: "Auto"
            case .desktop: "Desktop"
            case .mobile: "Mobile"
            }
        }
    }

    /// Pages that ignore the system's dark mode can be darkened by inverting them.
    /// Auto: invert only if the page stays light while the system is dark.
    enum DarkMode: String, Codable, CaseIterable {
        case auto, force, off

        var title: String {
            switch self {
            case .auto: "Auto"
            case .force: "Force"
            case .off: "Off"
            }
        }
    }

    var id = UUID()
    var name: String
    var url: URL
    var layout: Layout = .auto
    var darkMode: DarkMode = .auto

    init(name: String, url: URL, layout: Layout = .auto, darkMode: DarkMode = .auto) {
        self.name = name
        self.url = url
        self.layout = layout
        self.darkMode = darkMode
    }

    // Sites saved before `layout` / `darkMode` existed decode them as .auto.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .auto
        darkMode = try container.decodeIfPresent(DarkMode.self, forKey: .darkMode) ?? .auto
    }

    /// Hosts that differ only by a www./m./mobile. prefix belong to the same site.
    static func isSameSite(_ a: String?, _ b: String?) -> Bool {
        func base(_ host: String?) -> String? {
            guard var host = host?.lowercased() else { return nil }
            for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
                host.removeFirst(prefix.count)
            }
            return host
        }
        return base(a) != nil && base(a) == base(b)
    }

    /// Accepts "chatgpt.com" as well as full URLs; only http(s) with a real host is valid, so a
    /// bare word like "YKpedia" (a name typed into the address field) is rejected.
    static func normalizedURL(from text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, !string.contains(" ") else { return nil }
        if !string.contains("://") {
            string = "https://" + string
        }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              host.contains(".") || host.contains(":") || host == "localhost" else { return nil }
        return url
    }
}

let defaultSites: [Site] = [
    Site(name: "ChatGPT", url: URL(string: "https://chatgpt.com")!),
    Site(name: "Claude", url: URL(string: "https://claude.ai")!),
    Site(name: "Gemini", url: URL(string: "https://gemini.google.com/app")!),
    Site(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com")!),
    Site(name: "Perplexity", url: URL(string: "https://www.perplexity.ai")!),
]

/// The user's site list, persisted in UserDefaults.
final class SiteStore: ObservableObject {
    static let shared = SiteStore()

    private let storageKey = "services"

    @Published var sites: [Site] {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([Site].self, from: data) {
            sites = saved
        } else {
            sites = defaultSites
        }
    }

    func resetToDefaults() {
        sites = defaultSites
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
