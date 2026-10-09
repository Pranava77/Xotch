import AppKit
import Observation
import SwiftUI

/// One tool call in a reply, and how it went.
struct ToolStep: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        /// Waiting for the user to allow it.
        case waiting
        /// A lookup waiting its turn behind earlier cards.
        case queued
        case running, done, declined, failed
        /// Stopped before it ran.
        case cancelled
        /// Run, then taken back.
        case undone
    }

    var id = UUID()
    var call: ToolCall
    var status: Status
    /// What the card says: the preview before it runs, what happened after.
    var title: String
    /// What the model was told.
    var result: String?
    /// A module worth opening to see the change.
    var openModule: String?
}

/// A round of a reply that called tools: what it said, then the calls.
struct ToolRound: Codable, Equatable {
    var text: String
    var steps: [ToolStep]
}

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
    /// The rounds of a reply that used tools before `text`, its last round.
    var rounds: [ToolRound]?
    /// A slash command and what it did: shown, never sent to the model.
    var local: Bool?
    /// For a failed reply, something the person can do about it.
    var fix: ChatFix?

    var isLocal: Bool { local == true }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, isError, hadScreenshot, model, rounds, local, fix
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
    /// A fix offered on a failed reply is being carried out.
    private(set) var isFixing = false
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
    /// Cards waiting for Allow or Don't.
    @ObservationIgnored private var decisions: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var undoActions: [UUID: @MainActor () -> Void] = [:]
    /// Replies where the user chose Allow all.
    @ObservationIgnored private var allowedReplies: Set<UUID> = []
    /// Models that turned tools down this session.
    @ObservationIgnored private var noToolModels: Set<String> = []

    /// Rounds of tool calls before the model has to answer in words.
    private static let maxToolRounds = 5
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
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.hasPrefix("/"), attachment == nil {
            draft = ""
            runSlashCommand(typed)
            return
        }
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

        let backend = AIBackends.backend(for: provider.kind)
        let modelKey = provider.id.uuidString + "/" + provider.model
        let useTools = AppSettings.aiNotchTools && !noToolModels.contains(modelKey)
        isStreaming = true
        task = Task { [weak self] in
            // The Keychain can stop to ask whether this build may read the key
            // (every rebuild of a debug build does). Asked on the main thread,
            // that froze the whole notch until someone answered.
            let apiKey = await Task.detached { provider.apiKey }.value
            await self?.converse(backend: backend, provider: provider, apiKey: apiKey, turns: turns,
                                 replyID: reply.id, useTools: useTools, modelKey: modelKey)
            self?.finish(reply.id)
        }
    }

    /// Asks the model, runs the tools it calls (asking the user first for
    /// anything that changes or shares something), sends back what they
    /// returned, and repeats until the model answers in words.
    private func converse(backend: any ChatBackend, provider: ProviderConfig, apiKey: String?, turns: [ChatTurn],
                          replyID: UUID, useTools: Bool, modelKey: String) async {
        var turns = turns
        var tools = useTools ? NotchTools.specs : []
        var round = 0
        while !Task.isCancelled {
            // The last round offers no tools, so the model has to answer.
            let offered = round < Self.maxToolRounds ? tools : []
            let request = ChatRequest(baseURL: provider.baseURL, model: provider.model, apiKey: apiKey,
                                      system: systemPrompt(withTools: !offered.isEmpty), turns: turns, tools: offered)
            var calls: [ToolCall] = []
            var heardText = false
            #if DEBUG
            debugNote("round \(round): \(provider.model), \(offered.count) tools offered")
            #endif
            do {
                for try await event in backend.stream(request) {
                    switch event {
                    case .text(let piece):
                        heardText = true
                        append(piece, to: replyID)
                    case .toolCall(let call):
                        calls.append(call)
                    }
                }
            } catch {
                #if DEBUG
                debugNote("round \(round) error: \(error.localizedDescription)")
                #endif
                // A model without tool support: ask again without them.
                if !offered.isEmpty, round == 0, !heardText, calls.isEmpty, AIError.isAboutTools(error) {
                    noToolModels.insert(modelKey)
                    tools = []
                    notice = "\(provider.model) can't use notch tools, so it answered without them. Gemini, Claude and GPT can."
                    continue
                }
                // A local server that answers but doesn't have the model: say
                // which ones it has, and offer one.
                if let missing = await missingModel(backend: backend, provider: provider, apiKey: apiKey, after: error) {
                    fail(replyID, with: missing)
                    return
                }
                fail(replyID, with: error)
                return
            }
            #if DEBUG
            debugNote("round \(round) done: text=\(heardText) calls=\(calls.map(\.name))")
            #endif
            guard !calls.isEmpty, !Task.isCancelled else { return }
            let (said, stepIDs) = startToolRound(calls, in: replyID)
            var results: [ToolResult] = []
            for stepID in stepIDs {
                results.append(await run(stepID, in: replyID, asking: true))
            }
            turns.append(ChatTurn(role: .assistant, text: said, toolCalls: calls))
            turns.append(ChatTurn(role: .tool, text: "", toolResults: results))
            round += 1
        }
    }

    // MARK: - Tools

    /// What the reply has said so far becomes a finished round, with a card
    /// per call. Returns that text and the cards' ids.
    private func startToolRound(_ calls: [ToolCall], in replyID: UUID) -> (String, [UUID]) {
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return ("", []) }
        let steps = calls.map { call -> ToolStep in
            let tool = NotchTools.tool(named: call.name)
            let title = tool?.preview(ToolArgs(values: call.argumentObject)) ?? "Use \(call.name)"
            return ToolStep(call: call, status: tool?.asks == true ? .waiting : .queued, title: title)
        }
        let text = messages[index].text
        messages[index].rounds = (messages[index].rounds ?? []) + [ToolRound(text: text, steps: steps)]
        messages[index].text = ""
        saver.schedule()
        return (text, steps.map(\.id))
    }

    /// Runs one card's tool, first waiting for Allow if it changes or shares
    /// something, and returns what to tell the model.
    private func run(_ stepID: UUID, in replyID: UUID, asking: Bool) async -> ToolResult {
        guard let step = step(stepID, in: replyID) else { return ToolResult(callID: "", name: "", content: "{}") }
        func told(_ content: String) -> ToolResult {
            ToolResult(callID: step.call.id, name: step.call.name, content: content)
        }
        guard let tool = NotchTools.tool(named: step.call.name) else {
            let content = NotchTools.json(["error": "There's no tool called \(step.call.name)."])
            updateStep(stepID, in: replyID) { $0.status = .failed; $0.result = content }
            return told(content)
        }
        if asking, tool.asks, !allowedReplies.contains(replyID) {
            updateStep(stepID, in: replyID) { $0.status = .waiting }
            let allowed = await withCheckedContinuation { decisions[stepID] = $0 }
            if Task.isCancelled {
                let content = NotchTools.json(["error": "The user stopped the request."])
                updateStep(stepID, in: replyID) { $0.status = .cancelled; $0.result = content }
                return told(content)
            }
            guard allowed else {
                let content = NotchTools.json(["declined": true, "note": "The user said no. Don't try again unless they ask."])
                updateStep(stepID, in: replyID) { $0.status = .declined; $0.result = content }
                return told(content)
            }
        }
        updateStep(stepID, in: replyID) { $0.status = .running }
        do {
            let outcome = try await tool.run(ToolArgs(values: step.call.argumentObject))
            undoActions[stepID] = outcome.undo
            updateStep(stepID, in: replyID) {
                $0.status = .done
                $0.title = outcome.summary
                $0.result = outcome.result
                $0.openModule = outcome.openModule
            }
            return told(outcome.result)
        } catch {
            let content = NotchTools.json(["error": error.localizedDescription])
            updateStep(stepID, in: replyID) {
                $0.status = .failed
                $0.title = error.localizedDescription
                $0.result = content
            }
            return told(content)
        }
    }

    /// Allow or Don't on a card.
    func decide(_ step: ToolStep, allow: Bool) {
        decisions.removeValue(forKey: step.id)?.resume(returning: allow)
    }

    /// Allow all: this card and every later one in the reply.
    func allowAll(in reply: ChatMessage) {
        allowedReplies.insert(reply.id)
        for step in (reply.rounds ?? []).flatMap(\.steps) {
            decisions.removeValue(forKey: step.id)?.resume(returning: true)
        }
    }

    func canUndo(_ step: ToolStep) -> Bool {
        step.status == .done && undoActions[step.id] != nil
    }

    func undo(_ step: ToolStep, in reply: ChatMessage) {
        guard let action = undoActions.removeValue(forKey: step.id) else { return }
        action()
        updateStep(step.id, in: reply.id) { $0.status = .undone }
        Haptics.tick()
    }

    private func step(_ id: UUID, in replyID: UUID) -> ToolStep? {
        messages.first { $0.id == replyID }?.rounds?.lazy.flatMap(\.steps).first { $0.id == id }
    }

    private func updateStep(_ id: UUID, in replyID: UUID, _ change: (inout ToolStep) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == replyID }), var rounds = messages[index].rounds else { return }
        for round in rounds.indices {
            if let step = rounds[round].steps.firstIndex(where: { $0.id == id }) {
                change(&rounds[round].steps[step])
                messages[index].rounds = rounds
                saver.schedule()
                return
            }
        }
    }

    // MARK: - Slash commands

    struct SlashCommand: Identifiable {
        let name: String
        let hint: String
        let symbol: String
        var id: String { name }
    }

    static let slashCommands = [
        SlashCommand(name: "todo", hint: "Add a to-do for today", symbol: "plus.circle"),
        SlashCommand(name: "timer", hint: "Start a countdown: /timer 25m", symbol: "timer"),
        SlashCommand(name: "focus", hint: "Start a focus session", symbol: "brain.head.profile"),
        SlashCommand(name: "break", hint: "Take a short break", symbol: "cup.and.saucer.fill"),
        SlashCommand(name: "note", hint: "Write a note", symbol: "square.and.pencil"),
        SlashCommand(name: "play", hint: "Play music", symbol: "play.fill"),
        SlashCommand(name: "pause", hint: "Pause music", symbol: "pause.fill"),
        SlashCommand(name: "next", hint: "Next track", symbol: "forward.fill"),
        SlashCommand(name: "clear", hint: "Start a new chat", symbol: "square.and.pencil"),
    ]

    /// Runs a typed command straight away, through the same tools the AI
    /// uses, with no model and no Allow: you typed it.
    private func runSlashCommand(_ typed: String) {
        let parts = typed.dropFirst().split(separator: " ", maxSplits: 1)
        let name = parts.first.map { String($0).lowercased() } ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        let call: (tool: String, args: [String: Any])?
        switch name {
        case "clear":
            newChat()
            return
        case "todo":
            call = rest.isEmpty ? nil : ("add_todo", ["title": rest])
        case "timer":
            guard let seconds = CommandCatalog.duration(in: rest.isEmpty ? "10" : rest) else {
                notice = "Try /timer 25m, /timer 90s or /timer 1h."
                return
            }
            call = ("start_timer", ["kind": "countdown", "minutes": seconds / 60])
        case "focus":
            call = ("start_timer", ["kind": "focus"])
        case "break":
            call = ("start_timer", ["kind": "short_break"])
        case "note":
            call = rest.isEmpty ? nil : ("create_note", ["text": rest])
        case "play", "pause", "next":
            call = ("media", ["action": name])
        default:
            notice = "There's no /\(name). Type / to see the commands."
            return
        }
        guard let call else {
            notice = "Write what to add after /\(name)."
            return
        }
        notice = nil
        let arguments = (try? JSONSerialization.data(withJSONObject: call.args)) ?? Data("{}".utf8)
        let toolCall = ToolCall(id: ToolCall.localID(), name: call.tool, arguments: arguments)
        let title = NotchTools.tool(named: call.tool)?.preview(ToolArgs(values: call.args)) ?? typed
        let step = ToolStep(call: toolCall, status: .running, title: title)
        var command = ChatMessage(role: .user, text: typed)
        command.local = true
        var reply = ChatMessage(role: .assistant, text: "")
        reply.local = true
        reply.model = "Xotch"
        reply.rounds = [ToolRound(text: "", steps: [step])]
        messages.append(command)
        messages.append(reply)
        saver.schedule()
        Task { [weak self] in
            _ = await self?.run(step.id, in: reply.id, asking: false)
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
        // Cards waiting for an answer give up.
        let waiting = decisions
        decisions = [:]
        for continuation in waiting.values {
            continuation.resume(returning: false)
        }
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

    /// The commands matching what's typed after a slash, for the menu above the input.
    var slashSuggestions: [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(" ") else { return [] }
        let typed = draft.dropFirst().lowercased()
        return Self.slashCommands.filter { typed.isEmpty || $0.name.hasPrefix(typed) }
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

    /// After a failed request to a server on this Mac, whether the model is
    /// missing from it: then the error names what it has and offers one.
    private func missingModel(backend: any ChatBackend, provider: ProviderConfig, apiKey: String?,
                              after error: Error) async -> AIError? {
        guard (error as? AIError)?.fix == nil, provider.kind == .openAICompatible || provider.kind == .ollama,
              let url = URL(string: provider.baseURL), ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""),
              let list = try? await backend.models(baseURL: provider.baseURL, apiKey: apiKey),
              !list.isEmpty, !list.contains(provider.model) else { return nil }
        let chat = list.filter(LMStudio.canChat)
        let server = LMStudio.serves(provider.baseURL) ? "LM Studio" : provider.name
        guard let suggestion = chat.first else {
            return AIError("\(server) doesn't have \(provider.model), and has no chat models. Download one in \(server).")
        }
        return AIError("\(server) doesn't have \(provider.model). It has \(chat.joined(separator: ", ")).",
                       fix: .useModel(suggestion))
    }

    /// Carries out a failed reply's fix, then asks again.
    func apply(_ fix: ChatFix) {
        guard !isFixing, !isStreaming, let provider = AIProviderStore.shared.active else { return }
        switch fix {
        case .startLMStudio:
            isFixing = true
            Task {
                do {
                    try await LMStudio.startServer(baseURL: provider.baseURL)
                    isFixing = false
                    retry()
                } catch {
                    isFixing = false
                    notice = error.localizedDescription
                }
            }
        case .useModel(let model):
            var changed = provider
            changed.model = model
            AIProviderStore.shared.save(changed, key: nil)
            retry()
        }
    }

    private func fail(_ id: UUID, with error: Error) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // Keep whatever arrived before the failure.
        if messages[index].text.isEmpty {
            messages[index].text = error.localizedDescription
            messages[index].isError = true
            messages[index].fix = (error as? AIError)?.fix
        } else {
            messages[index].text += "\n\n(\(error.localizedDescription))"
        }
    }

    private func finish(_ id: UUID) {
        isStreaming = false
        task = nil
        allowedReplies.remove(id)
        if let index = messages.firstIndex(where: { $0.id == id }) {
            // Cards still waiting when the request ended never ran.
            if var rounds = messages[index].rounds {
                for round in rounds.indices {
                    for step in rounds[round].steps.indices
                    where [.waiting, .queued, .running].contains(rounds[round].steps[step].status) {
                        rounds[round].steps[step].status = .cancelled
                    }
                }
                messages[index].rounds = rounds
            }
            // Stopped before anything arrived: drop the empty card.
            if messages[index].text.isEmpty, (messages[index].rounds ?? []).isEmpty {
                messages.remove(at: index)
            }
        }
        saver.schedule()
    }

    // MARK: - Request

    private func systemPrompt(withTools: Bool) -> String {
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
        prompt += "\n\nIt is now \(NotchTools.stamp(Date())), time zone \(TimeZone.current.identifier)."
        if withTools {
            prompt += """


            You can see and change things in the user's notch with tools: to-dos, timers, music, notes, the \
            calendar, the clipboard and screenshots. Use them whenever a request is about those, and look things \
            up with them instead of guessing. The user approves every change on a card before it happens, so call \
            the tool rather than asking for permission in words. Never say something was done unless its tool \
            result says so, and if the user says no, accept it. When a task takes several steps, take them one \
            after another, then sum up in a sentence or two.
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
        func add(_ turn: ChatTurn) {
            // Two plain turns in a row from one side (after an error, say) become one.
            if let last = result.last, last.role == turn.role, turn.role != .tool,
               last.toolCalls.isEmpty, turn.toolCalls.isEmpty {
                result[result.count - 1] = ChatTurn(role: turn.role, text: last.text + "\n\n" + turn.text,
                                                    imageJPEG: turn.imageJPEG ?? last.imageJPEG)
            } else {
                result.append(turn)
            }
        }
        for (index, message) in messages.enumerated() where !message.isError && !message.isLocal {
            if message.role == .user {
                guard !message.text.isEmpty else { continue }
                // A question whose answer failed is left out: asked again it
                // would ride along with the next one, tools and all.
                if index + 1 < messages.count, messages[index + 1].isError { continue }
                add(ChatTurn(role: .user, text: message.text, imageJPEG: index == latestImage ? message.imageJPEG : nil))
                continue
            }
            for round in message.rounds ?? [] {
                add(ChatTurn(role: .assistant, text: round.text, toolCalls: round.steps.map(\.call)))
                add(ChatTurn(role: .tool, text: "", toolResults: round.steps.map {
                    ToolResult(callID: $0.call.id, name: $0.call.name,
                               content: $0.result ?? NotchTools.json(["error": "It didn't run."]))
                }))
            }
            // Follow-up suggestions are for the user, not the conversation.
            let text = ChatMarkdown.splitFollowUps(message.text).body
            if !text.isEmpty {
                add(ChatTurn(role: .assistant, text: text))
            }
        }
        result = Array(result.suffix(40))
        // Start with the user, and never with half of a tool exchange.
        while let first = result.first, first.role != .user {
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

    /// The turns a conversation would send, for the self-test.
    func debugTurns(for sample: [ChatMessage]) -> [ChatTurn] {
        let saved = messages
        messages = sample
        defer { messages = saved }
        return turns()
    }

    /// What each round of the last requests did, for `scripts/debug.sh status`.
    @ObservationIgnored private(set) var debugLog: [String] = []

    private func debugNote(_ line: String) {
        debugLog.append(line)
        if debugLog.count > 12 { debugLog.removeFirst(debugLog.count - 12) }
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

    /// A reply that used tools, for snapshots: a lookup, a change done, one
    /// waiting for Allow, and one declined.
    func withToolSample(_ body: () -> Void) {
        let saved = messages
        func call(_ name: String, _ args: [String: Any]) -> ToolCall {
            ToolCall(id: ToolCall.localID(), name: name,
                     arguments: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8))
        }
        var reply = ChatMessage(role: .assistant, text: "")
        reply.model = "gemini-3.1-flash-lite"
        reply.rounds = [
            ToolRound(text: "", steps: [
                ToolStep(call: call("get_agenda", [:]), status: .done, title: "Checked your calendar"),
            ]),
            ToolRound(text: "You're free after 3. I'll plan around the design review:", steps: [
                ToolStep(call: call("add_todo", ["title": "Prep review notes"]), status: .done,
                         title: "Added **Prep review notes** to today", openModule: "todos"),
                ToolStep(call: call("start_timer", ["kind": "focus"]), status: .waiting,
                         title: "Start a **25-minute** focus"),
                ToolStep(call: call("add_calendar_event", ["title": "Walk"]), status: .waiting,
                         title: "Add **Walk** to your calendar, Sat 4 Oct 17:30"),
                ToolStep(call: call("media", ["action": "pause"]), status: .declined, title: "Pause the music"),
            ]),
        ]
        messages = [ChatMessage(role: .user, text: "Plan my afternoon around the design review"), reply]
        isStreaming = true
        body()
        messages = saved
        isStreaming = false
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
