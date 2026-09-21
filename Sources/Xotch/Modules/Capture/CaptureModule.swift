import SwiftUI

@MainActor
final class CaptureModule: NotchModule {
    let id = "capture"
    let title = "Capture"
    let symbol = "camera.viewfinder"
    var tint: Color? { CaptureService.tint }
    func expandedView() -> AnyView { AnyView(CaptureView()) }
}

private enum CaptureMode: String, CaseIterable {
    case screenshot = "Screenshot"
    case record = "Record"
}

private struct CaptureView: View {
    @State private var mode: CaptureMode = CaptureService.shared.isRecording ? .record : .screenshot
    @State private var timed = false
    private var capture: CaptureService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if capture.isRecording {
                RecordingBar()
            } else {
                HStack(spacing: 4) {
                    ForEach(CaptureMode.allCases, id: \.self) { item in
                        Button(item.rawValue) {
                            withAnimation(Motion.switchModule) { mode = item }
                        }
                        .buttonStyle(PillButtonStyle(tint: Theme.ink, prominent: mode == item))
                    }
                    Spacer(minLength: 12)
                    ForEach(CaptureTarget.allCases) { target in
                        TargetButton(target: target, mode: mode, delay: timed ? 5 : 0)
                    }
                }
            }

            optionsRow
                .frame(height: 22)

            HStack {
                SectionLabel(capture.items.isEmpty ? "Recent" : "Recent · \(capture.items.count)")
                Spacer()
                Button { capture.openFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                .controlSize(.small)
            }

            if capture.items.isEmpty {
                EmptyShelf()
            } else {
                NotchScroll(axis: .horizontal, clipsContent: false) {
                    HStack(spacing: 4) {
                        ForEach(capture.items) { CaptureTile(item: $0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task { await capture.whileVisible() }
    }

    @ViewBuilder private var optionsRow: some View {
        if let notice = capture.notice {
            NoticeRow(notice: notice)
        } else if capture.isRecording {
            Text(recordingSummary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
        } else if mode == .record && !CaptureService.canRecord {
            Text("Recording needs macOS 15 or later. Screenshots work on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
        } else {
            HStack(spacing: 6) {
                switch mode {
                case .screenshot:
                    SettingChip(title: "Copy to clipboard", symbol: "doc.on.clipboard", key: SettingsKey.captureCopies)
                    OptionChip(title: "5-second timer", symbol: "timer", isOn: $timed)
                case .record:
                    SettingChip(title: "System audio", symbol: "speaker.wave.2", key: SettingsKey.captureSystemAudio)
                    SettingChip(title: "Microphone", symbol: "mic", key: SettingsKey.captureMicrophone)
                    SettingChip(title: "Show clicks", symbol: "cursorarrow.click", key: SettingsKey.captureShowsClicks)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var recordingSummary: String {
        let what = switch capture.recordingTarget {
        case .area: "an area"
        case .window: "a window"
        default: "the screen"
        }
        var parts = ["Recording \(what)"]
        if AppSettings.captureSystemAudio { parts.append("system audio") }
        if AppSettings.captureMicrophone { parts.append("microphone") }
        return parts.joined(separator: " · ") + ". Click the time beside the notch to stop."
    }
}

private struct TargetButton: View {
    let target: CaptureTarget
    let mode: CaptureMode
    let delay: Int
    private var capture: CaptureService { .shared }

    var body: some View {
        let recording = mode == .record
        Button {
            if recording {
                capture.startRecording(target)
            } else {
                capture.takeScreenshot(target, delay: delay)
            }
        } label: {
            Label(target.title, systemImage: target.symbol)
        }
        .buttonStyle(PillButtonStyle(tint: recording ? Theme.negative : CaptureService.tint))
        .disabled(recording ? (!CaptureService.canRecord || capture.isStartingRecording) : capture.isTakingScreenshot)
        .opacity(recording && !CaptureService.canRecord ? 0.4 : 1)
        .help(help(recording: recording))
    }

    private func help(recording: Bool) -> String {
        switch (target, recording) {
        case (.area, false): "Drag to choose an area. Press Space to pick a window instead."
        case (.window, false): "Click a window to capture it."
        case (.screen, false): "Capture the display the pointer is on."
        case (.area, true): "Drag to choose an area to record."
        case (.window, true): "Choose a window to record."
        case (.screen, true): "Record the display the pointer is on."
        }
    }
}

/// A red timer and a Stop button while a recording runs.
private struct RecordingBar: View {
    private var capture: CaptureService { .shared }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.negative)
                    .frame(width: 9, height: 9)
                if let started = capture.recordingStarted {
                    Text(started, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.negative.opacity(0.18), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording")

            Spacer()

            Button {
                capture.stopRecording()
            } label: {
                Label(capture.isStoppingRecording ? "Saving…" : "Stop", systemImage: "stop.fill")
            }
            .buttonStyle(PillButtonStyle(tint: Theme.negative))
            .disabled(capture.isStoppingRecording)
        }
    }
}

/// A setting you can flip right here. The same switches are in Settings › Capture.
private struct SettingChip: View {
    let title: String
    let symbol: String
    @AppStorage private var isOn: Bool

    init(title: String, symbol: String, key: String) {
        self.title = title
        self.symbol = symbol
        _isOn = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        OptionChip(title: title, symbol: symbol, isOn: $isOn)
    }
}

private struct OptionChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(isOn ? Theme.ink : Theme.tertiaryInk)
            .background(Capsule().fill(isOn ? Theme.selection : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.hairline))
            .contentShape(Capsule())
            .animation(Motion.press, value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

private struct NoticeRow: View {
    let notice: CaptureService.Notice
    private var capture: CaptureService { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let pane {
                Button("Open Settings") { pane.open() }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            Button { capture.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 20))
                .help("Dismiss")
        }
        .font(.system(size: 11))
    }

    private var message: String {
        switch notice {
        case .needsScreenPermission:
            "Allow Xotch under Screen & System Audio Recording, then quit and reopen Xotch."
        case .microphoneDenied:
            "Recording without your microphone. Allow Xotch under Microphone to include it."
        case .failed(let text):
            text
        }
    }

    private var pane: PrivacyPane? {
        switch notice {
        case .needsScreenPermission: .screenCapture
        case .microphoneDenied: .microphone
        case .failed: nil
        }
    }
}

private struct EmptyShelf: View {
    @AppStorage(SettingsKey.captureIncludesMac) private var includesMac = true

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Theme.tertiaryInk, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay {
                VStack(spacing: 5) {
                    Text("Your screenshots and recordings appear here")
                        .font(.system(size: 13, weight: .semibold))
                    Text(includesMac
                         ? "Including the ones you take with ⌘⇧3, ⌘⇧4 and ⌘⇧5."
                         : "Xotch saves them in Pictures › Xotch unless you choose another folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
    }
}

private struct CaptureTile: View {
    let item: CaptureItem
    private var capture: CaptureService { .shared }

    var body: some View {
        FileTile(name: item.url.lastPathComponent, handlers: capture.tileHandlers(for: item), padding: 6) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.fill)
                    if let image = capture.thumbnails[item.id] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.isVideo ? "video" : "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.tertiaryInk)
                    }
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                }
                .frame(width: 104, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

                HStack(spacing: 4) {
                    Image(systemName: item.isVideo ? "video.fill" : (item.fromMac ? "command" : "camera.fill"))
                        .font(.system(size: 8, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Format.relative(item.date, to: context.date))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
            }
            .frame(width: 104)
        }
        .onAppear { capture.loadThumbnail(for: item) }
    }
}
