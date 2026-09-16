import SwiftUI

/// Every feature in the notch is a module: an icon in the switcher and a
/// view for the open notch. `start()` and `stop()` bracket any background work,
/// so a module costs nothing while it's hidden.
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    func expandedView() -> AnyView
    func start()
    func stop()
}

extension NotchModule {
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
        MediaModule(),
        TimersModule(),
        ShelfModule(),
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
}
