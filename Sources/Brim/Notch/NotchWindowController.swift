import AppKit
import SwiftUI

/// What the SwiftUI shell can ask its window controller to do.
@MainActor
protocol NotchActions: AnyObject {
    func tapped()
    func togglePin()
    func select(moduleID: String)
}

/// Owns the notch panel on one screen and drives its state machine:
/// closed → peek → open (optionally pinned), with activity derived from ActivityCenter.
@MainActor
final class NotchWindowController: NotchActions {
    let model: NotchViewModel
    private let panel: NotchPanel
    private var isHovering = false
    /// After Esc or an outside click, don't reopen until the pointer leaves.
    private var suppressHover = false
    /// Opened because a file was dragged towards the notch.
    private var openedForDrag = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false
    private var keyObserver: NSObjectProtocol?
    /// Stepped aside because a full-screen app fills this display.
    private(set) var isHiddenForFullScreen = false

    var screenFrame: NSRect { model.geometry.screenFrame }
    var hasHardwareNotch: Bool { model.geometry.hasHardwareNotch }

    init(screen: NSScreen) {
        let geometry = NotchGeometry(screen: screen)
        model = NotchViewModel(geometry: geometry)
        panel = NotchPanel(frame: geometry.panelFrame)

        let host = NotchHostingView(rootView: ShellView(model: model, actions: self))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()

        // Clicking into a text field makes the panel key: keep it open while typing.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .open else { return }
                self.model.isPinned = true
            }
        }
    }

    func tearDown() {
        openTask?.cancel()
        closeTask?.cancel()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        panel.orderOut(nil)
        // The hosted ShellView holds this controller; drop it to break the cycle.
        panel.contentView = nil
        panel.close()
    }

    func setHiddenForFullScreen(_ hidden: Bool) {
        guard hidden != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = hidden
        if hidden {
            close()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Pointer

    func pointerMoved(to location: NSPoint) {
        guard !isHiddenForFullScreen else { return }
        let inside = hotRect.contains(location)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        guard inside != isHovering else { return }
        isHovering = inside
        if inside {
            hoverBegan()
        } else {
            suppressHover = false
            hoverEnded()
        }
    }

    func pointerPressed(at location: NSPoint) {
        guard model.phase == .open, !hotRect.contains(location) else { return }
        close()
    }

    /// A file drag from another app is moving; open the shelf when it nears the notch.
    func fileDragMoved(to location: NSPoint) {
        guard !isHiddenForFullScreen, model.phase != .open, isInDragZone(location) else { return }
        openedForDrag = true
        model.selectedModuleID = "shelf"
        setPhase(.open)
        panel.ignoresMouseEvents = false
    }

    func fileDragEnded() {
        guard openedForDrag else { return }
        openedForDrag = false
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            // Leave time to see the file land.
            try? await Task.sleep(for: .milliseconds(1400))
            guard let self, !Task.isCancelled, !self.model.isPinned,
                  !self.hotRect.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
    }

    /// Near enough to the notch that a dragged file should open the shelf.
    func isInDragZone(_ location: NSPoint) -> Bool {
        model.geometry.screenRect(
            bodySize: CGSize(width: model.closedSize.width + 220, height: model.closedSize.height + 110),
            shoulder: 0
        ).contains(location)
    }

    /// The area that counts as "on the notch". The closed notch gets a little
    /// extra room so it's easy to hit at the very top of the screen.
    private var hotRect: NSRect {
        var rect = model.screenRect
        if model.phase != .open {
            rect = rect.insetBy(dx: -10, dy: 0)
            rect.origin.y -= 6
            rect.size.height += 7
        }
        return rect
    }

    private func hoverBegan() {
        closeTask?.cancel()
        guard model.phase == .closed, !suppressHover else { return }
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: AppSettings.hoverDelay)
            guard let self, !Task.isCancelled, self.isHovering else { return }
            self.setPhase(.peek)
            guard AppSettings.openBehavior == .hover else { return }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, self.isHovering, self.model.phase == .peek else { return }
            self.setPhase(.open)
        }
    }

    private func hoverEnded() {
        openTask?.cancel()
        guard model.phase != .closed, !model.isPinned, !openedForDrag else { return }
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.isHovering, !self.model.isPinned else { return }
            self.close()
        }
    }

    // MARK: - State

    /// `focus` makes the panel key, so ⌘1–9 and typing work straight away.
    func open(pinned: Bool, focus: Bool = true) {
        closeTask?.cancel()
        if pinned {
            model.isPinned = true
            if focus {
                panel.makeKey()
            }
        }
        setPhase(.open)
        panel.ignoresMouseEvents = !hotRect.contains(NSEvent.mouseLocation)
    }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        openedForDrag = false
        model.isPinned = false
        suppressHover = isHovering
        setPhase(.closed)
        if panel.isKeyWindow {
            // Give keyboard focus back to the app that was in front.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = !hotRect.contains(NSEvent.mouseLocation)
    }

    private func setPhase(_ phase: NotchPhase) {
        guard model.phase != phase else { return }
        let animation: Animation = switch phase {
        case .open: Motion.open
        case .peek: Motion.peek
        case .closed: Motion.close
        }
        withAnimation(animation) { model.phase = phase }
        switch phase {
        case .open: Haptics.open()
        case .peek: Haptics.tick()
        case .closed: break
        }
    }

    // MARK: - NotchActions

    func tapped() {
        switch model.phase {
        case .closed, .peek:
            open(pinned: true)
        case .open where !model.isPinned:
            model.isPinned = true
            panel.makeKey()
        case .open:
            break
        }
    }

    func togglePin() {
        model.isPinned.toggle()
        if model.isPinned {
            panel.makeKey()
        } else if !isHovering {
            close()
        }
    }

    func select(moduleID: String) {
        guard moduleID != model.selectedModuleID else { return }
        let modules = ModuleRegistry.visibleNow
        let from = modules.firstIndex { $0.id == model.selectedModuleID } ?? 0
        let to = modules.firstIndex { $0.id == moduleID } ?? 0
        model.switchEdge = to >= from ? .trailing : .leading
        withAnimation(Motion.switchModule) { model.selectedModuleID = moduleID }
        Haptics.tick()
    }

    // MARK: - Keyboard and trackpad

    /// ⌘1–9 picks a module, Esc closes. Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, model.phase == .open else { return false }
        if event.keyCode == 53 {
            close()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number) {
            let modules = ModuleRegistry.visibleNow
            if number <= modules.count {
                select(moduleID: modules[number - 1].id)
            }
            return true
        }
        return false
    }

    /// A two-finger horizontal swipe moves one module per gesture.
    func handleScroll(_ event: NSEvent) {
        guard event.window === panel, model.phase == .open,
              event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began:
            swipeDistance = 0
            swipeHandled = false
        case .changed:
            guard !swipeHandled, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return }
            swipeDistance += event.scrollingDeltaX
            if abs(swipeDistance) > 44 {
                swipeHandled = true
                step(swipeDistance < 0 ? 1 : -1)
            }
        default:
            break
        }
    }

    private func step(_ offset: Int) {
        let modules = ModuleRegistry.visibleNow
        let index = modules.firstIndex { $0.id == model.selectedModuleID } ?? 0
        let next = index + offset
        guard modules.indices.contains(next) else { return }
        select(moduleID: modules[next].id)
    }
}
