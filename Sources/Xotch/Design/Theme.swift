import AppKit
import SwiftUI

/// Colours for views. Most come from the current theme (see Palette.swift).
enum Theme {
    static var palette: Palette { ThemeStore.shared.palette }
    /// The closed notch always matches the hardware.
    static let notch = Color.black
    /// Background of the open notch.
    static var surface: Color { palette.surface.color }
    static var ink: Color { palette.ink.color }
    static var secondaryInk: Color { ink.opacity(0.58) }
    /// 0.45 keeps hints above 4.5:1 on dark glass; 0.34 measured about 3.1:1.
    static var tertiaryInk: Color { ink.opacity(0.45) }
    static var fill: Color { ink.opacity(0.07) }
    static var raisedFill: Color { ink.opacity(0.11) }
    static var selection: Color { ink.opacity(0.15) }
    static var hairline: Color { ink.opacity(0.09) }
    /// Midnight's accent is the orange of macOS's microphone-in-use dot (#FF9F0A).
    static var accent: Color { palette.accent.color }
    static var onAccent: Color { palette.onAccent }
    /// Retro themes finish controls with gloss; modern ones stay flat.
    static var isRetro: Bool { palette.isRetro }
    /// Rounded type suits the retro look, the way Frutiger did.
    static var fontDesign: Font.Design { isRetro ? .rounded : .default }
    static let positive = Color(red: 0.2, green: 0.84, blue: 0.47)
    static let negative = Color(red: 1.0, green: 0.36, blue: 0.33)
}

enum Layout {
    /// Size of the open notch body, not counting its shoulders. A module can
    /// ask for more room (see `NotchModule.openSize`).
    /// Wide and short: it spreads along the menu bar rather than down the screen.
    static let openSize = CGSize(width: 740, height: 260)
    /// Default width of each "ear" beside the hardware notch in the activity state.
    static let earWidth: CGFloat = 78
    /// Room for an activity's icon when it moves into the right ear, because
    /// Adiyogi has the left one.
    static let inlineIconWidth: CGFloat = 28
    /// A left ear holding just an activity's icon and the edge padding.
    static let leftIconEarWidth: CGFloat = 52
    /// How much the closed notch grows while the pointer rests on it.
    static let peekGrowth = CGSize(width: 18, height: 6)
    /// Size of the drawn notch on displays that don't have one. A flat width
    /// looks lost on an ultra-wide, so it's a share of the screen between these.
    static let virtualNotchWidth: CGFloat = 186
    static let virtualNotchMaxWidth: CGFloat = 280
    static let virtualNotchShare: CGFloat = 0.09
    static let openShoulder: CGFloat = 14
    static let closedShoulder: CGFloat = 6
    /// How many modules get a tab beside the camera; the rest are under "more".
    static let headerTabs = 5
    /// Room around the open notch for its shadow.
    static let shadowMargin: CGFloat = 44

    /// The largest any module asks for; the panel has to hold it.
    static var maxOpenSize: CGSize { openSize }

    /// The panel never resizes, so it's sized for the largest state.
    static var panelSize: CGSize {
        CGSize(width: maxOpenSize.width + openShoulder * 2 + shadowMargin * 2,
               height: maxOpenSize.height + shadowMargin)
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass on macOS 26 and later. Earlier systems, snapshots (which
    /// can't draw glass) and the forced-fallback switch get a flat fill instead.
    func xotchGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                              fallback: Color? = nil, gloss: Double = 1) -> some View {
        modifier(XotchGlass(shape: shape, tint: tint, interactive: interactive, fallback: fallback, gloss: gloss))
    }

    /// The retro finish on its own: a bright band across the top half, a
    /// bevelled edge, and nothing at all in modern themes. `strength` scales it
    /// down for big surfaces, where full gloss would shout.
    func xotchGloss<S: Shape>(_ shape: S, strength: Double = 1) -> some View {
        modifier(RetroGloss(shape: shape, strength: strength))
    }
}

private struct RetroGloss<S: Shape>: ViewModifier {
    let shape: S
    let strength: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isRetro, strength > 0 {
            content.overlay {
                ZStack {
                    // The specular band: brightest at the top, with the hard
                    // edge at the middle that makes glass look wet.
                    shape.fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.42 * strength), location: 0),
                        .init(color: .white.opacity(0.14 * strength), location: 0.5),
                        .init(color: .white.opacity(0), location: 0.5001),
                    ], startPoint: .top, endPoint: .bottom))
                    // Bevel: a lit top edge fading to a dark lower edge.
                    shape.stroke(LinearGradient(colors: [.white.opacity(0.7 * strength),
                                                         .white.opacity(0.08 * strength),
                                                         .black.opacity(0.35 * strength)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

/// Whether controls can be drawn as real glass right now.
@MainActor func glassAvailable(snapshot: Bool) -> Bool {
    if #available(macOS 26.0, *) { return !snapshot && !GlassFallback.forced }
    return false
}

private struct XotchGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: Color?
    let gloss: Double
    @Environment(\.snapshotMode) private var snapshotMode

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !snapshotMode, !GlassFallback.forced {
            content.glassEffect(glass, in: shape).xotchGloss(shape, strength: gloss)
        } else {
            content.background(tint ?? fallback ?? Theme.fill, in: shape).xotchGloss(shape, strength: gloss)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        let base = tint.map { Glass.regular.tint($0) } ?? .regular
        return interactive ? base.interactive() : base
    }
}

// MARK: - Controls

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: Theme.fontDesign))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(PillBackground(tint: tint, prominent: prominent, pressed: configuration.isPressed))
            .foregroundStyle(prominent ? RGBA(tint).onColor : Theme.ink)
            .opacity(configuration.isPressed && !Theme.isRetro ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// A retro prominent pill is a lit jelly button: a gradient from a lighter top
/// to the tint, a gloss band, and a glow. Pressing darkens it and dims the
/// gloss. Everything else is glass.
private struct PillBackground: ViewModifier {
    let tint: Color
    let prominent: Bool
    let pressed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isRetro, prominent {
            let base = RGBA(tint)
            content
                .background(Capsule().fill(LinearGradient(
                    colors: [base.mixed(with: .white, pressed ? 0.05 : 0.35).color,
                             base.mixed(with: .black, pressed ? 0.3 : 0.05).color],
                    startPoint: .top, endPoint: .bottom)))
                .xotchGloss(Capsule(), strength: pressed ? 0.4 : 1)
                .shadow(color: tint.opacity(pressed ? 0.15 : 0.45), radius: pressed ? 2 : 6, y: 1)
        } else {
            content.xotchGlass(Capsule(), tint: prominent ? tint : nil, interactive: true,
                               fallback: Theme.raisedFill)
        }
    }
}

/// Round icon button with a hover highlight.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, prominent: prominent)
    }

    /// The high-emphasis button stays a solid disc; the rest are glass.
    private struct IconBackground: ViewModifier {
        let prominent: Bool
        let hovering: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            if prominent {
                content.background(Circle().fill(Theme.ink))
            } else {
                content.xotchGlass(Circle(), interactive: true,
                                   fallback: hovering ? Theme.selection : Theme.fill, gloss: 0.8)
            }
        }
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(prominent ? Theme.surface : Theme.ink)
                .frame(width: size, height: size)
                .modifier(IconBackground(prominent: prominent, hovering: hovering))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// A plain row or tile button that highlights on hover.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovering || configuration.isPressed ? Theme.fill : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Building blocks

/// Small uppercase label used above groups.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.tertiaryInk)
    }
}

/// A rounded panel for grouping content inside the open notch.
struct Tile<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .xotchGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), gloss: 0.4)
    }
}

/// Shown when a module has nothing yet, or can't do its job.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let buttonTitle, let action {
                    Button(buttonTitle, action: action)
                        .buttonStyle(PillButtonStyle())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A tiny line chart for recent values in 0...1.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Theme.accent
    var capacity = 30

    var body: some View {
        GeometryReader { geo in
            let points = values.suffix(capacity)
            let step = geo.size.width / CGFloat(max(capacity - 1, 1))
            let offset = CGFloat(capacity - points.count) * step
            let line = Path { path in
                for (index, value) in points.enumerated() {
                    let point = CGPoint(x: offset + CGFloat(index) * step,
                                        y: geo.size.height * (1 - CGFloat(min(max(value, 0), 1))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            ZStack {
                if points.count > 1 {
                    line.addingArea(height: geo.size.height, from: offset, to: offset + CGFloat(points.count - 1) * step)
                        .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    line.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private extension Path {
    func addingArea(height: CGFloat, from startX: CGFloat, to endX: CGFloat) -> Path {
        var area = self
        area.addLine(to: CGPoint(x: endX, y: height))
        area.addLine(to: CGPoint(x: startX, y: height))
        area.closeSubpath()
        return area
    }
}

// MARK: - Formatting

enum Format {
    /// 1:05:09 or 25:00
    static func clock(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let total = Int(min(max(interval, 0), 359_999).rounded(.up))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0
            ? String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
            : String(format: "%ld:%02ld", minutes, seconds)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }

    @MainActor static func relative(_ date: Date, to now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        // Dates in the future read "in 3 days"; only the present minute is "now".
        if abs(seconds) < 60 { return "now" }
        return RelativeDateTimeFormatter.xotch.localizedString(for: date, relativeTo: now)
    }
}

extension RelativeDateTimeFormatter {
    @MainActor static let xotch: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Colour from images

extension NSImage {
    /// A vivid colour from the image, brightened so it reads on black.
    var vividColor: Color? {
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var best: (score: Double, color: NSColor)?
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let high = max(red, green, blue), low = min(red, green, blue)
            guard high > 0.2 else { continue }
            let saturation = (high - low) / high
            let score = saturation * 0.75 + high * 0.25
            if score > (best?.score ?? -1) {
                best = (score, NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            }
        }
        guard let color = best?.color else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(nsColor: NSColor(hue: hue,
                                      saturation: min(saturation, 0.8),
                                      brightness: max(brightness, 0.82),
                                      alpha: 1))
    }
}
