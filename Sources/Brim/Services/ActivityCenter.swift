import SwiftUI
import Observation

/// Something worth showing beside the notch for a few seconds.
struct LiveActivity: Identifiable, Equatable {
    let id = UUID()
    let moduleID: String
    let symbol: String
    let text: String
    let tint: Color
    var duration: Duration = .seconds(4)
}

/// Shows live activities one at a time, in the order they arrive.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var current: LiveActivity?
    @ObservationIgnored private var queue: [LiveActivity] = []
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var demoIndex = 0

    func post(_ activity: LiveActivity) {
        queue.append(activity)
        if current == nil {
            advance()
        }
    }

    private func advance() {
        guard !queue.isEmpty else {
            withAnimation(Motion.activity) { current = nil }
            return
        }
        let next = queue.removeFirst()
        withAnimation(Motion.activity) { current = next }
        Haptics.tick()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: next.duration)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Sample activities for trying the shell before real modules exist.
    func postDemo() {
        let samples = [
            LiveActivity(moduleID: "timers", symbol: "timer", text: "24:59", tint: Theme.accent),
            LiveActivity(moduleID: "revenue", symbol: "dollarsign.circle.fill", text: "+$49", tint: .green),
            LiveActivity(moduleID: "media", symbol: "music.note", text: "Playing", tint: .pink),
            LiveActivity(moduleID: "shelf", symbol: "tray.full.fill", text: "3 files", tint: .cyan),
        ]
        post(samples[demoIndex % samples.count])
        demoIndex += 1
    }
}
