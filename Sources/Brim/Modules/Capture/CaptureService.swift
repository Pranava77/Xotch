import AppKit
import AVFoundation
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A screenshot or recording on the Capture shelf.
struct CaptureItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    /// Taken with macOS's own tools (⌘⇧3, ⌘⇧4, ⌘⇧5) rather than Brim.
    let fromMac: Bool

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isVideo: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }
}

/// What to capture: a dragged area, one window, or the display under the pointer.
enum CaptureTarget: String, CaseIterable, Identifiable {
    case area, window, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "menubar.dock.rectangle"
        }
    }
}

/// Screenshots, screen recordings, and the shelf of recent captures.
///
/// Screenshots use macOS's own `screencapture` tool, so choosing an area or a
/// window looks and works exactly like ⌘⇧4. Recordings use ScreenCaptureKit
/// (macOS 15 or later) and leave Brim's own windows out.
@MainActor
@Observable
final class CaptureService {
    static let shared = CaptureService()
    static let tint = Color(red: 0.36, green: 0.78, blue: 1)
    /// The most items the shelf shows.
    static let limit = 40

    enum Notice: Equatable {
        case needsScreenPermission
        case microphoneDenied
        case failed(String)
    }

    private(set) var items: [CaptureItem] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    /// macOS's crosshair or window picker is up.
    private(set) var isTakingScreenshot = false
    private(set) var isStartingRecording = false
    private(set) var isStoppingRecording = false
    private(set) var recordingStarted: Date?
    private(set) var recordingTarget: CaptureTarget?
    var notice: Notice?

    @ObservationIgnored private var brimItems: [CaptureItem] = []
    @ObservationIgnored private var macItems: [CaptureItem] = []
    /// Paths removed from the shelf, with the capture's date.
    @ObservationIgnored private var hidden: [String: Date]
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var queryObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var queryFolder: URL?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: AnyObject?
    @ObservationIgnored private lazy var hiddenSaver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(self.hidden, to: "capture-hidden.json")
    }

    init() {
        hidden = Storage.load([String: Date].self, from: "capture-hidden.json") ?? [:]
    }

    var isRecording: Bool { recordingStarted != nil }

    static var canRecord: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: - Folders

    static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brim", isDirectory: true)
    }

    var folder: URL {
        let path = AppSettings.captureFolder
        return path.isEmpty ? Self.defaultFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where ⌘⇧3 and ⌘⇧4 save, from Screenshot's Options menu. Desktop unless changed.
    static var macScreenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            var isFolder: ObjCBool = false
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder), isFolder.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// "Screenshot 2026-09-17 at 15.20.11.png", like macOS, with " (2)" if taken.
    static func fileName(prefix: String, date: Date, extension ext: String, attempt: Int = 1) -> String {
        let suffix = attempt > 1 ? " (\(attempt))" : ""
        return "\(prefix) \(stamp.string(from: date))\(suffix).\(ext)"
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    private func nextURL(prefix: String, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        var attempt = 1
        while true {
            let url = folder.appendingPathComponent(Self.fileName(prefix: prefix, date: now, extension: ext, attempt: attempt))
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            attempt += 1
        }
    }

    // MARK: - Permission

    static var hasScreenPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks the first time; afterwards macOS only points people to System Settings.
    private func ensureScreenPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() {
            if notice == .needsScreenPermission {
                notice = nil
            }
            return true
        }
        withAnimation(Motion.switchModule) { notice = .needsScreenPermission }
        return false
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    // MARK: - Screenshots

    /// `delay` in seconds, counted down by macOS.
    func takeScreenshot(_ target: CaptureTarget, delay: Int = 0) {
        guard !isTakingScreenshot, ensureScreenPermission() else { return }
        let url: URL
        do {
            url = try nextURL(prefix: "Screenshot", extension: "png")
        } catch {
            notice = .failed("Couldn't save to \(folder.lastPathComponent): \(error.localizedDescription)")
            return
        }
        var arguments = ["-x"]
        switch target {
        case .area: arguments.append("-i")
        case .window: arguments += ["-i", "-W"]
        case .screen: arguments += ["-D", String(Self.screencaptureIndex(of: Self.displayUnderPointer()))]
        }
        if delay > 0 {
            arguments += ["-T", String(delay)]
        }
        arguments.append(url.path)

        isTakingScreenshot = true
        // Get the open notch out of the picture first.
        ScreenManager.shared.closeAll()
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let status = await Self.runScreencapture(arguments)
            isTakingScreenshot = false
            guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
                // Esc in the crosshair leaves no file; so does macOS refusing to
                // capture. Picking a whole screen can't be cancelled, so that
                // can only be the permission.
                if target == .screen || !Self.hasScreenPermission {
                    withAnimation(Motion.switchModule) { notice = .needsScreenPermission }
                }
                return
            }
            saved(url)
        }
    }

    nonisolated private static func runScreencapture(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    static func displayUnderPointer() -> CGDirectDisplayID {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID ?? CGMainDisplayID()
    }

    /// `screencapture -D` counts displays from 1, in the order Quartz lists them (main first).
    static func screencaptureIndex(of display: CGDirectDisplayID) -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 1 }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return 1 }
        return (displays.firstIndex(of: display) ?? 0) + 1
    }

    // MARK: - Recording

    func startRecording(_ target: CaptureTarget) {
        guard #available(macOS 15.0, *) else {
            notice = .failed("Recording needs macOS 15 or later.")
            return
        }
        guard !isRecording, !isStartingRecording else { return }
        // Choosing a window uses macOS's picker, which works without the permission.
        guard target == .window || ensureScreenPermission() else { return }
        ScreenManager.shared.closeAll()
        switch target {
        case .screen:
            begin(.display(Self.displayUnderPointer()), target: target)
        case .area:
            RegionPicker.pick { [weak self] selection in
                guard let self, let selection else { return }
                self.begin(.area(selection.display, selection.rect), target: target, frame: selection.frame)
            }
        case .window:
            isStartingRecording = true
            ScreenRecorder.pickWindow { [weak self] filter in
                guard let self else { return }
                self.isStartingRecording = false
                guard let filter else { return }
                self.begin(.filter(filter), target: target)
            }
        }
    }

    @available(macOS 15.0, *)
    private func begin(_ source: ScreenRecorder.Source, target: CaptureTarget, frame: NSRect? = nil) {
        isStartingRecording = true
        let recorder = ScreenRecorder()
        recorder.onFinish = { [weak self] url, error in
            self?.recordingFinished(url, error: error)
        }
        Task {
            defer { isStartingRecording = false }
            var options = ScreenRecorder.Options(systemAudio: AppSettings.captureSystemAudio,
                                                 microphone: AppSettings.captureMicrophone,
                                                 showClicks: AppSettings.captureShowsClicks)
            if options.microphone, !(await Self.microphoneAllowed()) {
                options.microphone = false
                notice = .microphoneDenied
            }
            do {
                let url = try nextURL(prefix: "Screen Recording", extension: "mov")
                self.recorder = recorder
                try await recorder.start(source, options: options, to: url)
                recordingStarted = Date()
                recordingTarget = target
                if notice != .microphoneDenied {
                    notice = nil
                }
                updateActivity()
                if let frame {
                    RecordingFrame.show(around: frame)
                }
                Haptics.tick()
            } catch {
                self.recorder = nil
                notice = .failed("Couldn't start recording. \(error.localizedDescription)")
                postBanner(symbol: "exclamationmark.triangle.fill", text: "Not recording", image: nil)
            }
        }
    }

    func stopRecording() {
        guard #available(macOS 15.0, *), let recorder = recorder as? ScreenRecorder, !isStoppingRecording else { return }
        isStoppingRecording = true
        Task { await recorder.stop() }
    }

    func toggleRecording(_ target: CaptureTarget) {
        isRecording ? stopRecording() : startRecording(target)
    }

    private func recordingFinished(_ url: URL?, error: Error?) {
        recorder = nil
        recordingStarted = nil
        recordingTarget = nil
        isStoppingRecording = false
        RecordingFrame.hide()
        updateActivity()
        if let url {
            saved(url)
        } else {
            notice = .failed("The recording couldn't be saved. \(error?.localizedDescription ?? "")")
            postBanner(symbol: "exclamationmark.triangle.fill", text: "Not saved", image: nil)
        }
    }

    private func updateActivity() {
        guard let recordingStarted else {
            ActivityCenter.shared.setOngoing(nil, for: "capture")
            return
        }
        ActivityCenter.shared.setOngoing(Self.recordingActivity(since: recordingStarted), for: "capture")
    }

    static func recordingActivity(since start: Date) -> LiveActivity {
        LiveActivity(moduleID: "capture", symbol: "record.circle.fill", content: .stopwatch(since: start),
                     tint: Theme.negative, earWidth: 90, pulse: .urgent)
    }

    // MARK: - After a capture

    private func saved(_ url: URL) {
        let item = CaptureItem(url: url, date: Date(), fromMac: false)
        brimItems.removeAll { $0.id == item.id }
        brimItems.insert(item, at: 0)
        let preview = item.isVideo ? nil : Self.quickThumbnail(url)
        if let preview {
            thumbnails[item.id] = preview
        }
        merge()
        var copied = false
        if !item.isVideo, AppSettings.captureCopies {
            copy(item)
            copied = true
        }
        postBanner(symbol: item.isVideo ? "video.fill" : "camera.viewfinder",
                   text: copied ? "Copied" : "Saved", image: preview)
        if !item.isVideo, notice == .needsScreenPermission {
            notice = nil
        }
    }

    private func postBanner(symbol: String, text: String, image: NSImage?) {
        ActivityCenter.shared.post(LiveActivity(moduleID: "capture", symbol: symbol, content: .text(text),
                                                tint: Self.tint, image: image, earWidth: 96, duration: .seconds(3)))
    }

    /// A small preview straight from the file, for the banner.
    private static func quickThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    // MARK: - The shelf

    /// Call from the Capture view's `.task`. Lists Brim's folder, and watches
    /// for macOS screenshots while the view is on screen.
    func whileVisible() async {
        viewers += 1
        idleTask?.cancel()
        idleTask = nil
        if viewers == 1 {
            refresh()
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        viewers -= 1
        guard viewers == 0 else { return }
        // Starting a Spotlight query costs more than keeping one, and the notch
        // is opened and closed all the time. Let it run a little longer.
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, viewers == 0 else { return }
            stopQuery()
            idleTask = nil
        }
    }

    @ObservationIgnored private var listedWith = ""

    /// Rescans when a setting that changes the list does.
    func settingsChanged() {
        let signature = "\(folder.path)|\(AppSettings.captureIncludesMac)|\(AppSettings.captureKeepDays)"
        guard signature != listedWith else { return }
        listedWith = signature
        guard viewers > 0 else { return }
        stopQuery()
        refresh()
    }

    private var cutoff: Date? {
        let days = AppSettings.captureKeepDays
        return days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
    }

    func refresh() {
        listedWith = "\(folder.path)|\(AppSettings.captureIncludesMac)|\(AppSettings.captureKeepDays)"
        let folder = folder
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan(folder) }.value
            brimItems = found
            merge()
        }
        startQuery()
    }

    nonisolated private static func scan(_ folder: URL) -> [CaptureItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentTypeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let type = values.contentType,
                  type.conforms(to: .image) || type.conforms(to: .movie) else { return nil }
            return CaptureItem(url: url, date: values.creationDate ?? .distantPast, fromMac: false)
        }
    }

    static func macScreenshotPredicate(since date: Date?) -> NSPredicate {
        if let date {
            return NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", date as NSDate)
        }
        return NSPredicate(format: "kMDItemIsScreenCapture == 1")
    }

    private func startQuery() {
        guard AppSettings.captureIncludesMac else {
            stopQuery()
            macItems = []
            merge()
            return
        }
        let scope = Self.macScreenshotFolder
        guard query == nil || queryFolder != scope else { return }
        stopQuery()
        let query = NSMetadataQuery()
        query.predicate = Self.macScreenshotPredicate(since: cutoff)
        query.searchScopes = [scope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.5
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(center.addObserver(forName: name, object: query, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.queryChanged() }
            })
        }
        self.query = query
        queryFolder = scope
        query.start()
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        queryFolder = nil
        queryObservers.forEach(NotificationCenter.default.removeObserver)
        queryObservers = []
    }

    private func queryChanged() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found: [CaptureItem] = []
        // Sorted newest first; hidden ones may be among them, so read a few more than shown.
        for index in 0..<min(query.resultCount, Self.limit * 3) {
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let date = result.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
            found.append(CaptureItem(url: URL(fileURLWithPath: path), date: date, fromMac: true))
        }
        macItems = found
        merge()
    }

    private func merge() {
        let cutoff = cutoff
        var seen = Set<String>()
        let next = (brimItems + macItems)
            .filter { seen.insert($0.id).inserted }
            .filter { item in hidden[item.id] == nil && (cutoff.map { item.date >= $0 } ?? true) }
            .sorted { $0.date > $1.date }
            .prefix(Self.limit)
        guard Array(next) != items else { return }
        withAnimation(Motion.switchModule) { items = Array(next) }
        let ids = Set(items.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
    }

    func loadThumbnail(for item: CaptureItem) {
        guard thumbnails[item.id] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 240, height: 150),
                                                   scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            let size = CGSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.thumbnails[id] = NSImage(cgImage: cgImage, size: size)
                }
            }
        }
    }

    // MARK: - Item actions

    func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func quickLook(_ item: CaptureItem) {
        QuickLookController.shared.show(item.url)
    }

    /// Images go on the clipboard as a picture and as a file; recordings as a file.
    func copy(_ item: CaptureItem) {
        let entry = NSPasteboardItem()
        if !item.isVideo {
            if item.url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: item.url) {
                entry.setData(data, forType: .png)
            } else if let tiff = NSImage(contentsOf: item.url)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
        }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
    }

    var canAirDrop: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    func airDrop(_ item: CaptureItem) {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [item.url]) else { return }
        service.perform(withItems: [item.url])
    }

    func addToShelf(_ item: CaptureItem) {
        ShelfService.shared.add([item.url])
    }

    /// Takes it off this shelf; the file stays where it is.
    func hide(_ item: CaptureItem) {
        hidden[item.id] = item.date
        // Forget ones that have aged off the shelf anyway, and keep the list short.
        if let cutoff {
            hidden = hidden.filter { $0.value >= cutoff }
        }
        if hidden.count > 500 {
            hidden = Dictionary(uniqueKeysWithValues: hidden.sorted { $0.value > $1.value }.prefix(500).map { ($0.key, $0.value) })
        }
        hiddenSaver.schedule()
        merge()
    }

    func moveToTrash(_ item: CaptureItem) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            brimItems.removeAll { $0.id == item.id }
            macItems.removeAll { $0.id == item.id }
            merge()
        } catch {
            notice = .failed("Couldn't move \(item.name) to the Trash. \(error.localizedDescription)")
        }
    }

    func tileHandlers(for item: CaptureItem) -> FileTileHandlers {
        FileTileHandlers(
            url: { item.url },
            thumbnail: { [weak self] in self?.thumbnails[item.id] },
            open: { [weak self] in self?.open(item) },
            reveal: { [weak self] in self?.reveal(item) },
            remove: { [weak self] in self?.hide(item) },
            removeTitle: "Remove from Captures",
            menu: { [weak self] in
                let menu = NSMenu()
                guard let self else { return menu }
                menu.addItem(ClosureMenuItem("Open") { self.open(item) })
                menu.addItem(ClosureMenuItem("Quick Look") { self.quickLook(item) })
                menu.addItem(ClosureMenuItem("Copy") { self.copy(item) })
                menu.addItem(ClosureMenuItem("Show in Finder") { self.reveal(item) })
                menu.addItem(.separator())
                if self.canAirDrop {
                    menu.addItem(ClosureMenuItem("AirDrop…") { self.airDrop(item) })
                }
                menu.addItem(ClosureMenuItem("Add to Shelf") { self.addToShelf(item) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Remove from Captures") { self.hide(item) })
                menu.addItem(ClosureMenuItem("Move to Trash") { self.moveToTrash(item) })
                return menu
            }
        )
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (items, thumbnails, recordingStarted, recordingTarget, notice)
        items = []
        thumbnails = [:]
        notice = nil
        for (index, sample) in Self.sampleFiles().enumerated() {
            let item = CaptureItem(url: sample.url, date: Date().addingTimeInterval(-Double(index) * 1500 - 120),
                                   fromMac: index == 2)
            items.append(item)
            thumbnails[item.id] = sample.image
        }
        body()
        (items, thumbnails, recordingStarted, recordingTarget, notice) = saved
    }

    func debugSetRecording(since start: Date?) {
        recordingStarted = start
        recordingTarget = start == nil ? nil : .screen
    }

    /// Made-up captures in a temporary folder, so samples never show real ones.
    private static func sampleFiles() -> [(url: URL, image: NSImage)] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrimSamples/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = "2026-09-17 at"
        let specs: [(String, [NSColor], Bool)] = [
            ("Screenshot \(day) 09.38.02.png", [NSColor(srgbRed: 0.18, green: 0.2, blue: 0.5, alpha: 1),
                                                NSColor(srgbRed: 0.95, green: 0.45, blue: 0.4, alpha: 1)], false),
            ("Screen Recording \(day) 09.12.40.mov", [NSColor(srgbRed: 0.05, green: 0.35, blue: 0.4, alpha: 1),
                                                      NSColor(srgbRed: 0.4, green: 0.85, blue: 0.7, alpha: 1)], true),
            ("Screenshot \(day) 08.47.15.png", [NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
                                                NSColor(srgbRed: 0.8, green: 0.84, blue: 0.92, alpha: 1)], false),
            ("Screenshot \(day) 08.20.51.png", [NSColor(srgbRed: 0.3, green: 0.12, blue: 0.4, alpha: 1),
                                                NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)], false),
            ("Screen Recording \(day) 07.58.09.mov", [NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                                                      NSColor(srgbRed: 0.3, green: 0.5, blue: 1, alpha: 1)], true),
        ]
        return specs.map { name, colors, isVideo in
            let url = folder.appendingPathComponent(name)
            let image = NSImage(size: NSSize(width: 240, height: 150), flipped: false) { rect in
                NSGradient(colors: colors)?.draw(in: rect, angle: -35)
                // A made-up app window.
                let window = NSRect(x: 34, y: 18, width: 172, height: 112)
                NSColor(white: isVideo ? 0.12 : 1, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: window, xRadius: 9, yRadius: 9).fill()
                for (dot, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: window.minX + 9 + CGFloat(dot) * 10, y: window.maxY - 13, width: 6, height: 6)).fill()
                }
                NSColor(white: isVideo ? 1 : 0, alpha: 0.18).setFill()
                for line in 0..<5 {
                    NSBezierPath(roundedRect: NSRect(x: window.minX + 14, y: window.maxY - 34 - CGFloat(line) * 14,
                                                     width: CGFloat(128 - line % 3 * 26), height: 6),
                                 xRadius: 3, yRadius: 3).fill()
                }
                return true
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                if isVideo {
                    FileManager.default.createFile(atPath: url.path, contents: Data())
                } else if let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
            }
            return (url, image)
        }
    }
    #endif
}
