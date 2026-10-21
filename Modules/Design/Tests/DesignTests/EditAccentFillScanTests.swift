import Foundation
import Testing

/// **Edit fills its lit controls with the deepened accent, never the raw one.**
///
/// Edit was wired with one colour for everything: `ContentView+Editor` handed the workspace
/// `glassHue.accentColor`, and the mode capsule, the rail's tabs, the PDF header's lit actions,
/// Fill & Sign's lit tool, both Save buttons and the Autosave switch all filled with it under a
/// white label. On Green that is about 2.7:1, against the 4.5:1 every other filled surface in the
/// app keeps by filling with `LiquidGlassHue.accentFillColor` (see `AccentFill`). The fix hands Edit
/// a second colour, `accentFill`, and keeps the raw accent for what it is right for: washes,
/// hairlines, accent-coloured words and hover tints.
///
/// The failure this guards is a NEW fill written with the colour that is right next to it. Nothing
/// rendered can see that — a test hands the view whatever colour it likes — so it is a source scan,
/// like `SegmentedAccentTests.everySegmentedPickerInTheAppTakesTheAppAccent`. Three rules, over
/// Edit's sources with comments stripped:
///
/// 1. **No raw accent as a fill.** The argument of every `.fill(…)` and `.background(…)` — the
///    selection lens's `.fill(.capsule, color:)` included — may not name `accent`, `accentColor` or
///    `controlAccentColor`, unless it is turned down to a wash (`.opacity(…)`,
///    `.withAlphaComponent(…)`).
/// 2. **Every `.borderedProminent` takes `.tint(…)` with the fill.** Untinted, it paints the
///    SYSTEM accent in a window that follows the app's; tinted with the raw accent, AppKit lays its
///    white label on 2.7:1.
/// 3. **No `controlAccentColor` at all.** It is the system's accent, not the app's, so anything
///    drawn in it ignores the hue the user picked.
@Suite struct EditAccentFillScanTests {

    // MARK: The rules, on any source text

    /// One place a rule is broken: the rule, and enough of the call to find it.
    struct Finding: CustomStringConvertible, Equatable {
        let rule: String
        let snippet: String
        var description: String { "\(rule): \(snippet)" }
    }

    /// The colour names that are the RAW accent. `accentFill` and `onAccent` are not matched: the
    /// next character is a letter, or the preceding one is.
    static let rawToken = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(accent|accentColor|controlAccentColor)(?![A-Za-z0-9_])"#)

    /// AppKit's way to fill: `accent.setFill()` and then a path's `fill()`.
    static let rawSetFill = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(accent|accentColor|controlAccentColor)\.setFill\(\)"#)

    /// What turns a colour into a wash, which the raw accent is right for.
    static let washes = [".opacity(", ".withAlphaComponent("]

    static func findings(in source: String) -> [Finding] {
        let text = Array(stripComments(source))
        var found: [Finding] = []

        // Rule 1: the argument of every fill.
        for opener in [".fill(", ".background("] {
            for start in occurrences(of: opener, in: text) {
                let open = start + opener.count - 1
                guard let close = matching(text, open) else { continue }
                let argument = reduced(Array(text[(open + 1)..<close]))
                if namesRawAccent(argument) {
                    found.append(Finding(rule: "raw accent fill", snippet: snippet(text, start, close)))
                }
            }
        }

        // Rule 1 in AppKit drawing: the raw accent set as the fill colour, untouched.
        let joined = String(text)
        let range = NSRange(location: 0, length: (joined as NSString).length)
        for match in rawSetFill.matches(in: joined, range: range) {
            found.append(Finding(rule: "raw accent fill", snippet: (joined as NSString).substring(with: match.range)))
        }

        // Rule 2: every prominent button's tint.
        let prominent = ".buttonStyle(.borderedProminent)"
        for start in occurrences(of: prominent, in: text) {
            let tints = chain(text, after: start + prominent.count).filter { $0.name == "tint" }
            let site = snippet(text, start, min(text.count - 1, start + prominent.count + 60))
            if tints.isEmpty {
                found.append(Finding(rule: "untinted .borderedProminent", snippet: site))
            } else if tints.contains(where: { namesRawAccent(reduced(Array($0.argument))) }) {
                found.append(Finding(rule: ".borderedProminent tinted with the raw accent", snippet: site))
            }
        }

        // Rule 3: the system accent, drawn.
        for start in occurrences(of: "controlAccentColor", in: text) {
            found.append(Finding(rule: "controlAccentColor",
                                 snippet: snippet(text, max(0, start - 30), min(text.count - 1, start + 30))))
        }
        return found
    }

    /// Whether `argument` names the raw accent anywhere it is not turned down to a wash.
    static func namesRawAccent(_ argument: String) -> Bool {
        let ns = argument as NSString
        return rawToken.matches(in: argument, range: NSRange(location: 0, length: ns.length)).contains { match in
            let after = ns.substring(from: match.range.upperBound)
            return !washes.contains { after.hasPrefix($0) }
        }
    }

    /// `argument` with every method call's arguments dropped — `.opacity(0.18)` becomes
    /// `.opacity()` — so a colour handed to a nested view's modifier (`.strokeBorder(accent)` inside
    /// a `.background(…)`) does not count as the fill, while a wrapper that IS the fill
    /// (`AnyShapeStyle(accent)`, a ternary) still does. A nested `.fill(…)` is scanned on its own.
    /// Closures go too: a `{ … }` inside a fill is a view, scanned where its own fills are.
    static func reduced(_ argument: [Character]) -> String {
        var out: [Character] = []
        var i = 0
        while i < argument.count {
            let c = argument[i]
            if c == "{", let close = matching(argument, i) {
                out.append(contentsOf: "{}")
                i = close + 1
                continue
            }
            if c == "(", let previous = out.last, previous.isLetter || previous.isNumber || previous == "_",
               isMethodCall(out), let close = matching(argument, i) {
                out.append(contentsOf: "()")
                i = close + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Whether the identifier just written to `out` follows a dot — `x.opacity` — rather than
    /// standing alone like `AnyShapeStyle`.
    private static func isMethodCall(_ out: [Character]) -> Bool {
        var j = out.count - 1
        while j >= 0, out[j].isLetter || out[j].isNumber || out[j] == "_" { j -= 1 }
        return j >= 0 && out[j] == "."
    }

    /// The modifiers chained straight after `index`: `.name(argument)`, each with any trailing
    /// closure, for as long as the next thing is another `.`.
    static func chain(_ text: [Character], after index: Int) -> [(name: String, argument: [Character])] {
        var modifiers: [(String, [Character])] = []
        var i = index
        func skipSpace() { while i < text.count, text[i].isWhitespace { i += 1 } }
        while true {
            skipSpace()
            guard i < text.count, text[i] == "." else { break }
            i += 1
            var name = ""
            while i < text.count, text[i].isLetter || text[i].isNumber || text[i] == "_" { name.append(text[i]); i += 1 }
            guard !name.isEmpty else { break }
            var argument: [Character] = []
            if i < text.count, text[i] == "(", let close = matching(text, i) {
                argument = Array(text[(i + 1)..<close])
                i = close + 1
            }
            skipSpace()
            if i < text.count, text[i] == "{", let close = matching(text, i) { i = close + 1 }
            modifiers.append((name, argument))
        }
        return modifiers
    }

    /// The index of the bracket closing the one at `open`, skipping string literals.
    static func matching(_ text: [Character], _ open: Int) -> Int? {
        let pairs: [Character: Character] = ["(": ")", "{": "}", "[": "]"]
        guard let closer = pairs[text[open]] else { return nil }
        var depth = 0
        var inString = false
        var i = open
        while i < text.count {
            let c = text[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == text[open] {
                depth += 1
            } else if c == closer {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    static func occurrences(of needle: String, in text: [Character]) -> [Int] {
        let n = Array(needle)
        guard let first = n.first, n.count <= text.count else { return [] }
        var found: [Int] = []
        var start = 0
        while start <= text.count - n.count {
            if text[start] == first {
                var k = 1
                while k < n.count, text[start + k] == n[k] { k += 1 }
                if k == n.count { found.append(start) }
            }
            start += 1
        }
        return found
    }

    /// Each line with any `//` comment removed — only one outside a string literal, so a URL's
    /// `https://` survives — and every run of whitespace collapsed, so a call wrapped over lines
    /// reads as one.
    static func stripComments(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            var inString = false
            var previous: Character = " "
            for (offset, c) in line.enumerated() {
                if c == "\"" && previous != "\\" { inString.toggle() }
                if !inString, c == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = c
            }
            return line
        }
        .joined(separator: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func snippet(_ text: [Character], _ from: Int, _ to: Int) -> String {
        String(text[from...min(to, from + 140)])
    }

    // MARK: The scan can fail

    /// Every rule, broken once and kept once — so a matcher that silently stopped matching cannot
    /// pass the real scan below on a tree that has the bug.
    @Test func eachRuleCatchesItsBugAndPassesItsFix() {
        func rules(_ source: String) -> [String] { Self.findings(in: source).map(\.rule) }

        // Rule 1, broken: a lit chip, a ternary through AnyShapeStyle, the lens's style, the
        // system accent, a fill wrapped over two lines.
        #expect(rules(".background(isOn ? accent : .clear, in: RoundedRectangle(cornerRadius: 4))") == ["raw accent fill"])
        #expect(rules(".fill(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.quaternary))") == ["raw accent fill"])
        #expect(rules(".selectionLensHost(c, selected: s, style: .fill(.capsule, color: accent))") == ["raw accent fill"])
        #expect(rules("SelectionLensTodayMarker { Capsule().fill(accent) }") == ["raw accent fill"])
        #expect(rules(".fill(hovering ? Color.accentColor : .clear)") == ["raw accent fill"])
        #expect(rules(".fill(glassHue.accentColor)") == ["raw accent fill"])
        #expect(rules(".fill(\n    lit\n    ? accent\n    : .clear)") == ["raw accent fill"])
        // ...and kept: the fill, washes, a hairline inside a background, words, comments.
        #expect(rules(".background(isOn ? accentFill : .clear, in: RoundedRectangle(cornerRadius: 4))").isEmpty)
        #expect(rules(".selectionLensHost(c, selected: s, style: .fill(.capsule, color: accentFill))").isEmpty)
        #expect(rules(".fill(AccentFill.deepened(.accentColor))").isEmpty)
        #expect(rules(".fill(accent.opacity(lit ? 0.14 : 0))").isEmpty)
        #expect(rules(".background(Capsule().fill(railIsHidden ? accent.opacity(0.18) : .clear))").isEmpty)
        #expect(rules("(open ? accent.withAlphaComponent(0.12) : NSColor.gray).setFill()").isEmpty)
        #expect(rules("accent.setFill()\nbox.fill()") == ["raw accent fill"])
        #expect(rules(".background(Capsule().strokeBorder(accent, lineWidth: 1))").isEmpty)
        #expect(rules(".background { Capsule().strokeBorder(accent) }").isEmpty)
        #expect(rules(".foregroundStyle(lit ? accent : .primary)").isEmpty)
        #expect(rules(".fill(onAccent) // was .fill(accent)").isEmpty)
        #expect(rules(".fill(Color(nsColor: .separatorColor)) // see https://example.com").isEmpty)

        // Rule 2.
        #expect(rules("Button(\"Save\") {}.buttonStyle(.borderedProminent).disabled(x)") == ["untinted .borderedProminent"])
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .tint(accent)")
                == [".borderedProminent tinted with the raw accent"])
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .help(\"x\") .tint(accentFill)").isEmpty)
        // A tint on the NEXT control is not this one's.
        #expect(rules("Button(\"A\") {}.buttonStyle(.borderedProminent) Button(\"B\") {}.tint(accentFill)")
                == ["untinted .borderedProminent"])

        // Rule 3.
        #expect(rules("let accent = NSColor.controlAccentColor\naccent.setStroke()") == ["controlAccentColor"])
        #expect(rules("// NSColor.controlAccentColor is the system's").isEmpty)
    }

    // MARK: Edit

    /// Edit's lit controls fill with the deepened accent, and nothing in Edit draws the system's.
    @Test func editFillsWithTheDeepenedAccent() throws {
        var findings: [String] = []
        var fills = 0
        for file in try Self.editSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            findings += Self.findings(in: source).map { "\(file.lastPathComponent) — \($0)" }
            fills += Self.occurrences(of: "accentFill", in: Array(Self.stripComments(source))).count
        }
        #expect(findings.isEmpty, """
            Edit fills a control with the RAW accent, or draws the system's. A white label on the raw \
            accent is 2.7:1 on Green; fill with `accentFill` (`LiquidGlassHue.accentFillColor`), and \
            keep `accent` for washes, hairlines and words:
            \(findings.joined(separator: "\n"))
            """)
        // A tripwire, so the scan cannot pass by reading files that no longer hold the controls.
        #expect(fills >= 30, "only \(fills) mentions of `accentFill` in Edit — is the scan reading the right files?")
    }

    /// **The host hands Edit the deepened fill.** Every view below it can only fill with what it is
    /// given; the one line that decides it is in `ContentView+Editor`.
    @Test func theHostHandsEditTheDeepenedFill() throws {
        let host = try Self.editSources().first { $0.lastPathComponent == "ContentView+Editor.swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        let call = try #require(host.map(Self.stripComments), "ContentView+Editor.swift is not being scanned")
        // Bools, so a failure prints the sentence rather than the whole file.
        let handsTheFill = call.contains("accentFill: glassHue.accentFillColor")
        let handsTheAccent = call.contains("accent: glassHue.accentColor")
        #expect(handsTheFill, "the workspace is not handed `accentFill: glassHue.accentFillColor`")
        #expect(handsTheAccent, "the workspace is not handed the raw accent for its washes and words")
    }

    /// Edit's sources: the module's `Editor…` and `Markdown…` files, MacApp's `Editor…` files, and
    /// `ContentView+Editor`, the host that hands the workspace its colours.
    static func editSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)      // …/Design/Tests/DesignTests/<this>.swift
            .deletingLastPathComponent()                // …/Design/Tests/DesignTests
            .deletingLastPathComponent()                // …/Design/Tests
            .deletingLastPathComponent()                // …/Modules/Design
            .deletingLastPathComponent()                // …/Modules
            .deletingLastPathComponent()                // …/<repo>
        let module = repo.appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer")
        let app = repo.appendingPathComponent("MacApp")
        let manager = FileManager.default
        let moduleFiles = try manager.contentsOfDirectory(at: module, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .filter { $0.lastPathComponent.hasPrefix("Editor") || $0.lastPathComponent.hasPrefix("Markdown") }
        let appFiles = try manager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .filter { $0.lastPathComponent.hasPrefix("Editor") || $0.lastPathComponent == "ContentView+Editor.swift" }
        let files = moduleFiles + appFiles
        // Prove the roots resolved, or every rule passes on nothing.
        #expect(moduleFiles.count > 60, "found only \(moduleFiles.count) Edit sources in FileExplorer")
        #expect(files.contains { $0.lastPathComponent == "EditorMode.swift" }, "EditorMode.swift is not being scanned")
        #expect(files.contains { $0.lastPathComponent == "ContentView+Editor.swift" }, "MacApp is not being scanned")
        return files
    }
}
