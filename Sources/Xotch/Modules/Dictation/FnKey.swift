import AppKit
import Carbon.HIToolbox

/// The Fn (🌐) key for dictation:
/// - hold it and talk; let go and the words are inserted;
/// - double-tap it to keep listening hands-free; press it again to finish;
/// - a quick tap does nothing, and Fn with another key (Fn+→, Fn+F1) or Esc
///   cancels.
///
/// It watches with passive event monitors rather than a tap, so nothing you
/// type ever waits on Xotch. Seeing keys in other apps needs Accessibility,
/// which dictation needs anyway to paste.
@MainActor
final class FnKey {
    static let shared = FnKey()

    private var monitors: [Any] = []
    private var waitTask: Task<Void, Never>?
    /// Fn is down and this press started listening.
    private var holding = false
    private var pressedAt = Date.distantPast
    private var lastQuickTap = Date.distantPast
    /// The press that started or ended hands-free; its release is ignored.
    private var ignoreRelease = false

    /// Shorter than this, a press is a tap, not talking.
    private static let tapLength: TimeInterval = 0.3
    /// Two taps closer than this lock listening on.
    private static let doubleTapGap: TimeInterval = 0.4

    /// Called at launch and whenever a setting changes.
    func settingsChanged() {
        guard AppSettings.dictationEnabled, WhistleEngine.isSupported else {
            remove()
            return
        }
        if AXIsProcessTrusted() {
            install()
        } else {
            remove()
            waitForPermission()
        }
    }

    var isActive: Bool { !monitors.isEmpty }

    private func install() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { FnKey.shared.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { FnKey.shared.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func remove() {
        waitTask?.cancel()
        waitTask = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Accessibility can be granted while Xotch runs, and nothing tells us.
    private func waitForPermission() {
        guard waitTask == nil else { return }
        waitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    waitTask = nil
                    settingsChanged()
                    return
                }
            }
        }
    }

    private func handle(_ event: NSEvent) {
        let dictation = DictationService.shared
        if event.type == .keyDown {
            // Esc stops; any key with Fn held means Fn was a modifier, not talk.
            if dictation.isListening, event.keyCode == UInt16(kVK_Escape) || holding {
                holding = false
                ignoreRelease = true
                dictation.cancel()
            }
            return
        }
        guard event.keyCode == UInt16(kVK_Function) else { return }
        if event.modifierFlags.contains(.function) {
            pressed(at: Date())
        } else {
            released(at: Date())
        }
    }

    private func pressed(at now: Date) {
        let dictation = DictationService.shared
        if case .listening(handsFree: true) = dictation.phase {
            ignoreRelease = true
            dictation.finish()
            return
        }
        guard dictation.phase == .idle else { return }
        if now.timeIntervalSince(lastQuickTap) < Self.doubleTapGap {
            lastQuickTap = .distantPast
            ignoreRelease = true
            dictation.start(handsFree: true)
            return
        }
        holding = true
        pressedAt = now
        // Start at once, so the first word isn't lost while deciding.
        dictation.start()
    }

    private func released(at now: Date) {
        if ignoreRelease {
            ignoreRelease = false
            return
        }
        guard holding else { return }
        holding = false
        let dictation = DictationService.shared
        if now.timeIntervalSince(pressedAt) < Self.tapLength {
            lastQuickTap = now
            dictation.cancel()
        } else {
            dictation.finish()
        }
    }

    /// What the 🌐 key does on its own, from Keyboard settings. Anything but
    /// "Do Nothing" fights dictation: the emoji picker or macOS's own
    /// dictation opens as well.
    static var globeKeyConflict: String? {
        let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") ?? 0
        switch usage {
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return nil
        }
    }
}
