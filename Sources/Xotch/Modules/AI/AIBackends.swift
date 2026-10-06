import Foundation

/// A tool the model may call: its name, what it's for, and its arguments as
/// JSON Schema.
struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// JSON Schema for the arguments, encoded as JSON.
    let parameters: Data

    var parameterObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
    }

    /// True when the tool takes no arguments; Gemini wants those without a schema.
    var hasParameters: Bool {
        !((parameterObject["properties"] as? [String: Any]) ?? [:]).isEmpty
    }
}

/// The model asking to run a tool.
struct ToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// The arguments, as a JSON object.
    var arguments: Data
    /// Whatever the provider needs back exactly as it sent it: for Gemini, the
    /// whole part, thought signature included.
    var providerData: Data?

    var argumentObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
    }

    /// Ids for calls whose provider didn't send one.
    static func localID() -> String { "xotch-" + UUID().uuidString }
    var hasLocalID: Bool { id.hasPrefix("xotch-") }
}

/// What a tool returned, for the model.
struct ToolResult: Sendable {
    let callID: String
    let name: String
    let content: String
}

/// Something a backend streams back: reply text, or a request to run a tool.
enum ChatEvent: Sendable {
    case text(String)
    case toolCall(ToolCall)
}

/// One turn of the conversation as a backend sees it.
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant, tool }
    let role: Role
    let text: String
    /// A JPEG of the screen, sent with this turn.
    var imageJPEG: Data?
    /// The tools an assistant turn asked for.
    var toolCalls: [ToolCall] = []
    /// What they returned, in a tool turn.
    var toolResults: [ToolResult] = []
}

struct ChatRequest: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String?
    let system: String
    let turns: [ChatTurn]
    var maxTokens = 2048
    var tools: [ToolSpec] = []
}

struct AIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }

    /// The server turned the request down because of the tools, as a model
    /// without tool support does.
    static func isAboutTools(_ error: Error) -> Bool {
        let text = (error.localizedDescription).lowercased()
        return text.contains("tool") || text.contains("function call") || text.contains("function_call")
            || text.contains("functiondeclaration")
    }
}

/// Talks to one kind of AI service. Replies stream back as events.
protocol ChatBackend: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func models(baseURL: String, apiKey: String?) async throws -> [String]
}

/// Turns a streamed response, line by line, into events. One per request,
/// fed in order, so it can piece together tool calls that arrive in parts.
protocol StreamParser: AnyObject, Sendable {
    func parse(_ line: String) throws -> [ChatEvent]
    /// Anything still being assembled when the stream ends.
    func finish() -> [ChatEvent]
}

enum AIBackends {
    static func backend(for kind: ProviderKind) -> any ChatBackend {
        switch kind {
        case .ollama: OllamaBackend()
        case .openAICompatible, .openAI: OpenAICompatibleBackend(kind: kind)
        case .anthropic: AnthropicBackend()
        case .gemini: GeminiBackend()
        }
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - HTTP

private enum HTTP {
    /// Local models can take a while to load before the first word.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    static func url(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path), url.scheme?.hasPrefix("http") == true else {
            throw AIError("“\(base)” isn't a valid server address.")
        }
        return url
    }

    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                        body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    static func json(_ request: URLRequest, kind: ProviderKind) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw describe(error, kind: kind, url: request.url)
        }
        try check(response, body: data, kind: kind)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError("The server sent something that isn't JSON.")
        }
        return object
    }

    /// Streams the response line by line through `parser`.
    static func stream(_ request: URLRequest, kind: ProviderKind,
                       parser: any StreamParser) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        try check(response, body: body, kind: kind)
                    }
                    for try await line in bytes.lines {
                        for event in try parser.parse(line) {
                            if case .text(let text) = event, text.isEmpty { continue }
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as AIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: describe(error, kind: kind, url: request.url))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func check(_ response: URLResponse, body: Data, kind: ProviderKind) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let detail = serverMessage(in: body)
        switch http.statusCode {
        case 401, 403:
            throw AIError("\(kind.shortLabel) rejected the API key (\(http.statusCode)).\(detail.map { " \($0)" } ?? "")")
        case 404:
            throw AIError(detail ?? "Not found (404). Check the server address and model name.")
        case 429:
            throw AIError(detail ?? "Too many requests or out of credit (429). Try again shortly.")
        default:
            throw AIError(detail ?? "The server answered \(http.statusCode).")
        }
    }

    /// The human-readable part of an error body, whichever shape the service uses.
    static func serverMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        return nil
    }

    static func describe(_ error: Error, kind: ProviderKind, url: URL?) -> AIError {
        guard let urlError = error as? URLError else { return AIError(error.localizedDescription) }
        var host = url?.host ?? "the server"
        if let port = url?.port {
            host += ":\(port)"
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost:
            if kind == .ollama {
                return AIError("Can't reach Ollama at \(host). Open the Ollama app, or run `ollama serve` in Terminal.")
            }
            return AIError("Can't reach \(host). Is the server running?")
        case .notConnectedToInternet, .networkConnectionLost:
            return AIError("You're offline. A local model through Ollama works without the internet.")
        case .timedOut:
            return AIError("\(host) took too long to answer.")
        default:
            return AIError(urlError.localizedDescription)
        }
    }

    /// The payload of a server-sent-events `data:` line, or nil for anything else.
    static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload == "[DONE]" ? nil : payload
    }

    static func object(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// A failed stream, for a request that couldn't even be built.
    static func failing(_ error: Error) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

// MARK: - Ollama

private struct OllamaBackend: ChatBackend {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            var body: [String: Any] = ["model": request.model, "stream": true,
                                       "messages": Self.messages(request)]
            if !request.tools.isEmpty {
                body["tools"] = OpenAICompatibleBackend.tools(request.tools)
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/api/chat"), method: "POST", body: body)
            return HTTP.stream(urlRequest, kind: .ollama, parser: OllamaParser())
        } catch {
            return HTTP.failing(error)
        }
    }

    static func messages(_ request: ChatRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for turn in request.turns {
            switch turn.role {
            case .user:
                var message: [String: Any] = ["role": "user", "content": turn.text]
                if let image = turn.imageJPEG {
                    message["images"] = [image.base64EncodedString()]
                }
                messages.append(message)
            case .assistant:
                var message: [String: Any] = ["role": "assistant", "content": turn.text]
                if !turn.toolCalls.isEmpty {
                    message["tool_calls"] = turn.toolCalls.map { ["function": ["name": $0.name, "arguments": $0.argumentObject]] }
                }
                messages.append(message)
            case .tool:
                for result in turn.toolResults {
                    messages.append(["role": "tool", "content": result.content, "tool_name": result.name])
                }
            }
        }
        return messages
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let object = try await HTTP.json(try HTTP.request(try HTTP.url(baseURL, "/api/tags")), kind: .ollama)
        let models = object["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}

/// Ollama sends one JSON object per line; tool calls arrive whole.
final class OllamaParser: StreamParser, @unchecked Sendable {
    func parse(_ line: String) throws -> [ChatEvent] {
        guard let object = HTTP.object(line) else { return [] }
        if let error = object["error"] as? String { throw AIError(error) }
        let message = object["message"] as? [String: Any]
        var events: [ChatEvent] = []
        if let text = message?["content"] as? String {
            events.append(.text(text))
        }
        for call in message?["tool_calls"] as? [[String: Any]] ?? [] {
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
            let arguments = function["arguments"] as? [String: Any] ?? [:]
            events.append(.toolCall(ToolCall(id: call["id"] as? String ?? ToolCall.localID(), name: name,
                                             arguments: HTTP.data(arguments))))
        }
        return events
    }

    func finish() -> [ChatEvent] { [] }
}

// MARK: - OpenAI and compatible servers

/// OpenAI itself, LM Studio, llama.cpp, Groq, OpenRouter and anything else
/// that speaks `/chat/completions`.
private struct OpenAICompatibleBackend: ChatBackend {
    let kind: ProviderKind

    private func headers(_ key: String?) -> [String: String] {
        guard let key, !key.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    static func tools(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { ["type": "function",
                     "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameterObject]] }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            var body: [String: Any] = ["model": request.model, "stream": true, "messages": Self.messages(request)]
            if !request.tools.isEmpty {
                body["tools"] = Self.tools(request.tools)
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/chat/completions"), method: "POST",
                                              headers: headers(request.apiKey), body: body)
            return HTTP.stream(urlRequest, kind: kind, parser: OpenAIParser())
        } catch {
            return HTTP.failing(error)
        }
    }

    static func messages(_ request: ChatRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty {
            messages.append(["role": "system", "content": request.system])
        }
        for turn in request.turns {
            switch turn.role {
            case .user:
                if let image = turn.imageJPEG {
                    messages.append(["role": "user", "content": [
                        ["type": "text", "text": turn.text],
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
                    ]])
                } else {
                    messages.append(["role": "user", "content": turn.text])
                }
            case .assistant:
                var message: [String: Any] = ["role": "assistant", "content": turn.text]
                if !turn.toolCalls.isEmpty {
                    message["tool_calls"] = turn.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": String(decoding: call.arguments, as: UTF8.self)]]
                    }
                }
                messages.append(message)
            case .tool:
                for result in turn.toolResults {
                    messages.append(["role": "tool", "tool_call_id": result.callID, "content": result.content])
                }
            }
        }
        return messages
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let request = try HTTP.request(try HTTP.url(baseURL, "/models"), headers: headers(apiKey))
        let object = try await HTTP.json(request, kind: kind)
        var ids = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if kind == .openAI {
            // The list includes embeddings, speech and image models; keep the chat ones.
            let skip = ["embedding", "tts", "whisper", "dall-e", "image", "audio", "realtime", "transcribe",
                        "moderation", "search", "davinci", "babbage"]
            ids = ids.filter { id in !skip.contains { id.contains($0) } }
        }
        return ids.sorted()
    }
}

/// Tool calls arrive in pieces, keyed by index: the id and name first, then
/// the arguments a few characters at a time.
final class OpenAIParser: StreamParser, @unchecked Sendable {
    private var calls: [Int: (id: String?, name: String, arguments: String)] = [:]

    func parse(_ line: String) throws -> [ChatEvent] {
        guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return [] }
        if let error = object["error"] as? [String: Any] {
            throw AIError(error["message"] as? String ?? "The server reported an error.")
        }
        let choice = (object["choices"] as? [[String: Any]])?.first
        let delta = choice?["delta"] as? [String: Any]
        var events: [ChatEvent] = []
        if let text = delta?["content"] as? String {
            events.append(.text(text))
        }
        for part in delta?["tool_calls"] as? [[String: Any]] ?? [] {
            let index = part["index"] as? Int ?? calls.count
            var call = calls[index] ?? (id: nil, name: "", arguments: "")
            if let id = part["id"] as? String { call.id = id }
            let function = part["function"] as? [String: Any]
            if let name = function?["name"] as? String { call.name += name }
            if let arguments = function?["arguments"] as? String { call.arguments += arguments }
            calls[index] = call
        }
        if choice?["finish_reason"] is String {
            events += finish()
        }
        return events
    }

    func finish() -> [ChatEvent] {
        defer { calls = [:] }
        return calls.keys.sorted().compactMap { index in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return .toolCall(ToolCall(id: call.id ?? ToolCall.localID(), name: call.name,
                                      arguments: Data((arguments.isEmpty ? "{}" : arguments).utf8)))
        }
    }
}

// MARK: - Anthropic

private struct AnthropicBackend: ChatBackend {
    private func headers(_ key: String?) -> [String: String] {
        ["x-api-key": key ?? "", "anthropic-version": "2023-06-01"]
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            guard let key = request.apiKey, !key.isEmpty else { throw AIError("Add your Anthropic API key in Settings › AI.") }
            var body: [String: Any] = ["model": request.model, "max_tokens": request.maxTokens,
                                       "stream": true, "messages": Self.messages(request)]
            if !request.system.isEmpty {
                body["system"] = request.system
            }
            if !request.tools.isEmpty {
                body["tools"] = request.tools.map { ["name": $0.name, "description": $0.description,
                                                     "input_schema": $0.parameterObject] }
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/v1/messages"), method: "POST",
                                              headers: headers(key), body: body)
            return HTTP.stream(urlRequest, kind: .anthropic, parser: AnthropicParser())
        } catch {
            return HTTP.failing(error)
        }
    }

    static func messages(_ request: ChatRequest) -> [[String: Any]] {
        request.turns.compactMap { turn -> [String: Any]? in
            switch turn.role {
            case .user:
                var content: [[String: Any]] = []
                if let image = turn.imageJPEG {
                    content.append(["type": "image", "source": [
                        "type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString(),
                    ]])
                }
                content.append(["type": "text", "text": turn.text])
                return ["role": "user", "content": content]
            case .assistant:
                var content: [[String: Any]] = []
                if !turn.text.isEmpty {
                    content.append(["type": "text", "text": turn.text])
                }
                for call in turn.toolCalls {
                    content.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.argumentObject])
                }
                return content.isEmpty ? nil : ["role": "assistant", "content": content]
            case .tool:
                return ["role": "user", "content": turn.toolResults.map {
                    ["type": "tool_result", "tool_use_id": $0.callID, "content": $0.content]
                }]
            }
        }
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let request = try HTTP.request(try HTTP.url(baseURL, "/v1/models?limit=100"), headers: headers(apiKey))
        let object = try await HTTP.json(request, kind: .anthropic)
        return (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

/// Text arrives as deltas; a tool call opens a block, streams its input as
/// JSON fragments, and is complete when the block stops.
final class AnthropicParser: StreamParser, @unchecked Sendable {
    private var blocks: [Int: (id: String, name: String, json: String)] = [:]

    func parse(_ line: String) throws -> [ChatEvent] {
        guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return [] }
        let index = object["index"] as? Int ?? 0
        switch object["type"] as? String {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                blocks[index] = (id: block["id"] as? String ?? ToolCall.localID(), name: block["name"] as? String ?? "", json: "")
            }
            return []
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                return (delta?["text"] as? String).map { [.text($0)] } ?? []
            case "input_json_delta":
                blocks[index]?.json += delta?["partial_json"] as? String ?? ""
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let block = blocks.removeValue(forKey: index) else { return [] }
            let json = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.toolCall(ToolCall(id: block.id, name: block.name, arguments: Data((json.isEmpty ? "{}" : json).utf8)))]
        case "error":
            let error = object["error"] as? [String: Any]
            throw AIError(error?["message"] as? String ?? "Claude reported an error.")
        default:
            return []
        }
    }

    func finish() -> [ChatEvent] { [] }
}

// MARK: - Gemini

struct GeminiBackend: ChatBackend {
    private func headers(_ key: String?) -> [String: String] {
        ["x-goog-api-key": key ?? ""]
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            guard let key = request.apiKey, !key.isEmpty else { throw AIError("Add your Gemini API key in Settings › AI.") }
            let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
            let path = "/v1beta/models/\(model):streamGenerateContent?alt=sse"
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, path), method: "POST",
                                              headers: headers(key), body: Self.body(request))
            return HTTP.stream(urlRequest, kind: .gemini, parser: GeminiParser())
        } catch {
            return HTTP.failing(error)
        }
    }

    /// The request body. A tool call goes back as the very part Gemini sent,
    /// so its thought signature returns with it, as Gemini 3 needs to carry
    /// its reasoning across tool calls.
    static func body(_ request: ChatRequest) -> [String: Any] {
        let contents: [[String: Any]] = request.turns.compactMap { turn in
            switch turn.role {
            case .user:
                var parts: [[String: Any]] = []
                if let image = turn.imageJPEG {
                    parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]])
                }
                parts.append(["text": turn.text])
                return ["role": "user", "parts": parts]
            case .assistant:
                var parts: [[String: Any]] = []
                if !turn.text.isEmpty {
                    parts.append(["text": turn.text])
                }
                for call in turn.toolCalls {
                    if let data = call.providerData, let part = HTTP.object(data) {
                        parts.append(part)
                    } else {
                        parts.append(["functionCall": ["name": call.name, "args": call.argumentObject]])
                    }
                }
                return parts.isEmpty ? nil : ["role": "model", "parts": parts]
            case .tool:
                return ["role": "user", "parts": turn.toolResults.map { result -> [String: Any] in
                    // The response has to be an object.
                    let response = HTTP.object(result.content) ?? ["result": result.content]
                    var function: [String: Any] = ["name": result.name, "response": response]
                    if !result.callID.hasPrefix("xotch-") {
                        function["id"] = result.callID
                    }
                    return ["functionResponse": function]
                }]
            }
        }
        var body: [String: Any] = ["contents": contents]
        if !request.system.isEmpty {
            body["system_instruction"] = ["parts": [["text": request.system]]]
        }
        if !request.tools.isEmpty {
            body["tools"] = [["functionDeclarations": request.tools.map { tool -> [String: Any] in
                var declaration: [String: Any] = ["name": tool.name, "description": tool.description]
                if tool.hasParameters {
                    declaration["parameters"] = tool.parameterObject
                }
                return declaration
            }]]
        }
        return body
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let request = try HTTP.request(try HTTP.url(baseURL, "/v1beta/models?pageSize=200"), headers: headers(apiKey))
        let object = try await HTTP.json(request, kind: .gemini)
        let models = object["models"] as? [[String: Any]] ?? []
        return models.compactMap { model -> String? in
            guard let name = model["name"] as? String,
                  (model["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
        .sorted()
    }
}

/// Each chunk carries whole parts: text, or a function call to keep as it is.
final class GeminiParser: StreamParser, @unchecked Sendable {
    func parse(_ line: String) throws -> [ChatEvent] {
        guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return [] }
        if let error = object["error"] as? [String: Any] {
            throw AIError(error["message"] as? String ?? "Gemini reported an error.")
        }
        let candidate = (object["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { part -> ChatEvent? in
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let arguments = call["args"] as? [String: Any] ?? [:]
                return .toolCall(ToolCall(id: call["id"] as? String ?? ToolCall.localID(), name: name,
                                          arguments: HTTP.data(arguments), providerData: HTTP.data(part)))
            }
            // Thought summaries aren't part of the answer.
            if part["thought"] as? Bool == true { return nil }
            return (part["text"] as? String).map { .text($0) }
        }
    }

    func finish() -> [ChatEvent] { [] }
}
