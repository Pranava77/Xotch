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
        let paths = ["/System/Applications/Music.app", "/System/Library/CoreServices/Finder.app", "/Applications/Safari.app"]
        items = paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let bookmark = try? url.bookmarkData() else { return nil }
            return ShelfItem(bookmark: bookmark, name: url.lastPathComponent, added: Date())
        }
        body()
        (items, thumbnails) = saved
    }
    #endif
}
