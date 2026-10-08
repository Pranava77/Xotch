#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: the product images in docs/images, drawn from sample
/// data over a made-up wallpaper, so they never show anyone's own data.
///
///     scripts/debug.sh marketing docs/images
///
/// With `promo`, the shots for the promotional film instead (scripts/make-promo.sh).
@MainActor
enum MarketingShots {
    static func render(to directory: String, promo: Bool = false) async {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else {
            return
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kit = ShaderKit.shared
        kit.prepare()
        for _ in 0..<60 where !kit.isReady {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let center = ActivityCenter.shared
        let stashed = center.debugStash()
        defer { center.debugRestore(stashed) }
        let geometry = NotchGeometry(screen: screen)
        let clock = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now

        func model(_ configure: (NotchViewModel) -> Void) -> NotchViewModel {
            let model = NotchViewModel(geometry: geometry)
            configure(model)
            return model
        }

        func open(_ moduleID: String) -> NotchViewModel {
            model {
                $0.phase = .open
                $0.selectedModuleID = moduleID
            }
        }

        // JPEG: the wallpaper's gradients make PNGs several megabytes.
        /// `time` is seconds into a film sequence; `name` may hold a folder.
        func save(_ name: String, _ model: NotchViewModel, size: CGSize, scale: CGFloat = 2, status: Bool = false,
                  time: Double? = nil, hidesTiles: Bool = false) {
            let scene = Scene(model: model, clock: clock, showsStatus: status)
                .frame(width: size.width, height: size.height)
                .environment(\.snapshotMode, true)
                .environment(\.snapshotClearGlass, true)
                .environment(\.snapshotDate, clock)
                .environment(\.snapshotTime, time)
                .environment(\.snapshotHidesTiles, hidesTiles)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
                                                                           properties: [.compressionFactor: 0.86]) else { return }
            let file = folder.appendingPathComponent("\(name).jpg")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? jpeg.write(to: file)
        }

        if promo {
            renderPromo(folder: folder, center: center, model: model, open: open,
                        save: { save($0, $1, size: $2, scale: $3, status: true, time: $4, hidesTiles: $0 == "home-empty") })
            return
        }

        let openSize = CGSize(width: 840, height: 300)
        // Home is wider while the mascot and the mirror have tiles.
        let homeSize = CGSize(width: Layout.homeWidth(sideTiles: 2) + 140, height: 300)
        let earSize = CGSize(width: 520, height: 50)

        withSampleData {
            do {
                save("hero", open("home"), size: CGSize(width: Layout.homeWidth(sideTiles: 2) + 320, height: 400), status: true)
                for module in ["media", "calendar", "timers", "clipboard", "shelf", "capture", "todos", "stats", "claude"] {
                    save("module-\(module)", open(module), size: openSize, scale: 1.5)
                }
                // The chat opens taller than the other modules.
                save("module-ai", open(AIModule.moduleID),
                     size: CGSize(width: openSize.width, height: Layout.tallOpenHeight + 40), scale: 1.5)
                // And before the first message.
                AIChatService.shared.withoutMessages {
                    save("ai-welcome", open(AIModule.moduleID),
                         size: CGSize(width: openSize.width, height: Layout.tallOpenHeight + 40), scale: 1.5)
                }
                let palette = open("home")
                palette.isPinned = true
                palette.palette.isOpen = true
                palette.palette.query = "10"
                save("palette", palette, size: homeSize, scale: 1.5)
                // The AI asking before it changes anything, in the bigger chat.
                AIChatService.shared.withToolSample {
                    AIChatService.shared.withExpanded {
                        save("ai-tools", open(AIModule.moduleID), size: CGSize(width: 1100, height: 620), scale: 1.5)
                    }
                }
                // A reply with headings, steps, a table and code.
                AIChatService.shared.withCodeSample {
                    AIChatService.shared.withExpanded {
                        save("ai-reply", open(AIModule.moduleID), size: CGSize(width: 1100, height: 620), scale: 1.5)
                    }
                }
                // Dictation, mid-sentence.
                DictationService.shared.withSample {
                    save("module-dictation", open("dictation"), size: openSize, scale: 1.5)
                }
            }

            // The sample scratchpad shows itself beside the notch; set it aside.
            let samples = center.debugStash()
            do {
                // Beside the closed notch.
                let end = Date().addingTimeInterval(18 * 60 + 24)
                let ears: [(String, LiveActivity)] = [
                    ("timer", LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                           content: .countdown(until: end), tint: TimerKind.focus.tint,
                                           progress: .timed(start: end.addingTimeInterval(-25 * 60), end: end))),
                    ("music", LiveActivity(moduleID: "media", symbol: "music.note", content: .playing,
                                           tint: MediaService.shared.tint, image: MediaService.shared.artwork)),
                    ("claude", LiveActivity(moduleID: "claude", symbol: "sparkle", content: .text("Editing"),
                                            tint: ClaudeLiveService.tint, pulse: .calm)),
                    ("recording", CaptureService.recordingActivity(since: Date().addingTimeInterval(-(2 * 60 + 14)))),
                    ("download", LiveActivity(moduleID: "downloads", symbol: "arrow.down", content: .text("62%"),
                                              tint: Theme.accent,
                                              progress: .fraction(0.62))),
                    ("volume", LiveActivity(moduleID: "volume", symbol: "speaker.wave.2.fill", content: .level(0.56),
                                            tint: .white)),
                    ("dictation", LiveActivity(moduleID: "dictation", symbol: "mic.fill", content: .listening,
                                               tint: DictationService.tint, pulse: .calm)),
                ]
                for (name, activity) in ears {
                    center.setOngoing(activity, for: activity.moduleID)
                    save("ears-\(name)", model { _ in }, size: earSize, scale: 2)
                    center.setOngoing(nil, for: activity.moduleID)
                }
                // Adiyogi resting in the left ear of an otherwise quiet notch.
                center.debugShowCompanion(.adiyogi)
                save("ears-adiyogi", model { _ in }, size: earSize, scale: 2)
                // The mascot in the same place, watching the pointer.
                center.debugShowCompanion(.mascot)
                save("ears-mascot", model { _ in }, size: earSize, scale: 2)
                center.debugShowCompanion(.none)
            }
            center.debugRestore(samples)
        }

        saveIcon(to: folder.appendingPathComponent("icon.png"))
    }

    /// The film's shots: whole 1440 × 810 "screens" at 3840 × 2160 pixels, so the
    /// film can push in close and stay sharp, and geometry.json with the notch's
    /// size in each, so the film can grow the notch open over the real shot.
    private static func renderPromo(folder: URL, center: ActivityCenter,
                                    model: ((NotchViewModel) -> Void) -> NotchViewModel,
                                    open: (String) -> NotchViewModel,
                                    save: @escaping (String, NotchViewModel, CGSize, CGFloat, Double?) -> Void) {
        let screen = CGSize(width: 1440, height: 810)
        let scale: CGFloat = 8.0 / 3.0
        var shapes: [String: [Double]] = [:]
        var sequences: [String: Int] = [:]
        func shot(_ name: String, _ model: NotchViewModel) {
            save(name, model, screen, scale, nil)
            shapes[name] = [model.bodySize.width, model.bodySize.height, model.shoulder, model.cornerRadius].map(Double.init)
        }
        /// Frames at 30 a second, at 2x, so things move: `frame` sets up each one
        /// for its time and calls `capture` with the notch while that state holds.
        func sequence(_ name: String, seconds: Double,
                      _ frame: (_ t: Double, _ capture: (NotchViewModel) -> Void) -> Void) {
            let count = Int(seconds * 30)
            for index in 0..<count {
                let t = Double(index) / 30
                frame(t) { model in
                    save(String(format: "\(name)/%04d", index), model, screen, 2, t)
                    if index == count - 1 {
                        shapes[name] = [model.bodySize.width, model.bodySize.height, model.shoulder, model.cornerRadius].map(Double.init)
                    }
                }
            }
            sequences[name] = count
        }

        withSampleData {
            shot("home", open("home"))
            // Home's own background, which the film's tiles land on.
            shot("home-empty", open("home"))
            for module in ["todos", "calendar", "timers", "media", "capture", "claude", "clipboard", "shelf"] {
                shot(module, open(module))
            }
            AIChatService.shared.withToolSample {
                AIChatService.shared.withExpanded { shot("ai-tools", open(AIModule.moduleID)) }
            }
            AIChatService.shared.withCodeSample {
                AIChatService.shared.withExpanded { shot("ai-reply", open(AIModule.moduleID)) }
            }
            DictationService.shared.withSample { shot("dictation", open("dictation")) }
            let palette = open("home")
            palette.isPinned = true
            palette.palette.isOpen = true
            palette.palette.query = "10"
            shot("palette", palette)

            // The AI planning an afternoon, as it happens: the question, a
            // lookup, the reply arriving, the steps one by one, then Allow.
            sequence("ai-live", seconds: 7) { t, capture in
                let steps = t < 0.4 ? 0 : t < 2.6 ? 1 : min(5, 2 + Int((t - 2.6) / 0.35))
                let words = t < 1.0 ? 0 : min(11, Int((t - 1.0) / 1.5 * 11) + 1)
                AIChatService.shared.withToolSample(steps: steps, words: words, allowed: t >= 5.15) {
                    AIChatService.shared.withExpanded { capture(open(AIModule.moduleID)) }
                }
            }
            // Dictation hearing a sentence, a word at a time.
            sequence("dictation-live", seconds: 5) { t, capture in
                DictationService.shared.withSample(words: min(18, Int(max(t - 0.3, 0) / 3.7 * 18))) {
                    capture(open("dictation"))
                }
            }

            // The closed notch: quiet, then with each kind of ear.
            let samples = center.debugStash()
            shot("screen-quiet", model { _ in })
            let end = Date().addingTimeInterval(18 * 60 + 24)
            let ears: [(String, LiveActivity)] = [
                ("music", LiveActivity(moduleID: "media", symbol: "music.note", content: .playing,
                                       tint: MediaService.shared.tint, image: MediaService.shared.artwork)),
                ("timer", LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                       content: .countdown(until: end), tint: TimerKind.focus.tint,
                                       progress: .timed(start: end.addingTimeInterval(-25 * 60), end: end))),
                ("claude", LiveActivity(moduleID: "claude", symbol: "sparkle", content: .text("Editing"),
                                        tint: ClaudeLiveService.tint, pulse: .calm)),
                ("dictation", LiveActivity(moduleID: "dictation", symbol: "mic.fill", content: .listening,
                                           tint: DictationService.tint, pulse: .calm)),
            ]
            for (name, activity) in ears {
                center.setOngoing(activity, for: activity.moduleID)
                shot("screen-\(name)", model { _ in })
                center.setOngoing(nil, for: activity.moduleID)
            }
            center.debugShowCompanion(.mascot)
            shot("screen-mascot", model { _ in })
            center.debugShowCompanion(.none)

            // The ears, moving: music, a timer counting down, the microphone.
            let music = ears[0].1
            center.setOngoing(music, for: music.moduleID)
            sequence("ears-music", seconds: 4) { _, capture in capture(model { _ in }) }
            center.setOngoing(nil, for: music.moduleID)
            let remaining = 18.0 * 60 + 24
            sequence("ears-timer", seconds: 3) { t, capture in
                let until = Date().addingTimeInterval(remaining - t)
                center.setOngoing(LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                               content: .countdown(until: until), tint: TimerKind.focus.tint,
                                               progress: .timed(start: until.addingTimeInterval(-25 * 60), end: until)),
                                  for: "timers")
                capture(model { _ in })
            }
            center.setOngoing(nil, for: "timers")
            let mic = ears[3].1
            center.setOngoing(mic, for: mic.moduleID)
            sequence("ears-dictation", seconds: 2) { _, capture in capture(model { _ in }) }
            center.setOngoing(nil, for: mic.moduleID)
            center.debugRestore(samples)
        }

        let geometry: [String: Any] = ["screen": [screen.width, screen.height].map(Double.init),
                                       "scale": Double(scale), "shapes": shapes, "sequences": sequences]
        if let json = try? JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: folder.appendingPathComponent("geometry.json"))
        }
        saveIcon(to: folder.appendingPathComponent("icon.png"), side: 768)
    }

    /// Adiyogi on a rounded square, as the README's app icon.
    private static func saveIcon(to url: URL, side: CGFloat = 256) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 2)
            AdiyogiMark(size: side * 0.72, ink: .white)
                .offset(y: side * 0.06)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The top of a Mac screen: wallpaper, menu bar, and the notch.
    private struct Scene: View {
        let model: NotchViewModel
        let clock: Date
        let showsStatus: Bool

        var body: some View {
            let shape = NotchShape(shoulderRadius: model.shoulder, cornerRadius: model.cornerRadius)
            ZStack(alignment: .top) {
                Wallpaper()
                MenuBar(height: model.closedSize.height, clock: clock, showsStatus: showsStatus)
                if model.phase == .open {
                    // What the material shows: the wallpaper, blurred.
                    Wallpaper()
                        .blur(radius: 26)
                        .saturation(1.4)
                        .brightness(0.06)
                        .mask(alignment: .top) {
                            shape.frame(width: model.bodySize.width + model.shoulder * 2,
                                        height: model.bodySize.height)
                        }
                }
                ShellView(model: model, actions: SnapshotActions())
            }
        }
    }

    private struct Wallpaper: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.16),
                                        Color(red: 0.13, green: 0.08, blue: 0.27)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Color(red: 0.55, green: 0.27, blue: 0.93).opacity(0.85), .clear],
                               center: UnitPoint(x: 0.12, y: 0.95), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color(red: 1, green: 0.48, blue: 0.3).opacity(0.8), .clear],
                               center: UnitPoint(x: 0.9, y: 1.05), startRadius: 0, endRadius: 480)
                RadialGradient(colors: [Color(red: 0.13, green: 0.7, blue: 0.72).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.62, y: 0.35), startRadius: 0, endRadius: 360)
            }
        }
    }

    private struct MenuBar: View {
        let height: CGFloat
        let clock: Date
        let showsStatus: Bool

        var body: some View {
            HStack(spacing: 16) {
                Spacer()
                if showsStatus {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text(clock, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(Color.black.opacity(0.22))
        }
    }
}
#endif
