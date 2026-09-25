import AppKit

/// The panel's size, which the user sets by dragging its edges.
enum PanelSize {
    static let standard = NSSize(width: 600, height: 720)
    static let minimum = NSSize(width: 460, height: 480)
    private static let storageKey = "panelSize"

    static var saved: NSSize {
        get {
            guard let string = UserDefaults.standard.string(forKey: storageKey) else { return standard }
            let size = NSSizeFromString(string)
            return size.width >= minimum.width && size.height >= minimum.height ? size : standard
        }
        set {
            UserDefaults.standard.set(NSStringFromSize(newValue), forKey: storageKey)
        }
    }
}

/// A borderless, transparent window that drops down from the menu bar icon.
/// Replaces NSPopover so the panel can have no arrow and larger corners; the
/// shadow follows the glass view's rounded alpha.
final class GlassPanel: NSPanel {
    var onDismiss: (() -> Void)?

    init(contentViewController: NSViewController) {
        let size = PanelSize.saved
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.contentViewController = contentViewController
        setContentSize(size)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let contentView {
            ResizeHandle.install(in: contentView)
        }
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

/// An invisible strip along the panel's edge that resizes it. The top stays under the menu bar,
/// and the sides move together so the panel stays centered under its icon.
private final class ResizeHandle: NSView {
    private enum Edge { case left, right, bottom, bottomLeft, bottomRight }

    private let edge: Edge
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    private init(edge: Edge, frame: NSRect) {
        self.edge = edge
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func install(in view: NSView) {
        let bounds = view.bounds
        let thickness: CGFloat = 6
        let corner: CGFloat = 22
        // The corners are rounded and clicks on their transparent pixels fall through, so the
        // corner handles sit a little inside, where the glass is.
        let handles: [(Edge, NSRect, NSView.AutoresizingMask)] = [
            (.left, NSRect(x: 0, y: corner, width: thickness, height: bounds.height - corner - 30),
             [.height, .maxXMargin]),
            (.right, NSRect(x: bounds.width - thickness, y: corner, width: thickness, height: bounds.height - corner - 30),
             [.height, .minXMargin]),
            (.bottom, NSRect(x: corner, y: 0, width: bounds.width - corner * 2, height: thickness),
             [.width, .maxYMargin]),
            (.bottomLeft, NSRect(x: 3, y: 3, width: corner, height: corner),
             [.maxXMargin, .maxYMargin]),
            (.bottomRight, NSRect(x: bounds.width - corner - 3, y: 3, width: corner, height: corner),
             [.minXMargin, .maxYMargin]),
        ]
        for (edge, frame, mask) in handles {
            let handle = ResizeHandle(edge: edge, frame: frame)
            handle.autoresizingMask = mask
            view.addSubview(handle)
        }
    }

    private var movesSides: Bool { edge != .bottom }
    private var movesBottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(edge) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    private var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edge {
            case .left: .left
            case .right: .right
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return edge == .bottom ? .resizeUpDown : .resizeLeftRight
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? startFrame
        var frame = startFrame

        if movesSides {
            let direction: CGFloat = [.left, .bottomLeft].contains(edge) ? -1 : 1
            let delta = (mouse.x - startMouse.x) * direction
            let width = min(max(startFrame.width + delta * 2, PanelSize.minimum.width), visible.width - 16)
            frame.size.width = width
            frame.origin.x = min(max(startFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        }
        if movesBottom {
            let height = min(max(startFrame.height + (startMouse.y - mouse.y), PanelSize.minimum.height),
                             startFrame.maxY - visible.minY - 8)
            frame.size.height = height
            frame.origin.y = startFrame.maxY - height
        }
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        PanelSize.saved = window.frame.size
        window.invalidateShadow()
    }
}
