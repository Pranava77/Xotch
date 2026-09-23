#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: the product images in docs/images, drawn from sample
/// data over a made-up wallpaper, so they never show anyone's own data.
///
///     scripts/debug.sh marketing docs/images
@MainActor
enum MarketingShots {
    static func render(to directory: String) async {
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
        let theme = ThemeStore.shared
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
        func save(_ name: String, _ model: NotchViewModel, size: CGSize, scale: CGFloat = 2, status: Bool = false) {
            let scene = Scene(model: model, clock: clock, showsStatus: status)
                .frame(width: size.width, height: size.height)
                .environment(\.snapshotMode, true)
                .environment(\.snapshotClearGlass, true)
                .environment(\.snapshotDate, clock)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
                                                                           properties: [.compressionFactor: 0.86]) else { return }
            try? jpeg.write(to: folder.appendingPathComponent("\(name).jpg"))
        }

        let openSize = CGSize(width: 700, height: 340)
        let earSize = CGSize(width: 520, height: 50)

        withSampleData {
            theme.withPalette(Palette.midnight.id) {
                save("hero", open("home"), size: CGSize(width: 1080, height: 400), status: true)
                for module in ["media", "calendar", "timers", "clipboard", "shelf", "capture", "stats", "claude"] {
                    save("module-\(module)", open(module), size: openSize, scale: 1.5)
                }
                // Life asks for a bigger notch, so its shot needs a bigger scene.
                save("module-life", open("life"), size: CGSize(width: 1250, height: 650), scale: 1.2)
                // The routine is half of what Life is, so it gets its own shot.
                LifeService.debugTab = "Routine"
                save("module-life-routine", open("life"), size: CGSize(width: 1250, height: 650), scale: 1.2)
                LifeService.debugReset()
                let palette = open("home")
                palette.isPinned = true
                palette.palette.isOpen = true
                palette.palette.query = "10"
                save("palette", palette, size: openSize, scale: 1.5)
            }
            for id in [Palette.midnight.id, Palette.smoke.id, Palette.aurora.id] {
                theme.withPalette(id) {
                    save("theme-\(id)", open("home"), size: openSize, scale: 1.5)
                }
            }

            // The sample scratchpad shows itself beside the notch; set it aside.
            let samples = center.debugStash()
            theme.withPalette(Palette.midnight.id) {
                // Beside the closed notch.
                let end = Date().addingTimeInterval(18 * 60 + 24)
                let ears: [(String, LiveActivity)] = [
                    ("timer", LiveActivity(moduleID: "timers", symbol: TimerKind.focus.symbol,
                                           content: .countdown(until: end), tint: TimerKind.focus.tint,
                                           progress: .timed(start: end.addingTimeInterval(-25 * 60), end: end))),
                    ("music", LiveActivity(moduleID: "media", symbol: "music.note", content: .playing,
                                           tint: MediaService.shared.tint, image: MediaService.shared.artwork)),
                    ("claude", LiveActivity(moduleID: "claude", symbol: "sparkle", content: .text("Editing"),
                                            tint: ClaudeLiveService.tint, earWidth: 110, pulse: .calm)),
                    ("recording", CaptureService.recordingActivity(since: Date().addingTimeInterval(-(2 * 60 + 14)))),
                    ("download", LiveActivity(moduleID: "downloads", symbol: "arrow.down", content: .text("62%"),
                                              tint: Palette.midnight.accent.color, earWidth: 90,
                                              progress: .fraction(0.62))),
                    ("volume", LiveActivity(moduleID: "volume", symbol: "speaker.wave.2.fill", content: .level(0.56),
                                            tint: .white, earWidth: 96)),
                ]
                for (name, activity) in ears {
                    center.setOngoing(activity, for: activity.moduleID)
                    save("ears-\(name)", model { _ in }, size: earSize, scale: 2)
                    center.setOngoing(nil, for: activity.moduleID)
                }
            }
            center.debugRestore(samples)
        }

        saveIcon(to: folder.appendingPathComponent("icon.png"))
    }

    /// The mascot on a rounded square, as the README's app icon.
    private static func saveIcon(to url: URL) {
        let side: CGFloat = 256
        let icon = ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 2)
            if let mascot = MascotView.image(mood: .idle, side: side * 0.86) {
                Image(nsImage: mascot)
                    .offset(y: side * 0.04)
            }
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
                if model.phase == .open, Theme.palette.material == .glass {
                    // What glass would show: the wallpaper, blurred.
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
