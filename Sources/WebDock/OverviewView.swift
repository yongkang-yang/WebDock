import AppKit
import SwiftUI

/// A page in the overview, with the last picture taken of it.
struct OverviewPage: Identifiable {
    let site: Site
    var snapshot: NSImage?
    /// Resident memory of the page's main WebKit content process (not page-exclusive memory).
    var memoryBytes: UInt64?
    var sharedProcess = false

    var id: UUID { site.id }
}

/// One showing of the overview: its pages, oldest first, and the page on screen when it opened.
struct OverviewSession: Identifiable {
    let id = UUID()
    var pages: [OverviewPage]
    var currentID: UUID?
}

/// Every recent page as a card, like the iPhone's app switcher: newer pages lie over older ones,
/// and the older ones bunch up to the left. The page on screen shrinks into its card on opening,
/// and the card picked grows back into the page. Scroll or drag sideways to move through the
/// pages, drag a card up to close its page.
struct OverviewView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let session = model.overview {
            OverviewCarousel(model: model, session: session)
                .id(session.id)
        }
    }
}

/// Where each card goes for a scroll position.
private struct CarouselLayout {
    let size: CGSize

    var cardSize: CGSize {
        let width = size.width * 0.56
        return CGSize(width: width, height: width * size.height / max(size.width, 1))
    }

    /// How far apart cards to the right of the focused one sit: half a card, so they overlap by half.
    var step: CGFloat { cardSize.width * 0.5 }

    /// Cards to the left close up on each other the further back they are.
    func offset(_ distance: CGFloat) -> CGFloat {
        if distance >= 0 { return distance * step }
        let falloff: CGFloat = 0.55
        return -step * 0.75 * (1 - pow(falloff, -distance)) / (1 - falloff)
    }

    func scale(_ distance: CGFloat) -> CGFloat {
        distance >= 0 ? 1 : 1 - 0.045 * min(-distance, 3)
    }

    /// `distance` is the card's index minus the scroll position; 0 is the focused card.
    func rect(_ distance: CGFloat) -> CGRect {
        let scale = scale(distance)
        let width = cardSize.width * scale
        let height = cardSize.height * scale
        let centerX = size.width * 0.56 + offset(distance)
        let centerY = size.height / 2 + 12
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
}

/// The scroll position, in cards, and the event monitors that move it.
private final class CarouselScroll: ObservableObject {
    @Published var position: CGFloat = 0
    var count = 0
    var step: CGFloat = 1
    weak var window: NSWindow?
    private var monitor: Any?
    private var snapWork: DispatchWorkItem?

    private var maxPosition: CGFloat { CGFloat(max(count - 1, 0)) }

    /// Scroll events move the cards; `onKey` gets key presses and says whether it used them;
    /// a trackpad pinch out calls `onPinchOut`, as it opens the tab picked in Safari's overview.
    func start(onKey: @escaping (NSEvent) -> Bool, onPinchOut: @escaping () -> Void) {
        stop()
        var pinch: CGFloat = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .scrollWheel:
                self.scroll(event)
            case .magnify:
                if event.phase == .began { pinch = 0 }
                pinch += event.magnification
                if pinch > 0.25 {
                    pinch = -.infinity  // once per pinch
                    onPinchOut()
                }
            default:
                return onKey(event) ? nil : event
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cancelSnap()
    }

    private func scroll(_ event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var delta = abs(dx) > abs(dy) ? dx : dy
        if !event.hasPreciseScrollingDeltas { delta *= 10 }  // a mouse wheel's lines
        guard delta != 0 else { return }
        move(by: -delta / step)
        cancelSnap()
        let work = DispatchWorkItem { [weak self] in self?.snap() }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Past either end, the cards give only a little, like a rubber band.
    func move(by amount: CGFloat) {
        var amount = amount
        if (position < 0 && amount < 0) || (position > maxPosition && amount > 0) {
            amount *= 0.25
        }
        position += amount
    }

    func cancelSnap() {
        snapWork?.cancel()
        snapWork = nil
    }

    /// Settles on the nearest card, or on `target`.
    func snap(to target: CGFloat? = nil) {
        let settled = min(max((target ?? position).rounded(), 0), maxPosition)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { position = settled }
    }
}

private struct OverviewCarousel: View {
    @ObservedObject var model: PanelModel
    let session: OverviewSession
    @ObservedObject private var favicons = FaviconStore.shared
    @StateObject private var scroll = CarouselScroll()
    /// False while the page on screen is still full size, before it shrinks into its card.
    @State private var isLaidOut = false
    /// Set once a card is picked (it grows back into the page), or the overview is leaving.
    @State private var isClosing = false
    @State private var chosenID: UUID?
    @State private var hoveredID: UUID?
    /// A card being dragged up, and how far.
    @State private var lift: (id: UUID, amount: CGFloat)?
    @State private var flungIDs: Set<UUID> = []
    @State private var dragAxis: Axis?
    @State private var dragStart: CGFloat?

    private var pages: [OverviewPage] { session.pages }

    var body: some View {
        GeometryReader { proxy in
            let layout = CarouselLayout(size: proxy.size)
            ZStack(alignment: .topLeading) {
                background(size: proxy.size)
                    .gesture(sidewaysDrag(layout))
                    .onTapGesture(perform: dismiss)
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    title(page, index: index, layout: layout)
                    card(page, index: index, layout: layout)
                    processMemory(page, index: index, layout: layout)
                }
                if pages.isEmpty {
                    Text("No Recent Pages")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { scroll.step = layout.step }
            .onChange(of: proxy.size) { scroll.step = CarouselLayout(size: $0).step }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .background(WindowReader { scroll.window = $0 })
        .onAppear(perform: appear)
        .onDisappear { scroll.stop() }
        .onChange(of: pages.count) { scroll.count = $0 }
    }

    // MARK: Pieces

    /// The page on screen, blurred and dimmed, like the wallpaper behind the iPhone's switcher.
    private func background(size: CGSize) -> some View {
        ZStack {
            if let snapshot = pages.first(where: { $0.id == session.currentID })?.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 36)
                    .scaleEffect(1.15)
            } else {
                Color(nsColor: model.pageColor ?? .windowBackgroundColor)
            }
            Color.black.opacity(0.28)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .opacity(isLaidOut && !isClosing ? 1 : 0)
    }

    private func distance(_ index: Int) -> CGFloat { CGFloat(index) - scroll.position }

    private func isExpanded(_ page: OverviewPage) -> Bool {
        (!isLaidOut && page.id == session.currentID) || (isClosing && page.id == chosenID)
    }

    private func rect(_ page: OverviewPage, index: Int, layout: CarouselLayout) -> CGRect {
        if isExpanded(page) { return CGRect(origin: .zero, size: layout.size) }
        var rect = layout.rect(distance(index))
        if !isLaidOut {
            rect.origin.x -= layout.size.width * 0.35  // the others slide in from the left
        }
        if flungIDs.contains(page.id) {
            rect.origin.y = -rect.height - 60
        } else if let lift, lift.id == page.id {
            // Up follows the pointer; down only gives a little.
            rect.origin.y += lift.amount < 0 ? lift.amount : lift.amount * 0.15
        }
        return rect
    }

    /// Cards far back in the stack fade out, as does everything but the picked card when leaving.
    private func opacity(_ page: OverviewPage, index: Int) -> Double {
        if isClosing { return page.id == chosenID ? 1 : chosenID == nil ? 0 : 1 }
        if !isLaidOut && page.id != session.currentID { return 0 }
        let back = -distance(index)
        return back > 3 ? Double(max(0, 4 - back)) : 1
    }

    private func card(_ page: OverviewPage, index: Int, layout: CarouselLayout) -> some View {
        let rect = rect(page, index: index, layout: layout)
        let expanded = isExpanded(page)
        let shape = RoundedRectangle(cornerRadius: expanded ? Metrics.cardRadius : 20, style: .continuous)
        let back = max(0, -distance(index))
        return ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let snapshot = page.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: rect.width, height: rect.height, alignment: .top)
            } else {
                SiteGlyph(site: page.site, icon: favicons.icon(for: page.site),
                          plateColor: favicons.plateColor(for: page.site), size: 56, cornerRadius: 16)
            }
            // Cards further back are a little darker, for depth.
            Color.black.opacity(expanded ? 0 : min(0.3, Double(back) * 0.1))
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .contentShape(shape)
        .shadow(color: .black.opacity(expanded ? 0 : 0.3), radius: 16, x: -3, y: 4)
        .onHover { inside in
            if inside { hoveredID = page.id } else if hoveredID == page.id { hoveredID = nil }
        }
        .gesture(cardDrag(page, rect: rect, layout: layout))
        .onAppear { favicons.load(for: page.site) }
        // Placed rather than offset: an offset moves the drawing, but clicks went on landing
        // where the card would sit unmoved, so only its lower part took them. Hover and the
        // gesture go on before, so they cover the card and not the whole overview.
        .position(x: rect.midX, y: rect.midY)
        .opacity(opacity(page, index: index))
        .zIndex(isClosing && page.id == chosenID ? 1000 : Double(index * 2 + 1))
    }

    /// The icon and name above a card, cut short where the next card's begins; hovering the card
    /// swaps in a close button.
    private func title(_ page: OverviewPage, index: Int, layout: CarouselLayout) -> some View {
        let rect = rect(page, index: index, layout: layout)
        let next = index + 1 < pages.count ? layout.rect(distance(index + 1)).minX : .infinity
        let width = max(0, min(rect.width, next - rect.minX - 8))
        let hovered = hoveredID == page.id && isLaidOut && !isClosing
        return HStack(spacing: 6) {
            if hovered {
                Button {
                    fling(page.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.25)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close Page")
                .transition(.scale.combined(with: .opacity))
            }
            SiteGlyph(site: page.site, icon: favicons.icon(for: page.site),
                      plateColor: favicons.plateColor(for: page.site), size: 18, cornerRadius: 5)
            Text(page.site.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .frame(width: width, height: 22, alignment: .leading)
        .clipped()
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { inside in
            if inside { hoveredID = page.id } else if hoveredID == page.id { hoveredID = nil }
        }
        .position(x: rect.minX + width / 2, y: rect.minY - 17)
        .opacity(expandedOrHidden(page) ? 0 : opacity(page, index: index))
        .zIndex(Double(index * 2 + 1))
    }

    /// Put the process reading beneath its page, as on a phone's recent-apps screen.
    /// One WebKit process can be shared by several pages: this is NOT per-tab usage.
    private func processMemory(_ page: OverviewPage, index: Int, layout: CarouselLayout) -> some View {
        let rect = rect(page, index: index, layout: layout)
        let caption: String = if let bytes = page.memoryBytes {
            "Process " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
                + (page.sharedProcess ? " · shared" : "")
        } else {
            "Process memory unavailable"
        }
        return Text(caption)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.35)))
            .position(x: rect.midX, y: rect.maxY + 16)
            .opacity(expandedOrHidden(page) ? 0 : opacity(page, index: index))
            .zIndex(Double(index * 2 + 1))
            .allowsHitTesting(false)
    }

    private func expandedOrHidden(_ page: OverviewPage) -> Bool {
        !isLaidOut || isClosing || flungIDs.contains(page.id) || lift?.id == page.id
    }

    // MARK: Gestures

    /// A click opens the card's page; a drag sideways moves through the cards, and up closes the
    /// page. One gesture for all three, so a click never waits on, or loses to, a drag.
    private func cardDrag(_ page: OverviewPage, rect: CGRect, layout: CarouselLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isClosing, hypot(value.translation.width, value.translation.height) > 5 || dragAxis != nil
                else { return }
                if dragAxis == nil {
                    let upward = value.translation.height < 0
                        && abs(value.translation.height) > abs(value.translation.width)
                    dragAxis = upward ? .vertical : .horizontal
                }
                if dragAxis == .vertical {
                    lift = (page.id, value.translation.height)
                } else {
                    dragSideways(value, layout: layout)
                }
            }
            .onEnded { value in
                defer { dragAxis = nil }
                if dragAxis == nil {
                    open(page.id)
                    return
                }
                guard dragAxis == .vertical else {
                    endSideways(value, layout: layout)
                    return
                }
                let far = value.translation.height < -rect.height * 0.3
                let quick = value.predictedEndTranslation.height < -rect.height * 0.8
                if far || quick {
                    fling(page.id)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lift = nil }
                }
            }
    }

    private func sidewaysDrag(_ layout: CarouselLayout) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { dragSideways($0, layout: layout) }
            .onEnded { endSideways($0, layout: layout) }
    }

    private func dragSideways(_ value: DragGesture.Value, layout: CarouselLayout) {
        guard !isClosing else { return }
        if dragStart == nil {
            dragStart = scroll.position
            scroll.cancelSnap()
        }
        let target = (dragStart ?? 0) - value.translation.width / layout.step
        scroll.move(by: target - scroll.position)
    }

    /// A flick carries on to where it was headed.
    private func endSideways(_ value: DragGesture.Value, layout: CarouselLayout) {
        guard let start = dragStart else { return }
        dragStart = nil
        scroll.snap(to: start - value.predictedEndTranslation.width / layout.step)
    }

    // MARK: Actions

    private func appear() {
        scroll.count = pages.count
        let current = pages.firstIndex { $0.id == session.currentID } ?? pages.count - 1
        scroll.position = CGFloat(max(current, 0))
        scroll.start(onKey: handleKey) {
            let focused = Int(scroll.position.rounded())
            if pages.indices.contains(focused) { open(pages[focused].id) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.84)) { isLaidOut = true }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let focused = Int(scroll.position.rounded())
        switch event.keyCode {
        case 53:  // Esc
            dismiss()
        case 123:  // ←
            scroll.snap(to: scroll.position - 1)
        case 124:  // →
            scroll.snap(to: scroll.position + 1)
        case 36, 76, 49:  // Return, Enter, Space
            if pages.indices.contains(focused) { open(pages[focused].id) }
        case 51, 117:  // Delete
            if pages.indices.contains(focused) { fling(pages[focused].id) }
        default:
            return event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        }
        return true
    }

    /// The card grows back into the page, which then takes its place.
    private func open(_ id: UUID) {
        guard !isClosing, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        chosenID = id
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            scroll.position = CGFloat(index)
            isClosing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { model.onCloseOverview(id) }
    }

    /// Back to the page that was on screen, or, from the start page, a fade.
    private func dismiss() {
        guard !isClosing else { return }
        if let current = session.currentID, pages.contains(where: { $0.id == current }) {
            open(current)
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { isClosing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.onCloseOverview(nil) }
    }

    /// The card flies off the top, its page closes, and the rest close the gap.
    private func fling(_ id: UUID) {
        guard !isClosing, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        hoveredID = nil
        withAnimation(.easeIn(duration: 0.2)) {
            flungIDs.insert(id)
            lift = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var position = scroll.position.rounded()
            if CGFloat(index) < position { position -= 1 }
            position = min(position, CGFloat(max(pages.count - 2, 0)))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                scroll.position = position
                model.onCloseOverviewPage(id)
            }
            flungIDs.remove(id)
        }
    }
}

/// Hands over the window the view is in, for telling our events from other windows'.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
