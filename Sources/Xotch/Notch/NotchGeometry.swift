import AppKit

/// Where the notch sits on one screen, and how big the hardware (or drawn) notch is.
@MainActor
struct NotchGeometry {
    let screenFrame: NSRect
    let notchSize: CGSize
    let hasHardwareNotch: Bool

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasHardwareNotch = true
            notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                               height: topInset)
        } else {
            // No notch: draw one as tall as the menu bar.
            hasHardwareNotch = false
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            let height = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
            notchSize = CGSize(width: Layout.virtualNotchWidth, height: max(height, 24))
        }
    }

    /// The panel is centred on the top edge of the screen.
    var panelFrame: NSRect {
        let size = Layout.panelSize
        return NSRect(x: screenFrame.midX - size.width / 2,
                      y: screenFrame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// The on-screen rectangle of a notch body of the given size, shoulders included.
    func screenRect(bodySize: CGSize, shoulder: CGFloat) -> NSRect {
        let width = bodySize.width + shoulder * 2
        return NSRect(x: screenFrame.midX - width / 2,
                      y: screenFrame.maxY - bodySize.height,
                      width: width,
                      height: bodySize.height)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
