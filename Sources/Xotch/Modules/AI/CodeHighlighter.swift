import SwiftUI

/// Colours code in a reply: keywords, strings, comments, numbers and type
/// names. A small scanner rather than a parser, so it's quick enough to rerun
/// as a reply streams in and never fails on half-written code.
enum CodeHighlighter {
    enum Token: Equatable {
        case plain, keyword, string, comment, number, type
    }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for (text, token) in tokens(code, language: language) {
            var piece = AttributedString(text)
            piece.foregroundColor = color(for: token)
            result += piece
        }
        return result
    }

    /// The code cut into runs, each with its kind. Plain runs are merged.
    static func tokens(_ code: String, language: String?) -> [(String, Token)] {
        let family = Family(language)
        let characters = Array(code)
        var runs: [(String, Token)] = []
        var index = 0

        func add(_ text: String, _ token: Token) {
            if token == .plain, let last = runs.last, last.1 == .plain {
                runs[runs.count - 1].0 += text
            } else {
                runs.append((text, token))
            }
        }
        func starts(_ prefix: String, at position: Int) -> Bool {
            let prefix = Array(prefix)
            guard position + prefix.count <= characters.count else { return false }
            return Array(characters[position..<position + prefix.count]) == prefix
        }
        func isLineStart(_ position: Int) -> Bool {
            var back = position - 1
            while back >= 0, characters[back] == " " || characters[back] == "\t" { back -= 1 }
            return back < 0 || characters[back] == "\n"
        }

        while index < characters.count {
            let character = characters[index]

            // Comments run to the end of the line, or to */.
            if family.slashComments, starts("//", at: index) {
                let end = characters[index...].firstIndex(of: "\n") ?? characters.count
                add(String(characters[index..<end]), .comment)
                index = end
                continue
            }
            if family.slashComments, starts("/*", at: index) {
                var end = index + 2
                while end < characters.count, !starts("*/", at: end) { end += 1 }
                end = min(end + 2, characters.count)
                add(String(characters[index..<end]), .comment)
                index = end
                continue
            }
            if character == "#", family.hashComments || (family == .generic && isLineStart(index)
                                                            && index + 1 < characters.count && characters[index + 1] == " ") {
                let end = characters[index...].firstIndex(of: "\n") ?? characters.count
                add(String(characters[index..<end]), .comment)
                index = end
                continue
            }

            // Strings: """ blocks, then quotes that stop at the end of the line.
            if starts("\"\"\"", at: index) {
                var end = index + 3
                while end < characters.count, !starts("\"\"\"", at: end) { end += 1 }
                end = min(end + 3, characters.count)
                add(String(characters[index..<end]), .string)
                index = end
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                // An apostrophe in Swift or Rust is rarely a string.
                if character == "'", family == .swift || family == .rust {
                    add(String(character), .plain)
                    index += 1
                    continue
                }
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    if characters[end] == "\\" { end += 1 }
                    else if characters[end] == "\n", character != "`" { break }
                    end += 1
                }
                end = min(end + 1, characters.count)
                add(String(characters[index..<end]), .string)
                index = end
                continue
            }

            // Shell variables read like names: $HOME, ${PATH}.
            if character == "$", family == .shell, index + 1 < characters.count,
               characters[index + 1] == "{" || characters[index + 1].isLetter || characters[index + 1] == "_" {
                var end = index + 1
                if characters[end] == "{" {
                    while end < characters.count, characters[end] != "}" { end += 1 }
                    end = min(end + 1, characters.count)
                } else {
                    while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                        end += 1
                    }
                }
                add(String(characters[index..<end]), .type)
                index = end
                continue
            }

            if character.isNumber, index == 0 || !isWordCharacter(characters[index - 1]) {
                var end = index + 1
                while end < characters.count, characters[end].isHexDigit || "xX._".contains(characters[end]) {
                    end += 1
                }
                add(String(characters[index..<end]), .number)
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                var end = index + 1
                while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
                let word = String(characters[index..<end])
                let token: Token
                if family.keywords.contains(word) {
                    token = .keyword
                } else if family.capitalizedTypes, character.isUppercase, word.count > 1 {
                    token = .type
                } else {
                    token = .plain
                }
                add(word, token)
                index = end
                continue
            }

            add(String(character), .plain)
            index += 1
        }
        return runs
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func color(for token: Token) -> Color {
        switch token {
        case .plain: Theme.ink
        case .keyword: Theme.codeKeyword
        case .string: Theme.codeString
        case .comment: Theme.codeComment
        case .number: Theme.codeNumber
        case .type: Theme.codeType
        }
    }

    // MARK: - Languages

    private enum Family: Equatable {
        case swift, script, python, shell, go, rust, cLike, json, generic

        init(_ language: String?) {
            switch language?.lowercased() {
            case "swift": self = .swift
            case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs": self = .script
            case "py", "python", "python3": self = .python
            case "sh", "bash", "zsh", "shell", "console", "terminal", "fish": self = .shell
            case "go", "golang": self = .go
            case "rs", "rust": self = .rust
            case "c", "h", "cpp", "c++", "cc", "objc", "objective-c", "java", "kotlin", "kt", "cs", "csharp", "c#",
                 "php", "dart", "scala": self = .cLike
            case "json", "jsonc": self = .json
            default: self = .generic
            }
        }

        var slashComments: Bool { self != .python && self != .shell && self != .json }
        var hashComments: Bool { self == .python || self == .shell }
        var capitalizedTypes: Bool { self != .shell && self != .json }

        var keywords: Set<String> {
            switch self {
            case .swift: Self.swiftWords
            case .script: Self.scriptWords
            case .python: Self.pythonWords
            case .shell: Self.shellWords
            case .go: Self.goWords
            case .rust: Self.rustWords
            case .cLike: Self.cWords
            case .json: ["true", "false", "null"]
            case .generic: Self.swiftWords.union(Self.scriptWords).union(Self.pythonWords).union(Self.cWords)
            }
        }

        private static let swiftWords: Set<String> = [
            "let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case",
            "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "init",
            "self", "Self", "nil", "true", "false", "try", "catch", "throw", "throws", "async", "await", "private",
            "fileprivate", "internal", "public", "static", "some", "any", "where", "do", "defer", "inout", "is", "as",
            "lazy", "weak", "override", "final", "mutating", "typealias", "actor", "nonisolated",
        ]
        private static let scriptWords: Set<String> = [
            "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
            "default", "break", "continue", "new", "class", "extends", "import", "export", "from", "as", "async",
            "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined",
            "true", "false", "this", "interface", "type", "enum", "implements", "public", "private", "readonly",
        ]
        private static let pythonWords: Set<String> = [
            "def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from",
            "as", "class", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break",
            "continue", "None", "True", "False", "self", "async", "await", "global", "nonlocal",
        ]
        private static let shellWords: Set<String> = [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
            "function", "return", "export", "local", "readonly", "set", "unset", "source", "sudo",
        ]
        private static let goWords: Set<String> = [
            "package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default",
            "break", "continue", "go", "defer", "chan", "select", "struct", "interface", "map", "type", "var",
            "const", "nil", "true", "false",
        ]
        private static let rustWords: Set<String> = [
            "fn", "let", "mut", "return", "if", "else", "match", "for", "in", "while", "loop", "break", "continue",
            "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate", "self", "Self", "super", "as", "ref",
            "move", "async", "await", "where", "true", "false", "const", "static", "unsafe", "dyn",
        ]
        private static let cWords: Set<String> = [
            "int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "bool", "boolean",
            "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
            "struct", "class", "public", "private", "protected", "static", "const", "new", "delete", "null",
            "nullptr", "true", "false", "this", "import", "package", "final", "abstract", "interface", "extends",
            "implements", "try", "catch", "throw", "throws", "namespace", "using", "include", "fun", "val", "var",
        ]
    }
}
