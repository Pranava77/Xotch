import AppKit
import QuickLookThumbnailing
import SwiftUI
import Observation

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Bookmark, so the item follows the file if it's moved or renamed.
    var bookmark: Data
    var name: String
    var added: Date
}

/// A place to park files for a while. Keeps references, not copies, and
/// forgets items after the expiry set in Settings.
@MainActor
@Observable
final class ShelfService {
    static let shared = ShelfService()

    private(set) var items: [ShelfItem]
    private(set) var thumbnails: [UUID: NSImage] = [:]
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private lazy var saver = SaveScheduler { [weak self] in
        guard let self else { return }
        Storage.save(self.items, to: "shelf.json")
    }

    init() {
        items = Storage.load([ShelfItem].self, from: "shelf.json") ?? []
    }

    func start() {
        removeExpired()
        guard expiryTimer == nil else { return }
        let timer = Timer(timeInterval: 600, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.removeExpired() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    func url(for item: ShelfItem) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale)
    }

    func add(_ urls: [URL]) {
        let fresh = urls.compactMap { url -> ShelfItem? in
            guard !items.contains(where: { self.url(for: $0) == url }),
                  let bookmark = try? url.bookmarkData() else { return nil }
            return ShelfItem(bookmark: bookmark, name: url.lastPathComponent, added: Date())
        }
        guard !fresh.isEmpty else { return }
        withAnimation(Motion.switchModule) { items.insert(contentsOf: fresh, at: 0) }
        saver.schedule()
        Haptics.tick()
        let label = fresh.count == 1 ? "1 file" : "\(fresh.count) files"
        ActivityCenter.shared.post(LiveActivity(moduleID: "shelf", symbol: "tray.and.arrow.down.fill",
                                                content: .text(label), tint: .cyan, duration: .seconds(2)))
    }

    func remove(_ item: ShelfItem) {
        withAnimation(Motion.switchModule) { items.removeAll { $0.id == item.id } }
        thumbnails[item.id] = nil
        saver.schedule()
    }

    func removeAll() {
        withAnimation(Motion.switchModule) { items.removeAll() }
        thumbnails.removeAll()
        saver.schedule()
    }

    func open(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: ShelfItem) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var canAirDrop: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    func airDrop(_ items: [ShelfItem]) {
        let urls = items.compactMap(url(for:))
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { return }
        service.perform(withItems: urls)
    }

    /// Loads a Quick Look thumbnail once, falling back to the file icon.
    func loadThumbnail(for item: ShelfItem) {
        guard thumbnails[item.id] == nil, let url = url(for: item) else { return }
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
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

    /// By date only: resolving bookmarks at launch could trigger a folder-access
    /// prompt (Desktop, Documents) before the person opens the Shelf.
    private func removeExpired() {
        let hours = AppSettings.shelfExpiryHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        let kept = items.filter { $0.added > cutoff }
        guard kept.count != items.count else { return }
        items = kept
        saver.schedule()
    }

    /// Drops items whose file is gone. Called when the Shelf is shown.
    func removeMissing() {
        let kept = items.filter { item in
            guard let url = url(for: item) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard kept.count != items.count else { return }
        withAnimation(Motion.switchModule) { items = kept }
        saver.schedule()
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (items, thumbnails)
        items = []
        for url in Self.sampleFiles() {
            guard let bookmark = try? url.bookmarkData() else { continue }
            let item = ShelfItem(bookmark: bookmark, name: url.lastPathComponent, added: Date())
            items.append(item)
            thumbnails[item.id] = url.pathExtension == "png"
                ? NSImage(contentsOf: url)
                : NSWorkspace.shared.icon(forFile: url.path)
        }
        body()
        (items, thumbnails) = saved
    }

    /// Made-up files in a temporary folder, so samples never show real ones.
    private static func sampleFiles() -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrimSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("Launch plan.pdf")
        let png = folder.appendingPathComponent("Hero shot.png")
        let text = folder.appendingPathComponent("Changelog.md")
        if !FileManager.default.fileExists(atPath: pdf.path) {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            if let context = CGContext(pdf as CFURL, mediaBox: &box, nil) {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.04, alpha: 1))
                context.fill(CGRect(x: 60, y: 640, width: 300, height: 40))
                context.setFillColor(CGColor(gray: 0.8, alpha: 1))
                for line in 0..<14 {
                    context.fill(CGRect(x: 60, y: 580 - CGFloat(line) * 28, width: CGFloat(420 - line % 3 * 60), height: 10))
                }
                context.endPDFPage()
                context.closePDF()
            }
        }
        if !FileManager.default.fileExists(atPath: png.path) {
            let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
                NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.2, blue: 0.75, alpha: 1),
                                    NSColor(srgbRed: 1, green: 0.5, blue: 0.35, alpha: 1)])?.draw(in: rect, angle: 30)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 90, y: 150, width: 140, height: 50), xRadius: 16, yRadius: 16).fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? data.write(to: png)
            }
        }
        if !FileManager.default.fileExists(atPath: text.path) {
            try? "# Changelog\n\n## 0.2.0\n- Themes\n".write(to: text, atomically: true, encoding: .utf8)
        }
        return [pdf, png, text]
    }
    #endif
}
