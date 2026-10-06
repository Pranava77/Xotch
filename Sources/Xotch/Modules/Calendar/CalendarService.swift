import AppKit
import EventKit
import SwiftUI
import Observation

struct RGB: Equatable, Sendable {
    var red: Double, green: Double, blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    init(_ color: CGColor?) {
        let converted = color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        red = Double(converted?.redComponent ?? 0.6)
        green = Double(converted?.greenComponent ?? 0.6)
        blue = Double(converted?.blueComponent ?? 0.6)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct AgendaEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let calendarColor: RGB
    /// A Zoom, Meet, Teams or Webex link, if the event has one.
    let joinURL: URL?

    init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
         location: String?, calendarColor: RGB, joinURL: URL?) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.location = location
        self.calendarColor = calendarColor; self.joinURL = joinURL
    }

    init(_ event: EKEvent) {
        id = event.calendarItemIdentifier + "|" + String(event.startDate.timeIntervalSince1970)
        title = event.title ?? "Untitled"
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        location = event.location?.isEmpty == false ? event.location : nil
        calendarColor = RGB(event.calendar?.cgColor)
        joinURL = Self.meetingLink(in: [event.url?.absoluteString, event.location, event.notes])
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co"]

    private static func meetingLink(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, let host = url.host?.lowercased(),
                   meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }
}

struct AgendaReminder: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let due: Date?
    let listColor: RGB

    init(id: String, title: String, due: Date?, listColor: RGB) {
        self.id = id; self.title = title; self.due = due; self.listColor = listColor
    }

    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title ?? "Untitled"
        due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        listColor = RGB(reminder.calendar?.cgColor)
    }
}

enum AccessState: Equatable {
    case notAsked, granted, denied
}

/// The next seven days of events, and open reminders, from Calendar and Reminders.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    private(set) var eventAccess: AccessState
    private(set) var reminderAccess: AccessState
    private(set) var events: [AgendaEvent] = []
    private(set) var reminders: [AgendaReminder] = []
    /// Reminders ticked off in the last moment, shown checked before they leave.
    private(set) var justCompleted: Set<String> = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        eventAccess = Self.state(for: .event)
        reminderAccess = Self.state(for: .reminder)
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var needsAccess: Bool {
        eventAccess != .granted && reminderAccess != .granted
    }

    var nextEvent: AgendaEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.end > now }
    }

    private static func state(for type: EKEntityType) -> AccessState {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestAccess() {
        if eventAccess == .notAsked {
            store.requestFullAccessToEvents { @Sendable [weak self] granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.eventAccess = granted ? .granted : .denied
                        self?.refresh()
                        self?.requestRemindersIfNeeded()
                    }
                }
            }
        } else {
            requestRemindersIfNeeded()
        }
    }

    private func requestRemindersIfNeeded() {
        guard reminderAccess == .notAsked else { return }
        store.requestFullAccessToReminders { @Sendable [weak self] granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reminderAccess = granted ? .granted : .denied
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        eventAccess = Self.state(for: .event)
        reminderAccess = Self.state(for: .reminder)
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) else { return }

        if eventAccess == .granted {
            let predicate = store.predicateForEvents(withStart: startOfToday, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .filter { $0.endDate > now }
                .sorted { $0.startDate < $1.startDate }
                .prefix(40)
                .map(AgendaEvent.init)
        } else {
            events = []
        }

        if reminderAccess == .granted {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { @Sendable [weak self] found in
                let mapped = (found ?? []).map(AgendaReminder.init).sorted { lhs, rhs in
                    switch (lhs.due, rhs.due) {
                    case let (left?, right?): left < right
                    case (.some, nil): true
                    case (nil, .some): false
                    case (nil, nil): lhs.title < rhs.title
                    }
                }
                let limited = Array(mapped.prefix(30))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reminders = limited }
                }
            }
        } else {
            reminders = []
        }
    }

    func complete(_ reminder: AgendaReminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
        } catch {
            return
        }
        withAnimation(Motion.press) { _ = justCompleted.insert(reminder.id) }
        Haptics.tick()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(Motion.switchModule) {
                self?.reminders.removeAll { $0.id == reminder.id }
                _ = self?.justCompleted.remove(reminder.id)
            }
        }
    }

    // MARK: - For the AI

    /// Events between two dates, for any range, not just the week shown.
    func events(from start: Date, to end: Date) -> [AgendaEvent] {
        guard eventAccess == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(60)
            .map(AgendaEvent.init)
    }

    /// Adds an event to the default calendar and returns its identifier.
    func addEvent(title: String, start: Date, end: Date, allDay: Bool, location: String?) throws -> String {
        guard eventAccess == .granted else { throw CalendarError.noAccess }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        refresh()
        return event.eventIdentifier
    }

    func removeEvent(identifier: String) {
        guard let event = store.event(withIdentifier: identifier) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
        refresh()
    }

    enum CalendarError: LocalizedError {
        case noAccess
        var errorDescription: String? {
            "Xotch doesn't have access to Calendar. Open the Calendar module in the notch to allow it."
        }
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (eventAccess, reminderAccess, events, reminders)
        let start = Calendar.current.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            start.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
        }
        let blue = RGB(red: 0.3, green: 0.6, blue: 1), green = RGB(red: 0.3, green: 0.8, blue: 0.5)
        eventAccess = .granted
        reminderAccess = .granted
        events = [
            AgendaEvent(id: "1", title: "Design review", start: at(0, 23, 0), end: at(0, 23, 45), isAllDay: false,
                        location: "Zoom", calendarColor: blue, joinURL: URL(string: "https://zoom.us/j/1")),
            AgendaEvent(id: "2", title: "Gym", start: at(1, 7, 30), end: at(1, 8, 30), isAllDay: false,
                        location: nil, calendarColor: green, joinURL: nil),
            AgendaEvent(id: "3", title: "Ship Xotch beta", start: at(2, 0), end: at(3, 0), isAllDay: true,
                        location: nil, calendarColor: blue, joinURL: nil),
        ]
        reminders = [
            AgendaReminder(id: "a", title: "Renew domain", due: at(0, 18), listColor: RGB(red: 1, green: 0.6, blue: 0.1)),
            AgendaReminder(id: "b", title: "Reply to Sam", due: nil, listColor: blue),
        ]
        body()
        (eventAccess, reminderAccess, events, reminders) = saved
    }
    #endif
}
