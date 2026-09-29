import AppKit
import SwiftUI
import Observation

/// What the right-hand ear shows.
enum ActivityContent: Equatable {
    case text(String)
    /// Counts down to a date; SwiftUI updates the text by itself.
    case countdown(until: Date)
    /// Counts up from a date.
    case stopwatch(since: Date)
    /// Animated equalizer bars.
    case playing
    /// A short bar, 0...1 (volume).
    case level(Double)
    /// Lines that take turns, rolling like a ticker.
    case ticker([String])
    /// Small bars for the system HUD.
    case gauges([Gauge])
}

/// A ring drawn around the left-hand icon.
enum ActivityProgress: Equatable {
    /// Fills from `start` to `end` by itself (a running timer). Core Animation
    /// runs it, so Xotch does no work while it fills.
    case timed(start: Date, end: Date)
    case fraction(Double)
}

/// Something shown beside the notch while it's closed.
struct LiveActivity: Identifiable, Equatable {
    var id = UUID()
    let moduleID: String
    var symbol: String
    var content: ActivityContent
    var tint: Color
    /// Shown instead of the symbol, e.g. album art.
    var image: NSImage?
    var earWidth: CGFloat = Layout.earWidth
    /// How long a banner stays. Ongoing activities ignore it.
    var duration: Duration = .seconds(4)
    var progress: ActivityProgress?
    /// A soft beat behind the icon: something is working or waiting.
    var pulse: Pulse?

    enum Pulse: Equatable {
        case calm, urgent
    }

    static func == (lhs: LiveActivity, rhs: LiveActivity) -> Bool {
        lhs.id == rhs.id && lhs.moduleID == rhs.moduleID && lhs.symbol == rhs.symbol
            && lhs.content == rhs.content && lhs.tint == rhs.tint
            && lhs.image === rhs.image && lhs.earWidth == rhs.earWidth
            && lhs.progress == rhs.progress && lhs.pulse == rhs.pulse
    }
}

/// How Xotch's mascot feels, from what's going on.
enum MascotMood: String, CaseIterable {
    case idle, working, celebrating, sleeping
}

/// Three kinds of activity:
/// - a HUD, shown straight away while you adjust something (volume)
/// - banners, shown one at a time for a few seconds ("Saved", "Copied")
/// - ongoing activities, one per module, shown while no banner is up
///   (a running timer, a screen recording, music playing). The rest wait their turn.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Which ongoing activity wins when several are live.
    private static let priority = ["capture", "claude", "timers", "downloads", "media", "notes", "hud"]
    /// Ongoing activities that count as "working" for the mascot.
    private static let busyModules: Set<String> = ["capture", "claude", "timers", "downloads"]
    private static let sleepAfter: Duration = .seconds(10 * 60)

    private(set) var hud: LiveActivity?
    private(set) var banner: LiveActivity?
    private(set) var ongoing: [String: LiveActivity] = [:]
    /// Goes up by one for each celebration; views watch it to play one.
    private(set) var celebrations = 0
    private(set) var isCelebrating = false
    private(set) var isDrowsy = false
    @ObservationIgnored private var queue: [LiveActivity] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?
    @ObservationIgnored private var drowsyTask: Task<Void, Never>?
    @ObservationIgnored private var demoIndex = 0

    init() {
        noteActivity()
    }

    var current: LiveActivity? {
        if let hud { return hud }
        if let banner { return banner }
        return orderedOngoing.first
    }

    /// Live things not shown right now.
    var waitingCount: Int {
        // The system HUD is always there and always last, so it never counts as
        // something waiting.
        let live = ongoing.values.filter { $0.moduleID != GaugesHUD.moduleID }.count
            + queue.count + (banner == nil ? 0 : 1) + (hud == nil ? 0 : 1)
        return max(0, live - 1)
    }

    private var orderedOngoing: [LiveActivity] {
        ongoing.values.sorted { lhs, rhs in
            let left = Self.priority.firstIndex(of: lhs.moduleID) ?? Self.priority.count
            let right = Self.priority.firstIndex(of: rhs.moduleID) ?? Self.priority.count
            return left == right ? lhs.moduleID < rhs.moduleID : left < right
        }
    }

    var mood: MascotMood {
        if isCelebrating { return .celebrating }
        let busy = ongoing.values.contains { activity in
            guard Self.busyModules.contains(activity.moduleID) else { return false }
            // A paused timer isn't work.
            if case .text = activity.content, activity.moduleID == "timers" { return false }
            return true
        }
        if busy { return .working }
        return isDrowsy ? .sleeping : .idle
    }

    func post(_ activity: LiveActivity) {
        queue.append(activity)
        noteActivity()
        if banner == nil {
            advance()
        }
    }

    /// Shows something at once, replacing any HUD already up, and hides it
    /// shortly after the last update.
    func showHUD(_ activity: LiveActivity, for duration: Duration = .milliseconds(1300)) {
        var activity = activity
        if let hud, hud.moduleID == activity.moduleID {
            activity.id = hud.id
        }
        if hud == nil {
            withAnimation(Motion.activity) { hud = activity }
        } else {
            hud = activity
        }
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.activity) { self?.hud = nil }
        }
    }

    /// Sets or clears a module's ongoing activity. Keeps the same id while the
    /// module stays live, so updates don't replay the entrance animation.
    func setOngoing(_ activity: LiveActivity?, for moduleID: String) {
        guard var activity else {
            if ongoing[moduleID] != nil {
                withAnimation(Motion.activity) { ongoing[moduleID] = nil }
                noteActivity()
            }
            return
        }
        if let existing = ongoing[moduleID] {
            activity.id = existing.id
            if existing != activity {
                withAnimation(Motion.activity) { ongoing[moduleID] = activity }
            }
        } else {
            withAnimation(Motion.activity) { ongoing[moduleID] = activity }
            noteActivity()
        }
    }

    /// Confetti and a haptic, e.g. for a finished focus session.
    func celebrate() {
        noteActivity()
        celebrations += 1
        withAnimation(Motion.activity) { isCelebrating = true }
        Haptics.celebrate()
        RetroSound.play(.celebrate)
        celebrationTask?.cancel()
        celebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.activity) { self?.isCelebrating = false }
        }
    }

    /// Something happened: the mascot wakes up, and dozes off after a quiet while.
    private func noteActivity() {
        if isDrowsy {
            withAnimation(Motion.activity) { isDrowsy = false }
        }
        drowsyTask?.cancel()
        drowsyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sleepAfter)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.activity) { self.isDrowsy = true }
        }
    }

    private func advance() {
        guard !queue.isEmpty else {
            withAnimation(Motion.activity) { banner = nil }
            return
        }
        let next = queue.removeFirst()
        withAnimation(Motion.activity) { banner = next }
        Haptics.tick()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: next.duration)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Sample banners for trying the shell.
    func postDemo() {
        let samples = [
            LiveActivity(moduleID: "timers", symbol: "checkmark.circle.fill", content: .text("Done"), tint: Theme.positive),
            LiveActivity(moduleID: "capture", symbol: "camera.viewfinder", content: .text("Saved"),
                         tint: CaptureService.tint, earWidth: 96),
            LiveActivity(moduleID: "shelf", symbol: "tray.full.fill", content: .text("3 files"), tint: .cyan),
            LiveActivity(moduleID: "clipboard", symbol: "doc.on.clipboard.fill", content: .text("Copied"), tint: Theme.accent),
        ]
        let sample = samples[demoIndex % samples.count]
        post(sample)
        if sample.moduleID == "timers" {
            celebrate()
        }
        demoIndex += 1
    }

    #if DEBUG
    func debugSet(celebrating: Bool? = nil, drowsy: Bool? = nil) {
        if let celebrating { isCelebrating = celebrating }
        if let drowsy { isDrowsy = drowsy }
    }

    /// Which ongoing activities are live, for `scripts/debug.sh status`.
    var debugOngoingIDs: String { ongoing.keys.sorted().joined(separator: ",") }

    /// Sets live activities aside (for snapshots) and returns them.
    func debugStash() -> [String: LiveActivity] {
        let saved = ongoing
        ongoing = [:]
        return saved
    }

    func debugRestore(_ saved: [String: LiveActivity]) {
        for (moduleID, activity) in saved where ongoing[moduleID] == nil {
            ongoing[moduleID] = activity
        }
    }
    #endif
}
