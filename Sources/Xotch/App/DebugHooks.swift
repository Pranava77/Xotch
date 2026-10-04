#if DEBUG
import AppKit
import Metal
import QuickLookUI
import SwiftUI

/// Debug builds only: drive the notch from the command line.
///
///     scripts/debug.sh open [module] | close | activity | activity-media |
///                      activity-timer | activity-claude | activity-download |
///                      activity-recording | clear-activities [module] |
///                      capture <area|window|screen> | record <area|window|screen> |
///                      record-stop | celebrate | palette | ripple |
///                      theme <id> | rebuild <count> |
///                      status <file> | snapshot <folder> | effects <folder> |
///                      marketing <folder> | selftest <file>
///
/// `snapshot` renders every notch state to PNGs with ImageRenderer, so the
/// shell can be checked without screen-recording permission.
enum DebugHooks {
    static let notificationName = Notification.Name("com.pranava.xotch.debug")
    /// The window `settings:` opens, kept so `settings-close` can shut it.
    @MainActor private static var debugSettingsWindow: NSWindow?

    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor
    private static func run(_ command: String) {
        switch command {
        case "open": ScreenManager.shared.openPrimary()
        case "close": ScreenManager.shared.closeAll()
        case "activity": ActivityCenter.shared.postDemo()
        case "activity-media":
            ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "media", symbol: "music.note", content: .playing,
                                                          tint: .pink), for: "media")
        case "activity-timer":
            let end = Date().addingTimeInterval(90)
            ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                                          content: .countdown(until: end),
                                                          tint: TimerKind.focus.tint,
                                                          progress: .timed(start: end.addingTimeInterval(-120), end: end)),
                                             for: "timers")
        case "activity-claude":
            ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "claude", symbol: "sparkle", content: .text("Editing"),
                                                          tint: ClaudeLiveService.tint, earWidth: 110, pulse: .calm),
                                             for: "claude")
        case "activity-download":
            ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "downloads", symbol: "arrow.down", content: .text("62%"),
                                                          tint: Theme.accent, earWidth: 90, progress: .fraction(0.62)),
                                             for: "downloads")
        case "activity-recording":
            ActivityCenter.shared.setOngoing(CaptureService.recordingActivity(since: Date().addingTimeInterval(-42)),
                                             for: "capture")
        case "record-stop":
            CaptureService.shared.stopRecording()
        case "celebrate":
            ActivityCenter.shared.celebrate()
        case "palette":
            ScreenManager.shared.debugPalette()
        case "ripple":
            ScreenManager.shared.debugRipple()
        case "calendar-refresh":
            CalendarService.shared.refresh()
        case "clear-activities":
            for id in ["media", "timers", "claude", "notes", "downloads", "capture"] {
                ActivityCenter.shared.setOngoing(nil, for: id)
            }
        default:
            if command.hasPrefix("clear-activities:") {
                ActivityCenter.shared.setOngoing(nil, for: String(command.dropFirst("clear-activities:".count)))
            } else if command.hasPrefix("trace-spaces:") {
                ScreenManager.shared.debugTraceSpaces(to: String(command.dropFirst("trace-spaces:".count)))
            } else if command.hasPrefix("capture:"),
                      let target = CaptureTarget(rawValue: String(command.dropFirst("capture:".count))) {
                CaptureService.shared.takeScreenshot(target)
            } else if command.hasPrefix("record:"),
                      let target = CaptureTarget(rawValue: String(command.dropFirst("record:".count))) {
                CaptureService.shared.startRecording(target)
            } else if command.hasPrefix("click:") {
                // Either "x,y" in window coordinates, or the name a control
                // gave itself with `.debugFrame(_:)`.
                let target = String(command.dropFirst("click:".count))
                let parts = target.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    ScreenManager.shared.debugClick(at: CGPoint(x: parts[0], y: parts[1]))
                } else {
                    NotchPanel.debugNamedClick = ScreenManager.shared.debugClick(named: target)
                }
            } else if command.hasPrefix("type:") {
                ScreenManager.shared.debugType(String(command.dropFirst("type:".count)))
            } else if command.hasPrefix("probe:") {
                ScreenManager.shared.debugProbe(writingTo: String(command.dropFirst("probe:".count)))
            } else if command.hasPrefix("open:") {
                let target = String(command.dropFirst("open:".count)).split(separator: "@", maxSplits: 1)
                ScreenManager.shared.debugOpen(moduleID: String(target[0]),
                                               screen: target.count > 1 ? Int(target[1]) : nil)
            } else if command.hasPrefix("rebuild:") {
                let count = Int(command.dropFirst("rebuild:".count)) ?? 1
                for _ in 0..<count {
                    ScreenManager.shared.debugForceRebuild()
                }
            } else if command.hasPrefix("status:") {
                let path = String(command.dropFirst("status:".count))
                let lines = [
                    "screens: \(ScreenManager.shared.debugSummary)",
                    "ongoing: [\(ActivityCenter.shared.debugOngoingIDs)]",
                    "activity: \(ActivityCenter.shared.current?.moduleID ?? "-") waiting=\(ActivityCenter.shared.waitingCount) \(ActivityCenter.shared.debugRotation)",
                    "theme: \(ThemeStore.shared.palette.id) shaders ready=\(ShaderKit.shared.isReady) compile=\(ShaderKit.shared.compileTime.map { "\($0)" } ?? "-") failure=\(ShaderKit.shared.failure ?? "-")",
                    "audio levels: \(AudioLevels.shared.status)",
                    "media: hasNowPlaying=\(MediaService.shared.nowPlaying != nil) title=\(MediaService.shared.nowPlaying?.title ?? "-") hasArtwork=\(MediaService.shared.artwork != nil)",
                    "media log: \(MediaService.shared.debugLog.joined(separator: " | "))",
                    "ai: messages=\(AIChatService.shared.messages.count) streaming=\(AIChatService.shared.isStreaming) provider=\(AIProviderStore.shared.active.map { "\($0.kind)/\($0.model)" } ?? "-") notice=\(AIChatService.shared.notice ?? "-") last=\(AIChatService.shared.messages.last.map { "\($0.role) \($0.text.count) chars error=\($0.isError)" } ?? "-")",
                    "clipboard access: \(ClipboardService.shared.access)",
                    "todos: open today=\(TodoService.shared.openToday) total=\(TodoService.shared.todos.count)",
                    Storage.damaged.isEmpty ? "store: all files read cleanly"
                        : "store: DAMAGED, kept as \(Storage.damaged.joined(separator: ", "))",
                    "capture: permission=\(CaptureService.hasScreenPermission) items=\(CaptureService.shared.items.count) recording=\(CaptureService.shared.isRecording) starting=\(CaptureService.shared.isStartingRecording) stopping=\(CaptureService.shared.isStoppingRecording) notice=\(CaptureService.shared.notice.map { "\($0)" } ?? "-") quickLook=\(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible)",
                    String(format: "pointer events: %.1f/s", ScreenManager.shared.debugPointerRate()),
                ]
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            } else if command.hasPrefix("settings:") {
                // Shows the Settings view in its own window and writes the window
                // number to a file, for `screencapture -l`.
                let path = String(command.dropFirst("settings:".count))
                let window = SettingsWindow.makeWindow()
                window.orderFrontRegardless()
                debugSettingsWindow = window
                try? "\(window.windowNumber)".write(toFile: path, atomically: true, encoding: .utf8)
            } else if command.hasPrefix("settings-scroll:") {
                // Scrolls the debug Settings window's form to a point: `settings-scroll 900`.
                let y = Double(command.dropFirst("settings-scroll:".count)) ?? 0
                func scrollView(in view: NSView?) -> NSScrollView? {
                    guard let view else { return nil }
                    if let found = view as? NSScrollView { return found }
                    for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
                    return nil
                }
                if let scroll = scrollView(in: debugSettingsWindow?.contentView) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else if command.hasPrefix("settings-pane:") {
                // Switches Settings to a page: `settings-pane media`.
                UserDefaults.standard.set(String(command.dropFirst("settings-pane:".count)),
                                          forKey: SettingsKey.settingsPane)
            } else if command == "settings-close" {
                debugSettingsWindow?.close()
                debugSettingsWindow = nil
            } else if command.hasPrefix("key:") {
                // Sends a media key through the same handler the event tap uses,
                // with no Accessibility permission: `debug.sh key volup`.
                let names: [String: MediaKey] = ["volup": .volumeUp, "voldown": .volumeDown, "mute": .mute,
                                                 "brightup": .brightnessUp, "brightdown": .brightnessDown]
                if let key = names[String(command.dropFirst("key:".count))] {
                    _ = MediaKeys.shared.handle(key, isDown: true, flags: [])
                }
            } else if command.hasPrefix("sound:") {
                // Plays one cue whether or not sounds are switched on: `debug.sh sound complete`.
                if let cue = RetroCue(rawValue: String(command.dropFirst("sound:".count))) {
                    RetroSound.play(cue, force: true)
                }
            } else if command.hasPrefix("ai-ask:") {
                // Asks the AI chat a question without the UI: `debug.sh ai-ask "…"`.
                AIChatService.shared.ask(String(command.dropFirst("ai-ask:".count)))
            } else if command.hasPrefix("ai-rewrite:") {
                // Shorter, longer or retry on the last reply: `debug.sh ai-rewrite shorter`.
                let chat = AIChatService.shared
                if let last = chat.messages.last {
                    switch command.dropFirst("ai-rewrite:".count) {
                    case "shorter": chat.regenerate(last, as: .shorter)
                    case "longer": chat.regenerate(last, as: .longer)
                    default: chat.regenerate(last, as: .retry)
                    }
                }
            } else if command.hasPrefix("theme:") {
                ThemeStore.shared.select(String(command.dropFirst("theme:".count)))
            } else if command.hasPrefix("marketing:") {
                let folder = String(command.dropFirst("marketing:".count))
                Task { await MarketingShots.render(to: folder) }
            } else if command.hasPrefix("effects:") {
                let folder = String(command.dropFirst("effects:".count))
                Task { await renderEffects(to: folder) }
            } else if command.hasPrefix("snapshot:") {
                snapshot(to: String(command.dropFirst("snapshot:".count)))
            } else if command.hasPrefix("selftest:") {
                let path = String(command.dropFirst("selftest:".count))
                Task { await selfTest(writingTo: path) }
            }
        }
    }

    /// Exercises the real services and writes a report. Records states and
    /// counts only, never clipboard contents, notes or track titles.
    @MainActor
    private static func selfTest(writingTo path: String) async {
        var lines: [String] = []
        let stats = StatsService.shared
        stats.sampleNow()
        try? await Task.sleep(for: .seconds(1.5))
        stats.sampleNow()
        if let s = stats.snapshot {
            lines.append(String(format: "stats: cpu %.1f%%, memory %@ of %@, down %@, up %@, disk free %@ of %@",
                                s.cpu * 100, Format.bytes(s.memoryUsed), Format.bytes(s.memoryTotal),
                                Format.rate(s.download), Format.rate(s.upload),
                                Format.bytes(s.diskFree), Format.bytes(s.diskTotal)))
            if let b = s.battery {
                lines.append("battery: \(b.percent)% charging=\(b.isCharging) onPower=\(b.onPower) minutesLeft=\(b.minutesLeft.map(String.init) ?? "-") health=\(b.health.map { String(format: "%.2f", $0) } ?? "-") cycles=\(b.cycles.map(String.init) ?? "-")")
            }
        } else {
            lines.append("stats: no snapshot")
        }

        let media = MediaService.shared
        lines.append("media: available=\(media.isAvailable) hasNowPlaying=\(media.nowPlaying != nil) playing=\(media.nowPlaying?.isPlaying ?? false) app=\(media.nowPlaying?.bundleID ?? "-") hasArtwork=\(media.artwork != nil) hasDuration=\((media.nowPlaying?.duration ?? 0) > 0)")

        let calendar = CalendarService.shared
        lines.append("calendar: events=\(calendar.eventAccess) reminders=\(calendar.reminderAccess)")
        lines.append("clipboard: \(ClipboardService.shared.items.count) items, history=\(AppSettings.clipboardHistory)")
        lines.append("shelf: \(ShelfService.shared.items.count) items, airdrop=\(ShelfService.shared.canAirDrop)")
        lines.append("notes: \(NotesService.shared.notes.count) notes")
        lines += captureSelfTest()
        lines += todoSelfTest()
        lines += chatMarkdownSelfTest()
        lines += retroSoundSelfTest()
        lines += mediaKeysSelfTest()

        // Phase 5
        if #available(macOS 15.4, *) {
            lines.append("pasteboard accessBehavior raw=\(NSPasteboard.general.accessBehavior.rawValue) → xotch access \(ClipboardService.shared.access)")
        }
        lines += FullScreenDetector.selfTest()
        let wrapped = StatsService.cpuUsage(from: [UInt32.max - 99, 10, 1_000, 0], to: [100, 110, 1_300, 0])
        let normal = StatsService.cpuUsage(from: [100, 50, 800, 10], to: [150, 70, 1_000, 10])
        lines.append("cpu wrap: wrapped=\(wrapped.map { String(format: "%.3f", $0) } ?? "nil") (expect 0.500) normal=\(normal.map { String(format: "%.3f", $0) } ?? "nil") (expect 0.259)")
        lines.append("clock format: \(Format.clock(0)) \(Format.clock(59.2)) \(Format.clock(3725)) \(Format.clock(.infinity)) \(Format.clock(-5)) \(Format.clock(1e12))")
        let crashFolder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("crash-test", isDirectory: true)
        try? FileManager.default.removeItem(at: crashFolder)
        try? FileManager.default.createDirectory(at: crashFolder, withIntermediateDirectories: true)
        let markerFile = crashFolder.appendingPathComponent("session.lock")
        let sessionStart = Date().addingTimeInterval(-600)
        try? String(sessionStart.timeIntervalSince1970).write(to: markerFile, atomically: true, encoding: .utf8)
        let oldReport = crashFolder.appendingPathComponent("Xotch-2026-01-01-000000.ips")
        let newReport = crashFolder.appendingPathComponent("Xotch-2026-09-16-120000.ips")
        let otherApp = crashFolder.appendingPathComponent("Safari-2026-09-16-120500.ips")
        for file in [oldReport, newReport, otherApp] {
            try? "{}".write(to: file, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.modificationDate: sessionStart.addingTimeInterval(-3600)], ofItemAtPath: oldReport.path)
        let found = Diagnostics.crashReport(markerURL: markerFile, reportsFolder: crashFolder)
        try? FileManager.default.removeItem(at: markerFile)
        let noMarker = Diagnostics.crashReport(markerURL: markerFile, reportsFolder: crashFolder)
        try? FileManager.default.removeItem(at: crashFolder)
        lines.append("crash detection: found=\(found?.lastPathComponent ?? "nil") (expect Xotch-2026-09-16-120000.ips) withoutMarker=\(noMarker?.lastPathComponent ?? "nil") (expect nil)")
        lines.append("diagnostics: sharing=\(Diagnostics.shared.isSharingEnabled) lastCrash=\(Diagnostics.shared.lastCrashReport?.lastPathComponent ?? "none") version=\(Diagnostics.versionString)")

        // Claude Code
        let reportFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let settings = reportFolder.appendingPathComponent("claude-settings-test.json")
        let original = #"{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo existing"}]}]}}"#
        try? FileManager.default.removeItem(at: settings)
        try? FileManager.default.removeItem(at: settings.appendingPathExtension("xotch-backup"))
        try? original.write(to: settings, atomically: true, encoding: .utf8)
        do {
            try ClaudeHookInstaller.install(at: settings)
            try ClaudeHookInstaller.install(at: settings)
            let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
            let hooks = installed["hooks"] as? [String: Any] ?? [:]
            let preToolGroups = (hooks["PreToolUse"] as? [[String: Any]])?.count ?? 0
            lines.append("hook install: detected=\(ClaudeHookInstaller.isInstalled(at: settings)) events=\(hooks.keys.sorted()) preToolUseGroups=\(preToolGroups) keptModel=\(installed["model"] as? String ?? "-") backup=\(FileManager.default.fileExists(atPath: settings.appendingPathExtension("xotch-backup").path))")
            try ClaudeHookInstaller.uninstall(at: settings)
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary
            let before = try JSONSerialization.jsonObject(with: Data(original.utf8)) as? NSDictionary
            lines.append("hook uninstall: detected=\(ClaudeHookInstaller.isInstalled(at: settings)) restoredExactly=\(after == before)")
        } catch {
            lines.append("hook installer failed: \(error)")
        }
        lines.append("hook command: \(ClaudeHookInstaller.command)")
        lines.append("claude live: listening=\(ClaudeLiveService.shared.isListening) socket=\(ClaudeLiveService.socketPath) sessions=\(ClaudeLiveService.shared.sessions.map { "\($0.project):\($0.stateLabel)" })")

        let started = Date()
        await ClaudeUsageService.shared.reload()
        if let usage = ClaudeUsageService.shared.summary {
            let today = usage.today
            lines.append(String(format: "claude usage (%.2fs): logs=%@ streak=%d today tokens=%d (in %d, out %d, cache %d) replies=%d tools=%d sessions=%d week=%@",
                                Date().timeIntervalSince(started), String(usage.foundLogs), usage.streak, today.totalTokens,
                                today.inputTokens, today.outputTokens, today.cacheReadTokens + today.cacheWriteTokens,
                                today.replies, today.toolCalls, today.sessions.count,
                                usage.week.map { String($0.totalTokens) }.joined(separator: ",")))
        }
        let rescan = Date()
        await ClaudeUsageService.shared.reload()
        lines.append(String(format: "claude usage cached rescan: %.3fs", Date().timeIntervalSince(rescan)))
        lines.append("activity: current=\(ActivityCenter.shared.current?.moduleID ?? "-")")

        lines += await phase4SelfTest(folder: reportFolder)

        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Signature UI: palette parsing, gestures, shaders, audio analysis,
    /// download progress and themes.
    @MainActor
    private static func phase4SelfTest(folder: URL) async -> [String] {
        var lines: [String] = []

        let durations = ["10", "10m", "timer 25 min", "90s", "1h", "2 hours", "0", "abc", "1000"]
            .map { "\($0)=\(CommandCatalog.duration(in: $0).map { String(Int($0)) } ?? "nil")" }
        lines.append("palette durations: \(durations.joined(separator: " ")) (expect 600 600 1500 90 3600 7200 nil nil nil)")
        let actions = SnapshotActions()
        // Sample data: the palette also searches the clipboard.
        withSampleData {
            for query in ["", "cal", "gcal", "10 min", "theme", "pause", "xotch", "zzzz"] {
                let titles = CommandCatalog.commands(for: query, actions: actions).map(\.title)
                lines.append("palette \"\(query)\": \(titles.count) → \(titles.prefix(3).joined(separator: " | "))")
            }
        }

        let bands = [-300, -44, 0, 10, 44, 300].map { String(format: "%.1f", NotchWindowController.rubberBand(for: $0)) }
        lines.append("rubber band for -300 -44 0 10 44 300: \(bands.joined(separator: " ")) (limit ±56)")

        let bitmap = DotMatrix.render("Xotch 42 — Café ✓", rows: 9)
        let lit = bitmap.values.filter { $0 > 128 }.count
        lines.append("dot matrix: \(bitmap.columns)×\(bitmap.rows) lit=\(lit) of \(bitmap.values.count)")
        lines.append(DotMatrix.ascii(bitmap))

        let kit = ShaderKit.shared
        kit.prepare()
        for _ in 0..<40 where !kit.isReady && kit.failure == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        lines.append("shaders: ready=\(kit.isReady) compile=\(kit.compileTime.map { "\($0)" } ?? "-") failure=\(kit.failure ?? "-")")

        // Bands are bass to treble, one per bar beside the notch.
        let bandCount = SpectrumAnalyzer.bandCount
        lines.append(spectrumCheck("80 Hz", frequency: 80, peakIn: 0...2))
        lines.append(spectrumCheck("2.5 kHz", frequency: 2500, peakIn: bandCount / 2...bandCount - 3))
        lines.append(spectrumCheck("7 kHz", frequency: 7000, peakIn: bandCount - 3...bandCount - 1))
        let silence = spectrum(frequency: 0)
        lines.append("spectrum silence: \(format(silence)) → \(silence.allSatisfy { $0 == 0 } ? "PASS" : "FAILED: not all 0")")
        lines.append("audio levels: enabled=\(AudioLevels.shared.isEnabled) status=\(AudioLevels.shared.status)")
        let volume = SystemVolume.volume
        lines.append("volume: device=\(SystemVolume.outputDevice() != nil) readable=\(volume != nil) settable=\(SystemVolume.canSetVolume) muted=\(SystemVolume.isMuted) symbol=\(SystemVolume.symbol(for: volume ?? 0, muted: SystemVolume.isMuted))")

        // A fake download in a scratch folder.
        let downloads = folder.appendingPathComponent("downloads-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("xotch-test.zip.crdownload")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let center = ActivityCenter.shared
        DownloadsService.shared.debugWatch(downloads)
        try? await Task.sleep(for: .milliseconds(300))
        let progress = Progress(totalUnitCount: 100)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = file
        progress.publish()
        progress.completedUnitCount = 40
        try? await Task.sleep(for: .milliseconds(1200))
        let during = center.ongoing["downloads"]
        progress.completedUnitCount = 100
        try? await Task.sleep(for: .milliseconds(700))
        progress.unpublish()
        try? await Task.sleep(for: .milliseconds(500))
        let after = center.ongoing["downloads"]
        let doneBanner = center.banner?.moduleID == "downloads" || center.hud?.moduleID == "downloads"
        lines.append("downloads: during=\(describe(during)) after=\(describe(after)) doneBanner=\(doneBanner)")
        DownloadsService.shared.settingsChanged()
        try? FileManager.default.removeItem(at: downloads)

        let store = ThemeStore.shared
        for palette in store.choices {
            lines.append("theme \(palette.id): material=\(palette.material.rawValue) accent luminance=\(String(format: "%.2f", palette.accent.luminance)) text on accent=\(palette.accent.luminance > 0.45 ? "black" : "white") glow=\(palette.glow != nil ? "own" : "module") strength=\(palette.glowStrength)")
        }
        lines.append("theme selected=\(store.selectedID) glass api=\(glassAvailable) forcedFallback=\(GlassFallback.forced)")

        let ringNow = RingView.fraction(of: .timed(start: Date().addingTimeInterval(-30), end: Date().addingTimeInterval(90)), at: .now)
        lines.append(String(format: "ring: timed 30 s of 120 s = %.2f (expect 0.25)", ringNow))
        lines.append("cleanup: done=\(UserDefaults.standard.bool(forKey: "cleanup.removedConnectedModules")) module list \"home,revenue,media,weather,analytics,stats\" → \"\(LegacyCleanup.strippingRemoved(from: "home,revenue,media,weather,analytics,stats"))\" (expect home,media,stats)")
        return lines
    }

    /// Key decoding, step maths and modifier rules, plus what this Mac can do.
    /// Reads the brightness but never changes it.
    @MainActor
    private static func mediaKeysSelfTest() -> [String] {
        // data1 for a key: code << 16 | flags, where 0xA00 is pressed and 0xB00 released.
        func data(_ key: Int, down: Bool) -> Int { key << 16 | (down ? 0xA00 : 0xB00) }
        func describe(_ code: Int, down: Bool) -> String {
            guard let result = MediaKeyLogic.decode(data1: data(code, down: down)) else { return "nil" }
            return "\(result.key)/\(result.isDown)"
        }
        let decoded: [String] = [describe(0, down: true), describe(7, down: false), describe(21, down: true)]
        let steps: [Double] = [
            MediaKeyLogic.step(0.5, up: true, fine: false),      // 9/16
            MediaKeyLogic.step(0.52, up: true, fine: false),     // snaps: 9/16
            MediaKeyLogic.step(1, up: true, fine: false),        // stays 1
            MediaKeyLogic.step(0, up: false, fine: false),       // stays 0
            MediaKeyLogic.step(0.5, up: false, fine: true),      // 31/64
        ]
        let modifiers: [MediaKeyLogic.Modifiers] = [MediaKeyLogic.modifiers([]), MediaKeyLogic.modifiers([.shift, .option]),
                                                    MediaKeyLogic.modifiers([.option]), MediaKeyLogic.modifiers([.command])]
        let expectedSteps: [Double] = [9.0 / 16, 9.0 / 16, 1, 0, 31.0 / 64]
        let stepsOK = steps == expectedSteps
        let ok = decoded == ["volumeUp/true", "mute/false", "nil"] && stepsOK
            && modifiers == [.plain, .fine, .passThrough, .passThrough]
        let brightness = Brightness.level.map { String(format: "%.2f", $0) } ?? "unavailable"
        let stepText = steps.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let verdict = ok ? "PASS" : "FAILED"
        let first = "media keys: decode=\(decoded.joined(separator: ",")) steps=\(stepText) modifiers=\(modifiers) → \(verdict)"
        let enabled = AppSettings.mediaKeysHUD
        let trusted = MediaKeys.isTrusted
        let running = MediaKeys.shared.isRunning
        let canSet = SystemVolume.canSetVolume
        let canShow = ScreenManager.shared.canShowHUD
        let second = "media keys on this Mac: enabled=\(enabled) trusted=\(trusted) tapRunning=\(running) canSetVolume=\(canSet) brightness=\(brightness) canShowHUD=\(canShow)"
        return [first, second]
    }

    /// Renders every cue and checks it is audible, not clipped, short, and
    /// starts and ends at silence (a click is a jump at either edge).
    @MainActor
    private static func retroSoundSelfTest() -> [String] {
        var problems: [String] = []
        var summary: [String] = []
        for cue in RetroCue.allCases {
            let samples = RetroSynth.render(cue)
            let peak = samples.map(abs).max() ?? 0
            let ms = Int(Double(samples.count) / RetroSynth.sampleRate * 1000)
            let edge = max(abs(samples.first ?? 1), abs(samples.last ?? 1))
            summary.append("\(cue.rawValue)=\(ms)ms/\(String(format: "%.2f", peak))")
            if peak < 0.2 { problems.append("\(cue.rawValue) is nearly silent") }
            if peak > RetroSynth.peak + 0.001 { problems.append("\(cue.rawValue) clips") }
            if ms > 900 { problems.append("\(cue.rawValue) is too long") }
            if edge > 0.05 { problems.append("\(cue.rawValue) would click at its edge") }
        }
        return ["retro sounds: \(summary.joined(separator: " ")) enabled=\(AppSettings.retroSounds) engineRunning=\(RetroSound.shared.isEngineRunning) → \(problems.isEmpty ? "PASS" : "FAILED: " + problems.joined(separator: "; "))"]
    }

    /// Adds a real to-do, ticks it, moves it and deletes it: the same calls the
    /// buttons make, so a broken save shows up here.
    /// Parses replies the way they arrive, finished and half-streamed, and
    /// checks the blocks the chat would draw.
    private static func chatMarkdownSelfTest() -> [String] {
        func kinds(_ text: String) -> String {
            ChatMarkdown.blocks(text).map { block in
                switch block {
                case .heading(let level, _): "h\(level)"
                case .paragraph: "p"
                case .list(let items): "list(" + items.map { "\($0.isOrdered ? "n" : "b")\($0.indent)" }.joined(separator: ",") + ")"
                case .code(let language, _): "code(\(language ?? "-"))"
                case .quote: "quote"
                case .table(let header, let rows): "table(\(header.count)x\(rows.count))"
                case .rule: "rule"
                }
            }.joined(separator: " ")
        }
        let cases: [(String, String, String)] = [
            ("full", """
            ## Plan for C#
            Three steps:
            1. Install it
            2. Configure
               - set the key
               - restart
            3. Run

            | Tool | Cost |
            |---|:---:|
            | A | Free |

            > Note this.

            ---
            ```swift
            print("hi")
            ```
            """, "h2 p list(n0,n0,b1,b1,n0) table(2x1) quote rule code(swift)"),
            ("streaming code", "Try this:\n```swift\nlet a = 1", "p code(swift)"),
            ("streaming table", "| a | b |", "p"),
            ("loose list", "1. one\n\n2. two\n\nAfter.", "list(n0,n0) p"),
            ("not a list", "**Bold** start\n2024 was a year", "p"),
        ]
        var lines = cases.map { name, text, expected in
            let got = kinds(text)
            return "chat markdown \(name): \(got) → \(got == expected ? "PASS" : "FAILED: expected \(expected)")"
        }

        // Code colours: which kinds of token a line splits into.
        func shape(_ code: String, _ language: String?) -> String {
            CodeHighlighter.tokens(code, language: language)
                .filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty || $0.1 != .plain }
                .map { "\($0.1)" }.joined(separator: ",")
        }
        let code: [(String, String, String?, String)] = [
            ("swift", #"let name = "Xotch" // hi"#, "swift", "keyword,plain,string,comment"),
            ("shell", #"echo "$HOME" # where"#, "bash", "plain,string,comment"),
            ("type and number", "View(width: 42)", "swift", "type,plain,number,plain"),
            ("python", "def f(): return None", "python", "keyword,plain,keyword,keyword"),
        ]
        for (name, text, language, expected) in code {
            let got = shape(text, language)
            lines.append("code colours \(name): \(got) → \(got == expected ? "PASS" : "FAILED: expected \(expected)")")
        }

        // Follow-up questions: finished, half-streamed, missing.
        let follow: [(String, String, String)] = [
            ("finished", "Answer.\nFollow-ups: One? | Two? | Three?", "Answer.|One?,Two?,Three?"),
            ("bold label", "Answer.\n**Follow-ups:** One | Two", "Answer.|One,Two"),
            ("streaming", "Answer.\nFollow-u", "Answer.|"),
            ("none", "Answer.\nFine.", "Answer.\nFine.|"),
        ]
        for (name, text, expected) in follow {
            let parts = ChatMarkdown.splitFollowUps(text)
            let got = parts.body + "|" + parts.followUps.joined(separator: ",")
            lines.append("follow-ups \(name): \(got.replacingOccurrences(of: "\n", with: "⏎")) → \(got == expected ? "PASS" : "FAILED")")
        }

        // Callouts.
        let callouts: [(String, ChatMarkdown.Callout?, String)] = [
            ("**Note:** testers need it", .info, "testers need it"),
            ("[!WARNING] Back up first", .warning, "Back up first"),
            ("Tip: press ⌘K", .tip, "press ⌘K"),
            ("Just a quote", nil, ""),
            ("Note that this is a plain quote", nil, ""),
            ("**Important**: keep the key safe", .warning, "keep the key safe"),
        ]
        for (text, kind, body) in callouts {
            let got = ChatMarkdown.callout(text)
            let ok = got?.kind == kind && (kind == nil || got?.body == body)
            lines.append("callout “\(text)”: \(got.map { "\($0.kind) “\($0.body)”" } ?? "none") → \(ok ? "PASS" : "FAILED")")
        }
        return lines
    }

    @MainActor
    private static func todoSelfTest() -> [String] {
        var lines: [String] = []
        let todos = TodoService.shared
        let before = todos.todos.count
        let todo = todos.add("Self-test to-do", on: TodoService.today)
        let added = todo != nil
        var ticked = false, moved = false
        if let todo {
            todos.toggle(todo)
            ticked = todos.todos.first { $0.id == todo.id }?.isDone ?? false
            todos.move(todo, to: nil)
            moved = todos.todos.first { $0.id == todo.id }?.day == nil
            todos.delete(todo)
        }
        let cleaned = todos.todos.count == before
        lines.append("todos round trip: added=\(added) ticked=\(ticked) movedToSomeday=\(moved) cleanedUp=\(cleaned) → \(added && ticked && moved && cleaned ? "PASS" : "FAILED")")
        let renamed = UserDefaults.standard.bool(forKey: "migration.renamedFromBrim")
        let oldFolder = FileManager.default.fileExists(atPath: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Brim").path)
        lines.append("rename: migrated=\(renamed) oldFolderLeft=\(oldFolder) oldSettings=\(Migration.oldSettings()?.count ?? 0) keys, support=\(Storage.directory.lastPathComponent), hook=\(ClaudeHookInstaller.marker)")
        lines.append("todos: \(todos.todos.count) to-dos, rollover=\(AppSettings.todoRollover), ear=\(AppSettings.todoActivity)")
        return lines
    }

    /// File naming, folders and the Spotlight query, without taking a capture.
    @MainActor
    private static func captureSelfTest() -> [String] {
        let capture = CaptureService.shared
        var lines: [String] = []
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 9, 17, 15, 4, 5)
        let date = Calendar.current.date(from: parts) ?? .now
        lines.append("capture names: \"\(CaptureService.fileName(prefix: "Screenshot", date: date, extension: "png"))\" \"\(CaptureService.fileName(prefix: "Screen Recording", date: date, extension: "mov", attempt: 2))\" (expect \"Screenshot 2026-09-17 at 15.04.05.png\" \"Screen Recording 2026-09-17 at 15.04.05 (2).mov\")")
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        lines.append("capture query: \(CaptureService.macScreenshotPredicate(since: since).predicateFormat) | \(CaptureService.macScreenshotPredicate(since: nil).predicateFormat)")
        lines.append("capture folders: xotch=\(capture.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) mac=\(CaptureService.macScreenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        let main = CGMainDisplayID()
        lines.append("capture display: pointer=\(CaptureService.screencaptureIndex(of: CaptureService.displayUnderPointer())) main=\(CaptureService.screencaptureIndex(of: main)) (expect main=1) unknown=\(CaptureService.screencaptureIndex(of: 999_999)) (expect 1)")
        if let screen = NSScreen.screens.first {
            let height = screen.frame.height
            let picked = RegionPicker.selection(for: NSRect(x: 100, y: height - 300, width: 400.4, height: 200), on: screen)
            let tiny = RegionPicker.selection(for: NSRect(x: 10, y: 10, width: 8, height: 40), on: screen)
            let edge = RegionPicker.selection(for: NSRect(x: -50, y: -50, width: 150, height: 150), on: screen)
            lines.append("capture area: rect=\(picked.map { "\($0.rect)" } ?? "nil") (expect (100.0, 100.0, 401.0, 200.0)) tiny=\(tiny == nil ? "nil" : "rect") (expect nil) edge=\(edge.map { "\($0.rect.size)" } ?? "nil") (expect (100.0, 100.0))")
        }
        lines.append("capture: permission=\(CaptureService.hasScreenPermission) canRecord=\(CaptureService.canRecord) items=\(capture.items.count) keepDays=\(AppSettings.captureKeepDays) includesMac=\(AppSettings.captureIncludesMac) copies=\(AppSettings.captureCopies)")
        let actions = SnapshotActions()
        var titles: [String] = []
        for query in ["shot", "record", "screenshot win"] {
            let found = CommandCatalog.commands(for: query, actions: actions).map(\.title)
            titles.append("\"\(query)\" → \(found.prefix(3).joined(separator: " | "))")
        }
        lines.append("capture palette: \(titles.joined(separator: "; "))")
        return lines
    }

    private static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private static func describe(_ activity: LiveActivity?) -> String {
        guard let activity else { return "none" }
        var text = "\(activity.content)"
        if let progress = activity.progress { text += " ring=\(progress)" }
        return text
    }

    /// Which band a sine wave lights up most, and whether that's where it belongs.
    private static func spectrumCheck(_ name: String, frequency: Double, peakIn expected: ClosedRange<Int>) -> String {
        let levels = spectrum(frequency: frequency)
        let peak = levels.indices.max { levels[$0] < levels[$1] } ?? -1
        let verdict = expected.contains(peak) ? "PASS" : "FAILED: expected band \(expected.lowerBound)–\(expected.upperBound)"
        return "spectrum \(name): \(format(levels)) peak band \(peak) → \(verdict)"
    }

    private static func format(_ levels: [Float]) -> String {
        levels.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    /// Band levels after a few windows of a sine wave.
    private static func spectrum(frequency: Double) -> [Float] {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        var phase = 0.0
        var levels: [Float] = []
        for _ in 0..<24 {
            var buffer = [Float](repeating: 0, count: 512)
            for index in buffer.indices {
                buffer[index] = frequency > 0 ? Float(sin(phase)) * 0.5 : 0
                phase += 2 * .pi * frequency / 48_000
            }
            if let result = buffer.withUnsafeBufferPointer({ analyzer.add($0.baseAddress!, count: 512, stride: 1) }) {
                levels = result
            }
        }
        return levels
    }

    /// Draws each Metal effect into an image, so they can be checked without
    /// screen recording.
    @MainActor
    private static func renderEffects(to directory: String) async {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kit = ShaderKit.shared
        kit.prepare()
        for _ in 0..<60 where !kit.isReady {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard kit.isReady, let device = kit.device else { return }
        let accent = ThemeStore.shared.palette.accent

        func save(_ name: String, effect: ShaderEffect, size: CGSize, texture: MTLTexture? = nil,
                  uniforms: ShaderUniforms) {
            guard let effectImage = kit.image(effect, size: size, scale: 2, uniforms: uniforms, texture: texture) else { return }
            let width = effectImage.width, height = effectImage.height
            // Composite over the notch's black so the image shows what you'd see.
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(effectImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
        }

        let open = Layout.openSize
        for time in [0.12, 0.35, 0.7] {
            var uniforms = ShaderUniforms(time: time, size: open, scale: 2, colorA: accent, colorB: .white)
            uniforms[12] = 300
            uniforms[13] = 150
            save("ripple-\(Int(time * 100))", effect: .ripple, size: open, uniforms: uniforms)
        }
        let glowSize = CGSize(width: 132 + 52, height: 132 + 52)
        for (name, colors) in [("pink", (RGBA(hex: 0xFF5E9C), RGBA(hex: 0xFFB05E))),
                               ("blue", (RGBA(hex: 0x4FA3FF), RGBA(hex: 0x9B6BFF)))] {
            for time in [0.0, 2.5] {
                var uniforms = ShaderUniforms(time: time, size: glowSize, scale: 2, colorA: colors.0, colorB: colors.1)
                uniforms[12] = 26
                uniforms[13] = 21
                uniforms[14] = 0.75
                save("glow-\(name)-\(Int(time * 10))", effect: .glow, size: glowSize, uniforms: uniforms)
            }
        }
        let bitmap = DotMatrix.render("Midnight City — M83", rows: 9)
        let texture = DotMatrix.texture(bitmap, device: device)
        let ledSize = CGSize(width: 330, height: 27)
        for (name, offset, wraps) in [("start", 0, false), ("scrolled", 70, true)] {
            var uniforms = ShaderUniforms(time: 0, size: ledSize, scale: 2, colorA: accent,
                                          colorB: RGBA(red: accent.red, green: accent.green, blue: accent.blue, alpha: 0.1))
            uniforms[12] = 3
            uniforms[13] = 9
            uniforms[14] = Float(offset)
            uniforms[15] = Float(wraps ? bitmap.columns + 10 : bitmap.columns)
            uniforms[16] = wraps ? 1 : 0
            uniforms[17] = Float(bitmap.columns)
            uniforms[18] = wraps ? 1 : 0
            save("led-\(name)", effect: .led, size: ledSize, texture: texture, uniforms: uniforms)
        }

        // Core Animation pieces, drawn from their layers.
        func saveLayer(_ name: String, view: NSView, size: CGSize) {
            view.frame = CGRect(origin: .zero, size: size)
            view.layout()
            guard let layer = view.layer,
                  let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            context.scaleBy(x: 2, y: 2)
            layer.render(in: context)
            guard let image = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
        }
        let ring = RingView(frame: .zero)
        ring.update(progress: .fraction(0.62), tint: accent.nsColor)
        saveLayer("ring-62", view: ring, size: CGSize(width: 46, height: 46))
        // The Core Animation versions of the glow and the LED display.
        let glow = GlowView(frame: .zero)
        glow.update(colors: [RGBA(hex: 0xFF5E9C), RGBA(hex: 0xFFB05E)], padding: 24, cornerRadius: 21, animating: false)
        saveLayer("glowview", view: glow, size: CGSize(width: 180, height: 180))
        for (name, text) in [("fits", "Xotch — 42"), ("scrolls", "Midnight City — M83 — Hurry Up, We're Dreaming")] {
            let led = LEDView(frame: .zero)
            led.update(text: text, color: accent, rows: 9, pitch: 3, animating: false)
            saveLayer("ledview-\(name)", view: led, size: CGSize(width: 330, height: 27))
        }
    }

    @MainActor
    private static func snapshot(to directory: String) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = SnapshotActions()
        // Your own live activities (music, Claude) would cover the samples.
        let stashed = ActivityCenter.shared.debugStash()
        defer { ActivityCenter.shared.debugRestore(stashed) }

        func render(_ name: String, configure: (NotchViewModel) -> Void) {
            let model = NotchViewModel(geometry: NotchGeometry(screen: screen))
            configure(model)
            let view = ShellView(model: model, actions: actions)
                .frame(width: Layout.panelSize.width, height: Layout.panelSize.height)
                .background(Color(white: 0.84))
                .environment(\.snapshotMode, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return
            }
            try? png.write(to: folder.appendingPathComponent("\(name).png"))
        }

        render("1-closed") { _ in }
        render("2-peek") { $0.phase = .peek }
        // Sample data, so snapshots never show your own clipboard, notes, calendar or media.
        withSampleData {
            for module in ModuleRegistry.all {
                render("4-open-\(module.id)") {
                    $0.phase = .open
                    $0.selectedModuleID = module.id
                }
            }
            // Every kind of block in a reply, at both sizes.
            AIChatService.shared.withRichSample {
                render("4-open-ai-rich") {
                    $0.phase = .open
                    $0.selectedModuleID = AIModule.moduleID
                }
                AIChatService.shared.withExpanded {
                    render("4-open-ai-expanded") {
                        $0.phase = .open
                        $0.selectedModuleID = AIModule.moduleID
                    }
                }
            }
            AIChatService.shared.withCodeSample {
                render("4-open-ai-code") {
                    $0.phase = .open
                    $0.selectedModuleID = AIModule.moduleID
                }
                // Tall enough for the action bar and follow-up chips.
                AIChatService.shared.withExpanded {
                    render("4-open-ai-code-expanded") {
                        $0.phase = .open
                        $0.selectedModuleID = AIModule.moduleID
                    }
                }
            }
            AIChatService.shared.withStreamingSample {
                render("4-open-ai-streaming") {
                    $0.phase = .open
                    $0.selectedModuleID = AIModule.moduleID
                }
            }
        }
        withSampleData {
            // A volume key pressed while the notch is open: the level takes the header.
            ActivityCenter.shared.showHUD(LiveActivity(moduleID: "volume", symbol: "speaker.wave.2.fill",
                                                       content: .level(0.56), tint: Theme.ink, earWidth: 96),
                                          for: .seconds(30))
            render("4-open-key-hud") {
                $0.phase = .open
                $0.selectedModuleID = "home"
            }
            // Its timer can't fire while the snapshots run, so it would cover
            // every activity rendered after this.
            ActivityCenter.shared.debugClearHUD()
        }
        withSampleData {
            CaptureService.shared.debugSetRecording(since: Date().addingTimeInterval(-75))
            render("4-open-capture-recording") {
                $0.phase = .open
                $0.selectedModuleID = "capture"
            }
            render("4-open-home-recording") {
                $0.phase = .open
                $0.selectedModuleID = "home"
            }
        }
        render("4-open-capture-empty") {
            $0.phase = .open
            $0.selectedModuleID = "capture"
        }
        render("5-open-pinned") {
            $0.phase = .open
            $0.isPinned = true
        }
        // Signature UI
        withSampleData {
        for palette in ThemeStore.shared.choices {
            ThemeStore.shared.withPalette(palette.id) {
                render("6-theme-\(palette.id)-media") {
                    $0.phase = .open
                    $0.selectedModuleID = "media"
                }
                render("6-theme-\(palette.id)-home") {
                    $0.phase = .open
                    $0.selectedModuleID = "home"
                }
            }
        }
        for query in ["", "10 min", "cal"] {
            render("6-palette-\(query.isEmpty ? "empty" : query.replacingOccurrences(of: " ", with: ""))") {
                $0.phase = .open
                $0.isPinned = true
                $0.selectedModuleID = "home"
                $0.palette.isOpen = true
                $0.palette.query = query
            }
        }
        render("6-rubber-band") {
            $0.phase = .open
            $0.selectedModuleID = ModuleRegistry.visibleNow.first?.id ?? "home"
            $0.rubberBand = NotchWindowController.rubberBand(for: 140)
        }
        }
        let center = ActivityCenter.shared
        center.setOngoing(LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                       content: .countdown(until: Date().addingTimeInterval(24 * 60 + 59)),
                                       tint: TimerKind.focus.tint), for: "timers")
        render("3-activity-timer") { _ in }
        center.setOngoing(nil, for: "timers")
        center.setOngoing(LiveActivity(moduleID: "notes", symbol: "note.text", content: .text("Call the bank before 5"),
                                       tint: .yellow, earWidth: 170), for: "notes")
        render("3-activity-note") { _ in }
        center.setOngoing(nil, for: "notes")
        // The music wave on its own, then with Adiyogi taking the left ear.
        center.setOngoing(LiveActivity(moduleID: "media", symbol: "music.note", content: .playing, tint: .pink), for: "media")
        render("3-activity-music") { _ in }
        center.debugShowAdiyogi(true)
        render("3-activity-music-adiyogi") { _ in }
        center.debugShowAdiyogi(false)
        center.setOngoing(nil, for: "media")
        let end = Date().addingTimeInterval(18 * 60)
        // The newest live activity takes the ear first; the dots show the round.
        center.setOngoing(LiveActivity(moduleID: "media", symbol: "music.note", content: .playing, tint: .pink), for: "media")
        center.setOngoing(LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                       content: .countdown(until: end), tint: TimerKind.focus.tint,
                                       progress: .timed(start: end.addingTimeInterval(-25 * 60), end: end)), for: "timers")
        render("3-activity-ring-waiting") { _ in }
        // A turn later, music has the ear and the second dot is lit.
        center.showNext()
        render("3-activity-turns-next") { _ in }
        center.setOngoing(nil, for: "timers")
        center.setOngoing(nil, for: "media")
        center.setOngoing(LiveActivity(moduleID: "claude", symbol: "sparkle", content: .text("Editing"),
                                       tint: ClaudeLiveService.tint, earWidth: 110, pulse: .calm), for: "claude")
        render("3-activity-claude") { _ in }
        center.setOngoing(nil, for: "claude")
        center.setOngoing(LiveActivity(moduleID: "downloads", symbol: "arrow.down", content: .text("62%"),
                                       tint: Theme.accent, earWidth: 90, progress: .fraction(0.62)), for: "downloads")
        render("3-activity-download") { _ in }
        center.setOngoing(nil, for: "downloads")
        center.setOngoing(CaptureService.recordingActivity(since: Date().addingTimeInterval(-42)), for: "capture")
        render("3-activity-recording") { _ in }
        center.setOngoing(nil, for: "capture")
        center.setOngoing(LiveActivity(moduleID: "volume", symbol: "speaker.wave.2.fill", content: .level(0.56),
                                       tint: Theme.ink, earWidth: 96), for: "volume")
        render("3-activity-volume") { _ in }
        center.setOngoing(nil, for: "volume")
        NotesService.shared.start()
        center.post(LiveActivity(moduleID: "timers", symbol: "checkmark.circle.fill",
                                 content: .text("Done"), tint: Theme.positive))
        render("3-activity") { _ in }
    }
}

/// Swaps every module's data for samples while `body` runs.
@MainActor
func withSampleData(_ body: () -> Void) {
    MediaService.shared.withSample {
    CalendarService.shared.withSample {
    ClipboardService.shared.withSample {
    NotesService.shared.withSample {
    ShelfService.shared.withSample {
    CaptureService.shared.withSample {
    TodoService.shared.withSample {
    StatsService.shared.withSample {
    ClaudeUsageService.shared.withSample {
    ClaudeLiveService.shared.withSample {
    AIProviderStore.shared.withSample {
    AIContextStore.shared.withSample {
    AIChatService.shared.withSample {
        body()
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
    }
}

@MainActor
final class SnapshotActions: NotchActions {
    var isPinned = false
    func tapped() {}
    func togglePin() {}
    func select(moduleID: String) {}
    func closeNotch() {}
    func togglePalette() {}
    func closePalette() {}
    func run(_ command: PaletteCommand) {}
}
#endif
