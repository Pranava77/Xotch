import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts for the AI chat. Carbon's hot keys work from any app
/// without Accessibility permission, unlike a global key monitor.
@MainActor
enum GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case quickAsk = 1
        case askAboutScreen = 2

        var keyCode: UInt32 {
            switch self {
            case .quickAsk: UInt32(kVK_Space)
            case .askAboutScreen: UInt32(kVK_Return)
            }
        }

        var modifiers: UInt32 { UInt32(cmdKey | shiftKey) }

        var label: String {
            switch self {
            case .quickAsk: "⌘⇧Space"
            case .askAboutScreen: "⌘⇧↩"
            }
        }

        @MainActor var isEnabled: Bool {
            // Hiding the AI module in Settings switches its shortcuts off too.
            guard ModuleRegistry.visibleNow.contains(where: { $0.id == AIModule.moduleID }) else { return false }
            return switch self {
            case .quickAsk: AppSettings.aiQuickAskHotKey
            case .askAboutScreen: AppSettings.aiScreenHotKey
            }
        }

        @MainActor func run() {
            switch self {
            case .quickAsk: AIChatService.shared.quickAsk()
            case .askAboutScreen: AIChatService.shared.askAboutScreen()
            }
        }
    }

    private static var registered: [Action: EventHotKeyRef] = [:]
    private static var handler: EventHandlerRef?
    /// Shortcuts another app already holds, for Settings to explain.
    private(set) static var taken: Set<Action> = []

    private static let signature: OSType = 0x58_4F_54_43 // "XOTC"

    /// Registers what Settings asks for and drops the rest. Cheap to call often.
    static func update() {
        installHandler()
        for action in Action.allCases {
            let wanted = action.isEnabled
            if wanted, registered[action] == nil {
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(action.keyCode, action.modifiers,
                                                 EventHotKeyID(signature: signature, id: action.rawValue),
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    registered[action] = ref
                    taken.remove(action)
                } else {
                    taken.insert(action)
                }
            } else if !wanted, let ref = registered[action] {
                UnregisterEventHotKey(ref)
                registered[action] = nil
                taken.remove(action)
            } else if !wanted {
                taken.remove(action)
            }
        }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            let id = hotKey.id
            Task { @MainActor in
                Action(rawValue: id)?.run()
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
