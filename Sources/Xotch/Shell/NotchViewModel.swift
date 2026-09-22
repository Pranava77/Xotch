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
    /// Sideways stretch while swiping past the first or last module.
    var rubberBand: CGFloat = 0
    /// Goes up by one for each drop on the notch; the ripple plays from `dropPoint`.
    var dropCount = 0
    var dropPoint: CGPoint = .zero
    let palette = CommandPaletteState()

    let geometry: NotchGeometry
    let activities = ActivityCenter.shared

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        selectedModuleID = ModuleRegistry.visibleNow.first?.id ?? ModuleRegistry.all[0].id
    }

    var closedSize: CGSize { geometry.notchSize }

    /// False when the notch is drawn rather than cut out of the display.
    var hasHardwareNotch: Bool { geometry.hasHardwareNotch }

    /// The selected module's room, kept inside the screen so a wide module
    /// still fits a small display.
    var openSize: CGSize {
        let asked = ModuleRegistry.module(id: selectedModuleID)?.openSize ?? Layout.openSize
        let screen = geometry.screenFrame
        return CGSize(width: min(asked.width, max(Layout.openSize.width, screen.width - 80)),
                      height: min(asked.height, max(Layout.openSize.height, screen.height * 0.62)))
    }

    var showsActivity: Bool {
        phase != .open && activities.current != nil
    }

    var bodySize: CGSize {
        if phase == .open { return openSize }
        var size = closedSize
        if showsActivity, let activity = activities.current {
            size.width += activity.earWidth * 2
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
