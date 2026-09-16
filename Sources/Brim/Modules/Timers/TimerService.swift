import AppKit
import SwiftUI
import UserNotifications
import Observation

enum TimerKind: String {
    case focus, shortBreak, longBreak, countdown

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short break"
        case .longBreak: "Long break"
        case .countdown: "Timer"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak, .longBreak: "cup.and.saucer.fill"
        case .countdown: "timer"
        }
    }

    var tint: Color {
        switch self {
        case .focus: Theme.accent
        case .shortBreak, .longBreak: Theme.positive
        case .countdown: Color(red: 0.4, green: 0.75, blue: 1)
        }
    }
}

/// Pomodoro, countdown and stopwatch. Times are stored as dates, so nothing
/// ticks in the background: SwiftUI redraws the numbers only while they're on screen.
@MainActor
@Observable
final class TimerService {
    static let shared = TimerService()

    static let focusMinutes = 25.0
    static let shortBreakMinutes = 5.0
    static let longBreakMinutes = 15.0

    // Countdown (focus, breaks, plain timer)
    private(set) var kind: TimerKind?
    private(set) var endDate: Date?
    private(set) var pausedRemaining: TimeInterval?
    private(set) var total: TimeInterval = 0
    private(set) var focusSessionsDone = 0
    /// What the Focus tab offers next.
    private(set) var nextPomodoro: TimerKind = .focus

    // Stopwatch
    private(set) var stopwatchStarted: Date?
    private(set) var stopwatchBanked: TimeInterval = 0
    private(set) var laps: [TimeInterval] = []

    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private let notifications = NotificationPresenter()

    var isActive: Bool { kind != nil }
    var isRunning: Bool { endDate != nil }
    var isStopwatchRunning: Bool { stopwatchStarted != nil }

    func remaining(at date: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return 0
    }

    func progress(at date: Date) -> Double {
        guard total > 0, isActive else { return 0 }
        return 1 - remaining(at: date) / total
    }

    func stopwatchElapsed(at date: Date) -> TimeInterval {
        stopwatchBanked + (stopwatchStarted.map { date.timeIntervalSince($0) } ?? 0)
    }

    // MARK: - Countdown

    func startPomodoro() {
        let minutes = switch nextPomodoro {
        case .focus: Self.focusMinutes
        case .shortBreak: Self.shortBreakMinutes
        default: Self.longBreakMinutes
        }
        start(nextPomodoro, seconds: minutes * 60)
    }

    func start(_ kind: TimerKind, seconds: TimeInterval) {
        notifications.requestPermissionIfNeeded()
        self.kind = kind
        total = seconds
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(seconds)
        scheduleFinish()
        updateActivity()
        Haptics.tick()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        finishTask?.cancel()
        updateActivity()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        scheduleFinish()
        updateActivity()
    }

    func reset() {
        finishTask?.cancel()
        kind = nil
        endDate = nil
        pausedRemaining = nil
        total = 0
        updateActivity()
    }

    func skipBreak() {
        reset()
        nextPomodoro = .focus
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        guard let endDate else { return }
        finishTask = Task { [weak self] in
            // ContinuousClock keeps counting while the Mac sleeps.
            try? await Task.sleep(for: .seconds(max(0, endDate.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard let finished = kind else { return }
        var message: String
        switch finished {
        case .focus:
            focusSessionsDone += 1
            nextPomodoro = focusSessionsDone % 4 == 0 ? .longBreak : .shortBreak
            message = "Focus session done. Time for a break."
        case .shortBreak, .longBreak:
            nextPomodoro = .focus
            message = "Break's over. Ready to focus?"
        case .countdown:
            message = "Your \(Format.clock(total)) timer is done."
        }
        reset()
        NSSound(named: "Glass")?.play()
        notifications.post(title: finished.title, body: message)
        ActivityCenter.shared.post(LiveActivity(moduleID: "timers", symbol: "bell.fill",
                                                content: .text("Done"), tint: finished.tint,
                                                duration: .seconds(6)))
    }

    // MARK: - Stopwatch

    func toggleStopwatch() {
        if let started = stopwatchStarted {
            stopwatchBanked += Date().timeIntervalSince(started)
            stopwatchStarted = nil
        } else {
            stopwatchStarted = Date()
        }
        updateActivity()
        Haptics.tick()
    }

    func lap() {
        guard isStopwatchRunning else { return }
        withAnimation(Motion.switchModule) {
            laps.insert(stopwatchElapsed(at: .now), at: 0)
        }
    }

    func resetStopwatch() {
        stopwatchStarted = nil
        stopwatchBanked = 0
        withAnimation(Motion.switchModule) { laps = [] }
        updateActivity()
    }

    // MARK: - Live activity

    private func updateActivity() {
        let center = ActivityCenter.shared
        if let kind {
            if let endDate {
                center.setOngoing(LiveActivity(moduleID: "timers", symbol: kind.symbol,
                                               content: .countdown(until: endDate), tint: kind.tint), for: "timers")
            } else {
                center.setOngoing(LiveActivity(moduleID: "timers", symbol: "pause.fill",
                                               content: .text(Format.clock(pausedRemaining ?? 0)), tint: kind.tint), for: "timers")
            }
        } else if let stopwatchStarted {
            center.setOngoing(LiveActivity(moduleID: "timers", symbol: "stopwatch.fill",
                                           content: .stopwatch(since: stopwatchStarted.addingTimeInterval(-stopwatchBanked)),
                                           tint: Color(red: 0.4, green: 0.75, blue: 1)), for: "timers")
        } else {
            center.setOngoing(nil, for: "timers")
        }
    }
}

/// Posts "timer done" notifications. Only works from the .app bundle.
@MainActor
final class NotificationPresenter {
    private var asked = false
    private let delegate = ForegroundDelegate()

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestPermissionIfNeeded() {
        guard !asked, let center else { return }
        asked = true
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    func post(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }
}
