import SwiftUI
import Observation

struct TrafficOverview: Equatable {
    var visitors: Int
    var pageviews: Int
    var bounceRate: Double?
    var sessionSeconds: Int?
    var revenue: Double?
    var currency: String?
    var conversionRate: Double?
}

struct TrafficRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let visitors: Int
}

/// Today's traffic from DataFast, with a website key (df_…).
/// Refreshes every minute while the module is on screen.
@MainActor
@Observable
final class AnalyticsService {
    static let shared = AnalyticsService()
    static let keychainAccount = "analytics.datafast"
    private static let base = "https://datafa.st/api/v1/analytics/"

    private(set) var isConnected = KeychainStore.read(AnalyticsService.keychainAccount) != nil
    private(set) var overview: TrafficOverview?
    private(set) var liveVisitors: Int?
    private(set) var pages: [TrafficRow] = []
    private(set) var referrers: [TrafficRow] = []
    private(set) var error: ConnectionError?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored private lazy var gate = VisibilityGate(interval: .seconds(60)) { [weak self] in
        Task { await self?.refresh() }
    }

    func whileVisible() async {
        await gate.whileVisible()
    }

    func connect(key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("dft_") {
            return "That's an account token. Use a website API key (df_…) instead."
        }
        do {
            _ = try await HTTP.get(URL(string: Self.base + "realtime")!, bearer: key)
        } catch {
            return ConnectionError.from(error).errorDescription
        }
        guard KeychainStore.save(key, for: Self.keychainAccount) else {
            return "Couldn't save the key to your Keychain."
        }
        isConnected = true
        await refresh()
        return nil
    }

    func disconnect() {
        KeychainStore.delete(Self.keychainAccount)
        isConnected = false
        overview = nil
        liveVisitors = nil
        pages = []
        referrers = []
        error = nil
        lastUpdated = nil
    }

    func refresh() async {
        guard !isRefreshing, let key = KeychainStore.read(Self.keychainAccount) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let today = ISODate.day(Date())
        let range = "startAt=\(today)&endAt=\(today)"
        let overviewURL = URL(string: Self.base + "overview?" + range)!
        let realtimeURL = URL(string: Self.base + "realtime")!
        let pagesURL = URL(string: Self.base + "pages?" + range + "&limit=5")!
        let referrersURL = URL(string: Self.base + "referrers?" + range + "&limit=5")!
        do {
            async let overviewData = HTTP.get(overviewURL, bearer: key)
            async let realtimeData = HTTP.get(realtimeURL, bearer: key)
            async let pagesData = HTTP.get(pagesURL, bearer: key)
            async let referrersData = HTTP.get(referrersURL, bearer: key)
            let (overviewJSON, realtimeJSON, pagesJSON, referrersJSON) = try await (overviewData, realtimeData, pagesData, referrersData)
            let parsed = try Self.parse(overview: overviewJSON, realtime: realtimeJSON, pages: pagesJSON, referrers: referrersJSON)
            withAnimation(Motion.switchModule) {
                overview = parsed.overview
                liveVisitors = parsed.live
                pages = parsed.pages
                referrers = parsed.referrers
            }
            error = nil
            lastUpdated = Date()
        } catch {
            self.error = ConnectionError.from(error)
        }
    }

    // MARK: - Parsing

    /// DataFast wraps results as {"status":"success","data":[…]}.
    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionError.unreadable
        }
        if let rows = object["data"] as? [[String: Any]] { return rows }
        if let row = object["data"] as? [String: Any] { return [row] }
        throw ConnectionError.unreadable
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private static func breakdown(_ data: Data, labelKeys: [String]) throws -> [TrafficRow] {
        try rows(data).compactMap { row in
            let label = labelKeys.lazy.compactMap { row[$0] as? String }.first { !$0.isEmpty }
                ?? row.values.lazy.compactMap { $0 as? String }.first
            guard let label else { return nil }
            return TrafficRow(label: label, visitors: Int(number(row["visitors"]) ?? 0))
        }
    }

    static func parse(overview: Data, realtime: Data, pages: Data, referrers: Data) throws
        -> (overview: TrafficOverview, live: Int?, pages: [TrafficRow], referrers: [TrafficRow]) {
        guard let first = try rows(overview).first else { throw ConnectionError.unreadable }
        let traffic = TrafficOverview(
            visitors: Int(number(first["visitors"]) ?? 0),
            pageviews: Int(number(first["pageviews"]) ?? 0),
            bounceRate: number(first["bounce_rate"]),
            sessionSeconds: number(first["avg_session_duration"]).map { Int($0) },
            revenue: number(first["revenue"]),
            currency: first["currency"] as? String,
            conversionRate: number(first["conversion_rate"])
        )
        let live = try rows(realtime).first.flatMap { number($0["visitors"]) }.map { Int($0) }
        return (traffic, live,
                try breakdown(pages, labelKeys: ["path", "page"]),
                try breakdown(referrers, labelKeys: ["referrer", "source", "domain", "hostname", "name"]))
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (isConnected, overview, liveVisitors, pages, referrers, error, lastUpdated)
        isConnected = true
        overview = TrafficOverview(visitors: 1284, pageviews: 3920, bounceRate: 41.2, sessionSeconds: 94,
                                   revenue: 612, currency: "USD", conversionRate: 2.4)
        liveVisitors = 17
        pages = [TrafficRow(label: "/", visitors: 820), TrafficRow(label: "/pricing", visitors: 311),
                 TrafficRow(label: "/changelog", visitors: 96)]
        referrers = [TrafficRow(label: "news.ycombinator.com", visitors: 402), TrafficRow(label: "x.com", visitors: 188),
                     TrafficRow(label: "Direct", visitors: 140)]
        error = nil
        lastUpdated = Date().addingTimeInterval(-40)
        body()
        (isConnected, overview, liveVisitors, pages, referrers, error, lastUpdated) = saved
    }

    static func selfTest() async -> [String] {
        let overview = #"{"status":"success","data":[{"visitors":12450,"new_visitors":3840,"pageviews":16890,"sessions":16890,"bounce_rate":42.1,"avg_session_duration":68,"currency":"USD","revenue":28450,"payments":328,"revenue_per_visitor":2.29,"conversion_rate":2.63}]}"#
        let realtime = #"{"status":"success","data":[{"visitors":42}]}"#
        let pages = #"{"status":"success","data":[{"hostname":"example.com","path":"/pricing","visitors":2150,"revenue":8934,"payments":96}]}"#
        let referrers = #"{"status":"success","data":[{"referrer":"google.com","visitors":900},{"visitors":12,"source":"Direct"}]}"#
        var lines: [String] = []
        do {
            let parsed = try parse(overview: Data(overview.utf8), realtime: Data(realtime.utf8),
                                   pages: Data(pages.utf8), referrers: Data(referrers.utf8))
            lines.append("datafast parse: visitors \(parsed.overview.visitors) pageviews \(parsed.overview.pageviews) bounce \(parsed.overview.bounceRate ?? -1) revenue \(parsed.overview.revenue ?? -1) \(parsed.overview.currency ?? "-") live \(parsed.live ?? -1) pages \(parsed.pages.map { "\($0.label)=\($0.visitors)" }) referrers \(parsed.referrers.map { "\($0.label)=\($0.visitors)" })")
        } catch {
            lines.append("datafast parse failed: \(error)")
        }
        do {
            _ = try await HTTP.get(URL(string: base + "realtime")!, bearer: "df_brim_selftest_invalid")
            lines.append("DataFast bogus key: unexpectedly accepted")
        } catch {
            lines.append("DataFast bogus key: \(ConnectionError.from(error))")
        }
        return lines
    }
    #endif
}

@MainActor
final class AnalyticsModule: NotchModule {
    let id = "analytics"
    let title = "Analytics"
    let symbol = "chart.bar"
    func expandedView() -> AnyView { AnyView(AnalyticsView()) }
}

private struct AnalyticsView: View {
    private var analytics: AnalyticsService { .shared }

    var body: some View {
        if analytics.isConnected {
            TrafficView()
                .task { await analytics.whileVisible() }
        } else {
            ConnectKeyForm(title: "See today's traffic from DataFast",
                           help: "Create a website API key (df_…) in your site's settings.",
                           placeholder: "df_…",
                           keyPage: URL(string: "https://datafa.st/dashboard")!,
                           onConnect: { key, _ in await analytics.connect(key: key) },
                           onCancel: nil)
        }
    }
}

private struct TrafficView: View {
    private var analytics: AnalyticsService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LiveTile(visitors: analytics.liveVisitors)
                MetricTile(label: "Visitors", value: analytics.overview.map { $0.visitors.formatted() } ?? "—")
                MetricTile(label: "Pageviews", value: analytics.overview.map { $0.pageviews.formatted() } ?? "—")
                MetricTile(label: "Bounce", value: analytics.overview?.bounceRate.map { "\(Int($0.rounded()))%" } ?? "—")
                if let revenue = analytics.overview?.revenue, revenue > 0 {
                    MetricTile(label: "Revenue", value: Money.format(revenue, currency: analytics.overview?.currency ?? "USD", compact: true))
                }
            }
            .frame(height: 64)

            HStack(alignment: .top, spacing: 8) {
                RankedList(title: "Top pages", rows: analytics.pages)
                RankedList(title: "Referrers", rows: analytics.referrers)
            }

            HStack {
                StatusLine(errors: analytics.error.map { ["DataFast": $0] } ?? [:],
                           lastUpdated: analytics.lastUpdated,
                           isRefreshing: analytics.isRefreshing)
                Spacer()
                Button("Disconnect") { analytics.disconnect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
    }
}

private struct LiveTile: View {
    let visitors: Int?
    @State private var pulse = false

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.positive)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulse ? 1.35 : 0.85)
                        .opacity(pulse ? 0.6 : 1)
                    SectionLabel("Live")
                }
                Text(visitors.map(String.init) ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .onAppear {
            guard !Motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(visitors ?? 0) visitors right now")
    }
}

private struct MetricTile: View {
    let label: String
    let value: String

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(label)
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RankedList: View {
    let title: String
    let rows: [TrafficRow]

    var body: some View {
        Tile(padding: 10) {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(title)
                if rows.isEmpty {
                    Text("Nothing yet today.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryInk)
                }
                let peak = Double(rows.map(\.visitors).max() ?? 1)
                ForEach(rows.prefix(4)) { row in
                    HStack(spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(alignment: .leading) {
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Theme.positive.opacity(0.14))
                                        .frame(width: geo.size.width * Double(row.visitors) / max(peak, 1))
                                }
                                .padding(.vertical, -2)
                                .padding(.horizontal, -4)
                            }
                        Text(row.visitors.formatted())
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
        }
    }
}
