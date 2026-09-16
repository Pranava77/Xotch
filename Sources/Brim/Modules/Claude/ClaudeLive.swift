import Darwin
import SwiftUI
import Observation

struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable {
        case working(tool: String?)
        case waiting(message: String)
        case idle
    }

    let id: String
    var project: String
    var state: State
    var updated: Date

    var stateLabel: String {
        switch state {
        case .working(let tool): ClaudeLiveService.describe(tool: tool)
        case .waiting: "Needs you"
        case .idle: "Done"
        }
    }
}

/// Live Claude Code status. A hook in ~/.claude/settings.json pipes each
/// event to a Unix socket that only this user can open; Brim turns them into
/// "working / needs you / done" beside the notch.
@MainActor
@Observable
final class ClaudeLiveService {
    static let shared = ClaudeLiveService()
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    static var socketPath: String {
        Storage.directory.appendingPathComponent("claude.sock").path
    }

    private(set) var sessions: [ClaudeSession] = []
    private(set) var hookInstalled = ClaudeHookInstaller.isInstalled()
    private(set) var hookMessage: String?
    private(set) var isListening = false

    @ObservationIgnored private var server: UnixSocketServer?
    @ObservationIgnored private var pruneTimer: Timer?

    func start() {
        guard server == nil else { return }
        let server = UnixSocketServer(path: Self.socketPath) { data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ClaudeLiveService.shared.handle(data) }
            }
        }
        do {
            try server.start()
            self.server = server
            isListening = true
        } catch {
            isListening = false
        }
        let timer = Timer(timeInterval: 60, repeats: true) { @Sendable _ in
            MainActor.assumeIsolated { ClaudeLiveService.shared.prune() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        pruneTimer?.invalidate()
        pruneTimer = nil
        sessions = []
        updateActivity()
    }

    // MARK: - Hook

    func installHook() {
        do {
            try ClaudeHookInstaller.install()
            hookInstalled = true
            hookMessage = "Added. New Claude Code sessions will show here. A backup of your settings is next to settings.json."
        } catch {
            hookMessage = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    func removeHook() {
        do {
            try ClaudeHookInstaller.uninstall()
            hookInstalled = false
            hookMessage = "Removed Brim's hook from ~/.claude/settings.json."
            sessions = []
            updateActivity()
        } catch {
            hookMessage = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Events

    func handle(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = event["hook_event_name"] as? String,
              let sessionID = event["session_id"] as? String else { return }
        let project = (event["cwd"] as? String).map { ($0 as NSString).lastPathComponent } ?? "Claude Code"

        if name == "SessionEnd" {
            withAnimation(Motion.switchModule) { sessions.removeAll { $0.id == sessionID } }
            updateActivity()
            return
        }

        var session = sessions.first { $0.id == sessionID }
            ?? ClaudeSession(id: sessionID, project: project, state: .idle, updated: Date())
        let previous = session.state
        session.project = project
        session.updated = Date()

        switch name {
        case "SessionStart":
            session.state = .idle
        case "UserPromptSubmit", "PostToolUse":
            session.state = .working(tool: nil)
        case "PreToolUse":
            session.state = .working(tool: event["tool_name"] as? String)
        case "Notification":
            session.state = .waiting(message: event["message"] as? String ?? "Claude needs your attention")
            ActivityCenter.shared.post(LiveActivity(moduleID: "claude", symbol: "hand.raised.fill",
                                                    content: .text("Needs you"), tint: Theme.accent,
                                                    earWidth: 110, duration: .seconds(5)))
        case "Stop":
            session.state = .idle
            if case .working = previous {
                ActivityCenter.shared.post(LiveActivity(moduleID: "claude", symbol: "checkmark.circle.fill",
                                                        content: .text("Done"), tint: Theme.positive,
                                                        earWidth: 110, duration: .seconds(4)))
            }
        default:
            return
        }

        withAnimation(Motion.switchModule) {
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index] = session
            } else {
                sessions.insert(session, at: 0)
            }
            sessions.sort { $0.updated > $1.updated }
        }
        updateActivity()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let kept = sessions.filter { $0.updated > cutoff }
        guard kept.count != sessions.count else { return }
        withAnimation(Motion.switchModule) { sessions = kept }
        updateActivity()
    }

    private func updateActivity() {
        let center = ActivityCenter.shared
        if sessions.contains(where: { if case .waiting = $0.state { true } else { false } }) {
            center.setOngoing(LiveActivity(moduleID: "claude", symbol: "hand.raised.fill",
                                           content: .text("Needs you"), tint: Theme.accent, earWidth: 110), for: "claude")
        } else if let working = sessions.first(where: { if case .working = $0.state { true } else { false } }) {
            center.setOngoing(LiveActivity(moduleID: "claude", symbol: "sparkle",
                                           content: .text(working.stateLabel), tint: Self.tint, earWidth: 110), for: "claude")
        } else {
            center.setOngoing(nil, for: "claude")
        }
    }

    nonisolated static func describe(tool: String?) -> String {
        guard let tool else { return "Thinking" }
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "Running"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing"
        case "Read", "Glob", "Grep", "LS": return "Reading"
        case "WebFetch", "WebSearch": return "Browsing"
        case "Task", "Agent": return "Delegating"
        case "TodoWrite": return "Planning"
        default: return tool.hasPrefix("mcp__") ? "Using tools" : "Working"
        }
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (sessions, hookInstalled)
        let now = Date()
        sessions = [
            ClaudeSession(id: "a", project: "Brim", state: .working(tool: "Edit"), updated: now.addingTimeInterval(-4)),
            ClaudeSession(id: "b", project: "landing-page", state: .waiting(message: "Claude needs your permission to use Bash"), updated: now.addingTimeInterval(-50)),
            ClaudeSession(id: "c", project: "api-server", state: .idle, updated: now.addingTimeInterval(-900)),
        ]
        hookInstalled = true
        body()
        (sessions, hookInstalled) = saved
    }
    #endif
}

// MARK: - Hook installer

/// Adds or removes Brim's hook entries in Claude Code's user settings,
/// leaving everything else in the file as it was.
enum ClaudeHookInstaller {
    enum InstallError: LocalizedError {
        case notAnObject
        var errorDescription: String? { "settings.json isn't a JSON object." }
    }

    static let marker = "brim-claude-hook"
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Sends the event JSON from stdin to Brim; does nothing if Brim isn't running.
    static let command = #"/usr/bin/nc -U -w 2 "$HOME/Library/Application Support/Brim/claude.sock" >/dev/null 2>&1 || true # "# + marker

    static func isInstalled(at url: URL = settingsURL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    static func install(at url: URL = settingsURL) throws {
        var root = try load(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isBrims($0) }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if toolEvents.contains(event) {
                group["matcher"] = "*"
            }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try backUp(url)
        try save(root, to: url)
    }

    static func uninstall(at url: URL = settingsURL) throws {
        var root = try load(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isBrims($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root, to: url)
    }

    private static func isBrims(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.notAnObject
        }
        return object
    }

    private static func backUp(_ url: URL) throws {
        let backup = url.appendingPathExtension("brim-backup")
        let files = FileManager.default
        guard files.fileExists(atPath: url.path), !files.fileExists(atPath: backup.path) else { return }
        try files.copyItem(at: url, to: backup)
    }

    private static func save(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Socket

/// A tiny Unix-domain socket server. Each connection carries one JSON object;
/// the connection is closed as soon as a complete object has arrived.
final class UnixSocketServer: @unchecked Sendable {
    enum ServerError: Error {
        case pathTooLong, socket(Int32), bind(Int32), listen(Int32)
    }

    private final class Buffer: @unchecked Sendable {
        var data = Data()
        var delivered = false
    }

    private let path: String
    private let onMessage: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.pranava.brim.claude-socket")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(path: String, onMessage: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw ServerError.bind(errno)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.listen(errno)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }

    private func acceptClients() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            read(from: client)
        }
    }

    private func read(from client: Int32) {
        let buffer = Buffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        let deliver: @Sendable () -> Void = { [onMessage] in
            guard !buffer.delivered, !buffer.data.isEmpty else { return }
            buffer.delivered = true
            onMessage(buffer.data)
        }
        source.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(client, &chunk, chunk.count)
            if count > 0 {
                buffer.data.append(chunk, count: count)
                // Close as soon as the JSON object is complete, so the hook returns at once.
                if buffer.data.count > 512_000 || (try? JSONSerialization.jsonObject(with: buffer.data)) != nil {
                    deliver()
                    source.cancel()
                }
            } else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                deliver()
                source.cancel()
            }
        }
        source.setCancelHandler { close(client) }
        source.resume()
    }
}
