import AppKit
import QuartzCore
import SwiftUI

/// Confetti that bursts out of the notch each time `trigger` goes up.
/// A Core Animation emitter runs it, so it costs Xotch almost nothing.
struct CelebrationBurst: NSViewRepresentable {
    let trigger: Int
    /// How far below the top of the view the confetti starts.
    let originFromTop: CGFloat
    let width: CGFloat

    func makeNSView(context: Context) -> CelebrationView {
        let view = CelebrationView()
        // Don't replay an old celebration when the notch is rebuilt.
        view.lastTrigger = trigger
        return view
    }

    func updateNSView(_ view: CelebrationView, context: Context) {
        guard trigger != view.lastTrigger else { return }
        view.lastTrigger = trigger
        guard !Motion.reduceMotion else { return }
        view.burst(originFromTop: originFromTop, width: width)
    }
}

final class CelebrationView: NSView {
    var lastTrigger = 0

    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.2, green: 0.84, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1),
        NSColor(srgbRed: 1, green: 0.44, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1),
        .white,
    ]

    private static let strip = image(size: CGSize(width: 7, height: 3.5), corner: 1)
    private static let dot = image(size: CGSize(width: 5, height: 5), corner: 2.5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Clicks pass through to the notch.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func burst(originFromTop: CGFloat, width: CGFloat) {
        guard let root = layer else { return }
        let emitter = CAEmitterLayer()
        emitter.frame = root.bounds
        // Layer coordinates start at the bottom.
        emitter.emitterPosition = CGPoint(x: root.bounds.midX, y: root.bounds.height - originFromTop)
        emitter.emitterShape = .line
        emitter.emitterSize = CGSize(width: max(width - 30, 40), height: 1)
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = Self.colors.flatMap { color in
            [Self.cell(image: Self.strip, color: color), Self.cell(image: Self.dot, color: color)]
        }
        root.addSublayer(emitter)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            emitter.birthRate = 0
            try? await Task.sleep(for: .seconds(2.2))
            emitter.removeFromSuperlayer()
        }
    }

    private static func cell(image: CGImage?, color: NSColor) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = 2
        cell.color = color.cgColor
        cell.birthRate = 26
        cell.lifetime = 1.9
        cell.velocity = 210
        cell.velocityRange = 110
        // Downwards, fanning out.
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 2.6
        cell.yAcceleration = -480
        cell.spin = 3
        cell.spinRange = 9
        cell.scale = 1
        cell.scaleRange = 0.45
        cell.alphaSpeed = -0.5
        return cell
    }

    private static func image(size: CGSize, corner: CGFloat) -> CGImage? {
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: corner,
                               cornerHeight: corner, transform: nil))
        context.fillPath()
        return context.makeImage()
    }
}
