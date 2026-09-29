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

    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .timer: "timer"
        case .stopwatch: "stopwatch"
        }
    }
}

/// Three columns for the wide notch: the modes down the left, the ring or the
/// digits in the middle, and details with the controls on the right. The
/// controls sit in the same place whichever mode is showing.
private struct TimersView: View {
    @State private var tab: TimerTab = TimerService.shared.kind == .countdown ? .timer
        : (TimerService.shared.isStopwatchRunning && !TimerService.shared.isActive ? .stopwatch : .focus)
    @Namespace private var segment
    private var timers: TimerService { .shared }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TimerTab.allCases, id: \.self) { item in
                    modeButton(item)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 128)
            Rectangle()
                .fill(Theme.fill)
                .frame(width: 1)
                .padding(.vertical, 4)
            Group {
                switch tab {
                case .focus: FocusPane()
                case .timer: CountdownPane()
                case .stopwatch: StopwatchPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isLive(_ item: TimerTab) -> Bool {
        switch item {
        case .focus: timers.isActive && timers.kind != .countdown
        case .timer: timers.kind == .countdown
        case .stopwatch: timers.isStopwatchRunning
        }
    }

    private func modeButton(_ item: TimerTab) -> some View {
        let isOn = tab == item
        return Button {
            withAnimation(Motion.switchModule) { tab = item }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: .semibold, design: Theme.fontDesign))
                Spacer(minLength: 0)
                // Something is counting in this mode while you look at another.
                if isLive(item) {
                    Circle()
                        .fill(item == .focus ? (timers.kind?.tint ?? Theme.accent) : TimerKind.countdown.tint)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(isOn ? Theme.ink : Theme.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.raisedFill)
                        .matchedGeometryEffect(id: "mode", in: segment)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .debugFrame("timers.\(item.rawValue.lowercased())")
    }
}

/// A pane's two halves: what's counting in the middle, details and controls on the right.
private struct PaneLayout<Display: View, Details: View, Controls: View>: View {
    @ViewBuilder var display: Display
    @ViewBuilder var details: Details
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 18) {
            display
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                details
                Spacer(minLength: 0)
                HStack(spacing: 10) { controls }
            }
            .frame(width: 250, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// The countdown ring, with the time and what it's counting inside.
private struct Ring: View {
    let progress: Double
    let tint: Color
    let label: String
    var caption: String?
    var size: CGFloat = 124

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: 8)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 6)
            }
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                if let caption {
                    Text(caption.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

/// The big round start / pause button.
private struct PlayButton: View {
    let isRunning: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(RGBA(tint).onColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint))
                .xotchGloss(Circle(), strength: 0.6)
                .shadow(color: tint.opacity(0.45), radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isRunning ? "Pause" : "Start")
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// "Ends at 3:42 PM", which is what you actually want to know about a timer.
private func endsAt(_ remaining: TimeInterval, at date: Date) -> String {
    "Ends at " + date.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
}

private struct FocusPane: View {
    private var timers: TimerService { .shared }

    var body: some View {
        let isPomodoro = timers.kind != nil && timers.kind != .countdown
        let kind = isPomodoro ? timers.kind! : timers.nextPomodoro
        let done = timers.focusSessionsDone
        // Sessions finished in this round of four. After the fourth, the long
        // break still shows the round full; the next focus starts a new one.
        let filled = kind != .focus && done > 0 && done % 4 == 0 ? 4 : done % 4
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = isPomodoro ? timers.remaining(at: context.date) : defaultSeconds(kind)
            PaneLayout {
                Ring(progress: isPomodoro ? timers.progress(at: context.date) : 0,
                     tint: kind.tint,
                     label: Format.clock(remaining),
                     caption: kind.title,
                     size: 150)
            } details: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind == .focus ? "Session \(filled + 1) of 4" : kind.title)
                        .font(.system(size: 19, weight: .semibold))
                    Text(subtitle(kind, isPomodoro: isPomodoro, remaining: remaining, at: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index < filled ? Theme.accent : Theme.raisedFill)
                            .frame(width: 30, height: 5)
                    }
                    Text("\(done) done")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryInk)
                        .padding(.leading, 6)
                }
            } controls: {
                PlayButton(isRunning: timers.isRunning, tint: kind.tint) {
                    if !isPomodoro { timers.startPomodoro() }
                    else if timers.isRunning { timers.pause() }
                    else { timers.resume() }
                }
                if isPomodoro {
                    Button { timers.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(IconButtonStyle(size: 32))
                        .accessibilityLabel("Reset")
                }
                if kind != .focus {
                    Button { timers.skipBreak() } label: { Image(systemName: "forward.end.fill") }
                        .buttonStyle(IconButtonStyle(size: 32))
                        .help("Skip the break")
                        .accessibilityLabel("Skip break")
                }
            }
        }
    }

    private func defaultSeconds(_ kind: TimerKind) -> TimeInterval {
        switch kind {
        case .focus: TimerService.focusMinutes * 60
        case .shortBreak: TimerService.shortBreakMinutes * 60
        default: TimerService.longBreakMinutes * 60
        }
    }

    private func subtitle(_ kind: TimerKind, isPomodoro: Bool, remaining: TimeInterval, at date: Date) -> String {
        if isPomodoro {
            return timers.isRunning ? endsAt(remaining, at: date) : "Paused"
        }
        switch kind {
        case .focus: return "25 minutes, then a 5-minute break"
        case .shortBreak: return "5 minutes. Stand up, look away."
        case .longBreak: return "15 minutes. You've earned it."
        case .countdown: return ""
        }
    }
}

private struct CountdownPane: View {
    @AppStorage("countdownMinutes") private var minutes = 10
    private var timers: TimerService { .shared }
    private let presets = [1, 3, 5, 10, 15, 30, 45, 60]

    var body: some View {
        let isCountdown = timers.kind == .countdown
        let tint = TimerKind.countdown.tint
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = isCountdown ? timers.remaining(at: context.date) : Double(minutes * 60)
            PaneLayout {
                Ring(progress: isCountdown ? timers.progress(at: context.date) : 0,
                     tint: tint,
                     label: Format.clock(remaining),
                     caption: isCountdown ? (timers.isRunning ? "Running" : "Paused") : "Timer",
                     size: 150)
            } details: {
                if isCountdown {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int((timers.total / 60).rounded()))-minute timer")
                            .font(.system(size: 19, weight: .semibold))
                        Text(timers.isRunning ? endsAt(remaining, at: context.date) : "Paused")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                    }
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
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 4),
                              alignment: .leading, spacing: 6) {
                        ForEach(presets, id: \.self) { preset in
                            Button("\(preset) min") { minutes = preset }
                                .buttonStyle(ChipStyle(isOn: preset == minutes, tint: tint))
                        }
                    }
                }
            } controls: {
                PlayButton(isRunning: isCountdown && timers.isRunning, tint: tint) {
                    if !isCountdown { timers.start(.countdown, seconds: Double(minutes * 60)) }
                    else if timers.isRunning { timers.pause() }
                    else { timers.resume() }
                }
                if isCountdown {
                    Button { timers.reset() } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 32))
                        .accessibilityLabel("Cancel timer")
                }
            }
        }
    }
}

/// A small round-cornered preset, filled when chosen.
private struct ChipStyle: ButtonStyle {
    let isOn: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isOn ? RGBA(tint).onColor : Theme.ink)
            .frame(width: 56, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn ? tint : Theme.fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

private struct StopwatchPane: View {
    private var timers: TimerService { .shared }

    var body: some View {
        let tint = TimerKind.countdown.tint
        PaneLayout {
            TimelineView(.animation(minimumInterval: 0.05, paused: !timers.isStopwatchRunning)) { context in
                Text(stopwatchText(timers.stopwatchElapsed(at: context.date)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } details: {
            SectionLabel("Laps")
            if timers.laps.isEmpty {
                Text("Press the flag while it runs.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                let splits = lapDurations
                let fastest = splits.count >= 3 ? splits.min() : nil
                let slowest = splits.count >= 3 ? splits.max() : nil
                NotchScroll {
                    VStack(spacing: 4) {
                        ForEach(Array(splits.enumerated()), id: \.offset) { index, split in
                            HStack {
                                Text("Lap \(splits.count - index)")
                                    .foregroundStyle(Theme.secondaryInk)
                                Spacer()
                                Text(stopwatchText(split))
                                    .foregroundStyle(split == fastest ? Theme.positive
                                                     : split == slowest ? Theme.negative : Theme.ink)
                            }
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
        } controls: {
            PlayButton(isRunning: timers.isStopwatchRunning, tint: tint) { timers.toggleStopwatch() }
            Button { timers.lap() } label: { Image(systemName: "flag.fill") }
                .buttonStyle(IconButtonStyle(size: 32))
                .disabled(!timers.isStopwatchRunning)
                .accessibilityLabel("Lap")
            Button { timers.resetStopwatch() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(IconButtonStyle(size: 32))
                .accessibilityLabel("Reset")
        }
    }

    /// Each lap's own time. `laps` holds the running total at each press, newest first.
    private var lapDurations: [TimeInterval] {
        let laps = timers.laps
        return laps.indices.map { index in
            laps[index] - (index + 1 < laps.count ? laps[index + 1] : 0)
        }
    }

    private func stopwatchText(_ elapsed: TimeInterval) -> String {
        guard elapsed.isFinite else { return "0:00.00" }
        let hundredths = Int((elapsed * 100).truncatingRemainder(dividingBy: 100))
        return Format.clock(floor(elapsed)) + String(format: ".%02ld", hundredths)
    }
}
