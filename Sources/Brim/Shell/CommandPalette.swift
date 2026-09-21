import SwiftUI
import Observation

@MainActor
@Observable
final class CommandPaletteState {
    var isOpen = false
    var query = "" {
        didSet {
            if query != oldValue { selection = 0 }
        }
    }
    var selection = 0

    func move(by offset: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
    }
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    var tint: Color?
    /// Extra words that find this command.
    var keywords = ""
    let run: @MainActor () -> Void
}

/// Everything the palette can do, filtered by what's typed.
@MainActor
enum CommandCatalog {
    static let limit = 5

    static func commands(for query: String, actions: any NotchActions) -> [PaletteCommand] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [PaletteCommand] = []
        if let seconds = duration(in: text) {
            results.append(PaletteCommand(
                id: "timer-typed", title: "Start a \(describe(seconds)) timer", symbol: "timer",
                tint: TimerKind.countdown.tint
            ) {
                TimerService.shared.start(.countdown, seconds: seconds)
                actions.select(moduleID: "timers")
            })
        }

        // Anything typed that isn't a command can become today's to-do.
        if text.count >= 3, duration(in: text) == nil {
            results.append(PaletteCommand(
                id: "life-add", title: "Add “\(text)” to today", symbol: "plus.circle",
                tint: Theme.accent
            ) {
                LifeService.shared.add(text)
                actions.select(moduleID: "life")
            })
        }

        let all = catalog(actions: actions)
        if text.isEmpty {
            results += all
        } else {
            results += all
                .compactMap { command in score(command, for: text).map { (command, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            results += clipboardMatches(for: text)
        }
        return Array(results.prefix(limit))
    }

    // MARK: - Commands

    private static func catalog(actions: any NotchActions) -> [PaletteCommand] {
        var list: [PaletteCommand] = []
        let timers = TimerService.shared
        let media = MediaService.shared
        let capture = CaptureService.shared

        if capture.isRecording {
            list.append(PaletteCommand(id: "record-stop", title: "Stop recording", symbol: "stop.fill",
                                       tint: Theme.negative, keywords: "screen recording end finish save") {
                capture.stopRecording()
            })
        }

        if timers.isActive {
            if timers.isRunning {
                list.append(PaletteCommand(id: "timer-pause", title: "Pause the timer", symbol: "pause.fill",
                                           keywords: "stop hold") { timers.pause() })
            } else {
                list.append(PaletteCommand(id: "timer-resume", title: "Resume the timer", symbol: "play.fill",
                                           keywords: "continue start") { timers.resume() })
            }
            list.append(PaletteCommand(id: "timer-reset", title: "Cancel the timer", symbol: "xmark",
                                       keywords: "stop reset end") { timers.reset() })
        } else {
            list.append(PaletteCommand(id: "focus", title: "Start a focus session",
                                       subtitle: "\(Int(TimerService.focusMinutes)) minutes",
                                       symbol: TimerKind.focus.symbol, tint: TimerKind.focus.tint,
                                       keywords: "pomodoro timer work") {
                timers.start(.focus, seconds: TimerService.focusMinutes * 60)
                actions.select(moduleID: "timers")
            })
            list.append(PaletteCommand(id: "break", title: "Take a short break",
                                       subtitle: "\(Int(TimerService.shortBreakMinutes)) minutes",
                                       symbol: TimerKind.shortBreak.symbol, tint: TimerKind.shortBreak.tint,
                                       keywords: "pomodoro timer rest") {
                timers.start(.shortBreak, seconds: TimerService.shortBreakMinutes * 60)
            })
        }

        if let playing = media.nowPlaying {
            list.append(PaletteCommand(id: "media-toggle", title: playing.isPlaying ? "Pause music" : "Play music",
                                       subtitle: playing.title,
                                       symbol: playing.isPlaying ? "pause.fill" : "play.fill",
                                       keywords: "pause play resume song track now playing") { media.togglePlayPause() })
            list.append(PaletteCommand(id: "media-next", title: "Next track", symbol: "forward.fill",
                                       keywords: "skip song music") { media.next() })
            list.append(PaletteCommand(id: "media-previous", title: "Previous track", symbol: "backward.fill",
                                       keywords: "back song music") { media.previous() })
        }

        for (index, module) in ModuleRegistry.visibleNow.enumerated() {
            list.append(PaletteCommand(id: "go-\(module.id)", title: "Go to \(module.title)",
                                       subtitle: index < 9 ? "⌘\(index + 1)" : nil,
                                       symbol: module.symbol, keywords: module.id + " open show") {
                actions.select(moduleID: module.id)
            })
        }

        let life = LifeService.shared
        for (arc, habit) in life.liveArcs.flatMap({ arc in arc.habits.map { (arc, $0) } })
        where life.isDue(habit) {
            list.append(PaletteCommand(id: "checkin-\(habit.id)", title: "Check in on \(habit.title)",
                                       subtitle: arc.name, symbol: "circle.circle",
                                       tint: arc.colour.color, keywords: "habit arc streak done life") {
                life.toggleCheckIn(habit, in: arc)
            })
        }
        for task in life.tasks(on: LifeService.today).filter({ !$0.isDone }).prefix(3) {
            list.append(PaletteCommand(id: "tick-\(task.id)", title: "Tick off \(task.title)",
                                       subtitle: "Today", symbol: "checkmark.circle",
                                       keywords: "todo task done finish life") {
                life.toggle(task)
            })
        }
        list.append(PaletteCommand(id: "new-arc", title: "Start a new arc", symbol: "target",
                                   keywords: "life goal habit milestone lock in") {
            actions.select(moduleID: "life")
        })

        list.append(PaletteCommand(id: "shot-area", title: "Screenshot an area", symbol: CaptureTarget.area.symbol,
                                   tint: CaptureService.tint, keywords: "capture screen grab snip selection") {
            capture.takeScreenshot(.area)
        })
        list.append(PaletteCommand(id: "shot-window", title: "Screenshot a window", symbol: CaptureTarget.window.symbol,
                                   tint: CaptureService.tint, keywords: "capture screen grab snip") {
            capture.takeScreenshot(.window)
        })
        list.append(PaletteCommand(id: "shot-screen", title: "Screenshot the screen", symbol: CaptureTarget.screen.symbol,
                                   tint: CaptureService.tint, keywords: "capture display grab whole full") {
            capture.takeScreenshot(.screen)
        })
        if !capture.isRecording, CaptureService.canRecord {
            for target in CaptureTarget.allCases {
                let what = switch target {
                case .area: "an area"
                case .window: "a window"
                case .screen: "the screen"
                }
                list.append(PaletteCommand(id: "record-\(target.rawValue)", title: "Record \(what)",
                                           symbol: "record.circle", tint: Theme.negative,
                                           keywords: "screen recording video capture movie") {
                    capture.startRecording(target)
                })
            }
        }
        list.append(PaletteCommand(id: "captures-folder", title: "Open the captures folder", symbol: "folder",
                                   keywords: "screenshots recordings pictures finder") { capture.openFolder() })

        list.append(PaletteCommand(id: "stopwatch",
                                   title: timers.isStopwatchRunning ? "Stop the stopwatch" : "Start the stopwatch",
                                   symbol: "stopwatch", keywords: "timer lap") { timers.toggleStopwatch() })

        if !ShelfService.shared.items.isEmpty {
            list.append(PaletteCommand(id: "shelf-clear", title: "Clear the shelf", symbol: "tray",
                                       keywords: "files remove empty") { ShelfService.shared.removeAll() })
        }

        let store = ThemeStore.shared
        for palette in store.choices where palette.id != store.selectedID {
            list.append(PaletteCommand(id: "theme-\(palette.id)", title: "Use the \(palette.name) theme",
                                       symbol: "paintpalette", tint: palette.accent.color,
                                       keywords: "appearance colour color look") { store.select(palette.id) }
            )
        }

        list.append(PaletteCommand(id: "pin", title: actions.isPinned ? "Unpin the notch" : "Keep the notch open",
                                   symbol: "pin", keywords: "pin unpin stay") { actions.togglePin() })
        list.append(PaletteCommand(id: "close", title: "Close the notch", symbol: "chevron.up",
                                   keywords: "hide dismiss") { actions.closeNotch() })
        return list
    }

    private static func clipboardMatches(for text: String) -> [PaletteCommand] {
        guard text.count >= 2 else { return [] }
        return ClipboardService.shared.items
            .filter { ($0.kind == .text || $0.kind == .link) && ($0.text ?? "").localizedCaseInsensitiveContains(text) }
            .prefix(3)
            .map { item in
                PaletteCommand(id: "clip-\(item.id)", title: "Copy “\(item.preview.prefix(60))”",
                               subtitle: "Clipboard", symbol: item.kind == .link ? "link" : "doc.on.clipboard",
                               tint: Theme.accent) {
                    ClipboardService.shared.copy(item)
                }
            }
    }

    // MARK: - Matching

    /// Higher is better; nil means no match.
    static func score(_ command: PaletteCommand, for query: String) -> Int? {
        let title = command.title.lowercased()
        let needle = query.lowercased()
        if let range = title.range(of: needle) {
            let wordStart = range.lowerBound == title.startIndex || title[title.index(before: range.lowerBound)] == " "
            return 300 - title.distance(from: title.startIndex, to: range.lowerBound) + (wordStart ? 50 : 0)
        }
        let words = needle.split(separator: " ")
        let haystack = title + " " + command.keywords.lowercased()
        if words.allSatisfy({ haystack.contains($0) }) {
            return 150
        }
        // Letters in order, like "gcal" for "Go to Calendar".
        var index = title.startIndex
        var gaps = 0
        for character in needle where character != " " {
            guard let found = title[index...].firstIndex(of: character) else { return nil }
            gaps += title.distance(from: index, to: found)
            index = title.index(after: found)
        }
        // Letters scattered across the title aren't a match.
        guard gaps <= max(4, needle.count * 2) else { return nil }
        return max(1, 100 - gaps)
    }

    /// "10", "10m", "timer 10 min", "90s", "1h".
    static func duration(in text: String) -> TimeInterval? {
        let pattern = /^(?:timer\s*)?(\d{1,3})\s*(s|sec|secs|seconds?|m|min|mins|minutes?|h|hr|hrs|hours?)?$/
            .ignoresCase()
        guard let match = text.wholeMatch(of: pattern), let value = Double(match.1), value > 0 else { return nil }
        let unit = match.2.map { $0.lowercased() } ?? "m"
        let seconds: Double = switch unit.first {
        case "s": value
        case "h": value * 3600
        default: value * 60
        }
        return seconds <= 24 * 3600 ? seconds : nil
    }

    static func describe(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))-second" }
        if seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))-hour" }
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))-minute" }
        return Format.clock(seconds)
    }
}

// MARK: - View

struct CommandPaletteView: View {
    let model: NotchViewModel
    let actions: any NotchActions
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        @Bindable var palette = model.palette
        let commands = CommandCatalog.commands(for: palette.query, actions: actions)

        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiaryInk)
                if snapshotMode {
                    Text(palette.query.isEmpty ? Self.placeholder : palette.query)
                        .foregroundStyle(palette.query.isEmpty ? Theme.tertiaryInk : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(Self.placeholder, text: $palette.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .accessibilityLabel("Command")
                }
                KeyHint("esc")
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .frame(height: 42)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            if commands.isEmpty {
                Text("Nothing matches “\(palette.query)”. Try a module name, “10 min” or text you copied.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        PaletteRow(command: command, isSelected: index == palette.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { actions.run(command) }
                            .onHover { inside in
                                if inside { palette.selection = index }
                            }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 430)
        .background(PaletteBackground())
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private static let placeholder = "Type a command or search your clipboard"
}

private struct PaletteBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.fill))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(command.tint ?? Theme.secondaryInk)
                .frame(width: 24, height: 24)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7))
            Text(command.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
            }
            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Theme.selection : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

struct KeyHint: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.tertiaryInk)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            .accessibilityHidden(true)
    }
}
