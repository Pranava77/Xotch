#if DEBUG
import SwiftUI

/// Where controls actually sit in the notch, so a self-test can click them
/// rather than guess at coordinates that drift with every layout change.
///
/// Frames are in SwiftUI's global space — the window's content view, measured
/// from the top left. AppKit counts from the bottom, so a click converts with
/// `contentHeight - midY`.
enum DebugFrames {
    nonisolated(unsafe) private static var frames: [String: CGRect] = [:]

    static func record(_ name: String, _ frame: CGRect) { frames[name] = frame }
    static func frame(_ name: String) -> CGRect? { frames[name] }
    static var known: [String] { frames.keys.sorted() }
}

extension View {
    /// Remembers where this view is, for `debug.sh click <name>` and the UI
    /// self-test. Does nothing in a release build.
    func debugFrame(_ name: String) -> some View {
        modifier(DebugFrameRecorder(name: name))
    }
}

private struct DebugFrameRecorder: ViewModifier {
    let name: String
    /// Snapshots and marketing shots build the whole shell inside an
    /// `ImageRenderer`, off screen and in its own coordinate space. Recording
    /// those would point every later click at a window that isn't there.
    @Environment(\.snapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear { record(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, new in record(new) }
            }
        )
    }

    private func record(_ frame: CGRect) {
        guard !snapshotMode else { return }
        DebugFrames.record(name, frame)
    }
}
#endif
