import Foundation
import Observation

struct ClaudeDayStats: Equatable, Sendable {
    var day: Date
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var replies = 0
    var toolCalls = 0
    var sessions: Set<String> = []
    var repliesByModel: [String: Int] = [:]

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

struct ClaudeUsageSummary: Equatable, Sendable {
    /// The last seven days, oldest first, including empty days.
    var week: [ClaudeDayStats]
    var today: ClaudeDayStats { week.last ?? ClaudeDayStats(day: Calendar.current.startOfDay(for: .now)) }
    /// Consecutive days with activity, ending today (or yesterday if today is quiet so far).
    var streak: Int
    var lastActivity: Date?
    var foundLogs: Bool
}

/// One assistant reply in a Claude Code session log.
private struct ReplyUsage: Sendable {
    var day: Date
    var session: String
    var model: String?
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var tools: Int
    var time: Date
}

/// Reads Claude Code's local session logs (~/.claude/projects/**/*.jsonl).
/// Files are re-read only when their size or date changes. Replies are
/// counted once even when a log repeats them (streamed blocks, resumed sessions).
actor ClaudeLogReader {
    private struct FileResult {
        let size: Int
        let modified: Date
        let replies: [String: ReplyUsage]
    }

    private var cache: [String: FileResult] = [:]
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    private let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func summary() -> ClaudeUsageSummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -60, to: today) ?? today
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

        var replies: [String: ReplyUsage] = [:]
        var livePaths = Set<String>()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff else { continue }
            let size = values.fileSize ?? 0
            livePaths.insert(url.path)
            let result: FileResult
            if let cached = cache[url.path], cached.size == size, cached.modified == modified {
                result = cached
            } else {
                result = FileResult(size: size, modified: modified, replies: parse(url, cutoff: cutoff))
                cache[url.path] = result
            }
            replies.merge(result.replies) { first, _ in first }
        }
        cache = cache.filter { livePaths.contains($0.key) }

        var byDay: [Date: ClaudeDayStats] = [:]
        var lastActivity: Date?
        for reply in replies.values {
            var stats = byDay[reply.day] ?? ClaudeDayStats(day: reply.day)
            stats.inputTokens += reply.input
            stats.outputTokens += reply.output
            stats.cacheReadTokens += reply.cacheRead
            stats.cacheWriteTokens += reply.cacheWrite
            stats.replies += 1
            stats.toolCalls += reply.tools
            stats.sessions.insert(reply.session)
            if let model = reply.model {
                stats.repliesByModel[model, default: 0] += 1
            }
            byDay[reply.day] = stats
            lastActivity = max(lastActivity ?? reply.time, reply.time)
        }

        let week = (0..<7).reversed().compactMap { offset -> ClaudeDayStats? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return byDay[day] ?? ClaudeDayStats(day: day)
        }

        var streak = 0
        var cursor = (byDay[today]?.replies ?? 0) > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while (byDay[cursor]?.replies ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return ClaudeUsageSummary(week: week, streak: streak, lastActivity: lastActivity, foundLogs: !livePaths.isEmpty)
    }

    private func parse(_ url: URL, cutoff: Date) -> [String: ReplyUsage] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        let assistantMarker = Data("\"assistant\"".utf8)
        let usageMarker = Data("\"usage\"".utf8)
        let calendar = Calendar.current
        var replies: [String: ReplyUsage] = [:]

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Cheap byte checks first; most lines aren't assistant replies.
            guard line.range(of: assistantMarker) != nil, line.range(of: usageMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let time = fractionalFormatter.date(from: stamp) ?? ISODate.parse(stamp),
                  time >= cutoff else { continue }

            let key = (message["id"] as? String ?? UUID().uuidString) + "|" + (object["requestId"] as? String ?? "")
            let tools = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "tool_use" }.count
            func int(_ name: String) -> Int { (usage[name] as? NSNumber)?.intValue ?? 0 }

            let reply = ReplyUsage(day: calendar.startOfDay(for: time),
                                   session: object["sessionId"] as? String ?? url.lastPathComponent,
                                   model: message["model"] as? String,
                                   input: int("input_tokens"), output: int("output_tokens"),
                                   cacheRead: int("cache_read_input_tokens"),
                                   cacheWrite: int("cache_creation_input_tokens"),
                                   tools: tools, time: time)
            if var existing = replies[key] {
                // A reply streamed as several lines: same usage, one tool call per line.
                existing.input = max(existing.input, reply.input)
                existing.output = max(existing.output, reply.output)
                existing.cacheRead = max(existing.cacheRead, reply.cacheRead)
                existing.cacheWrite = max(existing.cacheWrite, reply.cacheWrite)
                existing.tools += reply.tools
                replies[key] = existing
            } else {
                replies[key] = reply
            }
        }
        return replies
    }
}

/// Keeps the usage summary fresh while the Claude module is on screen.
@MainActor
@Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    private(set) var summary: ClaudeUsageSummary?
    private(set) var isLoading = false
    @ObservationIgnored private let reader = ClaudeLogReader()
    @ObservationIgnored private lazy var gate = VisibilityGate(interval: .seconds(20)) { [weak self] in
        Task { await self?.reload() }
    }

    func whileVisible() async {
        await gate.whileVisible()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        let fresh = await reader.summary()
        isLoading = false
        summary = fresh
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = summary
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let week = (0..<7).reversed().map { offset -> ClaudeDayStats in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let scale = [0.4, 0.9, 0.0, 1.3, 0.7, 1.1, 0.8][6 - offset]
            return ClaudeDayStats(day: day, inputTokens: Int(40_000 * scale), outputTokens: Int(180_000 * scale),
                                  cacheReadTokens: Int(2_600_000 * scale), cacheWriteTokens: Int(310_000 * scale),
                                  replies: Int(240 * scale), toolCalls: Int(150 * scale),
                                  sessions: Set((0..<Int(4 * scale)).map(String.init)),
                                  repliesByModel: ["claude-opus-5": Int(200 * scale)])
        }
        summary = ClaudeUsageSummary(week: week, streak: 4, lastActivity: Date().addingTimeInterval(-300), foundLogs: true)
        body()
        summary = saved
    }
    #endif
}
