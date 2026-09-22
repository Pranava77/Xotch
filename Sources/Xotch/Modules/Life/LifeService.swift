import AppKit
import Foundation
import Observation
import SwiftUI

// The things you're trying to do with your time: to-dos for today and the
// week, arcs you've committed to, and a square for every day that darkens
// with what you got done.

struct LifeTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// The day it's planned for, at midnight. Nil means someday.
    var day: Date?
    var done: Date?
    var arcID: UUID?
    var created = Date()

    var isDone: Bool { done != nil }
}

/// How often a habit is meant to happen.
enum Cadence: Codable, Equatable, Hashable {
    case daily
    case timesPerWeek(Int)
    /// Calendar weekday numbers: 1 is Sunday, 7 is Saturday.
    case days([Int])

    var label: String {
        switch self {
        case .daily: "Every day"
        case .timesPerWeek(let count): "\(count)× a week"
        case .days(let days): days.sorted().map { Cadence.shortNames[$0 - 1] }.joined(separator: " ")
        }
    }

    static let shortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Is this habit expected on this weekday? `timesPerWeek` isn't tied to
    /// particular days, so it's expected until the week's count is met.
    func expects(weekday: Int) -> Bool {
        switch self {
        case .daily: true
        case .timesPerWeek: true
        case .days(let days): days.contains(weekday)
        }
    }
}

struct Habit: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var cadence: Cadence = .daily
    /// Minutes after midnight for a reminder, or nil for none.
    var reminder: Int?
}

struct Milestone: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var due: Date?
    var done: Date?

    var isDone: Bool { done != nil }
}

/// A season of your life you've committed to.
struct Arc: Codable, Identifiable, Equatable {
    /// Stands in for a draft that has just been cleared. One shared value, so
    /// the view's identity doesn't churn during that last update.
    static let placeholder = Arc(name: "", colour: RGBA(hex: 0xFF9F0A))

    var id = UUID()
    var name: String
    var colour: RGBA
    /// One line: what this arc is for.
    var intent: String?
    var start = Date()
    var end: Date?
    var habits: [Habit] = []
    var milestones: [Milestone] = []
    var archived = false
}

/// One habit kept on one day.
struct CheckIn: Codable, Equatable, Identifiable {
    var day: Date
    var arcID: UUID
    var habitID: UUID

    var id: String { "\(habitID)-\(day.timeIntervalSince1970)" }
}

/// What a day is worth. Arc work counts for more than ticking off a task.
enum LifeScore {
    static let task = 1
    static let checkIn = 2
    static let milestone = 5
    /// GitHub-style shades: nothing, a little, a day's work, a good day, a big day.
    static let levels = [1, 3, 6, 10]

    static func level(of commits: Int) -> Int {
        guard commits > 0 else { return 0 }
        return 1 + levels.dropFirst().filter { commits >= $0 }.count
    }
}

struct ArcProgress {
    var milestonesDone: Int
    var milestonesTotal: Int
    var habitRate: Double
    var daysLeft: Int?

    var fraction: Double {
        milestonesTotal > 0 ? Double(milestonesDone) / Double(milestonesTotal) : habitRate
    }
}

private struct LifeFile: Codable {
    var tasks: [LifeTask] = []
    var arcs: [Arc] = []
    var checkIns: [CheckIn] = []
    var lastRollover: Date?
}

@MainActor
@Observable
final class LifeService {
    static let shared = LifeService()
    /// A year of squares, plus the current part-week.
    static let graphWeeks = 53

    /// The arc being designed. Kept here rather than in the view, so shutting
    /// the notch mid-edit doesn't throw away what's been typed.
    var draft: Arc?

    /// A non-optional binding onto `draft`, for the designer.
    ///
    /// `Binding($life.draft)` looks like the natural way to do this, but it
    /// force-unwraps: SwiftUI updates the designer's subtree once more after
    /// the draft is cleared, and that update traps and kills the app. Saving
    /// or cancelling an arc did exactly that. This one falls back to a
    /// placeholder for that last update, and refuses writes once the draft is
    /// gone so a stray one can't bring it back.
    var draftBinding: Binding<Arc> {
        Binding(get: { self.draft ?? Arc.placeholder },
                set: { if self.draft != nil { self.draft = $0 } })
    }
    private(set) var tasks: [LifeTask]
    private(set) var arcs: [Arc]
    private(set) var checkIns: [CheckIn]
    @ObservationIgnored private var lastRollover: Date?
    /// Commits per day, worked out once and kept until something changes.
    @ObservationIgnored private var scoreCache: [Date: Int]?
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private lazy var saver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(LifeFile(tasks: tasks, arcs: arcs, checkIns: checkIns, lastRollover: lastRollover), to: "life.json")
    }

    init() {
        let file = Storage.load(LifeFile.self, from: "life.json") ?? LifeFile()
        tasks = file.tasks
        arcs = file.arcs
        checkIns = file.checkIns
        lastRollover = file.lastRollover
    }

    // MARK: - Days

    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = AppSettings.weekStartsMonday ? 2 : 1
        return calendar
    }

    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static var today: Date { day(Date()) }

    func start() {
        rolloverIfNeeded()
        LifeReminders.shared.refreshAll()
        scheduleMidnight()
    }

    func stop() {
        midnightTask?.cancel()
        midnightTask = nil
    }

    /// At midnight, yesterday's leftovers move to today and reminders are redone.
    private func scheduleMidnight() {
        midnightTask?.cancel()
        let calendar = Self.calendar
        guard let midnight = calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5),
                                               matchingPolicy: .nextTime) else { return }
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(60, midnight.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            rolloverIfNeeded()
            LifeReminders.shared.refreshAll()
            scheduleMidnight()
        }
    }

    /// Unfinished tasks from before today move to today, once a day.
    func rolloverIfNeeded() {
        let today = Self.today
        guard AppSettings.lifeRollover, lastRollover.map({ $0 < today }) ?? true else { return }
        lastRollover = today
        var moved = 0
        for index in tasks.indices where !tasks[index].isDone {
            if let day = tasks[index].day, day < today {
                tasks[index].day = today
                moved += 1
            }
        }
        invalidate()
        saver.schedule()
        guard moved > 0 else { return }
        ActivityCenter.shared.post(LiveActivity(moduleID: "life", symbol: "arrow.turn.up.right",
                                                content: .text(moved == 1 ? "1 carried over" : "\(moved) carried over"),
                                                tint: Self.tint, earWidth: 120, duration: .seconds(3)))
    }

    // MARK: - Reading

    static var tint: Color { Theme.accent }

    func tasks(on day: Date) -> [LifeTask] {
        let day = Self.day(day)
        return tasks.filter { $0.day.map { Self.day($0) == day } ?? false }
            .sorted { ($0.isDone ? 1 : 0, $0.created) < ($1.isDone ? 1 : 0, $1.created) }
    }

    var someday: [LifeTask] {
        tasks.filter { $0.day == nil && !$0.isDone }.sorted { $0.created > $1.created }
    }

    var openToday: Int { tasks(on: Self.today).filter { !$0.isDone }.count }

    /// The seven days of the week `date` falls in, from your week-start day.
    func week(containing date: Date = Date()) -> [Date] {
        let calendar = Self.calendar
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? Self.day(date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func arc(id: UUID?) -> Arc? {
        guard let id else { return nil }
        return arcs.first { $0.id == id }
    }

    var liveArcs: [Arc] { arcs.filter { !$0.archived } }

    // MARK: - The graph

    private var scores: [Date: Int] {
        if let scoreCache { return scoreCache }
        var scores: [Date: Int] = [:]
        for task in tasks {
            guard let done = task.done else { continue }
            scores[Self.day(done), default: 0] += LifeScore.task
        }
        for checkIn in checkIns {
            scores[Self.day(checkIn.day), default: 0] += LifeScore.checkIn
        }
        for arc in arcs {
            for milestone in arc.milestones {
                guard let done = milestone.done else { continue }
                scores[Self.day(done), default: 0] += LifeScore.milestone
            }
        }
        scoreCache = scores
        return scores
    }

    func commits(on day: Date) -> Int { scores[Self.day(day)] ?? 0 }

    func commitsThisWeek() -> Int {
        week().reduce(0) { $0 + commits(on: $1) }
    }

    /// Days with at least one commit, counting back from today. Today not
    /// counting yet doesn't break a streak until tomorrow.
    var streak: Int {
        let calendar = Self.calendar
        var day = Self.today
        if commits(on: day) == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while commits(on: day) > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    var longestStreak: Int {
        let days = scores.filter { $0.value > 0 }.keys.sorted()
        guard !days.isEmpty else { return 0 }
        let calendar = Self.calendar
        var longest = 1, run = 1
        for (previous, day) in zip(days, days.dropFirst()) {
            let gap = calendar.dateComponents([.day], from: previous, to: day).day ?? 0
            run = gap == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        return longest
    }

    /// Columns of seven days, oldest first, ending with the week today is in.
    func graphColumns(weeks: Int = LifeService.graphWeeks, endingOn end: Date = Date()) -> [[Date]] {
        let calendar = Self.calendar
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: end)?.start ?? Self.day(end)
        guard let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        return (0..<weeks).compactMap { week in
            guard let start = calendar.date(byAdding: .weekOfYear, value: week, to: first) else { return nil }
            return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        }
    }

    /// What you finished on a day, for the panel beside the graph.
    func done(on day: Date) -> (tasks: [LifeTask], checkIns: [(Arc, Habit)], milestones: [(Arc, Milestone)]) {
        let day = Self.day(day)
        let finished = tasks.filter { $0.done.map { Self.day($0) == day } ?? false }
        let kept = checkIns.filter { Self.day($0.day) == day }.compactMap { checkIn -> (Arc, Habit)? in
            guard let arc = arc(id: checkIn.arcID), let habit = arc.habits.first(where: { $0.id == checkIn.habitID }) else {
                return nil
            }
            return (arc, habit)
        }
        let milestones = arcs.flatMap { arc in
            arc.milestones.filter { $0.done.map { Self.day($0) == day } ?? false }.map { (arc, $0) }
        }
        return (finished, kept, milestones)
    }

    // MARK: - Tasks

    @discardableResult
    func add(_ title: String, on day: Date? = LifeService.today, arcID: UUID? = nil) -> LifeTask? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // "Ship the beta #xotch" puts it on the arc whose name starts with "xotch".
        var text = trimmed
        var arcID = arcID
        if let hash = text.range(of: "#", options: .backwards) {
            let tag = String(text[hash.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
            if !tag.isEmpty, let match = liveArcs.first(where: { $0.name.lowercased().hasPrefix(tag) }) {
                arcID = match.id
                text = String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        let task = LifeTask(title: text, day: day.map(Self.day), arcID: arcID)
        withAnimation(Motion.switchModule) { tasks.insert(task, at: 0) }
        invalidate()
        saver.schedule()
        Haptics.tick()
        return task
    }

    func toggle(_ task: LifeTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let nowDone = !tasks[index].isDone
        withAnimation(Motion.switchModule) { tasks[index].done = nowDone ? Date() : nil }
        if nowDone, tasks[index].day == nil {
            tasks[index].day = Self.today
        }
        invalidate()
        saver.schedule()
        if nowDone {
            committed()
        }
    }

    func move(_ task: LifeTask, to day: Date?) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        withAnimation(Motion.switchModule) { tasks[index].day = day.map(Self.day) }
        saver.schedule()
        Haptics.tick()
    }

    func delete(_ task: LifeTask) {
        withAnimation(Motion.switchModule) { tasks.removeAll { $0.id == task.id } }
        invalidate()
        saver.schedule()
    }

    // MARK: - Arcs

    func save(_ arc: Arc) {
        if let index = arcs.firstIndex(where: { $0.id == arc.id }) {
            arcs[index] = arc
        } else {
            withAnimation(Motion.switchModule) { arcs.append(arc) }
        }
        invalidate()
        saver.schedule()
        LifeReminders.shared.refreshAll()
    }

    func archive(_ arc: Arc) {
        guard let index = arcs.firstIndex(where: { $0.id == arc.id }) else { return }
        withAnimation(Motion.switchModule) { arcs[index].archived.toggle() }
        saver.schedule()
        LifeReminders.shared.refreshAll()
    }

    func delete(_ arc: Arc) {
        withAnimation(Motion.switchModule) { arcs.removeAll { $0.id == arc.id } }
        checkIns.removeAll { $0.arcID == arc.id }
        for index in tasks.indices where tasks[index].arcID == arc.id {
            tasks[index].arcID = nil
        }
        invalidate()
        saver.schedule()
        LifeReminders.shared.refreshAll()
    }

    func isKept(_ habit: Habit, on day: Date = LifeService.today) -> Bool {
        let day = Self.day(day)
        return checkIns.contains { $0.habitID == habit.id && Self.day($0.day) == day }
    }

    /// How many times a habit has been kept in the week `day` falls in.
    func keptThisWeek(_ habit: Habit, around day: Date = Date()) -> Int {
        let days = Set(week(containing: day).map(Self.day))
        return checkIns.filter { $0.habitID == habit.id && days.contains(Self.day($0.day)) }.count
    }

    /// Is this habit still asking to be done today?
    func isDue(_ habit: Habit, on day: Date = LifeService.today) -> Bool {
        guard !isKept(habit, on: day) else { return false }
        let weekday = Self.calendar.component(.weekday, from: day)
        switch habit.cadence {
        case .daily: return true
        case .days(let days): return days.contains(weekday)
        case .timesPerWeek(let target): return keptThisWeek(habit, around: day) < target
        }
    }

    func toggleCheckIn(_ habit: Habit, in arc: Arc, on day: Date = LifeService.today) {
        let day = Self.day(day)
        if isKept(habit, on: day) {
            withAnimation(Motion.switchModule) {
                checkIns.removeAll { $0.habitID == habit.id && Self.day($0.day) == day }
            }
            invalidate()
            saver.schedule()
            return
        }
        withAnimation(Motion.switchModule) { checkIns.append(CheckIn(day: day, arcID: arc.id, habitID: habit.id)) }
        invalidate()
        saver.schedule()
        committed()
    }

    func toggle(_ milestone: Milestone, in arc: Arc) {
        guard let arcIndex = arcs.firstIndex(where: { $0.id == arc.id }),
              let index = arcs[arcIndex].milestones.firstIndex(where: { $0.id == milestone.id }) else { return }
        let nowDone = !arcs[arcIndex].milestones[index].isDone
        withAnimation(Motion.switchModule) { arcs[arcIndex].milestones[index].done = nowDone ? Date() : nil }
        invalidate()
        saver.schedule()
        LifeReminders.shared.refreshAll()
        guard nowDone else { return }
        ActivityCenter.shared.post(LiveActivity(moduleID: "life", symbol: "flag.checkered",
                                                content: .text(milestone.title), tint: arc.colour.color,
                                                earWidth: 150, duration: .seconds(4)))
        ActivityCenter.shared.celebrate()
    }

    func progress(of arc: Arc, on day: Date = Date()) -> ArcProgress {
        let done = arc.milestones.filter(\.isDone).count
        let calendar = Self.calendar
        let daysLeft = arc.end.map { max(0, calendar.dateComponents([.day], from: Self.day(day), to: Self.day($0)).day ?? 0) }
        // Hit rate over the last four weeks: kept check-ins against the days asked for.
        let window = (0..<28).compactMap { calendar.date(byAdding: .day, value: -$0, to: Self.day(day)) }
            .filter { $0 >= Self.day(arc.start) }
        var expected = 0, kept = 0
        for habit in arc.habits {
            switch habit.cadence {
            case .daily:
                expected += window.count
            case .days(let weekdays):
                expected += window.count { weekdays.contains(calendar.component(.weekday, from: $0)) }
            case .timesPerWeek(let target):
                expected += Int((Double(window.count) / 7 * Double(target)).rounded())
            }
            kept += window.count { isKept(habit, on: $0) }
        }
        let rate = expected > 0 ? min(1, Double(kept) / Double(expected)) : 0
        return ArcProgress(milestonesDone: done, milestonesTotal: arc.milestones.count, habitRate: rate, daysLeft: daysLeft)
    }

    // MARK: - Housekeeping

    private func invalidate() {
        scoreCache = nil
        updateActivity()
    }

    /// A short "Committed" beside the notch, with the day's running total.
    private func committed() {
        let total = commits(on: Self.today)
        ActivityCenter.shared.post(LiveActivity(moduleID: "life", symbol: "checkmark.square.fill",
                                                content: .text(total == 1 ? "1 commit" : "\(total) commits"),
                                                tint: Self.tint, earWidth: 110, duration: .seconds(2)))
        Haptics.tick()
    }

    /// "3 left" beside the notch while today still has tasks, if that's on.
    func updateActivity() {
        let center = ActivityCenter.shared
        guard AppSettings.lifeActivity, openToday > 0 else {
            center.setOngoing(nil, for: "life")
            return
        }
        center.setOngoing(LiveActivity(moduleID: "life", symbol: "checklist", content: .text("\(openToday) left"),
                                       tint: Self.tint, earWidth: 96), for: "life")
    }

    func settingsChanged() {
        updateActivity()
        LifeReminders.shared.refreshAll()
    }

    func revealStore() {
        NSWorkspace.shared.activateFileViewerSelecting([Storage.directory.appendingPathComponent("life.json")])
    }

    #if DEBUG
    /// Snapshot state: which tab opens, whether the designer shows, and a
    /// day picked in the graph.
    /// What the module is showing, for `scripts/debug.sh status` — the only way
    /// to see whether a click on a tab or a button actually arrived.
    nonisolated(unsafe) static var debugUI = "not shown"
    nonisolated(unsafe) static var debugTab = "Today"
    /// The tab actually on screen, for the UI self-test. `debugTab` above is
    /// the other direction: which tab a snapshot should open on.
    nonisolated(unsafe) static var debugCurrentTab = "-"
    nonisolated(unsafe) static var debugDesigner = false
    nonisolated(unsafe) static var debugSelectedDay: Date?

    static func debugReset() {
        debugTab = "Today"
        debugDesigner = false
        debugSelectedDay = nil
    }

    func withSample(_ body: () -> Void) {
        let saved = (tasks, arcs, checkIns, scoreCache)
        (tasks, arcs, checkIns) = Self.sample()
        scoreCache = nil
        body()
        (tasks, arcs, checkIns, scoreCache) = saved
    }

    /// A made-up year, so snapshots never show anyone's real life.
    static func sample() -> ([LifeTask], [Arc], [CheckIn]) {
        let calendar = Self.calendar
        let today = Self.today
        func date(_ daysAgo: Int) -> Date { calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today }

        var ship = Arc(name: "Ship Xotch", colour: RGBA(hex: 0xFF9F0A), intent: "Beta in testers' hands by December",
                       start: date(60), end: calendar.date(byAdding: .day, value: 74, to: today))
        ship.habits = [Habit(title: "An hour on Xotch", cadence: .daily, reminder: 9 * 60 + 30)]
        ship.milestones = [Milestone(title: "Capture module", due: date(-6), done: date(2)),
                           Milestone(title: "Developer ID signing", due: date(-20)),
                           Milestone(title: "Ten testers", due: date(-38))]

        var strong = Arc(name: "Strong", colour: RGBA(hex: 0x30C26A), intent: "Lift three times a week, no excuses",
                         start: date(120))
        strong.habits = [Habit(title: "Gym", cadence: .timesPerWeek(3), reminder: 7 * 60),
                         Habit(title: "Walk 8k steps", cadence: .daily)]
        strong.milestones = [Milestone(title: "Bench bodyweight", done: date(24))]

        var read = Arc(name: "Read more", colour: RGBA(hex: 0x4FA3FF), intent: "Twenty pages before the phone",
                       start: date(200))
        read.habits = [Habit(title: "Twenty pages", cadence: .days([2, 3, 4, 5, 6]), reminder: 21 * 60)]

        let arcs = [ship, strong, read]
        let titles = [("Draft the beta email", ship.id), ("Fix the notch on wake", ship.id),
                      ("Book a physio slot", strong.id), ("Plan next week's arcs", nil as UUID?),
                      ("Renew the domain", nil), ("Write release notes", ship.id)]
        var tasks = titles.enumerated().map { index, item in
            LifeTask(title: item.0, day: today, done: index < 2 ? Date() : nil, arcID: item.1,
                     created: date(0).addingTimeInterval(Double(index) * 60))
        }
        for offset in 1...5 {
            tasks.append(LifeTask(title: ["Review Capture PR", "Tidy the shelf code", "Buy coffee",
                                          "Call home", "Sketch the arc designer"][offset - 1],
                                  day: calendar.date(byAdding: .day, value: offset, to: today),
                                  arcID: offset % 2 == 0 ? ship.id : nil))
        }

        // A year of check-ins, thinner in the past and denser lately.
        var checkIns: [CheckIn] = []
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(UInt64(1) << 31)
        }
        for daysAgo in 0..<364 {
            let day = date(daysAgo)
            let recent = 1.0 - Double(daysAgo) / 420
            for arc in arcs {
                for habit in arc.habits where random() < recent * 0.55 {
                    checkIns.append(CheckIn(day: day, arcID: arc.id, habitID: habit.id))
                }
            }
            if random() < recent * 0.5 {
                tasks.append(LifeTask(title: "Done", day: day, done: day.addingTimeInterval(36_000)))
            }
        }
        return (tasks, arcs, checkIns)
    }
    #endif
}
