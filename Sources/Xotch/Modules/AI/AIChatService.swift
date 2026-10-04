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
    /// The model that wrote a reply.
    var model: String?
    /// Kept in memory only, so it can go with follow-up questions.
    var imageJPEG: Data?

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, isError, hadScreenshot, model
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
        streamReply(from: provider, turns: turns())
    }

    /// How a reply is asked for again.
    enum Rewrite {
        case retry, shorter, longer
    }

    /// Replaces the last reply. Shorter and longer show the model its old
    /// answer and ask for a new one; retry asks the question afresh.
    func regenerate(_ reply: ChatMessage, as rewrite: Rewrite) {
        guard !isStreaming, reply.role == .assistant, messages.last?.id == reply.id,
              let provider = AIProviderStore.shared.active, !provider.model.isEmpty else { return }
        var turns = turns()
        messages.removeLast()
        switch rewrite {
        case .retry:
            turns = self.turns()
        case .shorter:
            turns.append(ChatTurn(role: .user, text: "Answer that again, about half as long. Reply with the new answer only."))
        case .longer:
            turns.append(ChatTurn(role: .user, text: "Answer that again in more depth, with more detail and examples. Reply with the new answer only."))
        }
        notice = nil
        streamReply(from: provider, turns: turns)
    }

    private func streamReply(from provider: ProviderConfig, turns: [ChatTurn]) {
        var reply = ChatMessage(role: .assistant, text: "")
        reply.model = provider.model
        messages.append(reply)
        saver.schedule()

        let system = systemPrompt
        let backend = AIBackends.backend(for: provider.kind)
        isStreaming = true
        task = Task { [weak self] in
            // The Keychain can stop to ask whether this build may read the key
            // (every rebuild of a debug build does). Asked on the main thread,
            // that froze the whole notch until someone answered.
            let apiKey = await Task.detached { provider.apiKey }.value
            let request = ChatRequest(baseURL: provider.baseURL, model: provider.model, apiKey: apiKey,
                                      system: system, turns: turns)
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

    /// Asks a follow-up chip's question.
    func ask(_ question: String) {
        guard !isStreaming else { return }
        draft = question
        send()
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
        NSPasteboard.general.setString(ChatMarkdown.splitFollowUps(message.text).body, forType: .string)
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
        in fenced blocks with the language named, and use them only for code. For a note, tip or warning, \
        use a quote that starts "Note:", "Tip:" or "Warning:".

        End every reply with one last line in exactly this form, three short questions (under eight words \
        each) the user might ask next: Follow-ups: first question | second question | third question
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
            // Follow-up suggestions are for the user, not the conversation.
            let text = role == .assistant ? ChatMarkdown.splitFollowUps(message.text).body : message.text
            if let last = result.last, last.role == role {
                result[result.count - 1] = ChatTurn(role: role, text: last.text + "\n\n" + text,
                                                    imageJPEG: image ?? last.imageJPEG)
            } else {
                result.append(ChatTurn(role: role, text: text, imageJPEG: image))
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
        var reply = ChatMessage(role: .assistant, text: """
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
            | `build-app.sh` | The app itself |

            > **Note:** testers on macOS 14 need to right-click › Open the first time.

            ```bash
            # Build, check and zip
            VERSION="0.3.0"
            ./scripts/build-app.sh release
            codesign --verify --deep build/Xotch.app
            ./scripts/package-beta.sh "$VERSION"
            ```
            Follow-ups: How do testers install it? | Can I notarise it? | What about a DMG?
            """)
        reply.model = "gemini-3.1-flash-lite"
        messages = [ChatMessage(role: .user, text: "How do I ship the beta to testers?"), reply]
        body()
        messages = saved
    }

    /// A finished reply with code, for snapshots: colours, line numbers, the
    /// action bar and follow-up chips.
    func withCodeSample(_ body: () -> Void) {
        let saved = messages
        var reply = ChatMessage(role: .assistant, text: """
            Use `guard` to leave early when the index is out of range:
            ```swift
            func item(at index: Int) -> String? {
                // Out of range: nothing to return
                guard items.indices.contains(index) else { return nil }
                let title = items[index].title
                return title.isEmpty ? "Untitled" : title
            }
            ```
            Follow-ups: What about negative indexes? | Can I use if let? | Show a test for it
            """)
        reply.model = "gemini-3.1-flash-lite"
        messages = [ChatMessage(role: .user, text: "How do I avoid the crash on an empty list?"), reply]
        body()
        messages = saved
    }

    /// A reply arriving, for snapshots: the cursor shows, the chips don't.
    func withStreamingSample(_ body: () -> Void) {
        let saved = (messages, isStreaming)
        var reply = ChatMessage(role: .assistant, text: """
            Swift's `guard` exits early when a condition fails, so the rest of the function can assume it holds.

            - It keeps the happy path unindented
            - The else branch must leave the scope
            Follow-ups: When should I use if
            """)
        reply.model = "gemini-3.1-flash-lite"
        messages = [ChatMessage(role: .user, text: "What does guard do in Swift?"), reply]
        isStreaming = true
        body()
        (messages, isStreaming) = saved
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
