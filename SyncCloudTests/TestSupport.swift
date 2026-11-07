import AppKit
import Testing
import Foundation

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled failure
/// on timeout. The app target's copy of `Modules/Sync/Tests/Sync/TestSupport.swift`'s helper: a
/// fixed `Task.sleep` is either slow or flaky under a loaded run, so wait for the observable
/// effect, never a guessed duration.
///
/// Reports its timeout at the call site through the forwarded `sourceLocation`; without it every
/// failure anchors here instead of naming a test file.
///
/// Bounded by polls as well as seconds: what this waits for arrives on main-actor turns, and a
/// congested run has fewer of them per second, so a seconds-only deadline shrinks exactly when the
/// wait needs it most. Keep the floor in step with Sync's copy and Dashboard's `WaitSupport.swift`.
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // The poll count IS the diagnosis: a handful means starved, hundreds means disproved.
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` will make before it may give up, however little of its deadline is
/// left. Same number, and the same reason, as `LayoutPumpWait.pumpFloor` in the FileExplorer test
/// target and `pollFloor` in `ShortcutRevealTrackerTests`.
let waitPollFloor = 50

// MARK: - Reading the app target's own source

/// Every Swift file in `MacApp/`, concatenated: the haystack for a source scan whose subject is a
/// call site rather than a file. `MacApp/` is in no SPM package, so tests reach it as text. Reading
/// the whole directory means moving code between files fails nothing, and a count catches a second
/// copy of a rule wherever it is written.
///
/// Two kinds of check must still name their file: a positive control, which needs a text known to
/// hold something; and a `!contains` whose string another file legitimately says. No per-file
/// length guard, so a small new file passes; the result's size is asserted instead.
func macAppSources() throws -> String {
    let directory = macAppDirectory()
    let urls = try #require(try? FileManager.default.contentsOfDirectory(
                                at: directory, includingPropertiesForKeys: nil),
                            "cannot list MacApp/ — every check below would be vacuous")
    let names = urls.filter { $0.pathExtension == "swift" }.map(\.lastPathComponent).sorted()
    try #require(names.count > 10,
                 "MacApp/ listed \(names.count) Swift file(s) — the reader is broken, not the app")
    var joined = ""
    for name in names {
        let text = try #require(
            try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
            "cannot read MacApp/\(name) — the scans below would be reading a partial app")
        joined += text + "\n"
    }
    try #require(joined.count > 10_000,
                 "MacApp/ read as \(joined.count) characters — the scans below would be near-vacuous")
    return joined
}

/// One MacApp file, with the same non-vacuity guard `macAppSources()` carries.
func macAppFile(_ name: String) throws -> String {
    try repoFile("MacApp/\(name)")
}

/// One file of the repo, by its path from the root, `#require`d readable and longer than 500
/// characters, so a scan over it cannot pass on an empty or truncated read.
func repoFile(_ path: String) throws -> String {
    let url = macAppDirectory().deletingLastPathComponent().appendingPathComponent(path)
    let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(path) — the scan would be vacuous")
    try #require(text.count > 500, "\(path) read as \(text.count) characters — truncated?")
    return text
}

/// `MacApp/`, located from this file, since the test bundle promises no working directory.
func macAppDirectory() -> URL {
    URL(fileURLWithPath: #filePath)          // …/SyncCloudTests/TestSupport.swift
        .deletingLastPathComponent()         // …/SyncCloudTests
        .deletingLastPathComponent()         // repo root
        .appendingPathComponent("MacApp")
}

/// The text between two positions found by separate `range(of:)` searches, or `nil` when they come
/// back out of order.
///
/// **Never slice `source[from..<to]` directly** in a scan: when the order is wrong, `Range` traps
/// inside `#expect`'s expression and takes down the whole test host, and every remaining test with
/// it. An ordering `#expect` on the line above does not prevent that, since `#expect` records and
/// continues. Compare against `== true` at the call site, so a `nil` fails without crashing:
///
/// ```swift
/// #expect(textBetween(body, from: gate.upperBound, to: log.lowerBound)?.contains("return") == true, "…")
/// ```
///
/// Where the second match really is "the next one after the first", search from after it instead
/// (`content[x.upperBound...].range(of:)`); this is for two independent searches whose order is
/// under test. `TextBetweenTests` pins the guard, which no correct call site exercises.
func textBetween(_ source: String, from: String.Index, to: String.Index) -> String? {
    guard from <= to else { return nil }
    return String(source[from..<to])
}

// MARK: - Reading Swift source as code

/// What one byte of Swift source belongs to: the lexer every source scan in this target shares,
/// so "skip strings and comments" means the same to the comment stripper, brace matcher, argument
/// reader and whitespace normaliser below.
///
/// It knows `//` and nested `/* */` comments, and plain, multi-line and raw string literals with
/// escapes and `\(…)` interpolations, which may hold strings, parentheses and braces of their own:
/// `Logger.shared.info("\(a ? "}" : ")")")` closes nothing. A whole literal, interpolations
/// included, is `.string`.
///
/// Byte-level because every delimiter is ASCII and UTF-8 never puts an ASCII byte inside a
/// multi-byte character, and bytes are much faster than `[Character]`. An unterminated single-line
/// string ends at its line, so a stray quote cannot swallow a file.
enum SwiftLexeme: UInt8 { case code, string, comment }

/// `bytes`' lexemes, one per byte. Uncached — the scans go through ``lexed(_:)``, which runs this
/// once per distinct text.
func swiftLexemes(_ bytes: [UInt8]) -> [SwiftLexeme] {
    var roles = [SwiftLexeme](repeating: .code, count: bytes.count)
    bytes.withUnsafeBufferPointer { b in
        roles.withUnsafeMutableBufferPointer { r in
            guard let bytes = b.baseAddress, let roles = r.baseAddress else { return }   // empty
            _ = SwiftLexer(b: bytes, count: b.count, roles: roles)
                .scanCode(from: 0, closingParen: false, mark: true)
        }
    }
    return roles
}

/// Raw pointers because the test target builds at `-Onone`, where each `Array` access pays bounds,
/// uniqueness and exclusivity checks per byte. Over all of `MacApp/` that makes a lex slow enough
/// to hold the cooperative pool the rest of the run needs.
private struct SwiftLexer {
    let b: UnsafePointer<UInt8>
    let count: Int
    let roles: UnsafeMutablePointer<SwiftLexeme>

    static let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), slash = UInt8(ascii: "/"),
               star = UInt8(ascii: "*"), newline = UInt8(ascii: "\n"), backslash = UInt8(ascii: "\\"),
               open = UInt8(ascii: "("), close = UInt8(ascii: ")")

    private func fill(_ from: Int, _ to: Int, _ role: SwiftLexeme) {
        var k = from
        let end = min(to, count)
        while k < end { roles[k] = role; k += 1 }
    }

    private func byte(_ i: Int) -> UInt8? { i < count ? b[i] : nil }

    /// Code from `start`. With `closingParen`, stops after the `)` that closes an interpolation
    /// opened just before `start`, and returns the index after it. `mark` is false inside an
    /// interpolation: the literal around it is marked `.string` whole.
    func scanCode(from start: Int, closingParen: Bool, mark: Bool) -> Int {
        var i = start, depth = 0
        while i < count {
            let c = b[i]
            if c == Self.slash, byte(i + 1) == Self.slash {
                var j = i
                while j < count, b[j] != Self.newline { j += 1 }
                if mark { fill(i, j, .comment) }
                i = j
                continue
            }
            if c == Self.slash, byte(i + 1) == Self.star {
                var j = i + 2, level = 1
                while j < count, level > 0 {
                    if b[j] == Self.slash, byte(j + 1) == Self.star { level += 1; j += 2 }
                    else if b[j] == Self.star, byte(j + 1) == Self.slash { level -= 1; j += 2 }
                    else { j += 1 }
                }
                if mark { fill(i, j, .comment) }
                i = j
                continue
            }
            if c == Self.quote || c == Self.hash, let end = endOfStringLiteral(openingAt: i) {
                if mark { fill(i, end, .string) }
                i = end
                continue
            }
            if closingParen {
                if c == Self.open { depth += 1 }
                if c == Self.close {
                    if depth == 0 { return i + 1 }
                    depth -= 1
                }
            }
            i += 1
        }
        return count
    }

    /// The index after the literal opening at `i`, or `nil` when none does (`#if`, `#selector`).
    private func endOfStringLiteral(openingAt i: Int) -> Int? {
        var j = i, hashes = 0
        while byte(j) == Self.hash { hashes += 1; j += 1 }
        guard byte(j) == Self.quote else { return nil }
        let multiline = byte(j + 1) == Self.quote && byte(j + 2) == Self.quote
        j += multiline ? 3 : 1
        while j < count {
            if b[j] == Self.backslash, hashesFollow(j + 1, hashes) {
                let k = j + 1 + hashes
                if byte(k) == Self.open {
                    j = scanCode(from: k + 1, closingParen: true, mark: false)
                } else {
                    j = k + 1          // an escaped character
                }
                continue
            }
            if b[j] == Self.quote, !multiline || (byte(j + 1) == Self.quote && byte(j + 2) == Self.quote) {
                let after = j + (multiline ? 3 : 1)
                if hashesFollow(after, hashes) { return after + hashes }
            }
            if !multiline, b[j] == Self.newline { return j }
            j += 1
        }
        return count
    }

    private func hashesFollow(_ i: Int, _ hashes: Int) -> Bool {
        guard hashes > 0 else { return true }
        guard i + hashes <= count else { return false }
        var k = i
        while k < i + hashes { if b[k] != Self.hash { return false }; k += 1 }
        return true
    }
}

// MARK: Once per text

/// A text's UTF-8 bytes and their lexemes, as the scan readers share them.
final class LexedSource: Sendable {
    let bytes: [UInt8]
    let roles: [SwiftLexeme]

    init(_ text: String) {
        bytes = Array(text.utf8)
        roles = swiftLexemes(bytes)
    }
}

/// `text` lexed, once per distinct text per process, however many scans ask. Many suites read the
/// same `MacApp/` files, and Swift Testing runs scans on the cooperative pool, so lexing each read
/// from scratch starves main-actor work other tests are waiting on.
///
/// Keyed by the exact bytes, not by path or `String` equality: `String` compares canonically, so
/// two spellings of an `é` would share an answer that differs by byte. Texts are immutable, so an
/// answer never goes stale.
func lexed(_ text: String) -> LexedSource { lexedMemo.value(for: text) { LexedSource(text) } }

private let lexedMemo = ScanMemo<LexedSource>()
private let codeOnlyMemo = ScanMemo<String>()
private let normalizedMemo = ScanMemo<String>()

/// A thread-safe memo keyed by a text's exact UTF-8 bytes. Concurrent askers of one text wait for
/// one computation rather than each doing it, the common case when parallel suites open the same
/// file at once.
final class ScanMemo<Value>: @unchecked Sendable {
    private final class Slot {
        let lock = NSLock()
        var value: Value?
    }

    private let lock = NSLock()
    private var slots: [Data: Slot] = [:]

    func value(for text: String, _ compute: () -> Value) -> Value {
        let key = Data(text.utf8)
        lock.lock()
        let slot: Slot
        if let existing = slots[key] {
            slot = existing
        } else {
            slot = Slot()
            slots[key] = slot
        }
        lock.unlock()
        slot.lock.lock()
        defer { slot.lock.unlock() }
        if let value = slot.value { return value }
        let value = compute()
        slot.value = value
        return value
    }
}

private let spaceByte = UInt8(ascii: " "), tabByte = UInt8(ascii: "\t"), newlineByte = UInt8(ascii: "\n"),
            returnByte = UInt8(ascii: "\r")

private func isHorizontalSpace(_ c: UInt8) -> Bool { c == spaceByte || c == tabByte }
private func isSpace(_ c: UInt8) -> Bool { isHorizontalSpace(c) || c == newlineByte || c == returnByte }

/// A byte that can be part of a word — an identifier, a keyword, `$0`, `@MainActor`, `#if` — so
/// the whitespace between two of them is a separator and not layout.
private func isWordByte(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
        || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "_")
        || c == UInt8(ascii: "$") || c == UInt8(ascii: "@") || c == UInt8(ascii: "#") || c >= 0x80
}

/// Source with its comments removed, which is what a source scan should ask its questions of:
/// prose is not code.
///
/// Lexical, not line-based: a comment is whatever ``swiftLexemes(_:)`` says is one, so a trailing
/// `// …` and `/* */` go, and a `//` line inside a multi-line string or `"https://…"` stays.
/// Layout is otherwise kept: a line that was only comment is dropped whole, a line that loses a
/// trailing comment loses the whitespace before it, and every other line is untouched.
func sourceCodeOnly(_ source: String) -> String {
    codeOnlyMemo.value(for: source) { stripComments(lexed(source)) }
}

/// Source with every comment and string literal blanked to spaces, byte for byte, newlines kept:
/// a brace, a `return` or a name inside a literal or a comment is then nothing to a scan, and the
/// layout is unchanged.
func maskedCode(_ source: String) -> String {
    let lexedSource = lexed(source)
    var out = lexedSource.bytes
    for i in out.indices where lexedSource.roles[i] != .code && out[i] != newlineByte { out[i] = spaceByte }
    return String(decoding: out, as: UTF8.self)
}

private func stripComments(_ source: LexedSource) -> String {
    let n = source.bytes.count
    var out: [UInt8] = []
    out.reserveCapacity(n)
    source.bytes.withUnsafeBufferPointer { bytes in
        source.roles.withUnsafeBufferPointer { roles in
            guard let b = bytes.baseAddress, let r = roles.baseAddress else { return }   // empty
            var emittedALine = false
            func emit(_ from: Int, _ to: Int) {
                var hadComment = false
                var k = from
                while k < to { if r[k] == .comment { hadComment = true; break }; k += 1 }
                guard hadComment else {
                    if emittedALine { out.append(newlineByte) }
                    emittedALine = true
                    out.append(contentsOf: UnsafeBufferPointer(start: b + from, count: to - from))
                    return
                }
                var kept: [UInt8] = []
                k = from
                while k < to { if r[k] != .comment { kept.append(b[k]) }; k += 1 }
                if kept.allSatisfy(isHorizontalSpace) { return }
                while let last = kept.last, isHorizontalSpace(last) { kept.removeLast() }
                if emittedALine { out.append(newlineByte) }
                emittedALine = true
                out += kept
            }
            var lineStart = 0
            var k = 0
            while k < n {
                if b[k] == newlineByte {
                    emit(lineStart, k)
                    lineStart = k + 1
                }
                k += 1
            }
            emit(lineStart, n)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Code with its comments removed and its layout normalised: every run of whitespace outside a
/// string literal is dropped, except between two word characters (`let x`), where it becomes one
/// space. String literals are kept byte for byte, since a log line's words are behaviour.
///
/// So a scan built on this cannot be turned red by a reformat. Use it through ``CodeText`` or
/// ``CallArguments`` rather than directly.
func normalizedCode(_ text: String) -> String {
    normalizedMemo.value(for: text) { normalize(lexed(text)) }
}

private func normalize(_ source: LexedSource) -> String {
    let n = source.bytes.count
    var out: [UInt8] = []
    out.reserveCapacity(n)
    source.bytes.withUnsafeBufferPointer { bytes in
        source.roles.withUnsafeBufferPointer { roles in
            guard let b = bytes.baseAddress, let r = roles.baseAddress else { return }   // empty
            var pendingSpace = false
            var last: UInt8?
            var k = 0
            while k < n {
                let c = b[k]
                switch r[k] {
                case .comment:
                    pendingSpace = true
                case .code where isSpace(c):
                    pendingSpace = true
                case .code, .string:
                    if pendingSpace, let last, isWordByte(last), isWordByte(c) { out.append(spaceByte) }
                    pendingSpace = false
                    out.append(c)
                    last = c
                }
                k += 1
            }
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// A slice of code, asked its questions whitespace-insensitively: the haystack and every needle go
/// through ``normalizedCode(_:)``, so a check means the same whether the call is on one line or
/// six. Mirrors the `String` API, so converting a scan is wrapping its slice.
///
/// Ranges are into ``normalized``, so compare them only with each other, as an ordering check
/// (`load.lowerBound < pane.lowerBound`) does.
struct CodeText: CustomStringConvertible {
    let normalized: String

    init(_ source: String) { normalized = normalizedCode(source) }

    private static func needle(_ snippet: String) -> String {
        let n = normalizedCode(snippet)
        // An all-whitespace needle matches everywhere. Recorded rather than trapped (a trap takes
        // the test host down, see `textBetween`), and answered with a needle nothing contains.
        guard !n.isEmpty else {
            Issue.record("an empty needle matches everything — the scan would be vacuous")
            return "\u{0}an empty needle\u{0}"
        }
        return n
    }

    func contains(_ snippet: String) -> Bool { normalized.contains(Self.needle(snippet)) }

    func range(of snippet: String) -> Range<String.Index>? { normalized.range(of: Self.needle(snippet)) }

    /// Non-overlapping occurrences, left to right.
    func ranges(of snippet: String) -> [Range<String.Index>] { normalized.ranges(of: Self.needle(snippet)) }

    func count(of snippet: String) -> Int { ranges(of: snippet).count }

    var description: String { normalized }
}

/// The index of the `{` opening the body of the declaration that starts at `from`, or `nil` when
/// the declaration has none — a `}` closing the enclosing scope, or the next line starting a new
/// member, comes first. Parentheses and brackets are skipped, so a default argument's closure
/// (`= { }`) is not taken for the body.
private func openingBrace(ofDeclarationAt from: Int, in b: [UInt8], roles: [SwiftLexeme]) -> Int? {
    let memberKeywords: Set<String> = ["func", "var", "let", "init", "deinit", "subscript", "case",
                                       "struct", "enum", "class", "extension", "protocol", "typealias",
                                       "private", "fileprivate", "internal", "public", "static", "@"]
    var depth = 0
    var i = from
    while i < b.count {
        if roles[i] == .code {
            switch b[i] {
            case UInt8(ascii: "("), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"): depth = max(0, depth - 1)
            case UInt8(ascii: "{") where depth == 0: return i
            case UInt8(ascii: "}") where depth == 0: return nil
            case newlineByte where depth == 0:
                var j = i + 1
                while j < b.count, isHorizontalSpace(b[j]) { j += 1 }
                var word = ""
                if j < b.count, b[j] == UInt8(ascii: "@") { word = "@" }
                while j < b.count, isWordByte(b[j]), b[j] != UInt8(ascii: "@") {
                    word.append(Character(Unicode.Scalar(b[j]))); j += 1
                }
                if memberKeywords.contains(word) { return nil }
            default: break
            }
        }
        i += 1
    }
    return nil
}

/// The index of the bracket closing the one at `open` — `{`/`}` or `(`/`)` — counting only code.
private func matchingBracket(_ open: Int, in b: [UInt8], roles: [SwiftLexeme]) -> Int? {
    let opener = b[open]
    let closer = opener == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "}")
    var depth = 0
    for i in open..<b.count where roles[i] == .code {
        if b[i] == opener { depth += 1 }
        if b[i] == closer {
            depth -= 1
            if depth == 0 { return i }
        }
    }
    return nil
}

/// One declaration's body, bounded by its own closing brace (matched in code, so any indentation,
/// a one-line body or a `}` in a string reads right), from comment-stripped source.
///
/// Stripping first means the uniqueness count, the search and the slice all see the same text: a
/// decoy in a doc comment cannot pass the count yet be the match, and a `!contains` cannot be
/// answered by the member's own prose. Returns everything after `declaration` up to the closing
/// brace, less that brace's own line.
///
/// Keep one reader here rather than per-suite copies, which drift. FileExplorer's `SourceText`
/// keeps its own because the FileExplorer module cannot see this one.
func declarationBody(of declaration: String, in source: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let code = sourceCodeOnly(source)
    let occurrences = code.components(separatedBy: declaration).count - 1
    // Absence first, then ambiguity, each with its own message: a renamed member (0×) would
    // otherwise be reported as a duplicate.
    try #require(occurrences > 0,
                 "\(declaration) is gone — the scan below would be vacuous", sourceLocation: sourceLocation)
    try #require(occurrences == 1,
                 "\(declaration) occurs \(occurrences)× in code — range(of:) would silently read the first, so every check below would be about the wrong member",
                 sourceLocation: sourceLocation)
    // Cannot fail after the count above, and the message says so, so a harness bug is not read
    // as a code bug.
    let start = try #require(code.range(of: declaration),
                             "counted \(declaration) once but could not find it — the reader is broken, not the app",
                             sourceLocation: sourceLocation)
    let lexedCode = lexed(code)
    let b = lexedCode.bytes, roles = lexedCode.roles
    let from = code.utf8.distance(from: code.startIndex, to: start.lowerBound)
    let afterDeclaration = from + declaration.utf8.count
    let open = try #require(openingBrace(ofDeclarationAt: from, in: b, roles: roles),
                            "\(declaration) has no body — nothing to scan", sourceLocation: sourceLocation)
    let close = try #require(matchingBracket(open, in: b, roles: roles),
                             "no closing brace for \(declaration)", sourceLocation: sourceLocation)
    // Less the closing brace's own line: its indentation and the newline before it.
    var end = close
    while end > afterDeclaration, isHorizontalSpace(b[end - 1]) { end -= 1 }
    if end > afterDeclaration, b[end - 1] == newlineByte { end -= 1 }
    return String(decoding: b[min(afterDeclaration, end)..<end], as: UTF8.self)
}

/// The text between the parentheses of the first call of `callee` in `source`, balanced, so a scan
/// cannot read into the next call and a `)` in a string or interpolation does not end it early.
/// `callee` may be given with or without its `(`.
///
/// A call, not a mention: the name must stand alone (`FileTreeView(` does not match
/// `SidebarFileTreeView(`), must be in code rather than a string or comment, and must not be the
/// function's own declaration (`func toggleQuickLook(`).
func argumentList(of callee: String, in source: String,
                  sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    try #require(argumentLists(of: callee, in: source).first,
                 "no call to \(callee) — this scan is aimed at nothing", sourceLocation: sourceLocation)
}

/// Every call of `callee` in `source`, as ``argumentList(of:in:sourceLocation:)`` reads one, in
/// source order.
func argumentLists(of callee: String, in source: String) -> [String] {
    let name = Array((callee.hasSuffix("(") ? String(callee.dropLast()) : callee).utf8)
    guard !name.isEmpty else { return [] }
    let lexedSource = lexed(source)
    let b = lexedSource.bytes, roles = lexedSource.roles
    var lists: [String] = []
    var i = 0
    while i + name.count <= b.count {
        defer { i += 1 }
        guard b[i] == name[0], roles[i] == .code, b[i..<(i + name.count)].elementsEqual(name) else { continue }
        if isWordByte(name[0]), i > 0, isWordByte(b[i - 1]) { continue }
        var p = i + name.count
        if isWordByte(name[name.count - 1]), p < b.count, isWordByte(b[p]) { continue }
        while p < b.count, isHorizontalSpace(b[p]) { p += 1 }
        guard p < b.count, b[p] == UInt8(ascii: "("), roles[p] == .code else { continue }
        // `func name(` declares; it does not call.
        var q = i
        while q > 0, isHorizontalSpace(b[q - 1]) { q -= 1 }
        if q >= 4, String(decoding: b[(q - 4)..<q], as: UTF8.self) == "func",
           q == 4 || !isWordByte(b[q - 5]) { continue }
        guard let close = matchingBracket(p, in: b, roles: roles) else { continue }
        lists.append(String(decoding: b[(p + 1)..<close], as: UTF8.self))
    }
    return lists
}

/// One call's arguments, read by label, so a scan can ask "does this call pass `label:` with value
/// X" whatever the layout or argument order. Values are ``normalizedCode(_:)``; commas split only
/// at the top level, so a closure or a nested call is one value.
struct CallArguments {
    struct Argument: Equatable {
        let label: String?
        let value: String
    }

    let arguments: [Argument]

    /// `list` is the text between a call's parentheses — ``argumentList(of:in:sourceLocation:)``.
    init(_ list: String) {
        let lexedList = lexed(list)
        let b = lexedList.bytes, roles = lexedList.roles
        var pieces: [String] = []
        var depth = 0
        var start = 0
        for i in 0..<b.count where roles[i] == .code {
            switch b[i] {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            case UInt8(ascii: ",") where depth == 0:
                pieces.append(String(decoding: b[start..<i], as: UTF8.self))
                start = i + 1
            default: break
            }
        }
        pieces.append(String(decoding: b[start..<b.count], as: UTF8.self))
        arguments = pieces.compactMap { piece in
            let value = normalizedCode(piece)
            guard !value.isEmpty else { return nil }        // `f()`, or a trailing comma
            // `label:` is an identifier then a colon that is not the first of `::`. A ternary's
            // `a ? b : c` cannot match: the identifier would have to be all that precedes it.
            if let colon = value.firstIndex(of: ":"),
               value.index(after: colon) == value.endIndex || value[value.index(after: colon)] != ":" {
                let label = value[..<colon]
                if let first = label.first, first.isLetter || first == "_",
                   label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    return Argument(label: String(label), value: String(value[value.index(after: colon)...]))
                }
            }
            return Argument(label: nil, value: value)
        }
    }

    /// The first call of `callee` in `source`, read by label.
    init(of callee: String, in source: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        self.init(try argumentList(of: callee, in: source, sourceLocation: sourceLocation))
    }

    /// The normalised value passed as `label:`, or `nil` when the call does not pass it.
    func value(_ label: String) -> String? { arguments.first { $0.label == label }?.value }

    /// Whether the call passes `label:` exactly `expected`, compared normalised so layout cannot
    /// decide it.
    func passes(_ label: String, _ expected: String) -> Bool { value(label) == normalizedCode(expected) }

    /// The unlabeled arguments, in order: `path` in `run(path, pane: pane)`.
    var unlabeled: [String] { arguments.filter { $0.label == nil }.map(\.value) }

    /// How many times `label:` is passed: a guard that ``value(_:)`` read the only one.
    func count(_ label: String) -> Int { arguments.filter { $0.label == label }.count }
}

/// A throwaway `UserDefaults` suite, so a test can pin a defaults-driven decision without writing
/// into the app's real domain, which, with the app as test host, is the user's live settings.
/// Like `Modules/Settings/Tests/Settings`' helper of the same name it has no `wipe()`: the suite
/// goes with its last holder, so a `SettingsManager` pass that lands late writes before the wipe.
struct TestDefaults {
    let defaults: ScratchDefaults
    var suiteName: String { defaults.scratchSuiteName }

    init(_ function: String = #function) {
        self.defaults = ScratchDefaults("SyncCloudTests-\(function)")
    }
}

// MARK: - The menu bar the app built

/// The menu titled `title` in `NSApp.mainMenu`. The test host is the app, so this is what AppKit
/// made of the `.commands`, not what the source declares.
@MainActor
func appMenu(_ title: String) throws -> NSMenu {
    try #require(NSApp.mainMenu?.items.first { $0.title == title }?.submenu,
                 "the app has no \(title) menu — this check would be vacuous")
}

/// A menu's item titles, separators left out.
@MainActor
func menuTitles(_ menu: NSMenu) -> [String] {
    menu.items.filter { !$0.isSeparatorItem }.map(\.title)
}

/// Every item anywhere in the menu bar whose chord is `key` (either case) with exactly
/// `modifiers` among ⌃⌥⇧⌘.
@MainActor
func menuItems(claiming key: String, modifiers: NSEvent.ModifierFlags) throws -> [NSMenuItem] {
    var claimants: [NSMenuItem] = []
    func walk(_ menu: NSMenu) {
        for entry in menu.items {
            if entry.keyEquivalent.lowercased() == key.lowercased(),
               entry.keyEquivalentModifierMask.intersection([.control, .command, .option, .shift]) == modifiers {
                claimants.append(entry)
            }
            if let sub = entry.submenu { walk(sub) }
        }
    }
    walk(try #require(NSApp.mainMenu, "the app has no menu bar — this check would be vacuous"))
    return claimants
}

/// An item's chord as Help writes it: ⌃⌥⇧⌘, then the key in capitals.
@MainActor
func chordGlyphs(_ item: NSMenuItem) -> String {
    let mask = item.keyEquivalentModifierMask
    return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
        + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
        + item.keyEquivalent.uppercased()
}
