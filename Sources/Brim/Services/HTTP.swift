import Foundation

/// Why a connected service couldn't be read, in words for the notch.
enum ConnectionError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case offline
    case badResponse(Int)
    case unreadable

    static func from(_ error: Error) -> ConnectionError {
        if let error = error as? ConnectionError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default:
                return .badResponse(error.errorCode)
            }
        }
        if error is DecodingError { return .unreadable }
        return .badResponse(0)
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The key was rejected. It may have been revoked or lack read access."
        case .rateLimited: "Too many requests. Brim will try again shortly."
        case .offline: "You're offline. Showing the last numbers."
        case .badResponse(let code): code > 0 ? "The service answered with an error (\(code))." : "The service couldn't be reached."
        case .unreadable: "The service sent something Brim couldn't read."
        }
    }
}

enum HTTP {
    /// No caching and no cookies: responses contain your business numbers.
    private static let session = URLSession(configuration: .ephemeral)

    static func get(_ url: URL, bearer token: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Brim/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ConnectionError.from(error)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ConnectionError.badResponse(0) }
        switch status {
        case 200..<300: return data
        case 401, 403: throw ConnectionError.unauthorized
        case 429: throw ConnectionError.rateLimited
        default: throw ConnectionError.badResponse(status)
        }
    }
}

enum ISODate {
    /// Parses ISO 8601 dates with or without fractional seconds of any length.
    static func parse(_ string: String) -> Date? {
        var text = string
        if let dot = text.firstIndex(of: ".") {
            let digitsEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            text.removeSubrange(dot..<digitsEnd)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// YYYY-MM-DD in the current time zone.
    static func day(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

enum Money {
    private static let zeroDecimal: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF",
    ]

    /// Converts an amount in the smallest unit (cents) to a decimal amount.
    static func fromMinorUnits(_ amount: Int, currency: String) -> Double {
        zeroDecimal.contains(currency.uppercased()) ? Double(amount) : Double(amount) / 100
    }

    static func format(_ amount: Double, currency: String, compact: Bool = false) -> String {
        let code = currency.uppercased()
        if compact && abs(amount) >= 10_000 {
            // Currency + compact notation needs macOS 15, so build "$12.4K" by hand.
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            let number = amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
            return (formatter.currencySymbol ?? code + " ") + number
        }
        let whole = amount.rounded() == amount
        return amount.formatted(.currency(code: code).precision(.fractionLength(whole ? 0 : 2)))
    }
}
