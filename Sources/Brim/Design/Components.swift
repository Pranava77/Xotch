import SwiftUI

// AppKit-backed controls (scroll views, text fields, switches) don't draw in
// ImageRenderer, which debug snapshots use. These wrappers swap in plain
// SwiftUI stand-ins when `snapshotMode` is set, and look native otherwise.

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// A scroll view without indicators.
struct NotchScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            content
                .fixedSize(horizontal: axis == .horizontal, vertical: axis == .vertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axis, showsIndicators: false) { content }
        }
    }
}

/// A rounded search field with a magnifying glass.
struct NotchSearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.tertiaryInk)
            if snapshotMode {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Theme.tertiaryInk : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(onSubmit)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// A field for pasting API keys. The text is hidden.
struct NotchSecureField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill")
                .foregroundStyle(Theme.tertiaryInk)
            if snapshotMode {
                Text(text.isEmpty ? placeholder : String(repeating: "•", count: min(text.count, 24)))
                    .foregroundStyle(text.isEmpty ? Theme.tertiaryInk : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit(onSubmit)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Paste-a-key form used by Revenue and Analytics.
struct ConnectKeyForm: View {
    let title: String
    let help: String
    let placeholder: String
    let keyPage: URL
    var testModeLabel: String?
    let onConnect: (_ key: String, _ testMode: Bool) async -> String?
    let onCancel: (() -> Void)?

    @State private var key = ""
    @State private var testMode = false
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 4) {
                Text(help)
                Link("Open dashboard", destination: keyPage)
                    .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryInk)
            HStack(spacing: 8) {
                NotchSecureField(placeholder: placeholder, text: $key, onSubmit: submit)
                Button(checking ? "Checking…" : "Connect", action: submit)
                    .buttonStyle(PillButtonStyle())
                    .disabled(checking || key.isEmpty)
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            if let testModeLabel {
                Toggle(testModeLabel, isOn: $testMode)
                    .toggleStyle(NotchSwitchStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryInk)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.negative)
            } else {
                Label("Stored in your Keychain. Brim only ever reads.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
    }

    private func submit() {
        guard !checking, !key.isEmpty else { return }
        checking = true
        error = nil
        Task {
            let message = await onConnect(key, testMode)
            checking = false
            if let message {
                error = message
            } else {
                key = ""
            }
        }
    }
}

/// A multi-line editor on a soft panel.
struct NotchTextEditor: View {
    @Binding var text: String
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        Group {
            if snapshotMode {
                Text(text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
            } else {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
            }
        }
        .font(.system(size: 13))
        .padding(8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A small capsule switch that suits the black notch.
struct NotchSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Theme.raisedFill)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.ink)
                            .padding(2)
                    }
                    .animation(Motion.press, value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Makes the notch a drop target for files, which then land on the shelf.
struct ShelfDropTarget: ViewModifier {
    let onDrop: () -> Void
    @Binding var isTargeted: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                ShelfService.shared.add(files)
                onDrop()
                return true
            } isTargeted: { targeted in
                withAnimation(Motion.press) { isTargeted = targeted }
            }
        }
    }
}
