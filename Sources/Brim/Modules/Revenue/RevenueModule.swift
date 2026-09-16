import SwiftUI

@MainActor
final class RevenueModule: NotchModule {
    let id = "revenue"
    let title = "Revenue"
    let symbol = "chart.line.uptrend.xyaxis"
    func expandedView() -> AnyView { AnyView(RevenueView()) }
    func start() { RevenueService.shared.start() }
    func stop() { RevenueService.shared.stop() }
}

private struct RevenueView: View {
    @State private var connecting: RevenueProviderKind?
    @State private var managing = false
    private var revenue: RevenueService { .shared }

    var body: some View {
        Group {
            if let connecting {
                ConnectKeyForm(title: "Connect \(connecting.name)",
                               help: connecting.keyHelp,
                               placeholder: connecting.keyPlaceholder,
                               keyPage: connecting.keyPage,
                               testModeLabel: connecting.hasTestMode ? "Use test mode" : nil,
                               onConnect: { key, testMode in
                                   let message = await revenue.connect(connecting, key: key, testMode: testMode)
                                   if message == nil { self.connecting = nil }
                                   return message
                               },
                               onCancel: { self.connecting = nil })
            } else if !revenue.isConnected || managing {
                ProviderPicker(connected: revenue.connected, isManaging: managing,
                               connect: { connecting = $0 },
                               disconnect: { revenue.disconnect($0) },
                               done: revenue.isConnected ? { managing = false } : nil)
            } else {
                TodayView(manage: { managing = true })
            }
        }
    }
}

private struct ProviderPicker: View {
    let connected: [RevenueProviderKind]
    let isManaging: Bool
    let connect: (RevenueProviderKind) -> Void
    let disconnect: (RevenueProviderKind) -> Void
    let done: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isManaging ? "Payment providers" : "See today's sales in the notch")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Connect with a read-only key. Each sale shows up as it happens, and today's total can sit beside the notch.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let done {
                    Button("Done", action: done)
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            HStack(spacing: 10) {
                ForEach(RevenueProviderKind.allCases) { kind in
                    let isConnected = connected.contains(kind)
                    Tile {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isConnected ? Theme.positive : Theme.raisedFill)
                                    .frame(width: 7, height: 7)
                                Text(kind.name)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text(isConnected ? "Connected" : "Not connected")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryInk)
                            Spacer(minLength: 0)
                            if isConnected {
                                Button("Disconnect") { disconnect(kind) }
                                    .buttonStyle(PillButtonStyle(prominent: false))
                            } else {
                                Button("Connect") { connect(kind) }
                                    .buttonStyle(PillButtonStyle())
                            }
                        }
                    }
                }
            }
            .frame(height: 110)
        }
    }
}

private struct TodayView: View {
    let manage: () -> Void
    @AppStorage(RevenueService.showTotalKey) private var showTotal = true
    private var revenue: RevenueService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Today")
                if let top = revenue.totals.first {
                    Text(Money.format(top.amount, currency: top.currency))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    ForEach(revenue.totals.dropFirst(), id: \.currency) { other in
                        Text("+ " + Money.format(other.amount, currency: other.currency))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                } else {
                    Text(Money.format(0, currency: "USD"))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Text(revenue.sales.count == 1 ? "1 sale" : "\(revenue.sales.count) sales")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)

                Spacer(minLength: 6)

                StatusLine(errors: revenue.errors, lastUpdated: revenue.lastUpdated,
                           isRefreshing: revenue.isRefreshing)
                HStack(spacing: 8) {
                    Toggle("Total in notch", isOn: $showTotal)
                        .toggleStyle(NotchSwitchStyle())
                        .onChange(of: showTotal) { _, _ in revenue.settingsChanged() }
                    Spacer(minLength: 0)
                    Button { Task { await revenue.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("Check now")
                    Button(action: manage) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .help("Payment providers")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
            }
            .frame(width: 220, alignment: .leading)

            Tile {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Latest sales")
                    if revenue.sales.isEmpty {
                        Text("No sales yet today. They'll appear here and beside the notch.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        NotchScroll {
                            VStack(spacing: 6) {
                                ForEach(revenue.sales) { SaleRow(sale: $0) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SaleRow: View {
    let sale: Sale

    var body: some View {
        HStack(spacing: 10) {
            Text(String(sale.provider.name.prefix(1)))
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Theme.raisedFill, in: Circle())
                .help(sale.provider.name)
            VStack(alignment: .leading, spacing: 0) {
                Text(sale.product ?? sale.provider.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text([sale.customer, Format.relative(sale.date)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("+" + Money.format(sale.amount, currency: sale.currency))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.positive)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Updated 2 min ago", or what went wrong and with which service.
struct StatusLine<Source: Hashable>: View {
    let errors: [Source: ConnectionError]
    let lastUpdated: Date?
    let isRefreshing: Bool
    var name: (Source) -> String = { "\($0)" }

    var body: some View {
        Group {
            if isRefreshing {
                Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.secondaryInk)
            } else if let failure = errors.first {
                Label(label(failure.key, failure.value),
                      systemImage: failure.value == .offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failure.value == .offline ? Theme.accent : Theme.negative)
                    .lineLimit(2)
            } else if let lastUpdated {
                Label("Updated " + Format.relative(lastUpdated), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
        .font(.system(size: 11))
    }

    private func label(_ source: Source, _ error: ConnectionError) -> String {
        let prefix = (source as? RevenueProviderKind)?.name ?? name(source)
        return "\(prefix): \(error.errorDescription ?? "")"
    }
}
