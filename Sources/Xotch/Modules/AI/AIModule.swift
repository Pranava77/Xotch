import AppKit
import SwiftUI

@MainActor
final class AIModule: NotchModule {
    nonisolated static let moduleID = "ai"
    let id = AIModule.moduleID
    let title = "AI"
    let symbol = "sparkles"
    /// A conversation needs more height than the other modules, and the
    /// expand button gives it more room still.
    var openSize: CGSize {
        AIChatService.shared.isExpanded ? Layout.expandedAISize
            : CGSize(width: Layout.openSize.width, height: Layout.tallOpenHeight)
    }
    func expandedView() -> AnyView { AnyView(AIChatView()) }
}

private struct AIChatView: View {
    @Bindable private var chat = AIChatService.shared
    private var providers: AIProviderStore { .shared }

    var body: some View {
        if providers.providers.isEmpty {
            EmptyStateView(symbol: "sparkles",
                           title: "Connect an AI",
                           message: "Run a model on this Mac with Ollama or LM Studio, or add an API key for Claude, OpenAI or Gemini. Keys stay in your Keychain.",
                           buttonTitle: "Set up in Settings") { showSettings() }
        } else {
            VStack(spacing: 8) {
                Conversation(showSettings: showSettings)
                    .frame(maxHeight: .infinity)
                if let notice = chat.notice {
                    NoticeRow(text: notice, showSettings: showSettings)
                }
                InputBar(showSettings: showSettings)
                    .overlay(alignment: .topLeading) {
                        let commands = chat.slashSuggestions
                        if !commands.isEmpty {
                            SlashMenu(commands: commands) { command in
                                chat.draft = "/" + command.name + " "
                            }
                            .alignmentGuide(.top) { $0[.bottom] + 6 }
                            .padding(.leading, 120)
                            .transition(.opacity)
                        }
                    }
            }
        }
    }

    private func showSettings() {
        SettingsWindow.show(.ai)
    }
}

// MARK: - Conversation

private struct Conversation: View {
    let showSettings: () -> Void
    private var chat: AIChatService { .shared }

    var body: some View {
        if chat.messages.isEmpty {
            Welcome()
        } else {
            ScrollViewReader { proxy in
                NotchScroll {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            let isLast = message.id == chat.messages.last?.id
                            MessageRow(message: message, isStreaming: chat.isStreaming && isLast, isLast: isLast)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 6)
                }
                // Text scrolling up fades out before it reaches the tabs.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                        Color.black
                    }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(Motion.switchModule) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

/// Before the first message: what the chat can do, as four cards across
/// the width, beside a short greeting naming the model in use.
private struct Welcome: View {
    private var contexts: AIContextStore { .shared }
    private var providers: AIProviderStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Ask anything")
                    .font(.system(size: 18, weight: .semibold))
                if let provider = providers.active {
                    Label(provider.model, systemImage: provider.isLocal ? "lock.fill" : "cloud.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 150, alignment: .leading)
            .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                card("keyboard", "From any app", "⌘⇧Space opens this chat wherever you are.")
                card("display", "About your screen", "⌘⇧↩, or the screen button below, sends what's on screen with your question.")
                if let context = contexts.active {
                    card("person.text.rectangle", "Using “\(context.name)”", "Answers draw on this context. Switch it from the menu below.")
                } else {
                    card("person.text.rectangle", "Add a context", "A resume, job description or notes, sent with every question.")
                }
                if let provider = providers.active {
                    card(provider.isLocal ? "lock" : "cloud",
                         provider.isLocal ? "Stays on this Mac" : "Sent to \(provider.name)",
                         provider.isLocal ? "\(provider.model) runs locally; nothing goes to the internet."
                             : "Your messages go to \(provider.name) to be answered.")
                } else {
                    card("cpu", "Pick a model", "Choose one from the menu below.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isLast: Bool
    private var isExpanded: Bool { AIChatService.shared.isExpanded }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 90)
                VStack(alignment: .trailing, spacing: 3) {
                    if message.hadScreenshot {
                        Label("Screen", systemImage: "display")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.tertiaryInk)
                    }
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.22)))
                }
                .frame(maxWidth: isExpanded ? 600 : 440, alignment: .trailing)
            }
        } else {
            ReplyCard(message: message, isStreaming: isStreaming, isLast: isLast)
                // About 80 characters a line (100 when bigger): easier to
                // read than the full width.
                .frame(maxWidth: isExpanded ? 790 : 580, alignment: .leading)
        }
    }
}

/// An answer in a soft card: who wrote it and when on top, then the reply,
/// then what you can do with it. The last answer offers follow-up questions.
private struct ReplyCard: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isLast: Bool
    @State private var hovering = false
    @State private var copied = false
    private var chat: AIChatService { .shared }

    var body: some View {
        let parts = ChatMarkdown.splitFollowUps(message.text)
        let rounds = message.rounds ?? []
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 9) {
                header
                // Each round of a reply that used tools: what it said, then its cards.
                ForEach(Array(rounds.enumerated()), id: \.offset) { _, round in
                    if !round.text.isEmpty {
                        RichText(text: round.text)
                    }
                    ToolSteps(steps: round.steps, reply: message)
                }
                if !parts.body.isEmpty {
                    RichText(text: parts.body, isStreaming: isStreaming)
                        .foregroundStyle(message.isError ? Theme.secondaryInk : Theme.ink)
                } else if isStreaming, !rounds.flatMap(\.steps).contains(where: { $0.status == .waiting }) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 16)
                }
                if message.isError {
                    Button("Try again") { chat.retry() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                } else if !isStreaming, !parts.body.isEmpty, !message.isLocal {
                    actions
                        .opacity(isLast || hovering ? 1 : 0)
                        .allowsHitTesting(isLast || hovering)
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 10)
            .padding(.bottom, message.isError || isStreaming ? 12 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            .onHover { hovering = $0 }

            if isLast, !isStreaming, !parts.followUps.isEmpty {
                FollowUps(questions: parts.followUps)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : message.isLocal ? "command" : "sparkles")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(message.isError ? Theme.negative : Theme.accent)
            Text(message.model ?? "AI")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
                .foregroundStyle(Theme.tertiaryInk)
            Text(message.date, format: .dateTime.hour().minute())
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryInk)
        }
        .font(.system(size: 10.5))
    }

    /// Copy for every answer; the rest change the last one.
    private var actions: some View {
        HStack(spacing: 2) {
            action(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc", tint: copied ? Theme.positive : nil) {
                chat.copy(message)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            }
            if isLast {
                action("Retry", "arrow.clockwise") { chat.regenerate(message, as: .retry) }
                action("Shorter", "minus.circle") { chat.regenerate(message, as: .shorter) }
                action("Longer", "plus.circle") { chat.regenerate(message, as: .longer) }
            }
        }
        .padding(.leading, -6)
    }

    private func action(_ title: String, _ symbol: String, tint: Color? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint ?? Theme.secondaryInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 7))
        .debugFrame("ai.reply.\(title.lowercased())")
    }
}

/// The cards for one round of tool calls. Anything that changes or shares
/// something waits on Allow; looking things up shows as a quiet line.
private struct ToolSteps: View {
    let steps: [ToolStep]
    let reply: ChatMessage
    private var chat: AIChatService { .shared }

    var body: some View {
        let waiting = steps.filter { $0.status == .waiting }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                if NotchTools.tool(named: step.call.name)?.asks == false, step.status != .failed {
                    // Lookups are a quiet line; a failed one becomes a card so it can offer a fix.
                    lookedUp(step)
                } else {
                    card(step, offersAllowAll: waiting.count > 1 && step.id == waiting.first?.id)
                }
            }
        }
    }

    private static let calendarTools: Set<String> = ["get_agenda", "add_calendar_event", "complete_reminder"]

    /// "Checked your calendar", with a spinner while it looks.
    private func lookedUp(_ step: ToolStep) -> some View {
        HStack(spacing: 6) {
            if step.status == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "eye")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(ChatMarkdown.inline(step.title))
                .font(.system(size: 11.5))
        }
        .foregroundStyle(Theme.tertiaryInk)
        .padding(.vertical, 1)
    }

    private func card(_ step: ToolStep, offersAllowAll: Bool) -> some View {
        let tool = NotchTools.tool(named: step.call.name)
        let tint = tool?.tint ?? Theme.accent
        let faded = [.declined, .cancelled, .undone, .queued].contains(step.status)
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(faded ? 0.08 : 0.18))
                Image(systemName: tool?.symbol ?? "wrench.and.screwdriver")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(faded ? Theme.tertiaryInk : tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(ChatMarkdown.inline(step.title))
                    .font(.system(size: 12.5))
                    .strikethrough(step.status == .declined || step.status == .undone)
                    .foregroundStyle(faded ? Theme.tertiaryInk : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = note(for: step) {
                    Text(note)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(step.status == .failed ? Theme.negative : Theme.tertiaryInk)
                }
            }
            Spacer(minLength: 8)
            buttons(step, offersAllowAll: offersAllowAll)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.raisedFill.opacity(faded ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(step.status == .waiting ? tint.opacity(0.45) : Theme.hairline))
    }

    private func note(for step: ToolStep) -> String? {
        switch step.status {
        case .waiting: "Needs your OK"
        case .queued: "Next"
        case .running: "Working…"
        case .done: nil
        case .declined: "You said no"
        case .failed: "Didn't work"
        case .cancelled: "Stopped"
        case .undone: "Undone"
        }
    }

    @ViewBuilder private func buttons(_ step: ToolStep, offersAllowAll: Bool) -> some View {
        switch step.status {
        case .waiting:
            HStack(spacing: 6) {
                Button("Don't") { chat.decide(step, allow: false) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .debugFrame("ai.tool.dont")
                if offersAllowAll {
                    Button("Allow all") { chat.allowAll(in: reply) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .debugFrame("ai.tool.allowall")
                }
                Button("Allow") { chat.decide(step, allow: true) }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .debugFrame("ai.tool.allow")
            }
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.positive)
                if chat.canUndo(step) {
                    Button("Undo") { chat.undo(step, in: reply) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .debugFrame("ai.tool.undo")
                }
                if let module = step.openModule, let info = ModuleRegistry.module(id: module)?.info {
                    Button { ScreenManager.shared.show(moduleID: module) } label: {
                        Image(systemName: "arrow.up.forward")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Open \(info.title)")
                }
            }
        case .failed:
            if Self.calendarTools.contains(step.call.name), CalendarService.shared.eventAccess != .granted {
                Button("Allow Calendar") { CalendarService.shared.requestAccess() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .help("Lets Xotch read and add events, then ask again")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.negative)
            }
        case .queued, .declined, .cancelled, .undone:
            EmptyView()
        }
    }
}

/// Commands for a typed slash, above the input.
private struct SlashMenu: View {
    let commands: [AIChatService.SlashCommand]
    let choose: (AIChatService.SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(commands) { command in
                Button { choose(command) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: command.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text("/" + command.name)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        Text(command.hint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 7))
            }
        }
        .padding(5)
        .frame(width: 330)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.raisedFill))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Questions the model suggests asking next, one click each.
private struct FollowUps: View {
    let questions: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(questions, id: \.self) { question in
                Button { AIChatService.shared.ask(question) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent)
                        Text(question)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Ask “\(question)”")
            }
        }
        .padding(.leading, 4)
    }
}

private struct NoticeRow: View {
    let text: String
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.negative)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(2)
            Spacer(minLength: 4)
            if text.contains("Screen Recording") {
                Button("Open Privacy Settings") { PrivacyPane.screenCapture.open() }
                    .buttonStyle(PillButtonStyle(prominent: false))
            } else if text.contains("Settings") {
                Button("Open Settings", action: showSettings)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            Button { AIChatService.shared.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 20))
        }
    }
}

// MARK: - Input

private struct InputBar: View {
    let showSettings: () -> Void
    @Bindable private var chat = AIChatService.shared
    private var providers: AIProviderStore { .shared }
    private var contexts: AIContextStore { .shared }
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 6) {
            Chip(symbol: "person.text.rectangle", text: contexts.active?.name ?? "No context",
                 dimmed: contexts.active == nil) { contextMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
                .help("Background the AI keeps in mind")

            HStack(spacing: 6) {
                if let attachment = chat.attachment {
                    AttachmentThumb(jpeg: attachment)
                }
                if snapshotMode {
                    Text(chat.draft.isEmpty ? placeholder : chat.draft)
                        .foregroundStyle(chat.draft.isEmpty ? Theme.tertiaryInk : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $chat.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { chat.send() }
                        .debugFrame("ai.input")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                Task { await chat.captureScreen() }
            } label: {
                if chat.isCapturing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: chat.attachment == nil ? "display" : "arrow.clockwise")
                }
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help(chat.attachment == nil ? "Attach your screen  ⌘⇧↩" : "Take the screen again")
            .debugFrame("ai.screen")

            if WhistleEngine.isSupported {
                let dictation = DictationService.shared
                Button {
                    if dictation.isListening {
                        dictation.finish()
                    } else {
                        dictation.start(handsFree: true, into: .aiDraft)
                    }
                } label: {
                    if dictation.phase == .finishing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: dictation.isListening ? "stop.fill" : "mic")
                            .foregroundStyle(dictation.isListening ? DictationService.tint : Theme.ink)
                    }
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help(dictation.isListening ? "Finish dictating" : "Dictate your question")
                .debugFrame("ai.mic")
            }

            Chip(symbol: providers.active?.isLocal == true ? "desktopcomputer" : "cloud",
                 text: modelLabel, dimmed: false) { modelMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
                .help("Provider and model")

            if chat.isStreaming {
                Button { chat.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(IconButtonStyle(size: 28, prominent: true))
                    .help("Stop")
            } else {
                Button { chat.send() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(IconButtonStyle(size: 28, prominent: true))
                    .disabled(!chat.canSend)
                    .help("Send  ↩")
                    .debugFrame("ai.send")
            }
            Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle(size: 28))
                .disabled(chat.messages.isEmpty || chat.isStreaming)
                .help("New chat")
                .debugFrame("ai.new")
            Button { chat.toggleExpanded() } label: {
                Image(systemName: chat.isExpanded ? "arrow.down.right.and.arrow.up.left"
                                                  : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help(chat.isExpanded ? "Make smaller" : "Make bigger")
            .accessibilityLabel(chat.isExpanded ? "Make the chat smaller" : "Make the chat bigger")
            .debugFrame("ai.expand")
        }
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: chat.wantsFocus) { _, _ in takeFocusIfAsked() }
    }

    private var placeholder: String {
        chat.attachment == nil ? "Ask anything, or type / for commands…" : "Ask about your screen…"
    }

    private var modelLabel: String {
        guard let provider = providers.active else { return "No provider" }
        return provider.model.isEmpty ? provider.name : provider.model
    }

    private func takeFocusIfAsked() {
        guard chat.wantsFocus else { return }
        chat.wantsFocus = false
        // The panel becomes key as the notch opens; focus once it has.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let none = ClosureMenuItem("No context") { contexts.activate(nil) }
        none.state = contexts.active == nil ? .on : .off
        menu.addItem(none)
        for profile in contexts.profiles {
            let item = ClosureMenuItem(profile.name) { contexts.activate(profile.id) }
            item.state = profile.id == contexts.activeID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add or Edit Contexts…", handler: showSettings))
        return menu
    }

    private func modelMenu() -> NSMenu {
        let menu = NSMenu()
        let active = providers.active?.id
        for provider in providers.providers {
            // Choosing a provider keeps its model; its submenu switches model.
            let item = ClosureMenuItem(provider.name) { providers.activate(provider.id) }
            item.state = provider.id == active ? .on : .off
            menu.addItem(item)

            let models = providers.models[provider.id] ?? []
            let listed = provider.model.isEmpty || models.contains(provider.model) ? models : [provider.model] + models
            guard listed.count > 1 else { continue }
            let submenu = NSMenu()
            for model in listed {
                let choice = ClosureMenuItem(model) {
                    providers.setModel(model, for: provider.id)
                    providers.activate(provider.id)
                }
                choice.state = model == provider.model ? .on : .off
                submenu.addItem(choice)
            }
            let modelsItem = NSMenuItem(title: "\(provider.name) Models", action: nil, keyEquivalent: "")
            modelsItem.indentationLevel = 1
            modelsItem.submenu = submenu
            menu.addItem(modelsItem)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Refresh Model Lists") {
            Task {
                for provider in providers.providers {
                    _ = try? await providers.refreshModels(for: provider.id)
                }
            }
        })
        menu.addItem(ClosureMenuItem("Manage Providers…", handler: showSettings))
        return menu
    }
}

/// A small capsule that opens a menu.
private struct Chip: View {
    let symbol: String
    let text: String
    let dimmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            .foregroundStyle(dimmed ? Theme.secondaryInk : Theme.ink)
            .padding(.horizontal, 9)
            .frame(height: 28)
            // Wide enough that a model name keeps its distinguishing end.
            .frame(maxWidth: 220)
            .background(Theme.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

private struct AttachmentThumb: View {
    let jpeg: Data

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = NSImage(data: jpeg) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline))
            }
            Button { AIChatService.shared.attachment = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink, Theme.surface)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Don't send the screen")
        }
    }
}
