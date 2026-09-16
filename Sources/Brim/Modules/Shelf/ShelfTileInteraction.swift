import AppKit
import SwiftUI

/// Mouse handling for a shelf tile, in AppKit so one drag can mean two things:
/// pulling a file up (towards the top of the screen, where nothing else can
/// take it) flicks it off the shelf; pulling it any other way drags the file out.
/// Also handles double-click to open, Option-click to remove, and the menu.
struct ShelfTileInteraction: NSViewRepresentable {
    let item: ShelfItem
    let onHover: (Bool) -> Void
    /// Offset while flicking, in SwiftUI coordinates (y down).
    let onFlick: (CGSize) -> Void
    /// True when the flick was far or fast enough to remove the item.
    let onFlickEnded: (Bool) -> Void

    func makeNSView(context: Context) -> ShelfTileView {
        ShelfTileView()
    }

    func updateNSView(_ view: ShelfTileView, context: Context) {
        view.item = item
        view.onHover = onHover
        view.onFlick = onFlick
        view.onFlickEnded = onFlickEnded
    }
}

final class ShelfTileView: NSView, NSDraggingSource {
    var item: ShelfItem?
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
    private var shelf: ShelfService { .shared }

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
        guard let item else { return }
        if event.modifierFlags.contains(.option) {
            shelf.remove(item)
            return
        }
        if event.clickCount == 2 {
            shelf.open(item)
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
        guard let item, let url = shelf.url(for: item) else { return }
        let image = shelf.thumbnails[item.id] ?? NSWorkspace.shared.icon(forFile: url.path)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let side: CGFloat = 64
        let frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        dragItem.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Other apps get a copy; the shelf keeps its item. Dropping back on the notch does nothing.
        context == .outsideApplication ? .copy : []
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.shelf.open(item) })
        menu.addItem(ClosureMenuItem("Show in Finder") { [weak self] in self?.shelf.reveal(item) })
        if shelf.canAirDrop {
            menu.addItem(ClosureMenuItem("AirDrop…") { [weak self] in self?.shelf.airDrop([item]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Shelf") { [weak self] in self?.shelf.remove(item) })
        return menu
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
