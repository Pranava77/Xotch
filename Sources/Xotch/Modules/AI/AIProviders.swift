import Foundation
import Observation
import Security

/// The kinds of AI service the chat can talk to. Each saved provider is one of
/// these plus a URL, a model and (in the Keychain) a key.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, openAICompatible, openAI, anthropic, gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama: "Ollama (on this Mac)"
        case .openAICompatible: "OpenAI-compatible server"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic (Claude)"
        case .gemini: "Google Gemini"
        }
    }

    var shortLabel: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "Custom"
        case .openAI: "OpenAI"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:1234/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com"
        }
    }

    /// A sensible first choice; the model list in Settings shows the rest.
    var defaultModel: String {
        switch self {
        case .ollama: "llama3.2"
        case .openAICompatible: ""
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-sonnet-5-5"
        case .gemini: "gemini-2.5-flash"
        }
    }

    var usesKey: Bool { self != .ollama }
    /// LM Studio and llama.cpp don't want one; Groq and OpenRouter do.
    var keyIsOptional: Bool { self == .openAICompatible }
    var isLocal: Bool { self == .ollama }

    var keyHint: String {
        switch self {
        case .ollama: ""
        case .openAICompatible: "Only if the server asks for one"
        case .openAI: "platform.openai.com › API keys"
        case .anthropic: "console.anthropic.com › API keys"
        case .gemini: "aistudio.google.com › Get API key"
        }
    }
}

struct ProviderConfig: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var model: String

    static func new(_ kind: ProviderKind) -> ProviderConfig {
        ProviderConfig(kind: kind, name: kind.shortLabel, baseURL: kind.defaultBaseURL, model: kind.defaultModel)
    }

    var apiKey: String? { AIKeychain.get(id) }

    /// Runs on this Mac or the local network, so messages stay off the internet.
    var isLocal: Bool {
        if kind.isLocal { return true }
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }
}

/// API keys live in the login Keychain, never in the JSON files or defaults.
enum AIKeychain {
    private static let service = "com.pranava.xotch"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "ai.\(id.uuidString)",
        ]
    }

    static func get(_ id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func set(_ key: String, for id: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(id)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Xotch AI key"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

private struct ProvidersFile: Codable {
    var providers: [ProviderConfig]
    var activeID: UUID?
}

/// The providers someone has set up, and which one the chat uses.
@MainActor
@Observable
final class AIProviderStore {
    static let shared = AIProviderStore()

    private(set) var providers: [ProviderConfig]
    private(set) var activeID: UUID?
    /// Models each provider offered when last asked, for the pickers.
    private(set) var models: [UUID: [String]] = [:]

    init() {
        let file = Storage.load(ProvidersFile.self, from: "ai-providers.json")
        providers = file?.providers ?? []
        activeID = file?.activeID
    }

    var active: ProviderConfig? {
        providers.first { $0.id == activeID } ?? providers.first
    }

    func provider(id: UUID) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    func save(_ config: ProviderConfig, key: String?) {
        if let index = providers.firstIndex(where: { $0.id == config.id }) {
            providers[index] = config
        } else {
            providers.append(config)
            if providers.count == 1 { activeID = config.id }
        }
        if let key, config.kind.usesKey {
            AIKeychain.set(key, for: config.id)
        }
        persist()
    }

    func delete(_ id: UUID) {
        providers.removeAll { $0.id == id }
        AIKeychain.delete(id)
        models[id] = nil
        if activeID == id { activeID = providers.first?.id }
        persist()
    }

    func activate(_ id: UUID) {
        activeID = id
        persist()
    }

    func setModel(_ model: String, for id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].model = model
        persist()
    }

    /// Asks the provider which models it has. Errors are left for the caller to show.
    @discardableResult
    func refreshModels(for id: UUID) async throws -> [String] {
        guard let config = provider(id: id) else { return [] }
        let list = try await AIBackends.backend(for: config.kind).models(baseURL: config.baseURL, apiKey: config.apiKey)
        models[id] = list
        return list
    }

    /// For lists fetched before the provider was saved, e.g. in its editor.
    func remember(models list: [String], for id: UUID) {
        models[id] = list
    }

    private func persist() {
        Storage.save(ProvidersFile(providers: providers, activeID: activeID), to: "ai-providers.json")
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (providers, activeID)
        let local = ProviderConfig(kind: .ollama, name: "Ollama", baseURL: ProviderKind.ollama.defaultBaseURL,
                                   model: "llama3.2-vision")
        providers = [local, .new(.anthropic)]
        activeID = local.id
        body()
        (providers, activeID) = saved
    }
    #endif
}
