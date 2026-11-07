import Testing
import Foundation

/// Production source, read for the call-site scans: a whole file, one member's body, and code
/// compared without comments or layout.
///
/// These are blunt instruments. Two habits keep them honest: a file that can't be read, or reads
/// implausibly short, fails the test (so a rename or a truncated checkout can't hand on an empty
/// haystack where every `!contains` answers true), and a member must occur exactly once (so a decoy
/// above the real one can't be what the scan reads).
enum SourceText {

    /// `Modules/`, located from this file, since `swift test` does not promise a working directory.
    static let modules: URL = URL(fileURLWithPath: #filePath)   // …/Tests/FileExplorer/<this>.swift
        .deletingLastPathComponent()                             // …/Tests/FileExplorer
        .deletingLastPathComponent()                             // …/Tests
        .deletingLastPathComponent()                             // …/FileExplorer (package)
        .deletingLastPathComponent()                             // …/Modules

    /// A file in `Sources/FileExplorer`.
    static func fileExplorer(_ name: String, atLeast minimum: Int = 500,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try read("FileExplorer/Sources/FileExplorer/" + name, atLeast: minimum, sourceLocation: sourceLocation)
    }

    /// A file in the Sync package's `Sources/Sync`.
    static func sync(_ name: String, atLeast minimum: Int = 500,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try read("Sync/Sources/Sync/" + name, atLeast: minimum, sourceLocation: sourceLocation)
    }

    /// `#require`, not `#expect`: a missing or truncated file would record one issue and hand the
    /// short string on, after which every `contains` answers false and every `!contains` true.
    private static func read(_ path: String, atLeast minimum: Int,
                             sourceLocation: SourceLocation) throws -> String {
        let text = try #require(try? String(contentsOf: modules.appendingPathComponent(path), encoding: .utf8),
                                "cannot read \(path) — the scan would be vacuous", sourceLocation: sourceLocation)
        try #require(text.count > minimum, "\(path) is implausibly short — the scan would be near-vacuous",
                     sourceLocation: sourceLocation)
        return text
    }

    /// The same text with whole-line `//` comments removed, so a doc comment explaining an absence
    /// can't falsify a negative check.
    ///
    /// Whole-line only, deliberately: stripping a trailing `// …` needs a lexer that knows string
    /// literals (``normalized(_:)`` has one), and one that got that wrong would silently shrink the
    /// haystack.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// A type member's body, from `declaration` to the first closing brace at member indentation
    /// (`\n    }`), comments stripped (``codeOnly(_:)``). `declaration` must occur exactly once in
    /// code, counted and searched over the same stripped text, so a decoy in a doc comment can
    /// neither fail the count nor be what is read.
    static func body(of declaration: String, in source: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let code = codeOnly(source)
        let occurrences = code.components(separatedBy: declaration).count - 1
        try #require(occurrences == 1,
                     "\(declaration) occurs \(occurrences)× in code — range(of:) would silently read the first",
                     sourceLocation: sourceLocation)
        let start = try #require(code.range(of: declaration),
                                 "\(declaration) is gone — the scan would be vacuous", sourceLocation: sourceLocation)
        let rest = code[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)",
                               sourceLocation: sourceLocation)
        return String(rest[..<end.lowerBound])
    }

    // MARK: Matched braces and layout-free code

    // The app target's `TestSupport.swift` has the full reader (`declarationBody`, `CodeText`,
    // `CallArguments`), which this module can't see. This is the part these scans need: a lexer
    // that knows comments and string literals (escapes, `\(…)`, `"""`, `#"…"#`), a brace matcher
    // over it, and a whitespace normaliser. Keep the two in step.

    enum Kind { case code, string, comment }

    /// What each byte is part of: code, a string literal (interpolations included), or a comment.
    static func kinds(_ b: [UInt8]) -> [Kind] {
        var kinds = [Kind](repeating: .code, count: b.count)
        func at(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), slash = UInt8(ascii: "/"),
            star = UInt8(ascii: "*"), newline = UInt8(ascii: "\n"), backslash = UInt8(ascii: "\\"),
            open = UInt8(ascii: "("), close = UInt8(ascii: ")")
        // Code from `i`; with `interpolation`, returns after the `)` that closes it.
        func code(from start: Int, interpolation: Bool, mark: Bool) -> Int {
            var i = start, depth = 0
            while i < b.count {
                let c = b[i]
                var end: Int?
                var kind = Kind.comment
                if c == slash, at(i + 1) == slash {
                    var j = i
                    while j < b.count, b[j] != newline { j += 1 }
                    end = j
                } else if c == slash, at(i + 1) == star {
                    var j = i + 2, level = 1
                    while j < b.count, level > 0 {
                        if b[j] == slash, at(j + 1) == star { level += 1; j += 2 }
                        else if b[j] == star, at(j + 1) == slash { level -= 1; j += 2 }
                        else { j += 1 }
                    }
                    end = j
                } else if c == quote || c == hash {
                    end = string(at: i)
                    kind = .string
                }
                if let end {
                    if mark { for k in i..<min(end, b.count) { kinds[k] = kind } }
                    i = end
                    continue
                }
                if interpolation, c == open { depth += 1 }
                if interpolation, c == close {
                    if depth == 0 { return i + 1 }
                    depth -= 1
                }
                i += 1
            }
            return b.count
        }
        func string(at i: Int) -> Int? {
            var j = i, hashes = 0
            while at(j) == hash { hashes += 1; j += 1 }
            guard at(j) == quote else { return nil }
            let multiline = at(j + 1) == quote && at(j + 2) == quote
            j += multiline ? 3 : 1
            func hashesAt(_ k: Int) -> Bool { (0..<hashes).allSatisfy { at(k + $0) == hash } }
            while j < b.count {
                if b[j] == backslash, hashesAt(j + 1) {
                    let k = j + 1 + hashes
                    j = at(k) == open ? code(from: k + 1, interpolation: true, mark: false) : k + 1
                    continue
                }
                if b[j] == quote, !multiline || (at(j + 1) == quote && at(j + 2) == quote) {
                    let after = j + (multiline ? 3 : 1)
                    if hashesAt(after) { return after + hashes }
                }
                if !multiline, b[j] == newline { return j }
                j += 1
            }
            return b.count
        }
        _ = code(from: 0, interpolation: false, mark: true)
        return kinds
    }

    /// The text inside the braces of the block `opening` starts — the first `{` in code from the
    /// start of `opening`, to its match. `opening` must occur exactly once.
    static func block(opening: String, in source: String,
                      sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let count = source.components(separatedBy: opening).count - 1
        try #require(count == 1, "\(opening) occurs \(count)× — the scan would read the wrong block",
                     sourceLocation: sourceLocation)
        let start = try #require(source.range(of: opening), sourceLocation: sourceLocation)
        let b = Array(source.utf8)
        let kind = kinds(b)
        var i = source.utf8.distance(from: source.startIndex, to: start.lowerBound)
        while i < b.count, !(kind[i] == .code && b[i] == UInt8(ascii: "{")) { i += 1 }
        let open = i
        var depth = 0
        while i < b.count {
            if kind[i] == .code, b[i] == UInt8(ascii: "{") { depth += 1 }
            if kind[i] == .code, b[i] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(decoding: b[(open + 1)..<i], as: UTF8.self) }
            }
            i += 1
        }
        Issue.record("\(opening) never closes — the scan would read the rest of the file", sourceLocation: sourceLocation)
        return String(decoding: b[min(open + 1, b.count)...], as: UTF8.self)
    }

    /// Comments dropped, and whitespace outside string literals dropped except between two word
    /// characters, where it becomes one space. Strings are kept byte for byte.
    static func normalized(_ text: String) -> String {
        let b = Array(text.utf8)
        let kind = kinds(b)
        func isWord(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c == UInt8(ascii: "@")
                || c == UInt8(ascii: "#") || c >= 0x80
        }
        var out: [UInt8] = []
        var pending = false
        for i in 0..<b.count {
            let c = b[i]
            if kind[i] == .comment || (kind[i] == .code && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)) {
                pending = true
                continue
            }
            if pending, let last = out.last, isWord(last), isWord(c) { out.append(0x20) }
            pending = false
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
