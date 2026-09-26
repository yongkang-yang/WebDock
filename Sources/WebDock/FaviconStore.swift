import AppKit

/// Site icons for the rail. Tries the site's well-known icon paths up front, and
/// upgrades to whatever the page itself declares once it has loaded. Icons are
/// cached on disk per host and first path segment, so they only download once, and
/// www.google.com/finance doesn't share www.google.com's icon.
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    /// Keyed by `key(for:)`, as are the other per-icon tables.
    @Published private(set) var icons: [String: NSImage] = [:]
    /// Hosts whose icon is a bare glyph on transparency, mapped to whether that glyph is light.
    /// Such icons get a contrasting plate so they don't vanish into the chrome.
    @Published private(set) var bareGlyphIsLight: [String: Bool] = [:]
    /// Each icon's most colorful tone, for tinting the start page tiles.
    @Published private(set) var accentColors: [String: NSColor] = [:]
    private var attempted: Set<String> = []
    /// Keys whose icon has come from the page this launch. A site under a path (e.g. Google
    /// Finance) starts from its host's generic icon, so the page's own icon always replaces it once.
    private var declared: Set<String> = []
    private let cacheDirectory: URL
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("com.johanyang.WebDock/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Host plus first path segment, if the site's address has one.
    static func key(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return url.pathComponents.dropFirst().first.map { host + "/" + $0 } ?? host
    }

    func icon(for site: Site) -> NSImage? {
        Self.key(for: site.url).flatMap { icons[$0] }
    }

    /// Plate color for a bare-glyph icon: dark behind a light glyph, white behind a dark one.
    func accentColor(for site: Site) -> NSColor? {
        Self.key(for: site.url).flatMap { accentColors[$0] }
    }

    func plateColor(for site: Site) -> NSColor? {
        guard let key = Self.key(for: site.url), let isLight = bareGlyphIsLight[key] else { return nil }
        return isLight ? NSColor(white: 0.12, alpha: 1) : .white
    }

    func load(for site: Site) {
        guard let host = site.url.host, let key = Self.key(for: site.url),
              icons[key] == nil, !attempted.contains(key) else { return }
        attempted.insert(key)
        if let cached = NSImage(contentsOf: cacheFile(for: key)), !Self.isBlank(cached) {
            store(cached, key: key)
            return
        }
        let base = URL(string: "https://\(host)")!
        fetchFirst([base.appendingPathComponent("apple-touch-icon.png"),
                    base.appendingPathComponent("favicon.ico")], key: key, replace: false)
    }

    /// Icons the site's loaded page declared, best first. For a site at a host's root, only used
    /// to replace a missing icon, or one too small to fill a start page tile sharply.
    func offer(_ urls: [URL], for site: Site) {
        guard let key = Self.key(for: site.url) else { return }
        let replace = key.contains("/") && !declared.contains(key)
        if !replace, let current = icons[key], Self.pixelWidth(current) >= 128 { return }
        fetchFirst(urls, key: key, replace: replace)
    }

    private func fetchFirst(_ urls: [URL], key: String, replace: Bool) {
        guard let url = urls.first else { return }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            let ok = http.map { (200..<300).contains($0.statusCode) } ?? false
            // NSImage will happily "render" an HTML bot-check page, so insist on an image type.
            let mime = http?.mimeType ?? ""
            let isImage = mime.hasPrefix("image/") || mime == "application/octet-stream"
            DispatchQueue.main.async {
                guard let self else { return }
                if ok, isImage, let data, let image = NSImage(data: data), Self.pixelWidth(image) > 0, !Self.isBlank(image) {
                    self.accept(image, key: key, replace: replace)
                } else {
                    self.fetchFirst(Array(urls.dropFirst()), key: key, replace: replace)
                }
            }
        }.resume()
    }

    private func accept(_ image: NSImage, key: String, replace: Bool) {
        if replace {
            declared.insert(key)
        } else if let current = icons[key], Self.pixelWidth(current) >= Self.pixelWidth(image) {
            return
        }
        store(image, key: key)
        // Cache as PNG whatever the source format (ico, svg, ...).
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: cacheFile(for: key))
        }
    }

    private func store(_ image: NSImage, key: String) {
        icons[key] = image
        bareGlyphIsLight[key] = Self.bareGlyphLightness(image)
        accentColors[key] = Self.coverage(of: image)?.accent
    }

    private func cacheFile(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    private struct Coverage {
        var clearFraction: Double
        var opaqueFraction: Double
        var meanLuminance: CGFloat
        /// Share of the opaque pixels that are strongly colored.
        var colorfulFraction: Double
        /// Average of the saturated pixels; nil for a monochrome icon.
        var accent: NSColor?
    }

    /// Samples the image at 32×32: how much of it is transparent, and how light the rest is.
    private static func coverage(of image: NSImage) -> Coverage? {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var clear = 0
        var opaque = 0
        var luminance: CGFloat = 0
        var saturated = 0
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent < 0.1 {
                    clear += 1
                } else {
                    opaque += 1
                    luminance += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    if let hsb = color.usingColorSpace(.sRGB), hsb.saturationComponent > 0.35, hsb.brightnessComponent > 0.25 {
                        saturated += 1
                        red += hsb.redComponent
                        green += hsb.greenComponent
                        blue += hsb.blueComponent
                    }
                }
            }
        }
        let total = Double(side * side)
        let accent = saturated >= 12
            ? NSColor(srgbRed: red / CGFloat(saturated), green: green / CGFloat(saturated),
                      blue: blue / CGFloat(saturated), alpha: 1)
            : nil
        return Coverage(clearFraction: Double(clear) / total,
                        opaqueFraction: Double(opaque) / total,
                        meanLuminance: opaque > 0 ? luminance / CGFloat(opaque) : 0,
                        colorfulFraction: opaque > 0 ? Double(saturated) / Double(opaque) : 0,
                        accent: accent)
    }

    /// Some SVG icons (e.g. ones styled by CSS media queries) render to nothing at all.
    private static func isBlank(_ image: NSImage) -> Bool {
        (coverage(of: image)?.opaqueFraction ?? 0) < 0.02
    }

    /// nil for a full-bleed or rounded app icon; for a glyph floating on transparency,
    /// whether the glyph itself is light. A mostly colorful glyph (Google's, say) counts as dark,
    /// so it sits on white the way its brand shows it.
    private static func bareGlyphLightness(_ image: NSImage) -> Bool? {
        guard let coverage = coverage(of: image), coverage.clearFraction > 0.3 else { return nil }
        return coverage.colorfulFraction < 0.25 && coverage.meanLuminance > 0.5
    }

    private static func pixelWidth(_ image: NSImage) -> Int {
        let widest = image.representations.map(\.pixelsWide).max() ?? 0
        return widest > 0 ? widest : Int(image.size.width)
    }
}
