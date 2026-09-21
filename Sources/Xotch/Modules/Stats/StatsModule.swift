import SwiftUI

@MainActor
final class StatsModule: NotchModule {
    let id = "stats"
    let title = "System"
    let symbol = "gauge.with.dots.needle.33percent"
    func expandedView() -> AnyView { AnyView(StatsView()) }
}

private struct StatsView: View {
    private var stats: StatsService { .shared }

    var body: some View {
        Group {
            if let snapshot = stats.snapshot {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        StatTile(label: "CPU", value: percent(snapshot.cpu),
                                 detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores") {
                            Sparkline(values: stats.cpuHistory, tint: level(snapshot.cpu))
                        }
                        StatTile(label: "Memory", value: Format.bytes(snapshot.memoryUsed),
                                 detail: "of " + Format.bytes(snapshot.memoryTotal)) {
                            Meter(fraction: snapshot.memoryUsed / max(snapshot.memoryTotal, 1))
                        }
                        StatTile(label: "Network", value: "↓ " + Format.rate(snapshot.download),
                                 detail: "↑ " + Format.rate(snapshot.upload)) {
                            Sparkline(values: stats.normalizedNetworkHistory, tint: Color(red: 0.4, green: 0.75, blue: 1))
                        }
                    }
                    GridRow {
                        StatTile(label: "Disk", value: Format.bytes(snapshot.diskFree) + " free",
                                 detail: "of " + Format.bytes(snapshot.diskTotal)) {
                            Meter(fraction: 1 - snapshot.diskFree / max(snapshot.diskTotal, 1))
                        }
                        .gridCellColumns(snapshot.battery == nil ? 3 : 1)
                        if let battery = snapshot.battery {
                            BatteryTile(battery: battery)
                                .gridCellColumns(2)
                        }
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await stats.whileVisible() }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func level(_ value: Double) -> Color {
        value > 0.85 ? Theme.negative : (value > 0.6 ? Theme.accent : Theme.positive)
    }
}

private struct StatTile<Chart: View>: View {
    let label: String
    let value: String
    let detail: String
    @ViewBuilder var chart: Chart

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(label)
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
                Spacer(minLength: 2)
                chart.frame(height: 14)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Meter: View {
    let fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raisedFill)
                Capsule()
                    .fill(clamped > 0.9 ? Theme.negative : Theme.ink.opacity(0.85))
                    .frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private struct BatteryTile: View {
    let battery: BatteryInfo

    var body: some View {
        Tile(padding: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Battery")
                    HStack(spacing: 6) {
                        Text("\(battery.percent)%")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Image(systemName: symbol)
                            .foregroundStyle(battery.percent <= 20 && !battery.onPower ? Theme.negative : Theme.positive)
                    }
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryInk)
                    Spacer(minLength: 2)
                    Meter(fraction: Double(battery.percent) / 100)
                        .frame(height: 14)
                }
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Health", battery.health.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    detailRow("Cycles", battery.cycles.map(String.init) ?? "—")
                }
                .frame(width: 96)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryInk)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var status: String {
        if battery.isCharging { return "Charging" }
        if battery.onPower { return "On power" }
        if let minutes = battery.minutesLeft {
            return "\(minutes / 60)h \(minutes % 60)m left"
        }
        return "On battery"
    }
}
