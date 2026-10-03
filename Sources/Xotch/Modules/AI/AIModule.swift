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
                            MessageRow(message: message,
                                       isStreaming: chat.isStreaming && message.id == chat.messages.last?.id)
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
    @State private var hovering = false
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
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: isExpanded ? 600 : 440, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.isError ? Theme.negative : Theme.accent)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if message.text.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 16)
                    } else {
                        RichText(text: message.text)
                            .foregroundStyle(message.isError ? Theme.secondaryInk : Theme.ink)
                    }
                    if message.isError {
                        Button("Try again") { AIChatService.shared.retry() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
                // About 80 characters a line (100 when bigger): easier to
                // read than the full width.
                .frame(maxWidth: isExpanded ? 760 : 540, alignment: .leading)
                Spacer(minLength: 20)
                Button { AIChatService.shared.copy(message) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Copy")
                    .opacity(hovering && !isStreaming && !message.isError ? 1 : 0)
                    .allowsHitTesting(hovering && !isStreaming && !message.isError)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
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
        chat.attachment == nil ? "Ask anything…" : "Ask about your screen…"
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
