import SwiftUI

@MainActor
final class MediaModule: NotchModule {
    let id = "media"
    let title = "Now Playing"
    let symbol = "music.note"

    var tint: Color? {
        MediaService.shared.nowPlaying == nil ? nil : MediaService.shared.tint
    }

    func expandedView() -> AnyView { AnyView(MediaView()) }
    func start() { MediaService.shared.start() }
    func stop() { MediaService.shared.stop() }
}

private struct MediaView: View {
    private var media: MediaService { .shared }

    var body: some View {
        if let playing = media.nowPlaying {
            HStack(spacing: 22) {
                Artwork(image: media.artwork, tint: media.tint, size: 132)
                    .onTapGesture { media.openSourceApp() }
                    .help("Open \(playing.appName ?? "the app")")

                VStack(alignment: .leading, spacing: 0) {
                    Text(playing.title)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    Text([playing.artist, playing.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .padding(.top, 3)
                    if let appName = playing.appName {
                        Label(appName, systemImage: "play.rectangle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryInk)
                            .padding(.top, 6)
                    }

                    Spacer(minLength: 12)

                    if playing.duration > 0 {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            ProgressScrubber(position: playing.position(at: context.date),
                                             duration: playing.duration,
                                             tint: media.tint) { media.seek(to: $0) }
                        }
                    }

                    HStack(spacing: 14) {
                        Button { media.previous() } label: { Image(systemName: "backward.fill") }
                            .buttonStyle(IconButtonStyle(size: 36))
                            .accessibilityLabel("Previous track")
                        Button { media.togglePlayPause() } label: {
                            Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                                .swapTransition(on: playing.isPlaying)
                        }
                        .buttonStyle(IconButtonStyle(size: 44, prominent: true))
                        .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
                        Button { media.next() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(IconButtonStyle(size: 36))
                            .accessibilityLabel("Next track")
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if media.isAvailable {
            EmptyStateView(symbol: "music.note",
                           title: "Nothing playing",
                           message: "Play something in Music, Spotify, a browser or any other app and it shows up here.")
        } else {
            EmptyStateView(symbol: "exclamationmark.triangle",
                           title: "Now Playing isn't available",
                           message: "macOS didn't answer Brim's request for media info.",
                           buttonTitle: "Try again") { media.retry() }
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [tint, tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .shadow(color: tint.opacity(0.45), radius: size * 0.16, y: size * 0.04)
    }
}

/// Playback bar you can drag to seek.
private struct ProgressScrubber: View {
    let position: Double
    let duration: Double
    let tint: Color
    let onSeek: (Double) -> Void
    @State private var dragPosition: Double?

    var body: some View {
        let shown = dragPosition ?? position
        VStack(spacing: 4) {
            GeometryReader { geo in
                let fraction = CGFloat(min(max(shown / duration, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raisedFill)
                    Capsule().fill(tint).frame(width: geo.size.width * fraction)
                }
                .frame(height: dragPosition == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragPosition = Double(min(max(value.location.x / geo.size.width, 0), 1)) * duration
                    }
                    .onEnded { _ in
                        if let dragPosition { onSeek(dragPosition) }
                        dragPosition = nil
                    })
                .animation(Motion.press, value: dragPosition == nil)
            }
            .frame(height: 12)

            HStack {
                Text(Format.clock(shown))
                Spacer()
                Text("-" + Format.clock(duration - shown))
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiaryInk)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Format.clock(shown)) of \(Format.clock(duration))")
    }
}
