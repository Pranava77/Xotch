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
                Toggle("Show music beside the notch while it plays", isOn: $mediaActivity)
                    .onChange(of: mediaActivity) { _, _ in MediaService.shared.settingsChanged() }
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
