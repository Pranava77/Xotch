import SwiftUI

// AppKit-backed controls (scroll views, text fields, switches) don't draw in
// ImageRenderer, which debug snapshots use. These wrappers swap in plain
// SwiftUI stand-ins when `snapshotMode` is set, and look native otherwise.

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct SnapshotClearGlassKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct SnapshotHidesTilesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }

    /// A fixed time for snapshots, so the clock always reads the same.
    var snapshotDate: Date? {
        get { self[SnapshotDateKey.self] }
        set { self[SnapshotDateKey.self] = newValue }
    }

    /// Seconds into an animated snapshot sequence (the promo film), so things
    /// that move, like the music bars, differ from frame to frame.
    var snapshotTime: Double? {
        get { self[SnapshotTimeKey.self] }
        set { self[SnapshotTimeKey.self] = newValue }
    }

    /// Home without its tiles, for the promo film, which brings them in itself.
    var snapshotHidesTiles: Bool {
        get { self[SnapshotHidesTilesKey.self] }
        set { self[SnapshotHidesTilesKey.self] = newValue }
    }

    /// Snapshots that draw their own blurred backdrop: glass leaves it showing.
    var snapshotClearGlass: Bool {
        get { self[SnapshotClearGlassKey.self] }
        set { self[SnapshotClearGlassKey.self] = newValue }
    }
}

/// A scroll view without indicators.
struct NotchScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    /// Lets content draw outside the scroll area, e.g. a tile being flicked away.
    var clipsContent = true
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            content
                .fixedSize(horizontal: axis == .horizontal, vertical: axis == .vertical)
                // minWidth/minHeight 0, so long content is clipped instead of widening its parent.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axis, showsIndicators: false) { content }
                .scrollClipDisabled(!clipsContent)
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
        .xotchGlass(RoundedRectangle(cornerRadius: 9, style: .continuous))
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

/// A small capsule switch that suits the dark notch.
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
    /// Called with the drop point, in the modified view's coordinates.
    let onDrop: (CGPoint) -> Void
    @Binding var isTargeted: Bool
    @Environment(\.snapshotMode) private var snapshotMode

    func body(content: Content) -> some View {
        if snapshotMode {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, location in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                ShelfService.shared.add(files)
                onDrop(location)
                return true
            } isTargeted: { targeted in
                withAnimation(Motion.press) { isTargeted = targeted }
            }
        }
    }
}
