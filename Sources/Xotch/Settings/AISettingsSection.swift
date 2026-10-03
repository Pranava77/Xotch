import SwiftUI

/// Settings › AI: providers and their keys, shortcuts, sharing, and contexts.
struct AISettingsSection: View {
    @AppStorage(SettingsKey.hideFromScreenSharing) private var hideFromSharing = false
    @AppStorage(SettingsKey.aiQuickAskHotKey) private var quickAskHotKey = true
    @AppStorage(SettingsKey.aiScreenHotKey) private var screenHotKey = true
    @State private var editingProvider: ProviderDraft?
    @State private var editingContext: ContextProfile?
    @State private var removingProvider: ProviderConfig?
    private var providers: AIProviderStore { .shared }
    private var contexts: AIContextStore { .shared }

    var body: some View {
        Section {
            ForEach(providers.providers) { provider in
                HStack(spacing: 10) {
                    Image(systemName: provider.id == providers.active?.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(provider.id == providers.active?.id ? Color.accentColor : .secondary)
                        .onTapGesture { providers.activate(provider.id) }
                        .accessibilityLabel(provider.id == providers.active?.id ? "In use" : "Use \(provider.name)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name)
                        Text("\(provider.kind.shortLabel) · \(provider.model.isEmpty ? "no model" : provider.model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") { editingProvider = ProviderDraft(config: provider, isNew: false) }
                    Button {
                        removingProvider = provider
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(provider.name)")
                }
            }
            Menu("Add Provider") {
                ForEach(ProviderKind.allCases) { kind in
                    Button(kind.label) { editingProvider = ProviderDraft(config: .new(kind), isNew: true) }
                }
            }
            .fixedSize()
        } header: {
            Text("AI")
        } footer: {
            Text("Ollama and LM Studio run models on this Mac, so nothing leaves it. Cloud providers receive your messages, your context and any screenshot you send. API keys are kept in your Keychain.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editingProvider) { draft in
            ProviderEditor(draft: draft)
        }
        .confirmationDialog("Remove \(removingProvider?.name ?? "provider")?",
                            isPresented: Binding(get: { removingProvider != nil },
                                                 set: { if !$0 { removingProvider = nil } }),
                            presenting: removingProvider) { provider in
            Button("Remove", role: .destructive) { providers.delete(provider.id) }
        } message: { _ in
            Text("Its API key is deleted from the Keychain too.")
        }

        Section {
            Toggle("\(GlobalHotKeys.Action.quickAsk.label) opens the AI chat from any app", isOn: $quickAskHotKey)
            Toggle("\(GlobalHotKeys.Action.askAboutScreen.label) asks the AI about your screen", isOn: $screenHotKey)
            if !GlobalHotKeys.taken.isEmpty {
                Text("Another app already uses \(GlobalHotKeys.taken.map(\.label).sorted().joined(separator: " and ")). Turn the shortcut off in that app, then switch it off and on here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Toggle("Hide the notch from screen sharing and recordings", isOn: $hideFromSharing)
            LabeledContent("Screen questions") {
                Button("Screen Recording Settings…") { PrivacyPane.screenCapture.open() }
            }
        } header: {
            Text("AI shortcuts and privacy")
        } footer: {
            Text("Asking about your screen needs Screen Recording permission. Hiding asks macOS to leave the notch out of shared screens and recordings, but some apps and macOS versions capture it anyway — check with a test call before relying on it.")
                .foregroundStyle(.secondary)
        }

        Section {
            ForEach(contexts.profiles) { profile in
                HStack(spacing: 10) {
                    Image(systemName: profile.id == contexts.activeID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.id == contexts.activeID ? Color.accentColor : .secondary)
                        .onTapGesture { contexts.activate(profile.id == contexts.activeID ? nil : profile.id) }
                        .accessibilityLabel(profile.id == contexts.activeID ? "In use" : "Use \(profile.name)")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                        Text("\(profile.text.count.formatted()) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editingContext = profile }
                    Button {
                        contexts.delete(profile.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(profile.name)")
                }
            }
            HStack {
                Button("New Context…") { editingContext = ContextProfile(name: "", text: "") }
                Button("Import File…") {
                    if let file = AIContextStore.importFile() {
                        editingContext = ContextProfile(name: file.name, text: file.text)
                    }
                }
            }
        } header: {
            Text("AI context")
        } footer: {
            Text("The context in use goes with every question, so answers fit your resume, a job description or a topic you're studying. Import a PDF, text or Markdown file, or paste it in.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editingContext) { profile in
            ContextEditor(profile: profile)
        }
    }
}

struct ProviderDraft: Identifiable {
    var config: ProviderConfig
    let isNew: Bool
    var id: UUID { config.id }
}

// MARK: - Provider editor

private struct ProviderEditor: View {
    let isNew: Bool
    @State private var config: ProviderConfig
    @State private var key: String
    @State private var models: [String]
    @State private var status: (ok: Bool, text: String)?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    init(draft: ProviderDraft) {
        isNew = draft.isNew
        _config = State(initialValue: draft.config)
        _key = State(initialValue: draft.isNew ? "" : (AIKeychain.get(draft.config.id) ?? ""))
        _models = State(initialValue: AIProviderStore.shared.models[draft.config.id] ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Service", selection: $config.kind) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: config.kind) { old, new in kindChanged(from: old, to: new) }
                TextField("Name", text: $config.name)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Server", text: $config.baseURL)
                    if config.kind == .openAICompatible {
                        Text("LM Studio: http://localhost:1234/v1 · Groq: https://api.groq.com/openai/v1 · OpenRouter: https://openrouter.ai/api/v1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if config.kind.usesKey {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("API key", text: $key,
                                    prompt: Text(config.kind.keyIsOptional ? "Optional" : "Required"))
                        Text(config.kind.keyHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        TextField("Model", text: $config.model,
                                  prompt: Text(config.kind.defaultModel.isEmpty ? "Load the list, or type a name"
                                               : config.kind.defaultModel))
                            .labelsHidden()
                        if !models.isEmpty {
                            Menu {
                                ForEach(models, id: \.self) { model in
                                    Button(model) { config.model = model }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Choose from \(models.count) models")
                        }
                        Button("Load List") { loadModels() }
                            .disabled(working)
                    }
                }
                if let status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? Color.green : Color.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Test Connection") { test() }
                    .disabled(working || config.model.isEmpty)
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    AIProviderStore.shared.save(config, key: key)
                    if !models.isEmpty {
                        AIProviderStore.shared.remember(models: models, for: config.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 480)
    }

    private var canSave: Bool {
        !config.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.model.trimmingCharacters(in: .whitespaces).isEmpty
            && (!config.kind.usesKey || config.kind.keyIsOptional || !key.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var keyForRequests: String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fields still showing the old service's defaults follow the new one.
    private func kindChanged(from old: ProviderKind, to new: ProviderKind) {
        if config.baseURL.isEmpty || config.baseURL == old.defaultBaseURL { config.baseURL = new.defaultBaseURL }
        if config.model.isEmpty || config.model == old.defaultModel { config.model = new.defaultModel }
        if config.name.isEmpty || config.name == old.shortLabel { config.name = new.shortLabel }
        models = []
        status = nil
    }

    private func loadModels() {
        working = true
        status = nil
        let backend = AIBackends.backend(for: config.kind)
        let baseURL = config.baseURL
        let key = keyForRequests
        let kind = config.kind
        Task {
            defer { working = false }
            do {
                let list = try await backend.models(baseURL: baseURL, apiKey: key)
                models = list
                if list.isEmpty {
                    status = (false, kind == .ollama
                              ? "Ollama has no models yet. Run `ollama pull llama3.2` (or llama3.2-vision for screen questions) in Terminal."
                              : "The server didn't list any models. Type the model's name instead.")
                } else {
                    status = (true, "Found \(list.count) models.")
                    if config.model.isEmpty || !list.contains(config.model) {
                        config.model = list.first { $0 == kind.defaultModel } ?? list[0]
                    }
                }
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }

    private func test() {
        working = true
        status = nil
        let request = ChatRequest(baseURL: config.baseURL, model: config.model, apiKey: keyForRequests, system: "",
                                  turns: [ChatTurn(role: .user, text: "Reply with just the word: ready")],
                                  maxTokens: 20)
        let backend = AIBackends.backend(for: config.kind)
        Task {
            defer { working = false }
            do {
                var reply = ""
                for try await piece in backend.stream(request) {
                    reply += piece
                    if reply.count > 200 { break }
                }
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                status = trimmed.isEmpty
                    ? (false, "Connected, but the model sent an empty reply.")
                    : (true, "Connected. \(config.model) replied “\(trimmed.prefix(60))”.")
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }
}

// MARK: - Context editor

private struct ContextEditor: View {
    @State var profile: ContextProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $profile.name, prompt: Text("Resume, Acme interview, Rust notes…"))
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $profile.text)
                .font(.body)
                .frame(height: 300)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                let over = profile.text.count > AIContextStore.characterLimit
                Text(over ? "Only the first \(AIContextStore.characterLimit.formatted()) characters are kept."
                          : "\(profile.text.count.formatted()) of \(AIContextStore.characterLimit.formatted()) characters")
                    .font(.caption)
                    .foregroundStyle(over ? Color.red : Color.secondary)
                Spacer()
                Button("Add From File…") {
                    guard let file = AIContextStore.importFile() else { return }
                    profile.text += (profile.text.isEmpty ? "" : "\n\n") + file.text
                    if profile.name.isEmpty { profile.name = file.name }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    AIContextStore.shared.save(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || profile.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
