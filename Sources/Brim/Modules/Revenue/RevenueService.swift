import SwiftUI
import Observation

/// Today's sales from Stripe, Polar and Dodo Payments. Checks every 90 seconds
/// with read-only keys from the Keychain; new sales show as a banner, and
/// today's total can stay beside the notch.
@MainActor
@Observable
final class RevenueService {
    static let shared = RevenueService()
    static let showTotalKey = "revenue.showTotal"

    private(set) var connected: [RevenueProviderKind] = []
    private(set) var sales: [Sale] = []
    private(set) var errors: [RevenueProviderKind: ConnectionError] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var hasLoadedOnce = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var day = Calendar.current.startOfDay(for: .now)

    init() {
        UserDefaults.standard.register(defaults: [Self.showTotalKey: true])
    }

    var isConnected: Bool { !connected.isEmpty }

    /// Totals per currency, largest first.
    var totals: [(currency: String, amount: Double)] {
        Dictionary(grouping: sales, by: \.currency)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.1 > $1.1 }
    }

    func start() {
        // Checking existence doesn't read the secret, so it never prompts.
        connected = RevenueProviderKind.allCases.filter { KeychainStore.contains($0.keychainAccount) }
        isRunning = true
        schedulePolling()
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        ActivityCenter.shared.setOngoing(nil, for: "revenue")
    }

    // MARK: - Connections

    /// Checks the key against the provider, then stores it. Returns an error message on failure.
    func connect(_ kind: RevenueProviderKind, key: String, testMode: Bool) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste a key first." }
        if kind == .stripe && (key.hasPrefix("sk_live_") || key.hasPrefix("sk_test_")) {
            return "That's a secret key with full access. Use a restricted key (rk_…) with read access to Charges."
        }
        do {
            _ = try await kind.provider(testMode: testMode).sales(since: Date().addingTimeInterval(-3600), key: key)
        } catch {
            return ConnectionError.from(error).errorDescription
        }
        guard KeychainStore.save(key, for: kind.keychainAccount) else {
            return "Couldn't save the key to your Keychain."
        }
        UserDefaults.standard.set(testMode, forKey: kind.testModeKey)
        if !connected.contains(kind) {
            connected.append(kind)
        }
        await refresh()
        schedulePolling()
        return nil
    }

    func disconnect(_ kind: RevenueProviderKind) {
        KeychainStore.delete(kind.keychainAccount)
        connected.removeAll { $0 == kind }
        errors[kind] = nil
        withAnimation(Motion.switchModule) { sales.removeAll { $0.provider == kind } }
        updateActivity()
        if connected.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            lastUpdated = nil
        }
    }

    // MARK: - Polling

    private func schedulePolling() {
        pollTask?.cancel()
        guard isConnected, isRunning else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let rateLimited = self?.errors.values.contains(.rateLimited) ?? false
                try? await Task.sleep(for: .seconds(rateLimited ? 300 : 90))
            }
        }
    }

    func refresh() async {
        guard isConnected, isRunning, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let today = Calendar.current.startOfDay(for: .now)
        if today != day {
            day = today
            sales = []
        }

        let jobs = connected.compactMap { kind -> (RevenueProviderKind, any RevenueProvider, String)? in
            guard let key = KeychainStore.read(kind.keychainAccount) else { return nil }
            return (kind, kind.provider(testMode: UserDefaults.standard.bool(forKey: kind.testModeKey)), key)
        }
        var fetched: [RevenueProviderKind: Result<[Sale], ConnectionError>] = [:]
        await withTaskGroup(of: (RevenueProviderKind, Result<[Sale], ConnectionError>).self) { group in
            for (kind, provider, key) in jobs {
                group.addTask {
                    do {
                        return (kind, .success(try await provider.sales(since: today, key: key)))
                    } catch {
                        return (kind, .failure(ConnectionError.from(error)))
                    }
                }
            }
            for await (kind, result) in group {
                fetched[kind] = result
            }
        }

        var updated = sales
        for (kind, result) in fetched {
            switch result {
            case .success(let fresh):
                errors[kind] = nil
                updated.removeAll { $0.provider == kind }
                updated += fresh
            case .failure(let error):
                errors[kind] = error
            }
        }
        updated.sort { $0.date > $1.date }

        let newSales = updated.filter { !announced.contains($0.id) }
        announced.formUnion(updated.map(\.id))
        withAnimation(Motion.switchModule) { sales = updated }
        if fetched.values.contains(where: { if case .success = $0 { true } else { false } }) {
            lastUpdated = Date()
        }
        if hasLoadedOnce {
            // Oldest first, so the banner queue ends on the newest sale.
            for sale in newSales.sorted(by: { $0.date < $1.date }).suffix(5) {
                announce(sale)
            }
        }
        hasLoadedOnce = true
        updateActivity()
    }

    private func announce(_ sale: Sale) {
        ActivityCenter.shared.post(LiveActivity(moduleID: "revenue", symbol: "dollarsign.circle.fill",
                                                content: .text("+" + Money.format(sale.amount, currency: sale.currency)),
                                                tint: Theme.positive, earWidth: 110, duration: .seconds(5)))
        if UserDefaults.standard.bool(forKey: SettingsKey.celebrateSales) {
            ActivityCenter.shared.celebrate()
        }
    }

    func settingsChanged() {
        updateActivity()
    }

    private func updateActivity() {
        guard isRunning, UserDefaults.standard.bool(forKey: Self.showTotalKey), let top = totals.first else {
            ActivityCenter.shared.setOngoing(nil, for: "revenue")
            return
        }
        ActivityCenter.shared.setOngoing(
            LiveActivity(moduleID: "revenue", symbol: "chart.line.uptrend.xyaxis",
                         content: .ticker([
                             Money.format(top.amount, currency: top.currency, compact: true),
                             sales.count == 1 ? "1 sale" : "\(sales.count) sales",
                         ]),
                         tint: Theme.positive, earWidth: 100),
            for: "revenue"
        )
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (connected, sales, errors, lastUpdated)
        let now = Date()
        connected = [.stripe, .polar]
        sales = [
            Sale(id: "1", provider: .stripe, amount: 49, currency: "USD", date: now.addingTimeInterval(-120), customer: "Maya Chen", product: "Brim Pro"),
            Sale(id: "2", provider: .polar, amount: 19, currency: "USD", date: now.addingTimeInterval(-1800), customer: "sam@example.com", product: "Brim"),
            Sale(id: "3", provider: .stripe, amount: 149, currency: "USD", date: now.addingTimeInterval(-7200), customer: "Northwind", product: "Team plan"),
            Sale(id: "4", provider: .stripe, amount: 9.5, currency: "EUR", date: now.addingTimeInterval(-9000), customer: nil, product: "Tip"),
        ]
        errors = [.polar: .offline]
        lastUpdated = now.addingTimeInterval(-60)
        body()
        (connected, sales, errors, lastUpdated) = saved
    }

    /// Checks the providers' parsers against the documented response shapes,
    /// and that a bogus key is refused by each live API.
    static func selfTest() async -> [String] {
        var lines: [String] = []
        let stripeJSON = #"{"object":"list","has_more":false,"data":[{"id":"ch_1","amount":4900,"amount_refunded":0,"currency":"usd","created":1789560000,"paid":true,"status":"succeeded","description":"Brim Pro","billing_details":{"name":"Maya","email":null}},{"id":"ch_2","amount":1000,"amount_refunded":1000,"currency":"usd","created":1789560001,"paid":true,"status":"succeeded","description":null,"billing_details":null},{"id":"ch_3","amount":500,"currency":"jpy","created":1789560002,"paid":false,"status":"failed"}]}"#
        let polarJSON = #"{"items":[{"id":"o1","created_at":"2026-01-01T00:00:00.000000Z","status":"paid","paid":true,"customer":{"email":"customer@example.com","name":"John Doe"},"product":{"name":"Pro Plan"},"subtotal_amount":10000,"discount_amount":1000,"net_amount":9000,"tax_amount":720,"total_amount":9720,"currency":"usd"}],"pagination":{"total_count":1,"max_page":1}}"#
        let dodoJSON = #"{"items":[{"payment_id":"pay_1","total_amount":2500,"currency":"EUR","status":"succeeded","created_at":"2026-09-16T10:00:00Z","customer":{"customer_id":"c1","name":"Ana","email":"ana@example.com"}},{"payment_id":"pay_2","total_amount":300,"currency":"JPY","status":"succeeded","created_at":"2026-09-16T11:00:00.123Z","customer":{"customer_id":"c2","name":"Ken","email":"k@example.com"}}]}"#
        func describe(_ sales: [Sale]) -> String {
            sales.map { "\($0.id)=\(Money.format($0.amount, currency: $0.currency)) \($0.customer ?? "-") \($0.product ?? "-") \(ISODate.string($0.date))" }.joined(separator: "; ")
        }
        do {
            let stripe = try StripeProvider.parse(Data(stripeJSON.utf8))
            lines.append("stripe parse: \(describe(stripe.sales)) hasMore=\(stripe.hasMore)")
            let polar = try PolarProvider.parse(Data(polarJSON.utf8))
            lines.append("polar parse: \(describe(polar.sales)) maxPage=\(polar.maxPage)")
            let dodo = try DodoProvider.parse(Data(dodoJSON.utf8))
            lines.append("dodo parse: \(describe(dodo.sales))")
        } catch {
            lines.append("parse failed: \(error)")
        }
        for kind in RevenueProviderKind.allCases {
            do {
                _ = try await kind.provider(testMode: true).sales(since: Date(), key: "brim_selftest_invalid_key")
                lines.append("\(kind.name) bogus key: unexpectedly accepted")
            } catch {
                lines.append("\(kind.name) bogus key: \(ConnectionError.from(error))")
            }
        }
        return lines
    }
    #endif
}
