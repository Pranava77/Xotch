import AppKit
import SwiftUI

/// A borderless panel that floats above the menu bar on every Space
/// without activating the app when clicked.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // .auxiliary and .canJoinAllApplications keep Stage Manager's hands off:
        // without them it treats the notch as an app window, scales it into a
        // stage and slides it about when you switch desktops or apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
                              .auxiliary, .canJoinAllApplications]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // Clicks pass through until the pointer is over the notch shape.
        ignoresMouseEvents = true
    }

    // Key status lets ⌘1–9 and Esc reach the notch once it's been clicked.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// `acceptsFirstMouse` on the hosting view lets a click act straight away
    /// while another app is in front — but it also means the click never makes
    /// this panel key, so text fields would quietly ignore the keyboard. Take
    /// focus as soon as someone clicks anything inside the notch.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    // Stop AppKit from pushing the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that handles the first click even when the panel isn't key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
