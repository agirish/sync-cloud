import Foundation
import Testing

/// The app fills its lit controls with the deepened accent, never the raw one.
///
/// A white label on the raw accent is about 2.7:1 on Green, against the 4.5:1 every filled surface
/// keeps by filling with `LiquidGlassHue.accentFillColor` (see `AccentFill`). Edit gets two colours
/// from its host: `accentFill` for fills, and the raw accent for washes, hairlines, accent-coloured
/// words and hover tints.
///
/// The failure guarded is a new fill written with the colour right next to it. A render can't see
/// that (a test hands the view whatever colour it likes), so this is a source scan, like
/// `SegmentedAccentTests.everySegmentedPickerInTheAppTakesTheAppAccent`. Seven rules, over the
/// app's sources with comments stripped:
///
/// 1. No raw accent as a fill. The argument of every `.fill(…)` and `.background(…)`, the
///    selection lens's `.fill(.capsule, color:)` included, may not name `accent`, `accentColor` or
///    `controlAccentColor` unless turned down to a wash (`.opacity(…)`, `.withAlphaComponent(…)`).
///    Nor may a view's `accentFill:` be handed the raw accent, which no scan of the view can see.
/// 2. Every `.borderedProminent` takes `.accentedProminent(…)` and no `.tint` of its own.
///    Untinted it paints the system accent; tinted with the raw accent, its white label sits at
///    2.7:1. The seam picks the deepened fill, and the stock blue at None (`ProminentAccent.swift`).
///    A `.keyboardShortcut(.defaultAction)` button fills with the tint too, so a file with one
///    must tint it with `.accentedProminent` or draw it as `.actionBar`.
/// 3. No `controlAccentColor` outside `systemAccentExemptions` (the None hue, which is the Mac's
///    accent). Anything else drawn in it ignores the hue the user picked.
/// 4. No SwiftUI `Color.accentColor` either, drawn or as a default argument, outside
///    `systemAccentExemptions`: it is the same system accent. A colour parameter defaults to
///    `LiquidGlassHue.stored()`, or to nil resolved through `StoredHueReader`.
/// 5. No ShapeStyle `.tint`. With no `.tint(…)` above it, it is the system accent, and whether one
///    is above it is a fact about another file, or about whether a `List` or `Table` row host
///    passes it down. Name the hue's `accentColor` instead.
/// 6. Every window root sets the native controls' accent. Switches, sliders, checkboxes and
///    progress bars fill with whatever accent the environment carries, the Mac's if none. So each
///    scene's root, each panel the owner named (Settings, Help, Setup) and each
///    `NSHostingView`/`NSHostingController` the app builds takes `.nativeControlAccent(…)`, or is
///    named in ``unaccentedHosts`` with why. A rule about roots, because the accent inherits and a
///    new window or hosted panel is how an untinted control would come back. The accent stops at
///    a `.sheet`, `.popover`, `.fullScreenCover` or `.inspector`, so each one's content takes
///    `.presentedNativeControlAccent()`, or is named in ``unaccentedPresentations`` with why.
/// 7. No raw-accent `.tint` at all, outside ``rawTintExemptions``. A container's `.tint` beats the
///    root's accent for every control under it, so a checkbox or switch fills with the raw shade
///    (white on raw Amber is 2.2:1). On a `Button` it colours the words, at 2.3:1 on the light
///    bezel at Green (`ButtonWordInkTests`), so a button's words take `.buttonWordsTint(…)`, which
///    deepens them in light and whitens them in dark. A `ViewModifier` tinting its `content` with
///    a colour handed in is caught too, since that colour is named only at the call site. Nor may
///    `.accentedProminent(…)` hang off anything but a `Button`: over a subtree it draws every
///    untinted button's words in the deepened fill (2.9:1 on the dark bezel at Green). Which
///    buttons a root covers is a fact about other files, so the rule is about the root.
@Suite struct AccentFillScanTests {

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

    static let prominent = ".buttonStyle(.borderedProminent)"

    /// SwiftUI's system accent: `Color.accentColor`, or `.accentColor` where a `Color` is inferred.
    /// Not `hue.accentColor` or `(…).accentColor` — a property of something else.
    static let systemAccent = try! NSRegularExpression(
        pattern: #"((?<![A-Za-z0-9_])Color|(?<![A-Za-z0-9_)\]?!]))\.accentColor(?![A-Za-z0-9_])"#)

    /// SwiftUI's tint as a style: `.tint` where a `ShapeStyle` is inferred, `.tint.opacity(…)`,
    /// `TintShapeStyle()`. Not the `.tint(…)` modifier, nor `hue.tint` — a property of something else.
    static let tintStyle = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_)\]?!])\.tint(?![A-Za-z0-9_(])|(?<![A-Za-z0-9_])TintShapeStyle(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])ShapeStyle\.tint(?![A-Za-z0-9_(])"#)

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

        // Rule 1 at the hand-off: a view's `accentFill:` handed the raw accent fills with it inside.
        for start in occurrences(of: "accentFill:", in: text) {
            let argument = String(text[(start + "accentFill:".count)...].drop { $0 == " " }
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
            if namesRawAccent(argument) {
                found.append(Finding(rule: "raw accent handed as accentFill",
                                     snippet: snippet(text, start, start + "accentFill:".count + argument.count)))
            }
        }

        // Rule 2: every prominent button's tint comes from the seam, and only from it.
        for start in occurrences(of: prominent, in: text) {
            let names = chain(text, after: start + prominent.count).map(\.name)
            let site = snippet(text, start, min(text.count - 1, start + prominent.count + 60))
            if names.contains("tint") {
                found.append(Finding(rule: ".borderedProminent tinted past the seam", snippet: site))
            } else if !names.contains("accentedProminent") {
                found.append(Finding(rule: "untinted .borderedProminent", snippet: site))
            }
        }

        // Rule 2, for default buttons: the file tints them somewhere.
        if !occurrences(of: ".keyboardShortcut(.defaultAction)", in: text).isEmpty,
           occurrences(of: ".accentedProminent(", in: text).isEmpty,
           occurrences(of: ".actionBar(", in: text).isEmpty {
            found.append(Finding(rule: "untinted default button", snippet: ".keyboardShortcut(.defaultAction)"))
        }

        // Rule 3: the system accent, drawn.
        for start in occurrences(of: "controlAccentColor", in: text) {
            found.append(Finding(rule: "controlAccentColor",
                                 snippet: snippet(text, max(0, start - 30), min(text.count - 1, start + 30))))
        }

        // Rule 4: SwiftUI's name for the same system accent.
        let characters = joined as NSString
        for match in systemAccent.matches(in: joined, range: range) {
            let from = max(0, match.range.location - 40)
            let to = min(characters.length, match.range.upperBound + 20)
            found.append(Finding(rule: "system accent",
                                 snippet: characters.substring(with: NSRange(location: from, length: to - from))))
        }

        // Rule 5: the same system accent, as the tint nothing set.
        for match in tintStyle.matches(in: joined, range: range) {
            let from = max(0, match.range.location - 40)
            let to = min(characters.length, match.range.upperBound + 20)
            found.append(Finding(rule: "tint style",
                                 snippet: characters.substring(with: NSRange(location: from, length: to - from))))
        }

        // Rule 7: no raw-accent tint — over a subtree's controls, or as a button's words.
        let partners = openers(text)
        for start in occurrences(of: ".tint(", in: text) {
            let open = start + ".tint(".count - 1
            guard let close = matching(text, open) else { continue }
            let argument = String(text[(open + 1)..<close]).trimmingCharacters(in: .whitespaces)
            guard let root = receiverRoot(text, partners, before: start) else { continue }
            let site = "\(root.name)\(snippet(text, root.index + root.name.count, close).prefix(40))"
            if namesRawAccent(reduced(Array(argument))) {
                found.append(Finding(rule: root.name == "Button" ? "raw accent tint on a button's words"
                                                                 : "raw accent tint over a subtree", snippet: site))
            } else if root.name == "content", argument.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                found.append(Finding(rule: "tint handed through a modifier", snippet: site))
            }
        }

        // Rule 7, the prominent tint: on the button it fills, never over a subtree of words.
        // `content` is a `ViewModifier` passing it on to the button the modifier is applied to.
        for start in occurrences(of: ".accentedProminent(", in: text) {
            let root = receiverRoot(text, partners, before: start)
            if root?.name == "Button" || root?.name == "content" { continue }
            let from = root.map { $0.index } ?? start
            found.append(Finding(rule: "prominent tint over a subtree",
                                 snippet: String(snippet(text, from, min(text.count - 1, start + 20)).prefix(80))))
        }
        return found
    }

    /// The call a modifier chain hangs off, walking back from the `.` at `index` over modifiers,
    /// their arguments and trailing closures (`label:` ones too): `Button`, `List`, `VStack`, or
    /// `content` inside a `ViewModifier`. Nil when the chain starts with a bare `.` (`.regular.tint`).
    static func receiverRoot(_ text: [Character], _ partners: [Int: Int], before index: Int) -> (name: String, index: Int)? {
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var i = index - 1
        while true {
            while i >= 0, text[i] == " " { i -= 1 }
            guard i >= 0 else { return nil }
            if text[i] == ")" || text[i] == "}" || text[i] == "]" {
                guard let open = partners[i] else { return nil }
                i = open - 1
                continue
            }
            let isLabel = text[i] == ":"
            if isLabel { i -= 1 }
            guard i >= 0, isWord(text[i]) else { return nil }
            let end = i
            while i >= 0, isWord(text[i]) { i -= 1 }
            if isLabel || (i >= 0 && text[i] == ".") {
                if !isLabel { i -= 1 }
                continue
            }
            return (String(text[(i + 1)...end]), i + 1)
        }
    }

    /// Every closing bracket's opening one, skipping string literals as `matching` does.
    static func openers(_ text: [Character]) -> [Int: Int] {
        var partners: [Int: Int] = [:]
        var stack: [Int] = []
        var inString = false
        var i = 0
        while i < text.count {
            let c = text[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "(" || c == "{" || c == "[" {
                stack.append(i)
            } else if c == ")" || c == "}" || c == "]", let open = stack.popLast() {
                partners[i] = open
            }
            i += 1
        }
        return partners
    }

    /// Whether `argument` names the raw accent anywhere it is not turned down to a wash. The wash
    /// may close a wrapper first: `(lit ? accent : x).opacity(…)`, `NSColor(accent).withAlphaComponent(…)`.
    static func namesRawAccent(_ argument: String) -> Bool {
        let ns = argument as NSString
        return rawToken.matches(in: argument, range: NSRange(location: 0, length: ns.length)).contains { match in
            let after = ns.substring(from: match.range.upperBound).drop { $0 == ")" || $0 == " " }
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
    /// closure, for as long as the next thing is another `.`. With `trailingClosureIsArgument`, a
    /// trailing closure is read as part of its modifier's argument.
    static func chain(_ text: [Character], after index: Int,
                      trailingClosureIsArgument: Bool = false) -> [(name: String, argument: [Character])] {
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
            if i < text.count, text[i] == "{", let close = matching(text, i) {
                if trailingClosureIsArgument { argument += Array(text[(i + 1)..<close]) }
                i = close + 1
            }
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

    /// Each line through `codeOnly`, and every run of whitespace collapsed, so a call wrapped over
    /// lines reads as one.
    static func stripComments(_ source: String) -> String {
        source.components(separatedBy: "\n").map { SourceComments.codeOnly($0) }
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
        #expect(rules(".fill(hovering ? Color.accentColor : .clear)") == ["raw accent fill", "system accent"])
        #expect(rules(".fill(glassHue.accentColor)") == ["raw accent fill"])
        #expect(rules(".fill(\n    lit\n    ? accent\n    : .clear)") == ["raw accent fill"])
        // ...and kept: the fill, washes, a hairline inside a background, words, comments.
        #expect(rules(".background(isOn ? accentFill : .clear, in: RoundedRectangle(cornerRadius: 4))").isEmpty)
        #expect(rules(".selectionLensHost(c, selected: s, style: .fill(.capsule, color: accentFill))").isEmpty)
        #expect(rules(".fill(AccentFill.deepened(accent))").isEmpty)
        #expect(rules(".fill(accent.opacity(lit ? 0.14 : 0))").isEmpty)
        #expect(rules(".background(Capsule().fill(railIsHidden ? accent.opacity(0.18) : .clear))").isEmpty)
        #expect(rules("(open ? accent.withAlphaComponent(0.12) : NSColor.gray).setFill()").isEmpty)
        #expect(rules(".fill((empty ? Color.primary : accent).opacity(PillVariant.fillOpacity))").isEmpty)
        #expect(rules(".background(Styler(wash: NSColor(glassHue.accentColor)\n .withAlphaComponent(0.2)))").isEmpty)
        #expect(rules(".fill(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))") == ["raw accent fill"])
        #expect(rules("accent.setFill()\nbox.fill()") == ["raw accent fill"])
        #expect(rules(".background(Capsule().strokeBorder(accent, lineWidth: 1))").isEmpty)
        #expect(rules(".background { Capsule().strokeBorder(accent) }").isEmpty)
        #expect(rules(".foregroundStyle(lit ? accent : .primary)").isEmpty)
        #expect(rules(".fill(onAccent) // was .fill(accent)").isEmpty)
        #expect(rules(".fill(Color(nsColor: .separatorColor)) // see https://example.com").isEmpty)

        // Rule 2.
        #expect(rules("Button(\"Save\") {}.buttonStyle(.borderedProminent).disabled(x)") == ["untinted .borderedProminent"])
        // Rule 7 sees the raw hue on the button too.
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .tint(accent)")
                == [".borderedProminent tinted past the seam", "raw accent tint on a button's words"])
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .tint(accentFill)")
                == [".borderedProminent tinted past the seam"])
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .accentedProminent() .tint(.red)")
                == [".borderedProminent tinted past the seam"])
        #expect(rules("Button(\"Save\") { go() } .buttonStyle(.borderedProminent) .help(\"x\") .accentedProminent()").isEmpty)
        #expect(rules("Button(\"Go\") {}.buttonStyle(.borderedProminent).accentedProminent(glassHue).controlSize(.small)").isEmpty)
        // A tint on the NEXT control is not this one's.
        #expect(rules("Button(\"A\") {}.buttonStyle(.borderedProminent) Button(\"B\") {}.accentedProminent()")
                == ["untinted .borderedProminent"])

        #expect(rules("StorageSectionBar(section: $s, accentFill: glassHue.accentColor, onAccent: .white)")
                == ["raw accent handed as accentFill"])
        #expect(rules("StorageSectionBar(section: $s, accentFill: glassHue.accentFillColor, onAccent: .white)").isEmpty)
        #expect(rules("init(accentFill: Color = LiquidGlassHue.stored().accentFillColor)").isEmpty)

        // Rule 2, default buttons.
        #expect(rules("Button(\"Done\") { dismiss() }.keyboardShortcut(.defaultAction)") == ["untinted default button"])
        #expect(rules("Button(\"Done\") { dismiss() }.keyboardShortcut(.defaultAction).accentedProminent()").isEmpty)
        #expect(rules("// no .keyboardShortcut(.defaultAction) here").isEmpty)

        // Rule 3.
        #expect(rules("let accent = NSColor.controlAccentColor\naccent.setStroke()") == ["controlAccentColor"])
        #expect(rules("// NSColor.controlAccentColor is the system's").isEmpty)

        // Rule 4, broken: words, a wash, a default argument, an inferred `.accentColor`, a deepened one.
        #expect(rules(".foregroundStyle(Color.accentColor)") == ["system accent"])
        #expect(rules(".background(Color.accentColor.opacity(0.10), in: Capsule())") == ["system accent"])
        #expect(rules("init(tint: Color = .accentColor) {}") == ["system accent"])
        #expect(rules("SelectionLensStyle(shape: .circle, color: .accentColor, markerOpacity: 0)") == ["system accent"])
        #expect(rules("var accentFill: Color = AccentFill.deepened(.accentColor)") == ["system accent"])
        #expect(rules("let c = SwiftUI.Color.accentColor") == ["system accent"])
        // ...and kept: the app's hue, under every spelling it takes, and comments.
        #expect(rules(".foregroundStyle(glassHue.accentColor)").isEmpty)
        #expect(rules(".foregroundStyle((LiquidGlassHue(rawValue: raw) ?? .blue).accentColor)").isEmpty)
        #expect(rules("init(tint: Color = LiquidGlassHue.stored().accentColor) {}").isEmpty)
        #expect(rules("let c = hue?.accentColor ?? x; let d = hue!.accentColor; let e = hues[0].accentColor").isEmpty)
        #expect(rules(".fill(accentColor.opacity(0.1))").isEmpty)
        #expect(rules("// `Color.accentColor` is the SYSTEM accent").isEmpty)

        // Rule 5, broken: words, a wash through AnyShapeStyle, a fill, the type by name.
        #expect(rules(".foregroundStyle(.tint)") == ["tint style"])
        #expect(rules(".foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))") == ["tint style"])
        #expect(rules(".fill(AnyShapeStyle(.tint.opacity(isDeepest ? 1 : 0.45)))") == ["tint style"])
        #expect(rules("Capsule().fill(.tint)") == ["tint style"])
        #expect(rules(".foregroundStyle(TintShapeStyle())") == ["tint style"])
        #expect(rules("let s: some ShapeStyle = ShapeStyle.tint") == ["tint style"])
        // ...and kept: the modifier, a property named tint, comments.
        #expect(rules(".tint(glassHue.accentColor)").isEmpty)
        #expect(rules(".tint(SegmentedAccent.tint(for: hue))").isEmpty)
        #expect(rules(".foregroundStyle(ProviderHue.classify(name).tint)").isEmpty)
        #expect(rules(".fill(hue?.tint.opacity(0.2) ?? .clear); .foregroundStyle(section.tint)").isEmpty)
        #expect(rules(".foregroundStyle(hue.accentColor) // was .foregroundStyle(.tint)").isEmpty)

        // Rule 7, broken: a card, a list, a ternary, a chain with trailing closures and labels.
        let subtree = "raw accent tint over a subtree"
        #expect(rules("VStack(spacing: 10) { Toggle(\"x\", isOn: $x) }.padding(14).tint(accent)") == [subtree])
        #expect(rules("List(selection: $s) { ForEach(rows) { row in Row(row) } }\n  .listStyle(.sidebar)\n  .tint(glassHue.accentColor)") == [subtree])
        #expect(rules("Table(of: D.self) { TableColumn(\"N\") { Text($0.n) } } rows: { ForEach(d) { TableRow($0) } } .onChange(of: x) { _, y in go(y) } .tint(lit ? accent : nil)") == [subtree])
        #expect(rules("Form { Slider(value: $v) }.tint((LiquidGlassHue(rawValue: raw) ?? .blue).accentColor)") == [subtree])
        #expect(rules("func body(content: Content) -> some View { content.tint(tint).controlSize(.large) }") == ["tint handed through a modifier"])
        // A button's words, every way one is written: the raw hue as words is 2.3:1 on the light
        // bezel.
        let words = "raw accent tint on a button's words"
        #expect(rules("Button(\"Cancel\") { if a { b() } else { c = false } }\n .keyboardShortcut(.cancelAction)\n .tint(glassHue.accentColor)") == [words])
        #expect(rules("Button { onFix([r]) } label: { Text(\"Fix\").fontWeight(.semibold) } .buttonStyle(.borderless) .tint(accent)") == [words])
        #expect(rules("Button(action: go) { Label(\"Download\", systemImage: \"icloud\") }.buttonStyle(.bordered).tint(tinted ? accent : nil)") == [words])
        #expect(rules("Button { go() } label: { Text(\"Rename all\") }.buttonStyle(.bordered).controlSize(.small).tint(c == .pad ? accent : tint(c))") == [words])
        #expect(rules("Button(\"Cancel\") {}.tint((LiquidGlassHue(rawValue: raw) ?? .blue).accentColor)") == [words])
        // ...and kept: the words at a depth they read at, every way one is written; the deepened
        // fill; a wash; Liquid Glass's tint; a seam; comments.
        #expect(rules("Button(\"Cancel\") { if a { b() } else { c = false } }\n .keyboardShortcut(.cancelAction)\n .buttonWordsTint(glassHue.accentColor)").isEmpty)
        #expect(rules("Button { onFix([r]) } label: { Text(\"Fix\") } .buttonStyle(.borderless) .buttonWordsTint(accent)").isEmpty)
        #expect(rules("Button(action: go) { Label(\"Download\", systemImage: \"icloud\") }.buttonStyle(.bordered).buttonWordsTint(tinted ? accent : nil)").isEmpty)
        #expect(rules("Button(\"Fix all\") {}.buttonStyle(.bordered).tint(SemanticColor.error)").isEmpty)
        #expect(rules("VStack { Toggle(\"x\", isOn: $x) }.tint(hue.accentFillColor)").isEmpty)
        #expect(rules("VStack { Toggle(\"x\", isOn: $x) }.tint(accent.opacity(0.4))").isEmpty)
        #expect(rules(".glassEffect(.regular.tint(accent.opacity(strength)), in: Capsule())").isEmpty)
        #expect(rules("content.tint(SegmentedAccent.tint(for: hue))").isEmpty)
        #expect(rules("VStack { } // .tint(accent)").isEmpty)

        // Rule 7, the prominent tint over a subtree: a sheet's root, a stack, a view handed one in
        // another file, a chain broken over lines.
        let root = "prominent tint over a subtree"
        #expect(rules("Group { switch sheet { case .a: A() } }.padding(20).frame(minWidth: 400).accentedProminent()") == [root])
        #expect(rules("VStack { Button(\"Go\") {}.keyboardShortcut(.defaultAction) }.accentedProminent()") == [root])
        #expect(rules("EditorPDFBatchSheet(batch: batch)\n .padding(20)\n .accentedProminent()\n .presentedNativeControlAccent()") == [root])
        #expect(rules("HStack { Button(\"Clear All\") {} }.accentedProminent(glassHue)") == [root])
        // ...and kept: on the button, every way one is written, and the seam's own modifier.
        #expect(rules("Button(action, action: run)\n .keyboardShortcut(.defaultAction)\n .disabled(!canRun)\n .accentedProminent()").isEmpty)
        #expect(rules("Button { go() } label: { Label(\"File\", systemImage: \"tray\") }.buttonStyle(.borderedProminent).accentedProminent(hue)").isEmpty)
        #expect(rules("func body(content: Content) -> some View { content.accentedProminent(LiquidGlassHue(rawValue: raw) ?? .blue) }").isEmpty)
        #expect(rules("VStack { } // .accentedProminent()").isEmpty)
    }

    // MARK: Edit

    /// The host hands Edit the deepened fill. Every view below it can only fill with what it is
    /// given; the one line that decides it is in `ContentView+Editor`.
    @Test func theHostHandsEditTheDeepenedFill() throws {
        let host = try Self.appSources().first { $0.lastPathComponent == "ContentView+Editor.swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        let call = try #require(host.map(Self.stripComments), "ContentView+Editor.swift is not being scanned")
        // Bools, so a failure prints the sentence rather than the whole file.
        let handsTheFill = call.contains("accentFill: glassHue.accentFillColor")
        let handsTheAccent = call.contains("accent: glassHue.accentColor")
        #expect(handsTheFill, "the workspace is not handed `accentFill: glassHue.accentFillColor`")
        #expect(handsTheAccent, "the workspace is not handed the raw accent for its washes and words")
    }

    // MARK: The whole app

    /// A raw-accent fill that is right, named with why: a mark with no label on it, or a swatch that
    /// IS the hue. Each must still match exactly one finding — an entry listed twice, two — so a
    /// stale entry fails too.
    static let markExemptions: [(file: String, fill: String, why: String)] = [
        ("AppearanceScreen.swift", ".fill(offered.accentColor)", "setup's hue swatch shows the hue itself"),
        ("SettingsView.swift", ".fill(hue.accentColor)", "Settings' hue swatch shows the hue itself"),
        ("FolderSidebar.swift", ".fill(accent)", "the 2pt drop caret between rows"),
        ("PaneBarCustomizeSheet.swift", ".fill(glassHue.accentColor)", "the 3pt drop caret between pills"),
        ("PaneBarCustomizeSheet.swift", ".fill(glassHue.accentColor)", "the same caret at the track's leading edge"),
        ("PaneTabStrip.swift", ".fill(accent)", "the 2pt rule under the active tab"),
        ("DocumentSurveyCard.swift", ".fill(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))",
         "the survey's 5pt progress bar"),
        ("DifferencesView.swift", ".fill(glassHue.accentColor)", "the 7pt dot beside \"Reviewing N of M\""),
        ("VisualPairModes.swift", ".fill(accent)", "Swipe's 1pt divider"),
        ("SetupArtwork.swift", ".fill(AnyShapeStyle(accent))", "the Edit tour page's 7pt heading rule"),
        ("SetupArtwork.swift", ".fill(AnyShapeStyle(accent))", "the Edit tour page's 2pt caret"),
    ]

    /// A use of the system accent (rules 3 and 4) that is right, named with why. Each must match
    /// exactly one finding, so a stale entry fails too.
    ///
    /// The None hue reads AppKit's `controlAccentColor`, not SwiftUI's `Color.accentColor`: the
    /// latter resolves to the environment's accent, which a root's `nativeControlAccent` (rule 6)
    /// sets to the window's hue, so the None swatch would draw the window's hue.
    static let systemAccentExemptions: [(file: String, fragment: String, why: String)] = [
        ("LiquidGlassStyle.swift", "return Color(nsColor: .controlAccentColor)",
         "the None hue means \"the Mac's accent\" — it is the one place the app asks for it"),
    ]

    /// A raw-accent `.tint` over a subtree (rule 7) that is right, named with why: it colours glyphs
    /// or a selection on purpose, and nothing under it reads the tint as a fill. A spinner takes no
    /// tint, and a `Toggle` in a context menu is an AppKit menu item. Matched by the call the tint
    /// hangs off and the start of its arguments; each must match exactly one site.
    static let rawTintExemptions: [(file: String, site: String, why: String)] = [
        ("FileTreeView.swift", "List(selection: $selection)",
         "Tree's disclosure chevrons — its rows hold a spinner, and its empty-area menu's toggles are menu items"),
        ("PaneColumnsView.swift", "List(selection: columnSelection(",
         "Columns' chevrons — the same rows, spinner and menu item as Tree"),
        ("DifferencesView.swift", "Table(session.queue",
         "the review table's chrome and selection — its cells are words and glyphs"),
        ("DifferencesView.swift", "Table(of: FileDifference.self",
         "the differences table's sort chevrons — its cells and section headers are words and glyphs"),
    ]

    /// Every filled control in the app carries its label at AA, in the app's accent: rules 1–5 and
    /// 7 over every shipping source. Exempt from rule 1: the marks above and nothing else, since a
    /// fill whose label flips to dark ink on light hues is a second button family, not a fix.
    /// Exempt from rules 3 and 4: `systemAccentExemptions`.
    @Test func theAppFillsWithTheDeepenedAccent() throws {
        var findings: [String] = []
        var exempted: [String: Int] = [:]
        var prominent = 0
        for file in try Self.appSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            prominent += Self.occurrences(of: Self.prominent, in: Array(Self.stripComments(source))).count
            for finding in Self.findings(in: source) {
                let name = file.lastPathComponent
                if finding.rule == "raw accent fill",
                   let mark = Self.markExemptions.first(where: { $0.file == name && finding.snippet.hasPrefix($0.fill) }) {
                    exempted["\(mark.file) \(mark.fill)", default: 0] += 1
                    continue
                }
                if finding.rule == "system accent" || finding.rule == "controlAccentColor",
                   let use = Self.systemAccentExemptions.first(where: { $0.file == name && finding.snippet.contains($0.fragment) }) {
                    exempted["\(use.file) \(use.fragment)", default: 0] += 1
                    continue
                }
                if finding.rule == "raw accent tint over a subtree",
                   let tint = Self.rawTintExemptions.first(where: { $0.file == name && finding.snippet.hasPrefix($0.site) }) {
                    exempted["tint \(tint.file) \(tint.site)", default: 0] += 1
                    continue
                }
                findings.append("\(name) — \(finding)")
            }
        }
        #expect(findings.isEmpty, """
            A control fills with the RAW accent, paints the system's, or tints a prominent button past \
            `accentedProminent`. A white label on the raw accent is 2.7:1 on Green; fill with \
            `LiquidGlassHue.accentFillColor`, tint prominent buttons with `.accentedProminent(…)`, and \
            keep the raw accent for washes, hairlines and words. `Color.accentColor` is the SYSTEM \
            accent, and so is a `.tint` nothing set: take the window's hue, or default to \
            `LiquidGlassHue.stored()`:
            \(findings.joined(separator: "\n"))
            """)
        for mark in Self.markExemptions {
            let count = exempted["\(mark.file) \(mark.fill)", default: 0]
            let listed = Self.markExemptions.filter { $0.file == mark.file && $0.fill == mark.fill }.count
            #expect(count == listed, "the exemption for \(mark.why) (\(mark.file)) matched \(count) fills, not \(listed)")
        }
        for use in Self.systemAccentExemptions {
            let count = exempted["\(use.file) \(use.fragment)", default: 0]
            #expect(count == 1, "the exemption for \(use.why) (\(use.file)) matched \(count) uses, not 1")
        }
        for tint in Self.rawTintExemptions {
            let count = exempted["tint \(tint.file) \(tint.site)", default: 0]
            #expect(count == 1, "the exemption for \(tint.why) (\(tint.file)) matched \(count) tints, not 1")
        }
        // A tripwire, so the scan can't pass on files that no longer hold the buttons.
        #expect(prominent >= 30, "expected at least 30 .borderedProminent buttons in the app, found \(prominent)")
    }

    // MARK: Rule 6 — every root sets the native controls' accent (DS4)

    static let rootAccent = ".nativeControlAccent("
    static let presentedAccent = ".presentedNativeControlAccent("

    /// The presentations whose content is a window of its own, which the root's accent does not
    /// reach (measured in `NativeControlAccentRenderTests.aControlInASheetTakesThePresentersHue`).
    static let presentations = [".sheet(", ".popover(", ".fullScreenCover(", ".inspector("]

    /// The roots in `source` that set no native-control accent: each scene's content closure, and
    /// each hosting view's `rootView:` argument. Returned as the opening text, to name the site.
    static func unaccentedRoots(in source: String) -> [String] {
        let text = Array(stripComments(source))
        var found: [String] = []
        // A scene: `Window("…", id: …) { … }` or `WindowGroup(…) { … }` — the closure is the root.
        for opener in ["Window(", "WindowGroup(", "WindowGroup {"] {
            for start in occurrences(of: opener, in: text) {
                if start > 0, text[start - 1].isLetter || text[start - 1].isNumber || text[start - 1] == "_" || text[start - 1] == "." { continue }
                var i = start + opener.count - 1
                if text[i] == "(" {
                    guard let close = matching(text, i) else { continue }
                    i = close + 1
                }
                while i < text.count, text[i] == " " { i += 1 }
                guard i < text.count, text[i] == "{", let end = matching(text, i) else { continue }
                if occurrences(of: rootAccent, in: Array(text[i...end])).isEmpty {
                    found.append(String(text[start..<min(text.count, start + 50)]))
                }
            }
        }
        // A presentation: the accent stops at it, so its content closure is a root of its own.
        // `.sheet(.compress)`, an enum case with no closure after it, is not one.
        for opener in presentations {
            for start in occurrences(of: opener, in: text) {
                let open = start + opener.count - 1
                guard let close = matching(text, open) else { continue }
                var i = close + 1
                while i < text.count, text[i] == " " { i += 1 }
                let body: [Character]
                if i < text.count, text[i] == "{", let end = matching(text, i) {
                    body = Array(text[i...end])
                } else if let label = occurrences(of: "content: {", in: Array(text[open...close])).first {
                    body = Array(text[(open + label)...close])
                } else {
                    continue
                }
                if occurrences(of: rootAccent, in: body).isEmpty, occurrences(of: presentedAccent, in: body).isEmpty {
                    found.append(String(text[start..<min(text.count, start + 50)]))
                }
            }
        }
        // A hosting view the app builds: its `rootView:` argument is the root.
        for opener in ["NSHostingView(rootView:", "NSHostingController(rootView:"] {
            for start in occurrences(of: opener, in: text) {
                let open = start + opener.firstIndex(of: "(")!.utf16Offset(in: opener)
                guard let close = matching(text, open) else { continue }
                if occurrences(of: rootAccent, in: Array(text[open...close])).isEmpty {
                    found.append(String(text[start..<min(text.count, start + 50)]))
                }
            }
        }
        return found
    }

    /// A root that rightly sets no accent, named with why: it hosts nothing a person operates.
    /// Each must match exactly one root, so a stale entry fails too.
    static let unaccentedHosts: [(file: String, root: String, why: String)] = [
        ("DocumentPDF.swift", "NSHostingView(rootView: root)", "a document laid out for printing — no controls"),
        ("PaneColumnsView.swift", "NSHostingView(rootView: VStack", "column rows measured offscreen, never shown"),
        ("ProbeRig.swift", "NSHostingView(rootView: root)", "the test-only render rig, which paints what each test hands it"),
        ("OffscreenRender.swift", "NSHostingView(rootView: view)", "the test-only bitmap rig, which paints what each test hands it"),
    ]

    /// A presentation that rightly sets no accent, named with why: nothing in it fills with one.
    /// Each must match exactly one presentation, so a stale entry fails too.
    static let unaccentedPresentations: [(file: String, site: String, why: String)] = [
        ("PreviewEditToggle.swift", ".popover(isPresented: $showsIntro",
         "editable Preview's first-use note — words and a plain Got It button"),
        ("EditorFormatBar.swift", ".popover(isPresented: $showsStyles",
         "the paragraph styles list — plain buttons, its tick drawn in the accent it is handed"),
    ]

    /// The panels the owner named, which sit inside the main window but set their own accent so
    /// that a render of one, or a host that ever shows it elsewhere, still carries the hue.
    static let accentedPanels = ["SettingsView.swift", "HelpBook.swift", "SetupSheet.swift"]

    @Test func rule6CatchesAnUnaccentedRootAndPassesAnAccentedOne() {
        #expect(Self.unaccentedRoots(in: "Window(\"Log\", id: \"log\") { LogViewer().appFontSizeFromSettings() }").count == 1)
        #expect(Self.unaccentedRoots(in: "WindowGroup { ContentView() }").count == 1)
        #expect(Self.unaccentedRoots(in: "WindowGroup(id: \"w\") { ContentView().nativeControlAccent() }").isEmpty)
        #expect(Self.unaccentedRoots(in: "Window(\"Log\", id: \"log\") { LogViewer().nativeControlAccent() }").isEmpty)
        #expect(Self.unaccentedRoots(in: "panel.contentView = NSHostingView(rootView: AnyView(content))").count == 1)
        #expect(Self.unaccentedRoots(in: "panel.contentView = NSHostingView(rootView: AnyView(content.nativeControlAccent()))").isEmpty)
        #expect(Self.unaccentedRoots(in: "let c = NSHostingController(rootView: Sheet())").count == 1)
        #expect(Self.unaccentedRoots(in: "// Window(\"x\", id: \"y\") { Bare() }").isEmpty)
        #expect(Self.unaccentedRoots(in: "NSWindow(contentRect: r, styleMask: [], backing: .buffered, defer: false)").isEmpty)
        // A presentation, broken: each kind, a closure over several lines, a `content:` argument.
        #expect(Self.unaccentedRoots(in: ".sheet(item: $planning) { finding in planSheet(for: finding) }").count == 1)
        #expect(Self.unaccentedRoots(in: ".sheet(isPresented: $x, onDismiss: done) {\n  Spend()\n}").count == 1)
        #expect(Self.unaccentedRoots(in: "Color.clear.popover(isPresented: $open, arrowEdge: .bottom) { Panel() }").count == 1)
        #expect(Self.unaccentedRoots(in: ".fullScreenCover(isPresented: $x) { Cover() }").count == 1)
        #expect(Self.unaccentedRoots(in: ".inspector(isPresented: $x) { Form { Toggle(\"a\", isOn: $a) } }").count == 1)
        #expect(Self.unaccentedRoots(in: ".sheet(isPresented: $x, content: { Spend() })").count == 1)
        // ...and kept: the helper, a hue in scope, an enum case named `sheet`, a comment.
        #expect(Self.unaccentedRoots(in: ".sheet(item: $planning) { finding in planSheet(for: finding).presentedNativeControlAccent() }").isEmpty)
        #expect(Self.unaccentedRoots(in: ".popover(isPresented: $open) {\n Panel()\n .presentedNativeControlAccent()\n}").isEmpty)
        #expect(Self.unaccentedRoots(in: ".sheet(isPresented: $x) { Spend().nativeControlAccent(hue) }").isEmpty)
        #expect(Self.unaccentedRoots(in: ".sheet(isPresented: $x, content: { Spend().presentedNativeControlAccent() })").isEmpty)
        #expect(Self.unaccentedRoots(in: "out.append(.init(title: \"Compress…\", action: .sheet(.compress), dividerBefore: true))").isEmpty)
        #expect(Self.unaccentedRoots(in: "case .sheet(let sheet): open(sheet)").isEmpty)
        #expect(Self.unaccentedRoots(in: "// .sheet(isPresented: $x) { Bare() }").isEmpty)
    }

    /// Every root in the app sets the native controls' accent, less the named hosts, and the
    /// owner's three panels set their own.
    @Test func everyRootSetsTheNativeControlsAccent() throws {
        var findings: [String] = []
        var exempted: [String: Int] = [:]
        var roots = 0
        var panels: Set<String> = []
        var presented = 0
        for file in try Self.appSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            let stripped = Array(Self.stripComments(source))
            roots += ["Window(\"", "NSHostingView(rootView:", "NSHostingController(rootView:"]
                .map { Self.occurrences(of: $0, in: stripped).count }.reduce(0, +)
            presented += Self.occurrences(of: Self.presentedAccent, in: stripped).count
            if Self.accentedPanels.contains(name), !Self.occurrences(of: Self.rootAccent, in: stripped).isEmpty {
                panels.insert(name)
            }
            for root in Self.unaccentedRoots(in: source) {
                if let host = Self.unaccentedHosts.first(where: { $0.file == name && root.hasPrefix($0.root) }) {
                    exempted["\(host.file) \(host.root)", default: 0] += 1
                    continue
                }
                if let shown = Self.unaccentedPresentations.first(where: { $0.file == name && root.hasPrefix($0.site) }) {
                    exempted["\(shown.file) \(shown.site)", default: 0] += 1
                    continue
                }
                findings.append("\(name) — \(root)")
            }
        }
        #expect(findings.isEmpty, """
            A window, hosted view, sheet or popover sets no native-control accent, so its switches, \
            sliders, checkboxes and progress bars fill with the Mac's accent rather than the app's \
            hue. Add `.nativeControlAccent()` at a window's root, and \
            `.presentedNativeControlAccent()` to a presentation's content (DS4):
            \(findings.joined(separator: "\n"))
            """)
        for host in Self.unaccentedHosts {
            #expect(exempted["\(host.file) \(host.root)"] == 1, "the exemption for \(host.why) (\(host.file)) matched \(exempted["\(host.file) \(host.root)"] ?? 0) roots, not 1")
        }
        for shown in Self.unaccentedPresentations {
            #expect(exempted["\(shown.file) \(shown.site)"] == 1, "the exemption for \(shown.why) (\(shown.file)) matched \(exempted["\(shown.file) \(shown.site)"] ?? 0) presentations, not 1")
        }
        #expect(panels == Set(Self.accentedPanels), "panels setting no accent of their own: \(Set(Self.accentedPanels).subtracting(panels).sorted())")
        // A tripwire, so the scan can't pass without reading MacApp's scenes and hosting views.
        #expect(roots >= 6, "only \(roots) window and hosting roots found — is the scan reading MacApp?")
        // ...and the modules' presentations that carry the hue.
        #expect(presented >= 14, "only \(presented) presentations carry the hue — is the scan reading the modules?")
    }

    /// Every Swift file the shipping app is built from: each module's `Sources`, plus `MacApp`.
    static func appSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let modules = repo.appendingPathComponent("Modules")
        let roots = [repo.appendingPathComponent("MacApp")]
            + (try FileManager.default.contentsOfDirectory(at: modules, includingPropertiesForKeys: nil))
                .map { $0.appendingPathComponent("Sources") }
        let files = roots.flatMap { root in
            (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" }
        }
        #expect(files.count > 300, "found only \(files.count) app sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("MacApp/SyncCloudApp.swift") }, "MacApp is not being scanned")
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
