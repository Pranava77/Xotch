import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// Background the AI should know: a resume, a job description, notes on a
/// topic. The active one goes into every conversation.
struct ContextProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

private struct ContextsFile: Codable {
    var profiles: [ContextProfile]
    var activeID: UUID?
}

@MainActor
@Observable
final class AIContextStore {
    static let shared = AIContextStore()

    /// Enough for a long resume plus a job description, without crowding out
    /// a small local model's window.
    static let characterLimit = 24_000

    private(set) var profiles: [ContextProfile]
    private(set) var activeID: UUID?

    init() {
        let file = Storage.load(ContextsFile.self, from: "ai-contexts.json")
        profiles = file?.profiles ?? []
        activeID = file?.activeID
    }

    var active: ContextProfile? {
        profiles.first { $0.id == activeID }
    }

    func save(_ profile: ContextProfile) {
        var profile = profile
        profile.text = String(profile.text.prefix(Self.characterLimit))
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
            activeID = profile.id
        }
        persist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        persist()
    }

    /// nil turns context off.
    func activate(_ id: UUID?) {
        activeID = id
        persist()
    }

    /// Lets someone pick a text, Markdown or PDF file and returns its name and text.
    static func importFile() -> (name: String, text: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText, .rtf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a resume, job description or notes for the AI to keep in mind."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let text: String?
        switch UTType(filenameExtension: url.pathExtension) {
        case let type? where type.conforms(to: .pdf):
            text = PDFDocument(url: url)?.string
        case let type? where type.conforms(to: .rtf):
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (name, text)
    }

    private func persist() {
        Storage.save(ContextsFile(profiles: profiles, activeID: activeID), to: "ai-contexts.json")
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (profiles, activeID)
        let notes = ContextProfile(name: "Project notes", text: "Xotch is a SwiftUI app for the Mac notch.")
        profiles = [notes]
        activeID = notes.id
        body()
        (profiles, activeID) = saved
    }
    #endif
}
