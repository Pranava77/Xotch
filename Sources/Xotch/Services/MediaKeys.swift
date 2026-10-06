import AppKit
import ApplicationServices

// Takes over the keyboard's volume, mute and brightness keys, so the notch shows
// the level instead of macOS's square popup.
//
// This is the one place Xotch needs Accessibility permission: only an event tap
// that can consume the key stops macOS also handling it and drawing its own
// popup. So the tap is opt-in, and it consumes a key only when Xotch can really
// do the job and show the result. Otherwise the key goes through to macOS.
// While Xotch isn't running there's no tap, so the keys work as normal.

enum MediaKey: Int, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// The pure parts, kept apart from the event tap so they can be tested.
enum MediaKeyLogic {
    /// What a system-defined event's `data1` says: which key, and pressed or released.
    /// Keyboard backlight and other keys give nil, and are never touched.
    static func decode(data1: Int) -> (key: MediaKey, isDown: Bool)? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        guard let key = MediaKey(rawValue: code) else { return nil }
        return (key, (flags & 0xFF00) >> 8 == 0xA)
    }

    /// One step up or down on macOS's 16-step scale, or 64 for fine steps
    /// (Shift+Option), snapped to the grid so repeated presses land on it.
    static func step(_ current: Double, up: Bool, fine: Bool) -> Double {
        let grid = fine ? 64.0 : 16.0
        let index = (current * grid).rounded() + (up ? 1 : -1)
        return min(max(index / grid, 0), 1)
    }

    enum Modifiers {
        case plain, fine, passThrough
    }

    /// Shift+Option is a fine step. Option alone opens Sound or Displays settings
    /// in macOS, and Command or Control mean something else, so those pass through.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
        let active = flags.intersection([.shift, .option, .command, .control])
        if active.isEmpty { return .plain }
        if active == [.shift, .option] { return .fine }
        return .passThrough
    }
}

@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var waitTask: Task<Void, Never>?

    static var isTrusted: Bool { AXIsProcessTrusted() }
    var isRunning: Bool { tap != nil }

    // MARK: - Turning it on and off

    /// Called at launch and whenever a setting changes.
    func settingsChanged() {
        guard AppSettings.mediaKeysHUD else {
            remove()
            return
        }
        if Self.isTrusted {
            waitTask?.cancel()
            waitTask = nil
            install()
        } else {
            waitForPermission()
        }
    }

    /// Shows macOS's own Accessibility prompt.
    static func requestPermission() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't let us read as a global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Permission can be granted while Xotch runs, and nothing tells us. Look
    /// every couple of seconds until it is, then stop looking.
    private func waitForPermission() {
        guard waitTask == nil else { return }
        waitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if Self.isTrusted, AppSettings.mediaKeysHUD {
                    waitTask = nil
                    install()
                    return
                }
                if !AppSettings.mediaKeysHUD {
                    waitTask = nil
                    return
                }
            }
        }
    }

    private func install() {
        guard tap == nil else { return }
        // NX_SYSDEFINED, the event that carries the media keys.
        let mask: CGEventMask = 1 << 14
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: mediaKeyCallback, userInfo: nil) else { return }
        let run = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), run, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = run
    }

    private func remove() {
        waitTask?.cancel()
        waitTask = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// macOS turns a tap off if it is too slow or on some input; turn it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: - Handling a key

    /// True when Xotch dealt with the key, so the event should be swallowed.
    func handle(_ key: MediaKey, isDown: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        let mode = MediaKeyLogic.modifiers(flags)
        guard mode != .passThrough, ScreenManager.shared.canShowHUD, canHandle(key) else { return false }
        // Releases are swallowed too, so macOS never sees half a key press.
        guard isDown else { return true }
        let fine = mode == .fine

        switch key {
        case .volumeUp, .volumeDown:
            let current = SystemVolume.volume ?? 0
            let next = MediaKeyLogic.step(current, up: key == .volumeUp, fine: fine)
            SystemVolume.setVolume(next)
            showVolume(next)
        case .mute:
            SystemVolume.setMuted(!SystemVolume.isMuted)
            showVolume(SystemVolume.volume ?? 0)
        case .brightnessUp, .brightnessDown:
            let current = Brightness.level ?? 0
            let next = MediaKeyLogic.step(current, up: key == .brightnessUp, fine: fine)
            Brightness.setLevel(next)
            showBrightness(next)
        }
        RetroSound.play(.tick)
        return true
    }

    /// Only a key Xotch can really carry out is taken from macOS: a volume key
    /// on an output with no software volume, or a brightness key with no
    /// built-in display to read, is left alone.
    private func canHandle(_ key: MediaKey) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute: SystemVolume.canSetVolume
        case .brightnessUp, .brightnessDown: Brightness.isAvailable
        }
    }

    func showVolume(_ value: Double) {
        ActivityCenter.shared.showHUD(LiveActivity(
            moduleID: "volume", symbol: SystemVolume.symbol(for: value, muted: SystemVolume.isMuted),
            content: .level(SystemVolume.isMuted ? 0 : value), tint: Theme.ink))
    }

    func showBrightness(_ value: Double) {
        ActivityCenter.shared.showHUD(LiveActivity(
            moduleID: "brightness", symbol: Brightness.symbol(for: value),
            content: .level(value), tint: Theme.ink))
    }
}

/// The C callback for the event tap. It runs on the main run loop, so it may
/// touch main-actor state directly.
private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeys.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard let system = NSEvent(cgEvent: event), system.type == .systemDefined, system.subtype.rawValue == 8,
          let decoded = MediaKeyLogic.decode(data1: system.data1) else {
        return Unmanaged.passUnretained(event)
    }
    let flags = system.modifierFlags
    let consumed = MainActor.assumeIsolated {
        MediaKeys.shared.handle(decoded.key, isDown: decoded.isDown, flags: flags)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
