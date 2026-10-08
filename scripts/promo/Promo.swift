// The Xotch promotional film: 46 seconds, 1920 × 1080 at 60 fps, silent.
// Draws every frame from the app's own promo shots (sample data over a
// made-up wallpaper, so no one's data appears) and writes an H.264 movie.
//
//     scripts/make-promo.sh                     the whole film
//     Promo <shots> <out.mp4>
//     Promo <shots> --stills <folder> 8.5 13    single frames, for review

import AppKit
import AVFoundation
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
}

/// The shots are 1440 × 810-point screens; geometry.json has the notch in each.
struct Geometry: Decodable {
    let screen: [Double]
    let scale: Double
    let shapes: [String: [Double]]
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

var cache: [String: CGImage] = [:]
func image(_ name: String) -> CGImage {
    if let hit = cache[name] { return hit }
    let file = name.contains(".") ? name : name + ".jpg"
    guard let source = CGImageSourceCreateWithURL(shotsFolder.appendingPathComponent(file) as CFURL, nil),
          let made = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("missing shot \(name)")
    }
    cache[name] = made
    return made
}

// MARK: - Timing

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
/// 0 before a, 1 after b.
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
/// A soft spring: a small overshoot, like the notch opening in the app.
func spring(_ x: Double) -> Double {
    let c1 = 1.1, c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}
func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
/// Fades in over a…a+fade and out over b-fade…b.
func window(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.45) -> Double {
    min(easeOut(progress(t, a, a + fade)), 1 - easeInOut(progress(t, b - fade, b)))
}

// MARK: - Drawing

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

    var pixelsPerPoint: Double { zoom * basePixels }
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// One frame's drawing context: y grows downwards, like the screen.
struct Frame {
    let ctx: CGContext

    func fill(_ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// A shot through the camera; optionally only inside `clip`, and scaled
    /// about the top of the notch, as content settling into it.
    func shot(_ name: String, _ camera: Camera, alpha: Double = 1, clip: CGPath? = nil, settle: Double = 1) {
        guard alpha > 0.001 else { return }
        let img = image(name)
        let top = camera.project(CGPoint(x: screenW / 2, y: 0))
        let origin = camera.project(.zero)
        let scale = camera.clamped.pixelsPerPoint * settle
        let rect = CGRect(x: top.x + (origin.x - top.x) * settle, y: top.y + (origin.y - top.y) * settle,
                          width: screenW * scale, height: screenH * scale)
        ctx.saveGState()
        if let clip {
            ctx.addPath(clip)
            ctx.clip()
        }
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The notch's outline, as the app draws it: shoulders that curve into
    /// the menu bar, and rounded bottom corners.
    func notch(_ shape: Shape, _ camera: Camera, alpha: Double = 1) {
        guard alpha > 0.001 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(notchPath(shape, camera))
        ctx.fillPath()
        ctx.restoreGState()
    }

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

    /// Darkens the bottom of the frame so captions read over the wallpaper.
    func shade(_ alpha: Double) {
        guard alpha > 0.001 else { return }
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.78 * alpha)] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(height) * 0.55),
                               end: CGPoint(x: 0, y: Double(height)), options: [])
    }

    /// Centred text that rises a little as it fades in.
    func text(_ string: String, size: Double, weight: NSFont.Weight = .semibold, gray: Double = 1,
              y: Double, alpha: Double, rise: Double = 18) {
        guard alpha > 0.001 else { return }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: gray, alpha: alpha),
            .kern: -size * 0.018,
        ])
        let bounds = attributed.size()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attributed.draw(at: CGPoint(x: outCenter.x - bounds.width / 2,
                                    y: y - bounds.height / 2 + rise * (1 - alpha)))
        NSGraphicsContext.current = previous
    }

    func icon(size: Double, centerY: Double, alpha: Double) {
        guard alpha > 0.001 else { return }
        let img = image("icon.png")
        let side = size * mix(0.92, 1, alpha)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .high
        let rect = CGRect(x: outCenter.x - side / 2, y: centerY - side / 2, width: side, height: side)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

// MARK: - The film

let black = CGColor(gray: 0, alpha: 1)
/// The whole screen, then closer in on the notch.
let wide = Camera(x: 720, y: 405, zoom: 1)
let onNotch = Camera(x: 720, y: 0, zoom: 1.9)
let onHome = Camera(x: 720, y: 0, zoom: 1.3)
let onModule = Camera(x: 720, y: 0, zoom: 1.55)
let onEars = Camera(x: 720, y: 0, zoom: 2.4)
let onAI = Camera(x: 720, y: 0, zoom: 1.05)
let captionY = Double(height) - 150
let subY = Double(height) - 92

let montage: [(shot: String, word: String)] = [
    ("todos", "To-dos."), ("calendar", "Calendar."), ("timers", "Focus."),
    ("media", "Music."), ("capture", "Capture."), ("claude", "Claude Code."),
]

/// From the whole screen in to the notch, then back out as it opens into
/// Home: one path, so the two scenes meet without a seam.
func openingCamera(_ t: Double) -> Camera {
    wide.blended(to: onNotch, easeInOut(progress(t, 3.4, 6.6)))
        .blended(to: onHome, easeInOut(progress(t, 7.0, 8.2)))
        .blended(to: Camera(x: 720, y: 0, zoom: 1.38), easeInOut(progress(t, 8.2, 13.3)))
}

func draw(_ f: Frame, at t: Double) {
    f.fill(black)

    // 0 – 3.4: the hook, on black.
    f.text("Your notch has been waiting.", size: 68, y: outCenter.y, alpha: window(t, 0.4, 3.2, fade: 0.7))

    // 3.4 – 7.6: a Mac screen; the camera drifts to the notch, which comes alive.
    if t >= 3.4 && t < 7.7 {
        let camera = openingCamera(t)
        let fadeIn = easeOut(progress(t, 3.4, 4.4))
        f.shot("screen-quiet", camera, alpha: fadeIn)
        f.shot("screen-music", camera, alpha: fadeIn * easeInOut(progress(t, 5.3, 5.8)))
        let caption = window(t, 5.7, 7.2)
        f.shade(caption)
        f.text("It comes alive.", size: 64, y: captionY, alpha: caption)
    }

    // 7.6 – 12.8: the notch grows open into Home. Meet Xotch.
    if t >= 7.6 && t < 13.3 {
        let camera = openingCamera(t)
        f.shot("screen-music", camera)
        let grow = spring(progress(t, 7.55, 8.25))
        let from = geometry.shape("screen-music"), to = geometry.shape("home")
        let shape = Shape(width: mix(from.width, to.width, grow), height: mix(from.height, to.height, grow),
                          shoulder: mix(from.shoulder, to.shoulder, grow), corner: mix(from.corner, to.corner, grow))
        // The notch takes over from the ears and Home shows through it as it
        // grows, settling into place; then Home's own edge takes over.
        let raw = progress(t, 7.55, 8.25)
        f.notch(shape, camera, alpha: easeOut(progress(t, 7.55, 7.7)) * (1 - easeInOut(progress(t, 8.3, 8.7))))
        if t < 8.5 {
            f.shot("home", camera, alpha: easeInOut(progress(raw, 0.25, 0.85)) * (1 - easeInOut(progress(t, 8.3, 8.5))),
                   clip: f.notchPath(shape, camera), settle: mix(0.94, 1, easeOut(raw)))
        }
        f.shot("home", camera, alpha: easeInOut(progress(t, 8.3, 8.5)))
        let meet = window(t, 8.9, 10.7), line = window(t, 10.9, 12.7)
        f.shade(max(meet, line))
        f.text("Meet Xotch.", size: 92, weight: .bold, y: captionY - 6, alpha: meet)
        f.text("The notch that does the work.", size: 64, y: captionY, alpha: line)
    }

    // 12.8 – 18.8: the AI acts, with your permission.
    if t >= 12.8 && t < 18.9 {
        let camera = onAI.blended(to: Camera(x: 720, y: 0, zoom: 1.12), easeInOut(progress(t, 12.8, 18.8)))
        f.shot("ai-tools", camera, alpha: easeInOut(progress(t, 12.8, 13.3)) * (1 - easeInOut(progress(t, 18.5, 18.9))))
        let head = window(t, 13.4, 18.6), sub = window(t, 14.3, 18.6)
        f.shade(head)
        f.text("Ask. And it acts.", size: 64, y: captionY - 14, alpha: head)
        f.text("Every change waits for your Allow.", size: 30, weight: .regular, gray: 0.72, y: subY - 4, alpha: sub)
    }

    // 18.8 – 25.0: dictation, from the ear to the open notch.
    if t >= 18.8 && t < 25.1 {
        let closeUp = onEars.blended(to: Camera(x: 720, y: 0, zoom: 2.6), easeInOut(progress(t, 18.8, 21.4)))
        let inOut = easeInOut(progress(t, 18.8, 19.2)) * (1 - easeInOut(progress(t, 24.7, 25.1)))
        f.shot("screen-dictation", closeUp, alpha: inOut)
        let open = onModule.blended(to: Camera(x: 720, y: 0, zoom: 1.62), easeInOut(progress(t, 21.2, 25.0)))
        f.shot("dictation", open, alpha: easeInOut(progress(t, 21.2, 21.6)) * inOut)
        let first = window(t, 19.3, 21.3), second = window(t, 21.6, 24.9), sub = window(t, 22.4, 24.9)
        f.shade(max(first, second))
        f.text("Hold Fn. Speak. Let go.", size: 64, y: captionY, alpha: first)
        f.text("Typed wherever you are.", size: 64, y: captionY - 14, alpha: second)
        f.text("Transcribed on your Mac, in milliseconds.", size: 30, weight: .regular, gray: 0.72,
               y: subY - 4, alpha: sub)
    }

    // 25.0 – 31.6: the rest of your day, one word at a time.
    if t >= 25.0 && t < 31.8 {
        let beat = 1.1
        for (index, item) in montage.enumerated() {
            let start = 25.0 + Double(index) * beat
            guard t >= start - 0.01 && t < start + beat + 0.25 else { continue }
            let camera = onModule.blended(to: Camera(x: 720, y: 0, zoom: 1.63), progress(t, start, start + beat + 0.25))
            let alpha = easeInOut(progress(t, start, start + 0.12))
                * (index == montage.count - 1 ? 1 - easeInOut(progress(t, 31.4, 31.8)) : 1)
            f.shot(item.shot, camera, alpha: alpha)
        }
        let index = min(Int((t - 25.0) / beat), montage.count - 1)
        let start = 25.0 + Double(index) * beat
        let word = min(easeOut(progress(t, start + 0.08, start + 0.3)), 1 - easeInOut(progress(t, start + beat - 0.12, start + beat)))
        f.shade(t < 31.6 ? 1 : 1 - progress(t, 31.6, 31.8))
        f.text(montage[index].word, size: 84, weight: .bold, y: captionY, alpha: index == montage.count - 1
               ? min(word == 0 && t > start + 0.3 ? 1 : word, 1 - easeInOut(progress(t, 31.2, 31.6))) : word, rise: 10)
    }

    // 31.6 – 36.0: a little company, and one shortcut for everything.
    if t >= 31.6 && t < 36.1 {
        let mascot = Camera(x: 700, y: 0, zoom: 3.4).blended(to: Camera(x: 700, y: 0, zoom: 3.6), progress(t, 31.6, 34.0))
        f.shot("screen-mascot", mascot, alpha: easeInOut(progress(t, 31.6, 32.0)) * (1 - easeInOut(progress(t, 33.7, 34.1))))
        let palette = Camera(x: 720, y: 0, zoom: 1.3).blended(to: Camera(x: 720, y: 0, zoom: 1.36), progress(t, 33.8, 36.0))
        f.shot("palette", palette, alpha: easeInOut(progress(t, 33.8, 34.2)) * (1 - easeInOut(progress(t, 35.7, 36.1))))
        let company = window(t, 32.1, 33.8), shortcut = window(t, 34.3, 35.9), key = window(t, 34.9, 35.9)
        f.shade(max(company, shortcut))
        f.text("A little company.", size: 64, y: captionY, alpha: company)
        f.text("Everything, one shortcut away.", size: 64, y: captionY - 14, alpha: shortcut)
        f.text("⌘K", size: 32, weight: .medium, gray: 0.72, y: subY - 2, alpha: key)
    }

    // 36.0 – 40.6: light, and private.
    if t >= 36.0 && t < 40.7 {
        let cpu = window(t, 36.3, 37.9), memory = window(t, 38.0, 39.4), privacy = window(t, 39.5, 40.6, fade: 0.35)
        f.text("0.3%", size: 160, weight: .bold, y: outCenter.y - 40, alpha: cpu)
        f.text("of your processor while it waits.", size: 34, weight: .regular, gray: 0.72, y: outCenter.y + 80, alpha: cpu)
        f.text("29 MB", size: 160, weight: .bold, y: outCenter.y - 40, alpha: memory)
        f.text("of memory.", size: 34, weight: .regular, gray: 0.72, y: outCenter.y + 80, alpha: memory)
        f.text("No account. No tracking.", size: 68, y: outCenter.y, alpha: privacy)
    }

    // 40.6 – 46.0: the end card.
    if t >= 40.6 {
        let out = 1 - easeInOut(progress(t, 45.2, 46.0))
        f.icon(size: 190, centerY: outCenter.y - 150, alpha: easeOut(progress(t, 40.8, 41.6)) * out)
        f.text("Xotch", size: 110, weight: .bold, y: outCenter.y + 20, alpha: easeOut(progress(t, 41.3, 42.0)) * out)
        f.text("The notch that does the work.", size: 38, weight: .regular, gray: 0.72, y: outCenter.y + 110,
               alpha: easeOut(progress(t, 42.0, 42.7)) * out)
        f.text("Private beta  ·  macOS 14 or later", size: 22, weight: .regular, gray: 0.5, y: Double(height) - 90,
               alpha: easeOut(progress(t, 42.8, 43.3)) * out)
    }
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
    draw(Frame(ctx: ctx), at: Double(index) / Double(fps))
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
