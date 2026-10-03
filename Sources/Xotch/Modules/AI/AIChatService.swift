import AppKit
import Observation
import SwiftUI

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var isError = false
    /// A screenshot went with this message. The image itself is never saved.
    var hadScreenshot = false
    /// Kept in memory only, so it can go with follow-up questions.
    var imageJPEG: Data?

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, isError, hadScreenshot
    }
}

private struct ChatFile: Codable {
    var messages: [ChatMessage]
}

/// The conversation in the AI module, and the hotkeys' way into it.
@MainActor
@Observable
final class AIChatService {
    static let shared = AIChatService()

    private(set) var messages: [ChatMessage]
    private(set) var isStreaming = false
    private(set) var isCapturing = false
    var draft = ""
    /// A screenshot waiting to go with the next message.
    var attachment: Data?
    /// Shown above the input, e.g. when the screenshot couldn't be taken.
    var notice: String?
    /// Set when the input should take the keyboard as soon as it's on screen.
    var wantsFocus = false
    /// The chat fills a bigger notch. Remembered between launches.
    var isExpanded = UserDefaults.standard.bool(forKey: SettingsKey.aiExpanded) {
        didSet { UserDefaults.standard.set(isExpanded, forKey: SettingsKey.aiExpanded) }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private lazy var saver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(ChatFile(messages: Array(self.messages.suffix(Self.keptMessages))), to: "ai-chat.json")
    }

    private static let keptMessages = 100

    init() {
        messages = Storage.load(ChatFile.self, from: "ai-chat.json")?.messages ?? []
    }

    var canSend: Bool {
        !isStreaming && !isCapturing
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
    }

    // MARK: - Hotkeys

    /// Opens the notch on the chat, ready to type.
    func quickAsk() {
        wantsFocus = true
        ScreenManager.shared.openPrimary(moduleID: AIModule.moduleID)
    }

    /// Takes the screen first, so the notch can't be in the way, then opens the chat.
    func askAboutScreen() {
        Task {
            await captureScreen()
            quickAsk()
        }
    }

    // MARK: - Chat

    func captureScreen() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            attachment = try await ScreenSnapshot.capture()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func send() {
        guard canSend else { return }
        guard let provider = AIProviderStore.shared.active else {
            notice = "Add an AI provider in Settings › AI first."
            return
        }
        guard !provider.model.isEmpty else {
            notice = "Choose a model for \(provider.name) in Settings › AI."
            return
        }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = "What's on my screen? Help me with it."
        }
        draft = ""
        notice = nil
        var question = ChatMessage(role: .user, text: text)
        if let attachment {
            question.imageJPEG = attachment
            question.hadScreenshot = true
            self.attachment = nil
        }
        messages.append(question)
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        saver.schedule()

        let request = ChatRequest(baseURL: provider.baseURL, model: provider.model, apiKey: provider.apiKey,
                                  system: systemPrompt, turns: turns())
        let backend = AIBackends.backend(for: provider.kind)
        isStreaming = true
        task = Task { [weak self] in
            do {
                for try await piece in backend.stream(request) {
                    self?.append(piece, to: reply.id)
                }
            } catch {
                self?.fail(reply.id, with: error)
            }
            self?.finish(reply.id)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func newChat() {
        stop()
        messages = []
        attachment = nil
        notice = nil
        saver.schedule()
    }

    /// Asks the last question again, e.g. after fixing a key or starting Ollama.
    func retry() {
        guard !isStreaming, let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[index]
        messages.removeSubrange(index...)
        draft = question.text
        attachment = question.imageJPEG
        send()
    }

    /// The notch follows `AIModule.openSize`, so it grows or shrinks with this.
    func toggleExpanded() {
        withAnimation(Motion.switchModule) { isExpanded.toggle() }
    }

    func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    func flush() {
        saver.flush()
    }

    // MARK: - Streaming

    private func append(_ piece: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += piece
    }

    private func fail(_ id: UUID, with error: Error) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // Keep whatever arrived before the failure.
        if messages[index].text.isEmpty {
            messages[index].text = error.localizedDescription
            messages[index].isError = true
        } else {
            messages[index].text += "\n\n(\(error.localizedDescription))"
        }
    }

    private func finish(_ id: UUID) {
        isStreaming = false
        task = nil
        // Stopped before a word arrived: drop the empty bubble.
        if let index = messages.firstIndex(where: { $0.id == id }), messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        saver.schedule()
    }

    // MARK: - Request

    private var systemPrompt: String {
        let room = isExpanded
            ? "The panel is large right now, so a fuller answer is fine when the question needs one."
            : "Replies appear in a small panel, so keep them short: a few sentences or a tight list."
        var prompt = """
        You are the assistant inside Xotch, an app that lives in the Mac's notch. \(room) When a screenshot \
        is attached it shows the user's screen right now; read it closely and answer about what it shows.

        Format replies in Markdown so they're easy to scan. Lead with the answer in one sentence, then the \
        detail. Use short paragraphs, bullets for options, numbered lists for steps, a table to compare \
        things, and **bold** for the key term. Add ## headings only when a reply has several parts. Put code \
        in fenced blocks with the language named, and use them only for code.
        """
        if let context = AIContextStore.shared.active, !context.text.isEmpty {
            prompt += """


            The user has shared this background. Use it whenever it's relevant, and tailor answers to it.
            <context name="\(context.name)">
            \(context.text)
            </context>
            """
        }
        return prompt
    }

    /// The conversation so far, shaped the way every provider accepts: errors
    /// left out, turns alternating, starting with the user. Only the latest
    /// screenshot is sent, so follow-ups don't pay for old ones again.
    private func turns() -> [ChatTurn] {
        var result: [ChatTurn] = []
        let latestImage = messages.lastIndex { $0.imageJPEG != nil }
        for (index, message) in messages.enumerated() where !message.isError && !message.text.isEmpty {
            let role: ChatTurn.Role = message.role == .user ? .user : .assistant
            let image = index == latestImage ? message.imageJPEG : nil
            if let last = result.last, last.role == role {
                result[result.count - 1] = ChatTurn(role: role, text: last.text + "\n\n" + message.text,
                                                    imageJPEG: image ?? last.imageJPEG)
            } else {
                result.append(ChatTurn(role: role, text: message.text, imageJPEG: image))
            }
        }
        result = Array(result.suffix(30))
        while result.first?.role == .assistant {
            result.removeFirst()
        }
        return result
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (messages, draft, attachment, notice)
        var question = ChatMessage(role: .user, text: "Why does this crash when the list is empty?")
        question.hadScreenshot = true
        messages = [
            question,
            ChatMessage(role: .assistant, text: """
            `items[index]` is read before the empty check, so an empty list goes out of range. Check first:
            ```swift
            guard items.indices.contains(index) else { return nil }
            ```
            """),
            ChatMessage(role: .user, text: "Write the commit message"),
            ChatMessage(role: .assistant, text: "**Check the index before reading items**, so an empty list no longer crashes."),
        ]
        draft = ""
        attachment = nil
        notice = nil
        body()
        (messages, draft, attachment, notice) = saved
    }

    /// A reply that uses every kind of block, for snapshots.
    func withRichSample(_ body: () -> Void) {
        let saved = messages
        messages = [
            ChatMessage(role: .user, text: "How do I ship the beta to testers?"),
            ChatMessage(role: .assistant, text: """
            Build a release, check its signature, then zip it with **package-beta.sh**.

            ## Steps
            1. Bump the version in `Info.plist`.
            2. Run the script:
               - it builds in release
               - it checks the signature
            3. Send the zip.

            | Script | What it makes |
            |---|---|
            | `package-beta.sh` | A zip for testers |
            | `package-dmg.sh` | A disk image |

            > Testers on macOS 14 need to right-click › Open the first time.

            ```bash
            ./scripts/package-beta.sh
            ```
            """),
        ]
        body()
        messages = saved
    }

    func withExpanded(_ body: () -> Void) {
        let saved = isExpanded
        isExpanded = true
        body()
        isExpanded = saved
    }

    /// The welcome screen, for snapshots: the chat set aside, then put back.
    func withoutMessages(_ body: () -> Void) {
        let saved = messages
        messages = []
        body()
        messages = saved
    }
    #endif
}
