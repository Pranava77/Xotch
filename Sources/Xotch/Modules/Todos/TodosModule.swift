import SwiftUI

@MainActor
final class TodosModule: NotchModule {
    let id = "todos"
    let title = "To-dos"
    let symbol = "checklist"
    func expandedView() -> AnyView { AnyView(TodosView()) }
    func start() { TodoService.shared.start() }
    func stop() { TodoService.shared.stop() }
}

private struct TodosView: View {
    @State private var typed = ""
    @FocusState private var focused: Bool
    @AppStorage("todosSomedayOpen") private var somedayOpen = true
    @Bindable private var service = TodoService.shared

    var body: some View {
        let today = service.todos(on: TodoService.today)
        let tomorrow = service.todos(on: Self.tomorrow)
        let someday = service.someday
        // Today on the left; what's coming up in its own column, so nothing
        // hides under the fold of a short notch.
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header
                AddField(text: $typed, focused: $focused) {
                    service.add(typed)
                    typed = ""
                }
                if today.isEmpty {
                    Text(someday.isEmpty && tomorrow.isEmpty
                         ? "Nothing planned. Type above, or press ⌘K and say what you're doing."
                         : "Nothing for today. Right-click one on the right to bring it over.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryInk)
                } else {
                    NotchScroll {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(today) { TodoRow(todo: $0) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Tile(padding: 10) {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel("Tomorrow")
                            .padding(.horizontal, 6)
                            .padding(.bottom, 2)
                        if tomorrow.isEmpty {
                            Text("Nothing yet")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.tertiaryInk)
                                .padding(.horizontal, 6)
                                .frame(height: 24)
                        } else {
                            ForEach(tomorrow) { TodoRow(todo: $0) }
                        }
                        SomedayHeader(count: someday.count, isOpen: $somedayOpen)
                            .padding(.top, 8)
                        if somedayOpen {
                            ForEach(someday) { TodoRow(todo: $0) }
                        }
                    }
                }
            }
            .frame(width: 250)
        }
        .onAppear {
            service.rolloverIfNeeded()
        }
    }

    private static var tomorrow: Date {
        TodoService.calendar.date(byAdding: .day, value: 1, to: TodoService.today) ?? TodoService.today
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.dayFormatter.string(from: Date()))
                .font(.system(size: 15, weight: .semibold))
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
        }
    }

    private var summary: String {
        let open = service.openToday
        return open == 0 ? "Nothing left today" : (open == 1 ? "1 to do today" : "\(open) to do today")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()
}

/// "Someday", with a triangle that folds the list away.
private struct SomedayHeader: View {
    let count: Int
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(Motion.switchModule) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 8))
                    .frame(width: 10)
                SectionLabel("Someday")
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.tertiaryInk)
            .padding(.horizontal, 6)
            .frame(height: 22, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Someday, \(count) to-dos")
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides the list")
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
                Text(text.isEmpty ? "Add a to-do" : text)
                    .foregroundStyle(text.isEmpty ? Theme.tertiaryInk : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Add a to-do", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .xotchGlass(RoundedRectangle(cornerRadius: 9, style: .continuous))
        #if DEBUG
        .debugFrame("todos.add")
        #endif
    }
}

private struct TodoRow: View {
    let todo: Todo
    @State private var hovering = false
    private var service: TodoService { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Button { service.toggle(todo) } label: {
                Image(systemName: todo.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.isDone ? Theme.accent : Theme.tertiaryInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark \(todo.title) not done" : "Finish \(todo.title)")

            Text(todo.title)
                .font(.system(size: 13))
                .strikethrough(todo.isDone, color: Theme.tertiaryInk)
                .foregroundStyle(todo.isDone ? Theme.tertiaryInk : Theme.ink)
                .lineLimit(1)

            Spacer(minLength: 6)

            if hovering {
                Button { service.delete(todo) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .help("Delete")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.fill : .clear))
        .onHover { hovering = $0 }
        .contextMenu { TodoMenu(todo: todo) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Delete") { service.delete(todo) }
    }
}

/// Moving a to-do: right-click it and pick a day.
struct TodoMenu: View {
    let todo: Todo
    private var service: TodoService { .shared }

    var body: some View {
        Button(todo.isDone ? "Mark as not done" : "Tick it off") { service.toggle(todo) }
        Divider()
        Button("Today") { service.move(todo, to: TodoService.today) }
            .disabled(todo.day.map { TodoService.day($0) == TodoService.today } ?? false)
        Button("Tomorrow") { service.move(todo, to: tomorrow) }
            .disabled(todo.day.map { TodoService.day($0) == tomorrow } ?? false)
        Button("Someday") { service.move(todo, to: nil) }
            .disabled(todo.day == nil)
        Divider()
        Button("Delete", role: .destructive) { service.delete(todo) }
    }

    private var tomorrow: Date {
        TodoService.calendar.date(byAdding: .day, value: 1, to: TodoService.today) ?? TodoService.today
    }
}
