import Foundation
import SwiftUI

/// Download progress beside the notch. Safari, Chrome and other apps publish
/// an NSProgress for files they download; Brim listens for ones in the
/// Downloads folder. Off by default, because macOS may ask for access to it.
@MainActor
final class DownloadsService {
    static let shared = DownloadsService()

    private final class Tracked {
        let progress: Progress
        var observation: NSKeyValueObservation?
        let started = Date()
        init(progress: Progress) { self.progress = progress }
    }

    private var token: Any?
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var updateScheduled = false

    func settingsChanged() {
        if UserDefaults.standard.bool(forKey: SettingsKey.downloadProgress),
           let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            start(watching: folder)
        } else {
            stop()
        }
    }

    private func start(watching folder: URL) {
        guard token == nil else { return }
        token = Progress.addSubscriber(forFileURL: folder) { @Sendable [weak self] progress in
            let id = ObjectIdentifier(progress)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.began(progress) }
            }
            return { @Sendable in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.ended(id) }
                }
            }
        }
    }

    private func stop() {
        if let token {
            Progress.removeSubscriber(token)
        }
        token = nil
        tracked.removeAll()
        ActivityCenter.shared.setOngoing(nil, for: "downloads")
    }

    private func began(_ progress: Progress) {
        let item = Tracked(progress: progress)
        // fractionCompleted changes many times a second; redraw at most twice a second.
        item.observation = progress.observe(\.fractionCompleted) { @Sendable [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            }
        }
        tracked[ObjectIdentifier(progress)] = item
        update()
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let item = tracked.removeValue(forKey: id) else { return }
        let finished = item.progress.fractionCompleted >= 0.999 && !item.progress.isCancelled
        update()
        if finished {
            ActivityCenter.shared.post(LiveActivity(moduleID: "downloads", symbol: "arrow.down.circle.fill",
                                                    content: .text("Done"), tint: Theme.accent,
                                                    earWidth: 90, duration: .seconds(3)))
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        // Show the newest download; the count says how many are going.
        guard let newest = tracked.values.max(by: { $0.started < $1.started }) else {
            ActivityCenter.shared.setOngoing(nil, for: "downloads")
            return
        }
        let fraction = newest.progress.fractionCompleted
        let known = newest.progress.totalUnitCount > 0 && !newest.progress.isIndeterminate
        let label = tracked.count > 1 ? "\(tracked.count) files" : (known ? "\(Int(fraction * 100))%" : "…")
        ActivityCenter.shared.setOngoing(
            LiveActivity(moduleID: "downloads", symbol: "arrow.down", content: .text(label),
                         tint: Theme.accent, earWidth: 90,
                         progress: .fraction(known ? fraction : 0)),
            for: "downloads"
        )
    }

    #if DEBUG
    /// Watches another folder, so the self-test can publish a fake download
    /// without touching ~/Downloads. Nil stops watching.
    func debugWatch(_ folder: URL?) {
        stop()
        if let folder {
            start(watching: folder)
        }
    }
    #endif
}
