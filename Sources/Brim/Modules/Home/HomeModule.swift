import SwiftUI

@MainActor
final class HomeModule: NotchModule {
    let id = "home"
    let title = "Home"
    let symbol = "house"
    func expandedView() -> AnyView { AnyView(HomeView()) }
}

/// A summary of the other modules. Each card jumps to its module.
private struct HomeView: View {
    private var media: MediaService { .shared }
    private var calendar: CalendarService { .shared }
    private var timers: TimerService { .shared }
    private var weather: WeatherService { .shared }
    private var revenue: RevenueService { .shared }
    @AppStorage(SettingsKey.showMascot) private var showMascot = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: 46, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    Spacer(minLength: 4)
                    if showMascot {
                        MascotBadge(mood: ActivityCenter.shared.mood, size: 48)
                            .padding(.top, 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if let report = weather.report {
                    Button { ScreenManager.shared.show(moduleID: "weather") } label: {
                        HStack(spacing: 8) {
                            Image(systemName: WeatherCode.symbol(report.current.code, isDay: report.current.isDay))
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(report.current.temperature.rounded()))° · \(WeatherCode.description(report.current.code))")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(report.place)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(HoverButtonStyle())
                }
                if revenue.isConnected {
                    Button { ScreenManager.shared.show(moduleID: "revenue") } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.positive)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(revenue.totals.first.map { Money.format($0.amount, currency: $0.currency) } ?? "No sales yet")
                                    .font(.system(size: 13, weight: .semibold))
                                    .monospacedDigit()
                                Text(revenue.sales.count == 1 ? "1 sale today" : "\(revenue.sales.count) sales today")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(HoverButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .frame(width: 210, alignment: .leading)

            VStack(spacing: 10) {
                nextEventCard
                if let playing = media.nowPlaying {
                    mediaCard(playing)
                } else if timers.isActive || timers.isStopwatchRunning {
                    timerCard
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task {
            calendar.refresh()
            weather.refreshIfAllowed()
        }
    }

    private var nextEventCard: some View {
        HomeCard(moduleID: "calendar") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(calendar.nextEvent?.calendarColor.color ?? Theme.tertiaryInk)
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Up next")
                    if let event = calendar.nextEvent {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(event.start <= .now ? "Happening now" : event.start.formatted(.relative(presentation: .named)).capitalizedFirst)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        Text(calendar.needsAccess ? "Connect your calendar" : "Nothing else this week")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                Spacer(minLength: 0)
                if let url = calendar.nextEvent?.joinURL {
                    Button("Join") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(tint: Theme.positive))
                }
            }
        }
    }

    private func mediaCard(_ playing: NowPlaying) -> some View {
        HomeCard(moduleID: "media") {
            HStack(spacing: 10) {
                Artwork(image: media.artwork, tint: media.tint, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playing.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(playing.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { media.togglePlayPause() } label: {
                    Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
            }
        }
    }

    private var timerCard: some View {
        HomeCard(moduleID: "timers") {
            HStack(spacing: 10) {
                Image(systemName: timers.kind?.symbol ?? "stopwatch.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(timers.kind?.tint ?? Theme.accent)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timers.kind?.title ?? "Stopwatch")
                        .font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timers.isActive
                             ? Format.clock(timers.remaining(at: context.date)) + (timers.isRunning ? " left" : " · paused")
                             : Format.clock(timers.stopwatchElapsed(at: context.date)))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct HomeCard<Content: View>: View {
    let moduleID: String
    @ViewBuilder var content: Content

    var body: some View {
        Button { ScreenManager.shared.show(moduleID: moduleID) } label: {
            content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
