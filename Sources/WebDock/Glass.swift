import AppKit
import SwiftUI

/// Inner corners are concentric with the panel's: each radius is the outer one
/// minus the padding between them, so the curves run parallel.
enum Metrics {
    static let panelRadius: CGFloat = 28
    static let panelPadding: CGFloat = 12
    static let cardRadius: CGFloat = panelRadius - panelPadding
    static let gap: CGFloat = 10
    static let railWidth: CGFloat = 44
    static let railIcon: CGFloat = 36
    static let railIconRadius: CGFloat = 12
    static let headerHeight: CGFloat = 30
    static let iconButton: CGFloat = 28
}

extension View {
    /// Liquid Glass on macOS 26+, a quiet fill before that.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(GlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else {
            background(tint ?? Color.primary.opacity(0.07), in: shape)
        }
    }
}

@available(macOS 26, *)
private enum GlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

/// Lets neighbouring glass shapes blend into each other instead of stacking as separate panes.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A round glass button holding one symbol.
struct GlassIconButton: View {
    let symbol: String
    let help: String
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .opacity(dimmed ? 0.35 : 1)
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .contentShape(Circle())
                .glassSurface(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The panel's backdrop: a Liquid Glass slab with large continuous corners.
func makeGlassBackground(size: NSSize) -> (root: NSView, content: NSView) {
    let content = NSView()
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = Metrics.panelRadius
        glass.contentView = content
        // Something in the panel leaves a faint fill in the corners outside the glass, and the
        // window shadow, traced from alpha, then came out square. Clipping keeps them clear.
        let clip = NSView(frame: NSRect(origin: .zero, size: size))
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Metrics.panelRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        glass.frame = clip.bounds
        glass.autoresizingMask = [.width, .height]
        clip.addSubview(glass)
        return (clip, content)
    }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = Metrics.panelRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: effect.topAnchor),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
    ])
    return (effect, content)
}
