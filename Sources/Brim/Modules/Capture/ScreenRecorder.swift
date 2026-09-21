import AppKit
import CoreMedia
@preconcurrency import QuickLookUI
@preconcurrency import ScreenCaptureKit

/// One screen recording, written straight to a movie file by ScreenCaptureKit.
@available(macOS 15.0, *)
@MainActor
final class ScreenRecorder: NSObject {
    enum Source {
        case display(CGDirectDisplayID)
        /// `rect` is in points from the display's top-left corner.
        case area(CGDirectDisplayID, CGRect)
        /// Chosen in macOS's window picker.
        case filter(SCContentFilter)
    }

    struct Options {
        var systemAudio: Bool
        var microphone: Bool
        var showClicks: Bool
    }

    struct RecorderError: LocalizedError {
        let errorDescription: String?
    }

    /// Called once, with the file if it was written.
    var onFinish: (URL?, Error?) -> Void = { _, _ in }

    private var stream: SCStream?
    private var url: URL?
    private var finished = false

    func start(_ source: Source, options: Options, to url: URL) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(let id), .area(let id, _):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw RecorderError(errorDescription: "No display to record.")
            }
            // Leave Brim's notch, and the frame around an area, out of the video.
            let brim = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: brim, exceptingWindows: [])
        case .filter(let picked):
            filter = picked
        }

        let configuration = SCStreamConfiguration()
        var size = filter.contentRect.size
        if case .area(_, let rect) = source {
            configuration.sourceRect = rect
            size = rect.size
        }
        let scale = CGFloat(filter.pointPixelScale)
        // H.264 wants even dimensions.
        configuration.width = max(2, Int(size.width * scale) / 2 * 2)
        configuration.height = max(2, Int(size.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.showMouseClicks = options.showClicks
        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = options.microphone
        configuration.streamName = "Brim screen recording"

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream
        self.url = url
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        // The file is finished once the recording output says so; don't wait forever.
        try? await Task.sleep(for: .seconds(4))
        finish(RecorderError(errorDescription: "Recording didn't finish writing."))
    }

    private func finish(_ error: Error?) {
        guard !finished, let url else { return }
        finished = true
        stream = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 {
            onFinish(url, nil)
        } else {
            try? FileManager.default.removeItem(at: url)
            onFinish(nil, error)
        }
    }

    private func streamStopped(_ error: Error) {
        // Stopped from macOS's menu bar, or the window closed. Give the file a moment to finish.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            finish(error)
        }
    }

    // MARK: - Window picker

    private static var picking: WindowPicking?

    /// Shows macOS's window picker. The handler gets nil if it was cancelled.
    static func pickWindow(_ handler: @escaping (SCContentFilter?) -> Void) {
        picking?.end(nil)
        let picking = WindowPicking(handler: handler)
        self.picking = picking
        picking.begin()
    }

    fileprivate static func pickingEnded(_ picking: WindowPicking) {
        if self.picking === picking {
            self.picking = nil
        }
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.streamStopped(RecorderError(errorDescription: message)) }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(nil) }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(RecorderError(errorDescription: message)) }
        }
    }
}

/// One use of macOS's content picker, limited to a single window.
@available(macOS 15.0, *)
@MainActor
private final class WindowPicking: NSObject, SCContentSharingPickerObserver {
    private var handler: ((SCContentFilter?) -> Void)?

    init(handler: @escaping (SCContentFilter?) -> Void) {
        self.handler = handler
    }

    func begin() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        NSApp.activate()
        picker.present(using: .window)
    }

    func end(_ filter: SCContentFilter?) {
        guard let handler else { return }
        self.handler = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        ScreenRecorder.pickingEnded(self)
        handler(filter)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.end(nil) }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.end(filter) }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.end(nil) }
        }
    }
}

// MARK: - Quick Look

/// Shows a capture in the Quick Look panel.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func show(_ url: URL) {
        urls = [url]
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        // Brim has no windows of its own to host the panel, so it has to come forward.
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
