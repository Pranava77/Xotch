import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.openBehavior) private var openBehavior: OpenBehavior = .hover
    @AppStorage(SettingsKey.hoverDelay) private var hoverDelay: Double = 150
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.display) private var display = DisplayChoice.automatic
    @AppStorage(SettingsKey.moduleOrder) private var moduleOrder = ""
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""
    @AppStorage(SettingsKey.clipboardHistory) private var clipboardHistory = true
    @AppStorage(SettingsKey.mediaActivity) private var mediaActivity = true
    @AppStorage(SettingsKey.shelfExpiryHours) private var shelfExpiryHours = 24
    @AppStorage(SettingsKey.hideInFullScreen) private var hideInFullScreen = true
    @AppStorage(Diagnostics.shareKey) private var shareDiagnostics = false
    @AppStorage(SettingsKey.scrollForVolume) private var scrollForVolume = true
    @AppStorage(SettingsKey.showMascot) private var showMascot = true
    @AppStorage(SettingsKey.celebrateFocus) private var celebrateFocus = true
    @AppStorage(SettingsKey.realAudioLevels) private var realAudioLevels = false
    @AppStorage(SettingsKey.downloadProgress) private var downloadProgress = false
    @AppStorage(SettingsKey.ledTitle) private var ledTitle = true
    @State private var confirmClearClipboard = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section("Opening") {
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

                Toggle("Haptic feedback", isOn: $haptics)
            }

            Section {
                ThemePicker()
                if ThemeStore.shared.selectedID == Palette.customID {
                    CustomThemeEditor()
                }
                Toggle("Show Brim's mascot on Home", isOn: $showMascot)
                Toggle("Show the track on a dot-matrix display", isOn: $ledTitle)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The closed notch always stays black, so it blends into the camera housing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show music beside the notch while it plays", isOn: $mediaActivity)
                    .onChange(of: mediaActivity) { _, _ in MediaService.shared.settingsChanged() }
                Toggle("Move the music bars with the real sound", isOn: $realAudioLevels)
                    .onChange(of: realAudioLevels) { _, _ in AudioLevels.shared.settingsChanged() }
                if realAudioLevels {
                    AudioLevelsStatus()
                }
                Toggle("Show download progress", isOn: $downloadProgress)
                    .onChange(of: downloadProgress) { _, _ in DownloadsService.shared.settingsChanged() }
                Toggle("Scroll on the closed notch to change the volume", isOn: $scrollForVolume)
            } header: {
                Text("Beside the notch")
            } footer: {
                Text("Real sound needs permission to record system audio; Brim only measures how loud it is and keeps nothing. Download progress works with Safari, Chrome and other apps that report it, and macOS may ask for access to your Downloads folder.")
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Picker("Show the notch on", selection: $display) {
                    Text("Automatic (built-in notch first)").tag(DisplayChoice.automatic)
                    Text("All displays").tag(DisplayChoice.all)
                    Divider()
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag(DisplayChoice.named(name))
                    }
                }
                Toggle("Hide the notch while an app is full screen", isOn: $hideInFullScreen)
            }

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
                Text("Modules")
            } footer: {
                Text("⌘1–9 picks a module in this order, and a two-finger swipe moves between them. Esc closes the notch.")
                    .foregroundStyle(.secondary)
            }

            Section("Features") {
                Toggle("Celebrate finished focus sessions", isOn: $celebrateFocus)
                LabeledContent("Try it") {
                    Button("Celebrate") {
                        ActivityCenter.shared.celebrate()
                        ScreenManager.shared.openPrimaryForPreview()
                    }
                }
                Picker("Keep shelf items for", selection: $shelfExpiryHours) {
                    Text("1 hour").tag(1)
                    Text("1 day").tag(24)
                    Text("1 week").tag(168)
                    Text("Until removed").tag(0)
                }
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
                Toggle("Keep crash reports I can choose to send", isOn: $shareDiagnostics)
                    .onChange(of: shareDiagnostics) { _, _ in Diagnostics.shared.settingsChanged() }
                if shareDiagnostics, Diagnostics.shared.lastCrashReport != nil {
                    LabeledContent("Brim quit unexpectedly last time") {
                        HStack {
                            Button("Show Report") { Diagnostics.shared.revealCrashReport() }
                            Button("Email Report…") { Diagnostics.shared.emailCrashReport() }
                        }
                    }
                }
                LabeledContent("Feedback") {
                    Button("Send Feedback…") { Diagnostics.shared.sendFeedback() }
                }
            } header: {
                Text("Privacy and feedback")
            } footer: {
                Text("Brim never sends anything by itself. With this on, it keeps macOS's crash details on this Mac so you can attach them to an email.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Brim at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginMessage {
                    Text(loginMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear { NSApp.activate() }
    }

    // MARK: - Modules

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

    // MARK: - Login item

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
                loginMessage = "Approve Brim in System Settings › General › Login Items."
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

// MARK: - Themes

private struct ThemePicker: View {
    private var store: ThemeStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(store.choices) { palette in
                    ThemeCard(palette: palette, isSelected: palette.id == store.selectedID) {
                        store.select(palette.id)
                    }
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
                .frame(width: 92, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isSelected ? 2.5 : 1)
                )
                Text(palette.name)
                    .font(.caption)
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
                Text("Brim isn't hearing any sound. If music is playing, allow Brim under Privacy & Security › Screen & System Audio Recording.")
                    .font(.callout)
            }
        case .failed(let message):
            Text("Real sound isn't available: \(message) The bars use their own animation.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
