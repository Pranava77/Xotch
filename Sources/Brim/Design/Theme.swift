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
    static var tertiaryInk: Color { ink.opacity(0.34) }
    static var fill: Color { ink.opacity(0.07) }
    static var raisedFill: Color { ink.opacity(0.11) }
    static var selection: Color { ink.opacity(0.15) }
    static var hairline: Color { ink.opacity(0.09) }
    /// Midnight's accent is the orange of macOS's microphone-in-use dot (#FF9F0A).
    static var accent: Color { palette.accent.color }
    static var onAccent: Color { palette.onAccent }
    static let positive = Color(red: 0.2, green: 0.84, blue: 0.47)
    static let negative = Color(red: 1.0, green: 0.36, blue: 0.33)
}

enum Layout {
    /// Size of the open notch body, not counting its shoulders. A module can
    /// ask for more room (see `NotchModule.openSize`); Life does.
    static let openSize = CGSize(width: 600, height: 300)
    /// Room for a year of squares, the week's columns and an arc beside them.
    static let wideOpenSize = CGSize(width: 880, height: 460)
    /// Default width of each "ear" beside the hardware notch in the activity state.
    static let earWidth: CGFloat = 78
    /// How much the closed notch grows while the pointer rests on it.
    static let peekGrowth = CGSize(width: 18, height: 6)
    /// Size of the drawn notch on displays that don't have one.
    static let virtualNotchWidth: CGFloat = 186
    static let openShoulder: CGFloat = 14
    static let closedShoulder: CGFloat = 6
    static let dockHeight: CGFloat = 40
    /// Room around the open notch for its shadow.
    static let shadowMargin: CGFloat = 44

    /// The largest any module asks for; the panel has to hold it.
    static var maxOpenSize: CGSize {
        CGSize(width: max(openSize.width, wideOpenSize.width),
               height: max(openSize.height, wideOpenSize.height))
    }

    /// The panel never resizes, so it's sized for the largest state.
    static var panelSize: CGSize {
        CGSize(width: maxOpenSize.width + openShoulder * 2 + shadowMargin * 2,
               height: maxOpenSize.height + shadowMargin)
    }
}

// MARK: - Controls

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(prominent ? tint : Theme.raisedFill, in: Capsule())
            .foregroundStyle(prominent ? RGBA(tint).onColor : Theme.ink)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Round icon button with a hover highlight.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, prominent: prominent)
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
                .background(Circle().fill(prominent ? Theme.ink : (hovering ? Theme.selection : Theme.fill)))
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
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
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
        return RelativeDateTimeFormatter.brim.localizedString(for: date, relativeTo: now)
    }
}

extension RelativeDateTimeFormatter {
    @MainActor static let brim: RelativeDateTimeFormatter = {
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
