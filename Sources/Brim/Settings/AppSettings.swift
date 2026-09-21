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
    static let hideInFullScreen = "hideInFullScreen"
    static let scrollForVolume = "scrollForVolume"
    static let showMascot = "showMascot"
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
    static let weekStartsMonday = "weekStartsMonday"
    static let lifeRollover = "lifeRollover"
    static let lifeActivity = "lifeActivity"
    static let lifeEveningNudge = "lifeEveningNudge"
    static let lifeNudgeMinutes = "lifeNudgeMinutes"
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
            SettingsKey.hideInFullScreen: true,
            SettingsKey.scrollForVolume: true,
            SettingsKey.showMascot: true,
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
            SettingsKey.weekStartsMonday: true,
            SettingsKey.lifeRollover: true,
            SettingsKey.lifeActivity: false,
            SettingsKey.lifeEveningNudge: false,
            SettingsKey.lifeNudgeMinutes: 21 * 60,
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

    /// 0 means keep shelf items until removed.
    static var shelfExpiryHours: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.shelfExpiryHours)
    }

    // MARK: - Capture

    /// Where Brim saves screenshots and recordings. Empty means ~/Pictures/Brim.
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

    // MARK: - Life

    static var weekStartsMonday: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.weekStartsMonday)
    }

    /// Unfinished tasks move to today at the first launch of a new day.
    static var lifeRollover: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.lifeRollover)
    }

    /// Shows how many to-dos are left beside the notch.
    static var lifeActivity: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.lifeActivity)
    }

    static var lifeEveningNudge: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.lifeEveningNudge)
    }

    /// Minutes after midnight for the evening nudge.
    static var lifeNudgeMinutes: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.lifeNudgeMinutes)
    }
}
