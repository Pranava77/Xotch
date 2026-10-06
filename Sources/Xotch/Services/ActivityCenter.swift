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
    /// The microphone's level while dictating, as a moving waveform.
    case listening
    /// A short bar, 0...1 (volume).
    case level(Double)
    /// Lines that take turns, rolling like a ticker.
    case ticker([String])
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
    /// The longest text the ear shows before it's cut short; the ear
    /// otherwise fits the content exactly (see `EarMetrics`).
    var maxContentWidth: CGFloat = 150
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
            && lhs.image === rhs.image && lhs.maxContentWidth == rhs.maxContentWidth
            && lhs.progress == rhs.progress && lhs.pulse == rhs.pulse
    }
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
    private static let priority = ["dictation", "capture", "claude", "timers", "downloads", "media", "notes"]

    private(set) var hud: LiveActivity?
    private(set) var banner: LiveActivity?
    private(set) var ongoing: [String: LiveActivity] = [:]
    /// What sits at the outer edge of the left ear: Adiyogi, the mascot, or nothing.
    private(set) var companion: EarCompanion = .none
    var showsCompanion: Bool { companion != .none }
    /// Goes up by one for each celebration; views watch it to play one.
    private(set) var celebrations = 0
    /// Which ongoing activity the ear shows while several are live. It moves
    /// on every few seconds, so music gets a turn while Claude works.
    private(set) var rotation = 0
    /// Goes up when a running clock in the ear gains or loses a digit, so the
    /// ears fit it again (see `EarMetrics.clockTemplate`).
    private(set) var clockTick = 0
    @ObservationIgnored private var queue: [LiveActivity] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var rotationTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var demoIndex = 0

    /// How long each live activity stays in the ear before the next.
    private static let turn: Duration = .seconds(6)

    var current: LiveActivity? {
        if let hud { return hud }
        if let banner { return banner }
        return shownOngoing
    }

    /// Ongoing activities, most important first.
    var liveOngoing: [LiveActivity] { orderedOngoing }

    /// True while the ear takes turns between several live activities.
    var isRotating: Bool {
        hud == nil && banner == nil && sticky == nil && ongoing.count > 1
    }

    /// Where the shown activity sits among the live ones, for the dots
    /// beside the ear. Nil while only one is live, or a banner is up.
    var livePosition: (index: Int, count: Int)? {
        guard hud == nil, banner == nil else { return nil }
        let list = orderedOngoing
        guard list.count > 1, let shown = shownOngoing,
              let index = list.firstIndex(where: { $0.moduleID == shown.moduleID }) else { return nil }
        return (index, list.count)
    }

    /// Never rotated away: a recording, so a click on the ear still stops it,
    /// and anything urgent, like Claude waiting for an answer.
    private var sticky: LiveActivity? {
        orderedOngoing.first { ["capture", "dictation"].contains($0.moduleID) || $0.pulse == .urgent }
    }

    private var shownOngoing: LiveActivity? {
        if let sticky { return sticky }
        let list = orderedOngoing
        guard !list.isEmpty else { return nil }
        return list[rotation % list.count]
    }

    /// Live things not shown right now.
    var waitingCount: Int {
        let live = ongoing.count + queue.count + (banner == nil ? 0 : 1) + (hud == nil ? 0 : 1)
        return max(0, live - 1)
    }

    private var orderedOngoing: [LiveActivity] {
        ongoing.values.sorted { lhs, rhs in
            let left = Self.priority.firstIndex(of: lhs.moduleID) ?? Self.priority.count
            let right = Self.priority.firstIndex(of: rhs.moduleID) ?? Self.priority.count
            return left == right ? lhs.moduleID < rhs.moduleID : left < right
        }
    }

    func post(_ activity: LiveActivity) {
        queue.append(activity)
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
        updateRotation()
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.activity) { self?.hud = nil }
            self?.updateRotation()
        }
    }

    /// Sets or clears a module's ongoing activity. Keeps the same id while the
    /// module stays live, so updates don't replay the entrance animation.
    func setOngoing(_ activity: LiveActivity?, for moduleID: String) {
        defer {
            updateRotation()
            scheduleClockRefit()
        }
        guard var activity else {
            if ongoing[moduleID] != nil {
                withAnimation(Motion.activity) { ongoing[moduleID] = nil }
            }
            return
        }
        if let existing = ongoing[moduleID] {
            activity.id = existing.id
            if existing != activity {
                withAnimation(Motion.activity) { ongoing[moduleID] = activity }
            }
        } else {
            withAnimation(Motion.activity) {
                ongoing[moduleID] = activity
                // Something new starts its turn straight away.
                if let index = orderedOngoing.firstIndex(where: { $0.moduleID == moduleID }) {
                    rotation = index
                }
            }
            restartRotation()
        }
    }

    /// The next live activity, now; the click on the right ear.
    func showNext() {
        guard isRotating else { return }
        withAnimation(Motion.turn) { rotation += 1 }
        Haptics.tick()
        restartRotation()
    }

    /// Runs the turn-taking while it's needed, and only then.
    private func updateRotation() {
        if isRotating {
            guard rotationTask == nil else { return }
            rotationTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.turn)
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(Motion.turn) { self.rotation += 1 }
                }
            }
        } else {
            rotationTask?.cancel()
            rotationTask = nil
        }
    }

    /// Wakes once when the next running clock changes its number of digits,
    /// a second early, as `EarMetrics` looks a second ahead.
    private func scheduleClockRefit() {
        clockTask?.cancel()
        clockTask = nil
        let now = Date()
        let steps = EarMetrics.clockSteps.map { $0 - 1 }
        let next = ongoing.values.compactMap { activity -> Date? in
            switch activity.content {
            case .countdown(let until): steps.map { until.addingTimeInterval(-$0) }.filter { $0 > now }.min()
            case .stopwatch(let since): steps.map { since.addingTimeInterval($0) }.filter { $0 > now }.min()
            default: nil
            }
        }.min()
        guard let next else { return }
        clockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05))
            guard let self, !Task.isCancelled else { return }
            withAnimation(Motion.activity) { self.clockTick += 1 }
            self.scheduleClockRefit()
        }
    }

    /// A full turn for whatever is showing now.
    private func restartRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        updateRotation()
    }

    /// Called at launch and whenever a setting changes.
    func settingsChanged() {
        let next = AppSettings.earCompanion
        #if DEBUG
        if isStashed {
            stashedCompanion = next
            return
        }
        #endif
        guard next != companion else { return }
        withAnimation(Motion.activity) { companion = next }
    }

    /// Confetti and a haptic, e.g. for a finished focus session.
    func celebrate() {
        celebrations += 1
        Haptics.celebrate()
        RetroSound.play(.celebrate)
    }

    private func advance() {
        defer { updateRotation() }
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
                         tint: CaptureService.tint),
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
    /// Which ongoing activities are live, for `scripts/debug.sh status`.
    var debugOngoingIDs: String { ongoing.keys.sorted().joined(separator: ",") }

    @ObservationIgnored private var stashedCompanion: EarCompanion = .none
    @ObservationIgnored private var isStashed = false

    /// Sets live activities (and the ear companion) aside for snapshots, and returns them.
    func debugStash() -> [String: LiveActivity] {
        let saved = ongoing
        ongoing = [:]
        updateRotation()
        stashedCompanion = companion
        companion = .none
        isStashed = true
        return saved
    }

    func debugClearHUD() {
        hudTask?.cancel()
        hud = nil
        updateRotation()
    }

    var debugRotation: String {
        "rotation=\(rotation) rotating=\(isRotating) sticky=\(sticky?.moduleID ?? "-") shown=\(current?.moduleID ?? "-")"
    }

    /// Snapshots set bars of their own; this goes around the stash.
    func debugShowCompanion(_ shown: EarCompanion) {
        companion = shown
    }

    func debugRestore(_ saved: [String: LiveActivity]) {
        for (moduleID, activity) in saved where ongoing[moduleID] == nil {
            ongoing[moduleID] = activity
        }
        isStashed = false
        companion = stashedCompanion
        updateRotation()
    }
    #endif
}
