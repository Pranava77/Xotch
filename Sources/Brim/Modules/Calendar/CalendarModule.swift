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
                               message: "Brim shows the next seven days from Calendar and lets you tick off reminders. Everything stays on your Mac.",
                               buttonTitle: "Allow Calendar and Reminders") { calendar.requestAccess() }
            } else if calendar.needsAccess {
                EmptyStateView(symbol: "calendar.badge.exclamationmark",
                               title: "Brim can't read your calendars",
                               message: "Turn on Brim under Calendars and Reminders in Privacy & Security.",
                               buttonTitle: "Open Privacy Settings") { PrivacyPane.calendars.open() }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    AgendaColumn(events: calendar.events, hasAccess: calendar.eventAccess == .granted)
                        .frame(maxWidth: .infinity)
                    RemindersColumn(reminders: calendar.reminders,
                                    completed: calendar.justCompleted,
                                    hasAccess: calendar.reminderAccess == .granted)
                        .frame(width: 210)
                }
            }
        }
        .task { calendar.refresh() }
    }
}

private struct AgendaColumn: View {
    let events: [AgendaEvent]
    let hasAccess: Bool

    private var days: [(day: Date, events: [AgendaEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: max($0.start, .now)) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Next 7 days")
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
            } else if events.isEmpty {
                Text("Nothing scheduled this week.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 6)
            } else {
                NotchScroll {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(days, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(dayTitle(group.day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryInk)
                                ForEach(group.events) { EventRow(event: $0) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

private struct EventRow: View {
    let event: AgendaEvent

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor.color)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(timeText + (event.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let joinURL = event.joinURL {
                Button("Join") { NSWorkspace.shared.open(joinURL) }
                    .buttonStyle(PillButtonStyle(tint: Theme.positive))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let now = Date()
        if event.start <= now {
            return "Now · until " + event.end.formatted(date: .omitted, time: .shortened)
        }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 {
            return "In \(max(minutes, 1)) min"
        }
        return event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened)
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
