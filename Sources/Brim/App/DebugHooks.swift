#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: drive the notch from the command line.
///
///     scripts/debug.sh open | close | activity | snapshot <folder>
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
        default:
            if command.hasPrefix("snapshot:") {
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
