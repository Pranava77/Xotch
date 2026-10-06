import SwiftUI

/// Every feature in the notch is a module: a tab in the header and a view for
/// the open notch. `start()` and `stop()` bracket background work (media,
/// clipboard) and follow whether the module is shown in Settings; anything that
/// only matters on screen should run from the view's `.task` instead.
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    /// Tints the open notch while this module is showing.
    var tint: Color? { get }
    /// How much room the open notch gives this module.
    var openSize: CGSize { get }
    func expandedView() -> AnyView
    func start()
    func stop()
}

extension NotchModule {
    var tint: Color? { nil }
    var openSize: CGSize { Layout.openSize }
    func start() {}
    func stop() {}

    var info: ModuleInfo {
        ModuleInfo(id: id, title: title, symbol: symbol)
    }
}

struct ModuleInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
}

@MainActor
enum ModuleRegistry {
    static let all: [any NotchModule] = [
        HomeModule(),
        AIModule(),
        DictationModule(),
        MediaModule(),
        CalendarModule(),
        TimersModule(),
        ClipboardModule(),
        ShelfModule(),
        CaptureModule(),
        TodosModule(),
        NotesModule(),
        StatsModule(),
        ClaudeModule(),
    ]

    static func module(id: String) -> (any NotchModule)? {
        all.first { $0.id == id }
    }

    /// All modules in the user's order; ones missing from the saved order go last.
    static func ordered(order: String) -> [any NotchModule] {
        var result = order.split(separator: ",").compactMap { module(id: String($0)) }
        for module in all where !result.contains(where: { $0.id == module.id }) {
            result.append(module)
        }
        return result
    }

    static func visible(order: String, hidden: String) -> [any NotchModule] {
        let hiddenIDs = Set(hidden.split(separator: ",").map(String.init))
        let visible = ordered(order: order).filter { !hiddenIDs.contains($0.id) }
        return visible.isEmpty ? all : visible
    }

    static var visibleNow: [any NotchModule] {
        visible(order: AppSettings.moduleOrder, hidden: AppSettings.hiddenModules)
    }

    private static var running: Set<String> = []

    /// Starts modules that are shown and stops ones the user hid.
    static func syncRunning() {
        let shown = Set(visibleNow.map { $0.id })
        for module in all {
            if shown.contains(module.id), !running.contains(module.id) {
                module.start()
                running.insert(module.id)
            } else if !shown.contains(module.id), running.contains(module.id) {
                module.stop()
                running.remove(module.id)
            }
        }
    }
}
