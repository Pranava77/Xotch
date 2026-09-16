import AppKit
import SwiftUI
import Observation

/// An sRGB colour that can be saved with a theme.
struct RGBA: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255,
                  green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func rotatingHue(by amount: Double) -> RGBA {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = NSColor(hue: (hue + amount).truncatingRemainder(dividingBy: 1), saturation: saturation,
                              brightness: brightness, alpha: alpha)
        return RGBA(Color(nsColor: shifted))
    }

    /// Black or white, whichever reads on top of this colour.
    var onColor: Color { luminance > 0.45 ? .black : .white }

    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let white = RGBA(red: 1, green: 1, blue: 1)
}

enum SurfaceMaterial: String, Codable, Sendable {
    /// A solid colour, like the hardware notch.
    case solid
    /// Frosted glass that shows a blur of what's behind the notch.
    case glass
}

/// The colours the open notch is drawn with. The closed notch is always black,
/// so it blends into the camera housing whatever the theme.
struct Palette: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// Background of the open notch.
    var surface: RGBA
    /// Text and icons.
    var ink: RGBA
    /// Buttons, progress, highlights.
    var accent: RGBA
    /// Light that spills in from the top corner. Nil follows the module's own colour.
    var glow: RGBA?
    /// 0 turns the glow off.
    var glowStrength: Double
    var material: SurfaceMaterial

    static let midnight = Palette(
        id: "midnight", name: "Midnight",
        surface: .black, ink: .white, accent: RGBA(hex: 0xFF9F0A),
        glow: nil, glowStrength: 0.32, material: .solid
    )
    static let smoke = Palette(
        id: "smoke", name: "Smoke Glass",
        surface: RGBA(hex: 0x0C0D10), ink: .white, accent: RGBA(hex: 0x64D2FF),
        glow: nil, glowStrength: 0.2, material: .glass
    )
    static let aurora = Palette(
        id: "aurora", name: "Aurora",
        surface: RGBA(hex: 0x080D1A), ink: RGBA(hex: 0xEAF1FF), accent: RGBA(hex: 0x5EF2C0),
        glow: RGBA(hex: 0x7B6CFF), glowStrength: 0.42, material: .solid
    )

    static let builtIn = [midnight, smoke, aurora]
    static let customID = "custom"

    /// Text colour that reads on top of the accent.
    var onAccent: Color { accent.onColor }
}

/// The current theme. Not tied to the main actor so `Theme.accent` can be read
/// anywhere; it's only changed from the main thread. Views that read a theme
/// colour redraw when the theme changes, through Observation.
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()

    private static let selectedKey = "themeID"
    private static let customKey = "customTheme"

    private(set) var selectedID: String
    private(set) var custom: Palette

    init() {
        let defaults = UserDefaults.standard
        selectedID = defaults.string(forKey: Self.selectedKey) ?? Palette.midnight.id
        if let data = defaults.data(forKey: Self.customKey),
           let saved = try? JSONDecoder().decode(Palette.self, from: data) {
            custom = saved
        } else {
            custom = Palette.aurora
            custom.id = Palette.customID
            custom.name = "Custom"
        }
    }

    var palette: Palette {
        if selectedID == Palette.customID { return custom }
        return Palette.builtIn.first { $0.id == selectedID } ?? .midnight
    }

    var choices: [Palette] { Palette.builtIn + [custom] }

    @MainActor func select(_ id: String) {
        guard id != selectedID else { return }
        withAnimation(Motion.switchModule) { selectedID = id }
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    /// Starts a custom theme from the one showing now.
    @MainActor func customizeCurrent() {
        guard selectedID != Palette.customID else { return }
        var copy = palette
        copy.id = Palette.customID
        copy.name = "Custom"
        updateCustom { $0 = copy }
        select(Palette.customID)
    }

    @MainActor func updateCustom(_ change: (inout Palette) -> Void) {
        var next = custom
        change(&next)
        next.id = Palette.customID
        guard next != custom else { return }
        custom = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.customKey)
        }
    }

    #if DEBUG
    /// Shows a theme for a snapshot without saving the choice.
    @MainActor func withPalette(_ id: String, _ body: () -> Void) {
        let saved = selectedID
        selectedID = id
        body()
        selectedID = saved
    }
    #endif
}
