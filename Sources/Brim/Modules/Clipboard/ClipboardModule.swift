import SwiftUI

@MainActor
final class ClipboardModule: NotchModule {
    let id = "clipboard"
    let title = "Clipboard"
    let symbol = "doc.on.clipboard"
    func expandedView() -> AnyView { AnyView(ClipboardView()) }
    func start() { ClipboardService.shared.start() }
    func stop() { ClipboardService.shared.stop() }
}

private struct ClipboardView: View {
    @State private var query = ""
    @AppStorage(SettingsKey.clipboardHistory) private var historyOn = true
    private var clipboard: ClipboardService { .shared }

    private var filtered: [ClipItem] {
        let sorted = clipboard.items.filter(\.pinned) + clipboard.items.filter { !$0.pinned }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.preview.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NotchSearchField(placeholder: "Search clipboard", text: $query)

                Button("Clear") { clipboard.clearUnpinned() }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(clipboard.items.allSatisfy(\.pinned))
                    .help("Remove everything except pinned items")
            }

            if clipboard.access == .denied {
                EmptyStateView(symbol: "hand.raised",
                               title: "Clipboard access is turned off",
                               message: "macOS is set to block Brim from reading what you copy. Allow Brim under Paste in Privacy & Security to keep a history.",
                               buttonTitle: "Open Privacy & Security") { ClipboardService.openPrivacySettings() }
            } else if clipboard.access == .needsPermission && historyOn {
                EmptyStateView(symbol: "doc.on.clipboard",
                               title: "Allow Brim to see what you copy",
                               message: "macOS asks before apps read the clipboard. Press Allow, choose Allow when macOS asks, then set Brim to always allow in Privacy & Security so history works in the background.",
                               buttonTitle: "Allow") { clipboard.requestAccess() }
            } else if !historyOn {
                EmptyStateView(symbol: "doc.on.clipboard",
                               title: "Clipboard history is off",
                               message: "Turn it on to keep what you copy, on this Mac only.",
                               buttonTitle: "Turn on") { historyOn = true }
            } else if clipboard.items.isEmpty {
                EmptyStateView(symbol: "doc.on.clipboard",
                               title: "Nothing copied yet",
                               message: "Copy some text, a link, an image or files and it shows up here. Passwords from password managers are skipped.")
            } else if filtered.isEmpty {
                Text("No matches for \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                NotchScroll {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { item in
                            ClipRow(item: item)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .onAppear { clipboard.refreshAccess() }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @State private var hovering = false
    private var clipboard: ClipboardService { .shared }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12.5, weight: .medium, design: item.kind == .link ? .default : .default))
                    .foregroundStyle(item.kind == .link ? Color(red: 0.45, green: 0.72, blue: 1) : Theme.ink)
                    .lineLimit(item.kind == .text ? 2 : 1)
                    .truncationMode(.tail)
                Text(Format.relative(item.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            Spacer(minLength: 6)
            if hovering || item.pinned {
                Button { clipboard.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .foregroundStyle(item.pinned ? Theme.accent : Theme.ink)
                .help(item.pinned ? "Unpin" : "Pin: keep when clearing")
            }
            if hovering {
                Button { clipboard.delete(item) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Remove from history")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.fill : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onTapGesture { clipboard.copy(item) }
        .help("Click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies this item")
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .image:
            if let image = clipboard.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.secondaryInk)
            }
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths?.first ?? "/"))
                .resizable()
        case .text, .link:
            if let source = item.sourceApp,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }
}
