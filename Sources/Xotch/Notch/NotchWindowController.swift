import AppKit
import SwiftUI

/// What the SwiftUI shell can ask its window controller to do.
@MainActor
protocol NotchActions: AnyObject {
    var isPinned: Bool { get }
    func tapped()
    func togglePin()
    func select(moduleID: String)
    func closeNotch()
    func togglePalette()
    func closePalette()
    func run(_ command: PaletteCommand)
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
    private var edgeHapticPlayed = false
    /// Scrolled to change the volume during this hover, so don't open by hovering.
    private var adjustedVolumeThisHover = false
    private var keyObserver: NSObjectProtocol?
    /// Stepped aside because a full-screen app fills this display.
    private(set) var isHiddenForFullScreen = false
    /// Shown over a full-screen app by a shortcut; steps aside again on close.
    private var revealedOverFullScreen = false

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
        updateSharing()
        panel.orderFrontRegardless()

        // Pressing a button in a module counts as meaning to stay: without this
        // the notch closes as soon as the pointer drifts off, and whatever was
        // being filled in — a new arc, a note — goes with it.
        panel.onClickInside = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .open else { return }
                self.closeTask?.cancel()
                if !self.model.isPinned {
                    self.model.isPinned = true
                    #if DEBUG
                    NotchPanel.debugPins += 1
                    #endif
                }
            }
        }

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
        // Opened over a full-screen app on purpose: leave it until it closes.
        if hidden, revealedOverFullScreen, model.phase == .open { return }
        guard hidden != isHiddenForFullScreen else { return }
        isHiddenForFullScreen = hidden
        if hidden {
            close()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// For a shortcut used while a full-screen app has hidden the notch.
    func revealOverFullScreen() {
        guard isHiddenForFullScreen else { return }
        isHiddenForFullScreen = false
        revealedOverFullScreen = true
        panel.orderFrontRegardless()
    }

    /// Keeps the notch out of screen sharing and recordings when asked to.
    func updateSharing() {
        let sharing: NSWindow.SharingType = AppSettings.hideFromScreenSharing ? .none : .readOnly
        if panel.sharingType != sharing {
            panel.sharingType = sharing
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
            adjustedVolumeThisHover = false
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
        // So the drop ripple is ready by the time the file lands.
        ShaderKit.shared.prepare()
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
            guard !Task.isCancelled, self.isHovering, self.model.phase == .peek,
                  !self.adjustedVolumeThisHover else { return }
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
        model.palette.isOpen = false
        model.isPinned = false
        suppressHover = isHovering
        setPhase(.closed)
        if panel.isKeyWindow {
            // Give keyboard focus back to the app that was in front.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = !hotRect.contains(NSEvent.mouseLocation)
        if revealedOverFullScreen {
            revealedOverFullScreen = false
            ScreenManager.shared.recheckFullScreen()
        }
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
        case .open:
            Haptics.open()
            RetroSound.play(.open)
        case .peek: Haptics.tick()
        case .closed: RetroSound.play(.close)
        }
    }

    // MARK: - NotchActions

    var isPinned: Bool { model.isPinned }

    func closeNotch() {
        close()
    }

    func tapped() {
        switch model.phase {
        case .closed, .peek:
            if isOnRecordingEar(NSEvent.mouseLocation) {
                CaptureService.shared.stopRecording()
                return
            }
            if model.activities.companion == .mascot, isOnLeftEar(NSEvent.mouseLocation) {
                // Boop the mascot; don't open on the way.
                openTask?.cancel()
                suppressHover = true
                MascotTracker.shared.boop(model.earMascotAnchor)
                return
            }
            if isOnRightEar(NSEvent.mouseLocation), model.activities.isRotating {
                // Next live activity; don't open on the way.
                openTask?.cancel()
                suppressHover = true
                model.activities.showNext()
                return
            }
            open(pinned: true)
        case .open where !model.isPinned:
            model.isPinned = true
            panel.makeKey()
        case .open:
            break
        }
    }

    /// A click beside the camera while a recording's time shows there stops it.
    private func isOnRecordingEar(_ location: NSPoint) -> Bool {
        let activities = model.activities
        guard model.showsActivity, CaptureService.shared.isRecording,
              let current = activities.current, current.id == activities.ongoing["capture"]?.id else { return false }
        // With Adiyogi in the left ear, only the right ear is the recording's.
        let offset = location.x - model.screenRect.midX
        return activities.showsCompanion ? offset > model.closedSize.width / 2 : abs(offset) > model.closedSize.width / 2
    }

    /// Left of the camera housing, where the ear companion sits.
    private func isOnLeftEar(_ location: NSPoint) -> Bool {
        model.showsActivity && model.screenRect.midX - location.x > model.closedSize.width / 2
    }

    /// Right of the camera housing, on the ear that shows an activity.
    private func isOnRightEar(_ location: NSPoint) -> Bool {
        model.showsActivity && location.x - model.screenRect.midX > model.closedSize.width / 2
    }

    func togglePin() {
        model.isPinned.toggle()
        RetroSound.play(.pin)
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
        RetroSound.play(.switchModule)
    }

    // MARK: - Keyboard and trackpad

    /// ⌘K opens the command palette, ⌘1–9 picks a module, Esc closes.
    /// Returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, model.phase == .open else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
            togglePalette()
            return true
        }
        if model.palette.isOpen {
            switch event.keyCode {
            case 53:
                closePalette()
                return true
            case 125:
                model.palette.move(by: 1, count: CommandCatalog.commands(for: model.palette.query, actions: self).count)
                return true
            case 126:
                model.palette.move(by: -1, count: CommandCatalog.commands(for: model.palette.query, actions: self).count)
                return true
            case 36, 76:
                runPaletteSelection()
                return true
            default:
                break
            }
        }
        if event.keyCode == 53 {
            close()
            return true
        }
        if flags == .command,
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

    /// On the open notch, a two-finger horizontal swipe moves one module per
    /// gesture, and stretches at the first and last module. On the closed notch,
    /// scrolling changes the volume.
    func handleScroll(_ event: NSEvent) {
        guard event.window === panel else { return }
        guard model.phase == .open else {
            adjustVolume(with: event)
            return
        }
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began:
            swipeDistance = 0
            swipeHandled = false
            edgeHapticPlayed = false
        case .changed:
            guard !swipeHandled, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return }
            swipeDistance += event.scrollingDeltaX
            let offset = swipeDistance < 0 ? 1 : -1
            if canStep(offset) {
                if abs(swipeDistance) > 44 {
                    swipeHandled = true
                    step(offset)
                }
            } else {
                model.rubberBand = Self.rubberBand(for: swipeDistance)
                if abs(swipeDistance) > 44, !edgeHapticPlayed {
                    edgeHapticPlayed = true
                    Haptics.tick()
                }
            }
        case .ended, .cancelled:
            if model.rubberBand != 0 {
                withAnimation(.spring(duration: 0.45, bounce: 0.4)) { model.rubberBand = 0 }
            }
        default:
            break
        }
    }

    /// Follows the fingers at first, then resists more and more (at most 56 points).
    nonisolated static func rubberBand(for distance: CGFloat) -> CGFloat {
        let limit: CGFloat = 56
        let stretched = limit * (1 - 1 / (abs(distance) / 110 + 1))
        return distance < 0 ? -stretched : stretched
    }

    private func canStep(_ offset: Int) -> Bool {
        let modules = ModuleRegistry.visibleNow
        let index = modules.firstIndex { $0.id == model.selectedModuleID } ?? 0
        return modules.indices.contains(index + offset)
    }

    private func step(_ offset: Int) {
        let modules = ModuleRegistry.visibleNow
        let index = modules.firstIndex { $0.id == model.selectedModuleID } ?? 0
        let next = index + offset
        guard modules.indices.contains(next) else { return }
        select(moduleID: modules[next].id)
    }

    // MARK: - Volume

    private func adjustVolume(with event: NSEvent) {
        guard AppSettings.scrollForVolume, !isHiddenForFullScreen,
              hotRect.contains(NSEvent.mouseLocation), event.momentumPhase.isEmpty else { return }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        // Adjusting the volume shouldn't open the notch.
        openTask?.cancel()
        adjustedVolumeThisHover = true
        guard let current = SystemVolume.volume, SystemVolume.canSetVolume else {
            ActivityCenter.shared.showHUD(LiveActivity(moduleID: "volume", symbol: "speaker.slash",
                                                       content: .text("Fixed"), tint: Theme.ink, earWidth: 90))
            return
        }
        let change = event.hasPreciseScrollingDeltas ? Double(delta) * 0.005 : (delta > 0 ? 1 : -1) / 16
        let next = min(max(current + change, 0), 1)
        if next != current {
            SystemVolume.setVolume(next)
            if next == 0 || next == 1 {
                Haptics.tick()
            }
        }
        ActivityCenter.shared.showHUD(LiveActivity(
            moduleID: "volume",
            symbol: SystemVolume.symbol(for: next, muted: SystemVolume.isMuted),
            content: .level(next), tint: Theme.ink, earWidth: 96
        ))
    }

    // MARK: - Command palette

    func togglePalette() {
        model.palette.isOpen ? closePalette() : openPalette()
    }

    /// `focus` makes the panel key so you can type; the debug tools skip it.
    func openPalette(focus: Bool = true) {
        if model.phase != .open {
            open(pinned: true, focus: focus)
        }
        model.isPinned = true
        if focus {
            panel.makeKey()
        }
        model.palette.query = ""
        model.palette.selection = 0
        withAnimation(Motion.switchModule) { model.palette.isOpen = true }
        Haptics.tick()
    }

    func closePalette() {
        withAnimation(Motion.switchModule) { model.palette.isOpen = false }
    }

    func runPaletteSelection() {
        let commands = CommandCatalog.commands(for: model.palette.query, actions: self)
        guard commands.indices.contains(model.palette.selection) else { return }
        run(commands[model.palette.selection])
    }

    func run(_ command: PaletteCommand) {
        closePalette()
        command.run()
    }

    #if DEBUG
    /// Clicks a control that tagged itself with `.debugFrame(_:)`, so a test
    /// doesn't carry coordinates that go stale the next time the layout moves.
    @discardableResult
    func debugClick(named name: String) -> String {
        guard let frame = DebugFrames.frame(name) else { return "\(name): never laid out" }
        guard let content = panel.contentView else { return "\(name): no content view" }
        let point = CGPoint(x: frame.midX, y: content.bounds.height - frame.midY)
        debugClick(at: point)
        return String(format: "%@: global %.0f,%.0f in %.0fx%.0f → window %.0f,%.0f",
                      name, frame.midX, frame.midY, content.bounds.width, content.bounds.height,
                      point.x, point.y)
    }

    /// Clicks the notch from inside the app: the event never leaves the
    /// process, so this needs no Accessibility permission and nothing moves
    /// the pointer on screen.
    func debugClick(at point: CGPoint) {
        let time = ProcessInfo.processInfo.systemUptime
        // The mouse-up goes in the queue and the mouse-down is handed straight
        // to the window, in that order, which sounds backwards and isn't:
        //
        // - A text view's `mouseDown` sits in `nextEventMatchingMask` until the
        //   mouse comes back up, and only reads the queue. Give it the up
        //   through `sendEvent` and it waits there for ever, eating keystrokes.
        // - Posting the down instead goes through the window server, which maps
        //   the location through the window's own geometry and lands the click
        //   somewhere else entirely.
        //
        // So: queue the up first, then send the down. Whatever the down starts
        // finds the up already waiting, and the coordinates stay exact.
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        // The queued up is only there to end a tracking loop; the sent one is
        // what finishes the click. A button needs its up at the same point as
        // its down or it reads the press as dragged off and does nothing.
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { panel.sendEvent(down) }
        if let up = event(.leftMouseUp) { panel.sendEvent(up) }
    }

    /// Types into the notch from inside the app, to test whether the panel's
    /// text fields actually receive the keyboard.
    func debugType(_ text: String) {
        let time = ProcessInfo.processInfo.systemUptime
        for character in text {
            // A newline stands for Return, so a self-test can submit a field.
            let isReturn = character == "\n"
            let string = isReturn ? "\r" : String(character)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: time, windowNumber: panel.windowNumber,
                                                   context: nil, characters: string,
                                                   charactersIgnoringModifiers: string,
                                                   isARepeat: false, keyCode: isReturn ? 36 : 0) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Whoever is taking the keyboard in the notch right now.
    var debugResponder: String {
        let responder = panel.firstResponder
        return responder.map { String(describing: type(of: $0)) } ?? "none"
    }

    /// What AppKit finds at points down the open notch, to tell "AppKit is
    /// swallowing the click" apart from "SwiftUI isn't listening".
    func debugProbe() -> [String] {
        guard let content = panel.contentView else { return ["no content view"] }
        let body = model.bodySize
        let left = (panel.frame.width - body.width) / 2
        var lines = ["probe: panel \(Int(panel.frame.width))x\(Int(panel.frame.height)) body \(Int(body.width))x\(Int(body.height)) phase=\(model.phase) module=\(model.selectedModuleID)"]
        for fromTop in stride(from: 10, through: Int(body.height), by: 30) {
            let y = panel.frame.height - CGFloat(fromTop)
            let columns = [left + body.width * 0.25, left + body.width * 0.5, left + body.width * 0.92]
            let found = columns.map { x -> String in
                let view = content.hitTest(NSPoint(x: x, y: y))
                return view.map { String(describing: type(of: $0)) } ?? "nil"
            }
            lines.append("  \(fromTop)pt from top: \(found.joined(separator: " | "))")
        }
        return lines
    }

    var debugBehaviour: String {
        var names: [String] = []
        let behaviour = panel.collectionBehavior
        let flags: [(NSWindow.CollectionBehavior, String)] = [
            (.canJoinAllSpaces, "canJoinAllSpaces"), (.stationary, "stationary"),
            (.fullScreenAuxiliary, "fullScreenAuxiliary"), (.ignoresCycle, "ignoresCycle"),
            (.auxiliary, "auxiliary"), (.canJoinAllApplications, "canJoinAllApplications"),
            (.moveToActiveSpace, "moveToActiveSpace"), (.transient, "transient"),
            (.participatesInCycle, "participatesInCycle"), (.primary, "primary"),
        ]
        for (flag, name) in flags where behaviour.contains(flag) {
            names.append(name)
        }
        return "responder=\(debugResponder) clicks=\(NotchPanel.debugClicks)@\(NotchPanel.debugLastClick) pins=\(NotchPanel.debugPins) content=\(panel.contentView.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) bounds \(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-") backing=\(panel.backingScaleFactor) named=\(NotchPanel.debugNamedClick) key=\(panel.isKeyWindow) visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) pinned=\(model.isPinned) mouse=\(panel.ignoresMouseEvents ? "ignored" : "taken") level=\(panel.level.rawValue) alpha=\(panel.alphaValue) behaviour=[\(names.joined(separator: ","))] raw=\(behaviour.rawValue)"
    }

    var debugFrames: String {
        String(format: "panel %.0fx%.0f@%.0f,%.0f screen %.0fx%.0f@%.0f,%.0f notch %.0fx%.0f",
               panel.frame.width, panel.frame.height, panel.frame.minX, panel.frame.minY,
               screenFrame.width, screenFrame.height, screenFrame.minX, screenFrame.minY,
               model.closedSize.width, model.closedSize.height)
    }
    #endif
}
