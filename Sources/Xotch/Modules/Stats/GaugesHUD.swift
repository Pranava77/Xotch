import AppKit
import SwiftUI

// A heads-up display in the notch's right ear: CPU, memory, network and battery
// as small bars, shown while the notch is closed and nothing else is live.
//
// Shape over text: a bar is read faster than a number. Positions never move, and
// only a warning colour draws the eye.

/// One reading in the HUD.
struct Gauge: Equatable, Sendable, Identifiable {
    enum Level: Equatable, Sendable {
        case normal, warn, alert
    }

    let id: String
    let label: String
    /// 0...1, how full the bar is.
    let value: Double
    let level: Level
    /// For VoiceOver, e.g. "23 percent" or "1.2 MB/s".
    let spoken: String
}

/// Which gauges the user has chosen.
struct HUDSelection: Equatable, Sendable {
    var cpu = true
    var memory = true
    var network = true
    var battery = true
}

@MainActor
final class GaugesHUD {
    static let shared = GaugesHUD()

    private var sampling: Task<Void, Never>?
    private var suspendedForFullScreen = false
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []

    // MARK: - Turning it on and off

    /// Called at launch and whenever a setting changes; cheap when nothing did.
    func settingsChanged() {
        installObserversOnce()
        if shouldRun {
            startSampling()
            // Settings changes arrive synchronously, sometimes in the middle of a
            // SwiftUI update, and changing what the notch shows there aborts the
            // app. Show the new bars on the next turn of the run loop instead.
            Task { @MainActor [weak self] in self?.publish() }
        } else {
            stopSampling()
        }
    }

    /// True while every notch is hidden behind a full-screen app.
    func setFullScreen(_ hidden: Bool) {
        guard hidden != suspendedForFullScreen else { return }
        suspendedForFullScreen = hidden
        settingsChanged()
    }

    private var shouldRun: Bool {
        AppSettings.hudEnabled && !suspendedForFullScreen && !screensAsleep
    }

    /// Xotch reads the stats only while the HUD is on, the notch can be seen,
    /// and the displays are awake. `StatsService` shares one 2-second timer with
    /// the Stats module, so opening Stats costs nothing extra.
    private func startSampling() {
        guard sampling == nil else { return }
        StatsService.shared.onSample = { [weak self] in self?.publish() }
        sampling = Task { await StatsService.shared.whileVisible() }
    }

    private func stopSampling() {
        sampling?.cancel()
        sampling = nil
        StatsService.shared.onSample = nil
        ActivityCenter.shared.setGauges(nil)
    }

    private func installObserversOnce() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.settingsChanged()
                }
            })
        }
    }

    private func publish() {
        guard shouldRun, let snapshot = StatsService.shared.snapshot else { return }
        ActivityCenter.shared.setGauges(Self.gauges(from: snapshot, selection: AppSettings.hudSelection))
    }

    // MARK: - Readings

    /// The gauges for a snapshot. Pure, so the self-test can check the thresholds.
    nonisolated static func gauges(from snapshot: StatsSnapshot, selection: HUDSelection) -> [Gauge] {
        var result: [Gauge] = []
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) percent" }

        if selection.cpu {
            let value = clamp(snapshot.cpu)
            result.append(Gauge(id: "cpu", label: "CPU", value: value,
                                level: value >= 0.9 ? .alert : value >= 0.8 ? .warn : .normal,
                                spoken: percent(value)))
        }
        if selection.memory, snapshot.memoryTotal > 0 {
            let value = clamp(snapshot.memoryUsed / snapshot.memoryTotal)
            result.append(Gauge(id: "memory", label: "Memory", value: value,
                                level: value >= 0.93 ? .alert : value >= 0.85 ? .warn : .normal,
                                spoken: percent(value)))
        }
        if selection.network {
            let bytesPerSecond = max(0, snapshot.download + snapshot.upload)
            // Log scale: 1 KB/s reads as a sliver, 10 MB/s fills the bar.
            let value = clamp(log10(1 + bytesPerSecond / 1000) / 4)
            result.append(Gauge(id: "network", label: "Network", value: value, level: .normal,
                                spoken: ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond),
                                                                  countStyle: .decimal) + " per second"))
        }
        if selection.battery, let battery = snapshot.battery {
            let value = clamp(Double(battery.percent) / 100)
            // Low only matters when you aren't plugged in.
            let low = !battery.onPower && !battery.isCharging
            result.append(Gauge(id: "battery", label: "Battery", value: value,
                                level: low && value <= 0.10 ? .alert : low && value <= 0.20 ? .warn : .normal,
                                spoken: percent(value) + (battery.isCharging ? ", charging" : "")))
        }
        return result
    }

    nonisolated private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

extension AppSettings {
    static var hudEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.hudEnabled)
    }

    static var hudSelection: HUDSelection {
        let defaults = UserDefaults.standard
        return HUDSelection(cpu: defaults.bool(forKey: SettingsKey.hudCPU),
                            memory: defaults.bool(forKey: SettingsKey.hudMemory),
                            network: defaults.bool(forKey: SettingsKey.hudNetwork),
                            battery: defaults.bool(forKey: SettingsKey.hudBattery))
    }
}
