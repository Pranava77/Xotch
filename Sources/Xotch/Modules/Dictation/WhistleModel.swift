import CryptoKit
import Foundation
import Observation

/// The Whistle speech model (16.9 MB, Apache-2.0, by Cactus Compute). It isn't
/// bundled: Settings › Dictation downloads it once, from a pinned revision, and
/// checks it against a known SHA-256 before using it.
@MainActor
@Observable
final class WhistleModel {
    static let shared = WhistleModel()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State

    nonisolated static let fileURL: URL = Storage.directory
        .appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent("whistle.cact")

    private nonisolated static let source = URL(string:
        "https://huggingface.co/Cactus-Compute/whistle/resolve/b358ddadd89b7a713b5aa131f23032d3cca1b251/whistle.cact")!
    private nonisolated static let sha256 = "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb"
    nonisolated static let size: Int64 = 16_919_407

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        state = FileManager.default.fileExists(atPath: Self.fileURL.path) ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            let result = await Self.fetch { progress in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(progress) }
                }
            }
            guard let self else { return }
            self.task = nil
            switch result {
            case .success: state = .ready
            case .failure(let error): state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .missing
    }

    func remove() {
        WhistleEngine.shared.shutDown()
        try? FileManager.default.removeItem(at: Self.fileURL)
        state = .missing
    }

    private struct DownloadError: LocalizedError {
        let errorDescription: String?
    }

    /// Streams the file to disk, hashing as it goes, and only moves it into
    /// place once the hash matches.
    private nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async -> Result<Void, Error> {
        let folder = fileURL.deletingLastPathComponent()
        let partial = folder.appendingPathComponent("whistle.cact.download")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (bytes, response) = try await URLSession.shared.bytes(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw DownloadError(errorDescription: "The download server didn't answer. Try again later.")
            }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var hasher = SHA256()
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            var received: Int64 = 0
            var reported = -1
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 1 << 16 {
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    let percent = Int(Double(received) / Double(size) * 100)
                    if percent != reported {
                        reported = percent
                        progress(min(Double(received) / Double(size), 1))
                    }
                }
            }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            try handle.close()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw DownloadError(errorDescription: "The download didn't match the model it should be. Try again.")
            }
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: partial, to: fileURL)
            return .success(())
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partial)
            return .failure(DownloadError(errorDescription: "Cancelled."))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .failure(error)
        }
    }
}
