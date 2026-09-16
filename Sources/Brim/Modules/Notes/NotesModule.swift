import SwiftUI

@MainActor
final class NotesModule: NotchModule {
    let id = "notes"
    let title = "Notes"
    let symbol = "note.text"
    func expandedView() -> AnyView { AnyView(NotesView()) }
    func start() { NotesService.shared.start() }
    func stop() { NotesService.shared.stop() }
}

private struct NotesView: View {
    /// nil means the scratchpad.
    @State private var selection: UUID?
    private var notes: NotesService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                NoteListRow(title: "Scratchpad", subtitle: notes.showScratchpadInNotch ? "Shown in the notch" : "Always here",
                            symbol: "pencil.line", isSelected: selection == nil) { selection = nil }
                HStack {
                    SectionLabel("Notes")
                    Spacer()
                    Button { selection = notes.newNote() } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .help("New note")
                }
                .padding(.top, 8)
                .padding(.horizontal, 6)
                NotchScroll {
                    VStack(spacing: 2) {
                        ForEach(notes.notes) { note in
                            NoteListRow(title: note.title, subtitle: Format.relative(note.updated),
                                        symbol: "doc.text", isSelected: selection == note.id) { selection = note.id }
                        }
                    }
                }
            }
            .frame(width: 170)

            Group {
                if let selection, notes.note(id: selection) != nil {
                    NoteEditor(id: selection) {
                        notes.delete(selection)
                        self.selection = nil
                    }
                    .id(selection)
                } else {
                    ScratchpadEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NoteListRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryInk)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.selection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 8))
    }
}

private struct ScratchpadEditor: View {
    @Bindable private var notes = NotesService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchTextEditor(text: $notes.scratchpad)
            HStack {
                Toggle("Show first line in the notch", isOn: $notes.showScratchpadInNotch)
                    .toggleStyle(NotchSwitchStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text("\(notes.scratchpad.count) characters")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
    }
}

private struct NoteEditor: View {
    let id: UUID
    let onDelete: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchTextEditor(text: $text)
                .onChange(of: text) { _, newValue in NotesService.shared.update(id, text: newValue) }
            HStack {
                Text("The first line is the title.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
                Spacer()
                Button("Delete note", role: .destructive, action: onDelete)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .onAppear { text = NotesService.shared.note(id: id)?.text ?? "" }
    }
}
