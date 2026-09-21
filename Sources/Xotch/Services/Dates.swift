import Foundation

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
        return String(format: "%04ld-%02ld-%02ld", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
