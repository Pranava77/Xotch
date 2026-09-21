import AppKit
import Metal
import MetalKit
import SwiftUI

// Metal effects: a ripple when files land on the shelf, a glow around album
// art, and a dot-matrix LED display.
//
// SwiftUI's `.layerEffect` needs shaders precompiled into a .metallib, which
// only Xcode's Metal compiler can make. These shaders are compiled from source
// when first needed (about a tenth of a second, in the background).
//
// To keep Xotch idle while they're on screen, the glow and the LED display are
// drawn once into images and moved by Core Animation. Only the one-second
// ripple draws frame by frame. Until the shaders are ready, and in snapshots,
// plain SwiftUI stands in.

enum ShaderEffect: String, CaseIterable {
    case ripple = "xotch_ripple"
    case glow = "xotch_glow"
    case led = "xotch_led"
}

/// Uniforms shared by every effect, as a flat float array (index → meaning):
/// 0 time, 1–2 size in points, 3 pixels per point, 4–7 colour A, 8–11 colour B,
/// 12… effect-specific.
struct ShaderUniforms {
    var values = [Float](repeating: 0, count: 20)

    init(time: Double, size: CGSize, scale: CGFloat, colorA: RGBA, colorB: RGBA) {
        values[0] = Float(time)
        values[1] = Float(size.width)
        values[2] = Float(size.height)
        values[3] = Float(scale)
        values.replaceSubrange(4..<8, with: [colorA.red, colorA.green, colorA.blue, colorA.alpha].map(Float.init))
        values.replaceSubrange(8..<12, with: [colorB.red, colorB.green, colorB.blue, colorB.alpha].map(Float.init))
    }

    subscript(index: Int) -> Float {
        get { values[index] }
        set { values[index] = newValue }
    }
}

@MainActor
@Observable
final class ShaderKit {
    static let shared = ShaderKit()

    @ObservationIgnored private(set) var device: MTLDevice?
    @ObservationIgnored private(set) var queue: MTLCommandQueue?
    @ObservationIgnored private var pipelines: [ShaderEffect: MTLRenderPipelineState] = [:]
    private(set) var isReady = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private(set) var compileTime: Duration?
    @ObservationIgnored private(set) var failure: String?

    /// Compiles the shaders in the background the first time an effect is shown.
    func prepare() {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let start = clock.now
            let result = Result { try Self.build() }
            let elapsed = clock.now - start
            await MainActor.run {
                let kit = ShaderKit.shared
                kit.isPreparing = false
                kit.compileTime = elapsed
                switch result {
                case .success(let built):
                    kit.device = built.device
                    kit.queue = built.queue
                    kit.pipelines = built.pipelines
                    kit.isReady = true
                case .failure(let error):
                    kit.failure = error.localizedDescription
                }
            }
        }
    }

    func pipeline(for effect: ShaderEffect) -> MTLRenderPipelineState? {
        pipelines[effect]
    }

    /// Draws an effect once. Returns a premultiplied sRGB image `scale` times `size`.
    func image(_ effect: ShaderEffect, size: CGSize, scale: CGFloat, uniforms: ShaderUniforms,
               texture: MTLTexture? = nil) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let device, let queue, let pipeline = pipelines[effect] else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var values = uniforms.values
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&values, length: MemoryLayout<Float>.stride * values.count, index: 0)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private struct Built: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipelines: [ShaderEffect: MTLRenderPipelineState]
    }

    private struct ShaderError: LocalizedError {
        let errorDescription: String?
    }

    nonisolated private static func build() throws -> Built {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ShaderError(errorDescription: "No Metal device.")
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        let library = try device.makeLibrary(source: source, options: options)
        guard let vertex = library.makeFunction(name: "xotch_vertex") else {
            throw ShaderError(errorDescription: "Missing vertex shader.")
        }
        var pipelines: [ShaderEffect: MTLRenderPipelineState] = [:]
        for effect in ShaderEffect.allCases {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = library.makeFunction(name: effect.rawValue)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelines[effect] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        return Built(device: device, queue: queue, pipelines: pipelines)
    }

    // Colours out are premultiplied; the window server composites them.
    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // One triangle that covers the view. uv starts at the top left.
    vertex VertexOut xotch_vertex(uint id [[vertex_id]]) {
        const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VertexOut out;
        out.position = float4(corners[id], 0, 1);
        out.uv = float2(corners[id].x * 0.5 + 0.5, 0.5 - corners[id].y * 0.5);
        return out;
    }

    // Rings of light spreading from where files were dropped.
    // 12–13 origin in points.
    fragment half4 xotch_ripple(VertexOut in [[stage_in]], constant float *u [[buffer(0)]]) {
        float t = u[0];
        float2 size = float2(u[1], u[2]);
        float2 p = in.uv * size;
        float2 origin = float2(u[12], u[13]);
        float3 tint = float3(u[4], u[5], u[6]);
        float d = distance(p, origin);
        float radius = t * 560.0;
        float fade = saturate(1.0 - t / 1.05);
        float3 light = float3(0);
        for (int i = 0; i < 3; i++) {
            float r = radius - float(i) * 42.0;
            if (r <= 0.0) { continue; }
            float width = 7.0 + r * 0.035;
            float strength = 1.0 - float(i) * 0.3;
            float band = exp(-pow((d - r) / width, 2.0));
            // A faint fringe: a little extra red just outside, blue just inside.
            float outside = exp(-pow((d - r - width * 0.7) / width, 2.0));
            float inside = exp(-pow((d - r + width * 0.7) / width, 2.0));
            light += (float3(band) + float3(outside, 0.0, inside) * 0.18) * strength;
        }
        float core = exp(-d / 50.0) * saturate(1.0 - t * 2.5) * 0.7;
        float3 color = tint * light * 0.9 + pow(light, float3(4.0)) * 0.22 + tint * core;
        color *= fade;
        float alpha = saturate(max(max(color.r, color.g), color.b));
        return half4(half3(min(color, float3(alpha))), half(alpha));
    }

    // A slow, breathing halo around a rounded rectangle in the middle of the view.
    // 12 padding around the rectangle, 13 corner radius, 14 strength.
    fragment half4 xotch_glow(VertexOut in [[stage_in]], constant float *u [[buffer(0)]]) {
        float t = u[0];
        float2 size = float2(u[1], u[2]);
        float pad = u[12];
        float corner = u[13];
        float strength = u[14];
        float2 p = in.uv * size - size * 0.5;
        float2 halfSize = size * 0.5 - pad;
        float2 q = abs(p) - halfSize + corner;
        float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
        float angle = atan2(p.y, p.x);
        float swirl = 0.5 + 0.5 * sin(angle * 2.0 + t * 0.8);
        float shimmer = 0.5 + 0.5 * sin(angle * 3.0 - t * 0.55 + 1.7);
        float3 color = mix(float3(u[4], u[5], u[6]), float3(u[8], u[9], u[10]), swirl);
        float falloff = exp(-max(sdf, 0.0) / (pad * 0.34));
        float breathing = 0.86 + 0.14 * sin(t * 1.25);
        float alpha = falloff * strength * (0.5 + 0.5 * shimmer) * breathing;
        alpha *= smoothstep(-1.0, 1.5, sdf);
        alpha = saturate(alpha);
        return half4(half3(color * alpha), half(alpha));
    }

    // Dot-matrix display. The texture holds one texel per dot (text is white).
    // 12 dot pitch in points, 13 rows, 14 first text column, 15 period in
    // columns (text plus gap), 16 wraps (1) or not (0), 17 text columns,
    // 18 fades the left and right edges (1) or not (0).
    fragment half4 xotch_led(VertexOut in [[stage_in]], constant float *u [[buffer(0)]],
                            texture2d<float> text [[texture(0)]]) {
        constexpr sampler nearest(filter::nearest, address::clamp_to_zero);
        float2 size = float2(u[1], u[2]);
        float pitch = u[12];
        float rows = u[13];
        float period = max(u[15], 1.0);
        float2 p = in.uv * size;
        float2 cell = floor(p / pitch);
        float2 local = fract(p / pitch) - 0.5;
        float column = cell.x + u[14];
        float lit = 0.0;
        if (u[16] > 0.5) {
            column = column - period * floor(column / period);
        }
        float textColumns = max(u[17], 1.0);
        if (column >= 0.0 && column < textColumns && cell.y < rows) {
            lit = text.sample(nearest, float2((column + 0.5) / textColumns, (cell.y + 0.5) / rows)).r;
        }
        float d = length(local);
        float dotMask = 1.0 - smoothstep(0.3, 0.42, d);
        float halo = exp(-d * 4.5) * lit * 0.3;
        float4 on = float4(u[4], u[5], u[6], 1.0);
        float4 off = float4(u[8], u[9], u[10], u[11]);
        float4 dotColor = mix(off, on, lit);
        float alpha = saturate(dotMask * dotColor.a + halo);
        float3 color = dotColor.rgb * dotMask * dotColor.a + on.rgb * halo;
        if (u[18] > 0.5) {
            float edge = smoothstep(0.0, 16.0, p.x) * smoothstep(0.0, 16.0, size.x - p.x);
            alpha *= edge;
            color *= edge;
        }
        return half4(half3(min(color, float3(alpha))), half(alpha));
    }
    """
}

// MARK: - Metal view

/// Draws one effect frame by frame while `animating` is on (the ripple).
final class EffectView: MTKView, MTKViewDelegate {
    let effect: ShaderEffect
    var uniforms: (_ time: Double, _ size: CGSize) -> ShaderUniforms = { _, size in
        ShaderUniforms(time: 0, size: size, scale: 2, colorA: .white, colorB: .black)
    }
    private let startTime = CACurrentMediaTime()
    private let pipeline: MTLRenderPipelineState
    private let commandQueue: MTLCommandQueue

    var animating = false {
        didSet {
            guard animating != oldValue else { return }
            isPaused = !animating
            enableSetNeedsDisplay = !animating
            needsDisplay = true
        }
    }

    var time: Double { CACurrentMediaTime() - startTime }

    @MainActor
    init?(effect: ShaderEffect) {
        let kit = ShaderKit.shared
        guard let device = kit.device, let queue = kit.queue, let pipeline = kit.pipeline(for: effect) else { return nil }
        self.effect = effect
        self.pipeline = pipeline
        commandQueue = queue
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Effects are decoration; clicks go to what's underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard bounds.width > 0, bounds.height > 0,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var values = uniforms(time, bounds.size).values
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&values, length: MemoryLayout<Float>.stride * values.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Glow around album art

/// A soft halo in the artwork's colours that slowly shifts while music plays.
struct ArtworkGlow: View {
    let colors: (RGBA, RGBA)
    let isPlaying: Bool
    /// Room the glow spreads into around the artwork.
    let padding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.snapshotMode) private var snapshotMode
    private var kit: ShaderKit { .shared }

    var body: some View {
        Group {
            if kit.isReady, !snapshotMode {
                GlowLayer(colors: colors, animating: isPlaying && !Motion.reduceMotion,
                          padding: padding, cornerRadius: cornerRadius)
            } else if kit.isReady {
                GeometryReader { geo in
                    if let image = GlowView.still(colors: [colors.0, colors.1], size: geo.size,
                                                  padding: padding, cornerRadius: cornerRadius) {
                        Image(decorative: image, scale: 2)
                    }
                }
            } else {
                // Plain stand-in: a blurred rounded rectangle.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [colors.0.color, colors.1.color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(padding)
                    .blur(radius: padding * 0.4)
                    .opacity(0.55)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { kit.prepare() }
    }
}

private struct GlowLayer: NSViewRepresentable {
    let colors: (RGBA, RGBA)
    let animating: Bool
    let padding: CGFloat
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> GlowView { GlowView() }

    func updateNSView(_ view: GlowView, context: Context) {
        view.update(colors: [colors.0, colors.1], padding: padding, cornerRadius: cornerRadius, animating: animating)
    }
}

/// Two renders of the glow, half a turn apart, cross-fading while music plays.
final class GlowView: NSView {
    private let container = CALayer()
    private let first = CALayer()
    private let second = CALayer()
    private var key: [Float] = []
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(container)
        container.addSublayer(first)
        container.addSublayer(second)
        second.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var padding: CGFloat = 0
    private var cornerRadius: CGFloat = 0
    private var colors: [RGBA] = []

    func update(colors: [RGBA], padding: CGFloat, cornerRadius: CGFloat, animating: Bool) {
        self.colors = colors
        self.padding = padding
        self.cornerRadius = cornerRadius
        render()
        guard animating != self.animating else { return }
        self.animating = animating
        restartAnimations()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [container, first, second] {
            layer.frame = bounds
        }
        CATransaction.commit()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        key = []
        render()
    }

    /// The glow as an image, for snapshots.
    @MainActor
    static func still(colors: [RGBA], size: CGSize, padding: CGFloat, cornerRadius: CGFloat) -> CGImage? {
        guard colors.count == 2 else { return nil }
        var uniforms = ShaderUniforms(time: 0, size: size, scale: 2, colorA: colors[0], colorB: colors[1])
        uniforms[12] = Float(padding)
        uniforms[13] = Float(cornerRadius)
        uniforms[14] = 0.75
        return ShaderKit.shared.image(.glow, size: size, scale: 2, uniforms: uniforms)
    }

    @MainActor
    private func render() {
        guard colors.count == 2, bounds.width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let newKey = [Float(bounds.width), Float(bounds.height), Float(scale), Float(padding), Float(cornerRadius)]
            + colors.flatMap { [$0.red, $0.green, $0.blue].map(Float.init) }
        guard newKey != key else { return }
        key = newKey
        let kit = ShaderKit.shared
        for (layer, time) in [(first, 0.0), (second, Double.pi / 0.8)] {
            var uniforms = ShaderUniforms(time: time, size: bounds.size, scale: scale,
                                          colorA: colors[0], colorB: colors[1])
            uniforms[12] = Float(padding)
            uniforms[13] = Float(cornerRadius)
            uniforms[14] = 0.75
            layer.contents = kit.image(.glow, size: bounds.size, scale: scale, uniforms: uniforms)
            layer.contentsScale = scale
        }
    }

    private func restartAnimations() {
        second.removeAllAnimations()
        container.removeAllAnimations()
        guard animating else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 3.9
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        second.add(fade, forKey: "shift")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.8
        breathe.toValue = 1
        breathe.duration = 2.5
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(breathe, forKey: "breathe")
    }
}

// MARK: - Ripple

/// Plays a ripple from `origin` each time `trigger` goes up. The Metal view
/// only exists while the ripple plays.
struct RippleOverlay: View {
    let trigger: Int
    let origin: CGPoint
    let tint: RGBA
    @State private var playing: Int?
    @Environment(\.snapshotMode) private var snapshotMode
    private var kit: ShaderKit { .shared }

    var body: some View {
        ZStack {
            if let playing, kit.isReady, !snapshotMode {
                RippleLayer(origin: origin, tint: tint)
                    .id(playing)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, newValue in
            guard !Motion.reduceMotion else { return }
            kit.prepare()
            playing = newValue
            Task {
                try? await Task.sleep(for: .milliseconds(1150))
                if playing == newValue {
                    playing = nil
                }
            }
        }
    }
}

private struct RippleLayer: NSViewRepresentable {
    let origin: CGPoint
    let tint: RGBA

    func makeNSView(context: Context) -> NSView {
        guard let view = EffectView(effect: .ripple) else { return NSView() }
        let origin = origin, tint = tint
        view.preferredFramesPerSecond = 60
        view.uniforms = { [weak view] time, size in
            var uniforms = ShaderUniforms(time: time, size: size,
                                          scale: view?.window?.backingScaleFactor ?? 2,
                                          colorA: tint, colorB: .white)
            uniforms[12] = Float(origin.x)
            uniforms[13] = Float(origin.y)
            return uniforms
        }
        view.animating = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? EffectView)?.animating = false
    }
}

// MARK: - LED display

/// Text on a dot-matrix display. Long text scrolls one column at a time,
/// like a real LED sign.
struct LEDText: View {
    let text: String
    let color: RGBA
    var rows = 9
    var pitch: CGFloat = 3
    @Environment(\.snapshotMode) private var snapshotMode
    private var kit: ShaderKit { .shared }

    var body: some View {
        Group {
            if kit.isReady, !snapshotMode {
                LEDLayer(text: text, color: color, rows: rows, pitch: pitch,
                         animating: !Motion.reduceMotion)
            } else if kit.isReady {
                GeometryReader { geo in
                    if let image = LEDView.still(text: text, color: color, rows: rows, pitch: pitch, size: geo.size) {
                        Image(decorative: image, scale: 2)
                    }
                }
            } else {
                // Plain stand-in with the same footprint.
                Text(text.uppercased())
                    .font(.system(size: pitch * CGFloat(rows) * 0.62, weight: .bold, design: .monospaced))
                    .foregroundStyle(color.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: pitch * CGFloat(rows))
        .accessibilityElement()
        .accessibilityLabel(text)
        .onAppear { kit.prepare() }
    }
}

private struct LEDLayer: NSViewRepresentable {
    let text: String
    let color: RGBA
    let rows: Int
    let pitch: CGFloat
    let animating: Bool

    func makeNSView(context: Context) -> LEDView { LEDView() }

    func updateNSView(_ view: LEDView, context: Context) {
        view.update(text: text, color: color, rows: rows, pitch: pitch, animating: animating)
    }
}

/// The unlit dots are one still image. When the text is too long, the lit
/// dots are a wider image that Core Animation shifts a whole column at a time.
final class LEDView: NSView {
    private static let gap = 10
    private static let stepsPerSecond = 14.0
    private static let hold = 1.2

    private let board = CALayer()
    private let strip = CALayer()
    private let edges = CAGradientLayer()
    private var text = ""
    private var color = RGBA.white
    private var rows = 9
    private var pitch: CGFloat = 3
    private var animating = true
    private var bitmap: DotMatrix.Bitmap?
    private var texture: MTLTexture?
    private var key = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(board)
        layer?.addSublayer(strip)
        strip.anchorPoint = .zero
        edges.startPoint = CGPoint(x: 0, y: 0.5)
        edges.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String, color: RGBA, rows: Int, pitch: CGFloat, animating: Bool) {
        if text != self.text || rows != self.rows {
            bitmap = DotMatrix.render(text, rows: rows)
            texture = nil
        }
        self.text = text
        self.color = color
        self.rows = rows
        self.pitch = pitch
        self.animating = animating
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        key = ""
        render()
    }

    @MainActor
    private func render() {
        let kit = ShaderKit.shared
        guard let bitmap, bounds.width > 0, let device = kit.device else { return }
        let scale = window?.backingScaleFactor ?? 2
        let visible = Int(bounds.width / pitch)
        let scrolls = bitmap.columns + 1 > visible
        let newKey = "\(text)|\(color)|\(rows)|\(pitch)|\(visible)|\(bounds.height)|\(scale)|\(scrolls && animating)"
        guard newKey != key else { return }
        key = newKey
        if texture == nil {
            texture = DotMatrix.texture(bitmap, device: device)
        }

        let period = bitmap.columns + Self.gap
        let height = CGFloat(rows) * pitch
        let dim = RGBA(red: color.red, green: color.green, blue: color.blue, alpha: 0.1)
        func uniforms(size: CGSize, off: RGBA, wraps: Bool) -> ShaderUniforms {
            var uniforms = ShaderUniforms(time: 0, size: size, scale: scale, colorA: color, colorB: off)
            uniforms[12] = Float(pitch)
            uniforms[13] = Float(rows)
            uniforms[15] = Float(wraps ? period : bitmap.columns)
            uniforms[16] = wraps ? 1 : 0
            uniforms[17] = Float(bitmap.columns)
            return uniforms
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        board.frame = bounds
        board.contentsScale = scale
        strip.contentsScale = scale
        strip.removeAllAnimations()
        if scrolls {
            // Unlit dots stay put; lit dots move over them.
            var empty = uniforms(size: bounds.size, off: dim, wraps: false)
            empty[17] = 0
            board.contents = kit.image(.led, size: bounds.size, scale: scale, uniforms: empty)
            let stripSize = CGSize(width: CGFloat(period + visible + 1) * pitch, height: height)
            strip.contents = kit.image(.led, size: stripSize, scale: scale,
                                       uniforms: uniforms(size: stripSize, off: .init(red: 0, green: 0, blue: 0, alpha: 0), wraps: true),
                                       texture: texture)
            strip.bounds = CGRect(origin: .zero, size: stripSize)
            strip.position = .zero
            strip.isHidden = false
            edges.frame = bounds
            let fade = min(16 / bounds.width, 0.2)
            edges.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            edges.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
            layer?.mask = edges
            if animating {
                strip.add(Self.scroll(period: period, pitch: pitch), forKey: "scroll")
            }
        } else {
            var still = uniforms(size: bounds.size, off: dim, wraps: false)
            // One dark column before the text.
            still[14] = -1
            board.contents = kit.image(.led, size: bounds.size, scale: scale, uniforms: still, texture: texture)
            strip.contents = nil
            strip.isHidden = true
            layer?.mask = nil
        }
        CATransaction.commit()
    }

    /// The display at rest, for snapshots. Text that doesn't fit fades out at the edge.
    @MainActor
    static func still(text: String, color: RGBA, rows: Int, pitch: CGFloat, size: CGSize) -> CGImage? {
        let kit = ShaderKit.shared
        guard let device = kit.device, size.width > 0 else { return nil }
        let bitmap = DotMatrix.render(text, rows: rows)
        guard let texture = DotMatrix.texture(bitmap, device: device) else { return nil }
        var uniforms = ShaderUniforms(time: 0, size: size, scale: 2, colorA: color,
                                      colorB: RGBA(red: color.red, green: color.green, blue: color.blue, alpha: 0.1))
        uniforms[12] = Float(pitch)
        uniforms[13] = Float(rows)
        uniforms[14] = -1
        uniforms[15] = Float(bitmap.columns)
        uniforms[17] = Float(bitmap.columns)
        uniforms[18] = CGFloat(bitmap.columns + 1) * pitch > size.width ? 1 : 0
        return kit.image(.led, size: size, scale: 2, uniforms: uniforms, texture: texture)
    }

    /// Whole-column steps, pausing at the start of each pass.
    private static func scroll(period: Int, pitch: CGFloat) -> CAAnimation {
        let step = 1 / stepsPerSecond
        let total = hold + Double(period) * step
        var values: [CGFloat] = []
        var times: [NSNumber] = []
        for column in 0...period {
            values.append(-CGFloat(column) * pitch)
            let start = column == 0 ? 0 : hold + Double(column - 1) * step
            times.append(NSNumber(value: start / total))
        }
        times.append(1)
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = values
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        return animation
    }
}

/// Text reduced to one value per LED dot.
enum DotMatrix {
    struct Bitmap {
        var columns: Int
        var rows: Int
        /// rows × columns, top row first, 0...255.
        var values: [UInt8]
    }

    /// Classic 5 × 7 LED lettering, one column of space between characters.
    /// Lowercase is shown as capitals and accents are dropped; anything else
    /// (other scripts, emoji) is drawn from the system font at the same size.
    static func render(_ text: String, rows: Int) -> Bitmap {
        let top = max(0, (rows - 7) / 2)
        var columns: [[UInt8]] = []
        let letters = text.uppercased().folding(options: .diacriticInsensitive, locale: nil)
        for character in letters {
            let glyph = LEDFont.glyphs[character] ?? LEDFont.fallback(character)
            for column in glyph {
                var values = [UInt8](repeating: 0, count: rows)
                for (row, on) in column.enumerated() where on && top + row < rows {
                    values[top + row] = 255
                }
                columns.append(values)
            }
            columns.append([UInt8](repeating: 0, count: rows))
        }
        if !columns.isEmpty {
            columns.removeLast()
        }
        if columns.isEmpty {
            columns = [[UInt8](repeating: 0, count: rows)]
        }
        var values = [UInt8](repeating: 0, count: columns.count * rows)
        for (x, column) in columns.enumerated() {
            for y in 0..<rows {
                values[y * columns.count + x] = column[y]
            }
        }
        return Bitmap(columns: columns.count, rows: rows, values: values)
    }

    static func texture(_ bitmap: Bitmap, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: bitmap.columns,
                                                                  height: bitmap.rows, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bitmap.values.withUnsafeBytes { buffer in
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.columns, bitmap.rows), mipmapLevel: 0,
                            withBytes: buffer.baseAddress!, bytesPerRow: bitmap.columns)
        }
        return texture
    }

    #if DEBUG
    /// The bitmap as text, for the self-test report.
    static func ascii(_ bitmap: Bitmap) -> String {
        (0..<bitmap.rows).map { row in
            String((0..<bitmap.columns).map { bitmap.values[row * bitmap.columns + $0] > 128 ? "#" : "." })
        }.joined(separator: "\n")
    }
    #endif
}

/// A 5 × 7 dot font. Each glyph is a list of columns, each column seven
/// dots from the top.
enum LEDFont {
    static let glyphs: [Character: [[Bool]]] = {
        var table: [Character: [[Bool]]] = [:]
        for (character, rows) in source {
            table[character] = columns(rows, trim: !character.isLetter && !character.isNumber)
        }
        table[" "] = Array(repeating: Array(repeating: false, count: 7), count: 3)
        return table
    }()

    private static func columns(_ rows: [String], trim: Bool) -> [[Bool]] {
        let grid = rows.map { $0.map { $0 == "#" } }
        let width = grid.map(\.count).max() ?? 0
        var columns = (0..<width).map { x in grid.map { x < $0.count && $0[x] } }
        if trim {
            while columns.count > 1, columns.first?.contains(true) == false { columns.removeFirst() }
            while columns.count > 1, columns.last?.contains(true) == false { columns.removeLast() }
        }
        return columns
    }

    /// Characters the font doesn't have, drawn with the system font and
    /// reduced to seven rows.
    static func fallback(_ character: Character) -> [[Bool]] {
        let oversample = 4
        let height = 7 * oversample
        let font = NSFont.systemFont(ofSize: CGFloat(height), weight: .bold)
        let string = NSAttributedString(string: String(character),
                                        attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = max(oversample, Int(ceil(string.size().width / CGFloat(oversample))) * oversample)
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(at: NSPoint(x: 0, y: -font.descender * 0.6))
            NSGraphicsContext.restoreGraphicsState()
        }
        let columns = width / oversample
        return (0..<columns).map { x in
            (0..<7).map { y in
                var sum = 0
                for dy in 0..<oversample {
                    for dx in 0..<oversample {
                        sum += Int(pixels[(y * oversample + dy) * width + x * oversample + dx])
                    }
                }
                return sum / (oversample * oversample) > 100
            }
        }
    }

    private static let source: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
        ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
        ";": [".....", ".##..", ".##..", ".....", ".##..", "..#..", ".#..."],
        "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "’": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "\"": [".#.#.", ".#.#.", ".#.#.", ".....", ".....", ".....", "....."],
        "-": [".....", ".....", ".....", ".###.", ".....", ".....", "....."],
        "–": [".....", ".....", ".....", "####.", ".....", ".....", "....."],
        "—": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
        "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
        ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
        "[": [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
        "]": [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],
        "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
        "*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
        "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
        "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "@": [".###.", "#...#", "....#", ".##.#", "#.#.#", "#.#.#", ".###."],
        "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
        "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
        ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
        "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
        "•": [".....", ".....", ".###.", ".###.", ".###.", ".....", "....."],
        "~": [".....", ".....", ".#...", "#.#.#", "...#.", ".....", "....."],
    ]
}

