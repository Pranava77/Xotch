import AppKit
import SwiftUI

/// Named spring presets. Every state change in the notch uses one of these,
/// so the whole app moves with one personality.
@MainActor
enum Motion {
    static var open: Animation { pick(.spring(duration: 0.42, bounce: 0.28)) }
    static var close: Animation { pick(.spring(duration: 0.34, bounce: 0.1)) }
    static var peek: Animation { pick(.spring(duration: 0.3, bounce: 0.4)) }
    static var activity: Animation { pick(.spring(duration: 0.5, bounce: 0.32)) }
    static var switchModule: Animation { pick(.spring(duration: 0.38, bounce: 0.18)) }
    static var press: Animation { pick(.spring(duration: 0.2, bounce: 0.4)) }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// With Reduce Motion on, springs become short fades.
    private static func pick(_ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : animation
    }
}
