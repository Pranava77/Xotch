import SwiftUI

/// The hours of the week, drawn as a grid: the fixed routine faint in the
/// background, this week's timed to-dos solid in front of it.

/// Minutes to points, shared by the ruler, the lanes and the now line.
struct TimetableMetrics: Equatable {
    /// An hour is this tall. Sixteen of them is more than the notch can show
    /// at once, which is why the grid scrolls.
    static let hourHeight: CGFloat = 28
    /// The hours the week starts and ends on when nothing falls outside them.
    static let defaultFirstHour = 7
    static let defaultLastHour = 23

    let firstHour: Int
    let lastHour: Int

    /// Widens the usual 07:00–23:00 to hold anything earlier or later, so a
    /// 06:00 lecture or a midnight shift is never hidden above the scroll.
    init(slots: [TimetableEntry], tasks: [LifeTask]) {
        var first = Self.defaultFirstHour
        var last = Self.defaultLastHour
        for start in slots.map(\.start) + tasks.compactMap(\.time) {
            first = min(first, start / 60)
            last = max(last, start / 60 + 1)
        }
        for end in slots.map(\.end) {
            last = max(last, Int((Double(end) / 60).rounded(.up)))
        }
        firstHour = max(0, first)
        lastHour = min(24, max(last, first + 1))
    }

    var hours: [Int] { Array(firstHour..<lastHour) }
    var height: CGFloat { CGFloat(lastHour - firstHour) * Self.hourHeight }

    /// Where a minute of the day sits, measured from the top of the grid.
    func y(_ minutes: Int) -> CGFloat {
        CGFloat(minutes - firstHour * 60) / 60 * Self.hourHeight
    }

    func height(ofMinutes minutes: Int) -> CGFloat {
        max(14, CGFloat(minutes) / 60 * Self.hourHeight)
    }
}

/// The hours down the left, each label sitting on its own line.
struct TimetableRuler: View {
    let metrics: TimetableMetrics
    static let width: CGFloat = 34

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(metrics.hours, id: \.self) { hour in
                Text(LifeTime.label(hour * 60))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(height: TimetableMetrics.hourHeight, alignment: .top)
                    .id(hour)
            }
        }
        .frame(width: Self.width, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// One line per hour, behind every lane at once.
struct TimetableHourLines: View {
    let metrics: TimetableMetrics

    var body: some View {
        Canvas { context, size in
            for (index, _) in metrics.hours.enumerated() {
                let y = CGFloat(index) * TimetableMetrics.hourHeight
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Theme.ink.opacity(index == 0 ? 0.12 : 0.06)),
                               lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One day's column of the grid.
struct TimetableLane: View {
    let day: Date
    let metrics: TimetableMetrics
    /// True while the routine is being edited: the slots come forward and the
    /// to-dos step back, so what you're changing is what you can see.
    let routineForward: Bool
    private var life: LifeService { .shared }

    var body: some View {
        let isToday = day == LifeService.today
        let slots = life.slots(onDay: day)
        let timed = life.tasks(on: day).filter { $0.time != nil }

        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                SlotBlock(slot: slot, forward: routineForward)
                    .frame(height: metrics.height(ofMinutes: slot.length), alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: metrics.y(slot.start))
            }
            ForEach(timed) { task in
                TimedTaskBlock(task: task, faded: routineForward)
                    // Inset, so the routine block it sits on still shows its edge.
                    .padding(.leading, slots.isEmpty ? 0 : 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: metrics.y(task.time ?? 0))
            }
            if isToday {
                NowLine(metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity, minHeight: metrics.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isToday ? Theme.ink.opacity(0.05) : .clear)
            .allowsHitTesting(false))
    }
}

/// Where we are in the day, on today's lane only.
private struct NowLine: View {
    let metrics: TimetableMetrics

    var body: some View {
        TimelineView(.everyMinute) { context in
            let parts = LifeService.calendar.dateComponents([.hour, .minute], from: context.date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if minutes >= metrics.firstHour * 60, minutes <= metrics.lastHour * 60 {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .offset(y: metrics.y(minutes))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A fixed weekly slot: the same every week, and never ticked.
private struct SlotBlock: View {
    let slot: TimetableEntry
    let forward: Bool
    private var life: LifeService { .shared }

    var body: some View {
        let tint = life.arc(id: slot.arcID)?.colour.color ?? Theme.ink
        VStack(alignment: .leading, spacing: 0) {
            Text(slot.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            if slot.length >= 45 {
                Text(LifeTime.label(slot.start))
                    .font(.system(size: 8))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tertiaryInk)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink.opacity(forward ? 0.9 : 0.55))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(forward ? 0.3 : 0.14)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(tint.opacity(forward ? 0.9 : 0.5))
                .frame(width: 2)
                .padding(.vertical, 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .help("\(slot.title) · \(LifeTime.span(start: slot.start, length: slot.length)) · every week")
        .contextMenu { SlotMenu(slot: slot) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.title), \(LifeTime.span(start: slot.start, length: slot.length)), every week")
    }
}

/// A to-do that happens at a time this week, in front of the routine.
private struct TimedTaskBlock: View {
    let task: LifeTask
    let faded: Bool
    private var life: LifeService { .shared }

    var body: some View {
        let tint = life.arc(id: task.arcID)?.colour.color ?? Theme.accent
        Button { life.toggle(task) } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(task.isDone ? Theme.tertiaryInk : tint)
                    .frame(width: 5, height: 5)
                Text(task.title)
                    .font(.system(size: 10))
                    .strikethrough(task.isDone, color: Theme.tertiaryInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raisedFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(faded ? 0.45 : 1)
        .help("\(LifeTime.label(task.time ?? 0)) · click to tick off, right-click to move it")
        .modifier(TaskDragger(task: task))
        .contextMenu { TaskMenu(task: task) }
    }
}

/// What you can do to a slot: move it to another day, or drop it.
struct SlotMenu: View {
    let slot: TimetableEntry
    private var life: LifeService { .shared }

    var body: some View {
        Text(LifeTime.span(start: slot.start, length: slot.length))
        Divider()
        ForEach(life.week(), id: \.self) { day in
            let weekday = LifeService.calendar.component(.weekday, from: day)
            Button(day.formatted(.dateTime.weekday(.wide))) { life.move(slot, to: weekday) }
                .disabled(weekday == slot.weekday)
        }
        Divider()
        Button("Remove from the routine", role: .destructive) { life.remove(slot) }
    }
}
