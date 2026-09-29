import SwiftUI

@MainActor
final class CalendarModule: NotchModule {
    let id = "calendar"
    let title = "Calendar"
    let symbol = "calendar"
    func expandedView() -> AnyView { AnyView(CalendarView()) }
}

private struct CalendarView: View {
    private var calendar: CalendarService { .shared }

    var body: some View {
        Group {
            if calendar.eventAccess == .notAsked && calendar.reminderAccess == .notAsked {
                EmptyStateView(symbol: "calendar",
                               title: "See your week at a glance",
                               message: "Xotch shows the next seven days from Calendar and lets you tick off reminders. Everything stays on your Mac.",
                               buttonTitle: "Allow Calendar and Reminders") { calendar.requestAccess() }
            } else if calendar.needsAccess {
                EmptyStateView(symbol: "calendar.badge.exclamationmark",
                               title: "Xotch can't read your calendars",
                               message: "Turn on Xotch under Calendars and Reminders in Privacy & Security.",
                               buttonTitle: "Open Privacy Settings") { PrivacyPane.calendars.open() }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    WeekAgenda(events: calendar.events, hasAccess: calendar.eventAccess == .granted)
                        .frame(maxWidth: .infinity)
                    RemindersColumn(reminders: calendar.reminders,
                                    completed: calendar.justCompleted,
                                    hasAccess: calendar.reminderAccess == .granted)
                        .frame(width: 196)
                }
            }
        }
        .task { calendar.refresh() }
    }
}

/// A strip of the next seven days, and the chosen day's events under it with
/// their times in a column, the way most notch calendars read.
private struct WeekAgenda: View {
    let events: [AgendaEvent]
    let hasAccess: Bool
    @State private var selected = Calendar.current.startOfDay(for: .now)
    @Environment(\.snapshotDate) private var snapshotDate

    private var today: Date { Calendar.current.startOfDay(for: snapshotDate ?? .now) }

    private var week: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private func events(on day: Date) -> [AgendaEvent] {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        // All-day and multi-day events show on every day they cover.
        return events.filter { $0.start < next && $0.end > day }
    }

    var body: some View {
        let day = week.contains(selected) ? selected : today
        let dayEvents = events(on: day)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(week, id: \.self) { date in
                    DayCell(date: date, isToday: date == today, isSelected: date == day,
                            colors: events(on: date).prefix(3).map(\.calendarColor.color)) {
                        withAnimation(Motion.press) { selected = date }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(dayTitle(day))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Open Calendar") { CalendarService.shared.openCalendarApp() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
            if !hasAccess {
                Text("Calendar access is off.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
            } else if dayEvents.isEmpty {
                emptyDay(day)
            } else {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dayEvents) { EventRow(event: $0, day: day) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Nothing that day: point at the next thing that is on.
    @ViewBuilder private func emptyDay(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Calendar.current.isDate(day, inSameDayAs: today) ? "Nothing else today." : "Nothing on \(day.formatted(.dateTime.weekday(.wide))).")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryInk)
            if let next = events.first(where: { $0.start >= day }) ?? events.first {
                let nextDay = Calendar.current.startOfDay(for: max(next.start, today))
                if nextDay != day, week.contains(nextDay) {
                    Button {
                        withAnimation(Motion.press) { selected = nextDay }
                    } label: {
                        Label("Next: \(next.title), \(dayTitle(nextDay))", systemImage: "arrow.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: today) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One day in the strip: its initial, its number, and a dot per event.
private struct DayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isToday ? Theme.accent : Theme.tertiaryInk)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 14, weight: isSelected || isToday ? .bold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isToday && isSelected ? RGBA(Theme.accent).onColor : Theme.ink)
                    .frame(width: 28, height: 28)
                    .background {
                        if isToday && isSelected {
                            Circle().fill(Theme.accent)
                        } else if isSelected {
                            Circle().fill(Theme.raisedFill)
                        } else if isToday {
                            Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 2.5) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityValue(colors.isEmpty ? "No events" : colors.count == 1 ? "1 event" : "\(colors.count) or more events")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EventRow: View {
    let event: AgendaEvent
    let day: Date

    var body: some View {
        let isNow = !event.isAllDay && event.start <= .now && event.end > .now
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if event.isAllDay || event.start < day {
                    Text("All day")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .semibold))
                    Text(event.end.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryInk)
                }
            }
            .monospacedDigit()
            .frame(width: 58, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor.color)
                .frame(width: 3.5, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isNow ? Theme.accent : Theme.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let joinURL = event.joinURL {
                Button("Join") { NSWorkspace.shared.open(joinURL) }
                    .buttonStyle(PillButtonStyle(tint: Theme.positive))
            }
        }
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .background {
            if isNow {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.fill)
                    .padding(.horizontal, -4)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Now", "In 12 min", or where it is.
    private var detail: String? {
        let now = Date()
        var parts: [String] = []
        if !event.isAllDay {
            if event.start <= now && event.end > now {
                parts.append("Now")
            } else if event.start > now, event.start.timeIntervalSince(now) < 3600 {
                parts.append("In \(max(Int(event.start.timeIntervalSince(now) / 60), 1)) min")
            }
        }
        if let location = event.location { parts.append(location) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct RemindersColumn: View {
    let reminders: [AgendaReminder]
    let completed: Set<String>
    let hasAccess: Bool

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Reminders")
                if !hasAccess {
                    Text("Reminders access is off.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                } else if reminders.isEmpty {
                    Text("All done.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                } else {
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(reminders) { reminder in
                                ReminderRow(reminder: reminder, isDone: completed.contains(reminder.id))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: AgendaReminder
    let isDone: Bool

    var body: some View {
        Button {
            CalendarService.shared.complete(reminder)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isDone ? Theme.positive : reminder.listColor.color)
                    .swapTransition(on: isDone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? Theme.secondaryInk : Theme.ink)
                        .lineLimit(2)
                    if let due = reminder.due {
                        Text(dueText(due))
                            .font(.system(size: 10))
                            .foregroundStyle(due < .now ? Theme.negative : Theme.tertiaryInk)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDone)
        .accessibilityLabel("Complete \(reminder.title)")
    }

    private func dueText(_ due: Date) -> String {
        if Calendar.current.isDateInToday(due) {
            return "Today, " + due.formatted(date: .omitted, time: .shortened)
        }
        return due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
