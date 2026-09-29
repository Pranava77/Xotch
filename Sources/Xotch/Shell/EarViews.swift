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

/// The system HUD: one thin bar per reading, always in the same place. A bar
/// only changes colour when something needs attention.
struct GaugeBars: View {
    let gauges: [Gauge]
    let tint: Color

    static let barWidth: CGFloat = 5
    static let spacing: CGFloat = 3

    /// An ear just wide enough for `count` bars and the ear's edge padding.
    static func earWidth(count: Int) -> CGFloat {
        let bars = CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * spacing
        return bars + 12 + 14
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(gauges) { gauge in
                GaugeBar(gauge: gauge, tint: tint)
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("System gauges")
        .accessibilityValue(gauges.map { "\($0.label) \($0.spoken)" }.joined(separator: ", "))
    }
}

private struct GaugeBar: View {
    let gauge: Gauge
    let tint: Color

    private var colour: Color {
        switch gauge.level {
        case .normal: tint
        case .warn: Color(red: 1, green: 0.69, blue: 0.13)
        case .alert: Theme.negative
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Theme.raisedFill)
            Capsule()
                .fill(colour)
                .frame(height: max(3, 16 * gauge.value))
                .xotchGloss(Capsule(), strength: 0.5)
        }
        .frame(width: GaugeBars.barWidth, height: 16)
        .animation(Motion.press, value: gauge.value)
    }
}

/// Up to three dots: how many other live activities are waiting their turn.
struct WaitingDots: View {
    let count: Int

    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<min(count, 3), id: \.self) { _ in
                Circle()
                    .fill(Theme.tertiaryInk)
                    .frame(width: 3, height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(count == 1 ? "1 more activity waiting" : "\(count) more activities waiting")
    }
}
