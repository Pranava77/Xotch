import SwiftUI

// Stand-ins so the Phase 1 shell has something to switch between.
// Each one is replaced by a real module in Phase 2.

@MainActor
final class HomeModule: NotchModule {
    let id = "home"
    let title = "Home"
    let symbol = "house.fill"
    func expandedView() -> AnyView { AnyView(HomeView()) }
}

@MainActor
final class MediaModule: NotchModule {
    let id = "media"
    let title = "Now Playing"
    let symbol = "music.note"
    func expandedView() -> AnyView { AnyView(MediaPlaceholderView()) }
}

@MainActor
final class TimersModule: NotchModule {
    let id = "timers"
    let title = "Timers"
    let symbol = "timer"
    func expandedView() -> AnyView { AnyView(TimersPlaceholderView()) }
}

@MainActor
final class ShelfModule: NotchModule {
    let id = "shelf"
    let title = "Shelf"
    let symbol = "tray.full.fill"
    func expandedView() -> AnyView { AnyView(ShelfPlaceholderView()) }
}

// MARK: - Views

private struct HomeView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 9) {
                Text("TRY THE SHELL")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.tertiaryInk)
                ShortcutRow(keys: "⌘1–4", text: "Switch modules")
                ShortcutRow(keys: "Swipe", text: "Two fingers, sideways")
                ShortcutRow(keys: "Esc", text: "Close the notch")
                Button {
                    ScreenManager.shared.closeAll()
                    ActivityCenter.shared.postDemo()
                } label: {
                    Label("Send a live activity", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 4)
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 54, alignment: .leading)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}

private struct MediaPlaceholderView: View {
    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.55),
                                              Color(red: 0.52, green: 0.27, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 104, height: 104)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing playing")
                    .font(.system(size: 17, weight: .semibold))
                Text("Now Playing arrives in Phase 2")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                Capsule()
                    .fill(Theme.fill)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.secondaryInk).frame(width: 64, height: 4)
                    }
                    .padding(.top, 10)
                HStack(spacing: 26) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "play.fill").font(.system(size: 22))
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 16))
                .foregroundStyle(Theme.tertiaryInk)
                .padding(.top, 6)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TimersPlaceholderView: View {
    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().stroke(Theme.fill, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("25:00")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 108, height: 108)

            VStack(alignment: .leading, spacing: 8) {
                Text("Focus")
                    .font(.system(size: 17, weight: .semibold))
                Text("Pomodoro, countdown and stopwatch arrive in Phase 2. For now, see how a running timer looks beside the notch.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    ScreenManager.shared.closeAll()
                    ActivityCenter.shared.post(LiveActivity(moduleID: "timers", symbol: "timer",
                                                            text: "24:59", tint: Theme.accent))
                } label: {
                    Label("Preview in the notch", systemImage: "timer")
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ShelfPlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Theme.tertiaryInk, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.secondaryInk)
                    Text("Drop files here")
                        .font(.system(size: 14, weight: .semibold))
                    Text("The shelf arrives in Phase 2")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
    }
}
