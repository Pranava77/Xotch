import Foundation

/// One turn of the conversation as a backend sees it.
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
    /// A JPEG of the screen, sent with this turn.
    var imageJPEG: Data?
}

struct ChatRequest: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String?
    let system: String
    let turns: [ChatTurn]
    var maxTokens = 2048
}

struct AIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Talks to one kind of AI service. Replies stream back as text fragments.
protocol ChatBackend: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error>
    func models(baseURL: String, apiKey: String?) async throws -> [String]
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

    /// Streams the response line by line; `parse` turns a line into reply text.
    static func stream(_ request: URLRequest, kind: ProviderKind,
                       parse: @escaping @Sendable (String) throws -> String?) -> AsyncThrowingStream<String, Error> {
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
                        if let text = try parse(line), !text.isEmpty {
                            continuation.yield(text)
                        }
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
}

// MARK: - Ollama

private struct OllamaBackend: ChatBackend {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        do {
            var messages: [[String: Any]] = []
            if !request.system.isEmpty {
                messages.append(["role": "system", "content": request.system])
            }
            for turn in request.turns {
                var message: [String: Any] = ["role": turn.role.rawValue, "content": turn.text]
                if let image = turn.imageJPEG {
                    message["images"] = [image.base64EncodedString()]
                }
                messages.append(message)
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/api/chat"), method: "POST",
                                              body: ["model": request.model, "stream": true, "messages": messages])
            return HTTP.stream(urlRequest, kind: .ollama) { line in
                guard let object = HTTP.object(line) else { return nil }
                if let error = object["error"] as? String { throw AIError(error) }
                return (object["message"] as? [String: Any])?["content"] as? String
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let object = try await HTTP.json(try HTTP.request(try HTTP.url(baseURL, "/api/tags")), kind: .ollama)
        let models = object["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }
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

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        do {
            var messages: [[String: Any]] = []
            if !request.system.isEmpty {
                messages.append(["role": "system", "content": request.system])
            }
            for turn in request.turns {
                if let image = turn.imageJPEG {
                    messages.append(["role": turn.role.rawValue, "content": [
                        ["type": "text", "text": turn.text],
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
                    ]])
                } else {
                    messages.append(["role": turn.role.rawValue, "content": turn.text])
                }
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/chat/completions"), method: "POST",
                                              headers: headers(request.apiKey),
                                              body: ["model": request.model, "stream": true, "messages": messages])
            return HTTP.stream(urlRequest, kind: kind) { line in
                guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return nil }
                if let error = object["error"] as? [String: Any] {
                    throw AIError(error["message"] as? String ?? "The server reported an error.")
                }
                let choice = (object["choices"] as? [[String: Any]])?.first
                return (choice?["delta"] as? [String: Any])?["content"] as? String
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
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

// MARK: - Anthropic

private struct AnthropicBackend: ChatBackend {
    private func headers(_ key: String?) -> [String: String] {
        ["x-api-key": key ?? "", "anthropic-version": "2023-06-01"]
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        do {
            guard let key = request.apiKey, !key.isEmpty else { throw AIError("Add your Anthropic API key in Settings › AI.") }
            let messages: [[String: Any]] = request.turns.map { turn in
                var content: [[String: Any]] = []
                if let image = turn.imageJPEG {
                    content.append(["type": "image", "source": [
                        "type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString(),
                    ]])
                }
                content.append(["type": "text", "text": turn.text])
                return ["role": turn.role.rawValue, "content": content]
            }
            var body: [String: Any] = ["model": request.model, "max_tokens": request.maxTokens,
                                       "stream": true, "messages": messages]
            if !request.system.isEmpty {
                body["system"] = request.system
            }
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, "/v1/messages"), method: "POST",
                                              headers: headers(key), body: body)
            return HTTP.stream(urlRequest, kind: .anthropic) { line in
                guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return nil }
                switch object["type"] as? String {
                case "content_block_delta":
                    let delta = object["delta"] as? [String: Any]
                    return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
                case "error":
                    let error = object["error"] as? [String: Any]
                    throw AIError(error?["message"] as? String ?? "Claude reported an error.")
                default:
                    return nil
                }
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func models(baseURL: String, apiKey: String?) async throws -> [String] {
        let request = try HTTP.request(try HTTP.url(baseURL, "/v1/models?limit=100"), headers: headers(apiKey))
        let object = try await HTTP.json(request, kind: .anthropic)
        return (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - Gemini

private struct GeminiBackend: ChatBackend {
    private func headers(_ key: String?) -> [String: String] {
        ["x-goog-api-key": key ?? ""]
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        do {
            guard let key = request.apiKey, !key.isEmpty else { throw AIError("Add your Gemini API key in Settings › AI.") }
            let contents: [[String: Any]] = request.turns.map { turn in
                var parts: [[String: Any]] = []
                if let image = turn.imageJPEG {
                    parts.append(["inline_data": ["mime_type": "image/jpeg", "data": image.base64EncodedString()]])
                }
                parts.append(["text": turn.text])
                return ["role": turn.role == .user ? "user" : "model", "parts": parts]
            }
            var body: [String: Any] = ["contents": contents]
            if !request.system.isEmpty {
                body["system_instruction"] = ["parts": [["text": request.system]]]
            }
            let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
            let path = "/v1beta/models/\(model):streamGenerateContent?alt=sse"
            let urlRequest = try HTTP.request(try HTTP.url(request.baseURL, path), method: "POST",
                                              headers: headers(key), body: body)
            return HTTP.stream(urlRequest, kind: .gemini) { line in
                guard let payload = HTTP.sseData(line), let object = HTTP.object(payload) else { return nil }
                if let error = object["error"] as? [String: Any] {
                    throw AIError(error["message"] as? String ?? "Gemini reported an error.")
                }
                let candidate = (object["candidates"] as? [[String: Any]])?.first
                let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
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
