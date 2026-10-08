// The Xotch promotional film: 46 seconds, 1920 × 1080 at 60 fps.
// Draws every frame from the app's own promo shots and animated sequences
// (sample data over a made-up wallpaper, so no one's data appears), with
// motion of its own on top: titles that arrive a word at a time, the notch
// traced in light and grown open with Home's tiles landing in it, a pointer
// that clicks Allow, whip pans, and numbers that count. Writes H.264.
//
// The section boundaries are fixed: scripts/promo/Score.swift times its cues
// to them.
//
//     scripts/make-promo.sh                     the whole film, with the score
//     Promo <shots> <out.mp4>
//     Promo <shots> --stills <folder> 8.5 13    single frames, for review

import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

// MARK: - Setup

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: Promo <shots folder> <out.mp4> | Promo <shots folder> --stills <folder> <seconds…>")
    exit(1)
}
let shotsFolder = URL(fileURLWithPath: args[1], isDirectory: true)
let width = 1920, height = 1080
let fps = 60
let duration = 46.0
let outCenter = CGPoint(x: Double(width) / 2, y: Double(height) / 2)

struct Shape {
    var width: Double, height: Double, shoulder: Double, corner: Double

    func mixed(with other: Shape, _ x: Double) -> Shape {
        Shape(width: mix(width, other.width, x), height: mix(height, other.height, x),
              shoulder: mix(shoulder, other.shoulder, x), corner: mix(corner, other.corner, x))
    }
}

/// The shots are 1440 × 810-point screens; geometry.json has the notch in
/// each and how many frames each animated sequence has (at 30 a second).
struct Geometry: Decodable {
    let screen: [Double]
    let scale: Double
    let shapes: [String: [Double]]
    let sequences: [String: Int]?
    func shape(_ name: String) -> Shape {
        let s = shapes[name] ?? [220, 38, 6, 10]
        return Shape(width: s[0], height: s[1], shoulder: s[2], corner: s[3])
    }
}
let geometry: Geometry = {
    let data = try! Data(contentsOf: shotsFolder.appendingPathComponent("geometry.json"))
    return try! JSONDecoder().decode(Geometry.self, from: data)
}()
let screenW = geometry.screen[0], screenH = geometry.screen[1]
/// Output pixels per screen point at zoom 1, when the whole screen fills the frame.
let basePixels = Double(width) / screenW

/// Decoded shots, the most recent few kept: a 4K shot is 33 MB decoded.
final class ImageCache {
    private var store: [String: CGImage] = [:]
    private var order: [String] = []
    private let capacity = 16

    func image(_ path: String) -> CGImage {
        if let hit = store[path] {
            order.removeAll { $0 == path }
            order.append(path)
            return hit
        }
        guard let source = CGImageSourceCreateWithURL(shotsFolder.appendingPathComponent(path) as CFURL, nil),
              let made = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("missing shot \(path)")
        }
        store[path] = made
        order.append(path)
        if order.count > capacity { store[order.removeFirst()] = nil }
        return made
    }
}
let images = ImageCache()

func still(_ name: String) -> CGImage { images.image(name.contains(".") ? name : name + ".jpg") }

/// A frame of an animated sequence, at `t` seconds into it; `loop` repeats it.
func sequence(_ name: String, _ t: Double, loop: Bool = false) -> CGImage {
    let count = geometry.sequences?[name] ?? 1
    var index = Int(max(t, 0) * 30)
    index = loop ? index % count : min(index, count - 1)
    return images.image(String(format: "%@/%04d.jpg", name, index))
}

// MARK: - Timing

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
/// 0 before a, 1 after b.
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeIn(_ x: Double) -> Double { x * x * x }
/// A soft spring: a small overshoot, like the notch opening in the app.
func spring(_ x: Double, overshoot: Double = 1.1) -> Double {
    let c3 = overshoot + 1
    return 1 + c3 * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
}
func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }

// MARK: - Camera

/// Where the frame looks: a point on the screen and how far in.
struct Camera {
    var x: Double, y: Double, zoom: Double

    /// Stays inside the screen, so the top of the screen stays at the top.
    var clamped: Camera {
        let scale = zoom * basePixels
        let halfW = Double(width) / 2 / scale, halfH = Double(height) / 2 / scale
        return Camera(x: min(max(x, halfW), screenW - halfW), y: min(max(y, halfH), screenH - halfH), zoom: zoom)
    }

    func blended(to other: Camera, _ x: Double) -> Camera {
        Camera(x: mix(self.x, other.x, x), y: mix(y, other.y, x), zoom: mix(zoom, other.zoom, x))
    }

    /// A screen point in output pixels.
    func project(_ p: CGPoint) -> CGPoint {
        let c = clamped, scale = c.zoom * basePixels
        return CGPoint(x: outCenter.x + (p.x - c.x) * scale, y: outCenter.y + (p.y - c.y) * scale)
    }

    func rect(_ r: CGRect) -> CGRect {
        let a = project(r.origin), b = project(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    var pixelsPerPoint: Double { clamped.zoom * basePixels }
}

/// Looking at the top of the screen, where the notch is.
func top(_ zoom: Double) -> Camera { Camera(x: 720, y: 0, zoom: zoom) }

// MARK: - Drawing

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

/// One frame's drawing context: y grows downwards, like the screen.
struct Frame {
    let ctx: CGContext

    func fill(_ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws an image right way up into a rect in this y-down space.
    func put(_ img: CGImage, in rect: CGRect, alpha: Double = 1) {
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// A whole screen through the camera. `settle` scales it about the top of
    /// the notch, `clip` keeps it inside a path, `shift` moves it in pixels
    /// and `smear` blurs it along that move, like a whip pan.
    func screen(_ img: CGImage, _ camera: Camera, alpha: Double = 1, clip: CGPath? = nil, settle: Double = 1,
                shift: CGFloat = 0, smear: CGFloat = 0) {
        guard alpha > 0.001 else { return }
        let topPoint = camera.project(CGPoint(x: screenW / 2, y: 0))
        let origin = camera.project(.zero)
        let scale = camera.pixelsPerPoint * settle
        let rect = CGRect(x: topPoint.x + (origin.x - topPoint.x) * settle + shift,
                          y: topPoint.y + (origin.y - topPoint.y) * settle,
                          width: screenW * scale, height: screenH * scale)
        ctx.saveGState()
        if let clip {
            ctx.addPath(clip)
            ctx.clip()
        }
        if smear > 1 {
            let copies = 7
            for i in 0..<copies {
                let offset = smear * (CGFloat(i) / CGFloat(copies - 1) - 0.5)
                put(img, in: rect.offsetBy(dx: offset, dy: 0), alpha: min(1, alpha / Double(copies) * 1.8))
            }
        } else {
            put(img, in: rect, alpha: alpha)
        }
        ctx.restoreGState()
    }

    /// Part of a screen, `from` (in screen points), drawn into `to` (pixels).
    func piece(_ img: CGImage, from: CGRect, to: CGRect, alpha: Double) {
        guard alpha > 0.001 else { return }
        let px = Double(img.width) / screenW
        let crop = CGRect(x: from.minX * px, y: from.minY * px, width: from.width * px, height: from.height * px).integral
        guard let part = img.cropping(to: crop) else { return }
        put(part, in: to, alpha: alpha)
    }

    /// The notch's outline, as the app draws it: shoulders that curve into
    /// the menu bar, and rounded bottom corners.
    func notchPath(_ shape: Shape, _ camera: Camera) -> CGPath {
        let cx = screenW / 2
        let left = cx - shape.width / 2, right = cx + shape.width / 2
        let s = shape.shoulder, r = min(shape.corner, shape.height / 2), h = shape.height
        let path = CGMutablePath()
        func p(_ x: Double, _ y: Double) -> CGPoint { camera.project(CGPoint(x: x, y: y)) }
        path.move(to: p(left - s, -1))
        path.addQuadCurve(to: p(left, s), control: p(left, 0))
        path.addLine(to: p(left, h - r))
        path.addQuadCurve(to: p(left + r, h), control: p(left, h))
        path.addLine(to: p(right - r, h))
        path.addQuadCurve(to: p(right, h - r), control: p(right, h))
        path.addLine(to: p(right, s))
        path.addQuadCurve(to: p(right + s, -1), control: p(right, 0))
        path.closeSubpath()
        return path
    }

    func notch(_ shape: Shape, _ camera: Camera, alpha: Double = 1) {
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(notchPath(shape, camera))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The notch drawn in light, `drawn` of the way round, from the middle of
    /// its bottom edge out to both shoulders.
    func trace(_ shape: Shape, _ camera: Camera, drawn: Double, alpha: Double) {
        guard alpha > 0.001, drawn > 0 else { return }
        let scale = camera.pixelsPerPoint
        let half = (shape.width / 2 + shape.height + shape.shoulder) * scale
        let cx = screenW / 2
        func p(_ x: Double, _ y: Double) -> CGPoint { camera.project(CGPoint(x: x, y: y)) }
        let left = cx - shape.width / 2, right = cx + shape.width / 2
        let h = shape.height, r = min(shape.corner, h / 2), s = shape.shoulder
        let leftHalf = CGMutablePath(), rightHalf = CGMutablePath()
        leftHalf.move(to: p(cx, h))
        leftHalf.addLine(to: p(left + r, h))
        leftHalf.addQuadCurve(to: p(left, h - r), control: p(left, h))
        leftHalf.addLine(to: p(left, s))
        leftHalf.addQuadCurve(to: p(left - s, 0), control: p(left, 0))
        rightHalf.move(to: p(cx, h))
        rightHalf.addLine(to: p(right - r, h))
        rightHalf.addQuadCurve(to: p(right, h - r), control: p(right, h))
        rightHalf.addLine(to: p(right, s))
        rightHalf.addQuadCurve(to: p(right + s, 0), control: p(right, 0))
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setLineCap(.round)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setShadow(offset: .zero, blur: 26, color: CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 0.9))
        ctx.setLineDash(phase: 0, lengths: [half * drawn, half * 4])
        for path in [leftHalf, rightHalf] {
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Darkens the bottom of the frame so captions read over the wallpaper.
    func shade(_ alpha: Double) {
        guard alpha > 0.001 else { return }
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.8 * alpha)] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(height) * 0.52),
                               end: CGPoint(x: 0, y: Double(height)), options: [])
    }

    /// Soft colour drifting behind the black sections, from the wallpaper's palette.
    func ambient(_ t: Double, alpha: Double) {
        guard alpha > 0.001 else { return }
        let glows: [(CGColor, Double, Double, Double)] = [
            (CGColor(red: 0.42, green: 0.25, blue: 0.85, alpha: 0.30), 0.30, 0.75, 0.9),
            (CGColor(red: 0.12, green: 0.45, blue: 0.50, alpha: 0.26), 0.72, 0.30, 1.3),
            (CGColor(red: 0.85, green: 0.42, blue: 0.30, alpha: 0.16), 0.80, 0.85, 0.7),
        ]
        ctx.saveGState()
        ctx.setAlpha(alpha)
        for (color, x, y, speed) in glows {
            let center = CGPoint(x: Double(width) * (x + 0.06 * sin(t * 0.35 * speed)),
                                 y: Double(height) * (y + 0.05 * cos(t * 0.3 * speed)))
            let colors = [color, color.copy(alpha: 0)!] as CFArray
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: Double(width) * 0.55, options: [])
        }
        ctx.restoreGState()
    }

    /// The macOS pointer, pressing down a little while `press` > 0.
    func pointer(at p: CGPoint, scale: Double, press: Double, alpha: Double) {
        guard alpha > 0.001 else { return }
        let s = scale * (1 - 0.12 * press)
        let arrow = CGMutablePath()
        let pts: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 19.6), (9.8, 18.4), (6.8, 12.2), (12.2, 12.2)]
        arrow.move(to: CGPoint(x: p.x + pts[0].0 * s, y: p.y + pts[0].1 * s))
        for point in pts.dropFirst() { arrow.addLine(to: CGPoint(x: p.x + point.0 * s, y: p.y + point.1 * s)) }
        arrow.closeSubpath()
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(arrow)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.6 * s / scale)
        ctx.setLineJoin(.round)
        ctx.addPath(arrow)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A ring that spreads out from a click.
    func ripple(at p: CGPoint, _ x: Double) {
        guard x > 0 && x < 1 else { return }
        let r = 14 + 46 * easeOut(x)
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7 * (1 - x)))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }

    /// A rounded key cap with a label, like ⌘K, pressed while `press` > 0.
    func key(_ label: String, center: CGPoint, alpha: Double, press: Double) {
        guard alpha > 0.001 else { return }
        let font = NSFont.systemFont(ofSize: 34, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)])
        let size = text.size()
        let w = size.width + 44, h = 64.0
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2 + 4 * press, width: w, height: h)
        let shape = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.10 + 0.08 * press))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        ctx.setLineWidth(1.5)
        ctx.addPath(shape)
        ctx.strokePath()
        ctx.restoreGState()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        NSGraphicsContext.current = previous
    }
}

// MARK: - Kinetic type

/// Words rendered once into bitmaps, then blurred while they move.
final class Glyphs {
    private var cache: [String: (CGImage, CGSize)] = [:]
    static let pad = 40.0

    func word(_ text: String, size: Double, weight: NSFont.Weight, gray: Double) -> (CGImage, CGSize) {
        let key = "\(text)|\(size)|\(weight.rawValue)|\(gray)"
        if let hit = cache[key] { return hit }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: gray, alpha: 1),
            .kern: -size * 0.018,
        ])
        let bounds = attributed.size()
        let w = Int(ceil(bounds.width + Self.pad * 2)), h = Int(ceil(bounds.height + Self.pad * 2))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(at: CGPoint(x: Self.pad, y: Self.pad))
        NSGraphicsContext.current = previous
        let made = (ctx.makeImage()!, bounds)
        cache[key] = made
        return made
    }

    func blurred(_ image: CGImage, radius: Double) -> CGImage {
        guard radius > 0.4 else { return image }
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let made = ciContext.createCGImage(output, from: input.extent) else { return image }
        return made
    }
}
let glyphs = Glyphs()

enum Split { case words, letters }

/// A line that arrives a piece at a time: each word (or letter) sharpens from
/// a blur and rises into place, then lifts away blurred as it leaves. `slam`
/// lands it from slightly larger instead, for the montage.
func kinetic(_ f: Frame, _ text: String, size: Double, weight: NSFont.Weight = .semibold, gray: Double = 1,
             y: Double, t: Double, start: Double, end: Double, stagger: Double = 0.07, split: Split = .words,
             rise: Double = 34, slam: Bool = false) {
    guard t > start - 0.01 && t < end + 0.6 else { return }
    let pieces: [String] = split == .words ? text.split(separator: " ").map(String.init) : text.map(String.init)
    let gap = split == .words ? size * 0.27 : 0
    let rendered = pieces.map { glyphs.word($0, size: size, weight: weight, gray: gray) }
    let total = rendered.map(\.1.width).reduce(0, +) + gap * Double(max(pieces.count - 1, 0))
    var x = outCenter.x - total / 2
    for (index, (image, bounds)) in rendered.enumerated() {
        let delay = Double(index) * stagger
        let arrive = easeOut(progress(t, start + delay, start + delay + (slam ? 0.22 : 0.55)))
        let leave = easeIn(progress(t, end - 0.35 + delay * 0.4, end + delay * 0.4))
        let alpha = arrive * (1 - leave)
        if alpha > 0.002 {
            let blur = 14 * (1 - arrive) + 10 * leave
            let lift = rise * (1 - arrive) - rise * 0.7 * leave
            let scale = slam ? mix(1.35, 1, arrive) : 1
            let img = glyphs.blurred(image, radius: blur)
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            let cx = x + bounds.width / 2
            f.put(img, in: CGRect(x: cx - w / 2, y: y - h / 2 + lift, width: w, height: h), alpha: alpha)
        }
        x += bounds.width + gap
    }
}

/// A number, centred, for the counters.
func number(_ f: Frame, _ text: String, y: Double, alpha: Double, scale: Double = 1) {
    guard alpha > 0.001 else { return }
    let (img, _) = glyphs.word(text, size: 170, weight: .bold, gray: 1)
    let w = Double(img.width) * scale, h = Double(img.height) * scale
    f.put(img, in: CGRect(x: outCenter.x - w / 2, y: y - h / 2, width: w, height: h), alpha: alpha)
}

// MARK: - Home's tiles

/// Home's tiles, in screen points, from the layout in HomeModule.swift: a
/// 300-point tile, the mascot's and the mirror's 150-point tiles, then two
/// columns of two, 10 points apart, 184 tall, inset 23.5 from the body.
func homeTiles() -> [CGRect] {
    let home = geometry.shape("home")
    let x0 = screenW / 2 - home.width / 2 + 23.5, y0 = 48.0
    let small = (home.width - 47 - 300 - 150 - 150 - 40) / 2
    let colA = x0 + 630, colB = colA + small + 10
    return [
        CGRect(x: x0, y: y0, width: 300, height: 184),
        CGRect(x: x0 + 310, y: y0, width: 150, height: 184),
        CGRect(x: x0 + 470, y: y0, width: 150, height: 184),
        CGRect(x: colA, y: y0, width: small, height: 87),
        CGRect(x: colB, y: y0, width: small, height: 87),
        CGRect(x: colA, y: y0 + 97, width: small, height: 87),
        CGRect(x: colB, y: y0 + 97, width: small, height: 87),
    ].map { $0.insetBy(dx: -1, dy: -1) }
}

// MARK: - Finding Allow

/// Where the focus timer's Allow button is in the AI sequence, in screen
/// points: the top-most run of the accent orange once the steps show.
let allowPoint: CGPoint = {
    let img = sequence("ai-live", 4.6)
    let rep = NSBitmapImageRep(cgImage: img)
    let px = Double(img.width) / screenW
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        var xs: [Int] = []
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.redComponent > 0.85 && c.greenComponent > 0.45 && c.greenComponent < 0.75 && c.blueComponent < 0.3 {
                xs.append(x)
            }
        }
        if xs.count > 6 {
            let right = xs.filter { $0 > (xs.max() ?? 0) - Int(40 * px) }
            return CGPoint(x: Double(right.reduce(0, +)) / Double(right.count) / px, y: Double(y) / px + 6)
        }
    }
    return CGPoint(x: 1010, y: 150)
}()

// MARK: - The film

let black = CGColor(gray: 0, alpha: 1)
let captionY = Double(height) - 150
let subY = Double(height) - 88

let montage: [(shot: String, word: String)] = [
    ("todos", "To-dos."), ("calendar", "Calendar."), ("timers", "Focus."),
    ("media", "Music."), ("capture", "Capture."), ("claude", "Claude Code."),
]

/// From the closed notch, out as it opens into Home, then a slow push in.
func openingCamera(_ t: Double) -> Camera {
    top(2.5).blended(to: top(1.9), easeInOut(progress(t, 5.0, 7.0)))
        .blended(to: top(1.3), easeInOut(progress(t, 7.0, 8.2)))
        .blended(to: top(1.38), easeInOut(progress(t, 8.2, 13.3)))
}

func draw(_ f: Frame, at t: Double) {
    f.fill(black)

    // 0 – 3.4: the hook, on a drifting glow.
    if t < 3.6 {
        f.ambient(t, alpha: easeOut(progress(t, 0, 1.2)) * (1 - easeInOut(progress(t, 2.9, 3.5))))
        kinetic(f, "Your notch has been waiting.", size: 72, y: outCenter.y, t: t, start: 0.45, end: 3.05)
    }

    // 3.4 – 7.6: the notch, traced in light; the screen arrives; the ears wake up.
    if t >= 3.4 && t < 7.7 {
        let camera = openingCamera(t)
        f.screen(still("screen-quiet"), camera, alpha: easeInOut(progress(t, 4.2, 5.0)))
        f.screen(sequence("ears-music", t - 5.3, loop: true), camera, alpha: easeInOut(progress(t, 5.3, 5.7)))
        f.trace(geometry.shape("screen-quiet"), camera, drawn: easeInOut(progress(t, 3.45, 4.35)),
                alpha: 1 - easeInOut(progress(t, 4.7, 5.3)))
        f.shade(easeOut(progress(t, 5.8, 6.2)) * (1 - easeInOut(progress(t, 7.0, 7.4))))
        kinetic(f, "It comes alive.", size: 68, y: captionY, t: t, start: 5.85, end: 7.2)
    }

    // 7.6 – 12.8: the notch grows open; Home's tiles land in it. Meet Xotch.
    if t >= 7.6 && t < 13.3 {
        let camera = openingCamera(t)
        f.screen(sequence("ears-music", t - 5.3, loop: true), camera)
        let raw = progress(t, 7.55, 8.25)
        let shape = geometry.shape("ears-music").mixed(with: geometry.shape("home"), spring(raw))
        let handoff = 1 - easeInOut(progress(t, 9.0, 9.3))
        f.notch(shape, camera, alpha: easeOut(progress(t, 7.55, 7.7)) * handoff)
        if t < 9.3 {
            // Home's background shows through the growing notch…
            f.screen(still("home-empty"), camera, alpha: easeInOut(progress(raw, 0.3, 0.9)) * handoff,
                     clip: f.notchPath(shape, camera), settle: mix(0.94, 1, easeOut(raw)))
            // …and the tiles land in it one after another.
            let full = still("home")
            for (index, tile) in homeTiles().enumerated() {
                let start = 7.95 + Double(index) * 0.075
                let land = spring(progress(t, start, start + 0.5), overshoot: 0.9)
                let target = camera.rect(tile)
                let s = mix(0.82, 1, land)
                let drawn = CGRect(x: target.midX - target.width * s / 2, y: target.midY - target.height * s / 2 + 22 * (1 - land),
                                   width: target.width * s, height: target.height * s)
                f.piece(full, from: tile, to: drawn, alpha: easeOut(progress(t, start, start + 0.3)) * handoff)
            }
        }
        f.screen(still("home"), camera, alpha: 1 - handoff)
        f.shade(easeOut(progress(t, 8.9, 9.3)) * (1 - easeInOut(progress(t, 12.5, 12.9))))
        kinetic(f, "Meet Xotch.", size: 96, weight: .bold, y: captionY - 6, t: t, start: 9.0, end: 10.75, stagger: 0.12)
        kinetic(f, "The notch that does the work.", size: 66, y: captionY, t: t, start: 10.95, end: 12.75)
    }

    // 12.8 – 18.8: the AI plans an afternoon; the pointer clicks Allow.
    if t >= 12.8 && t < 18.9 {
        let camera = top(1.05).blended(to: Camera(x: 790, y: 250, zoom: 1.32), easeInOut(progress(t, 14.6, 16.6)))
        let alpha = easeInOut(progress(t, 12.8, 13.25)) * (1 - easeInOut(progress(t, 18.5, 18.9)))
        f.screen(sequence("ai-live", t - 12.8), camera, alpha: alpha)
        // The pointer comes in from the lower right and presses Allow.
        let target = camera.project(allowPoint)
        let from = CGPoint(x: Double(width) * 0.86, y: Double(height) * 0.86)
        let travel = easeInOut(progress(t, 16.3, 17.55))
        let pos = CGPoint(x: mix(from.x, target.x - 4, travel), y: mix(from.y, target.y - 6, travel) - 24 * sin(travel * .pi))
        let press = progress(t, 17.75, 17.85) - progress(t, 17.9, 18.05)
        f.pointer(at: pos, scale: 2.2, press: clamp(press),
                  alpha: easeOut(progress(t, 16.2, 16.5)) * (1 - easeInOut(progress(t, 18.3, 18.6))))
        f.ripple(at: target, progress(t, 17.82, 18.4))
        f.shade(easeOut(progress(t, 13.3, 13.7)) * (1 - easeInOut(progress(t, 18.4, 18.8))))
        kinetic(f, "Ask. And it acts.", size: 68, y: captionY - 16, t: t, start: 13.4, end: 18.55)
        kinetic(f, "Every change waits for your Allow.", size: 32, weight: .regular, gray: 0.72, y: subY - 2,
                t: t, start: 14.3, end: 18.55, stagger: 0.04, rise: 16)
    }

    // 18.8 – 25.0: dictation, the ear listening, then the words arriving.
    if t >= 18.8 && t < 25.1 {
        let out = 1 - easeInOut(progress(t, 24.7, 25.1))
        let ear = top(2.4).blended(to: top(2.65), easeInOut(progress(t, 18.8, 21.5)))
        f.screen(sequence("ears-dictation", t - 18.8, loop: true), ear, alpha: easeInOut(progress(t, 18.8, 19.2)) * out)
        let open = top(1.5).blended(to: top(1.62), easeInOut(progress(t, 21.2, 25.0)))
        f.screen(sequence("dictation-live", t - 21.2), open, alpha: easeInOut(progress(t, 21.2, 21.6)) * out)
        f.shade(easeOut(progress(t, 19.2, 19.6)) * out)
        kinetic(f, "Hold Fn. Speak. Let go.", size: 68, y: captionY, t: t, start: 19.3, end: 21.3, stagger: 0.1)
        kinetic(f, "Typed wherever you are.", size: 68, y: captionY - 16, t: t, start: 21.6, end: 24.9)
        kinetic(f, "Transcribed on your Mac, in milliseconds.", size: 32, weight: .regular, gray: 0.72, y: subY - 2,
                t: t, start: 22.4, end: 24.9, stagger: 0.04, rise: 16)
    }

    // 25.0 – 31.6: the rest of the day, whip-panned, one word each.
    if t >= 25.0 && t < 31.8 {
        let beat = 1.1, whip = 0.26
        let index = min(Int((t - 25.0) / beat), montage.count - 1)
        let start = 25.0 + Double(index) * beat
        let x = easeInOut(progress(t, start, start + whip))
        let smear = CGFloat(sin(x * .pi) * 260)
        func push(_ i: Int) -> Camera {
            top(1.55).blended(to: top(1.64), progress(t, 25.0 + Double(i) * beat, 25.0 + Double(i + 1) * beat + 0.3))
        }
        let end = 1 - easeInOut(progress(t, 31.35, 31.75))
        if index > 0 && x < 1 {
            f.screen(still(montage[index - 1].shot), push(index - 1), alpha: end, shift: -CGFloat(x) * CGFloat(width), smear: smear)
        }
        if index == 0 {
            f.screen(still(montage[0].shot), push(0), alpha: easeOut(progress(t, 25.0, 25.3)) * end)
        } else {
            f.screen(still(montage[index].shot), push(index), alpha: end, shift: CGFloat(1 - x) * CGFloat(width), smear: smear)
        }
        f.shade(easeOut(progress(t, 25.0, 25.3)) * end)
        kinetic(f, montage[index].word, size: 92, weight: .bold, y: captionY, t: t, start: start + 0.14,
                end: index == montage.count - 1 ? 31.55 : start + beat - 0.02, stagger: 0.05, rise: 0, slam: true)
    }

    // 31.6 – 36.0: a little company, and one shortcut for everything.
    if t >= 31.6 && t < 36.1 {
        let mascot = Camera(x: 700, y: 0, zoom: 3.3).blended(to: Camera(x: 700, y: 0, zoom: 3.7), easeInOut(progress(t, 31.6, 34.0)))
        f.screen(still("screen-mascot"), mascot, alpha: easeInOut(progress(t, 31.6, 32.0)) * (1 - easeInOut(progress(t, 33.7, 34.1))))
        let palette = top(1.25).blended(to: top(1.36), easeInOut(progress(t, 33.8, 36.0)))
        f.screen(still("palette"), palette, alpha: easeInOut(progress(t, 33.8, 34.2)) * (1 - easeInOut(progress(t, 35.7, 36.1))))
        f.shade(easeOut(progress(t, 31.9, 32.3)) * (1 - easeInOut(progress(t, 35.6, 36.0))))
        kinetic(f, "A little company.", size: 68, y: captionY, t: t, start: 32.1, end: 33.75)
        kinetic(f, "Everything, one shortcut away.", size: 68, y: captionY - 30, t: t, start: 34.3, end: 35.85)
        let press = progress(t, 35.15, 35.22) - progress(t, 35.3, 35.4)
        f.key("⌘K", center: CGPoint(x: outCenter.x, y: subY - 2),
              alpha: easeOut(progress(t, 34.8, 35.1)) * (1 - easeInOut(progress(t, 35.6, 35.9))), press: clamp(press))
    }

    // 36.0 – 40.6: light, and private: numbers that count.
    if t >= 36.0 && t < 40.7 {
        f.ambient(t, alpha: easeOut(progress(t, 36.0, 36.6)) * (1 - easeInOut(progress(t, 40.2, 40.7))) * 0.8)
        // 0.3%, counting up over a processor at rest.
        let cpuAlpha = easeOut(progress(t, 36.3, 36.6)) * (1 - easeIn(progress(t, 37.6, 37.95)))
        number(f, String(format: "%.1f%%", 0.3 * easeOut(progress(t, 36.3, 37.1))), y: outCenter.y - 70,
               alpha: cpuAlpha, scale: mix(0.92, 1, easeOut(progress(t, 36.3, 36.8))))
        drawGraph(f, alpha: cpuAlpha, drawn: easeInOut(progress(t, 36.35, 37.4)), y: outCenter.y + 50)
        kinetic(f, "of your processor while it waits.", size: 34, weight: .regular, gray: 0.72, y: outCenter.y + 150,
                t: t, start: 36.6, end: 37.9, stagger: 0.03, rise: 14)
        // 29 MB, counting up as a bar fills.
        let memAlpha = easeOut(progress(t, 38.0, 38.25)) * (1 - easeIn(progress(t, 39.05, 39.4)))
        let memory = easeOut(progress(t, 38.0, 38.7))
        number(f, "\(Int((29 * memory).rounded())) MB", y: outCenter.y - 70, alpha: memAlpha,
               scale: mix(0.92, 1, easeOut(progress(t, 38.0, 38.5))))
        drawBar(f, alpha: memAlpha, filled: memory * 0.18, y: outCenter.y + 70)
        kinetic(f, "of memory.", size: 34, weight: .regular, gray: 0.72, y: outCenter.y + 150, t: t, start: 38.2, end: 39.4, rise: 14)
        kinetic(f, "No account. No tracking.", size: 72, y: outCenter.y, t: t, start: 39.5, end: 40.55, stagger: 0.09)
    }

    // 40.6 – 46.0: the end card.
    if t >= 40.6 {
        let out = 1 - easeInOut(progress(t, 45.2, 46.0))
        f.ambient(t, alpha: easeOut(progress(t, 40.6, 41.6)) * out * 0.7)
        let iconIn = spring(progress(t, 40.8, 41.6), overshoot: 0.7)
        let iconAlpha = easeOut(progress(t, 40.8, 41.3)) * out
        // A soft bloom behind the icon.
        let bloomCenter = CGPoint(x: outCenter.x, y: outCenter.y - 150)
        let bloom = [CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 0.28 * iconAlpha),
                     CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 0)] as CFArray
        f.ctx.drawRadialGradient(CGGradient(colorsSpace: colorSpace, colors: bloom, locations: [0, 1])!, startCenter: bloomCenter,
                                 startRadius: 0, endCenter: bloomCenter, endRadius: max(1, 260 * iconIn), options: [])
        let side = 196 * mix(0.7, 1, iconIn)
        f.put(still("icon.png"), in: CGRect(x: outCenter.x - side / 2, y: bloomCenter.y - side / 2, width: side, height: side), alpha: iconAlpha)
        let held = min(t, 45.1)
        kinetic(f, "Xotch", size: 118, weight: .bold, y: outCenter.y + 26, t: held, start: 41.25, end: 99,
                stagger: 0.06, split: .letters, rise: 40)
        kinetic(f, "The notch that does the work.", size: 40, weight: .regular, gray: 0.72, y: outCenter.y + 118,
                t: held, start: 41.9, end: 99, stagger: 0.05, rise: 18)
        kinetic(f, "Private beta  ·  macOS 14 or later", size: 22, weight: .regular, gray: 0.5, y: Double(height) - 90,
                t: held, start: 42.8, end: 99, stagger: 0.03, rise: 8)
        if out < 1 { f.fill(CGColor(gray: 0, alpha: 1 - out)) }
    }
}

/// A processor at rest: a low, almost flat line with the odd tiny bump.
func drawGraph(_ f: Frame, alpha: Double, drawn: Double, y: Double) {
    guard alpha > 0.001, drawn > 0 else { return }
    let w = 560.0, h = 70.0, x0 = outCenter.x - w / 2
    let path = CGMutablePath()
    let steps = 120
    for i in 0...Int(Double(steps) * drawn) {
        let u = Double(i) / Double(steps)
        let bump = 0.10 * exp(-pow((u - 0.32) * 18, 2)) + 0.07 * exp(-pow((u - 0.71) * 22, 2))
        let v = 0.06 + bump + 0.015 * sin(u * 40)
        let p = CGPoint(x: x0 + w * u, y: y + h / 2 - h * v)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    let ctx = f.ctx
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: x0, y: y + h / 2))
    ctx.addLine(to: CGPoint(x: x0 + w, y: y + h / 2))
    ctx.strokePath()
    ctx.setStrokeColor(CGColor(red: 0.2, green: 0.84, blue: 0.47, alpha: 1))
    ctx.setLineWidth(3)
    ctx.setLineJoin(.round)
    ctx.setShadow(offset: .zero, blur: 12, color: CGColor(red: 0.2, green: 0.84, blue: 0.47, alpha: 0.7))
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Memory in use, as a slim bar that fills.
func drawBar(_ f: Frame, alpha: Double, filled: Double, y: Double) {
    guard alpha > 0.001 else { return }
    let w = 560.0, h = 10.0, x0 = outCenter.x - w / 2
    let ctx = f.ctx
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.14))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: y, width: w, height: h), cornerWidth: 5, cornerHeight: 5, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1))
    ctx.setShadow(offset: .zero, blur: 10, color: CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 0.6))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: y, width: max(w * filled, h), height: h), cornerWidth: 5, cornerHeight: 5, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - Output

func makeContext(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int) -> CGContext {
    let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // y down, like the screen and the shots.
    ctx.translateBy(x: 0, y: Double(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

if args[2] == "--stills" {
    let folder = URL(fileURLWithPath: args[3], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for value in args.dropFirst(4) {
        guard let t = Double(value) else { continue }
        let ctx = makeContext(nil, bytesPerRow: 0)
        draw(Frame(ctx: ctx), at: t)
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try! png.write(to: folder.appendingPathComponent(String(format: "still-%05.2f.png", t)))
    }
    print("stills written to \(folder.path)")
    exit(0)
}

let outURL = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: outURL)
let writer = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 24_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: fps,
        AVVideoExpectedSourceFrameRateKey: fps,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let frames = Int(duration * Double(fps))
let started = Date()
for index in 0..<frames {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = makeContext(CVPixelBufferGetBaseAddress(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    autoreleasepool { draw(Frame(ctx: ctx), at: Double(index) / Double(fps)) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
    if index % (fps * 5) == 0 { print("\(index / fps) s of \(Int(duration)) s") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if writer.status != .completed { print("failed: \(writer.error?.localizedDescription ?? "unknown")"); exit(1) }
print(String(format: "wrote %@ in %.0f s", outURL.path, Date().timeIntervalSince(started)))
