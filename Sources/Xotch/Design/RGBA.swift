import AppKit
import SwiftUI

/// An sRGB colour, for the places SwiftUI's Color can't go (Metal, AppKit).
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
