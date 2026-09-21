import AppKit
import MetricKit
import Observation

/// Opt-in crash reporting that never sends anything by itself.
///
/// - A marker file notes that Xotch is running. If it's still there at the next
///   launch and macOS wrote a crash report for Xotch since, the last session crashed.
/// - With sharing turned on, MetricKit diagnostics are kept on disk as well.
/// - The person decides whether to email a report; nothing is uploaded.
@MainActor
@Observable
final class Diagnostics {
    static let shared = Diagnostics()
    nonisolated static let shareKey = "shareDiagnostics"
    /// Where "Email Report…" and "Send Feedback…" go. Set before the beta.
    nonisolated static let supportAddress = ""

    /// A crash report from the previous session, if there is one.
    private(set) var lastCrashReport: URL?

    @ObservationIgnored private let marker = Storage.directory.appendingPathComponent("session.lock")
    @ObservationIgnored private let folder = Storage.folder("Diagnostics")
    @ObservationIgnored private var subscriber: MetricSubscriber?

    var isSharingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.shareKey)
    }

    static var reportsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    func sessionStarted() {
        lastCrashReport = Self.crashReport(markerURL: marker, reportsFolder: Self.reportsFolder)
        try? String(Date().timeIntervalSince1970).write(to: marker, atomically: true, encoding: .utf8)
        settingsChanged()
    }

    func sessionEnded() {
        try? FileManager.default.removeItem(at: marker)
    }

    func settingsChanged() {
        if isSharingEnabled, subscriber == nil {
            let subscriber = MetricSubscriber(folder: folder)
            MXMetricManager.shared.add(subscriber)
            self.subscriber = subscriber
        } else if !isSharingEnabled, let subscriber {
            MXMetricManager.shared.remove(subscriber)
            self.subscriber = nil
        }
    }

    /// If the marker survived and macOS wrote a Xotch crash report after it, returns that report.
    nonisolated static func crashReport(markerURL: URL, reportsFolder: URL) -> URL? {
        guard let text = try? String(contentsOf: markerURL, encoding: .utf8),
              let started = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let startDate = Date(timeIntervalSince1970: started)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let reports = (try? FileManager.default.contentsOfDirectory(at: reportsFolder, includingPropertiesForKeys: keys)) ?? []
        return reports
            .filter { $0.lastPathComponent.hasPrefix("Xotch") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      date >= startDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Actions

    func revealCrashReport() {
        guard let lastCrashReport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastCrashReport])
    }

    func emailCrashReport() {
        guard let lastCrashReport else { return }
        compose(subject: "Xotch crash report (\(Self.versionString))",
                body: "What were you doing when Xotch quit?\n\n\n\(Self.systemSummary)",
                attachments: [lastCrashReport])
    }

    func dismissCrashReport() {
        lastCrashReport = nil
    }

    func sendFeedback() {
        compose(subject: "Xotch feedback (\(Self.versionString))",
                body: "What happened, and what did you expect?\n\n\n\(Self.systemSummary)",
                attachments: [])
    }

    private func compose(subject: String, body: String, attachments: [URL]) {
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = Self.supportAddress.isEmpty ? [] : [Self.supportAddress]
            service.subject = subject
            let items: [Any] = [body] + attachments
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return
            }
        }
        // No mail account set up: fall back to a mailto link without the attachment.
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportAddress
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var systemSummary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelName = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        return """
        Xotch \(versionString)
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Mac \(modelName)
        Displays: \(NSScreen.screens.count)
        """
    }
}

/// Saves MetricKit diagnostic payloads (crashes, hangs) as JSON, keeping the newest 20.
private final class MetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let name = "diagnostic-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try? payload.jsonRepresentation().write(to: folder.appendingPathComponent(name))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(20) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
