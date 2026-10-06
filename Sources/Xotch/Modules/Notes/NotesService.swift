import SwiftUI
import Observation

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updated: Date

    var title: String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New note" : trimmed
    }
}

private struct NotesFile: Codable {
    var scratchpad: String
    var showScratchpad: Bool
    var notes: [Note]
}

/// The scratchpad (one always-there text box) and longer notes.
@MainActor
@Observable
final class NotesService {
    static let shared = NotesService()

    var scratchpad: String {
        didSet {
            saver.schedule()
            updateActivity()
        }
    }
    /// Shows the scratchpad's first line beside the notch.
    var showScratchpadInNotch: Bool {
        didSet {
            saver.schedule()
            updateActivity()
        }
    }
    private(set) var notes: [Note]
    @ObservationIgnored private var isRunning = false

    @ObservationIgnored private lazy var saver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(NotesFile(scratchpad: self.scratchpad, showScratchpad: self.showScratchpadInNotch, notes: self.notes),
                     to: "notes.json")
    }

    init() {
        let file = Storage.load(NotesFile.self, from: "notes.json")
        scratchpad = file?.scratchpad ?? ""
        showScratchpadInNotch = file?.showScratchpad ?? false
        notes = file?.notes ?? []
    }

    func start() {
        isRunning = true
        updateActivity()
    }

    func stop() {
        isRunning = false
        updateActivity()
    }

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func newNote() -> UUID {
        let note = Note(text: "", updated: Date())
        withAnimation(Motion.switchModule) { notes.insert(note, at: 0) }
        saver.schedule()
        return note.id
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        saver.schedule()
    }

    func delete(_ id: UUID) {
        withAnimation(Motion.switchModule) { notes.removeAll { $0.id == id } }
        saver.schedule()
    }

    /// Saves immediately, e.g. before quitting.
    func flush() {
        saver.flush()
    }

    private func updateActivity() {
        let firstLine = scratchpad.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard isRunning, showScratchpadInNotch, !firstLine.isEmpty else {
            ActivityCenter.shared.setOngoing(nil, for: "notes")
            return
        }
        ActivityCenter.shared.setOngoing(
            LiveActivity(moduleID: "notes", symbol: "note.text", content: .text(firstLine),
                         tint: Color(red: 1, green: 0.84, blue: 0.3)),
            for: "notes"
        )
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (scratchpad, notes)
        scratchpad = "Call the bank before 5\nBuy coffee beans"
        notes = [
            Note(text: "Launch checklist\n- Record hero video\n- Write changelog", updated: Date().addingTimeInterval(-900)),
            Note(text: "Ideas for Phase 4\nRive mascot that sleeps when idle", updated: Date().addingTimeInterval(-86_400)),
        ]
        body()
        (scratchpad, notes) = saved
    }
    #endif
}
