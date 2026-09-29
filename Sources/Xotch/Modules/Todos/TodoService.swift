import AppKit
import Foundation
import Observation
import SwiftUI

// To-dos for today, and a someday list for the rest.

struct Todo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// The day it's planned for, at midnight. Nil means someday.
    var day: Date?
    var done: Date?
    var created = Date()

    var isDone: Bool { done != nil }
}

private struct TodoFile: Codable {
    var todos: [Todo] = []
    var lastRollover: Date?
}

/// Just the part of the old life.json that still matters: its to-dos.
private struct LegacyLifeFile: Decodable {
    struct Task: Decodable {
        var id: UUID
        var title: String
        var day: Date?
        var done: Date?
        var created: Date
    }
    var tasks: [Task] = []
}

@MainActor
@Observable
final class TodoService {
    static let shared = TodoService()

    private(set) var todos: [Todo]
    @ObservationIgnored private var lastRollover: Date?
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private lazy var saver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(TodoFile(todos: todos, lastRollover: lastRollover), to: "todos.json")
    }

    init() {
        if let file = Storage.load(TodoFile.self, from: "todos.json") {
            todos = file.todos
            lastRollover = file.lastRollover
        } else if let legacy = Storage.load(LegacyLifeFile.self, from: "life.json") {
            // First launch after Life went away: bring the to-dos across and
            // leave life.json where it is, untouched.
            todos = legacy.tasks.map {
                Todo(id: $0.id, title: $0.title, day: $0.day, done: $0.done, created: $0.created)
            }
            saver.schedule()
        } else {
            todos = []
        }
    }

    // MARK: - Days

    static var calendar: Calendar { .current }
    static func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    static var today: Date { day(Date()) }
    static var tint: Color { Theme.accent }

    func start() {
        rolloverIfNeeded()
        scheduleMidnight()
        updateActivity()
    }

    func stop() {
        midnightTask?.cancel()
        midnightTask = nil
    }

    /// At midnight, yesterday's leftovers move to today.
    private func scheduleMidnight() {
        midnightTask?.cancel()
        guard let midnight = Self.calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5),
                                                    matchingPolicy: .nextTime) else { return }
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(60, midnight.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            rolloverIfNeeded()
            scheduleMidnight()
        }
    }

    /// Unfinished to-dos from before today move to today, once a day.
    func rolloverIfNeeded() {
        let today = Self.today
        guard AppSettings.todoRollover, lastRollover.map({ $0 < today }) ?? true else { return }
        lastRollover = today
        var moved = 0
        for index in todos.indices where !todos[index].isDone {
            if let day = todos[index].day, day < today {
                todos[index].day = today
                moved += 1
            }
        }
        saver.schedule()
        updateActivity()
        guard moved > 0 else { return }
        ActivityCenter.shared.post(LiveActivity(moduleID: "todos", symbol: "arrow.turn.up.right",
                                                content: .text(moved == 1 ? "1 carried over" : "\(moved) carried over"),
                                                tint: Self.tint, earWidth: 120, duration: .seconds(3)))
    }

    // MARK: - Reading

    func todos(on day: Date) -> [Todo] {
        let day = Self.day(day)
        return todos.filter { $0.day.map { Self.day($0) == day } ?? false }
            .sorted { ($0.isDone ? 1 : 0, $0.created) < ($1.isDone ? 1 : 0, $1.created) }
    }

    var someday: [Todo] {
        todos.filter { $0.day == nil && !$0.isDone }.sorted { $0.created > $1.created }
    }

    var openToday: Int { todos(on: Self.today).filter { !$0.isDone }.count }

    // MARK: - Changing

    @discardableResult
    func add(_ title: String, on day: Date? = TodoService.today) -> Todo? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let todo = Todo(title: trimmed, day: day.map(Self.day))
        withAnimation(Motion.switchModule) { todos.insert(todo, at: 0) }
        saver.schedule()
        updateActivity()
        Haptics.tick()
        return todo
    }

    func toggle(_ todo: Todo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        let nowDone = !todos[index].isDone
        withAnimation(Motion.switchModule) { todos[index].done = nowDone ? Date() : nil }
        if nowDone, todos[index].day == nil { todos[index].day = Self.today }
        saver.schedule()
        updateActivity()
        if nowDone { Haptics.tick() }
    }

    func move(_ todo: Todo, to day: Date?) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        withAnimation(Motion.switchModule) { todos[index].day = day.map(Self.day) }
        saver.schedule()
        updateActivity()
        Haptics.tick()
    }

    func delete(_ todo: Todo) {
        withAnimation(Motion.switchModule) { todos.removeAll { $0.id == todo.id } }
        saver.schedule()
        updateActivity()
    }

    // MARK: - Housekeeping

    /// "3 left" beside the notch while today still has to-dos, if that's on.
    func updateActivity() {
        let center = ActivityCenter.shared
        guard AppSettings.todoActivity, openToday > 0 else {
            center.setOngoing(nil, for: "todos")
            return
        }
        center.setOngoing(LiveActivity(moduleID: "todos", symbol: "checklist", content: .text("\(openToday) left"),
                                       tint: Self.tint, earWidth: 96), for: "todos")
    }

    func revealStore() {
        NSWorkspace.shared.activateFileViewerSelecting([Storage.directory.appendingPathComponent("todos.json")])
    }

    #if DEBUG
    /// Made-up to-dos for snapshots, so they never show anyone's real list.
    func withSample(_ body: () -> Void) {
        let saved = todos
        let today = Self.today
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: today) ?? today
        func todo(_ title: String, _ day: Date?, done: Bool = false) -> Todo {
            Todo(title: title, day: day, done: done ? Date() : nil)
        }
        todos = [
            todo("Book a physio slot", today),
            todo("Draft the beta email", today, done: true),
            todo("Call the dentist", tomorrow),
            todo("Read the Metal docs", nil),
            todo("Sort the photo backlog", nil),
        ]
        body()
        todos = saved
    }
    #endif
}
