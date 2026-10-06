import SwiftUI

@MainActor
final class HomeModule: NotchModule {
    let id = "home"
    let title = "Home"
    let symbol = "house"
    /// Wider when the mascot has its own tile, so nothing else shrinks.
    var openSize: CGSize {
        AppSettings.homeMascot ? CGSize(width: 860, height: Layout.openSize.height) : Layout.openSize
    }
    func expandedView() -> AnyView { AnyView(HomeView()) }
}

/// A summary of the other modules as live tiles: a large one for what's
/// playing (or the time), and small ones for the next meeting, the focus
/// timer, to-dos and Claude. Each tile opens its module.
private struct HomeView: View {
    private var media: MediaService { .shared }
    private var calendar: CalendarService { .shared }
    private var timers: TimerService { .shared }
    private var todos: TodoService { .shared }
    private var claude: ClaudeLiveService { .shared }
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""
    @AppStorage(SettingsKey.homeMascot) private var homeMascot = true
    @AppStorage(SettingsKey.mascotCharacter) private var mascotCharacter = "fox"
    @Environment(\.snapshotDate) private var snapshotDate

    var body: some View {
        let hidden = Set(hiddenModules.split(separator: ",").map(String.init))
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let playing = media.nowPlaying, !hidden.contains("media") {
                    mediaTile(playing)
                } else {
                    clockTile
                }
            }
            .frame(width: 300)
            if homeMascot {
                mascotTile
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                if !hidden.contains("calendar") { nextEventTile }
                if !hidden.contains("timers") { timerTile }
                if !hidden.contains("todos") { todosTile }
                if !hidden.contains("claude") { claudeTile }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            calendar.refresh()
        }
    }

    // MARK: Large tile

    private var clockTile: some View {
        HomeTile(moduleID: "calendar", height: 184) {
            TimelineView(.everyMinute) { context in
                let date = snapshotDate ?? context.date
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 50, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    /// The page mascot in a tile of its own, standing on the bottom edge and
    /// watching the pointer. A click boops it; it doesn't open a module.
    private var mascotTile: some View {
        let character = MascotCharacter.all.first { $0.id == mascotCharacter } ?? MascotCharacter.all[0]
        return Button { MascotTracker.shared.boop("home") } label: {
            ZStack(alignment: .bottom) {
                MascotView(anchor: "home", size: 132, character: character)
                    .offset(y: 6)
                Text(character.name.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
            }
            .frame(width: 150, height: 184)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Boop \(character.name)")
        .debugFrame("home.mascot")
    }

    private func mediaTile(_ playing: NowPlaying) -> some View {
        HomeTile(moduleID: "media", height: 184) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Artwork(image: media.artwork, tint: media.tint, size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playing.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        Text(playing.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Ticks only while the song plays, so a paused track costs nothing.
                TimelineView(.animation(minimumInterval: 1, paused: !playing.isPlaying)) { context in
                    let fraction = playing.duration > 0 ? playing.position(at: context.date) / playing.duration : 0
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.raisedFill)
                            Capsule().fill(Theme.ink)
                                .frame(width: geo.size.width * min(max(fraction, 0), 1))
                        }
                    }
                    .frame(height: 4)
                }
                HStack(spacing: 18) {
                    Spacer()
                    Button { media.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                    Button { media.togglePlayPause() } label: {
                        Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
                    .debugFrame("home.playpause")
                    Button { media.next() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next")
                        .debugFrame("home.next")
                    Spacer()
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Small tiles

    private var nextEventTile: some View {
        HomeTile(moduleID: "calendar") {
            let event = calendar.nextEvent
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(event?.calendarColor.color ?? Theme.tertiaryInk)
                        .frame(width: 6, height: 6)
                    SectionLabel(event.map { $0.start <= .now ? "Now" : $0.start.formatted(date: .omitted, time: .shortened) } ?? "Up next")
                    Spacer(minLength: 0)
                    if let url = event?.joinURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Text("Join")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(RGBA(Theme.positive).onColor)
                                .padding(.horizontal, 8)
                                .frame(height: 18)
                                .background(Capsule().fill(Theme.positive))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                Text(event?.title ?? (calendar.needsAccess ? "Connect your calendar" : "Nothing else this week"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let event {
                    Text(event.start <= .now ? "Happening now" : event.start.formatted(.relative(presentation: .named)).capitalizedFirst)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
            }
        }
    }

    private var timerTile: some View {
        HomeTile(moduleID: "timers") {
            // Ticks only while something is counting; an idle tile stays still.
            TimelineView(.animation(minimumInterval: 1, paused: !timers.isRunning && !timers.isStopwatchRunning)) { context in
                let kind = timers.kind ?? timers.nextPomodoro
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(kind.tint)
                        SectionLabel(kind.title)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .lastTextBaseline) {
                        if timers.isActive {
                            Text(Format.clock(timers.remaining(at: context.date)))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(kind.tint)
                            Text(timers.isRunning ? "left" : "paused")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        } else if timers.isStopwatchRunning {
                            Text(Format.clock(timers.stopwatchElapsed(at: context.date)))
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("stopwatch")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                        } else {
                            Text("\(Int(TimerService.focusMinutes)) min")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                            Spacer(minLength: 0)
                            Button { timers.startPomodoro() } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(RGBA(kind.tint).onColor)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(kind.tint))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Start \(kind.title.lowercased())")
                        }
                    }
                }
            }
        }
    }

    private var todosTile: some View {
        HomeTile(moduleID: "todos") {
            let open = todos.todos(on: TodoService.today).filter { !$0.isDone }
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel("To-dos")
                Spacer(minLength: 0)
                Text(open.isEmpty ? "All done today" : open.count == 1 ? "1 left today" : "\(open.count) left today")
                    .font(.system(size: 13, weight: .semibold))
                if let first = open.first {
                    Text(first.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
            }
        }
    }

    private var claudeTile: some View {
        HomeTile(moduleID: "claude") {
            let session = claude.sessions.first
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ClaudeLiveService.tint)
                    SectionLabel("Claude Code")
                }
                Spacer(minLength: 0)
                Text(session?.stateLabel ?? (claude.hookInstalled ? "No live sessions" : "Usage and streak"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.map { if case .waiting = $0.state { ClaudeLiveService.tint } else { Theme.ink } } ?? Theme.ink)
                    .lineLimit(1)
                if let session {
                    Text(session.project)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A rounded tile that opens its module when clicked.
private struct HomeTile<Content: View>: View {
    let moduleID: String
    var height: CGFloat = 87
    @ViewBuilder var content: Content

    var body: some View {
        Button { ScreenManager.shared.show(moduleID: moduleID) } label: {
            content
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
