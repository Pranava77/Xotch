import Foundation

/// Speech to text with Cactus's Whistle model, run by `needle-helper` in its
/// own process (see NeedleHelper/needle-helper.c for why). The helper starts
/// on the first request and quits after two idle minutes, so the model's
/// memory is only taken while you're dictating.
///
/// The engine is built for macOS 26 on Apple silicon; elsewhere dictation
/// says it isn't available.
final class WhistleEngine: @unchecked Sendable {
    static let shared = WhistleEngine()

    struct EngineError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Words a stream committed, and its unconfirmed tail.
    struct StreamUpdate: Sendable {
        let committed: String
        let pending: String
    }

    static var isSupported: Bool {
        #if arch(arm64)
        if #available(macOS 26, *) { return helperURL != nil }
        #endif
        return false
    }

    static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/needle-helper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Every request runs here, one at a time: the engine isn't thread-safe,
    /// and the pipe carries one request and one answer at a time.
    private let queue = DispatchQueue(label: "com.pranava.xotch.whistle", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var options: String?
    private var idleStop: DispatchWorkItem?
    private static let idleLimit: TimeInterval = 120

    var isRunning: Bool { queue.sync { process?.isRunning == true } }

    // MARK: - Requests

    /// Words and phrases to listen for (names, jargon), and the language, or nil to detect it.
    func setOptions(language: String?, keywords: [String]) async throws {
        let value = (language ?? "") + "\u{0}" + keywords.joined(separator: "\n")
        try await run { [self] in
            guard options != value else { return }
            _ = try request(UInt8(ascii: "O"), Data(value.utf8))
            options = value
        }
    }

    /// Adds about a second of 16 kHz mono audio to the live stream.
    func stream(_ samples: [Float]) async throws -> StreamUpdate {
        try await run { [self] in
            let reply = try request(UInt8(ascii: "A"), Self.data(samples))
            return StreamUpdate(committed: reply["text"] as? String ?? "", pending: reply["pending"] as? String ?? "")
        }
    }

    /// Ends the live stream, returning the words still uncommitted.
    func stopStream() async throws -> String {
        try await run { [self] in
            try request(UInt8(ascii: "S"), Data())["text"] as? String ?? ""
        }
    }

    /// Transcribes a whole clip of at most 30 s in one pass.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await run { [self] in
            try request(UInt8(ascii: "T"), Self.data(samples))["text"] as? String ?? ""
        }
    }

    /// Quits the helper now, freeing the model's memory.
    func shutDown() {
        queue.async { [self] in stopHelper() }
    }

    // MARK: - The helper

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// On the queue: one frame out, one line of JSON back.
    private func request(_ op: UInt8, _ payload: Data) throws -> [String: Any] {
        try startIfNeeded()
        guard let input, let output else { throw EngineError("Dictation's engine isn't running.") }
        var frame = Data([op])
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        do {
            try input.write(contentsOf: frame)
        } catch {
            stopHelper()
            throw EngineError("Dictation's engine stopped. Try again.")
        }
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                scheduleIdleStop()
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw EngineError("Dictation's engine sent something unreadable.")
                }
                if let error = object["error"] as? String { throw EngineError(error) }
                return object
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                stopHelper()
                throw EngineError("Dictation's engine stopped. Try again.")
            }
            pending.append(chunk)
        }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stopHelper()
        guard Self.isSupported, let helper = Self.helperURL else {
            throw EngineError("Dictation needs a Mac with Apple silicon and macOS 26 or later.")
        }
        guard FileManager.default.fileExists(atPath: WhistleModel.fileURL.path) else {
            throw EngineError("Download the Whistle model in Settings › Dictation first.")
        }
        let process = Process()
        process.executableURL = helper
        let toHelper = Pipe()
        let fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        pending.removeAll()
        options = nil
        _ = try request(UInt8(ascii: "L"), Data(WhistleModel.fileURL.path.utf8))
    }

    private func stopHelper() {
        idleStop?.cancel()
        idleStop = nil
        // Closing its input ends the helper.
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        pending.removeAll()
        options = nil
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stopHelper() }
        idleStop = stop
        queue.asyncAfter(deadline: .now() + Self.idleLimit, execute: stop)
    }

    private static func data(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
