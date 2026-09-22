import SwiftUI

/// Designing an arc: what you're committing to, until when, the habits you'll
/// keep and the milestones that prove it. Sits over the module like the
/// command palette does, so it never leaves the notch.
struct ArcDesigner: View {
    @Binding var draft: Arc
    @State private var newHabit = ""
    @State private var newMilestone = ""
    @FocusState private var nameFocused: Bool
    /// Nil when cancelled.
    let done: (Arc?) -> Void
    @Environment(\.snapshotMode) private var snapshotMode
    private var life: LifeService { .shared }

    private static let colours: [UInt32] = [0xFF9F0A, 0x30C26A, 0x4FA3FF, 0xFF5E9C, 0x9B6BFF, 0xFFD60A]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(draft.name.isEmpty ? "New arc" : draft.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if life.arcs.contains(where: { $0.id == draft.id }) {
                    Button("Archive") {
                        life.archive(draft)
                        done(nil)
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                Button("Cancel") { done(nil) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    #if DEBUG
                    .debugFrame("life.cancel")
                    #endif
                Button("Lock it in") { done(draft.name.isEmpty ? nil : draft) }
                    .buttonStyle(PillButtonStyle(tint: draft.colour.color))
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    #if DEBUG
                    .debugFrame("life.lockItIn")
                    #endif
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Field(title: "Name", text: $draft.name, placeholder: "Ship Xotch", focused: $nameFocused)
                    Field(title: "Intent", text: Binding(get: { draft.intent ?? "" },
                                                         set: { draft.intent = $0 }),
                          placeholder: "One line: what this is for")
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Colour")
                        HStack(spacing: 6) {
                            ForEach(Self.colours, id: \.self) { hex in
                                let colour = RGBA(hex: hex)
                                Button { draft.colour = colour } label: {
                                    Circle()
                                        .fill(colour.color)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(Theme.ink,
                                                                       lineWidth: draft.colour == colour ? 2 : 0))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Colour")
                            }
                        }
                    }
                    EndDateRow(end: $draft.end)
                    Spacer(minLength: 0)
                }
                .frame(width: 250)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Habits")
                    ForEach($draft.habits) { $habit in
                        HabitEditor(habit: $habit) {
                            draft.habits.removeAll { $0.id == habit.id }
                        }
                    }
                    AddRow(text: $newHabit, placeholder: "A habit you'll keep") {
                        let title = newHabit.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        draft.habits.append(Habit(title: title))
                        newHabit = ""
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 290)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Milestones")
                    ForEach($draft.milestones) { $milestone in
                        MilestoneEditor(milestone: $milestone) {
                            draft.milestones.removeAll { $0.id == milestone.id }
                        }
                    }
                    AddRow(text: $newMilestone, placeholder: "Something that proves it") {
                        let title = newMilestone.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        draft.milestones.append(Milestone(title: title))
                        newMilestone = ""
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if LifeReminders.shared.permission == .denied, draft.habits.contains(where: { $0.reminder != nil }) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                    Text("Notifications are off for Xotch, so reminders won't arrive.")
                    Button("Open Settings") { PrivacyPane.notifications.open() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // All of this goes behind the content. As an overlay, the filled shape
        // sat on top and swallowed every click in the designer — a filled shape
        // takes hits even at 7% opacity.
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.fill))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        }

        // Start in the name field, so you can just type.
        .onAppear { nameFocused = true }

    }
}

// MARK: - Pieces

private struct Field: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding?
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            Group {
                if snapshotMode {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? Theme.tertiaryInk : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let focused {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .focused(focused)
                } else {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct AddRow: View {
    @Binding var text: String
    let placeholder: String
    let submit: () -> Void
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryInk)
            if snapshotMode {
                Text(placeholder)
                    .foregroundStyle(Theme.tertiaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EndDateRow: View {
    @Binding var end: Date?
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Ends")
            HStack(spacing: 6) {
                if let end {
                    if snapshotMode {
                        Text(end.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12))
                    } else {
                        DatePicker("", selection: Binding(get: { end }, set: { self.end = $0 }),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .scaleEffect(0.85, anchor: .leading)
                            .frame(width: 110, height: 24)
                    }
                    Button { self.end = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 18))
                        .help("No end date")
                } else {
                    Button("Give it an end date") {
                        end = LifeService.calendar.date(byAdding: .day, value: 90, to: LifeService.today)
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
    }
}

private struct HabitEditor: View {
    @Binding var habit: Habit
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(habit.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button(action: remove) { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle(size: 18))
                        .help("Remove this habit")
                }
            }
            HStack(spacing: 6) {
                // Pickers and steppers are AppKit, which ImageRenderer can't
                // draw, so snapshots show what they'd say instead.
                if snapshotMode {
                    Text(habit.cadence.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 120, alignment: .leading)
                } else {
                    Picker("", selection: cadenceKind) {
                        Text("Every day").tag(0)
                        Text("Times a week").tag(1)
                        Text("Certain days").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .scaleEffect(0.85, anchor: .leading)
                }

                switch habit.cadence {
                case .timesPerWeek(let count):
                    if snapshotMode {
                        Text("\(count)×")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Stepper(value: Binding(get: { count },
                                               set: { habit.cadence = .timesPerWeek(max(1, min(7, $0))) }),
                                in: 1...7) {
                            Text("\(count)×")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .scaleEffect(0.85, anchor: .leading)
                        .frame(width: 70)
                    }
                case .days(let days):
                    HStack(spacing: 2) {
                        ForEach(1...7, id: \.self) { weekday in
                            let on = days.contains(weekday)
                            Button(String(Cadence.shortNames[weekday - 1].prefix(1))) {
                                var next = Set(days)
                                if on { next.remove(weekday) } else { next.insert(weekday) }
                                habit.cadence = .days(next.sorted())
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(on ? Theme.accent : Theme.raisedFill))
                            .foregroundStyle(on ? Theme.onAccent : Theme.secondaryInk)
                        }
                    }
                case .daily:
                    EmptyView()
                }

                Spacer(minLength: 0)
                ReminderButton(minutes: $habit.reminder)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raisedFill.opacity(hovering ? 1 : 0.6)))
        .onHover { hovering = $0 }
    }

    private var cadenceKind: Binding<Int> {
        Binding(
            get: {
                switch habit.cadence {
                case .daily: 0
                case .timesPerWeek: 1
                case .days: 2
                }
            },
            set: { kind in
                switch kind {
                case 1: habit.cadence = .timesPerWeek(3)
                case 2: habit.cadence = .days([2, 3, 4, 5, 6])
                default: habit.cadence = .daily
                }
            }
        )
    }
}

/// A reminder time for one habit. Asks macOS for permission the first time.
private struct ReminderButton: View {
    @Binding var minutes: Int?
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: minutes == nil ? "bell.slash" : "bell.fill")
                .font(.system(size: 9))
                .foregroundStyle(minutes == nil ? Theme.tertiaryInk : Theme.accent)
            if let minutes {
                if snapshotMode {
                    Text(Self.label(minutes))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                } else {
                    DatePicker("", selection: Binding(
                        get: { LifeService.today.addingTimeInterval(Double(minutes) * 60) },
                        set: { date in
                            let parts = LifeService.calendar.dateComponents([.hour, .minute], from: date)
                            self.minutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
                        }
                    ), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(width: 74, height: 22)
                }
                Button { self.minutes = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 16))
                    .help("No reminder")
            } else {
                Button("Remind me") {
                    minutes = 9 * 60
                    LifeReminders.shared.requestPermission()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    static func label(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct MilestoneEditor: View {
    @Binding var milestone: Milestone
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: milestone.isDone ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(milestone.isDone ? Theme.accent : Theme.tertiaryInk)
            Text(milestone.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let due = milestone.due {
                if snapshotMode {
                    Text(due.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryInk)
                } else {
                    DatePicker("", selection: Binding(get: { due }, set: { milestone.due = $0 }),
                               displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .scaleEffect(0.8, anchor: .trailing)
                        .frame(width: 96, height: 22)
                }
            } else {
                Button("Due…") {
                    milestone.due = LifeService.calendar.date(byAdding: .day, value: 14, to: LifeService.today)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
            }
            if hovering {
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .help("Remove this milestone")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.raisedFill.opacity(hovering ? 1 : 0.6)))
        .onHover { hovering = $0 }
    }
}
