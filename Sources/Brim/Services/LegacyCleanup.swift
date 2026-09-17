import Foundation
import Security

/// Removes what the Revenue, Analytics and Weather modules left behind:
/// their saved API keys, cached files and settings. Runs once.
enum LegacyCleanup {
    private static let doneKey = "cleanup.removedConnectedModules"
    private static let removedModules: Set<String> = ["revenue", "analytics", "weather"]
    private static let keychainAccounts = ["revenue.stripe", "revenue.polar", "revenue.dodo", "analytics.datafast"]
    private static let files = ["weather.json", "weather-place.json"]
    private static let settings = [
        "revenue.showTotal", "revenue.stripe.testMode", "revenue.polar.testMode", "revenue.dodo.testMode",
        "celebrateSales", "saleSound",
    ]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        for account in keychainAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.pranava.brim",
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        for file in files {
            try? FileManager.default.removeItem(at: Storage.directory.appendingPathComponent(file))
        }
        settings.forEach(defaults.removeObject)
        for key in [SettingsKey.moduleOrder, SettingsKey.hiddenModules] {
            guard let list = defaults.string(forKey: key) else { continue }
            defaults.set(strippingRemoved(from: list), forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// "home,revenue,media" → "home,media"
    static func strippingRemoved(from list: String) -> String {
        list.split(separator: ",").map(String.init).filter { !removedModules.contains($0) }.joined(separator: ",")
    }
}
