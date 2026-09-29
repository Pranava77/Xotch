import AppKit
import CoreGraphics

/// The built-in display's brightness.
///
/// macOS has no public API for this. Xotch loads Apple's private DisplayServices
/// framework at run time, the way many menu bar apps do, so nothing links to a
/// private symbol: if the framework or a function is missing after an update,
/// `isAvailable` is false and the HUD simply leaves brightness to macOS.
/// External monitors aren't covered.
@MainActor
enum Brightness {
    private typealias GetFunction = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (UInt32, Float) -> Int32

    private static let functions: (get: GetFunction, set: SetFunction)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFunction.self), unsafeBitCast(set, to: SetFunction.self))
    }()

    /// The built-in display, if this Mac has one.
    static var builtInDisplay: CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    /// 0...1, or nil when it can't be read (no built-in display, or the
    /// framework isn't there).
    static var level: Double? {
        guard let functions, let display = builtInDisplay else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    static var isAvailable: Bool { level != nil }

    @discardableResult
    static func setLevel(_ newValue: Double) -> Bool {
        guard let functions, let display = builtInDisplay else { return false }
        return functions.set(display, Float(min(max(newValue, 0), 1))) == 0
    }

    static func symbol(for level: Double) -> String {
        level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }
}
