import Foundation

/// LM Studio runs models on this Mac, but its server is a switch of its own:
/// opening the app doesn't start it unless "Start on launch" is on, so the
/// chat finds nothing on the port. Its `lms` tool can start it.
enum LMStudio {
    static let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms")

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: cli.path) }

    /// The port LM Studio's server listens on: its own setting, or 1234.
    static var port: Int {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/.internal/http-server-config.json")
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int else { return 1234 }
        return port
    }

    /// Whether this server address is LM Studio's: this Mac, LM Studio's port,
    /// with LM Studio installed.
    static func serves(_ address: String) -> Bool {
        guard isInstalled, let url = URL(string: address), let host = url.host else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host) && url.port == port
    }

    /// Embedding models can't chat, so they're never picked as one.
    static func canChat(_ model: String) -> Bool {
        !model.lowercased().contains("embed")
    }

    /// Runs `lms server start`, then waits until the server answers at `baseURL`.
    static func startServer(baseURL: String) async throws {
        let output: String = try await Task.detached {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["server", "start"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw AIError("LM Studio couldn't start its server: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text
        }.value
        _ = output
        // It can take a moment to open the port.
        let backend = AIBackends.backend(for: .openAICompatible)
        for _ in 0..<20 {
            if (try? await backend.models(baseURL: baseURL, apiKey: nil)) != nil { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw AIError("LM Studio started its server, but it isn't answering at \(baseURL) yet.")
    }
}

/// Something the person can do about a failed reply, offered as a button.
enum ChatFix: Codable, Equatable, Sendable {
    /// LM Studio is installed but its server is off.
    case startLMStudio
    /// The server doesn't have the chosen model; this one it does.
    case useModel(String)

    var title: String {
        switch self {
        case .startLMStudio: "Start LM Studio's Server"
        case .useModel(let model): "Use \(model)"
        }
    }
}
