import AppKit
import SwiftUI

/// One piece of a reply, as the chat draws it.
enum ChatBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ChatListItem])
    case code(language: String?, text: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct ChatListItem: Equatable {
    /// "•", "◦", or the item's number, e.g. "3."
    var marker: String
    var isOrdered: Bool
    /// Nesting depth, 0 for the outermost list.
    var indent: Int
    var text: String
}

/// Splits a reply's Markdown into blocks: headings, paragraphs, lists, code,
/// quotes, tables and rules. Styling inside a block (bold, italics, inline
/// code, links) is left to `AttributedString`.
///
/// Replies arrive a few words at a time, so half-finished Markdown has to
/// read well too: an unclosed code fence is still code, and a table row shows
/// as text until its `|---|` line arrives.
enum ChatMarkdown {
    static func blocks(_ text: String) -> [ChatBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ChatBlock] = []
        // At most one of these is collecting at a time.
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ChatListItem] = []
        // Leading spaces of each open list level, outermost first.
        var indents: [Int] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !items.isEmpty { blocks.append(.list(items)) }
            paragraph = []
            quote = []
            items = []
            indents = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                let body = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body))
                continue
            }

            if trimmed.isEmpty {
                // A blank line between two items doesn't end the list.
                if !items.isEmpty, let next = lines[(index + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   listItem(next) != nil {
                    index += 1
                    continue
                }
                flush()
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            } else if var item = listItem(line) {
                if items.isEmpty { flush() }
                let spaces = leadingSpaces(line)
                while let last = indents.last, spaces < last {
                    indents.removeLast()
                }
                if indents.last.map({ spaces > $0 }) ?? true {
                    indents.append(spaces)
                }
                item.indent = min(indents.count - 1, 3)
                if !item.isOrdered, item.indent > 0 {
                    item.marker = "◦"
                }
                items.append(item)
            } else if !items.isEmpty, leadingSpaces(line) > 0 {
                // An indented line under an item is more of that item.
                items[items.count - 1].text += "\n" + trimmed
            } else {
                if paragraph.isEmpty { flush() }
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// Bold, italics, inline code and links, with line breaks kept. Inline
    /// code gets a soft pill behind it.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let code = result.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        // From the end, so earlier ranges stay valid while thin spaces go in.
        for range in code.reversed() {
            result[range].backgroundColor = Theme.raisedFill
            var pad = AttributedString("\u{2009}")
            pad.backgroundColor = Theme.raisedFill
            result.insert(pad, at: range.upperBound)
            result.insert(pad, at: range.lowerBound)
        }
        return result
    }

    // MARK: - Follow-ups

    /// The reply without its closing "Follow-ups: a | b | c" line, and the
    /// questions on it. A line still streaming in that could become one is
    /// held back too, so it never flashes up as text.
    static func splitFollowUps(_ text: String) -> (body: String, followUps: [String]) {
        guard let lastBreak = text.lastIndex(of: "\n") ?? (text.isEmpty ? nil : text.startIndex) else {
            return (text, [])
        }
        let lineStart = text[lastBreak] == "\n" ? text.index(after: lastBreak) : lastBreak
        let line = text[lineStart...]
        let label = "follow-ups:"
        let bare = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`>"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let isLabel = bare.hasPrefix(label) || bare.hasPrefix("follow ups:")
        let isPartial = !bare.isEmpty && bare.count < label.count && label.hasPrefix(bare)
        guard isLabel || isPartial else { return (text, []) }
        let body = String(text[..<lineStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLabel, let colon = line.firstIndex(of: ":") else { return (body, []) }
        let questions = line[line.index(after: colon)...]
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`\""))) }
            .filter { !$0.isEmpty }
        return (body, Array(questions.prefix(3)))
    }

    // MARK: - Callouts

    enum Callout: Equatable {
        case info, tip, warning

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .tip: "lightbulb.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: Theme.accent
            case .tip: Theme.positive
            case .warning: Theme.warning
            }
        }
    }

    /// A quote that starts "Note:", "**Tip**", "[!WARNING]" and so on, with
    /// the label taken off.
    static func callout(_ text: String) -> (kind: Callout, body: String)? {
        // "[!NOTE]", "**Note**", "**Note:**" or "Note:", but not "Note that…".
        let names = "note|info|tip|hint|warning|caution|important|danger"
        let pattern = #"^\s*(?:\[!("# + names + #")\]|(?:\*\*|__)("# + names + #"):?(?:\*\*|__):?|("# + names + #"):)\s*"#
        guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let label = text[match].lowercased()
        let kind: Callout = if label.contains("tip") || label.contains("hint") { .tip }
            else if label.contains("warn") || label.contains("caution") || label.contains("danger") || label.contains("important") { .warning }
            else { .info }
        return (kind, String(text[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Lines

    private static func heading(_ line: String) -> ChatBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // "## Title ##" closes with hashes; "## Learn C#" keeps its own.
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(closing)
        }
        return .heading(level: hashes, text: text)
    }

    /// `---`, `***` or `___`, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> ChatListItem? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
            return ChatListItem(marker: "•", isOrdered: false, indent: 0,
                                text: trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return ChatListItem(marker: String(digits) + ".", isOrdered: true, indent: 0,
                            text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// The line under a table's header: `|---|:--:|`.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Views

/// A reply drawn block by block. While it streams, a cursor follows the text
/// and each new block fades in.
struct RichText: View {
    let text: String
    var isStreaming = false

    var body: some View {
        let blocks = ChatMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                BlockView(block: block, isFirst: index == 0,
                          showsCursor: isStreaming && index == blocks.count - 1)
                    .transition(.opacity)
            }
        }
        // Only when a block is added: animating every streamed word would
        // make SwiftUI morph the text, which it draws on the CPU.
        .animation(.easeOut(duration: 0.2), value: blocks.count)
    }
}

private struct BlockView: View {
    let block: ChatBlock
    let isFirst: Bool
    let showsCursor: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3, height: level == 1 ? 17 : 15)
                Text(styled(text))
                    .font(.system(size: level == 1 ? 15.5 : level == 2 ? 14 : 13, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, isFirst ? 0 : 5)
        case .paragraph(let text):
            // A short opening answer reads as the headline.
            if isFirst, text.count < 280 {
                prose(text, size: 14.5, weight: .medium)
            } else {
                prose(text)
            }
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item)
                        prose(item.text, cursor: showsCursor && index == items.count - 1)
                    }
                    .padding(.leading, CGFloat(item.indent) * 20)
                }
            }
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .quote(let text):
            if let callout = ChatMarkdown.callout(text) {
                CalloutBox(kind: callout.kind, text: callout.body, cursor: showsCursor)
            } else {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 1.25)
                        .fill(Theme.accent.opacity(0.7))
                        .frame(width: 2.5)
                    prose(text)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    /// A round number badge, or a dot: filled for the outer list, hollow inside.
    @ViewBuilder private func marker(_ item: ChatListItem) -> some View {
        if item.isOrdered {
            Text(item.marker.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 18, minHeight: 18)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
        } else {
            // A space in the body font gives the dot the line's baseline.
            Text(" ")
                .font(.system(size: 13))
                .frame(width: 18)
                .overlay {
                    if item.indent == 0 {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    } else {
                        Circle().strokeBorder(Theme.accent, lineWidth: 1.2).frame(width: 5.5, height: 5.5)
                    }
                }
        }
    }

    private func prose(_ text: String, size: CGFloat = 13, weight: Font.Weight = .regular,
                       cursor: Bool? = nil) -> some View {
        Text(styled(text, cursor: cursor ?? showsCursor))
            .font(.system(size: size, weight: weight))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func styled(_ text: String, cursor: Bool = false) -> AttributedString {
        var result = ChatMarkdown.inline(text)
        if cursor {
            result += RichTextCursor.piece
        }
        return result
    }
}

/// The accent bar that follows a reply while it streams in.
enum RichTextCursor {
    @MainActor static var piece: AttributedString {
        var cursor = AttributedString(" ▍")
        cursor.foregroundColor = Theme.accent
        return cursor
    }
}

private struct CalloutBox: View {
    let kind: ChatMarkdown.Callout
    let text: String
    let cursor: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(ChatMarkdown.inline(text) + (cursor ? RichTextCursor.piece : AttributedString()))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(kind.tint.opacity(0.28)))
    }
}

/// Coloured code, with line numbers once it's more than a few lines. Each line
/// is its own row, so a long line wraps under itself and its number stays put.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        let lines = Self.lines(CodeHighlighter.highlight(code, language: language))
        let numbered = lines.count > 4
        let digits = String(lines.count).count
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryInk)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Theme.positive : Theme.secondaryInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 6))
                .help("Copy the code")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if numbered {
                            Text("\(index + 1)")
                                .foregroundStyle(Theme.tertiaryInk.opacity(0.75))
                                .frame(width: CGFloat(digits) * 7.5, alignment: .trailing)
                        }
                        Text(line)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// The coloured code cut at each newline.
    private static func lines(_ code: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = code.startIndex
        var index = code.startIndex
        while index < code.endIndex {
            if code.characters[index] == "\n" {
                lines.append(AttributedString(code[start..<index]))
                start = code.characters.index(after: index)
            }
            index = code.characters.index(after: index)
        }
        lines.append(AttributedString(code[start..<code.endIndex]))
        return lines
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(header, column, background: Theme.raisedFill)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(row, column, background: index % 2 == 1 ? Theme.fill : .clear)
                            .font(.system(size: 12))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Cells touch, so a row's stripe runs unbroken across it.
    private func cell(_ row: [String], _ column: Int, background: Color) -> some View {
        Text(ChatMarkdown.inline(column < row.count ? row[column] : ""))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(background)
    }
}
