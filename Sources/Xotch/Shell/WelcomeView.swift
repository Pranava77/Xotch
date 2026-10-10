import AppKit
import SwiftUI

/// The first thing Xotch shows, once: "hello" writing itself in the notch the
/// way a new Mac greets you, then three things to know.
/// It comes back from the menu bar's Welcome to Xotch.
struct WelcomeView: View {
    static let size = CGSize(width: 760, height: 320)

    let notchHeight: CGFloat
    @State private var showsSetup: Bool
    @State private var greeted = false
    @Environment(\.snapshotMode) private var snapshotMode

    /// `atSetup` skips the hello, for snapshots of the second page.
    init(notchHeight: CGFloat, atSetup: Bool = false) {
        self.notchHeight = notchHeight
        _showsSetup = State(initialValue: atSetup)
    }

    /// Snapshots can't wait for the first word, so they show it all.
    private var ready: Bool { greeted || snapshotMode }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            ZStack {
                if showsSetup {
                    setup
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                } else {
                    hello
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Theme.ink)
        .animation(Motion.switchModule, value: showsSetup)
        .task {
            // The button arrives once the word has written itself.
            try? await Task.sleep(for: .seconds(snapshotMode ? 0 : HelloLetteringView.writing + 0.3))
            withAnimation(Motion.activity) { greeted = true }
        }
    }

    // MARK: The hello

    private var hello: some View {
        VStack(spacing: 10) {
            HelloLettering()
                .frame(width: 420, height: 130)
            Text("Welcome to Xotch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .opacity(ready ? 1 : 0)
            Button("Continue") { showsSetup = true }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .opacity(ready ? 1 : 0)
                .padding(.top, 4)
                .debugFrame("welcome.continue")
        }
    }

    // MARK: Three things to know

    private var setup: some View {
        VStack(spacing: 14) {
            Text("Three things to know")
                .font(.system(size: 17, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                Step(symbol: "cursorarrow.motionlines", title: "Rest on the notch",
                     detail: "Hover to peek, and keep the pointer there to open it. Click to keep it open; Esc closes it.")
                Step(symbol: "sparkles", title: "Ask, and it acts",
                     detail: "Press ⌘⇧Space in any app. The AI changes things only after you click Allow.",
                     action: ("Set Up AI…", { SettingsWindow.show(.ai) }))
                if WhistleEngine.isSupported {
                    Step(symbol: "mic.fill", title: "Talk instead of typing",
                         detail: "Hold Fn and speak; the words appear where you're typing, transcribed on this Mac.",
                         action: ("Set Up Dictation…", { SettingsWindow.show(.dictation) }))
                } else {
                    Step(symbol: "command", title: "One shortcut for everything",
                         detail: "Press ⌘K in the open notch to start a timer, take a screenshot or add a to-do.")
                }
            }
            Button("Start Using Xotch") { ScreenManager.shared.finishWelcome() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .debugFrame("welcome.done")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

private struct Step: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(height: 22)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Hello, written out

/// "hello" written out by hand: one continuous pen line of even weight, the
/// way a new Mac greets you, in original lettering. The pen slows into tight
/// turns and speeds along straight runs, then the word rests, fades, and is
/// written again. Snapshots and Reduce Motion show it already written.
private struct HelloLettering: View {
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode || Motion.reduceMotion {
            GeometryReader { geo in
                let fit = HelloStroke.fit(in: geo.size)
                Path(HelloStroke.path(in: geo.size))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: fit.lineWidth, lineCap: .round, lineJoin: .round))
            }
        } else {
            HelloLayer()
        }
    }
}

/// The lettering: points a pen passes through, joined by a Catmull-Rom spline
/// so the line stays smooth. Laid out with y up and the baseline at 0, then
/// slanted forward.
enum HelloStroke {
    static let points: [CGPoint] = [
        (0, 26), (46, 58), (96, 128), (138, 214), (166, 292), (176, 340), (166, 368), (144, 370), (126, 340),
        (112, 270), (102, 190), (95, 110), (90, 48), (87, 0),
        (96, 66), (114, 114), (140, 144), (168, 148), (188, 128), (195, 94), (194, 52), (199, 18), (216, 2),
        (240, 10), (266, 36),
        (296, 66), (326, 96), (336, 126), (322, 148), (292, 148), (270, 124), (264, 82), (274, 38), (298, 10),
        (330, 4), (362, 22), (388, 58),
        (414, 130), (440, 212), (462, 290), (474, 342), (468, 370), (448, 376), (430, 350), (418, 290), (410, 214),
        (405, 136), (404, 64), (410, 18), (428, 0), (452, 10), (476, 46),
        (502, 124), (528, 208), (550, 288), (562, 342), (556, 370), (536, 376), (518, 350), (506, 290), (498, 214),
        (493, 136), (492, 64), (498, 18), (516, 0), (540, 10), (564, 44),
        (590, 92), (620, 128), (654, 144), (630, 148), (604, 128), (592, 90), (596, 44), (616, 10), (648, 0),
        (682, 14), (700, 52), (698, 98), (678, 132), (652, 146),
        (690, 146), (736, 134), (784, 140),
    ].map { CGPoint(x: $0.0 + $0.1 * 0.16, y: $0.1) }

    /// The pen's width, in the points' units.
    static let penWidth: CGFloat = 19

    /// How the lettering is scaled and placed to fit `size`, centred, with
    /// room for the pen's width; y is flipped for SwiftUI when `flipped`.
    static func fit(in size: CGSize, flipped: Bool = true) -> (transform: CGAffineTransform, lineWidth: CGFloat) {
        let box = spline(points).boundingBoxOfPath.insetBy(dx: -penWidth, dy: -penWidth)
        let scale = min(size.width / box.width, size.height / box.height)
        var transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        transform = transform.scaledBy(x: scale, y: flipped ? -scale : scale)
        transform = transform.translatedBy(x: -box.midX, y: -box.midY)
        return (transform, penWidth * scale)
    }

    static func path(in size: CGSize, flipped: Bool = true) -> CGPath {
        var transform = fit(in: size, flipped: flipped).transform
        return spline(points).copy(using: &transform) ?? spline(points)
    }

    /// A smooth curve through every point.
    static func spline(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    /// How far along the line (0…1) the pen is at each point, and when (0…1):
    /// each stretch takes its length plus a pause for how sharply it turns.
    static var pace: (progress: [Double], times: [Double]) {
        var lengths: [Double] = [], costs: [Double] = []
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            var turn = 0.0
            if i > 0 {
                let before = Double(atan2(a.y - points[i - 1].y, a.x - points[i - 1].x))
                let after = Double(atan2(b.y - a.y, b.x - a.x))
                turn = abs(remainder(after - before, 2 * Double.pi))
            }
            lengths.append(Double(length))
            costs.append(length + turn * 26)
        }
        let totalLength = lengths.reduce(0, +), totalCost = costs.reduce(0, +)
        var progress = [0.0], times = [0.0]
        for i in lengths.indices {
            progress.append(progress[i] + lengths[i] / totalLength)
            times.append(times[i] + costs[i] / totalCost)
        }
        return (progress, times)
    }
}

private struct HelloLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> HelloLetteringView { HelloLetteringView() }
    func updateNSView(_ view: HelloLetteringView, context: Context) {}
}

final class HelloLetteringView: NSView {
    /// How long the word takes to write, and how long it then rests.
    static let writing: CFTimeInterval = 3.0
    static let resting: CFTimeInterval = 2.4

    private let line = CAShapeLayer()
    private var task: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.fillColor = nil
        line.strokeColor = NSColor.white.cgColor
        line.lineCap = .round
        line.lineJoin = .round
        line.strokeEnd = 0
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = bounds
        // Layers are y up here, like the points.
        line.path = HelloStroke.path(in: bounds.size, flipped: false)
        line.lineWidth = HelloStroke.fit(in: bounds.size, flipped: false).lineWidth
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            task?.cancel()
            task = nil
            return
        }
        // Opening the notch can move the view into its window twice; writing
        // again from the start would show as a hiccup.
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.write()
                try? await Task.sleep(for: .seconds(Self.writing + Self.resting))
                guard !Task.isCancelled else { return }
                self.fadeOut()
                try? await Task.sleep(for: .seconds(0.7))
            }
        }
    }

    /// The pen writes the word at handwriting pace.
    private func write() {
        let pace = HelloStroke.pace
        let pen = CAKeyframeAnimation(keyPath: "strokeEnd")
        pen.values = pace.progress
        pen.keyTimes = pace.times.map { NSNumber(value: $0) }
        pen.calculationMode = .linear
        pen.duration = Self.writing
        // Straight off the mark, settling as the hand lifts off.
        pen.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0, 0.5, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.removeAllAnimations()
        line.opacity = 1
        line.strokeEnd = 1
        CATransaction.commit()
        line.add(pen, forKey: "write")
    }

    private func fadeOut() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        line.add(fade, forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.opacity = 0
        CATransaction.commit()
    }

    #if DEBUG
    /// For the self-test: one stroke that fits, paced from start to finish.
    static var debugLettering: Bool {
        let path = HelloStroke.path(in: CGSize(width: 420, height: 130))
        let box = path.boundingBoxOfPath
        let pace = HelloStroke.pace
        return !path.isEmpty && box.width <= 420 && box.height <= 130
            && pace.progress.count == HelloStroke.points.count && abs((pace.progress.last ?? 0) - 1) < 1e-9
            && abs((pace.times.last ?? 0) - 1) < 1e-9 && zip(pace.times, pace.times.dropFirst()).allSatisfy { $0 < $1 }
    }
    #endif
}
