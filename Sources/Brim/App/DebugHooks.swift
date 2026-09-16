#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: drive the notch from the command line.
///
///     scripts/debug.sh open [module] | close | activity | activity-media |
///                      activity-timer | clear-activities | rebuild <count> |
///                      status <file> | snapshot <folder> | selftest <file>
///
/// `snapshot` renders every notch state to PNGs with ImageRenderer, so the
/// shell can be checked without screen-recording permission.
enum DebugHooks {
    static let notificationName = Notification.Name("com.pranava.brim.debug")

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
            ActivityCenter.shared.setOngoing(LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                                          content: .countdown(until: Date().addingTimeInterval(1500)),
                                                          tint: TimerKind.focus.tint), for: "timers")
        case "calendar-refresh":
            CalendarService.shared.refresh()
        case "clear-activities":
            for id in ["media", "timers", "claude", "notes", "revenue"] {
                ActivityCenter.shared.setOngoing(nil, for: id)
            }
        default:
            if command.hasPrefix("open:") {
                ScreenManager.shared.debugOpen(moduleID: String(command.dropFirst("open:".count)))
            } else if command.hasPrefix("rebuild:") {
                let count = Int(command.dropFirst("rebuild:".count)) ?? 1
                for _ in 0..<count {
                    ScreenManager.shared.debugForceRebuild()
                }
            } else if command.hasPrefix("status:") {
                let path = String(command.dropFirst("status:".count))
                let lines = [
                    "screens: \(ScreenManager.shared.debugSummary)",
                    "activity: \(ActivityCenter.shared.current?.moduleID ?? "-")",
                    "clipboard access: \(ClipboardService.shared.access)",
                    String(format: "pointer events: %.1f/s", ScreenManager.shared.debugPointerRate()),
                ]
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
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

        do {
            let report = try await WeatherService.shared.forecast(latitude: 52.52, longitude: 13.41, place: "Berlin (test)")
            lines.append("weather: ok \(report.current.temperature)\(report.temperatureUnit) code \(report.current.code), \(report.hours.count) hours, \(report.days.count) days, tz \(report.timeZone)")
        } catch {
            lines.append("weather: failed \(error.localizedDescription)")
        }
        let weather = WeatherService.shared
        lines.append("weather state: status=\(weather.status) locationDenied=\(weather.locationDenied) hasReport=\(weather.report != nil) manualPlace=\(weather.manualPlace != nil)")
        lines.append("location: \(weather.location.statusDescription)")

        // Phase 5
        if #available(macOS 15.4, *) {
            lines.append("pasteboard accessBehavior raw=\(NSPasteboard.general.accessBehavior.rawValue) → brim access \(ClipboardService.shared.access)")
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
        let oldReport = crashFolder.appendingPathComponent("Brim-2026-01-01-000000.ips")
        let newReport = crashFolder.appendingPathComponent("Brim-2026-09-16-120000.ips")
        let otherApp = crashFolder.appendingPathComponent("Safari-2026-09-16-120500.ips")
        for file in [oldReport, newReport, otherApp] {
            try? "{}".write(to: file, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.modificationDate: sessionStart.addingTimeInterval(-3600)], ofItemAtPath: oldReport.path)
        let found = Diagnostics.crashReport(markerURL: markerFile, reportsFolder: crashFolder)
        try? FileManager.default.removeItem(at: markerFile)
        let noMarker = Diagnostics.crashReport(markerURL: markerFile, reportsFolder: crashFolder)
        try? FileManager.default.removeItem(at: crashFolder)
        lines.append("crash detection: found=\(found?.lastPathComponent ?? "nil") (expect Brim-2026-09-16-120000.ips) withoutMarker=\(noMarker?.lastPathComponent ?? "nil") (expect nil)")
        lines.append("diagnostics: sharing=\(Diagnostics.shared.isSharingEnabled) lastCrash=\(Diagnostics.shared.lastCrashReport?.lastPathComponent ?? "none") version=\(Diagnostics.versionString)")
        lines.append("location authorized=\(WeatherService.shared.location.isAuthorized)")

        // Phase 3
        lines += await RevenueService.selfTest()
        lines += await AnalyticsService.selfTest()
        let account = "selftest.\(UUID().uuidString)"
        let saved = KeychainStore.save("value-123", for: account)
        let readBack = KeychainStore.read(account)
        KeychainStore.delete(account)
        lines.append("keychain: saved=\(saved) readBack=\(readBack == "value-123") deleted=\(KeychainStore.read(account) == nil)")

        let reportFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let settings = reportFolder.appendingPathComponent("claude-settings-test.json")
        let original = #"{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo existing"}]}]}}"#
        try? FileManager.default.removeItem(at: settings)
        try? FileManager.default.removeItem(at: settings.appendingPathExtension("brim-backup"))
        try? original.write(to: settings, atomically: true, encoding: .utf8)
        do {
            try ClaudeHookInstaller.install(at: settings)
            try ClaudeHookInstaller.install(at: settings)
            let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? [:]
            let hooks = installed["hooks"] as? [String: Any] ?? [:]
            let preToolGroups = (hooks["PreToolUse"] as? [[String: Any]])?.count ?? 0
            lines.append("hook install: detected=\(ClaudeHookInstaller.isInstalled(at: settings)) events=\(hooks.keys.sorted()) preToolUseGroups=\(preToolGroups) keptModel=\(installed["model"] as? String ?? "-") backup=\(FileManager.default.fileExists(atPath: settings.appendingPathExtension("brim-backup").path))")
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

        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func snapshot(to directory: String) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = SnapshotActions()

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
        // Sample data, so snapshots never show your own clipboard, notes or media.
        MediaService.shared.withSample {
        CalendarService.shared.withSample {
        ClipboardService.shared.withSample {
        NotesService.shared.withSample {
        ShelfService.shared.withSample {
        WeatherService.shared.withSample {
        StatsService.shared.withSample {
        RevenueService.shared.withSample {
        AnalyticsService.shared.withSample {
        ClaudeUsageService.shared.withSample {
        ClaudeLiveService.shared.withSample {
            for module in ModuleRegistry.all {
                render("4-open-\(module.id)") {
                    $0.phase = .open
                    $0.selectedModuleID = module.id
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
        render("5-open-pinned") {
            $0.phase = .open
            $0.isPinned = true
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
        NotesService.shared.start()
        center.post(LiveActivity(moduleID: "revenue", symbol: "dollarsign.circle.fill",
                                 content: .text("+$49"), tint: Theme.positive))
        render("3-activity") { _ in }
    }
}

@MainActor
private final class SnapshotActions: NotchActions {
    func tapped() {}
    func togglePin() {}
    func select(moduleID: String) {}
}
#endif
