import AppKit
import QuartzCore
import SwiftUI

/// Brim's mascot: a tiny notch with glowing eyes. It naps when nothing has
/// happened for a while, thinks while Claude, a timer or a download is busy,
/// and jumps for joy at a sale. ActivityCenter decides the mood.
struct MascotBadge: View {
    let mood: MascotMood
    var size: CGFloat = 52
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        Group {
            if snapshotMode {
                if let image = MascotView.image(mood: mood, side: size) {
                    Image(nsImage: image)
                }
            } else {
                MascotLayer(mood: mood, accent: NSColor(Theme.accent), ink: NSColor(Theme.ink))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Brim")
        .accessibilityValue(mood.spoken)
    }
}

extension MascotMood {
    var spoken: String {
        switch self {
        case .idle: "Relaxing"
        case .working: "Busy"
        case .celebrating: "Celebrating"
        case .sleeping: "Asleep"
        }
    }
}

private struct MascotLayer: NSViewRepresentable {
    let mood: MascotMood
    let accent: NSColor
    let ink: NSColor

    func makeNSView(context: Context) -> MascotView { MascotView() }

    func updateNSView(_ view: MascotView, context: Context) {
        view.update(mood: mood, accent: accent, ink: ink, animated: !Motion.reduceMotion)
    }
}

/// Drawn in a 64 × 64 box (y up) and scaled to the view.
final class MascotView: NSView {
    /// Scales the 64-point drawing to the view.
    private let stage = CALayer()
    /// Everything that moves together (breathing, jumping).
    private let figure = CALayer()
    private let body = CAShapeLayer()
    private let leftEye = CAShapeLayer()
    private let rightEye = CAShapeLayer()
    private let mouth = CAShapeLayer()
    private let dots = (0..<3).map { _ in CALayer() }
    private let sparkles = (0..<3).map { _ in CAShapeLayer() }
    private let snores = (0..<2).map { _ in CATextLayer() }
    private var state: (mood: MascotMood, accent: NSColor, ink: NSColor, animated: Bool)?

    private static let box: CGFloat = 64
    private static let leftEyeCenter = CGPoint(x: 25, y: 29)
    private static let rightEyeCenter = CGPoint(x: 39, y: 29)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        stage.bounds = CGRect(x: 0, y: 0, width: Self.box, height: Self.box)
        layer?.addSublayer(stage)
        // Breathe and squash from the feet.
        figure.bounds = stage.bounds
        figure.anchorPoint = CGPoint(x: 0.5, y: 8 / Self.box)
        figure.position = CGPoint(x: Self.box / 2, y: 8)
        stage.addSublayer(figure)

        body.path = Self.bodyPath
        body.lineWidth = 1
        figure.addSublayer(body)

        for eye in [leftEye, rightEye] {
            eye.shadowOpacity = 0.9
            eye.shadowRadius = 3
            eye.shadowOffset = .zero
            eye.lineCap = .round
            eye.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            figure.addSublayer(eye)
        }
        leftEye.position = Self.leftEyeCenter
        rightEye.position = Self.rightEyeCenter

        mouth.lineWidth = 1.6
        mouth.lineCap = .round
        mouth.bounds = CGRect(x: 0, y: 0, width: 12, height: 8)
        mouth.position = CGPoint(x: 32, y: 19)
        figure.addSublayer(mouth)

        for (index, dot) in dots.enumerated() {
            dot.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            dot.cornerRadius = 2
            dot.position = CGPoint(x: 26 + CGFloat(index) * 6, y: 56)
            figure.addSublayer(dot)
        }

        let sparkleSpots = [CGPoint(x: 8, y: 50), CGPoint(x: 57, y: 46), CGPoint(x: 52, y: 60)]
        for (sparkle, spot) in zip(sparkles, sparkleSpots) {
            sparkle.path = Self.sparklePath
            sparkle.bounds = CGRect(x: -4, y: -4, width: 8, height: 8)
            sparkle.position = spot
            figure.addSublayer(sparkle)
        }

        for (index, snore) in snores.enumerated() {
            snore.string = "z"
            snore.fontSize = index == 0 ? 9 : 7
            snore.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            snore.alignmentMode = .center
            snore.bounds = CGRect(x: 0, y: 0, width: 10, height: 12)
            snore.position = CGPoint(x: 52 + CGFloat(index) * 5, y: 50 + CGFloat(index) * 7)
            snore.contentsScale = 2
            figure.addSublayer(snore)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = min(bounds.width, bounds.height) / Self.box
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = (window?.backingScaleFactor ?? 2) * max(bounds.width / Self.box, 1)
        for layer in [body, leftEye, rightEye, mouth] + sparkles as [CAShapeLayer] {
            layer.contentsScale = scale
        }
        snores.forEach { $0.contentsScale = scale }
    }

    func update(mood: MascotMood, accent: NSColor, ink: NSColor, animated: Bool) {
        if let state, state.mood == mood, state.accent == accent, state.ink == ink, state.animated == animated {
            return
        }
        state = (mood, accent, ink, animated)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pose(mood: mood, accent: accent, ink: ink)
        CATransaction.commit()
        removeAnimations()
        if animated {
            animate(mood)
        }
    }

    // MARK: - Poses

    private func pose(mood: MascotMood, accent: NSColor, ink: NSColor) {
        body.fillColor = ink.withAlphaComponent(mood == .sleeping ? 0.08 : 0.13).cgColor
        body.strokeColor = ink.withAlphaComponent(0.22).cgColor

        let eyesOpen = mood == .idle || mood == .working
        for eye in [leftEye, rightEye] {
            eye.shadowColor = accent.cgColor
            eye.shadowOpacity = mood == .sleeping ? 0 : 0.9
            if eyesOpen {
                eye.path = Self.openEye
                eye.fillColor = accent.cgColor
                eye.strokeColor = nil
                eye.lineWidth = 0
            } else {
                eye.path = mood == .celebrating ? Self.happyEye : Self.closedEye
                eye.fillColor = nil
                eye.strokeColor = (mood == .sleeping ? ink.withAlphaComponent(0.55) : accent).cgColor
                eye.lineWidth = 1.8
            }
        }

        switch mood {
        case .celebrating:
            mouth.path = Self.openMouth
            mouth.fillColor = ink.withAlphaComponent(0.85).cgColor
            mouth.strokeColor = nil
        case .sleeping:
            mouth.path = Self.smallMouth
            mouth.fillColor = nil
            mouth.strokeColor = ink.withAlphaComponent(0.4).cgColor
        case .idle, .working:
            mouth.path = mood == .working ? Self.flatMouth : Self.smile
            mouth.fillColor = nil
            mouth.strokeColor = ink.withAlphaComponent(0.7).cgColor
        }

        for dot in dots {
            dot.backgroundColor = accent.cgColor
            dot.opacity = mood == .working ? 0.9 : 0
        }
        for sparkle in sparkles {
            sparkle.fillColor = accent.cgColor
            sparkle.opacity = mood == .celebrating ? 1 : 0
        }
        for snore in snores {
            snore.foregroundColor = ink.withAlphaComponent(0.6).cgColor
            snore.opacity = mood == .sleeping ? 1 : 0
        }
    }

    private func removeAnimations() {
        ([figure, body, leftEye, rightEye, mouth] + dots + sparkles + snores).forEach { $0.removeAllAnimations() }
    }

    private func animate(_ mood: MascotMood) {
        let now = CACurrentMediaTime()
        switch mood {
        case .idle:
            figure.add(Self.breathe(duration: 3.2, amount: 0.035), forKey: "breathe")
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.1, 1, 1]
            blink.keyTimes = [0, 0.9, 0.93, 0.96, 1]
            blink.duration = 4.6
            blink.repeatCount = .infinity
            leftEye.add(blink, forKey: "blink")
            rightEye.add(blink, forKey: "blink")

        case .working:
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = 1.5
            bob.duration = 0.32
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            figure.add(bob, forKey: "bob")
            let glance = CAKeyframeAnimation(keyPath: "transform.translation.x")
            glance.values = [0, -2.5, -2.5, 2.5, 2.5, 0]
            glance.keyTimes = [0, 0.1, 0.4, 0.5, 0.85, 1]
            glance.duration = 2.4
            glance.repeatCount = .infinity
            leftEye.add(glance, forKey: "glance")
            rightEye.add(glance, forKey: "glance")
            for (index, dot) in dots.enumerated() {
                let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
                hop.values = [0, 3, 0, 0]
                hop.keyTimes = [0, 0.2, 0.4, 1]
                hop.duration = 1.0
                hop.repeatCount = .infinity
                hop.beginTime = now + Double(index) * 0.15
                dot.add(hop, forKey: "hop")
            }

        case .celebrating:
            let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
            jump.values = [0, 7, 0, 0]
            jump.keyTimes = [0, 0.3, 0.6, 1]
            jump.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                                    CAMediaTimingFunction(name: .linear)]
            jump.duration = 0.7
            jump.repeatCount = .infinity
            figure.add(jump, forKey: "jump")
            for (index, sparkle) in sparkles.enumerated() {
                let twinkle = CAKeyframeAnimation(keyPath: "transform.scale")
                twinkle.values = [0.3, 1.2, 0.3]
                twinkle.duration = 0.8
                twinkle.repeatCount = .infinity
                twinkle.beginTime = now + Double(index) * 0.22
                sparkle.add(twinkle, forKey: "twinkle")
            }

        case .sleeping:
            figure.add(Self.breathe(duration: 4.6, amount: 0.05), forKey: "breathe")
            for (index, snore) in snores.enumerated() {
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -4
                rise.toValue = 5
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 0]
                let group = CAAnimationGroup()
                group.animations = [rise, fade]
                group.duration = 2.6
                group.repeatCount = .infinity
                group.beginTime = now + Double(index) * 1.3
                snore.opacity = 0
                snore.add(group, forKey: "snore")
            }
        }
    }

    private static func breathe(duration: CFTimeInterval, amount: CGFloat) -> CAAnimation {
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1
        breathe.toValue = 1 + amount
        breathe.duration = duration / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return breathe
    }

    // MARK: - Shapes

    /// A notch: flat top with small shoulders, generous bottom corners.
    private static let bodyPath: CGPath = {
        let rect = CGRect(x: 11, y: 8, width: 42, height: 38)
        let bottom: CGFloat = 15, top: CGFloat = 5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - top))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + bottom), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - top), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }()

    // Eye paths are drawn in the eye layer's 12 × 12 box.
    private static let openEye = CGPath(roundedRect: CGRect(x: 3.5, y: 1.5, width: 5, height: 9),
                                        cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)

    /// ^ shape.
    private static let happyEye: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 4))
        path.addLine(to: CGPoint(x: 6, y: 8))
        path.addLine(to: CGPoint(x: 10, y: 4))
        return path
    }()

    /// A gentle downward curve.
    private static let closedEye: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 6.5))
        path.addQuadCurve(to: CGPoint(x: 10, y: 6.5), control: CGPoint(x: 6, y: 3))
        return path
    }()

    // Mouth paths are drawn in the mouth layer's 12 × 8 box.
    private static let smile: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: 5))
        path.addQuadCurve(to: CGPoint(x: 9, y: 5), control: CGPoint(x: 6, y: 1.5))
        return path
    }()

    private static let flatMouth: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 4))
        path.addLine(to: CGPoint(x: 8, y: 4))
        return path
    }()

    private static let smallMouth = CGPath(ellipseIn: CGRect(x: 5, y: 2.5, width: 2, height: 2), transform: nil)

    private static let openMouth: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2.5, y: 6.5))
        path.addLine(to: CGPoint(x: 9.5, y: 6.5))
        path.addQuadCurve(to: CGPoint(x: 2.5, y: 6.5), control: CGPoint(x: 6, y: -2.5))
        path.closeSubpath()
        return path
    }()

    /// A four-pointed star, centred on the origin.
    private static let sparklePath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 4))
        path.addQuadCurve(to: CGPoint(x: 4, y: 0), control: CGPoint(x: 0.6, y: 0.6))
        path.addQuadCurve(to: CGPoint(x: 0, y: -4), control: CGPoint(x: 0.6, y: -0.6))
        path.addQuadCurve(to: CGPoint(x: -4, y: 0), control: CGPoint(x: -0.6, y: -0.6))
        path.addQuadCurve(to: CGPoint(x: 0, y: 4), control: CGPoint(x: -0.6, y: 0.6))
        path.closeSubpath()
        return path
    }()

    // MARK: - Still image

    /// The mood's resting pose as an image, for snapshots.
    static func image(mood: MascotMood, side: CGFloat) -> NSImage? {
        let view = MascotView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.update(mood: mood, accent: NSColor(Theme.accent), ink: NSColor(Theme.ink), animated: false)
        view.layout()
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
