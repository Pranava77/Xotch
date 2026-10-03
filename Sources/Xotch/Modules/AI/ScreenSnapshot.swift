import AppKit
@preconcurrency import ScreenCaptureKit

/// A still of the display under the pointer, for the AI to look at. Xotch's
/// own windows are left out, so the open notch never covers what's asked about.
enum ScreenSnapshot {
    /// Long edge in pixels: plenty to read text, and small enough to send quickly.
    static let maxEdge: CGFloat = 1600

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @MainActor
    static func capture() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AIError("Xotch needs Screen Recording permission to see your screen. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        let displayID = CaptureService.displayUnderPointer()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw AIError("No display to capture.")
        }
        let xotch = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: xotch, exceptingWindows: [])

        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let ratio = min(1, maxEdge / max(pixels.width, pixels.height, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(pixels.width * ratio))
        configuration.height = max(2, Int(pixels.height * ratio))
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpeg = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw AIError("Couldn't encode the screenshot.")
        }
        return jpeg
    }
}
