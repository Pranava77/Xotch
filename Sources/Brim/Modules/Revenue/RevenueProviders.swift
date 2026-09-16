import Foundation

struct Sale: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let provider: RevenueProviderKind
    let amount: Double
    let currency: String
    let date: Date
    let customer: String?
    let product: String?
}

enum RevenueProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case stripe, polar, dodo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .stripe: "Stripe"
        case .polar: "Polar"
        case .dodo: "Dodo Payments"
        }
    }

    var keychainAccount: String { "revenue.\(rawValue)" }

    var keyPlaceholder: String {
        switch self {
        case .stripe: "rk_live_…"
        case .polar: "polar_oat_…"
        case .dodo: "API key"
        }
    }

    /// What kind of key to create, in the provider's words.
    var keyHelp: String {
        switch self {
        case .stripe: "Create a restricted key with read access to Charges."
        case .polar: "Create an organization access token with the orders:read scope."
        case .dodo: "Create an API key in Developer › API Keys."
        }
    }

    var keyPage: URL {
        switch self {
        case .stripe: URL(string: "https://dashboard.stripe.com/apikeys")!
        case .polar: URL(string: "https://polar.sh/dashboard")!
        case .dodo: URL(string: "https://app.dodopayments.com")!
        }
    }

    /// Polar and Dodo use separate hosts for test data.
    var hasTestMode: Bool { self != .stripe }

    var testModeKey: String { "revenue.\(rawValue).testMode" }

    func provider(testMode: Bool) -> any RevenueProvider {
        switch self {
        case .stripe: StripeProvider()
        case .polar: PolarProvider(sandbox: testMode)
        case .dodo: DodoProvider(testMode: testMode)
        }
    }
}

protocol RevenueProvider: Sendable {
    /// Successful sales created at or after `since`.
    func sales(since: Date, key: String) async throws -> [Sale]
}

// MARK: - Stripe

/// GET /v1/charges with a restricted key (Charges: Read).
struct StripeProvider: RevenueProvider {
    func sales(since: Date, key: String) async throws -> [Sale] {
        var sales: [Sale] = []
        var startingAfter: String?
        for _ in 0..<10 {
            var components = URLComponents(string: "https://api.stripe.com/v1/charges")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "created[gte]", value: String(Int(since.timeIntervalSince1970))),
            ] + (startingAfter.map { [URLQueryItem(name: "starting_after", value: $0)] } ?? [])
            let page = try Self.parse(try await HTTP.get(components.url!, bearer: key))
            sales += page.sales
            guard page.hasMore, let last = page.lastID else { break }
            startingAfter = last
        }
        return sales
    }

    static func parse(_ data: Data) throws -> (sales: [Sale], hasMore: Bool, lastID: String?) {
        struct Charge: Decodable {
            struct Billing: Decodable { let name: String?; let email: String? }
            let id: String
            let amount: Int
            let amount_refunded: Int?
            let currency: String
            let created: Int
            let paid: Bool?
            let status: String
            let description: String?
            let billing_details: Billing?
        }
        struct Page: Decodable {
            let data: [Charge]
            let has_more: Bool
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let sales = page.data.compactMap { charge -> Sale? in
            let net = charge.amount - (charge.amount_refunded ?? 0)
            guard charge.status == "succeeded", charge.paid ?? true, net > 0 else { return nil }
            return Sale(id: "stripe:" + charge.id, provider: .stripe,
                        amount: Money.fromMinorUnits(net, currency: charge.currency),
                        currency: charge.currency.uppercased(),
                        date: Date(timeIntervalSince1970: TimeInterval(charge.created)),
                        customer: charge.billing_details?.name ?? charge.billing_details?.email,
                        product: charge.description)
        }
        return (sales, page.has_more, page.data.last?.id)
    }
}

// MARK: - Polar

/// GET /v1/orders/ with an organization access token (orders:read).
struct PolarProvider: RevenueProvider {
    let sandbox: Bool

    func sales(since: Date, key: String) async throws -> [Sale] {
        var sales: [Sale] = []
        let host = sandbox ? "https://sandbox-api.polar.sh" : "https://api.polar.sh"
        for pageNumber in 1...10 {
            var components = URLComponents(string: host + "/v1/orders/")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "page", value: String(pageNumber)),
                URLQueryItem(name: "sorting", value: "-created_at"),
                URLQueryItem(name: "created_after", value: ISODate.string(since)),
            ]
            let page = try Self.parse(try await HTTP.get(components.url!, bearer: key))
            sales += page.sales.filter { $0.date >= since }
            guard pageNumber < page.maxPage else { break }
        }
        return sales
    }

    static func parse(_ data: Data) throws -> (sales: [Sale], maxPage: Int) {
        struct Order: Decodable {
            struct Customer: Decodable { let name: String?; let email: String? }
            struct Product: Decodable { let name: String? }
            let id: String
            let created_at: String
            let status: String?
            let paid: Bool?
            let net_amount: Int?
            let total_amount: Int?
            let currency: String
            let customer: Customer?
            let product: Product?
        }
        struct Pagination: Decodable { let max_page: Int }
        struct Page: Decodable {
            let items: [Order]
            let pagination: Pagination
        }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let sales = page.items.compactMap { order -> Sale? in
            let isPaid = order.paid ?? (order.status == "paid")
            let amount = order.net_amount ?? order.total_amount ?? 0
            guard isPaid, amount > 0, let date = ISODate.parse(order.created_at) else { return nil }
            return Sale(id: "polar:" + order.id, provider: .polar,
                        amount: Money.fromMinorUnits(amount, currency: order.currency),
                        currency: order.currency.uppercased(), date: date,
                        customer: order.customer?.name ?? order.customer?.email,
                        product: order.product?.name)
        }
        return (sales, page.pagination.max_page)
    }
}

// MARK: - Dodo Payments

/// GET /payments with an API key.
struct DodoProvider: RevenueProvider {
    let testMode: Bool

    func sales(since: Date, key: String) async throws -> [Sale] {
        var sales: [Sale] = []
        let host = testMode ? "https://test.dodopayments.com" : "https://live.dodopayments.com"
        for pageNumber in 0..<10 {
            var components = URLComponents(string: host + "/payments")!
            components.queryItems = [
                URLQueryItem(name: "created_at_gte", value: ISODate.string(since)),
                URLQueryItem(name: "status", value: "succeeded"),
                URLQueryItem(name: "page_size", value: "100"),
                URLQueryItem(name: "page_number", value: String(pageNumber)),
            ]
            let page = try Self.parse(try await HTTP.get(components.url!, bearer: key))
            sales += page.sales
            guard page.count == 100 else { break }
        }
        return sales
    }

    static func parse(_ data: Data) throws -> (sales: [Sale], count: Int) {
        struct Payment: Decodable {
            struct Customer: Decodable { let name: String?; let email: String? }
            let payment_id: String
            let total_amount: Int
            let currency: String
            let status: String?
            let created_at: String
            let customer: Customer?
        }
        struct Page: Decodable { let items: [Payment] }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let sales = page.items.compactMap { payment -> Sale? in
            guard (payment.status ?? "succeeded") == "succeeded", payment.total_amount > 0,
                  let date = ISODate.parse(payment.created_at) else { return nil }
            return Sale(id: "dodo:" + payment.payment_id, provider: .dodo,
                        amount: Money.fromMinorUnits(payment.total_amount, currency: payment.currency),
                        currency: payment.currency.uppercased(), date: date,
                        customer: payment.customer?.name ?? payment.customer?.email,
                        product: nil)
        }
        return (sales, page.items.count)
    }
}
