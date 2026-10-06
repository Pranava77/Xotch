import Foundation

/// Cleans up dictated text on the Mac, without the AI: drops filler words and
/// stutters, turns "new line" into a line break, and fixes capitals, spacing
/// and the closing full stop. Whistle already punctuates, so this stays light.
enum TextTidy {
    static func tidy(_ text: String) -> String {
        var result = " " + text + " "

        // Spoken line breaks.
        result = replace(result, #"(?i)[\s,]*\bnew paragraph\b[\s,.]*"#, with: "\n\n")
        result = replace(result, #"(?i)[\s,]*\bnew line\b[\s,.]*"#, with: "\n")

        // Fillers, with the comma that often comes along. "Like" and "so" carry
        // meaning too often to drop.
        result = replace(result, #"(?i)(^|[\s,])(um+|uh+|uhm+|er+m?|hmm+|mm+)([\s,.!?]|$)"#, with: "$1$3")
        result = replace(result, #"(?i),\s*you know,"#, with: ",")
        result = replace(result, #"(?i)\byou know,\s*"#, with: "")

        // Stutters: "the the", "I I".
        result = replace(result, #"(?i)\b(\w+)(\s+\1\b)+"#, with: "$1")

        // Spacing: no space before punctuation, single spaces, no stray commas.
        result = replace(result, #"[ \t]+([,.!?;:])"#, with: "$1")
        result = replace(result, #",{2,}"#, with: ",")
        result = replace(result, #"(^|\n)[ \t]*,\s*"#, with: "$1")
        result = replace(result, #"[ \t]{2,}"#, with: " ")
        result = replace(result, #"[ \t]*\n[ \t]*"#, with: "\n")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // Capitals at the start and after a sentence ends or a line breaks.
        result = capitalizeSentences(result)

        // A sentence ends with a full stop unless it already ends some way.
        if let last = result.last, last.isLetter || last.isNumber {
            result += "."
        }
        return result
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// A sentence starts at the beginning, after a line break, or after . ! ?
    /// and a space, so "example.com" and "3.5" are left alone.
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var startsSentence = true
        var ended = false
        for character in text {
            if character.isLetter || character.isNumber {
                result += startsSentence && character.isLetter ? character.uppercased() : String(character)
                startsSentence = false
                ended = false
            } else {
                result.append(character)
                if character == "\n" {
                    startsSentence = true
                } else if ".!?".contains(character) {
                    ended = true
                } else if character.isWhitespace {
                    if ended { startsSentence = true }
                } else if !"\"'”’)]".contains(character) {
                    ended = false
                }
            }
        }
        return result
    }
}
