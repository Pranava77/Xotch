import SwiftUI

/// Every feature in the notch is a module: an icon in the dock and a view for
/// the open notch. `start()` runs once at launch for modules that need to
/// listen in the background (media, clipboard); anything that only matters on
/// screen should run from the view's `.task` instead, so it stops when hidden.
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    /// Tints the open notch while this module is showing.
    var tint: Color? { get }
    func expandedView() -> AnyView
    func start()
}

extension NotchModule {
    var tint: Color? { nil }
    func start() {}

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
        MediaModule(),
        CalendarModule(),
        TimersModule(),
        ClipboardModule(),
        ShelfModule(),
        NotesModule(),
        StatsModule(),
        WeatherModule(),
        RevenueModule(),
        AnalyticsModule(),
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

    static func startAll() {
        all.forEach { $0.start() }
    }
}
