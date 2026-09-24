import AppKit

/// A borderless, transparent window that drops down from the menu bar icon.
/// Replaces NSPopover so the panel can have no arrow and larger corners; the
/// shadow follows the glass view's rounded alpha.
final class GlassPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init(contentViewController: NSViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: Metrics.panelSize),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.contentViewController = contentViewController
        setContentSize(Metrics.panelSize)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc that the web page didn't handle.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// Cmd+W; a borderless window has no close button to perform.
    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}
