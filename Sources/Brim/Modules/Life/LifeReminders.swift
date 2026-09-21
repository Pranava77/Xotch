import Foundation
import UserNotifications

/// Notifications for habits, milestones and the evening nudge. macOS is only
/// asked for permission when you first set a reminder, never at launch, and
/// every reminder can be kept from the notification itself.
@MainActor
final class LifeReminders {
    static let shared = LifeReminders()

    enum Permission: Equatable {
        case notAsked, allowed, denied
    }

    nonisolated static let category = "life.habit"
    nonisolated static let checkInAction = "life.checkIn"
    nonisolated static let skipAction = "life.skip"
    nonisolated private static let prefix = "life."

    private(set) var permission: Permission = .notAsked
    private var center: UNUserNotificationCenter? {
        // Notifications only work from the .app bundle, as in TimerService.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    private let delegate = ReminderDelegate()
    private var registered = false

    /// Everything Brim would schedule right now, for the self-test to read
    /// without touching the notification centre.
    struct Plan: Equatable {
        var identifier: String
        var weekday: Int?
        var hour: Int
        var minute: Int
        var title: String
    }

    // MARK: - Scheduling

    func refreshAll() {
        guard let center else { return }
        let plans = Self.plans(arcs: LifeService.shared.liveArcs,
                               eveningNudge: AppSettings.lifeEveningNudge ? AppSettings.lifeNudgeMinutes : nil)
        center.getNotificationSettings { @Sendable settings in
            // Read what's needed here; the settings object itself isn't Sendable.
            let status = settings.authorizationStatus
            let allowed = status == .authorized || status == .provisional
            let denied = status == .denied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permission = allowed ? .allowed : (denied ? .denied : .notAsked)
                    guard allowed else { return }
                    self.apply(plans)
                }
            }
        }
    }

    private func apply(_ plans: [Plan]) {
        guard let center else { return }
        registerCategory()
        // Stable identifiers, so rescheduling replaces rather than piles up.
        center.getPendingNotificationRequests { @Sendable requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            let wanted = Set(plans.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: stale.filter { !wanted.contains($0) })
        }
        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.identifier.hasPrefix("life.nudge") ? "Nothing committed today yet."
                : "Keeping this one going?"
            content.sound = .default
            if plan.identifier.hasPrefix("life.habit") {
                content.categoryIdentifier = Self.category
            }
            var components = DateComponents()
            components.hour = plan.hour
            components.minute = plan.minute
            components.weekday = plan.weekday
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger))
        }
    }

    private func registerCategory() {
        guard !registered, let center else { return }
        registered = true
        center.delegate = delegate
        let checkIn = UNNotificationAction(identifier: Self.checkInAction, title: "Check in", options: [])
        let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip today", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [checkIn, skip],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Works out every reminder from the arcs, without scheduling anything.
    /// `timesPerWeek` habits are reminded every day; the service stops asking
    /// once the week's count is met.
    nonisolated static func plans(arcs: [Arc], eveningNudge: Int?) -> [Plan] {
        var plans: [Plan] = []
        for arc in arcs {
            for habit in arc.habits {
                guard let minutes = habit.reminder else { continue }
                let hour = minutes / 60, minute = minutes % 60
                switch habit.cadence {
                case .daily, .timesPerWeek:
                    plans.append(Plan(identifier: "\(prefix)habit.\(habit.id.uuidString)",
                                      weekday: nil, hour: hour, minute: minute, title: habit.title))
                case .days(let weekdays):
                    for weekday in weekdays.sorted() {
                        plans.append(Plan(identifier: "\(prefix)habit.\(habit.id.uuidString).\(weekday)",
                                          weekday: weekday, hour: hour, minute: minute, title: habit.title))
                    }
                }
            }
            for milestone in arc.milestones {
                guard let due = milestone.due, !milestone.isDone, due > Date() else { continue }
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: due)
                guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
                plans.append(Plan(identifier: "\(prefix)milestone.\(milestone.id.uuidString)",
                                  weekday: nil, hour: 9, minute: 0,
                                  title: "\(milestone.title) — due today (\(year)-\(month)-\(day))"))
            }
        }
        if let eveningNudge {
            plans.append(Plan(identifier: "\(prefix)nudge", weekday: nil,
                              hour: eveningNudge / 60, minute: eveningNudge % 60, title: "Anything to commit today?"))
        }
        return plans
    }

    // MARK: - Permission

    /// Asked the first time someone sets a reminder time.
    func requestPermission() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { @Sendable allowed, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.permission = allowed ? .allowed : .denied
                    if allowed { self.refreshAll() }
                }
            }
        }
    }

    func cancelAll() {
        guard let center else { return }
        center.getPendingNotificationRequests { @Sendable requests in
            center.removePendingNotificationRequests(
                withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(Self.prefix) })
        }
    }

    /// Checks in on the habit a notification came from.
    fileprivate func handle(identifier: String, action: String) {
        guard action == Self.checkInAction,
              let habitID = UUID(uuidString: identifier.split(separator: ".").dropFirst(2).first.map(String.init) ?? "") else {
            return
        }
        let life = LifeService.shared
        for arc in life.liveArcs {
            if let habit = arc.habits.first(where: { $0.id == habitID }) {
                if !life.isKept(habit) {
                    life.toggleCheckIn(habit, in: arc)
                }
                return
            }
        }
    }

    private final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                didReceive response: UNNotificationResponse) async {
            let identifier = response.notification.request.identifier
            let action = response.actionIdentifier
            await MainActor.run {
                LifeReminders.shared.handle(identifier: identifier, action: action)
            }
        }
    }
}
