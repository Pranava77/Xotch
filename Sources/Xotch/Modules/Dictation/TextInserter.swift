import AppKit
import Carbon.HIToolbox

/// Puts dictated text where you're typing: on the clipboard for a moment,
/// pasted with ⌘V, then the clipboard is put back as it was. The text is
/// marked transient, so clipboard history (Xotch's and others') skips it.
/// Posting ⌘V needs Accessibility; without it the text is left on the
/// clipboard to paste yourself.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        case inserted
        case copied
        /// A password field has the keyboard; nothing was typed or copied.
        case refused
    }

    /// When the notch has the keyboard (you clicked its microphone), it steps
    /// aside first so the text goes to the app you were in. A text field in
    /// the notch, like the AI chat's input, keeps it.
    static func insertWhereTyping(_ text: String, paste: Bool) async -> Outcome {
        if let window = NSApp.keyWindow, window is NotchPanel, !(window.firstResponder is NSTextView) {
            ScreenManager.shared.closeAll()
            try? await Task.sleep(for: .milliseconds(300))
        }
        return insert(text, paste: paste)
    }

    static func insert(_ text: String, paste: Bool) -> Outcome {
        guard !text.isEmpty else { return .copied }
        if IsSecureEventInputEnabled() { return .refused }
        let pasteboard = NSPasteboard.general
        guard paste, AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copied
        }
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let change = pasteboard.changeCount

        postPaste()

        // Give the app time to read it, then put the clipboard back, unless
        // something else has been copied since.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard pasteboard.changeCount == change else { return }
            restore(saved, to: pasteboard)
        }
        return .inserted
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Every item and type on the clipboard, so it can be put back exactly.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type] = data }
            }
            return types
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            // Putting the old clipboard back isn't a new copy.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return item
        }
        pasteboard.writeObjects(items)
    }
}
