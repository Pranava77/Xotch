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
    static let retroSounds = "retroSounds"
    static let mediaKeysHUD = "mediaKeysHUD"
    static let retroSoundVolume = "retroSoundVolume"
    static let display = "displayChoice"
    static let moduleOrder = "moduleOrder"
    static let hiddenModules = "hiddenModules"
    static let clipboardHistory = "clipboardHistory"
    static let mediaActivity = "mediaActivity"
    static let shelfExpiryHours = "shelfExpiryHours"
    static let hideInFullScreen = "hideInFullScreen"
    static let scrollForVolume = "scrollForVolume"
    static let adiyogiEar = "adiyogiEar"
    static let celebrateFocus = "celebrateFocus"
    static let realAudioLevels = "realAudioLevels"
    static let downloadProgress = "downloadProgress"
    static let ledTitle = "ledTitle"
    static let captureFolder = "captureFolder"
    static let captureCopies = "captureCopiesToClipboard"
    static let captureIncludesMac = "captureIncludesMacScreenshots"
    static let captureSystemAudio = "captureSystemAudio"
    static let captureMicrophone = "captureMicrophone"
    static let captureShowsClicks = "captureShowsClicks"
    static let captureKeepDays = "captureKeepDays"
    // The key strings still say "life": people who changed them keep their choice.
    static let todoRollover = "lifeRollover"
    static let todoActivity = "lifeActivity"
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
            SettingsKey.retroSounds: false,
            SettingsKey.mediaKeysHUD: false,
            SettingsKey.retroSoundVolume: 0.5,
            SettingsKey.display: DisplayChoice.all,
            SettingsKey.moduleOrder: "",
            SettingsKey.hiddenModules: "",
            SettingsKey.clipboardHistory: true,
            SettingsKey.mediaActivity: true,
            SettingsKey.shelfExpiryHours: 24,
            SettingsKey.hideInFullScreen: true,
            SettingsKey.scrollForVolume: true,
            SettingsKey.adiyogiEar: true,
            SettingsKey.celebrateFocus: true,
            SettingsKey.realAudioLevels: false,
            SettingsKey.downloadProgress: false,
            SettingsKey.ledTitle: true,
            SettingsKey.captureFolder: "",
            SettingsKey.captureCopies: true,
            SettingsKey.captureIncludesMac: true,
            SettingsKey.captureSystemAudio: true,
            SettingsKey.captureMicrophone: false,
            SettingsKey.captureShowsClicks: false,
            SettingsKey.captureKeepDays: 7,
            SettingsKey.todoRollover: true,
            SettingsKey.todoActivity: false,
            Diagnostics.shareKey: false,
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

    /// Volume and brightness keys show in the notch instead of macOS's popup.
    /// Needs Accessibility permission, so it is off until asked for.
    static var mediaKeysHUD: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.mediaKeysHUD)
    }

    /// Arcade sound effects. Off until asked for.
    static var retroSounds: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.retroSounds)
    }

    static var retroSoundVolume: Double {
        UserDefaults.standard.double(forKey: SettingsKey.retroSoundVolume)
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

    static var hideInFullScreen: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.hideInFullScreen)
    }

    static var scrollForVolume: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.scrollForVolume)
    }

    /// Adiyogi in the left ear of the closed notch.
    static var adiyogiEar: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.adiyogiEar)
    }

    /// 0 means keep shelf items until removed.
    static var shelfExpiryHours: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.shelfExpiryHours)
    }

    // MARK: - Capture

    /// Where Xotch saves screenshots and recordings. Empty means ~/Pictures/Xotch.
    static var captureFolder: String {
        UserDefaults.standard.string(forKey: SettingsKey.captureFolder) ?? ""
    }

    static var captureCopies: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.captureCopies)
    }

    /// Also list screenshots taken with ⌘⇧3, ⌘⇧4 and ⌘⇧5.
    static var captureIncludesMac: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.captureIncludesMac)
    }

    static var captureSystemAudio: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.captureSystemAudio)
    }

    static var captureMicrophone: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.captureMicrophone)
    }

    static var captureShowsClicks: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.captureShowsClicks)
    }

    /// 0 means list captures of any age.
    static var captureKeepDays: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.captureKeepDays)
    }

    // MARK: - To-dos

    /// Unfinished to-dos move to today at the first launch of a new day.
    static var todoRollover: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.todoRollover)
    }

    /// Shows how many to-dos are left beside the notch.
    static var todoActivity: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.todoActivity)
    }
}
