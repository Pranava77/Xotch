import AppKit
import SwiftUI

/// The notch's background. Closed, it's always black so it blends into the
/// camera housing. Open, it follows the theme: a solid colour, or glass.
struct NotchSurface: View {
    let shape: NotchShape
    let isOpen: Bool
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.snapshotClearGlass) private var clearGlass

    var body: some View {
        let palette = Theme.palette
        let glass = isOpen && palette.material == .glass
        ZStack(alignment: .top) {
            if glass, !snapshotMode || clearGlass {
                if snapshotMode {
                    // The snapshot draws the blurred backdrop itself.
                    shape.fill(palette.surface.color.opacity(0.55))
                } else {
                    GlassBackground(shape: shape, tint: palette.surface.color)
                        .transition(.opacity)
                }
                if palette.isRetro {
                    RetroSheen(shape: shape)
                        .transition(.opacity)
                }
                // A short fade to black at the top, so the glass meets the menu
                // bar and the camera housing without a seam. Any longer and the
                // top of the panel stops looking like glass.
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else {
                shape
                    .fill(isOpen ? palette.surface.color : Theme.notch)
                    .transition(.opacity)
            }
        }
    }
}

/// Light through the top of a window: a soft sheen from the top edge, and a
/// faint streak of reflected light across the glass. Static, so it costs nothing.
private struct RetroSheen: View {
    let shape: NotchShape

    var body: some View {
        ZStack {
            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04), .clear],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
            LinearGradient(colors: [.clear, .white.opacity(0.07), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

private struct GlassBackground: View {
    let shape: NotchShape
    let tint: Color

    var body: some View {
        if #available(macOS 26.0, *), !GlassFallback.forced {
            Color.clear
                .glassEffect(.regular.tint(tint.opacity(0.25)), in: shape)
        } else {
            VisualEffectBlur()
                .clipShape(shape)
                .overlay(shape.fill(tint.opacity(0.55)))
        }
    }
}

enum GlassFallback {
    /// `defaults write com.pranava.xotch forceBlurFallback -bool YES` shows the
    /// macOS 14–15 look on newer systems, for testing.
    static var forced: Bool { UserDefaults.standard.bool(forKey: "forceBlurFallback") }
}

/// Blur of whatever is behind the window (macOS 14 and 15).
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
