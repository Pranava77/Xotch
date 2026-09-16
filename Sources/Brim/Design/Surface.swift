import AppKit
import SwiftUI

/// The notch's background. Closed, it's always black so it blends into the
/// camera housing. Open, it follows the theme: a solid colour, or glass.
struct NotchSurface: View {
    let shape: NotchShape
    let isOpen: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        let palette = Theme.palette
        ZStack(alignment: .top) {
            if isOpen, palette.material == .glass, !snapshotMode {
                GlassBackground(shape: shape, tint: palette.surface.color)
                    .transition(.opacity)
                // Fade to black at the top, so the glass meets the menu bar and
                // the camera housing without a seam.
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
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

private struct GlassBackground: View {
    let shape: NotchShape
    let tint: Color

    var body: some View {
        if #available(macOS 26.0, *), !GlassFallback.forced {
            Color.clear
                .glassEffect(.regular.tint(tint.opacity(0.6)), in: shape)
        } else {
            VisualEffectBlur()
                .clipShape(shape)
                .overlay(shape.fill(tint.opacity(0.55)))
        }
    }
}

enum GlassFallback {
    /// `defaults write com.pranava.brim forceBlurFallback -bool YES` shows the
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
