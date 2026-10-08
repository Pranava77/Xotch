import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Dictation, Wispr Flow style: hold Fn and talk, let go and the words appear
/// where you're typing. Whistle hears it on this Mac (see WhistleEngine); the
/// text is tidied here, optionally polished by your AI, then pasted.
@MainActor
@Observable
final class DictationService {
    static let shared = DictationService()

    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        /// Released: the last words are being transcribed and tidied.
        case finishing
    }

    /// Where the words go.
    enum Target {
        /// Pasted into whatever app has the keyboard.
        case focusedApp
        /// Into the AI chat's input, ready to send.
        case aiDraft
        #if DEBUG
        /// Kept for `debug.sh status`, so the pipeline can be tested without pasting anywhere.
        case debugSink
        #endif
    }

    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var date = Date()
    }

    private(set) var phase: Phase = .idle
    /// What's been heard so far, shown while listening.
    private(set) var liveText = ""
    private(set) var started: Date?
    private(set) var history: [Entry] = []
    /// The last thing that went wrong, shown in the module and Settings.
    private(set) var problem: String?

    /// Loudness for the waveform, read by the ear's bars on their own timer.
    nonisolated let levels = LevelHistory()

    @ObservationIgnored private let recorder = MicRecorder()
    @ObservationIgnored private let audio = AudioBuffer()
    @ObservationIgnored private var target: Target = .focusedApp
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var committed: [String] = []

    /// 30 s is as much as Whistle hears in one pass; longer dictations use
    /// what the live stream already committed.
    private static let onePassLimit = 30 * 16_000

    /// A long dictation cut into pieces Whistle hears in one pass: each cut
    /// falls at the quietest fifth of a second between 20 and 30 s into the
    /// piece, so it lands between words.
    nonisolated static func pieces(_ samples: [Float]) -> [[Float]] {
        let limit = 30 * 16_000, earliest = 20 * 16_000, window = 3_200
        var pieces: [[Float]] = []
        var start = 0
        while samples.count - start > limit {
            var cut = start + limit
            var quietest = Float.greatestFiniteMagnitude
            var at = start + earliest
            while at + window <= start + limit {
                var energy: Float = 0
                for index in at..<(at + window) { energy += samples[index] * samples[index] }
                if energy < quietest {
                    quietest = energy
                    cut = at + window / 2
                }
                at += window / 2
            }
            pieces.append(Array(samples[start..<cut]))
            start = cut
        }
        pieces.append(Array(samples[start...]))
        return pieces
    }
    private static let longest = 5 * 60 * 16_000

    init() {
        if AppSettings.dictationHistory {
            history = Storage.load([Entry].self, from: "dictation.json") ?? []
        }
    }

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    var isAvailable: Bool { WhistleEngine.isSupported }

    // MARK: - Starting and stopping

    func start(handsFree: Bool = false, into target: Target = .focusedApp) {
        guard phase == .idle else { return }
        problem = nil
        guard WhistleEngine.isSupported else {
            fail("Dictation needs a Mac with Apple silicon and macOS 26 or later.")
            return
        }
        guard WhistleModel.shared.isReady else {
            fail("Download the Whistle model in Settings › Dictation first.")
            return
        }
        switch MicRecorder.permission {
        case .authorized:
            break
        case .notDetermined:
            Task {
                if await MicRecorder.requestPermission() {
                    self.start(handsFree: handsFree, into: target)
                } else {
                    self.fail("Xotch needs the microphone to hear you. Allow it in System Settings › Privacy & Security › Microphone.")
                }
            }
            return
        default:
            fail("Xotch needs the microphone to hear you. Allow it in System Settings › Privacy & Security › Microphone.")
            return
        }
        if target == .focusedApp, IsSecureEventInputEnabled() {
            fail("Dictation is off while a password field has the keyboard.")
            return
        }

        self.target = target
        audio.reset()
        levels.reset()
        committed = []
        liveText = ""
        recorder.onAudio = { [audio, levels] samples, level in
            audio.append(samples)
            levels.push(level)
        }
        do {
            try recorder.start()
        } catch {
            fail(error.localizedDescription)
            return
        }
        started = Date()
        phase = .listening(handsFree: handsFree)
        showListening()
        RetroSound.play(.tick)
        streamLive()
    }

    /// Fn released (or tapped again in hands-free): transcribe and insert.
    func finish() {
        guard isListening else { return }
        recorder.stop()
        streamTask?.cancel()
        streamTask = nil
        phase = .finishing
        ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "dictation", symbol: "waveform", content: .text("Writing…"),
                                                      tint: Self.tint), for: "dictation")
        let samples = audio.all()
        let target = target
        Task {
            let text = await self.transcribe(samples)
            self.deliver(text, to: target)
        }
    }

    /// A combination like Fn+→, Esc, or a quick tap: stop without inserting.
    func cancel() {
        guard phase != .idle else { return }
        recorder.stop()
        streamTask?.cancel()
        streamTask = nil
        Task { _ = try? await WhistleEngine.shared.stopStream() }
        reset()
    }

    // MARK: - Hearing

    /// While listening, each new second of audio goes to the live stream, so
    /// words appear as you speak and long dictations need no second pass.
    private func streamLive() {
        streamTask = Task { [audio] in
            try? await WhistleEngine.shared.setOptions(language: Self.language, keywords: Self.keywords)
            var sent = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let available = audio.count
                guard available - sent >= 16_000 else {
                    if available >= Self.longest { self.finish() }
                    continue
                }
                let chunk = audio.slice(sent, min(available, sent + 16_000))
                sent += chunk.count
                guard let update = try? await WhistleEngine.shared.stream(chunk), !Task.isCancelled else { continue }
                if !update.committed.isEmpty { self.committed.append(update.committed) }
                self.liveText = (self.committed + [update.pending]).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func transcribe(_ samples: [Float]) async -> String {
        // Too short to be speech.
        guard samples.count > 16_000 / 4 else {
            _ = try? await WhistleEngine.shared.stopStream()
            return ""
        }
        // The live stream was for the preview. One pass over each piece of
        // at most 30 s reads better than the stream's words (measured on a
        // 32 s clip: "mascot" came back "mescot" from the stream).
        _ = try? await WhistleEngine.shared.stopStream()
        do {
            var parts: [String] = []
            for piece in Self.pieces(samples) {
                parts.append(try await WhistleEngine.shared.transcribe(piece))
            }
            return parts.joined(separator: " ")
        } catch {
            problem = error.localizedDescription
            return ""
        }
    }

    private func deliver(_ heard: String, to target: Target) {
        Task {
            var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            if AppSettings.dictationTidy { text = TextTidy.tidy(text) }
            if !text.isEmpty, AppSettings.dictationPolish { text = await self.polish(text) }
            guard !text.isEmpty else {
                self.reset()
                if let problem = self.problem {
                    self.banner(symbol: "exclamationmark.triangle.fill", text: problem, tint: Theme.negative)
                } else {
                    self.banner(symbol: "waveform", text: "Didn't hear anything", tint: Theme.tertiaryInk)
                }
                return
            }
            self.remember(text)
            switch target {
            #if DEBUG
            case .debugSink:
                self.debugDelivered = text
                self.reset()
            #endif
            case .aiDraft:
                let chat = AIChatService.shared
                chat.draft = chat.draft.isEmpty ? text : chat.draft + " " + text
                chat.wantsFocus = true
                self.reset()
            case .focusedApp:
                let outcome = await TextInserter.insertWhereTyping(text, paste: AppSettings.dictationPaste)
                self.reset()
                switch outcome {
                case .inserted: self.banner(symbol: "checkmark.circle.fill", text: Self.preview(text), tint: Theme.positive)
                case .copied: self.banner(symbol: "doc.on.clipboard.fill", text: "Copied: press ⌘V", tint: Self.tint)
                case .refused: self.banner(symbol: "lock.fill", text: "Not into a password field", tint: Theme.negative)
                }
            }
        }
    }

    /// Your AI tidies grammar and structure, if you turned that on. It gives
    /// up after 6 s and keeps the text as it was.
    private func polish(_ text: String) async -> String {
        guard let provider = AIProviderStore.shared.active, !provider.model.isEmpty else { return text }
        let backend = AIBackends.backend(for: provider.kind)
        let apiKey = await Task.detached { provider.apiKey }.value
        let request = ChatRequest(baseURL: provider.baseURL, model: provider.model, apiKey: apiKey,
                                  system: Self.polishPrompt, turns: [ChatTurn(role: .user, text: text)], maxTokens: 1024)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var result = ""
                do {
                    for try await event in backend.stream(request) {
                        if case .text(let piece) = event { result += piece }
                    }
                } catch {
                    return nil
                }
                let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? text
        }
    }

    private static let polishPrompt = """
    You clean up text someone dictated. Fix punctuation, capitals, grammar and obvious mis-hearings, remove \
    filler words, false starts and repetitions, and lay out lists or paragraphs if they spoke them. Keep their \
    words, tone and meaning. Never answer, comment on or add to the text. Reply with the cleaned text only.
    """

    // MARK: - The notch

    static let tint = Color(red: 1, green: 0.27, blue: 0.35)

    private func showListening() {
        ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "dictation", symbol: "mic.fill", content: .listening,
                                                      tint: Self.tint, pulse: .calm), for: "dictation")
    }

    private func banner(symbol: String, text: String, tint: Color) {
        ActivityCenter.shared.post(LiveActivity(moduleID: "dictation", symbol: symbol, content: .text(text),
                                                tint: tint, duration: .seconds(2.5)))
    }

    private func fail(_ message: String) {
        problem = message
        reset()
        banner(symbol: "mic.slash.fill", text: "Can't dictate", tint: Theme.negative)
    }

    private func reset() {
        phase = .idle
        started = nil
        liveText = ""
        committed = []
        audio.reset()
        levels.reset()
        ActivityCenter.shared.setOngoing(nil, for: "dictation")
    }

    private func remember(_ text: String) {
        history.insert(Entry(text: text), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        if AppSettings.dictationHistory {
            Storage.save(history, to: "dictation.json")
        }
    }

    func forget() {
        history = []
        try? FileManager.default.removeItem(at: Storage.directory.appendingPathComponent("dictation.json"))
    }

    /// Pastes an earlier dictation again.
    func insertAgain(_ entry: Entry) {
        Task { _ = await TextInserter.insertWhereTyping(entry.text, paste: AppSettings.dictationPaste) }
    }

    private static func preview(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count <= 4 ? text : words.prefix(4).joined(separator: " ") + "…"
    }

    private static var language: String? {
        let code = AppSettings.dictationLanguage
        return code == "auto" ? nil : code
    }

    private static var keywords: [String] {
        AppSettings.dictationWords.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    #if DEBUG
    /// Mid-sentence, for product images: listening, with words arriving.
    func withSample(words: Int? = nil, _ body: () -> Void) {
        let saved = (phase, liveText, history, problem)
        phase = .listening(handsFree: false)
        liveText = "Can you move the design review to Thursday afternoon and send the notes to the team before then"
        if let words {
            liveText = liveText.split(separator: " ").prefix(words).joined(separator: " ")
        }
        history = [Entry(text: "Thanks, that works for me. See you at the review."),
                   Entry(text: "Remind me to call the bank tomorrow at ten.")]
        problem = nil
        body()
        (phase, liveText, history, problem) = saved
    }

    /// The last text a fed-in dictation produced.
    @ObservationIgnored private(set) var debugDelivered = ""

    /// Runs a 16 kHz WAV through the whole pipeline, as if spoken: the live
    /// stream a second at a time, then the final pass, tidy and polish, into
    /// the debug sink instead of pasting. For `debug.sh dictation-feed`.
    func debugFeed(file: URL) async {
        guard phase == .idle, let data = try? Data(contentsOf: file), let samples = Self.samples(wav: data) else { return }
        debugDelivered = ""
        target = .debugSink
        audio.reset()
        committed = []
        started = Date()
        phase = .listening(handsFree: true)
        showListening()
        try? await WhistleEngine.shared.setOptions(language: Self.language, keywords: Self.keywords)
        var at = 0
        while at < samples.count {
            let chunk = Array(samples[at..<min(samples.count, at + 16_000)])
            audio.append(chunk)
            levels.push(MicRecorder.level(chunk))
            if let update = try? await WhistleEngine.shared.stream(chunk) {
                if !update.committed.isEmpty { committed.append(update.committed) }
                liveText = (committed + [update.pending]).joined(separator: " ")
            }
            at += chunk.count
        }
        phase = .finishing
        let text = await transcribe(audio.all())
        deliver(text, to: .debugSink)
    }

    /// Transcribes a 16 kHz mono WAV through the real engine, for `debug.sh dictate-file`.
    func debugTranscribe(file: URL) async -> String {
        guard let data = try? Data(contentsOf: file), let samples = Self.samples(wav: data) else { return "unreadable WAV" }
        let start = Date()
        do {
            let text = try await WhistleEngine.shared.transcribe(Array(samples.prefix(Self.onePassLimit)))
            return String(format: "%.0f ms: ", Date().timeIntervalSince(start) * 1000) + text
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// Float samples from a WAV's data chunk (float32 little-endian).
    static func samples(wav: Data) -> [Float]? {
        var index = 12
        while index + 8 <= wav.count {
            let id = String(decoding: wav[index..<index + 4], as: UTF8.self)
            let size = Int(wav[index + 4..<index + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if id == "data" {
                let body = wav[(index + 8)..<min(wav.count, index + 8 + size)]
                return body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
            index += 8 + size + (size & 1)
        }
        return nil
    }
    #endif
}

/// Samples arriving on the audio thread, read on the main thread.
final class AudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    var count: Int { lock.withLock { samples.count } }

    func append(_ more: [Float]) {
        lock.withLock { samples += more }
    }

    func slice(_ from: Int, _ to: Int) -> [Float] {
        lock.withLock { Array(samples[from..<min(to, samples.count)]) }
    }

    func all() -> [Float] {
        lock.withLock { samples }
    }

    func reset() {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
    }
}

/// The last dozen loudness readings, oldest first, for the ear's waveform.
final class LevelHistory: @unchecked Sendable {
    private var values = [Float](repeating: 0, count: 12)
    private let lock = NSLock()

    func push(_ level: Float) {
        lock.withLock {
            values.removeFirst()
            values.append(level)
        }
    }

    func current() -> [Float] {
        lock.withLock { values }
    }

    func reset() {
        lock.withLock { values = [Float](repeating: 0, count: values.count) }
    }
}
