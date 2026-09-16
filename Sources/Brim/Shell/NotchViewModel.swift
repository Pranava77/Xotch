import SwiftUI
import Observation

enum NotchPhase: Equatable {
    case closed, peek, open
}

/// State for the notch on one screen. "Activity" isn't a phase of its own:
/// it's what a closed or peeking notch shows while ActivityCenter has something.
@MainActor
@Observable
final class NotchViewModel {
    var phase: NotchPhase = .closed
    var isPinned = false
    var selectedModuleID: String
    /// Which side the next module slides in from.
    var switchEdge: Edge = .trailing

    let geometry: NotchGeometry
    let activities = ActivityCenter.shared

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        selectedModuleID = ModuleRegistry.visibleNow.first?.id ?? ModuleRegistry.all[0].id
    }

    var closedSize: CGSize { geometry.notchSize }

    var showsActivity: Bool {
        phase != .open && activities.current != nil
    }

    var bodySize: CGSize {
        if phase == .open { return Layout.openSize }
        var size = closedSize
        if showsActivity {
            size.width += Layout.earWidth * 2
        }
        if phase == .peek {
            size.width += Layout.peekGrowth.width
            size.height += Layout.peekGrowth.height
        }
        return size
    }

    var shoulder: CGFloat {
        phase == .open ? Layout.openShoulder : Layout.closedShoulder
    }

    var cornerRadius: CGFloat {
        switch phase {
        case .open: 26
        case .peek: 14
        case .closed: showsActivity ? 14 : 10
        }
    }

    var screenRect: NSRect {
        geometry.screenRect(bodySize: bodySize, shoulder: shoulder)
    }
}
