import SwiftUI

enum Theme {
    static let notch = Color.black
    static let ink = Color.white
    static let secondaryInk = Color.white.opacity(0.55)
    static let tertiaryInk = Color.white.opacity(0.32)
    static let fill = Color.white.opacity(0.07)
    static let selection = Color.white.opacity(0.14)
    /// The orange of macOS's microphone-in-use dot (#FF9F0A).
    static let accent = Color(red: 1.0, green: 0.624, blue: 0.039)
}

enum Layout {
    /// Size of the open notch body, not counting its shoulders.
    static let openSize = CGSize(width: 580, height: 236)
    /// Width of each "ear" beside the hardware notch in the activity state.
    static let earWidth: CGFloat = 78
    /// How much the closed notch grows while the pointer rests on it.
    static let peekGrowth = CGSize(width: 18, height: 6)
    /// Size of the drawn notch on displays that don't have one.
    static let virtualNotchWidth: CGFloat = 186
    static let openShoulder: CGFloat = 14
    static let closedShoulder: CGFloat = 6
    /// Room around the open notch for its shadow.
    static let shadowMargin: CGFloat = 44

    /// The panel never resizes, so it's sized for the largest state.
    static var panelSize: CGSize {
        CGSize(width: openSize.width + openShoulder * 2 + shadowMargin * 2,
               height: openSize.height + shadowMargin)
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .foregroundStyle(.black)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
