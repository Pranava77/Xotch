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

    func start() {
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
        process.terminationHandler = { @Sendable [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.bridgeExited() }
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
        isAvailable = true
    }

    // MARK: - Commands

    func togglePlayPause() {
        send("toggle")
        if var playing = nowPlaying {
            // Update right away; the bridge confirms a moment later.
            playing.elapsed = playing.position(at: .now)
            playing.timestamp = .now
            playing.isPlaying.toggle()
            nowPlaying = playing
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
        if object["error"] != nil {
            isAvailable = false
            return
        }
        restarts = 0

        if let encoded = object["artwork"] as? String {
            let image = encoded.isEmpty ? nil : Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
            withAnimation(Motion.switchModule) {
                artwork = image
                tint = image?.vividColor ?? Theme.accent
            }
        }

        let title = object["title"] as? String ?? ""
        guard !title.isEmpty else {
            nowPlaying = nil
            updateActivity()
            return
        }
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

    private func bridgeExited() {
        process = nil
        input = nil
        buffer.removeAll()
        guard restarts < 3 else {
            isAvailable = false
            return
        }
        restarts += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
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
    func withSample(_ body: () -> Void) {
        let saved = (nowPlaying, artwork, tint)
        nowPlaying = NowPlaying(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                duration: 243, elapsed: 97, timestamp: nil, rate: 1, isPlaying: true,
                                bundleID: "com.apple.Music")
        artwork = nil
        tint = Color(red: 0.62, green: 0.55, blue: 1)
        body()
        (nowPlaying, artwork, tint) = saved
    }
    #endif
}
