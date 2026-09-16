import AppKit

/// Works out whether a display is showing a full-screen app (or two in Split
/// View), so the notch can step aside. Uses window bounds only, which macOS
/// shares without Screen Recording permission.
enum FullScreenDetector {
    struct WindowInfo: Equatable {
        var bounds: CGRect
        var layer: Int
    }

    /// Normal-layer windows currently on screen, in Quartz coordinates (origin top-left).
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            return WindowInfo(bounds: bounds, layer: layer)
        }
    }

    /// The screen's frame in Quartz coordinates.
    static func quartzFrame(of screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX, y: primaryHeight - screenFrame.maxY,
               width: screenFrame.width, height: screenFrame.height)
    }

    /// True when normal windows fill the whole screen, menu bar area included.
    static func isFullScreen(screen: CGRect, windows: [WindowInfo]) -> Bool {
        let tolerance: CGFloat = 2
        let filling = windows.filter { window in
            window.layer == 0
                && abs(window.bounds.minY - screen.minY) <= tolerance
                && abs(window.bounds.height - screen.height) <= tolerance
                && window.bounds.minX >= screen.minX - tolerance
                && window.bounds.maxX <= screen.maxX + tolerance
                && window.bounds.width >= 200
        }
        guard !filling.isEmpty else { return false }
        // One full-width window, or Split View's side-by-side pair.
        let covered = filling.reduce(0) { $0 + $1.bounds.width }
        return covered >= screen.width * 0.95
    }

    #if DEBUG
    static func selfTest() -> [String] {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let cases: [(String, [WindowInfo], Bool)] = [
            ("empty desktop", [], false),
            ("normal window", [WindowInfo(bounds: CGRect(x: 100, y: 200, width: 900, height: 700), layer: 0)], false),
            ("zoomed window below menu bar", [WindowInfo(bounds: CGRect(x: 0, y: 38, width: 1800, height: 1131), layer: 0)], false),
            ("full-screen app", [WindowInfo(bounds: screen, layer: 0)], true),
            ("split view", [WindowInfo(bounds: CGRect(x: 0, y: 0, width: 897, height: 1169), layer: 0),
                            WindowInfo(bounds: CGRect(x: 903, y: 0, width: 897, height: 1169), layer: 0)], true),
            ("screen-sized overlay above windows", [WindowInfo(bounds: screen, layer: 25)], false),
            ("window on another display", [WindowInfo(bounds: CGRect(x: 1800, y: 0, width: 1920, height: 1080), layer: 0)], false),
        ]
        let results = cases.map { name, windows, expected in
            let actual = isFullScreen(screen: screen, windows: windows)
            return "\(name)=\(actual == expected ? "ok" : "WRONG(\(actual))")"
        }
        let converted = quartzFrame(of: CGRect(x: -1920, y: 200, width: 1920, height: 1080), primaryHeight: 1169)
        return ["full-screen detection: " + results.joined(separator: ", "),
                "quartz conversion: \(converted == CGRect(x: -1920, y: -111, width: 1920, height: 1080) ? "ok" : "WRONG \(converted)")"]
    }
    #endif
}
