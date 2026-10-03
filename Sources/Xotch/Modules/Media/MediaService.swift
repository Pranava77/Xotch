import AppKit
import SwiftUI
import Observation

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date?
    var rate: Double
    var isPlaying: Bool
    var bundleID: String?

    /// Playback position now, extrapolated from the last update.
    func position(at date: Date) -> Double {
        guard isPlaying, let timestamp else { return elapsed }
        let position = elapsed + date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1)
        return duration > 0 ? min(position, duration) : position
    }

    var appName: String? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Now-playing info for whatever app is playing, via MediaRemoteBridge
/// (see MediaRemoteBridge/MediaRemoteBridge.m).
@MainActor
@Observable
final class MediaService {
    static let shared = MediaService()

    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var tint: Color = Theme.accent
    private(set) var isAvailable = true

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var isStopped = true
    /// Pending "nothing is playing" and "no artwork" from the bridge (see `handle`).
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var artworkClearTask: Task<Void, Never>?

    /// MediaRemote reports no title for a moment between tracks, and no artwork
    /// for 0.13 s on every play or pause, then sends them again. Waiting this
    /// long before believing it stops the player blinking to "Nothing playing"
    /// and the cover flashing when you press Next.
    private static let nothingGrace: Duration = .seconds(1.5)

    func start() {
        isStopped = false
        guard process == nil else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-bridge", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteBridge.dylib"),
              FileManager.default.fileExists(atPath: library.path) else {
            isAvailable = false
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            // DispatchQueue keeps chunks in order; Tasks might not.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { @Sendable [weak self] exited in
            let id = ObjectIdentifier(exited)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bridgeExited(id) }
            }
        }

        do {
            try process.run()
        } catch {
            isAvailable = false
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        startedAt = Date()
        isAvailable = true
    }

    /// Ends the bridge; closing its input makes it exit.
    func stop() {
        isStopped = true
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
        clearTask?.cancel()
        clearTask = nil
        artworkClearTask?.cancel()
        artworkClearTask = nil
        nowPlaying = nil
        artwork = nil
        ActivityCenter.shared.setOngoing(nil, for: "media")
    }

    func retry() {
        restarts = 0
        isAvailable = true
        start()
    }

    // MARK: - Commands

    func togglePlayPause() {
        send("toggle")
        if var playing = nowPlaying {
            // Update right away; the bridge confirms a moment later.
            playing.elapsed = playing.position(at: .now)
            playing.timestamp = .now
            playing.isPlaying.toggle()
            withAnimation(Motion.press) { nowPlaying = playing }
            updateActivity()
        }
    }

    func next() { send("next") }
    func previous() { send("previous") }

    func seek(to seconds: Double) {
        send("seek \(seconds)")
        nowPlaying?.elapsed = seconds
        nowPlaying?.timestamp = .now
    }

    func openSourceApp() {
        guard let bundleID = nowPlaying?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        #if DEBUG
        debugNote("sent \(command)")
        #endif
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - Bridge output

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        #if DEBUG
        let debugArtwork = (object["artwork"] as? String).map { $0.isEmpty ? "empty" : "data" } ?? "absent"
        debugNote("line title=\((object["title"] as? String ?? "").isEmpty ? "EMPTY" : "set") playing=\(object["playing"] ?? "-") artwork=\(debugArtwork)")
        #endif
        if object["error"] != nil {
            isAvailable = false
            return
        }
        if let encoded = object["artwork"] as? String {
            let image = encoded.isEmpty ? nil : Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
            if image == nil, artwork != nil {
                clearArtworkSoon()
            } else {
                artworkClearTask?.cancel()
                artworkClearTask = nil
                setArtwork(image)
            }
        }

        let title = object["title"] as? String ?? ""
        guard !title.isEmpty else {
            if nowPlaying != nil {
                clearSoon()
            }
            return
        }
        clearTask?.cancel()
        clearTask = nil
        let timestamp = (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        nowPlaying = NowPlaying(
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: object["duration"] as? Double ?? 0,
            elapsed: object["elapsed"] as? Double ?? 0,
            timestamp: timestamp,
            rate: object["rate"] as? Double ?? 0,
            isPlaying: (object["playing"] as? Bool) ?? ((object["playing"] as? Int) ?? 0 != 0),
            bundleID: object["bundleID"] as? String
        )
        updateActivity()
    }

    private func setArtwork(_ image: NSImage?) {
        withAnimation(Motion.switchModule) {
            artwork = image
            tint = image?.vividColor ?? Theme.accent
        }
    }

    /// Clears the player unless a title comes back first. Further empty
    /// reports don't restart the wait.
    private func clearSoon() {
        guard clearTask == nil else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.nothingGrace)
            guard let self, !Task.isCancelled else { return }
            self.clearTask = nil
            #if DEBUG
            self.debugNote("cleared nowPlaying")
            #endif
            self.nowPlaying = nil
            self.updateActivity()
        }
    }

    /// Drops the cover unless new artwork arrives first.
    private func clearArtworkSoon() {
        guard artworkClearTask == nil else { return }
        artworkClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.nothingGrace)
            guard let self, !Task.isCancelled else { return }
            self.artworkClearTask = nil
            #if DEBUG
            self.debugNote("cleared artwork")
            #endif
            self.setArtwork(nil)
            self.updateActivity()
        }
    }

    private func bridgeExited(_ exited: ObjectIdentifier) {
        // Ignore a bridge that was already replaced or deliberately stopped.
        guard let process, ObjectIdentifier(process) == exited else { return }
        self.process = nil
        input = nil
        buffer.removeAll()
        guard !isStopped else { return }
        if Date().timeIntervalSince(startedAt) > 60 {
            restarts = 0
        }
        guard restarts < 3 else {
            isAvailable = false
            return
        }
        restarts += 1
        let delay = Duration.seconds(1 << restarts)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.isStopped else { return }
            self.start()
        }
    }

    private func updateActivity() {
        guard AppSettings.mediaActivity, let playing = nowPlaying, playing.isPlaying else {
            ActivityCenter.shared.setOngoing(nil, for: "media")
            return
        }
        ActivityCenter.shared.setOngoing(
            LiveActivity(moduleID: "media", symbol: "music.note", content: .playing, tint: tint, image: artwork),
            for: "media"
        )
    }

    func settingsChanged() {
        updateActivity()
    }

    #if DEBUG
    /// The last bridge lines, commands and clears, for
    /// `scripts/debug.sh status`.
    @ObservationIgnored private(set) var debugLog: [String] = []
    @ObservationIgnored private var debugLastNote = Date()

    /// Each entry starts with the time since the one before it.
    private func debugNote(_ text: String) {
        let gap = Date().timeIntervalSince(debugLastNote)
        debugLastNote = Date()
        debugLog.append(String(format: "+%.2fs ", gap) + text)
        if debugLog.count > 20 {
            debugLog.removeFirst(debugLog.count - 20)
        }
    }

    /// An abstract cover: a low sun over layered hills.
    private static let sampleArtwork = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
        let sky = NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.42, alpha: 1),
                                      NSColor(srgbRed: 0.47, green: 0.25, blue: 0.78, alpha: 1)])
        sky?.draw(in: rect, angle: -90)
        NSColor(srgbRed: 1, green: 0.84, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 95, y: 110, width: 110, height: 110)).fill()
        let hills: [(CGFloat, NSColor)] = [
            (150, NSColor(srgbRed: 0.36, green: 0.18, blue: 0.55, alpha: 1)),
            (105, NSColor(srgbRed: 0.24, green: 0.12, blue: 0.42, alpha: 1)),
            (60, NSColor(srgbRed: 0.12, green: 0.07, blue: 0.26, alpha: 1)),
        ]
        for (index, (height, color)) in hills.enumerated() {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: height))
            path.curve(to: NSPoint(x: 300, y: height - 20 + CGFloat(index) * 12),
                       controlPoint1: NSPoint(x: 90, y: height + 45),
                       controlPoint2: NSPoint(x: 200, y: height - 50))
            path.line(to: NSPoint(x: 300, y: 0))
            path.close()
            color.setFill()
            path.fill()
        }
        return true
    }

    func withSample(_ body: () -> Void) {
        let saved = (nowPlaying, artwork, tint)
        nowPlaying = NowPlaying(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                duration: 243, elapsed: 97, timestamp: nil, rate: 1, isPlaying: true,
                                bundleID: "com.apple.Music")
        artwork = Self.sampleArtwork
        tint = Self.sampleArtwork.vividColor ?? Color(red: 0.62, green: 0.55, blue: 1)
        body()
        (nowPlaying, artwork, tint) = saved
    }
    #endif
}
