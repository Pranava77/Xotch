import SwiftUI

@MainActor
final class ClaudeModule: NotchModule {
    let id = "claude"
    let title = "Claude Code"
    let symbol = "sparkle"
    var tint: Color? { nil }
    func expandedView() -> AnyView { AnyView(ClaudeView()) }
    func start() { ClaudeLiveService.shared.start() }
}

private struct ClaudeView: View {
    private var usage: ClaudeUsageService { .shared }

    var body: some View {
        Group {
            if let summary = usage.summary {
                if summary.foundLogs {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TodayTile(today: summary.today)
                            StreakTile(summary: summary)
                                .frame(width: 130)
                            WeekTile(week: summary.week)
                        }
                        .frame(height: 104)
                        LiveSessionsTile()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        EmptyStateView(symbol: "sparkle",
                                       title: "No Claude Code activity yet",
                                       message: "Brim reads Claude Code's local logs in ~/.claude/projects. Use Claude Code and your usage shows up here.")
                            .frame(height: 90)
                        LiveSessionsTile()
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await usage.whileVisible() }
    }
}

/// Token counts read as K and M whatever the region (not lakh or crore).
private func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))
        .locale(Locale(identifier: "en_US")))
}

private struct TodayTile: View {
    let today: ClaudeDayStats

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Tokens today")
                Text(compact(today.totalTokens))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 2)
                HStack(spacing: 10) {
                    part("In", today.inputTokens)
                    part("Out", today.outputTokens)
                    part("Cache", today.cacheReadTokens + today.cacheWriteTokens)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func part(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiaryInk)
            Text(compact(value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }
}

private struct StreakTile: View {
    let summary: ClaudeUsageSummary

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Streak")
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(summary.streak > 0 ? ClaudeLiveService.tint : Theme.tertiaryInk)
                    Text(summary.streak == 1 ? "1 day" : "\(summary.streak) days")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 2)
                Text("\(summary.today.replies) replies · \(summary.today.toolCalls) tools")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                Text(summary.today.sessions.count == 1 ? "1 session" : "\(summary.today.sessions.count) sessions")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WeekTile: View {
    let week: [ClaudeDayStats]

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Last 7 days")
                let peak = Double(week.map(\.totalTokens).max() ?? 0)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                        let isToday = index == week.count - 1
                        VStack(spacing: 3) {
                            GeometryReader { geo in
                                let fraction = peak > 0 ? Double(day.totalTokens) / peak : 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isToday ? ClaudeLiveService.tint : Theme.selection)
                                    .frame(height: max(3, geo.size.height * fraction))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                            Text(day.day.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(isToday ? Theme.ink : Theme.tertiaryInk)
                        }
                        .help("\(day.day.formatted(.dateTime.weekday(.wide))): \(compact(day.totalTokens)) tokens")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens over the last seven days")
    }
}

private struct LiveSessionsTile: View {
    private var live: ClaudeLiveService { .shared }

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Live sessions")
                    Spacer()
                    if live.hookInstalled {
                        Button("Remove hook") { live.removeHook() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryInk)
                    }
                }
                if !live.hookInstalled {
                    HStack(alignment: .center, spacing: 12) {
                        Text("See when Claude is working, needs you, or is done, right beside the notch. Brim adds a small hook to ~/.claude/settings.json and backs the file up first.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add hook") { live.installHook() }
                            .buttonStyle(PillButtonStyle(tint: ClaudeLiveService.tint))
                    }
                } else if live.sessions.isEmpty {
                    Text(live.isListening
                         ? "No active sessions. Start Claude Code in a terminal and it shows up here."
                         : "Brim couldn't open its status socket. Quit and reopen Brim.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryInk)
                } else {
                    NotchScroll {
                        VStack(spacing: 5) {
                            ForEach(live.sessions) { SessionRow(session: $0) }
                        }
                    }
                }
                if let message = live.hookMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryInk)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(session.project)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(session.stateLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
            if case .waiting(let message) = session.state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Format.relative(session.updated))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch session.state {
        case .working: ClaudeLiveService.tint
        case .waiting: Theme.accent
        case .idle: Theme.positive
        }
    }
}
