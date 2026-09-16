import AppKit

/// Trackpad feedback. Only felt on Force Touch trackpads.
@MainActor
enum Haptics {
    static func tick() { perform(.alignment) }
    static func open() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard AppSettings.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
