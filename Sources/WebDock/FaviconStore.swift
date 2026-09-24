import AppKit

/// Site icons for the rail. Tries the site's well-known icon paths up front, and
/// upgrades to whatever the page itself declares once it has loaded. Icons are
/// cached on disk per host, so they only download once.
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var icons: [String: NSImage] = [:]
    /// Hosts whose icon is a bare glyph on transparency, mapped to whether that glyph is light.
    /// Such icons get a contrasting plate so they don't vanish into the chrome.
    @Published private(set) var bareGlyphIsLight: [String: Bool] = [:]
    /// Each icon's most colorful tone, for tinting the start page tiles.
    @Published private(set) var accentColors: [String: NSColor] = [:]
    private var attempted: Set<String> = []
    private let cacheDirectory: URL
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("com.johanyang.WebDock/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func icon(for site: Site) -> NSImage? {
        site.url.host.flatMap { icons[$0] }
    }

    /// Plate color for a bare-glyph icon: dark behind a light glyph, white behind a dark one.
    func accentColor(for site: Site) -> NSColor? {
        site.url.host.flatMap { accentColors[$0] }
    }

    func plateColor(for site: Site) -> NSColor? {
        guard let host = site.url.host, let isLight = bareGlyphIsLight[host] else { return nil }
        return isLight ? NSColor(white: 0.12, alpha: 1) : .white
    }

    func load(for site: Site) {
        guard let host = site.url.host, icons[host] == nil, !attempted.contains(host) else { return }
        attempted.insert(host)
        if let cached = NSImage(contentsOf: cacheFile(for: host)), !Self.isBlank(cached) {
            store(cached, host: host)
            return
        }
        let base = URL(string: "https://\(host)")!
        fetchFirst([base.appendingPathComponent("apple-touch-icon.png"),
                    base.appendingPathComponent("favicon.ico")], host: host)
    }

    /// Icons the loaded page declared, best first. Only used to replace a missing or tiny icon.
    func offer(_ urls: [URL], host: String) {
        if let current = icons[host], Self.pixelWidth(current) >= 64 { return }
        fetchFirst(urls, host: host)
    }

    private func fetchFirst(_ urls: [URL], host: String) {
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
                    self.accept(image, host: host)
                } else {
                    self.fetchFirst(Array(urls.dropFirst()), host: host)
                }
            }
        }.resume()
    }

    private func accept(_ image: NSImage, host: String) {
        if let current = icons[host], Self.pixelWidth(current) >= Self.pixelWidth(image) {
            return
        }
        store(image, host: host)
        // Cache as PNG whatever the source format (ico, svg, ...).
        if let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: cacheFile(for: host))
        }
    }

    private func store(_ image: NSImage, host: String) {
        icons[host] = image
        bareGlyphIsLight[host] = Self.bareGlyphLightness(image)
        accentColors[host] = Self.coverage(of: image)?.accent
    }

    private func cacheFile(for host: String) -> URL {
        cacheDirectory.appendingPathComponent(host + ".png")
    }

    private struct Coverage {
        var clearFraction: Double
        var opaqueFraction: Double
        var meanLuminance: CGFloat
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
                        accent: accent)
    }

    /// Some SVG icons (e.g. ones styled by CSS media queries) render to nothing at all.
    private static func isBlank(_ image: NSImage) -> Bool {
        (coverage(of: image)?.opaqueFraction ?? 0) < 0.02
    }

    /// nil for a full-bleed or rounded app icon; for a glyph floating on transparency,
    /// whether the glyph itself is light.
    private static func bareGlyphLightness(_ image: NSImage) -> Bool? {
        guard let coverage = coverage(of: image), coverage.clearFraction > 0.3 else { return nil }
        return coverage.meanLuminance > 0.5
    }

    private static func pixelWidth(_ image: NSImage) -> Int {
        let widest = image.representations.map(\.pixelsWide).max() ?? 0
        return widest > 0 ? widest : Int(image.size.width)
    }
}
