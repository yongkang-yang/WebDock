import SwiftUI

/// Address first, then a name that fills itself in from the page until the user types one.
/// Used by the panel's "+" popovers and by Settings.
struct AddSiteForm: View {
    var initialURL = ""
    var initialName = ""
    let onAdd: (Site) -> Void
    let onCancel: () -> Void

    @State private var urlText = ""
    @State private var name = ""
    /// The user typed the name, so fetched titles leave it alone.
    @State private var isNameEdited = false
    @State private var isFetching = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Site")
                .font(.headline)
            TextField("URL", text: $urlText, prompt: Text("e.g. x.com"))
                .textFieldStyle(.roundedBorder)
                .focused($isURLFocused)
                .onSubmit(add)
            HStack(spacing: 6) {
                TextField("Name", text: Binding(get: { name }, set: { name = $0; isNameEdited = true }),
                          prompt: Text(placeholderName))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if isFetching {
                    ProgressView().controlSize(.small)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            urlText = initialURL
            name = initialName
            isURLFocused = true
        }
        .onChange(of: urlText) { text in
            errorMessage = nil
            guard text != initialURL else { return }
            scheduleTitleFetch(for: text)
        }
        .onDisappear { fetchTask?.cancel() }
    }

    private var placeholderName: String {
        Site.normalizedURL(from: urlText).map(SiteTitle.fromHost) ?? "e.g. X"
    }

    private func scheduleTitleFetch(for text: String) {
        fetchTask?.cancel()
        guard !isNameEdited, let url = Site.normalizedURL(from: text), url.host?.contains(".") == true else {
            isFetching = false
            return
        }
        fetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            isFetching = true
            let title = await SiteTitle.fetch(url)
            guard !Task.isCancelled else { return }
            isFetching = false
            if !isNameEdited, let title {
                name = title
            }
        }
    }

    private func add() {
        var name = name
        var url = Site.normalizedURL(from: urlText)
        // The address went into the name field and the name into the address field.
        if url == nil, let swapped = Site.normalizedURL(from: name) {
            url = swapped
            name = urlText
        }
        guard let url else {
            errorMessage = "Invalid URL. It must be an http(s) address."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(Site(name: trimmed.isEmpty ? SiteTitle.fromHost(url) : trimmed, url: url))
    }
}

/// Finds a short name for a site: what the page calls itself, or failing that its domain.
enum SiteTitle {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// "chat.deepseek.com" → "Deepseek".
    static func fromHost(_ url: URL) -> String {
        let parts = (url.host ?? "").split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? ""
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A page title often reads "Page – Section | Brand"; the brand is the part worth keeping.
    static func brand(fromTitle title: String) -> String {
        let separators = [" | ", " - ", " – ", " — ", " · ", " / ", " • "]
        var parts = [title]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.last ?? title
    }

    static func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let head = data.prefix(300_000)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }

        for property in ["og:site_name", "application-name", "apple-mobile-web-app-title"] {
            if let value = metaContent(property, in: html) {
                return value
            }
        }
        if let title = firstMatch(#"<title[^>]*>([^<]+)</title>"#, in: html) {
            return brand(fromTitle: decodeEntities(title))
        }
        return nil
    }

    /// The content of <meta property|name="key" content="…">, attributes in either order.
    private static func metaContent(_ key: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"<meta[^>]+(?:property|name)=["']"# + escaped + #"["'][^>]*content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']"# + escaped + #"["']"#,
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern, in: html) {
                let decoded = decodeEntities(value)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeEntities(_ text: String) -> String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
