import AppKit
import SwiftUI

/// The notch's background. Closed, it's black so it blends into the camera
/// housing. Open, it's macOS's dark HUD material, like Control Center.
struct NotchSurface: View {
    let shape: NotchShape
    let isOpen: Bool
    @Environment(\.snapshotMode) private var snapshotMode
    @Environment(\.snapshotClearGlass) private var clearGlass

    var body: some View {
        ZStack(alignment: .top) {
            if isOpen {
                if snapshotMode {
                    // Snapshots can't draw the material: over the blurred backdrop
                    // some draw themselves, a dark fill stands in.
                    shape.fill(Color(white: 0.08).opacity(clearGlass ? 0.72 : 1))
                } else {
                    DarkMaterial()
                        .clipShape(shape)
                        .overlay(shape.fill(.black.opacity(0.18)))
                }
                // A short fade to black at the top, so the material meets the
                // menu bar and the camera housing without a seam.
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            } else {
                shape.fill(Theme.notch)
            }
        }
        .transition(.opacity)
    }
}

/// Blur of whatever is behind the window, in macOS's dark appearance whatever
/// the system is set to.
private struct DarkMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

enum GlassFallback {
    /// `defaults write com.pranava.xotch forceBlurFallback -bool YES` draws
    /// controls the macOS 14–15 way on newer systems, for testing.
    static var forced: Bool { UserDefaults.standard.bool(forKey: "forceBlurFallback") }
}
