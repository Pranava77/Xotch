import Foundation

enum OpenBehavior: String, CaseIterable, Identifiable {
    case hover, click

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hover: "Hover"
        case .click: "Click"
        }
    }
}

/// UserDefaults keys. SwiftUI views read the same keys through @AppStorage.
enum SettingsKey {
    static let openBehavior = "openBehavior"
    static let hoverDelay = "hoverDelayMs"
    static let haptics = "hapticsEnabled"
    static let display = "displayChoice"
    static let moduleOrder = "moduleOrder"
    static let hiddenModules = "hiddenModules"
    static let clipboardHistory = "clipboardHistory"
    static let mediaActivity = "mediaActivity"
    static let shelfExpiryHours = "shelfExpiryHours"
}

enum DisplayChoice {
    static let automatic = "auto"
    static let all = "all"
    private static let namePrefix = "name:"

    static func named(_ name: String) -> String { namePrefix + name }

    static func screenName(in choice: String) -> String? {
        choice.hasPrefix(namePrefix) ? String(choice.dropFirst(namePrefix.count)) : nil
    }
}

/// Typed read access for code outside SwiftUI views.
enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.openBehavior: OpenBehavior.hover.rawValue,
            SettingsKey.hoverDelay: 150.0,
            SettingsKey.haptics: true,
            SettingsKey.display: DisplayChoice.automatic,
            SettingsKey.moduleOrder: "",
            SettingsKey.hiddenModules: "",
            SettingsKey.clipboardHistory: true,
            SettingsKey.mediaActivity: true,
            SettingsKey.shelfExpiryHours: 24,
        ])
    }

    static var openBehavior: OpenBehavior {
        OpenBehavior(rawValue: UserDefaults.standard.string(forKey: SettingsKey.openBehavior) ?? "") ?? .hover
    }

    static var hoverDelay: Duration {
        .milliseconds(Int(UserDefaults.standard.double(forKey: SettingsKey.hoverDelay)))
    }

    static var hapticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.haptics)
    }

    static var displayChoice: String {
        UserDefaults.standard.string(forKey: SettingsKey.display) ?? DisplayChoice.automatic
    }

    static var moduleOrder: String {
        UserDefaults.standard.string(forKey: SettingsKey.moduleOrder) ?? ""
    }

    static var hiddenModules: String {
        UserDefaults.standard.string(forKey: SettingsKey.hiddenModules) ?? ""
    }

    static var clipboardHistory: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.clipboardHistory)
    }

    static var mediaActivity: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.mediaActivity)
    }

    /// 0 means keep shelf items until removed.
    static var shelfExpiryHours: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.shelfExpiryHours)
    }
}
