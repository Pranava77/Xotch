import ServiceManagement
import SwiftUI

/// A page of Settings, listed in the sidebar.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, modules, media, todos, shelf, capture, ai, privacy

    var id: String { rawValue }

    /// The sidebar's groups, separated by a gap.
    static let groups: [[SettingsPane]] = [
        [.general, .appearance, .modules],
        [.media, .todos, .shelf, .capture, .ai],
        [.privacy],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .modules: "Modules"
        case .media: "Media"
        case .todos: "To-dos & Timers"
        case .shelf: "Shelf & Clipboard"
        case .capture: "Capture"
        case .ai: "AI"
        case .privacy: "Privacy & Feedback"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .modules: "square.grid.2x2.fill"
        case .media: "music.note"
        case .todos: "checklist"
        case .shelf: "tray.full.fill"
        case .capture: "camera.viewfinder"
        case .ai: "sparkles"
        case .privacy: "hand.raised.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .modules: .indigo
        case .media: .pink
        case .todos: .orange
        case .shelf: .teal
        case .capture: .red
        case .ai: .purple
        case .privacy: .blue
        }
    }
}

/// The sidebar of the Settings window. `SettingsWindow` puts it beside `SettingsDetail`.
struct SettingsSidebar: View {
    @AppStorage(SettingsKey.settingsPane) private var pane: SettingsPane = .general

    var body: some View {
        List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let new = $0 { pane = new } })) {
            ForEach(SettingsPane.groups, id: \.self) { group in
                Section {
                    ForEach(group) { pane in
                        Label { Text(pane.title) } icon: { PaneIcon(pane: pane) }
                            .tag(pane)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The page picked in the sidebar.
struct SettingsDetail: View {
    @AppStorage(SettingsKey.settingsPane) private var pane: SettingsPane = .general

    var body: some View {
        page
            .formStyle(.grouped)
            .background(WindowTitle(title: pane.title))
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .modules: ModulesPane()
        case .media: MediaPane()
        case .todos: TodosPane()
        case .shelf: ShelfPane()
        case .capture: CapturePane()
        case .ai: AISettingsPane()
        case .privacy: PrivacyFeedbackPane()
        }
    }
}

/// Explanatory text under a section, lined up with its rows. A grouped form
/// puts footers on the trailing edge, which leaves paragraphs ragged on the left.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// Names the window after the page, as System Settings does. The window is
/// AppKit's, so `navigationTitle` doesn't reach it, and its title follows its
/// content view controller's, so that's the one to set.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title }

    final class TitleView: NSView {
        var title = "" { didSet { apply() } }
        override func viewDidMoveToWindow() { apply() }

        private func apply() {
            window?.contentViewController?.title = title
        }
    }
}

/// A white symbol on a coloured tile, like System Settings' sidebar.
private struct PaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(SettingsKey.openBehavior) private var openBehavior: OpenBehavior = .hover
    @AppStorage(SettingsKey.hoverDelay) private var hoverDelay: Double = 150
    @AppStorage(SettingsKey.display) private var display = DisplayChoice.automatic
    @AppStorage(SettingsKey.hideInFullScreen) private var hideInFullScreen = true
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.retroSounds) private var retroSounds = false
    @AppStorage(SettingsKey.retroSoundVolume) private var retroSoundVolume = 0.5
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Xotch at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginMessage {
                    Text(loginMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Opening the notch") {
                Picker("Open the notch on", selection: $openBehavior) {
                    ForEach(OpenBehavior.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $hoverDelay, in: 50...600, step: 25)
                        Text("\(Int(hoverDelay)) ms")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(openBehavior == .click)
            }

            Section {
                Picker("Show the notch on", selection: $display) {
                    Text("All displays").tag(DisplayChoice.all)
                    Text("Only the built-in notch").tag(DisplayChoice.automatic)
                    Divider()
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(DisplayChoice.named(name))
                    }
                }
                Toggle("Hide the notch while an app is full screen", isOn: $hideInFullScreen)
            } header: {
                Text("Displays")
            } footer: {
                SettingsFootnote("A display without a notch gets one drawn in its menu bar, sized to the screen — external monitors, an iMac, a Mac mini or a Studio all work.")
            }

            Section("Sound and haptics") {
                Toggle("Haptic feedback", isOn: $haptics)
                Toggle("Arcade sound effects", isOn: $retroSounds)
                    .onChange(of: retroSounds) { _, on in
                        if on { RetroSound.play(.complete, force: true) }
                    }
                if retroSounds {
                    LabeledContent("Volume") {
                        Slider(value: $retroSoundVolume, in: 0.05...1, onEditingChanged: { editing in
                            if !editing { RetroSound.play(.tick, force: true) }
                        })
                        .frame(maxWidth: 180)
                    }
                }
            }
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            if service.status == .requiresApproval {
                loginMessage = "Approve Xotch in System Settings › General › Login Items."
                SMAppService.openSystemSettingsLoginItems()
            } else {
                loginMessage = nil
            }
        } catch {
            loginMessage = "Couldn't change this: \(error.localizedDescription)"
            openAtLogin = service.status == .enabled
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage(SettingsKey.adiyogiEar) private var adiyogiEar = true

    var body: some View {
        Form {
            Section {
                ThemePicker()
            } header: {
                Text("Theme")
            } footer: {
                SettingsFootnote("The closed notch always stays black, so it blends into the camera housing.")
            }

            if ThemeStore.shared.selectedID == Palette.customID {
                Section("Custom theme") {
                    CustomThemeEditor()
                }
            }

            Section("Closed notch") {
                Toggle("Show Adiyogi beside the closed notch", isOn: $adiyogiEar)
            }
        }
    }
}

// MARK: - Modules

private struct ModulesPane: View {
    @AppStorage(SettingsKey.moduleOrder) private var moduleOrder = ""
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""

    var body: some View {
        Form {
            Section {
                ForEach(Array(orderedModules.enumerated()), id: \.element.id) { index, module in
                    HStack(spacing: 10) {
                        Image(systemName: module.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Toggle(module.title, isOn: visibility(of: module.id))
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(module.title) up")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == orderedModules.count - 1)
                            .accessibilityLabel("Move \(module.title) down")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Show and order")
            } footer: {
                SettingsFootnote("The first five get a tab beside the camera; the rest are under ···. ⌘1–9 picks a module in this order, and a two-finger swipe moves between them. Esc closes the notch.")
            }
        }
    }

    private var orderedModules: [ModuleInfo] {
        ModuleRegistry.ordered(order: moduleOrder).map { $0.info }
    }

    private var hiddenIDs: Set<String> {
        Set(hiddenModules.split(separator: ",").map(String.init))
    }

    private func visibility(of id: String) -> Binding<Bool> {
        Binding(
            get: { !hiddenIDs.contains(id) },
            set: { visible in
                var hidden = hiddenIDs
                if visible {
                    hidden.remove(id)
                } else {
                    // Keep at least one module visible.
                    guard orderedModules.count - hidden.count > 1 else { return }
                    hidden.insert(id)
                }
                hiddenModules = hidden.sorted().joined(separator: ",")
            }
        )
    }

    private func move(_ index: Int, by offset: Int) {
        var ids = orderedModules.map(\.id)
        let target = index + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        moduleOrder = ids.joined(separator: ",")
    }
}

// MARK: - Media

private struct MediaPane: View {
    @AppStorage(SettingsKey.mediaActivity) private var mediaActivity = true
    @AppStorage(SettingsKey.realAudioLevels) private var realAudioLevels = false
    @AppStorage(SettingsKey.ledTitle) private var ledTitle = true
    @AppStorage(SettingsKey.scrollForVolume) private var scrollForVolume = true
    @AppStorage(SettingsKey.mediaKeysHUD) private var mediaKeysHUD = false
    @State private var keysTrusted = MediaKeys.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle("Show music beside the notch while it plays", isOn: $mediaActivity)
                    .onChange(of: mediaActivity) { _, _ in MediaService.shared.settingsChanged() }
                Toggle("Move the music bars with the real sound", isOn: $realAudioLevels)
                    .onChange(of: realAudioLevels) { _, _ in AudioLevels.shared.settingsChanged() }
                if realAudioLevels {
                    AudioLevelsStatus()
                }
                Toggle("Show the track on a dot-matrix display", isOn: $ledTitle)
            } header: {
                Text("Now Playing")
            } footer: {
                SettingsFootnote("Real sound needs permission to record system audio; Xotch only measures how loud it is and keeps nothing.")
            }

            Section {
                Toggle("Scroll on the closed notch to change the volume", isOn: $scrollForVolume)
                Toggle("Show volume and brightness in the notch", isOn: $mediaKeysHUD)
                    .onChange(of: mediaKeysHUD) { _, on in
                        if on, !MediaKeys.isTrusted { MediaKeys.requestPermission() }
                        keysTrusted = MediaKeys.isTrusted
                    }
                if mediaKeysHUD, !keysTrusted {
                    LabeledContent("Needs permission") {
                        Button("Open Accessibility settings") { PrivacyPane.accessibility.open() }
                    }
                }
            } header: {
                Text("Volume and brightness")
            } footer: {
                SettingsFootnote("The keys show their level in the notch instead of macOS's popup. Needs Accessibility permission. Brightness works on the built-in display only; Shift+Option gives smaller steps.")
            }
        }
        .task {
            // Permission is granted in System Settings, and nothing tells us.
            while !Task.isCancelled {
                keysTrusted = MediaKeys.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - To-dos and timers

private struct TodosPane: View {
    @AppStorage(SettingsKey.todoRollover) private var todoRollover = true
    @AppStorage(SettingsKey.todoActivity) private var todoActivity = false
    @AppStorage(SettingsKey.celebrateFocus) private var celebrateFocus = true

    var body: some View {
        Form {
            Section {
                Toggle("Carry unfinished to-dos over to the next day", isOn: $todoRollover)
                Toggle("Show how many to-dos are left beside the notch", isOn: $todoActivity)
                    .onChange(of: todoActivity) { _, _ in TodoService.shared.updateActivity() }
                LabeledContent("Your to-do file") {
                    Button("Show in Finder") { TodoService.shared.revealStore() }
                }
            } header: {
                Text("To-dos")
            } footer: {
                SettingsFootnote("Your to-dos live in todos.json on this Mac.")
            }

            Section("Timers") {
                Toggle("Celebrate finished focus sessions", isOn: $celebrateFocus)
                LabeledContent("Try it") {
                    Button("Celebrate") {
                        ActivityCenter.shared.celebrate()
                        ScreenManager.shared.openPrimaryForPreview()
                    }
                }
            }
        }
    }
}

// MARK: - Shelf and clipboard

private struct ShelfPane: View {
    @AppStorage(SettingsKey.shelfExpiryHours) private var shelfExpiryHours = 24
    @AppStorage(SettingsKey.clipboardHistory) private var clipboardHistory = true
    @AppStorage(SettingsKey.downloadProgress) private var downloadProgress = false
    @State private var confirmClearClipboard = false

    var body: some View {
        Form {
            Section("Shelf") {
                Picker("Keep shelf items for", selection: $shelfExpiryHours) {
                    Text("1 hour").tag(1)
                    Text("1 day").tag(24)
                    Text("1 week").tag(168)
                    Text("Until removed").tag(0)
                }
            }

            Section("Clipboard") {
                Toggle("Keep clipboard history", isOn: $clipboardHistory)
                LabeledContent("Clipboard history") {
                    Button("Clear…") { confirmClearClipboard = true }
                }
                .confirmationDialog("Clear clipboard history?", isPresented: $confirmClearClipboard) {
                    Button("Clear History", role: .destructive) { ClipboardService.shared.clearUnpinned() }
                } message: {
                    Text("Pinned items stay. This can't be undone.")
                }
            }

            Section {
                Toggle("Show download progress beside the notch", isOn: $downloadProgress)
                    .onChange(of: downloadProgress) { _, _ in DownloadsService.shared.settingsChanged() }
            } header: {
                Text("Downloads")
            } footer: {
                SettingsFootnote("Download progress works with Safari, Chrome and other apps that report it, and macOS may ask for access to your Downloads folder.")
            }
        }
    }
}

// MARK: - Capture

private struct CapturePane: View {
    @AppStorage(SettingsKey.captureFolder) private var captureFolder = ""
    @AppStorage(SettingsKey.captureCopies) private var captureCopies = true
    @AppStorage(SettingsKey.captureIncludesMac) private var captureIncludesMac = true
    @AppStorage(SettingsKey.captureKeepDays) private var captureKeepDays = 7
    @AppStorage(SettingsKey.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(SettingsKey.captureMicrophone) private var captureMicrophone = false
    @AppStorage(SettingsKey.captureShowsClicks) private var captureShowsClicks = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(captureFolderName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseCaptureFolder() }
                        if !captureFolder.isEmpty {
                            Button("Use Pictures › Xotch") { captureFolder = "" }
                        }
                    }
                }
                Toggle("Copy screenshots to the clipboard", isOn: $captureCopies)
                Toggle("List screenshots taken with ⌘⇧3, ⌘⇧4 and ⌘⇧5", isOn: $captureIncludesMac)
                Picker("Keep captures in the list for", selection: $captureKeepDays) {
                    Text("1 day").tag(1)
                    Text("1 week").tag(7)
                    Text("Always").tag(0)
                }
            } header: {
                Text("Screenshots")
            } footer: {
                SettingsFootnote("Listing ⌘⇧3 and ⌘⇧4 screenshots may need access to the folder macOS saves them in, which is Desktop unless you've changed it.")
            }

            Section {
                Toggle("Record system audio", isOn: $captureSystemAudio)
                Toggle("Record from the microphone", isOn: $captureMicrophone)
                Toggle("Show clicks in recordings", isOn: $captureShowsClicks)
            } header: {
                Text("Recordings")
            } footer: {
                SettingsFootnote("macOS asks for Screen Recording permission the first time you capture, and for the microphone only if you record with it. Recording needs macOS 15.")
            }
        }
    }

    private var captureFolderName: String {
        let url = captureFolder.isEmpty ? CaptureService.defaultFolder : URL(fileURLWithPath: captureFolder)
        return FileManager.default.displayName(atPath: url.deletingLastPathComponent().path) + " › "
            + FileManager.default.displayName(atPath: url.path)
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Choose where Xotch saves screenshots and recordings."
        panel.directoryURL = captureFolder.isEmpty ? CaptureService.defaultFolder : URL(fileURLWithPath: captureFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        captureFolder = url.path
    }
}

// MARK: - Privacy and feedback

private struct PrivacyFeedbackPane: View {
    @AppStorage(SettingsKey.hideFromScreenSharing) private var hideFromSharing = false
    @AppStorage(Diagnostics.shareKey) private var shareDiagnostics = false

    var body: some View {
        Form {
            Section {
                Toggle("Hide the notch from screen sharing and recordings", isOn: $hideFromSharing)
            } header: {
                Text("Screen sharing")
            } footer: {
                SettingsFootnote("This asks macOS to leave the notch out of shared screens and recordings, but some apps and macOS versions capture it anyway — check with a test call before relying on it.")
            }

            Section {
                Toggle("Keep crash reports I can choose to send", isOn: $shareDiagnostics)
                    .onChange(of: shareDiagnostics) { _, _ in Diagnostics.shared.settingsChanged() }
                if shareDiagnostics, Diagnostics.shared.lastCrashReport != nil {
                    LabeledContent("Xotch quit unexpectedly last time") {
                        HStack {
                            Button("Show Report") { Diagnostics.shared.revealCrashReport() }
                            Button("Email Report…") { Diagnostics.shared.emailCrashReport() }
                        }
                    }
                }
            } header: {
                Text("Crash reports")
            } footer: {
                SettingsFootnote("Xotch never sends anything by itself. With this on, it keeps macOS's crash details on this Mac so you can attach them to an email.")
            }

            Section("Feedback") {
                LabeledContent("Ideas, bugs or questions") {
                    Button("Send Feedback…") { Diagnostics.shared.sendFeedback() }
                }
            }
        }
    }
}

// MARK: - Themes

private struct ThemePicker: View {
    private var store: ThemeStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The cards share the row's width. At a fixed 92 points each, five of
            // them made the row wider than the window and clipped the whole form.
            HStack(spacing: 8) {
                ForEach(store.choices) { palette in
                    ThemeCard(palette: palette, isSelected: palette.id == store.selectedID) {
                        store.select(palette.id)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if store.selectedID != Palette.customID {
                Button("Customise This Theme…") { store.customizeCurrent() }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThemeCard: View {
    let palette: Palette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(white: 0.55))
                    // A tiny open notch.
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                        .fill(palette.material == .glass
                              ? AnyShapeStyle(LinearGradient(colors: [.black, palette.surface.color.opacity(0.75)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(palette.surface.color))
                        .overlay(alignment: .topLeading) {
                            if let glow = palette.glow ?? Optional(palette.accent), palette.glowStrength > 0 {
                                RadialGradient(colors: [glow.color.opacity(palette.glowStrength * 1.4), .clear],
                                               center: .topLeading, startRadius: 2, endRadius: 60)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Capsule().fill(palette.ink.color.opacity(0.9)).frame(width: 30, height: 4)
                                Capsule().fill(palette.ink.color.opacity(0.4)).frame(width: 20, height: 3)
                                Capsule().fill(palette.accent.color).frame(width: 24, height: 7)
                            }
                            .padding(7)
                        }
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isSelected ? 2.5 : 1)
                )
                Text(palette.name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.name) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CustomThemeEditor: View {
    private var store: ThemeStore { .shared }

    var body: some View {
        ColorPicker("Background", selection: color(\.surface), supportsOpacity: false)
        ColorPicker("Text", selection: color(\.ink), supportsOpacity: false)
        ColorPicker("Accent", selection: color(\.accent), supportsOpacity: false)
        Picker("Material", selection: Binding(
            get: { store.custom.material },
            set: { material in store.updateCustom { $0.material = material } }
        )) {
            Text("Solid").tag(SurfaceMaterial.solid)
            Text("Glass").tag(SurfaceMaterial.glass)
        }
        .pickerStyle(.segmented)
        Toggle("Glossy retro controls", isOn: Binding(
            get: { store.custom.isRetro },
            set: { on in store.updateCustom { $0.style = on ? .retro : .modern } }
        ))
        Toggle("Glow in each module's colour", isOn: Binding(
            get: { store.custom.glow == nil },
            set: { follows in store.updateCustom { $0.glow = follows ? nil : $0.accent } }
        ))
        if store.custom.glow != nil {
            ColorPicker("Glow", selection: Binding(
                get: { store.custom.glow?.color ?? .white },
                set: { color in store.updateCustom { $0.glow = RGBA(color) } }
            ), supportsOpacity: false)
        }
        LabeledContent("Glow strength") {
            Slider(value: Binding(
                get: { store.custom.glowStrength },
                set: { value in store.updateCustom { $0.glowStrength = value } }
            ), in: 0...0.7)
        }
    }

    private func color(_ keyPath: WritableKeyPath<Palette, RGBA>) -> Binding<Color> {
        Binding(
            get: { store.custom[keyPath: keyPath].color },
            set: { color in store.updateCustom { $0[keyPath: keyPath] = RGBA(color) } }
        )
    }
}

private struct AudioLevelsStatus: View {
    private var levels: AudioLevels { .shared }

    var body: some View {
        switch levels.status {
        case .off, .listening:
            Text("The bars follow the music while they're showing. macOS asks for permission the first time.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .silent:
            LabeledContent {
                Button("Open Settings") { PrivacyPane.audioCapture.open() }
            } label: {
                Text("Xotch isn't hearing any sound. If music is playing, allow Xotch under Privacy & Security › Screen & System Audio Recording.")
                    .font(.callout)
            }
        case .failed(let message):
            Text("Real sound isn't available: \(message) The bars use their own animation.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
