import AVFoundation
import SwiftUI

@MainActor
final class DictationModule: NotchModule {
    let id = "dictation"
    let title = "Dictation"
    let symbol = "waveform"
    func expandedView() -> AnyView { AnyView(DictationView()) }
}

/// The big microphone, what's being heard, anything still to set up, and the
/// last few dictations.
private struct DictationView: View {
    private var dictation: DictationService { .shared }
    private var model: WhistleModel { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 10) {
                MicButton()
                Text(caption)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 150)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                if dictation.isListening || dictation.phase == .finishing {
                    Text(dictation.liveText.isEmpty ? "Listening…" : dictation.liveText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(dictation.liveText.isEmpty ? Theme.tertiaryInk : Theme.ink)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else if let setup = setupStep {
                    setup
                } else {
                    recent
                }
                if let problem = dictation.problem, !dictation.isListening {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.negative)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var caption: String {
        switch dictation.phase {
        case .listening(handsFree: true): "Listening. Press Fn to finish, Esc to cancel"
        case .listening: "Listening. Let go of Fn to insert"
        case .finishing: "Writing…"
        case .idle: AppSettings.dictationEnabled ? "Hold Fn and talk, or double-tap Fn for hands-free" : "Click to talk"
        }
    }

    /// The first thing missing, as a short row with its fix.
    private var setupStep: AnyView? {
        if !dictation.isAvailable {
            return AnyView(SetupRow(symbol: "cpu", title: "Needs Apple silicon and macOS 26",
                                    detail: "Whistle's engine runs on M-series Macs with macOS 26 or later."))
        }
        switch model.state {
        case .missing, .failed:
            var detail = "Whistle hears you on this Mac: 17 MB, downloaded once, nothing leaves your Mac."
            if case .failed(let message) = model.state { detail = message }
            return AnyView(SetupRow(symbol: "arrow.down.circle", title: "Download the speech model", detail: detail,
                                    button: "Download") { model.download() })
        case .downloading(let progress):
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text("Downloading Whistle… \(Int(progress * 100))%")
                    .font(.system(size: 12.5, weight: .semibold))
                ProgressView(value: progress)
                    .tint(DictationService.tint)
            })
        case .ready:
            break
        }
        if !AppSettings.dictationEnabled {
            return AnyView(SetupRow(symbol: "fn", title: "Turn on the Fn key",
                                    detail: "Hold Fn anywhere to dictate into the app you're typing in.",
                                    button: "Turn On") {
                UserDefaults.standard.set(true, forKey: SettingsKey.dictationEnabled)
            })
        }
        if !AXIsProcessTrusted() {
            return AnyView(SetupRow(symbol: "accessibility", title: "Allow Accessibility",
                                    detail: "Lets Xotch notice the Fn key and paste where you're typing.",
                                    button: "Open Settings") { PrivacyPane.accessibility.open() })
        }
        if let conflict = FnKey.globeKeyConflict {
            return AnyView(SetupRow(symbol: "globe", title: "The 🌐 key also does “\(conflict)”",
                                    detail: "Set Keyboard › Press 🌐 key to “Do Nothing”, so only dictation answers.",
                                    button: "Keyboard Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            })
        }
        return nil
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.tertiaryInk)
            if dictation.history.isEmpty {
                Text("What you dictate shows here, so you can copy or insert it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(dictation.history.prefix(8)) { entry in
                            RecentRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

private struct MicButton: View {
    private var dictation: DictationService { .shared }
    @State private var pulse = false

    var body: some View {
        let listening = dictation.isListening
        Button {
            if listening {
                dictation.finish()
            } else if dictation.phase == .idle {
                dictation.start(handsFree: true)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(listening ? DictationService.tint : Theme.raisedFill)
                    .frame(width: 66, height: 66)
                if listening {
                    Circle()
                        .stroke(DictationService.tint.opacity(0.5), lineWidth: 3)
                        .frame(width: 66, height: 66)
                        .scaleEffect(pulse ? 1.35 : 1)
                        .opacity(pulse ? 0 : 1)
                }
                if dictation.phase == .finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(listening ? .white : Theme.ink)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(listening ? "Finish" : "Start dictating, hands-free")
        .accessibilityLabel(listening ? "Finish dictating" : "Start dictating")
        .debugFrame("dictation.mic")
        .onChange(of: listening, initial: true) { _, now in
            guard now, !Motion.reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct SetupRow: View {
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DictationService.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let button, let action {
                    Button(button, action: action)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .padding(.top, 2)
                        .debugFrame("dictation.setup")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RecentRow: View {
    let entry: DictationService.Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiaryInk)
            HStack(spacing: 2) {
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Copy")
                Button { DictationService.shared.insertAgain(entry) } label: { Image(systemName: "text.insert") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Insert again")
            }
            .opacity(hovering ? 1 : 0.0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }
}
