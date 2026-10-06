import AppKit
import QuartzCore
import SwiftUI

// Pieces of the live activity beside the notch. Anything that moves for a
// long time (the timer ring, the pulse) is a Core Animation layer, so the
// window server animates it and Xotch itself stays idle.

// MARK: - Progress ring

/// A ring around the left-hand icon.
struct ProgressRing: View {
    let progress: ActivityProgress
    let tint: Color
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        Group {
            if snapshotMode {
                ZStack {
                    Circle().stroke(tint.opacity(0.22), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0, to: RingView.fraction(of: progress, at: .now))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(1.1)
            } else {
                RingLayer(progress: progress, tint: NSColor(tint))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RingLayer: NSViewRepresentable {
    let progress: ActivityProgress
    let tint: NSColor

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.update(progress: progress, tint: tint)
    }
}

final class RingView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var progress: ActivityProgress?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineWidth = 2.2
            ring.lineCap = .round
            layer?.addSublayer(ring)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    static func fraction(of progress: ActivityProgress, at date: Date) -> Double {
        switch progress {
        case .fraction(let value):
            return min(max(value, 0), 1)
        case .timed(let start, let end):
            let total = end.timeIntervalSince(start)
            guard total > 0 else { return 1 }
            return min(max(date.timeIntervalSince(start) / total, 0), 1)
        }
    }

    func update(progress: ActivityProgress, tint: NSColor) {
        track.strokeColor = tint.withAlphaComponent(0.22).cgColor
        fill.strokeColor = tint.cgColor
        guard progress != self.progress else { return }
        self.progress = progress
        restart()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = track.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        // Start at twelve o'clock and go clockwise (the layer's y axis points up).
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        track.contentsScale = scale
        fill.contentsScale = scale
    }

    private func restart() {
        guard let progress else { return }
        fill.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = Date()
        let current = Self.fraction(of: progress, at: now)
        if case .timed(_, let end) = progress, end > now {
            fill.strokeEnd = 1
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = current
            animation.toValue = 1
            animation.duration = end.timeIntervalSince(now)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            fill.add(animation, forKey: "fill")
        } else {
            fill.strokeEnd = current
        }
        CATransaction.commit()
    }
}

// MARK: - Pulse

/// A soft ring that swells and fades behind an icon.
struct PulseHalo: View {
    let pulse: LiveActivity.Pulse
    let tint: Color
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        Group {
            if snapshotMode || Motion.reduceMotion {
                Circle().fill(tint.opacity(pulse == .urgent ? 0.34 : 0.22))
            } else {
                PulseLayer(pulse: pulse, tint: NSColor(tint))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PulseLayer: NSViewRepresentable {
    let pulse: LiveActivity.Pulse
    let tint: NSColor

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.update(pulse: pulse, tint: tint)
    }
}

final class PulseView: NSView {
    private let halo = CALayer()
    private var pulse: LiveActivity.Pulse?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(halo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(pulse: LiveActivity.Pulse, tint: NSColor) {
        halo.backgroundColor = tint.cgColor
        guard pulse != self.pulse else { return }
        self.pulse = pulse
        halo.removeAllAnimations()
        startAnimating()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds
        halo.cornerRadius = bounds.width / 2
        CATransaction.commit()
        startAnimating()
    }

    private func startAnimating() {
        guard let pulse, halo.animation(forKey: "pulse") == nil, bounds.width > 0 else { return }
        let urgent = pulse == .urgent
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = urgent ? 1.25 : 1.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = urgent ? 0.7 : 0.5
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = urgent ? 0.95 : 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.opacity = 0
        halo.add(group, forKey: "pulse")
    }
}

// MARK: - Right-hand pieces

/// Lines that take turns every few seconds. Numbers that change roll into place.
struct TickerText: View {
    let lines: [String]
    @State private var index = 0

    var body: some View {
        let line = lines.isEmpty ? "" : lines[index % lines.count]
        ZStack(alignment: .trailing) {
            Text(line)
                .contentTransition(.numericText())
                .id(index % max(lines.count, 1))
                .transition(.push(from: .bottom))
        }
        .clipped()
        .task(id: lines.count) {
            guard lines.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                withAnimation(Motion.activity) { index += 1 }
            }
        }
    }
}

// MARK: - Ear metrics

/// How wide the ears' contents are, worked out from the font rather than laid
/// out, so the closed notch fits them exactly, in snapshots too.
@MainActor
enum EarMetrics {
    /// The right ear's font; `LiveActivityBar` uses the same.
    static let fontSize: CGFloat = 12.5
    /// The volume and brightness bar.
    static let levelWidth: CGFloat = 60
    /// An activity's icon in the left ear.
    static let iconSide: CGFloat = 26
    /// The icon beside the right ear's content while a companion has the left
    /// ear: 26 pt scaled to 0.85, and the spacing before the content.
    static let inlineIcon: CGFloat = 22 + 6

    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        var descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        descriptor = descriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }()

    /// The width SwiftUI gives this text in the ear: measured with the same
    /// font and rounded up, which matches it to the point.
    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// What a running clock shows for this many seconds: SwiftUI's timer text
    /// reads 9:59, 59:59, 9:59:59, then 99:59:59. Digits are all one width.
    static func clockTemplate(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<600: "0:00"
        case ..<3600: "00:00"
        case ..<36000: "0:00:00"
        default: "00:00:00"
        }
    }

    /// The seconds at which a clock gains a digit.
    static let clockSteps: [TimeInterval] = [600, 3600, 36000]

    /// The right ear's content, without padding.
    static func contentWidth(_ activity: LiveActivity, at now: Date = .now) -> CGFloat {
        switch activity.content {
        case .text(let text):
            min(textWidth(text), activity.maxContentWidth)
        case .ticker(let lines):
            min(lines.map(textWidth).max() ?? 0, activity.maxContentWidth)
        // Clocks look a second ahead: a stopwatch's ear widens just before
        // the digit arrives, and a countdown's narrows just after it goes.
        case .countdown(let until):
            textWidth(clockTemplate(seconds: until.timeIntervalSince(now) + 1))
        case .stopwatch(let since):
            textWidth(clockTemplate(seconds: now.timeIntervalSince(since) + 1))
        case .playing, .listening:
            EqualizerView.width
        case .level:
            levelWidth
        }
    }
}

/// A short horizontal level, e.g. volume.
struct LevelBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raisedFill)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(Motion.press, value: value)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Adiyogi

/// Adiyogi, at the outer edge of the left ear: the jata with
/// its crescent moon, eyes closed, and a softly glowing third eye. Drawn once
/// and never animated, so an idle notch stays idle.
struct AdiyogiMark: View {
    static let side: CGFloat = 22
    /// Wide enough for the figure and the ear's edge padding.
    static let earWidth: CGFloat = 40
    /// Saffron, whatever the theme.
    static let thirdEye = Color(red: 1, green: 0.56, blue: 0.2)

    var size: CGFloat = side
    /// The figure's colour: the theme's ink unless set, as for the app icon.
    var ink: Color?

    var body: some View {
        let ink = ink ?? Theme.ink
        Canvas { context, size in
            Self.draw(in: &context, size: size, ink: ink)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Adiyogi")
    }

    /// Drawn in a 64 × 64 box (y down) and scaled to fit.
    private static func draw(in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let s = min(size.width, size.height) / 64
        context.translateBy(x: (size.width - 64 * s) / 2, y: (size.height - 64 * s) / 2)
        context.scaleBy(x: s, y: s)

        // The jata: a tall knot on top and locks down to the shoulders.
        var hair = Path(roundedRect: CGRect(x: 22, y: 0, width: 20, height: 19), cornerRadius: 9)
        hair.addEllipse(in: CGRect(x: 15, y: 10, width: 34, height: 26))
        for side in [-1.0, 1.0] {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 32 + side * x, y: y) }
            hair.move(to: p(15, 22))
            hair.addCurve(to: p(18, 56), control1: p(18, 34), control2: p(21, 46))
            hair.addCurve(to: p(10, 40), control1: p(14, 54), control2: p(10, 48))
            hair.addLine(to: p(9, 24))
            hair.closeSubpath()
        }
        context.fill(hair, with: .color(ink.opacity(0.45)))

        // Shoulders, a little dimmer than the face.
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: 1, y: 64))
        shoulders.addCurve(to: CGPoint(x: 24, y: 50), control1: CGPoint(x: 2, y: 55), control2: CGPoint(x: 12, y: 51))
        shoulders.addLine(to: CGPoint(x: 40, y: 50))
        shoulders.addCurve(to: CGPoint(x: 63, y: 64), control1: CGPoint(x: 52, y: 51), control2: CGPoint(x: 62, y: 55))
        shoulders.closeSubpath()
        context.fill(shoulders.subtracting(hair), with: .color(ink.opacity(0.72)))

        // The crescent moon in the jata.
        let moon = Path(ellipseIn: CGRect(x: 16, y: 3, width: 11, height: 11))
            .subtracting(Path(ellipseIn: CGRect(x: 19, y: 1.5, width: 10, height: 10)))
        context.fill(moon, with: .color(ink))

        // Face and neck.
        var face = Path(roundedRect: CGRect(x: 19, y: 16, width: 26, height: 33), cornerRadius: 12.5)
        face.addRect(CGRect(x: 26, y: 44, width: 12, height: 8))
        context.fill(face, with: .color(ink))

        // Closed eyes and a half smile, cut out so the notch's black shows through.
        var features = Path()
        features.move(to: CGPoint(x: 22.5, y: 32.5))
        features.addQuadCurve(to: CGPoint(x: 29.5, y: 32.5), control: CGPoint(x: 26, y: 36.5))
        features.move(to: CGPoint(x: 34.5, y: 32.5))
        features.addQuadCurve(to: CGPoint(x: 41.5, y: 32.5), control: CGPoint(x: 38, y: 36.5))
        features.move(to: CGPoint(x: 28.5, y: 43))
        features.addQuadCurve(to: CGPoint(x: 35.5, y: 43), control: CGPoint(x: 32, y: 45.5))
        var cut = context
        cut.blendMode = .destinationOut
        cut.stroke(features, with: .color(.black), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

        // The third eye.
        var eye = context
        eye.addFilter(.shadow(color: thirdEye, radius: 3))
        eye.fill(Path(ellipseIn: CGRect(x: 30.2, y: 20.5, width: 3.6, height: 8)), with: .color(thirdEye))
    }
}

/// One dot per live activity, the one in the ear brighter: they take turns
/// there, and the dots show where in the round it is.
struct WaitingDots: View {
    let index: Int
    let count: Int

    private static let maxDots = 4

    var body: some View {
        let shown = min(count, Self.maxDots)
        VStack(spacing: 2.5) {
            ForEach(0..<shown, id: \.self) { dot in
                Circle()
                    .fill(dot == min(index, shown - 1) ? Theme.ink : Theme.tertiaryInk.opacity(0.7))
                    .frame(width: 3, height: 3)
            }
        }
        .animation(Motion.turn, value: index)
        .accessibilityElement()
        .accessibilityLabel("\(index + 1) of \(count) live activities")
    }
}
