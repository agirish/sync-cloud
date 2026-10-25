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
/// The rule, per view: a `Text`, `Label` or `HStack` whose own modifier chain both inks it with a
/// colour and washes it with that same colour (`.background`/`.fill` with `.opacity`, or
/// `.pillSurface(…, tint:)`) is a coloured word on its own wash. Label colours (`.primary`,
/// `.secondary`, `.tertiary`) and `PillVariant.labelInk` are the fix and never match. An `Image`
/// root is not scanned: a glyph tile (Person's group headers, the strip buttons) carries no
/// words.
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

    /// The colours a modifier washes the view with: in a `.background`/`.fill`, the names written
    /// before an `.opacity(`; in a `.pillSurface`, its `tint:`.
    static func washes(_ name: String, _ argument: String) -> Set<String> {
        switch name {
        case "background", "fill":
            guard let last = argument.range(of: ".opacity(", options: .backwards) else { return [] }
            return names(in: String(argument[..<last.lowerBound]))
        case "pillSurface":
            guard let tint = argument.range(of: "tint:") else { return [] }
            let rest = argument[tint.upperBound...].prefix { $0 != "," && $0 != ")" }
            return names(in: String(rest))
        default:
            return []
        }
    }

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

    /// A coloured word on its own wash that is right, named with why. Each must match exactly one
    /// finding, so a stale entry fails too.
    static let exemptions: [(file: String, root: String, why: String)] = [
        ("EditorFormatBar.swift", "HStack(spacing: word == nil ? 2 : 4)",
         "a lit format-bar BUTTON — the owner's call leaves buttons as they are"),
    ]

    static func findings(in source: String) -> [String] {
        let text = Array(Scan.stripComments(source))
        var found: [String] = []
        for root in ["Text(", "Label(", "HStack(", "HStack {"] {
            for start in Scan.occurrences(of: root, in: text) {
                // A root, not the tail of another name (`RichText(`, `MyHStack(`).
                if start > 0, text[start - 1].isLetter || text[start - 1].isNumber || text[start - 1] == "_" { continue }
                var i = start + root.count - 1
                if text[i] == "(" {
                    guard let close = Scan.matching(text, i) else { continue }
                    i = close + 1
                }
                while i < text.count, text[i] == " " { i += 1 }
                if i < text.count, text[i] == "{", let close = Scan.matching(text, i) { i = close + 1 }
                let chain = Self.chain(text, after: i)
                let inks = chain.filter { $0.name == "foregroundStyle" }
                    .reduce(into: Set<String>()) { $0.formUnion(names(in: Self.withoutReadableInks($1.argument))) }
                let washed = chain.reduce(into: Set<String>()) { $0.formUnion(washes($1.name, String($1.argument))) }
                let both = inks.intersection(washed)
                if !both.isEmpty {
                    found.append("\(String(text[start..<min(text.count, start + 60)])) — inked and washed in \(both.sorted())")
                }
            }
        }
        return found
    }

    /// Broken once and kept once per shape, so a matcher that stopped matching cannot pass the
    /// real scan on a tree that has the bug.
    @Test func theScanCatchesAColouredWordOnItsOwnWash() {
        // Broken: the reclaim pill, Person's capsule, the NEW tag (wash first), a ternary ink,
        // an HStack pill, a Label chip.
        #expect(Self.findings(in: "Text(f).scaledFont(x).foregroundStyle(SemanticColor.success).pillSurface(.mini, tint: SemanticColor.success)").count == 1)
        #expect(Self.findings(in: "Text(\"\\(n) to review\").foregroundStyle(SemanticColor.warning)\n.padding(.horizontal, 7)\n.background(Capsule().fill(SemanticColor.warning.opacity(0.14)))").count == 1)
        #expect(Self.findings(in: "Text(\"NEW\").padding(4).background(Capsule().fill(hueAccent.opacity(PillVariant.fillOpacity))).foregroundStyle(hueAccent)").count == 1)
        #expect(Self.findings(in: "HStack { Image(systemName: \"a\"); Text(t) }.foregroundStyle(template.isEmpty ? Color.secondary : accent).background(Capsule().fill((template.isEmpty ? Color.primary : accent).opacity(0.14)))").count == 1)
        #expect(Self.findings(in: "HStack(spacing: 6) { Circle(); Text(r) }.foregroundStyle(glassHue.accentColor).pillSurface(.standard, tint: glassHue.accentColor)").count == 1)
        #expect(Self.findings(in: "Label(\"Keeping this\", systemImage: \"c\").foregroundStyle(accent).background { Capsule().fill(accent.opacity(0.13)) }").count == 1)
        // Kept: label ink, the shared rule, a different colour, a glyph tile, a wash with no word.
        #expect(Self.findings(in: "Text(f).foregroundStyle(.primary).pillSurface(.mini, tint: SemanticColor.success)").isEmpty)
        #expect(Self.findings(in: "Text(f).foregroundStyle(PillVariant.labelInk(for: tint)).pillSurface(.mini, tint: tint)").isEmpty)
        #expect(Self.findings(in: "Text(f).foregroundStyle(accent).background(Capsule().fill(SemanticColor.error.opacity(0.1)))").isEmpty)
        #expect(Self.findings(in: "Image(systemName: s).foregroundStyle(hue).background(RoundedRectangle(cornerRadius: 4).fill(hue.opacity(0.14)))").isEmpty)
        #expect(Self.findings(in: "Text(t).foregroundStyle(.secondary).pillSurface(.mini, tint: .secondary)").isEmpty)
        #expect(Self.findings(in: "RichText(t).foregroundStyle(tint).background(tint.opacity(0.2))").isEmpty)
        #expect(Self.findings(in: "Text(t).foregroundStyle(ChromeInk.bodyText(scheme, SemanticColor.caution)).background(Capsule().fill(SemanticColor.caution.opacity(0.16)))").isEmpty)
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
