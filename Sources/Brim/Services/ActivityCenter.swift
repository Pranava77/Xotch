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

    static func == (lhs: LiveActivity, rhs: LiveActivity) -> Bool {
        lhs.id == rhs.id && lhs.moduleID == rhs.moduleID && lhs.symbol == rhs.symbol
            && lhs.content == rhs.content && lhs.tint == rhs.tint
            && lhs.image === rhs.image && lhs.earWidth == rhs.earWidth
    }
}

/// Two kinds of activity:
/// - banners, shown one at a time for a few seconds ("+$49", "Copied")
/// - ongoing activities, one per module, shown while no banner is up
///   (a running timer, music playing)
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Which ongoing activity wins when several are live.
    private static let priority = ["claude", "timers", "media", "notes", "revenue"]

    private(set) var banner: LiveActivity?
    private(set) var ongoing: [String: LiveActivity] = [:]
    @ObservationIgnored private var queue: [LiveActivity] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var demoIndex = 0

    var current: LiveActivity? {
        if let banner { return banner }
        for moduleID in Self.priority {
            if let activity = ongoing[moduleID] { return activity }
        }
        return ongoing.values.first
    }

    func post(_ activity: LiveActivity) {
        queue.append(activity)
        if banner == nil {
            advance()
        }
    }

    /// Sets or clears a module's ongoing activity. Keeps the same id while the
    /// module stays live, so updates don't replay the entrance animation.
    func setOngoing(_ activity: LiveActivity?, for moduleID: String) {
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
            withAnimation(Motion.activity) { ongoing[moduleID] = activity }
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
            LiveActivity(moduleID: "revenue", symbol: "dollarsign.circle.fill", content: .text("+$49"), tint: Theme.positive),
            LiveActivity(moduleID: "shelf", symbol: "tray.full.fill", content: .text("3 files"), tint: .cyan),
            LiveActivity(moduleID: "clipboard", symbol: "doc.on.clipboard.fill", content: .text("Copied"), tint: Theme.accent),
        ]
        post(samples[demoIndex % samples.count])
        demoIndex += 1
    }
}
