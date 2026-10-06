import AppKit
import SwiftUI

/// What a tool did: a short JSON result for the model, a line for the card,
/// and how to take it back.
struct ToolOutcome {
    var result: String
    var summary: String
    var undo: (@MainActor () -> Void)?
    /// A module worth opening to see the change, offered on the card.
    var openModule: String?
}

struct ToolFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A tool call's arguments, read leniently: models send numbers as strings
/// and the other way round.
struct ToolArgs {
    let values: [String: Any]

    func string(_ key: String) -> String? {
        if let text = values[key] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = values[key] as? NSNumber { return number.stringValue }
        return nil
    }

    func number(_ key: String) -> Double? {
        if let number = values[key] as? NSNumber { return number.doubleValue }
        return (values[key] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func bool(_ key: String) -> Bool? {
        if let value = values[key] as? Bool { return value }
        return (values[key] as? String).map { ["true", "yes", "1"].contains($0.lowercased()) }
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolFailure("Missing “\(key)”.") }
        return value
    }
}

/// One thing the AI can see or do in the notch.
@MainActor
struct NotchTool {
    enum Kind {
        /// Only looks at the notch; runs without asking.
        case look
        /// Shares something private (clipboard, notes) with the provider; asks first.
        case share
        /// Changes something; asks first.
        case change
    }

    let name: String
    let description: String
    let parameters: [String: Any]
    let kind: Kind
    let symbol: String
    let tint: Color
    /// What the card says before it runs, e.g. "Add **Buy milk** to today".
    let preview: (ToolArgs) -> String
    let run: (ToolArgs) async throws -> ToolOutcome

    var asks: Bool { kind != .look }

    var spec: ToolSpec {
        let data = (try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ToolSpec(name: name, description: description, parameters: data)
    }
}

/// Everything the AI can do in the notch. Looking is free; anything that
/// changes something, or shares the clipboard or notes, waits for the user.
@MainActor
enum NotchTools {
    static var all: [NotchTool] { looks + shares + changes }

    static var specs: [ToolSpec] { all.map(\.spec) }

    static func tool(named name: String) -> NotchTool? {
        all.first { $0.name == name }
    }

    // MARK: - Looking

    private static var looks: [NotchTool] {[
        NotchTool(
            name: "get_now_playing",
            description: "What music or video is playing on the Mac right now, if anything.",
            parameters: object([:]), kind: .look, symbol: "music.note", tint: .pink,
            preview: { _ in "Check what's playing" }
        ) { _ in
            guard let playing = MediaService.shared.nowPlaying else {
                return ToolOutcome(result: json(["playing": false]), summary: "Checked what's playing: nothing")
            }
            return ToolOutcome(result: json(["playing": playing.isPlaying, "title": playing.title,
                                             "artist": playing.artist, "album": playing.album,
                                             "app": playing.appName ?? ""]),
                               summary: "Checked what's playing")
        },
        NotchTool(
            name: "list_todos",
            description: "The user's to-dos for a day, with their ids, so they can be ticked off.",
            parameters: object(["day": day("Which day's list. Default today.")]),
            kind: .look, symbol: "checklist", tint: Theme.accent,
            preview: { args in "Check your to-dos for \(dayLabel(args.string("day")))" }
        ) { args in
            let todos = TodoService.shared
            let day = try parseDay(args.string("day"))
            let list = day.map { todos.todos(on: $0) } ?? todos.someday
            let items = list.map { ["id": $0.id.uuidString, "title": $0.title, "done": $0.isDone] as [String: Any] }
            return ToolOutcome(result: json(["day": dayLabel(args.string("day")), "todos": items]),
                               summary: "Checked your to-dos for \(dayLabel(args.string("day")))")
        },
        NotchTool(
            name: "get_agenda",
            description: "Calendar events and open reminders. Reminders come with ids so they can be completed.",
            parameters: object([
                "from": ["type": "string", "description": "First day, YYYY-MM-DD. Default today."],
                "days": ["type": "integer", "description": "How many days from there, 1 to 14. Default 1."],
            ]),
            kind: .look, symbol: "calendar", tint: .red,
            preview: { _ in "Check your calendar" }
        ) { args in
            let calendar = CalendarService.shared
            guard calendar.eventAccess == .granted || calendar.reminderAccess == .granted else {
                throw CalendarService.CalendarError.noAccess
            }
            let start = try args.string("from").map(parseDate) ?? TodoService.today
            let days = Int(min(max(args.number("days") ?? 1, 1), 14))
            let end = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: start)) ?? start
            let events = calendar.events(from: Calendar.current.startOfDay(for: start), to: end).map { event -> [String: Any] in
                var item: [String: Any] = ["title": event.title, "start": stamp(event.start), "end": stamp(event.end),
                                           "all_day": event.isAllDay]
                if let location = event.location { item["location"] = location }
                return item
            }
            let reminders = calendar.reminders.map { reminder -> [String: Any] in
                var item: [String: Any] = ["id": reminder.id, "title": reminder.title]
                if let due = reminder.due { item["due"] = stamp(due) }
                return item
            }
            return ToolOutcome(result: json(["events": events, "open_reminders": reminders]),
                               summary: "Checked your calendar")
        },
        NotchTool(
            name: "get_timer",
            description: "The focus timer or countdown, and the stopwatch, as they are now.",
            parameters: object([:]), kind: .look, symbol: "timer", tint: TimerKind.focus.tint,
            preview: { _ in "Check your timer" }
        ) { _ in
            let timers = TimerService.shared
            var result: [String: Any] = ["stopwatch_running": timers.isStopwatchRunning,
                                         "stopwatch_seconds": Int(timers.stopwatchElapsed(at: .now))]
            if let kind = timers.kind {
                result["timer"] = ["kind": kind.title, "running": timers.isRunning,
                                   "seconds_left": Int(timers.remaining(at: .now))]
            } else {
                result["timer"] = NSNull()
            }
            return ToolOutcome(result: json(result), summary: "Checked your timer")
        },
        NotchTool(
            name: "get_system_stats",
            description: "The Mac's CPU, memory, disk space and battery right now.",
            parameters: object([:]), kind: .look, symbol: "gauge.with.dots.needle.33percent", tint: .green,
            preview: { _ in "Check your Mac's stats" }
        ) { _ in
            let stats = StatsService.shared
            if stats.snapshot == nil {
                // CPU use needs two readings.
                stats.sampleNow()
                try? await Task.sleep(for: .seconds(1))
                stats.sampleNow()
            }
            guard let snapshot = stats.snapshot else { throw ToolFailure("The stats aren't ready yet.") }
            var result: [String: Any] = [
                "cpu_percent": Int((snapshot.cpu * 100).rounded()),
                "memory_used": Format.bytes(snapshot.memoryUsed), "memory_total": Format.bytes(snapshot.memoryTotal),
                "disk_free": Format.bytes(snapshot.diskFree), "disk_total": Format.bytes(snapshot.diskTotal),
            ]
            if let battery = snapshot.battery {
                result["battery_percent"] = battery.percent
                result["charging"] = battery.isCharging
            }
            return ToolOutcome(result: json(result), summary: "Checked your Mac's stats")
        },
        NotchTool(
            name: "get_claude_sessions",
            description: "Claude Code sessions on this Mac and what each is doing.",
            parameters: object([:]), kind: .look, symbol: "sparkle", tint: ClaudeLiveService.tint,
            preview: { _ in "Check Claude Code" }
        ) { _ in
            let sessions = ClaudeLiveService.shared.sessions.map { ["project": $0.project, "state": $0.stateLabel] }
            return ToolOutcome(result: json(["sessions": sessions]), summary: "Checked Claude Code")
        },
    ]}

    // MARK: - Sharing

    private static var shares: [NotchTool] {[
        NotchTool(
            name: "read_clipboard",
            description: "The most recent text the user copied. Asks the user first, as it's private.",
            parameters: object(["count": ["type": "integer", "description": "How many recent items, 1 to 5. Default 1."]]),
            kind: .share, symbol: "doc.on.clipboard", tint: Theme.accent,
            preview: { args in
                let count = Int(min(max(args.number("count") ?? 1, 1), 5))
                return count == 1 ? "Share your last copied text with \(providerName)" : "Share your last \(count) copied texts with \(providerName)"
            }
        ) { args in
            let count = Int(min(max(args.number("count") ?? 1, 1), 5))
            let items = ClipboardService.shared.items
                .filter { $0.kind == .text || $0.kind == .link }
                .prefix(count)
                .map { ["text": String(($0.text ?? "").prefix(1500)), "from": $0.sourceApp ?? ""] }
            return ToolOutcome(result: json(["items": Array(items)]),
                               summary: items.isEmpty ? "Nothing copied to share" : "Shared \(items.count) copied \(items.count == 1 ? "text" : "texts")")
        },
        NotchTool(
            name: "read_notes",
            description: "The user's notes in the notch, optionally only those containing some words, with ids. Asks the user first.",
            parameters: object(["query": ["type": "string", "description": "Words to look for. Leave out for the latest notes."]]),
            kind: .share, symbol: "note.text", tint: .yellow,
            preview: { args in
                args.string("query").map { "Share your notes about “\($0)” with \(providerName)" } ?? "Share your latest notes with \(providerName)"
            }
        ) { args in
            var notes = NotesService.shared.notes
            if let query = args.string("query") {
                notes = notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
            }
            let items = notes.prefix(5).map { ["id": $0.id.uuidString, "title": $0.title, "text": String($0.text.prefix(2000))] }
            return ToolOutcome(result: json(["notes": Array(items)]),
                               summary: items.isEmpty ? "No notes matched" : "Shared \(items.count) \(items.count == 1 ? "note" : "notes")",
                               openModule: "notes")
        },
    ]}

    // MARK: - Changing

    private static var changes: [NotchTool] {[
        NotchTool(
            name: "add_todo",
            description: "Adds a to-do to the user's list.",
            parameters: object(["title": ["type": "string", "description": "The to-do, short."],
                                "day": day("When it's for. Default today.")], required: ["title"]),
            kind: .change, symbol: "plus.circle", tint: Theme.accent,
            preview: { args in "Add **\(args.string("title") ?? "a to-do")** to \(dayLabel(args.string("day")))" }
        ) { args in
            let title = try args.required("title")
            let day = try parseDay(args.string("day"))
            guard let todo = TodoService.shared.add(title, on: day) else { throw ToolFailure("The to-do was empty.") }
            return ToolOutcome(result: json(["added": true, "id": todo.id.uuidString]),
                               summary: "Added **\(title)** to \(dayLabel(args.string("day")))",
                               undo: { TodoService.shared.delete(todo) }, openModule: "todos")
        },
        NotchTool(
            name: "complete_todo",
            description: "Ticks off one of the user's to-dos, by the id from list_todos.",
            parameters: object(["id": ["type": "string", "description": "The to-do's id."]], required: ["id"]),
            kind: .change, symbol: "checkmark.circle", tint: Theme.positive,
            preview: { args in "Tick off **\(todo(args.string("id"))?.title ?? "a to-do")**" }
        ) { args in
            guard let todo = todo(args.string("id")) else { throw ToolFailure("No to-do has that id. Call list_todos first.") }
            guard !todo.isDone else { return ToolOutcome(result: json(["already_done": true]), summary: "**\(todo.title)** was already done") }
            TodoService.shared.toggle(todo)
            return ToolOutcome(result: json(["done": true]), summary: "Ticked off **\(todo.title)**",
                               undo: {
                                   if let current = TodoService.shared.todos.first(where: { $0.id == todo.id }), current.isDone {
                                       TodoService.shared.toggle(current)
                                   }
                               }, openModule: "todos")
        },
        NotchTool(
            name: "start_timer",
            description: "Starts a focus session, a break, or a countdown timer. Replaces any timer already running.",
            parameters: object([
                "kind": ["type": "string", "enum": ["focus", "short_break", "long_break", "countdown"],
                         "description": "Focus is 25 minutes and breaks 5 or 15 unless minutes says otherwise."],
                "minutes": ["type": "number", "description": "Length in minutes."],
            ], required: ["kind"]),
            kind: .change, symbol: "timer", tint: TimerKind.focus.tint,
            preview: { args in
                let (kind, minutes) = timerRequest(args)
                return "Start a **\(describe(minutes: minutes))** \(kind.title.lowercased())"
            }
        ) { args in
            let (kind, minutes) = timerRequest(args)
            guard minutes > 0, minutes <= 24 * 60 else { throw ToolFailure("Pick between 1 minute and 24 hours.") }
            TimerService.shared.start(kind, seconds: minutes * 60)
            return ToolOutcome(result: json(["started": true, "kind": kind.title, "minutes": minutes]),
                               summary: "Started a **\(describe(minutes: minutes))** \(kind.title.lowercased())",
                               undo: { TimerService.shared.reset() }, openModule: "timers")
        },
        NotchTool(
            name: "control_timer",
            description: "Pauses, resumes or cancels the running focus timer or countdown.",
            parameters: object(["action": ["type": "string", "enum": ["pause", "resume", "cancel"]]], required: ["action"]),
            kind: .change, symbol: "playpause", tint: TimerKind.focus.tint,
            preview: { args in "\((args.string("action") ?? "Change").capitalized) the timer" }
        ) { args in
            let timers = TimerService.shared
            guard timers.isActive else { throw ToolFailure("No timer is running.") }
            switch args.string("action") {
            case "pause": timers.pause()
            case "resume": timers.resume()
            case "cancel": timers.reset()
            default: throw ToolFailure("Use pause, resume or cancel.")
            }
            let done = ["pause": "Paused", "resume": "Resumed", "cancel": "Cancelled"][args.string("action") ?? ""] ?? "Changed"
            return ToolOutcome(result: json(["ok": true]), summary: "\(done) the timer", openModule: "timers")
        },
        NotchTool(
            name: "stopwatch",
            description: "Starts, stops, laps or resets the stopwatch.",
            parameters: object(["action": ["type": "string", "enum": ["start", "stop", "lap", "reset"]]], required: ["action"]),
            kind: .change, symbol: "stopwatch", tint: TimerKind.countdown.tint,
            preview: { args in "\((args.string("action") ?? "Use").capitalized) the stopwatch" }
        ) { args in
            let timers = TimerService.shared
            switch args.string("action") {
            case "start": if !timers.isStopwatchRunning { timers.toggleStopwatch() }
            case "stop": if timers.isStopwatchRunning { timers.toggleStopwatch() }
            case "lap": timers.lap()
            case "reset": timers.resetStopwatch()
            default: throw ToolFailure("Use start, stop, lap or reset.")
            }
            return ToolOutcome(result: json(["ok": true, "seconds": Int(timers.stopwatchElapsed(at: .now))]),
                               summary: "\((args.string("action") ?? "Used").capitalized) the stopwatch", openModule: "timers")
        },
        NotchTool(
            name: "media",
            description: "Plays, pauses or skips whatever music or video is playing on the Mac.",
            parameters: object(["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]]], required: ["action"]),
            kind: .change, symbol: "playpause.fill", tint: .pink,
            preview: { args in
                switch args.string("action") {
                case "next": "Skip to the next track"
                case "previous": "Go back a track"
                case "pause": "Pause the music"
                default: "Play the music"
                }
            }
        ) { args in
            let media = MediaService.shared
            guard let playing = media.nowPlaying else { throw ToolFailure("Nothing is playing.") }
            switch args.string("action") {
            case "play": if !playing.isPlaying { media.togglePlayPause() }
            case "pause": if playing.isPlaying { media.togglePlayPause() }
            case "next": media.next()
            case "previous": media.previous()
            default: throw ToolFailure("Use play, pause, next or previous.")
            }
            return ToolOutcome(result: json(["ok": true]), summary: "Done: \(args.string("action") ?? "")", openModule: "media")
        },
        NotchTool(
            name: "create_note",
            description: "Writes a new note in the notch.",
            parameters: object(["text": ["type": "string", "description": "The note. Its first line is the title."]], required: ["text"]),
            kind: .change, symbol: "square.and.pencil", tint: .yellow,
            preview: { args in "Write a note: **\(firstLine(args.string("text")))**" }
        ) { args in
            let text = try args.required("text")
            let notes = NotesService.shared
            let id = notes.newNote()
            notes.update(id, text: text)
            return ToolOutcome(result: json(["created": true, "id": id.uuidString]),
                               summary: "Wrote a note: **\(firstLine(text))**",
                               undo: { NotesService.shared.delete(id) }, openModule: "notes")
        },
        NotchTool(
            name: "append_to_note",
            description: "Adds text to the end of an existing note, by the id from read_notes.",
            parameters: object(["id": ["type": "string", "description": "The note's id."],
                                "text": ["type": "string", "description": "What to add."]], required: ["id", "text"]),
            kind: .change, symbol: "text.append", tint: .yellow,
            preview: { args in "Add to the note **\(note(args.string("id"))?.title ?? "a note")**" }
        ) { args in
            guard let note = note(args.string("id")) else { throw ToolFailure("No note has that id. Call read_notes first.") }
            let addition = try args.required("text")
            let before = note.text
            NotesService.shared.update(note.id, text: before + (before.hasSuffix("\n") || before.isEmpty ? "" : "\n") + addition)
            return ToolOutcome(result: json(["ok": true]), summary: "Added to **\(note.title)**",
                               undo: { NotesService.shared.update(note.id, text: before) }, openModule: "notes")
        },
        NotchTool(
            name: "add_calendar_event",
            description: "Adds an event to the user's default calendar.",
            parameters: object([
                "title": ["type": "string"],
                "start": ["type": "string", "description": "Local start time, YYYY-MM-DDTHH:MM, or YYYY-MM-DD for all day."],
                "end": ["type": "string", "description": "Local end time. Default one hour after the start."],
                "location": ["type": "string"],
            ], required: ["title", "start"]),
            kind: .change, symbol: "calendar.badge.plus", tint: .red,
            preview: { args in
                let when = (try? parseDate(args.string("start") ?? "")).map(friendly) ?? (args.string("start") ?? "")
                return "Add **\(args.string("title") ?? "an event")** to your calendar, \(when)"
            }
        ) { args in
            let title = try args.required("title")
            let startText = try args.required("start")
            let allDay = !startText.contains("T") && !startText.contains(":")
            let start = try parseDate(startText)
            let end = try args.string("end").map(parseDate) ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
            guard end > start else { throw ToolFailure("The end is before the start.") }
            let id = try CalendarService.shared.addEvent(title: title, start: start, end: end, allDay: allDay,
                                                         location: args.string("location"))
            return ToolOutcome(result: json(["added": true]),
                               summary: "Added **\(title)**, \(friendly(start))",
                               undo: { CalendarService.shared.removeEvent(identifier: id) }, openModule: "calendar")
        },
        NotchTool(
            name: "complete_reminder",
            description: "Marks one of the user's reminders done, by the id from get_agenda.",
            parameters: object(["id": ["type": "string"]], required: ["id"]),
            kind: .change, symbol: "checkmark.circle", tint: .orange,
            preview: { args in
                let title = CalendarService.shared.reminders.first { $0.id == args.string("id") }?.title
                return "Complete the reminder **\(title ?? "a reminder")**"
            }
        ) { args in
            guard let reminder = CalendarService.shared.reminders.first(where: { $0.id == args.string("id") }) else {
                throw ToolFailure("No open reminder has that id. Call get_agenda first.")
            }
            CalendarService.shared.complete(reminder)
            return ToolOutcome(result: json(["done": true]), summary: "Completed **\(reminder.title)**", openModule: "calendar")
        },
        NotchTool(
            name: "copy_to_clipboard",
            description: "Puts text on the clipboard, ready to paste.",
            parameters: object(["text": ["type": "string"]], required: ["text"]),
            kind: .change, symbol: "doc.on.doc", tint: Theme.accent,
            preview: { args in "Copy “\(String((args.string("text") ?? "").prefix(60)))” to the clipboard" }
        ) { args in
            let text = try args.required("text")
            let pasteboard = NSPasteboard.general
            let previous = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return ToolOutcome(result: json(["copied": true]), summary: "Copied to the clipboard",
                               undo: {
                                   NSPasteboard.general.clearContents()
                                   if let previous { NSPasteboard.general.setString(previous, forType: .string) }
                               })
        },
        NotchTool(
            name: "take_screenshot",
            description: "Takes a screenshot: an area or a window the user picks, or the whole screen. Saved in the captures folder.",
            parameters: object(["target": ["type": "string", "enum": ["area", "window", "screen"]]], required: ["target"]),
            kind: .change, symbol: "camera.viewfinder", tint: CaptureService.tint,
            preview: { args in
                switch args.string("target") {
                case "area": "Take a screenshot of an area you pick"
                case "window": "Take a screenshot of a window you pick"
                default: "Take a screenshot of the screen"
                }
            }
        ) { args in
            guard let target = CaptureTarget(rawValue: args.string("target") ?? "") else {
                throw ToolFailure("Use area, window or screen.")
            }
            CaptureService.shared.takeScreenshot(target)
            return ToolOutcome(result: json(["started": true]), summary: "Screenshot started", openModule: "capture")
        },
    ]}

    // MARK: - Helpers

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func day(_ description: String) -> [String: Any] {
        ["type": "string", "description": description + " today, tomorrow, someday, or YYYY-MM-DD."]
    }

    static func json(_ object: [String: Any]) -> String {
        AIBackends.json(object)
    }

    private static var providerName: String {
        AIProviderStore.shared.active?.name ?? "the AI"
    }

    /// nil means someday.
    static func parseDay(_ text: String?) throws -> Date? {
        let calendar = Calendar.current
        switch text?.lowercased() {
        case nil, "", "today": return TodoService.today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: TodoService.today)
        case "someday", "later", "none": return nil
        case let value?: return calendar.startOfDay(for: try parseDate(value))
        }
    }

    static func dayLabel(_ text: String?) -> String {
        switch text?.lowercased() {
        case nil, "", "today": return "today"
        case "tomorrow": return "tomorrow"
        case "someday", "later", "none": return "someday"
        case let value?:
            guard let date = try? parseDate(value) else { return value }
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    /// Local dates and times as models write them.
    static func parseDate(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        throw ToolFailure("“\(text)” isn't a date. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM.")
    }

    /// Local time with its weekday, so the model can tell what "Friday" is.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    private static func friendly(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private static func todo(_ id: String?) -> Todo? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return TodoService.shared.todos.first { $0.id == uuid }
    }

    private static func note(_ id: String?) -> Note? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return NotesService.shared.note(id: uuid)
    }

    private static func firstLine(_ text: String?) -> String {
        let line = (text ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    private static func timerRequest(_ args: ToolArgs) -> (TimerKind, Double) {
        let kind: TimerKind = switch args.string("kind") {
        case "short_break", "break": .shortBreak
        case "long_break": .longBreak
        case "countdown", "timer": .countdown
        default: .focus
        }
        let fallback = switch kind {
        case .focus: TimerService.focusMinutes
        case .shortBreak: TimerService.shortBreakMinutes
        case .longBreak: TimerService.longBreakMinutes
        case .countdown: 10.0
        }
        return (kind, args.number("minutes") ?? fallback)
    }

    private static func describe(minutes: Double) -> String {
        minutes == minutes.rounded() ? "\(Int(minutes))-minute" : String(format: "%.1f-minute", minutes)
    }
}
