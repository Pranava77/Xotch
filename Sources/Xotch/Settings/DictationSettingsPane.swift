import AVFoundation
import SwiftUI

/// Settings › Dictation: the Fn key, the Whistle model, permissions, and what
/// happens to the words.
struct DictationSettingsPane: View {
    @AppStorage(SettingsKey.dictationEnabled) private var enabled = false
    @AppStorage(SettingsKey.dictationLanguage) private var language = "auto"
    @AppStorage(SettingsKey.dictationPaste) private var paste = true
    @AppStorage(SettingsKey.dictationTidy) private var tidy = true
    @AppStorage(SettingsKey.dictationPolish) private var polish = false
    @AppStorage(SettingsKey.dictationHistory) private var keepHistory = false
    @AppStorage(SettingsKey.dictationWords) private var words = ""
    @State private var microphone = MicRecorder.permission
    @State private var trusted = AXIsProcessTrusted()
    @State private var globeConflict = FnKey.globeKeyConflict
    private var model: WhistleModel { .shared }

    private static let languages: [(String, String)] = [
        ("auto", "Detect"), ("en", "English"), ("de", "German"), ("fr", "French"),
        ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Dictate with the Fn key", isOn: $enabled)
                    .disabled(!WhistleEngine.isSupported)
                modelRow
            } header: {
                Text("Dictation")
            } footer: {
                SettingsFootnote(WhistleEngine.isSupported
                    ? "Hold Fn (🌐) and talk; let go and the words appear where you're typing. Double-tap Fn to keep listening hands-free, and press it again to finish. Esc cancels. Speech is turned into text on this Mac by Whistle from Cactus Compute; your voice is never saved or sent."
                    : "Dictation needs a Mac with Apple silicon and macOS 26 or later.")
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    switch microphone {
                    case .authorized:
                        Text("Allowed").foregroundStyle(.secondary)
                    case .notDetermined:
                        Button("Allow…") {
                            Task {
                                _ = await MicRecorder.requestPermission()
                                microphone = MicRecorder.permission
                            }
                        }
                    default:
                        Button("Open Microphone Settings") { PrivacyPane.microphone.open() }
                    }
                }
                LabeledContent("Accessibility") {
                    if trusted {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Open Accessibility Settings") { PrivacyPane.accessibility.open() }
                    }
                }
                if let globeConflict {
                    LabeledContent("🌐 key also does “\(globeConflict)”") {
                        Button("Keyboard Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(Self.languages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                Toggle("Paste into the app you're typing in", isOn: $paste)
                Toggle("Tidy up: drop “um”s and repeats, fix capitals", isOn: $tidy)
                Toggle("Polish with \(AIProviderStore.shared.active?.name ?? "your AI")", isOn: $polish)
                    .disabled(AIProviderStore.shared.active == nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Words to listen for")
                    TextEditor(text: $words)
                        .font(.body)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            } header: {
                Text("Text")
            } footer: {
                SettingsFootnote("Accessibility lets Xotch notice the Fn key and paste; without it, the text is copied for you to paste. Polishing sends what you said to \(AIProviderStore.shared.active?.name ?? "your AI") to fix grammar, and adds about a second. Put names and jargon Whistle should expect in Words to listen for, one per line.")
            }

            Section("Recent dictations") {
                Toggle("Keep them between launches", isOn: $keepHistory)
                Button("Forget Recent Dictations") { DictationService.shared.forget() }
                    .disabled(DictationService.shared.history.isEmpty)
            }
        }
        .task {
            // Permissions are granted in System Settings, and nothing tells us.
            while !Task.isCancelled {
                microphone = MicRecorder.permission
                trusted = AXIsProcessTrusted()
                globeConflict = FnKey.globeKeyConflict
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var modelRow: some View {
        LabeledContent("Speech model") {
            switch model.state {
            case .ready:
                HStack {
                    Text("Whistle, ready").foregroundStyle(.secondary)
                    Button("Remove") { model.remove() }
                }
            case .downloading(let progress):
                HStack {
                    ProgressView(value: progress).frame(width: 120)
                    Button("Cancel") { model.cancel() }
                }
            case .missing:
                Button("Download Whistle (17 MB)") { model.download() }
                    .disabled(!WhistleEngine.isSupported)
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                    Button("Try Again") { model.download() }
                }
            }
        }
    }
}
