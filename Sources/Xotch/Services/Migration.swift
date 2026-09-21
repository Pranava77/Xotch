import Foundation

/// Xotch was called Brim while it was being built. Anyone updating from one of
/// those builds keeps everything: their notes, to-dos, arcs, clipboard history,
/// shelf and settings all move across on the first launch under the new name.
///
/// Runs once, before anything reads `Storage` or the settings.
enum Migration {
    private static let doneKey = "migration.renamedFromBrim"
    private static let oldName = "Brim"
    private static let oldBundleID = "com.pranava.brim"
    private static let oldHookMarker = "brim-claude-hook"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        moveFiles()
        copySettings()
        refreshClaudeHook()
    }

    /// ~/Library/Application Support/Brim → …/Xotch, keeping anything already
    /// written under the new name.
    private static func moveFiles() {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        guard manager.fileExists(atPath: old.path) else { return }
        let new = base.appendingPathComponent("Xotch", isDirectory: true)
        if !manager.fileExists(atPath: new.path) {
            try? manager.moveItem(at: old, to: new)
            return
        }
        for item in (try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            let target = new.appendingPathComponent(item.lastPathComponent)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.moveItem(at: item, to: target)
        }
        // Don't leave an empty folder from the old name behind.
        if (try? manager.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
            try? manager.removeItem(at: old)
        }
    }

    /// The bundle identifier changed too, so settings live in a new file. Copy
    /// the old one's keys, without touching anything already set under Xotch.
    private static func copySettings() {
        guard let stored = oldSettings() else { return }
        let defaults = UserDefaults.standard
        let mine = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for (key, value) in stored where mine[key] == nil && key != doneKey {
            defaults.set(value, forKey: key)
        }
    }

    static func oldSettings() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/Preferences/\(oldBundleID).plist")
        if let stored = NSDictionary(contentsOf: plist) as? [String: Any], !stored.isEmpty {
            return stored
        }
        // Sandboxless apps sometimes only have it through the defaults system.
        return UserDefaults(suiteName: oldBundleID)?.persistentDomain(forName: oldBundleID)
    }

    /// An installed Claude Code hook points at the old socket path, so it would
    /// quietly stop working. Put the new one in its place.
    private static func refreshClaudeHook() {
        let url = ClaudeHookInstaller.settingsURL
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(oldHookMarker) else { return }
        try? ClaudeHookInstaller.uninstall(at: url, marker: oldHookMarker)
        try? ClaudeHookInstaller.install(at: url)
    }
}
