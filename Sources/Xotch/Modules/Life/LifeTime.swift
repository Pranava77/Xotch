import Foundation

/// Reading a clock time out of something you typed.
///
/// "9:30 standup" is a to-do at half nine; "30 push-ups" is a to-do called
/// "30 push-ups". That difference is the whole job: a bare number is never a
/// time, so a match needs minutes after a colon or a dot, or an am/pm on the
/// end. Times are minutes after midnight, the way `Habit.reminder` already is.
enum LifeTime {
    /// What a line of text says about when something happens.
    struct Reading: Equatable {
        /// Minutes after midnight, or nil when no time was written.
        var start: Int?
        /// Minutes, when an end time was written too.
        var length: Int?
        /// What's left once the time is taken off the front.
        var rest: String
    }

    /// How long a slot runs when you only say when it starts.
    static let defaultLength = 60

    /// "9:30 standup" → 570, nil, "standup"
    /// "14:00-15:30 deep work" → 840, 90, "deep work"
    /// "2pm dentist" → 840, nil, "dentist"
    /// "30 push-ups" → nil, nil, "30 push-ups"
    static func parse(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        guard let first = time(at: &rest) else { return Reading(start: nil, length: nil, rest: trimmed) }

        // An en dash reads as a range too: people type "9–10" as often as "9-10".
        var length: Int?
        var afterRange = rest
        afterRange = afterRange.drop { $0 == " " }
        if let separator = afterRange.first, separator == "-" || separator == "–" || separator == "—" {
            var tail = afterRange.dropFirst().drop { $0 == " " }
            if let second = time(at: &tail) {
                // Midnight the other side of the range means the next day.
                length = second > first ? second - first : second + 24 * 60 - first
                rest = tail
            }
        }

        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return Reading(start: first, length: length, rest: title)
    }

    /// "09:30". Twenty-four hour, as the habit reminder button writes it.
    static func label(_ minutes: Int) -> String {
        let wrapped = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    /// The span a slot covers, for a block's tooltip and for accessibility.
    static func span(start: Int, length: Int) -> String {
        "\(label(start))–\(label(start + length))"
    }

    // MARK: - Reading one time off the front

    /// Takes a time off the front of `text` if one is written there, moving
    /// `text` past it. Returns nil and leaves `text` alone otherwise.
    private static func time(at text: inout Substring) -> Int? {
        var scan = text.drop { $0 == " " }
        let digits = scan.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, var hour = Int(digits) else { return nil }
        scan = scan.dropFirst(digits.count)

        var minute = 0
        var hadMinutes = false
        if let separator = scan.first, separator == ":" || separator == "." {
            let after = scan.dropFirst()
            let minuteDigits = after.prefix { $0.isNumber }
            // Exactly two digits: "9:5" is a typo, not five past nine.
            if minuteDigits.count == 2, let value = Int(minuteDigits), value < 60 {
                minute = value
                hadMinutes = true
                scan = after.dropFirst(2)
            }
        }

        // "2pm", "2 pm", "2:15PM"
        var hadMeridiem = false
        let beforeMeridiem = scan
        let writtenHour = hour
        let spaced = scan.drop { $0 == " " }
        let meridiem = spaced.prefix(2).lowercased()
        if meridiem == "am" || meridiem == "pm" {
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            hadMeridiem = true
            scan = spaced.dropFirst(2)
            // "9amazing" is a word, not nine in the morning.
            if let next = scan.first, next.isLetter || next.isNumber {
                scan = beforeMeridiem
                hadMeridiem = false
                hour = writtenHour
            }
        }

        // The rule: a bare number is never a time.
        guard hadMinutes || hadMeridiem, hour < 24 else { return nil }
        text = scan
        return hour * 60 + minute
    }
}
