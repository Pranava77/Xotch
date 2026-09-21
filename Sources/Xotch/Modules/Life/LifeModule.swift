import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LifeModule: NotchModule {
    let id = "life"
    let title = "Life"
    let symbol = "square.grid.3x3.fill"
    var openSize: CGSize { Layout.wideOpenSize }
    func expandedView() -> AnyView { AnyView(LifeView()) }
    func start() { LifeService.shared.start() }
    func stop() { LifeService.shared.stop() }
}

private enum LifeTab: String, CaseIterable {
    case today = "Today"
    case week = "Week"
    case arcs = "Arcs"
}

private struct LifeView: View {
    @State private var tab: LifeTab
    @State private var selectedDay: Date?
    @State private var editing: Arc?
    private var life: LifeService { .shared }

    init() {
        #if DEBUG
        // Snapshots can open on another tab, with the designer or a past day up.
        _tab = State(initialValue: LifeTab(rawValue: LifeService.debugTab) ?? .today)
        _selectedDay = State(initialValue: LifeService.debugSelectedDay)
        _editing = State(initialValue: LifeService.debugDesigner ? LifeService.shared.liveArcs.first : nil)
        #else
        _tab = State(initialValue: .today)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                switch tab {
                case .today: TodayPane()
                case .week: WeekPane()
                case .arcs: ArcsPane(editing: $editing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(alignment: .top, spacing: 16) {
                LifeGraph(columns: life.graphColumns(),
                          commits: { life.commits(on: $0) },
                          selected: $selectedDay)
                if let selectedDay {
                    LifeDayPanel(day: selectedDay) {
                        withAnimation(Motion.switchModule) { self.selectedDay = nil }
                    }
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 100, alignment: .topLeading)
        }
        .overlay {
            if let arc = editing {
                ArcDesigner(arc: arc) { saved in
                    if let saved { life.save(saved) }
                    withAnimation(Motion.switchModule) { editing = nil }
                }
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .onAppear { life.rolloverIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.dayFormatter.string(from: Date()))
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer(minLength: 8)
            StreakBadge(streak: life.streak)
            HStack(spacing: 4) {
                ForEach(LifeTab.allCases, id: \.self) { item in
                    Button(item.rawValue) {
                        withAnimation(Motion.switchModule) { tab = item }
                    }
                    .buttonStyle(PillButtonStyle(tint: Theme.ink, prominent: tab == item))
                }
            }
        }
    }

    private var summary: String {
        let today = life.commits(on: LifeService.today)
        let week = life.commitsThisWeek()
        let open = life.openToday
        let left = open == 0 ? "nothing left" : (open == 1 ? "1 to do" : "\(open) to do")
        return "\(today) today · \(week) this week · \(left)"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()
}

private struct StreakBadge: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundStyle(streak > 0 ? Theme.accent : Theme.tertiaryInk)
            Text(streak == 1 ? "1 day" : "\(streak) days")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Theme.fill, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Streak: \(streak) days")
    }
}

// MARK: - Today

private struct TodayPane: View {
    @State private var typed = ""
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshotMode
    private var life: LifeService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                AddField(text: $typed, focused: $focused) {
                    life.add(typed)
                    typed = ""
                }
                let tasks = life.tasks(on: LifeService.today)
                if tasks.isEmpty {
                    Text("Nothing planned. Type above, or press ⌘K and say what you're doing.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryInk)
                        .padding(.top, 2)
                } else {
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(tasks) { TaskRow(task: $0) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HabitsColumn()
                .frame(width: 300)
        }
    }
}

private struct AddField: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let submit: () -> Void
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.tertiaryInk)
            if snapshotMode {
                Text(text.isEmpty ? "Add a to-do, #arc to file it" : text)
                    .foregroundStyle(text.isEmpty ? Theme.tertiaryInk : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Add a to-do, #arc to file it", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct TaskRow: View {
    let task: LifeTask
    @State private var hovering = false
    private var life: LifeService { .shared }

    var body: some View {
        let arc = life.arc(id: task.arcID)
        HStack(spacing: 8) {
            Button { life.toggle(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.isDone ? (arc?.colour.color ?? Theme.accent) : Theme.tertiaryInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark \(task.title) not done" : "Finish \(task.title)")

            Text(task.title)
                .font(.system(size: 13))
                .strikethrough(task.isDone, color: Theme.tertiaryInk)
                .foregroundStyle(task.isDone ? Theme.tertiaryInk : Theme.ink)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let arc {
                Text(arc.name)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(arc.colour.color.opacity(0.22), in: Capsule())
                    .foregroundStyle(arc.colour.color)
                    .lineLimit(1)
            }
            if hovering {
                Button { life.delete(task) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .help("Delete")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.fill : .clear))
        .onHover { hovering = $0 }
        .modifier(TaskDragger(task: task))
        .contextMenu { TaskMenu(task: task) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Delete") { life.delete(task) }
    }
}

/// Today's habits from every live arc, with a tick each.
private struct HabitsColumn: View {
    private var life: LifeService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Today's habits")
            let rows = life.liveArcs.flatMap { arc in arc.habits.map { (arc, $0) } }
            if rows.isEmpty {
                Text("Arcs hold the habits you're keeping. Make one in Arcs.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            } else {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows, id: \.1.id) { arc, habit in
                            HabitRow(arc: arc, habit: habit)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct HabitRow: View {
    let arc: Arc
    let habit: Habit
    private var life: LifeService { .shared }

    var body: some View {
        let kept = life.isKept(habit)
        let due = life.isDue(habit)
        HStack(spacing: 8) {
            Button { life.toggleCheckIn(habit, in: arc) } label: {
                Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(kept ? arc.colour.color : (due ? Theme.tertiaryInk : Theme.ink.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kept ? "Undo check-in for \(habit.title)" : "Check in on \(habit.title)")

            VStack(alignment: .leading, spacing: 0) {
                Text(habit.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(arc.name) · \(habit.cadence.label)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if case .timesPerWeek(let target) = habit.cadence {
                Text("\(life.keptThisWeek(habit))/\(target)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(kept ? arc.colour.color.opacity(0.12) : .clear))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Week

private struct WeekPane: View {
    private var life: LifeService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(life.week(), id: \.self) { day in
                DayColumn(day: day)
            }
        }
    }
}

private struct DayColumn: View {
    let day: Date
    @State private var targeted = false
    private var life: LifeService { .shared }

    var body: some View {
        let isToday = day == LifeService.today
        let tasks = life.tasks(on: day)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(Self.weekday.string(from: day).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.tertiaryInk)
                Text(Self.dayNumber.string(from: day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.ink : Theme.secondaryInk)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(square(for: life.commits(on: day)))
                    .frame(width: 8, height: 8)
            }
            ForEach(tasks.prefix(6)) { task in
                Button {
                    life.toggle(task)
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(life.arc(id: task.arcID)?.colour.color ?? Theme.tertiaryInk)
                            .frame(width: 5, height: 5)
                        Text(task.title)
                            .font(.system(size: 10))
                            .strikethrough(task.isDone, color: Theme.tertiaryInk)
                            .foregroundStyle(task.isDone ? Theme.tertiaryInk : Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to tick off. Right-click to move it.")
                .modifier(TaskDragger(task: task))
                .contextMenu { TaskMenu(task: task) }
            }
            if tasks.count > 6 {
                Text("+\(tasks.count - 6) more")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? Theme.selection : (isToday ? Theme.fill : Theme.ink.opacity(0.03))))
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.5))
            }
        }
        .modifier(DayDropTarget(day: day, targeted: $targeted))
        .accessibilityElement(children: .combine)
    }

    private func square(for commits: Int) -> Color {
        switch LifeScore.level(of: commits) {
        case 0: Theme.ink.opacity(0.1)
        case 1: Theme.accent.opacity(0.35)
        case 2: Theme.accent.opacity(0.6)
        case 3: Theme.accent.opacity(0.8)
        default: Theme.accent
        }
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayNumber: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()
}

/// Moving a task without dragging: right-click any task, in Today or in the
/// week's columns. Dragging works too, but this doesn't depend on it.
private struct TaskMenu: View {
    let task: LifeTask
    private var life: LifeService { .shared }

    var body: some View {
        Button(task.isDone ? "Mark as not done" : "Tick it off") { life.toggle(task) }
        Divider()
        ForEach(life.week(), id: \.self) { day in
            Button(Self.label(for: day)) { life.move(task, to: day) }
                .disabled(task.day.map { LifeService.day($0) == day } ?? false)
        }
        Button("Someday") { life.move(task, to: nil) }
            .disabled(task.day == nil)
        Divider()
        Button("Delete", role: .destructive) { life.delete(task) }
    }

    private static func label(for day: Date) -> String {
        let today = LifeService.today
        if day == today { return "Move to today" }
        if day == LifeService.calendar.date(byAdding: .day, value: 1, to: today) { return "Move to tomorrow" }
        return "Move to " + day.formatted(.dateTime.weekday(.wide))
    }
}

/// Dragging a task to another day, and a column that takes one. Both are
/// AppKit underneath, which ImageRenderer can't draw, so snapshots skip them.
private struct TaskDragger: ViewModifier {
    let task: LifeTask
    @Environment(\.snapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content
        } else {
            content.onDrag { NSItemProvider(object: task.id.uuidString as NSString) }
        }
    }
}

private struct DayDropTarget: ViewModifier {
    let day: Date
    @Binding var targeted: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content
        } else {
            content.onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                let day = day
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let string = value as? String, let id = UUID(uuidString: string) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let task = LifeService.shared.tasks.first(where: { $0.id == id }) else { return }
                            LifeService.shared.move(task, to: day)
                        }
                    }
                }
                return true
            }
        }
    }
}

// MARK: - Arcs

private struct ArcsPane: View {
    @Binding var editing: Arc?
    private var life: LifeService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(life.liveArcs.isEmpty ? "Arcs" : "\(life.liveArcs.count) arcs running")
                Spacer()
                Button {
                    withAnimation(Motion.switchModule) { editing = Arc(name: "", colour: RGBA(hex: 0xFF9F0A)) }
                } label: {
                    Label("New arc", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle())
            }
            if life.liveArcs.isEmpty {
                EmptyStateView(symbol: "target",
                               title: "Design an arc",
                               message: "An arc is a stretch of your life you're committing to: a name, an end date, the habits you'll keep and the milestones that prove it.")
                    .frame(maxHeight: .infinity)
            } else {
                NotchScroll(axis: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(life.liveArcs) { arc in
                            ArcCard(arc: arc, edit: { withAnimation(Motion.switchModule) { editing = arc } })
                        }
                    }
                }
            }
        }
    }
}

private struct ArcCard: View {
    let arc: Arc
    let edit: () -> Void
    @State private var hovering = false
    private var life: LifeService { .shared }

    var body: some View {
        let progress = life.progress(of: arc)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(arc.colour.color).frame(width: 8, height: 8)
                Text(arc.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button(action: edit) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(IconButtonStyle(size: 20))
                        .help("Edit this arc")
                }
            }
            if let intent = arc.intent, !intent.isEmpty {
                Text(intent)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ProgressRingLabel(fraction: progress.fraction, tint: arc.colour.color,
                                  label: progress.milestonesTotal > 0
                                  ? "\(progress.milestonesDone)/\(progress.milestonesTotal)"
                                  : "\(Int(progress.habitRate * 100))%")
                VStack(alignment: .leading, spacing: 1) {
                    if let daysLeft = progress.daysLeft {
                        Text(daysLeft == 0 ? "Ends today" : "\(daysLeft) days left")
                            .font(.system(size: 10, weight: .medium))
                    }
                    Text(progress.milestonesTotal > 0 ? "milestones" : "habits kept")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryInk)
                }
            }

            // Two rows fit; the designer holds the rest.
            let shownHabits = arc.habits.prefix(arc.milestones.isEmpty ? 2 : 1)
            let shownMilestones = arc.milestones.prefix(2 - shownHabits.count)
            ForEach(shownHabits) { habit in
                HabitRow(arc: arc, habit: habit)
            }
            ForEach(shownMilestones) { milestone in
                Button { life.toggle(milestone, in: arc) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: milestone.isDone ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundStyle(milestone.isDone ? arc.colour.color : Theme.tertiaryInk)
                        Text(milestone.title)
                            .font(.system(size: 11))
                            .strikethrough(milestone.isDone, color: Theme.tertiaryInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let due = milestone.due, !milestone.isDone {
                            Text(Format.relative(due))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.tertiaryInk)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            let hidden = arc.habits.count + arc.milestones.count - shownHabits.count - shownMilestones.count
            if hidden > 0 {
                Text("+\(hidden) more · edit to see them all")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        // Fills the room the pane has, so a long arc clips inside its card
        // rather than spilling past it.
        .frame(width: 262, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.fill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(arc.colour.color.opacity(hovering ? 0.5 : 0.18)))
        .onHover { hovering = $0 }
    }
}

struct ProgressRingLabel: View {
    let fraction: Double
    let tint: Color
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raisedFill, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(label)
    }
}
