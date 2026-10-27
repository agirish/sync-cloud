import Foundation
import Testing

/// **No word drawn in a colour on a wash of that same colour (DS1).**
///
/// `Pill`, `StatusBadge`, `TokenChipsRow` and the size tiles take their words' ink from
/// `PillVariant.labelInk(for:)`, which `PillLabelInkTests` measures. A hand-built pill does not:
/// it writes `.foregroundStyle(tint)` and `.background(Capsule().fill(tint.opacity(…)))` itself,
/// and a dozen did — the duplicates card's reclaim pill, Person's "N to review", the review
/// card's delta, Compare's "Keeping this". This scan is what keeps a new one from arriving.
///
/// The rule, per view: a `Text`, `Label`, `HStack`, `VStack`, `ZStack` or `Group` whose modifier
/// chain washes it with a colour — `.background`/`.fill` of that colour turned down with
/// `.opacity(…)` (either arm of a ternary), `.pillSurface(…, tint:)`, or a `.modifier(…Surface(…,
/// tint:))` — and which is inked with that same colour (`.foregroundStyle`, `.foregroundColor`), by
/// its own chain or on a `Text` or `Label` inside it, is a coloured word on its own wash. So is an
/// `AttributedString` run given the same colour as its `foregroundColor` and, washed, as its
/// `backgroundColor`. Label colours (`.primary`, `.secondary`, `.tertiary`) and
/// `PillVariant.labelInk` are the fix and never match. An `Image` root is not scanned: a glyph tile
/// (Person's group headers, the strip buttons) carries no words.
///
/// **The first version read only one modifier chain**, and five fixed components could be
/// reverted under it with the scan green: StatusBadge (ink on the child `Text`), the size tiles (a
/// `VStack` root), StatPill (the wash inside `StatPillSurface`), the differences header's review
/// pill (ink on the child, `.pillSurface` on the parent) and the risky-name marker (an
/// `AttributedString` run). Three live chips were invisible to it the same way (RB1, RB2).
@Suite struct PillLabelInkScanTests {

    typealias Scan = AccentFillScanTests

    /// A name that can be a colour: a hue, a tint, an accent, a semantic colour. Booleans and
    /// view names in the same chain (`isActive`, `Capsule`) never are.
    static let colourName = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*"#)

    static func isColourName(_ name: String) -> Bool {
        // The label colours — `onAccent` is the label on an accent FILL, white by construction —
        // the type's own name (`Color(red:…)` is a literal, not a variable) and the shared rule are
        // never "the same colour as the wash".
        let notAColourName: Set<String> = ["Color.primary", "Color.secondary", "Color.clear", "Color.white",
                                           "Color.black", "primary", "secondary", "tertiary", "quaternary",
                                           "Color", "AnyShapeStyle", "onAccent", "onTint"]
        guard !notAColourName.contains(name), !name.hasPrefix("PillVariant") else { return false }
        let lower = name.lowercased()
        return lower.contains("accent") || lower.contains("tint") || lower.contains("hue")
            || lower.contains("color") || lower.hasPrefix("semanticcolor.")
    }

    static func names(in argument: String) -> Set<String> {
        let ns = argument as NSString
        return Set(colourName.matches(in: argument, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter(isColourName))
    }

    /// The modifiers that turn a colour into a wash.
    static let washCalls = [".opacity(", ".withAlphaComponent("]

    /// The colours `argument` turns down to a wash: the receiver of each `.opacity(…)` — a dotted
    /// name (`SemanticColor.error.opacity`), or a bracketed one, every arm of it
    /// (`(empty ? Color.primary : accent).opacity`). `on ? accent.opacity(0.14) : Color.primary
    /// .opacity(0.06)` washes with `accent`, whichever arm is last.
    static func washedNames(in argument: [Character]) -> Set<String> {
        let partners = Scan.openers(argument)
        var found: Set<String> = []
        for call in washCalls {
            for start in Scan.occurrences(of: call, in: argument) where start > 0 {
                // The receiver ends at the last non-blank before the call: a chain written one
                // modifier to a line puts a newline and an indent there, which read as a receiver
                // with no name and an inverted range.
                var end = start - 1
                while end >= 0, argument[end].isWhitespace { end -= 1 }
                guard end >= 0 else { continue }
                if argument[end] == ")", let open = partners[end] {
                    found.formUnion(names(in: String(argument[(open + 1)..<end])))
                } else {
                    var i = end
                    while i >= 0, argument[i].isLetter || argument[i].isNumber || argument[i] == "_"
                            || argument[i] == "." || argument[i] == "?" || argument[i] == "!" { i -= 1 }
                    guard i < end else { continue }
                    found.formUnion(names(in: String(argument[(i + 1)...end])))
                }
            }
        }
        return found
    }

    /// The colours a modifier washes the view with: in a `.background`/`.fill`, what it turns down
    /// with `.opacity(…)`; in a `.pillSurface`, or a `.modifier(…Surface(…))` that draws one, its
    /// `tint:`.
    static func washes(_ name: String, _ argument: [Character]) -> Set<String> {
        func tint(_ argument: String) -> Set<String> {
            guard let tint = argument.range(of: "tint:") else { return [] }
            let rest = argument[tint.upperBound...].prefix { $0 != "," && $0 != ")" }
            return names(in: String(rest))
        }
        switch name {
        case "background", "fill":
            return washedNames(in: argument)
        case "pillSurface":
            return tint(String(argument))
        case "modifier":
            let text = String(argument)
            return text.contains("Surface(") ? tint(text) : []
        default:
            return []
        }
    }

    /// The inks a view is given.
    static let inkModifiers: Set<String> = ["foregroundStyle", "foregroundColor"]

    /// `AccentFillScanTests.chain`, but a trailing closure is read as part of its modifier's
    /// argument — a wash is as often `.background { Capsule().fill(tint.opacity(…)) }` as
    /// `.background(…)`.
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
            if i < text.count, text[i] == "(", let close = Scan.matching(text, i) {
                argument = Array(text[(i + 1)..<close])
                i = close + 1
            }
            skipSpace()
            if i < text.count, text[i] == "{", let close = Scan.matching(text, i) {
                argument += Array(text[(i + 1)..<close])
                i = close + 1
            }
            modifiers.append((name, argument))
        }
        return modifiers
    }

    /// An ink argument with the readable inks taken out: `PillVariant.labelInk(for: tint)` names
    /// the tint and is the fix, and `ChromeInk.bodyText(…)` is a coloured sentence's deepened ink,
    /// which the owner's call leaves as it is.
    static func withoutReadableInks(_ argument: [Character]) -> String {
        var out = argument
        for call in ["PillVariant.labelInk(", "ChromeInk.bodyText("] {
            while let start = Scan.occurrences(of: call, in: out).first,
                  let close = Scan.matching(out, start + call.count - 1) {
                out.replaceSubrange(start...close, with: Array("readableInk"))
            }
        }
        return String(out)
    }

    /// The colours a view's own chain inks it with.
    static func inks(_ chain: [(name: String, argument: [Character])]) -> Set<String> {
        chain.filter { inkModifiers.contains($0.name) }
            .reduce(into: Set<String>()) { $0.formUnion(names(in: withoutReadableInks($1.argument))) }
    }

    /// The colours the WORDS inside `body` are inked with — each `Text` and `Label` in it, by its
    /// own chain. A glyph inside a washed card (a lens card's accent icon) is not a word, and is
    /// left alone.
    static func wordInks(in body: [Character]) -> Set<String> {
        var found: Set<String> = []
        for word in ["Text(", "Label("] {
            for start in Scan.occurrences(of: word, in: body) {
                if start > 0, body[start - 1].isLetter || body[start - 1].isNumber || body[start - 1] == "_"
                    || body[start - 1] == "." { continue }
                guard let close = Scan.matching(body, start + word.count - 1) else { continue }
                var i = close + 1
                while i < body.count, body[i] == " " { i += 1 }
                if i < body.count, body[i] == "{", let end = Scan.matching(body, i) { i = end + 1 }
                found.formUnion(inks(chain(body, after: i)))
            }
        }
        return found
    }

    /// A coloured word on its own wash that is right, named with why. Each must match exactly one
    /// finding, so a stale entry fails too. Empty since RB2: the format bar's lit button, the one
    /// entry, measured 2.3:1 (Green) and 1.9:1 (Amber) and now draws label-colour words.
    static let exemptions: [(file: String, root: String, why: String)] = []

    static let roots = ["Text(", "Label(", "HStack(", "HStack {", "VStack(", "VStack {",
                        "ZStack(", "ZStack {", "Group {", "Group("]

    static func findings(in source: String) -> [String] {
        let text = Array(Scan.stripComments(source))
        var found: [String] = []
        for root in roots {
            for start in Scan.occurrences(of: root, in: text) {
                // A root, not the tail of another name (`RichText(`, `MyHStack(`, `.Group(`).
                if start > 0, text[start - 1].isLetter || text[start - 1].isNumber || text[start - 1] == "_"
                    || text[start - 1] == "." { continue }
                var i = start + root.count - 1
                if text[i] == "(" {
                    guard let close = Scan.matching(text, i) else { continue }
                    i = close + 1
                }
                while i < text.count, text[i] == " " { i += 1 }
                var body: [Character] = []
                if i < text.count, text[i] == "{", let close = Scan.matching(text, i) {
                    body = Array(text[(i + 1)..<close])
                    i = close + 1
                }
                let chain = Self.chain(text, after: i)
                let washed = chain.reduce(into: Set<String>()) { $0.formUnion(washes($1.name, $1.argument)) }
                guard !washed.isEmpty else { continue }
                // Its own ink, and its words': a child `Text` inked in the colour of the parent's
                // wash is the same word on the same wash.
                let inks = Self.inks(chain).union(Self.wordInks(in: body))
                let both = inks.intersection(washed)
                if !both.isEmpty {
                    found.append("\(String(text[start..<min(text.count, start + 60)])) — inked and washed in \(both.sorted())")
                }
            }
        }
        found += attributedRuns(in: String(text))
        return found
    }

    /// An `AttributedString` run whose `foregroundColor` and washed `backgroundColor` are one
    /// colour: `piece.foregroundColor = SemanticColor.error` beside `piece.backgroundColor =
    /// SemanticColor.error.opacity(…)`. Matched per variable, anywhere in the file.
    static let runAssignment = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)\.(foregroundColor|backgroundColor) = ([A-Za-z_][A-Za-z0-9_.]*)"#)

    static func attributedRuns(in text: String) -> [String] {
        let ns = text as NSString
        var ink: [String: Set<String>] = [:]
        var wash: [String: Set<String>] = [:]
        for match in runAssignment.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let variable = ns.substring(with: match.range(at: 1))
            var value = ns.substring(with: match.range(at: 3))
            if ns.substring(with: match.range(at: 2)) == "foregroundColor" {
                ink[variable, default: []].formUnion(names(in: value))
            } else {
                // Only a washed colour: `X.opacity(` after the name.
                let after = ns.substring(from: match.range(at: 3).upperBound)
                for call in ["opacity", "withAlphaComponent"] where value.hasSuffix(".\(call)") {
                    value.removeLast(call.count + 1)
                    if after.hasPrefix("(") { wash[variable, default: []].formUnion(names(in: value)) }
                }
            }
        }
        return ink.keys.sorted().compactMap { variable in
            let both = ink[variable, default: []].intersection(wash[variable, default: []])
            return both.isEmpty ? nil : "\(variable).foregroundColor — an AttributedString run inked and washed in \(both.sorted())"
        }
    }

    /// Broken once and kept once per shape, so a matcher that stopped matching cannot pass the
    /// real scan on a tree that has the bug. The broken shapes are the real ones: each of the five
    /// components the first version could not see, and the three chips it missed in the app.
    @Test func theScanCatchesAColouredWordOnItsOwnWash() {
        func count(_ source: String) -> Int { Self.findings(in: source).count }
        // Broken, the first version's shapes: the reclaim pill, Person's capsule, the NEW tag
        // (wash first), a ternary ink, an HStack pill, a Label chip.
        #expect(count("Text(f).scaledFont(x).foregroundStyle(SemanticColor.success).pillSurface(.mini, tint: SemanticColor.success)") == 1)
        #expect(count("Text(\"\\(n) to review\").foregroundStyle(SemanticColor.warning)\n.padding(.horizontal, 7)\n.background(Capsule().fill(SemanticColor.warning.opacity(0.14)))") == 1)
        #expect(count("Text(\"NEW\").padding(4).background(Capsule().fill(hueAccent.opacity(PillVariant.fillOpacity))).foregroundStyle(hueAccent)") == 1)
        #expect(count("HStack { Image(systemName: \"a\"); Text(t) }.foregroundStyle(template.isEmpty ? Color.secondary : accent).background(Capsule().fill((template.isEmpty ? Color.primary : accent).opacity(0.14)))") == 1)
        #expect(count("HStack(spacing: 6) { Circle(); Text(r) }.foregroundStyle(glassHue.accentColor).pillSurface(.standard, tint: glassHue.accentColor)") == 1)
        #expect(count("Label(\"Keeping this\", systemImage: \"c\").foregroundStyle(accent).background { Capsule().fill(accent.opacity(0.13)) }") == 1)
        // Broken, the five components reverted: StatusBadge (ink on the child), the size tile (a
        // VStack root inside a Button label), StatPill (the wash in a Surface modifier), the
        // review pill (ink on the child, the surface on the parent), the risky-name run.
        #expect(count("HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6)\n Text(isValid ? \"Valid path\" : \"Invalid path\").scaledFont(x).foregroundStyle(color) }.padding(.horizontal, 10).background(color.opacity(PillVariant.fillOpacity)).clipShape(Capsule())") == 1)
        #expect(count("Button { go() } label: { VStack(spacing: 3) { Text(p).foregroundStyle(isSelected ? accent : Color.secondary) }.lineLimit(1).foregroundStyle(isSelected ? accent : Color.primary).background { if isSelected { SelectionLensTodayMarker { RoundedRectangle(cornerRadius: 4).fill(accent.opacity(Self.selectedWash)) } } } }") == 1)
        #expect(count("HStack(spacing: 5) { Text(count.formatted()); Text(label) }.foregroundStyle(semantic?.content ?? color).modifier(StatPillSurface(semantic: semantic, tint: color)).fixedSize()") == 1)
        #expect(count("HStack(spacing: 6) { Circle().fill(glassHue.accentColor).frame(width: 7, height: 7)\n Text(\"Reviewing\").monospacedDigit().foregroundStyle(glassHue.accentColor) }.pillSurface(.standard, tint: glassHue.accentColor)") == 1)
        #expect(count("var piece = AttributedString(cell.glyph)\nif cell.isMarker {\n piece.foregroundColor = SemanticColor.error\n piece.backgroundColor = SemanticColor.error.opacity(PillVariant.fillOpacity)\n}") == 1)
        // Broken, the three live chips: a ternary wash whose last `.opacity` is the other arm, an
        // ink on the child of a washed HStack, a Group root, and `.foregroundColor`.
        #expect(count("Text(variant.chipLabel).padding(.horizontal, 8).background(Capsule().fill(on ? accent.opacity(0.14) : Color.primary.opacity(0.06))).foregroundStyle(on ? accent : Color.secondary)") == 1)
        #expect(count("HStack(spacing: 4) { Text(\"\\(index + 1)\").foregroundStyle(isCurrent ? accent : Color.secondary) }.padding(.horizontal, 7).background { Capsule().fill(isCurrent ? accent.opacity(0.14) : Color.clear) }") == 1)
        #expect(count("Group { if worded { HStack { Text(t) } } else { Image(systemName: s) } }.foregroundStyle(railIsHidden ? accent : .primary).background(Capsule().fill(railIsHidden ? accent.opacity(0.18) : .clear))") == 1)
        #expect(count("ZStack { Text(t).foregroundColor(tint) }.background(tint.opacity(0.2))") == 1)
        // A wash written one modifier to a line: the newline before `.opacity(` is not the receiver.
        #expect(count("Text(t).foregroundStyle(tint)\n.background(tint\n    .opacity(0.2))") == 1)
        // …and a hidden button in a `.background { }` — an `.opacity(0)` after a call on its own line,
        // which crashed the scan's process (2026-10-27) — is no word on a wash.
        #expect(count("VStack { Text(t) }\n.background {\n    Button(\"\", action: stop)\n        .keyboardShortcut(k)\n        .opacity(0)\n}") == 0)
        // Kept: label ink, the shared rule, a different colour, a glyph tile, a wash with no word,
        // a dot in the colour beside label-colour words, a glyph in the colour inside a washed card,
        // a deepened sentence, a run washed only.
        #expect(count("Text(f).foregroundStyle(.primary).pillSurface(.mini, tint: SemanticColor.success)") == 0)
        #expect(count("Text(f).foregroundStyle(PillVariant.labelInk(for: tint)).pillSurface(.mini, tint: tint)") == 0)
        #expect(count("Text(f).foregroundStyle(accent).background(Capsule().fill(SemanticColor.error.opacity(0.1)))") == 0)
        #expect(count("Image(systemName: s).foregroundStyle(hue).background(RoundedRectangle(cornerRadius: 4).fill(hue.opacity(0.14)))") == 0)
        #expect(count("Text(t).foregroundStyle(.secondary).pillSurface(.mini, tint: .secondary)") == 0)
        #expect(count("RichText(t).foregroundStyle(tint).background(tint.opacity(0.2))") == 0)
        #expect(count("Text(t).foregroundStyle(ChromeInk.bodyText(scheme, SemanticColor.caution)).background(Capsule().fill(SemanticColor.caution.opacity(0.16)))") == 0)
        #expect(count("HStack(spacing: 5) { Circle().fill(color); Text(t).foregroundStyle(PillVariant.labelInk(for: color)) }.background(color.opacity(PillVariant.fillOpacity))") == 0)
        #expect(count("HStack(spacing: 4) { Text(n).foregroundStyle(isCurrent ? Color.primary : Color.secondary) }.background { Capsule().fill(isCurrent ? accent.opacity(0.14) : Color.clear) }") == 0)
        #expect(count("HStack { Text(t) }.foregroundStyle(semantic?.content ?? PillVariant.labelInk(for: color)).modifier(StatPillSurface(semantic: semantic, tint: color))") == 0)
        #expect(count("HStack { Text(t).foregroundStyle(accent) }.modifier(DetailRunCapsule(style: s, ring: accent))") == 0)
        #expect(count("HStack { Image(systemName: \"eye\").foregroundStyle(accent); Text(t).foregroundStyle(.secondary) }.padding(10).background(accent.opacity(0.06))") == 0)
        #expect(count("piece.backgroundColor = SemanticColor.error.opacity(PillVariant.fillOpacity)") == 0)
        #expect(count("piece.foregroundColor = SemanticColor.error\nother.backgroundColor = SemanticColor.error.opacity(0.2)") == 0)
    }

    /// **Every shipping source**, less the named exemptions.
    @Test func noWordInTheAppIsInkedInItsOwnWash() throws {
        var findings: [String] = []
        var exempted: [String: Int] = [:]
        var pills = 0
        for file in try Scan.appSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for finding in Self.findings(in: source) {
                if let use = Self.exemptions.first(where: { $0.file == file.lastPathComponent && finding.hasPrefix($0.root) }) {
                    exempted["\(use.file) \(use.root)", default: 0] += 1
                    continue
                }
                findings.append("\(file.lastPathComponent) — \(finding)")
            }
            pills += Scan.occurrences(of: ".pillSurface(", in: Array(Scan.stripComments(source))).count
        }
        for use in Self.exemptions {
            #expect(exempted["\(use.file) \(use.root)"] == 1, "the exemption for \(use.why) matched \(exempted["\(use.file) \(use.root)"] ?? 0) views, not 1")
        }
        #expect(findings.isEmpty, """
            A word is drawn in a colour on a wash of that colour — 1.4:1 for yellow, about 1.9:1 for \
            green in light. Ink it with `.primary` (or `PillVariant.labelInk(for:)`) and keep the \
            colour in the wash (DS1):
            \(findings.joined(separator: "\n"))
            """)
        // A tripwire, so the scan cannot pass on files that no longer hold the pills.
        #expect(pills >= 8, "only \(pills) `.pillSurface(` calls in the app — is the scan reading the right files?")
    }
}
