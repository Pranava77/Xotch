import AppKit

/// Drag to choose an area of the screen to record. Covers every display with
/// a dimmed layer; Esc cancels.
@MainActor
enum RegionPicker {
    struct Selection {
        let display: CGDirectDisplayID
        /// In points from the display's top-left corner, as ScreenCaptureKit wants.
        let rect: CGRect
        /// The same area in screen coordinates.
        let frame: NSRect
    }

    private static var panels: [RegionPanel] = []
    private static var completion: ((Selection?) -> Void)?
    private static let smallest: CGFloat = 16

    static var isPicking: Bool { !panels.isEmpty }

    static func pick(_ completion: @escaping (Selection?) -> Void) {
        finish(nil)
        self.completion = completion
        let pointer = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = RegionPanel(screen: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
            if NSMouseInRect(pointer, screen.frame, false) {
                panel.makeKey()
            }
        }
        NSApp.activate()
        NSCursor.crosshair.set()
    }

    static func finish(_ selection: Selection?) {
        let panels = panels
        self.panels = []
        panels.forEach { $0.orderOut(nil) }
        NSCursor.arrow.set()
        let completion = completion
        self.completion = nil
        completion?(selection)
    }

    /// The part of `rect` (view coordinates, origin bottom-left) worth recording.
    static func selection(for rect: NSRect, on screen: NSScreen) -> Selection? {
        let clipped = rect.intersection(NSRect(origin: .zero, size: screen.frame.size)).integral
        guard clipped.width >= smallest, clipped.height >= smallest, let display = screen.displayID else { return nil }
        let flipped = CGRect(x: clipped.minX, y: screen.frame.height - clipped.maxY,
                             width: clipped.width, height: clipped.height)
        let frame = clipped.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        return Selection(display: display, rect: flipped, frame: frame)
    }
}

private final class RegionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = RegionView(screen: screen)
        contentView = view
        initialFirstResponder = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class RegionView: NSView {
    private let screen: NSScreen
    private var start: NSPoint?
    private var current: NSPoint?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let rect = selection, let chosen = RegionPicker.selection(for: rect, on: screen) else {
            // A click, not a drag: keep picking.
            start = nil
            current = nil
            needsDisplay = true
            return
        }
        RegionPicker.finish(chosen)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            RegionPicker.finish(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        RegionPicker.finish(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        guard let rect = selection, rect.width > 0, rect.height > 0 else {
            drawHint("Drag to choose an area to record. Press Esc to cancel.", at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let below = rect.minY > 34
        drawHint(label, at: NSPoint(x: rect.midX, y: below ? rect.minY - 18 : rect.maxY + 18))
    }

    private func drawHint(_ text: String, at center: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = NSRect(x: center.x - size.width / 2 - 10, y: center.y - size.height / 2 - 5,
                          width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: NSPoint(x: pill.minX + 10, y: pill.minY + 5))
    }
}

/// A thin frame around an area while it's being recorded. Brim's windows are
/// left out of recordings, so it never shows up in the video.
@MainActor
enum RecordingFrame {
    private static var panel: NSPanel?
    private static let margin: CGFloat = 3

    static func show(around area: NSRect) {
        hide()
        let frame = area.insetBy(dx: -margin, dy: -margin)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let border = CAShapeLayer()
        border.path = CGPath(rect: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        view.layer?.addSublayer(border)
        panel.contentView = view
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
