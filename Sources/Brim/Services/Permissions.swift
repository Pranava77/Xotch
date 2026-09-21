import AppKit

/// Deep links into System Settings › Privacy & Security.
enum PrivacyPane: String {
    case calendars = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"
    case audioCapture = "Privacy_AudioCapture"
    case screenCapture = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"

    func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Shared "run this once a sampling view is on screen" gate, so several views
/// (Home and Stats, or two displays) share one loop that stops when none are visible.
@MainActor
final class VisibilityGate {
    private var subscribers = 0
    private var loop: Task<Void, Never>?
    private let interval: Duration
    private let tick: () -> Void

    init(interval: Duration, tick: @escaping () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    /// Call from a view's `.task`; returns when the view goes away.
    func whileVisible() async {
        subscribers += 1
        if subscribers == 1 {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick()
                    try? await Task.sleep(for: self.interval)
                }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        subscribers -= 1
        if subscribers == 0 {
            loop?.cancel()
            loop = nil
        }
    }
}
