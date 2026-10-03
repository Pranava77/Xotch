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
                               message: "macOS is set to block Xotch from reading what you copy. Allow Xotch under Paste in Privacy & Security to keep a history.",
                               buttonTitle: "Open Privacy & Security") { ClipboardService.openPrivacySettings() }
            } else if clipboard.access == .needsPermission && historyOn {
                EmptyStateView(symbol: "doc.on.clipboard",
                               title: "Allow Xotch to see what you copy",
                               message: "macOS asks before apps read the clipboard. Press Allow, choose Allow when macOS asks, then set Xotch to always allow in Privacy & Security so history works in the background.",
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
                // A row of cards, newest first: the wide notch shows five at once.
                NotchScroll(axis: .horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(filtered) { item in
                            ClipCard(item: item)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .onAppear { clipboard.refreshAccess() }
    }
}

/// One copied thing as a card: where it came from, as much of it as fits,
/// and when. Click to copy it again; pin and remove appear on hover.
private struct ClipCard: View {
    let item: ClipItem
    @State private var hovering = false
    private var clipboard: ClipboardService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sourceIcon
                    .frame(width: 16, height: 16)
                Text(kindLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryInk)
                Spacer(minLength: 0)
                if item.pinned && !hovering {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(Format.relative(item.date))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
        }
        .padding(10)
        .frame(width: 146, height: 150)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(hovering ? Theme.raisedFill : Theme.fill))
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 4) {
                    Button { clipboard.togglePin(item) } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .foregroundStyle(item.pinned ? Theme.accent : Theme.ink)
                    .help(item.pinned ? "Unpin" : "Pin: keep when clearing")
                    Button { clipboard.delete(item) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .help("Remove from history")
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { over in withAnimation(Motion.press) { hovering = over } }
        .onTapGesture { clipboard.copy(item) }
        .help("Click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.preview)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies this item")
    }

    private var kindLabel: String {
        switch item.kind {
        case .text: "TEXT"
        case .link: "LINK"
        case .image: "IMAGE"
        case .files: (item.paths?.count ?? 1) > 1 ? "\(item.paths?.count ?? 0) FILES" : "FILE"
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let image = clipboard.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.secondaryInk)
            }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths?.first ?? "/"))
                    .resizable()
                    .frame(width: 40, height: 40)
                Text(item.preview)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
            }
        case .link:
            VStack(alignment: .leading, spacing: 3) {
                if let host = URL(string: item.preview)?.host {
                    Text(host.replacingOccurrences(of: "www.", with: ""))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(item.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1))
                    .lineLimit(3)
            }
        case .text:
            Text(item.preview)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(5)
        }
    }

    @ViewBuilder private var sourceIcon: some View {
        if let source = item.sourceApp,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: item.kind == .link ? "link" : item.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}
