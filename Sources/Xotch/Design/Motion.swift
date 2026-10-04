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
    /// The ear's turn-taking, every few seconds: a short fade, because a
    /// spring keeps SwiftUI drawing every frame until it settles (measured:
    /// bursts of 11–37% CPU per turn).
    static var turn: Animation { .easeInOut(duration: 0.25) }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// With Reduce Motion on, springs become short fades.
    private static func pick(_ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : animation
    }
}

/// A quick spring "pop" when a value changes. Used instead of SF Symbol effects,
/// which load ~100 MB of symbol animation data while they run.
private struct PopOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var popped = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(popped ? 1.3 : 1)
            .onChange(of: value, initial: true) { _, _ in
                guard !Motion.reduceMotion else { return }
                withAnimation(.spring(duration: 0.18, bounce: 0.4)) { popped = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(180))
                    withAnimation(.spring(duration: 0.4, bounce: 0.45)) { popped = false }
                }
            }
    }
}

extension View {
    func popOnChange<Value: Equatable>(of value: Value) -> some View {
        modifier(PopOnChange(value: value))
    }

    /// Swaps an icon with a quick scale and fade when `value` changes.
    func swapTransition<Value: Hashable>(on value: Value) -> some View {
        id(value).transition(.scale(scale: 0.5).combined(with: .opacity))
    }
}
