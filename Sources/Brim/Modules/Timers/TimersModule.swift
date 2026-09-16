import SwiftUI

@MainActor
final class TimersModule: NotchModule {
    let id = "timers"
    let title = "Timers"
    let symbol = "timer"
    func expandedView() -> AnyView { AnyView(TimersView()) }
}

private enum TimerTab: String, CaseIterable {
    case focus = "Focus"
    case timer = "Timer"
    case stopwatch = "Stopwatch"
}

private struct TimersView: View {
    @State private var tab: TimerTab = TimerService.shared.kind == .countdown ? .timer
        : (TimerService.shared.isStopwatchRunning && !TimerService.shared.isActive ? .stopwatch : .focus)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(TimerTab.allCases, id: \.self) { item in
                    Button(item.rawValue) {
                        withAnimation(Motion.switchModule) { tab = item }
                    }
                    .buttonStyle(PillButtonStyle(tint: Theme.ink, prominent: tab == item))
                }
            }
            Group {
                switch tab {
                case .focus: FocusPane()
                case .timer: CountdownPane()
                case .stopwatch: StopwatchPane()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct Ring: View {
    let progress: Double
    let tint: Color
    let label: String
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: 9)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 6)
            }
            Text(label)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: size, height: size)
    }
}

private struct FocusPane: View {
    private var timers: TimerService { .shared }

    var body: some View {
        let isPomodoro = timers.kind != nil && timers.kind != .countdown
        let kind = isPomodoro ? timers.kind! : timers.nextPomodoro
        HStack(spacing: 26) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = isPomodoro ? timers.remaining(at: context.date) : defaultSeconds(kind)
                Ring(progress: isPomodoro ? timers.progress(at: context.date) : 0,
                     tint: kind.tint,
                     label: Format.clock(remaining))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.title)
                    .font(.system(size: 19, weight: .semibold))
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < timers.focusSessionsDone % 4 || (timers.focusSessionsDone > 0 && timers.focusSessionsDone % 4 == 0)
                                  ? Theme.accent : Theme.raisedFill)
                            .frame(width: 7, height: 7)
                    }
                    Text(timers.focusSessionsDone == 1 ? "1 session done" : "\(timers.focusSessionsDone) sessions done")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.leading, 4)
                }
                Text(caption(kind))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !isPomodoro {
                        Button { timers.startPomodoro() } label: {
                            Label("Start \(kind.title.lowercased())", systemImage: "play.fill")
                        }
                        .buttonStyle(PillButtonStyle(tint: kind.tint))
                        if kind != .focus {
                            Button("Skip break") { timers.skipBreak() }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    } else {
                        RunControls()
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func defaultSeconds(_ kind: TimerKind) -> TimeInterval {
        switch kind {
        case .focus: TimerService.focusMinutes * 60
        case .shortBreak: TimerService.shortBreakMinutes * 60
        default: TimerService.longBreakMinutes * 60
        }
    }

    private func caption(_ kind: TimerKind) -> String {
        switch kind {
        case .focus: "25 minutes of focus, then a short break. Every fourth break is longer."
        case .shortBreak: "Five minutes. Stand up, look away from the screen."
        case .longBreak: "Fifteen minutes. You've earned it."
        case .countdown: ""
        }
    }
}

/// Pause / resume / reset for whichever countdown is running.
private struct RunControls: View {
    private var timers: TimerService { .shared }

    var body: some View {
        if timers.isRunning {
            Button { timers.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                .buttonStyle(PillButtonStyle(tint: timers.kind?.tint ?? Theme.accent))
        } else {
            Button { timers.resume() } label: { Label("Resume", systemImage: "play.fill") }
                .buttonStyle(PillButtonStyle(tint: timers.kind?.tint ?? Theme.accent))
        }
        Button("Reset") { timers.reset() }
            .buttonStyle(PillButtonStyle(prominent: false))
    }
}

private struct CountdownPane: View {
    @AppStorage("countdownMinutes") private var minutes = 10
    private var timers: TimerService { .shared }
    private let presets = [1, 3, 5, 10, 15, 30, 45, 60]

    var body: some View {
        let isCountdown = timers.kind == .countdown
        HStack(spacing: 26) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Ring(progress: isCountdown ? timers.progress(at: context.date) : 0,
                     tint: TimerKind.countdown.tint,
                     label: Format.clock(isCountdown ? timers.remaining(at: context.date) : Double(minutes * 60)))
            }
            VStack(alignment: .leading, spacing: 10) {
                if isCountdown {
                    Text("Timer running")
                        .font(.system(size: 19, weight: .semibold))
                    HStack(spacing: 8) { RunControls() }
                } else {
                    HStack(spacing: 10) {
                        Button { minutes = max(1, minutes - 1) } label: { Image(systemName: "minus") }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel("One minute less")
                        Text("\(minutes) min")
                            .font(.system(size: 19, weight: .semibold))
                            .monospacedDigit()
                            .frame(minWidth: 72)
                        Button { minutes = min(600, minutes + 1) } label: { Image(systemName: "plus") }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel("One minute more")
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(presets, id: \.self) { preset in
                            Button("\(preset)m") { minutes = preset }
                                .buttonStyle(PillButtonStyle(tint: TimerKind.countdown.tint, prominent: preset == minutes))
                        }
                    }
                    Button { timers.start(.countdown, seconds: Double(minutes * 60)) } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: TimerKind.countdown.tint))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StopwatchPane: View {
    private var timers: TimerService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.animation(minimumInterval: 0.05, paused: !timers.isStopwatchRunning)) { context in
                    Text(stopwatchText(timers.stopwatchElapsed(at: context.date)))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button { timers.toggleStopwatch() } label: {
                        Label(timers.isStopwatchRunning ? "Pause" : "Start",
                              systemImage: timers.isStopwatchRunning ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: TimerKind.countdown.tint))
                    Button("Lap") { timers.lap() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .disabled(!timers.isStopwatchRunning)
                    Button("Reset") { timers.resetStopwatch() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            Tile {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Laps")
                    if timers.laps.isEmpty {
                        Text("Press Lap while it runs.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        NotchScroll {
                            VStack(spacing: 4) {
                                ForEach(Array(timers.laps.enumerated()), id: \.offset) { index, lap in
                                    HStack {
                                        Text("Lap \(timers.laps.count - index)")
                                            .foregroundStyle(Theme.secondaryInk)
                                        Spacer()
                                        Text(stopwatchText(lap))
                                    }
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 200)
        }
    }

    private func stopwatchText(_ elapsed: TimeInterval) -> String {
        let hundredths = Int(elapsed * 100) % 100
        return Format.clock(floor(elapsed)) + String(format: ".%02d", hundredths)
    }
}
