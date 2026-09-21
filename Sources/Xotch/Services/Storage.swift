import Foundation


/// Small JSON files in ~/Library/Application Support/Xotch. Nothing leaves the Mac.
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Xotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func folder(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    static func save<Value: Encodable>(_ value: Value, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

/// Coalesces rapid changes into one save a moment later.
@MainActor
final class SaveScheduler {
    private var task: Task<Void, Never>?
    private let delay: Duration
    private let save: () -> Void

    init(delay: Duration = .milliseconds(600), save: @escaping () -> Void) {
        self.delay = delay
        self.save = save
    }

    func schedule() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.delay)
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    func flush() {
        task?.cancel()
        save()
    }
}

/// A thread with a run loop for work that mustn't block the main one, like
/// starting an `NSMetadataQuery`: macOS can hold that call open while it asks
/// the person for access to the folder being searched.
final class SpotlightRunner: NSObject, @unchecked Sendable {
    static let shared = SpotlightRunner()
    private let thread: Thread

    private final class Box: NSObject {
        let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    override init() {
        thread = Thread {
            Thread.current.name = "com.pranava.xotch.spotlight"
            let runLoop = RunLoop.current
            runLoop.add(NSMachPort(), forMode: .default)
            while !Thread.current.isCancelled {
                runLoop.run(mode: .default, before: .distantFuture)
            }
        }
        super.init()
        thread.start()
    }

    func async(_ work: @escaping @Sendable () -> Void) {
        perform(#selector(run(_:)), on: thread, with: Box(work), waitUntilDone: false)
    }

    @objc private func run(_ box: Box) {
        box.work()
    }
}
