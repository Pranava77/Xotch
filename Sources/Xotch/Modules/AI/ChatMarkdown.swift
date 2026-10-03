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

    /// Bold, italics, inline code and links, with line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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

/// A reply drawn block by block.
struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { index, block in
                BlockView(block: block, isFirst: index == 0)
            }
        }
    }
}

private struct BlockView: View {
    let block: ChatBlock
    let isFirst: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(ChatMarkdown.inline(text))
                .font(.system(size: level == 1 ? 15.5 : level == 2 ? 14 : 13, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, isFirst ? 0 : 4)
        case .paragraph(let text):
            prose(text)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 13, weight: item.isOrdered ? .medium : .bold).monospacedDigit())
                            .foregroundStyle(item.isOrdered ? Theme.secondaryInk : Theme.accent)
                            .frame(minWidth: item.isOrdered ? 18 : 10, alignment: item.isOrdered ? .trailing : .center)
                        prose(item.text)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: 2.5)
                prose(text)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(ChatMarkdown.inline(text))
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 10, weight: .medium))
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the code")
            }
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    cell(header, column)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(row, column)
                            .font(.system(size: 12))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func cell(_ row: [String], _ column: Int) -> some View {
        Text(ChatMarkdown.inline(column < row.count ? row[column] : ""))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
