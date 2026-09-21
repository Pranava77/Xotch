import AppKit
import SwiftUI

/// What a file tile can do. The Shelf and Capture modules each supply their own.
struct FileTileHandlers {
    var url: @MainActor () -> URL?
    var thumbnail: @MainActor () -> NSImage?
    var open: @MainActor () -> Void
    var reveal: @MainActor () -> Void
    /// Option-click, the × button and a flick.
    var remove: @MainActor () -> Void
    var removeTitle: String
    var menu: @MainActor () -> NSMenu
}

/// A file that can be dragged out, double-clicked to open, and flicked up
/// to remove. `content` draws the thumbnail and label.
struct FileTile<Content: View>: View {
    let name: String
    let handlers: FileTileHandlers
    var padding: CGFloat = 8
    @ViewBuilder var content: Content
    @State private var hovering = false
    @State private var flick = CGSize.zero
    @State private var thrown = false
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovering || flick != .zero ? Theme.fill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if !snapshotMode {
                    FileTileInteraction(handlers: handlers,
                                        onHover: { hovering = $0 },
                                        onFlick: { flick = $0 },
                                        onFlickEnded: flickEnded)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering, flick == .zero {
                    Button { handlers.remove() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 20))
                        .padding(2)
                        .help(handlers.removeTitle)
                }
            }
            .rotationEffect(.degrees(Double(flick.width) / 6))
            .offset(flick)
            .opacity(thrown ? 0 : 1 - 0.5 * min(1, Double(-flick.height) / 140))
            .help(name)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Drag to use the file. Double-click to open. Flick up to remove.")
            .accessibilityAction(named: "Open") { handlers.open() }
            .accessibilityAction(named: "Show in Finder") { handlers.reveal() }
            .accessibilityAction(named: handlers.removeTitle) { handlers.remove() }
    }

    private func flickEnded(_ remove: Bool) {
        guard remove, !Motion.reduceMotion else {
            if remove {
                handlers.remove()
            } else {
                withAnimation(.spring(duration: 0.35, bounce: 0.45)) { flick = .zero }
            }
            return
        }
        Haptics.tick()
        withAnimation(.easeIn(duration: 0.2)) {
            flick = CGSize(width: flick.width * 1.6, height: -230)
            thrown = true
        }
        let remove = handlers.remove
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            remove()
        }
    }
}

/// Mouse handling for a file tile, in AppKit so one drag can mean two things:
/// pulling a file up (towards the top of the screen, where nothing else can
/// take it) flicks it away; pulling it any other way drags the file out.
/// Also handles double-click to open, Option-click to remove, and the menu.
struct FileTileInteraction: NSViewRepresentable {
    let handlers: FileTileHandlers
    let onHover: (Bool) -> Void
    /// Offset while flicking, in SwiftUI coordinates (y down).
    let onFlick: (CGSize) -> Void
    /// True when the flick was far or fast enough to remove the item.
    let onFlickEnded: (Bool) -> Void

    func makeNSView(context: Context) -> FileTileView {
        FileTileView()
    }

    func updateNSView(_ view: FileTileView, context: Context) {
        view.handlers = handlers
        view.onHover = onHover
        view.onFlick = onFlick
        view.onFlickEnded = onFlickEnded
    }
}

final class FileTileView: NSView, NSDraggingSource {
    var handlers: FileTileHandlers?
    var onHover: (Bool) -> Void = { _ in }
    var onFlick: (CGSize) -> Void = { _ in }
    var onFlickEnded: (Bool) -> Void = { _ in }

    private enum Mode {
        case waiting, flicking, dragging
    }

    private var mode = Mode.waiting
    private var mouseDown: NSEvent?
    private var start = NSPoint.zero
    private var recent: [(time: TimeInterval, y: CGFloat)] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        guard let handlers else { return }
        if event.modifierFlags.contains(.option) {
            handlers.remove()
            return
        }
        if event.clickCount == 2 {
            handlers.open()
            return
        }
        mode = .waiting
        mouseDown = event
        start = event.locationInWindow
        recent = [(event.timestamp, start.y)]
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        let dx = point.x - start.x, dy = point.y - start.y
        switch mode {
        case .waiting:
            guard hypot(dx, dy) > 5 else { return }
            // Window coordinates point up: dy > 0 is towards the top of the screen.
            if dy > 0, dy > abs(dx) * 1.1 {
                mode = .flicking
                flick(to: event, dx: dx, dy: dy)
            } else {
                mode = .dragging
                beginFileDrag(with: mouseDown ?? event)
            }
        case .flicking:
            flick(to: event, dx: dx, dy: dy)
        case .dragging:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mode = .waiting
            mouseDown = nil
        }
        guard mode == .flicking else { return }
        let distance = event.locationInWindow.y - start.y
        var speed: CGFloat = 0
        if let first = recent.first, let last = recent.last, last.time > first.time {
            speed = (last.y - first.y) / CGFloat(last.time - first.time)
        }
        onFlickEnded(distance > 46 || speed > 480)
    }

    private func flick(to event: NSEvent, dx: CGFloat, dy: CGFloat) {
        recent.append((event.timestamp, event.locationInWindow.y))
        // Speed from the last tenth of a second.
        recent.removeAll { event.timestamp - $0.time > 0.1 }
        onFlick(CGSize(width: dx * 0.4, height: -max(dy, 0)))
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let handlers, let url = handlers.url() else { return }
        let image = handlers.thumbnail() ?? NSWorkspace.shared.icon(forFile: url.path)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let side: CGFloat = 64
        let frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        dragItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Other apps get a copy; the tile stays. Dropping back on the notch does nothing.
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        handlers?.menu()
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func runHandler() {
        handler()
    }
}
