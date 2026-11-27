import Testing
@testable import Design

/// Type follows Settings ▸ Text size, and a raw `.font(...)` is the one way to opt out of it
/// without anything saying so: `.font(.system(size: 12))` or `.font(.caption)` draws at 100% at
/// every setting. `.scaledFont(...)` is the replacement, and on a `Text` run inside a `Text + Text`
/// concatenation, where a modifier can't attach, `Text.scaledFont(_:scale:)`.
///
/// A resolved font (`.font(font.resolved(scale: scale))`) is the scaled path and is not matched.
@Suite struct RawFontScanTests {

    /// A raw `Font` constructor or text style passed straight to `.font(`.
    /// Ends with a lookahead, not `\b`: Swift's `Regex` uses Unicode word boundaries, under which
    /// `caption.weight` is one word, so `\b` would miss `.font(.caption.weight(.semibold))`.
    static let pattern = #"\.font\(\.(system\(size:|(caption2?|callout|footnote|body|subheadline|headline|title[0-9]?|largeTitle)(?![A-Za-z0-9]))"#

    /// Fixed on purpose, each for a reason the call site carries. Keyed by file name, with how many
    /// raw fonts that file may hold, so a second one added beside an allowed one still fails.
    static let allowed: [String: (count: Int, why: String)] = [
        "ProgressCapsule.swift": (1, "the ring's glyph sits in a fixed ring inside the fixed 28pt capsule"),
        "ProgressCapsuleFlight.swift": (1, "the same glyph, flying to the ring it lands in"),
        "TextSizeStepper.swift": (2, "the control that sets the text size shows each size at its own size"),
        "VaultPanel.swift": (2, "Large Type is sized to the window, and shrinks to fit"),
    ]

    @Test func noSourceSetsTypeThatIgnoresTheTextSize() throws {
        let sources = try AccentFillScanTests.appSources()
        let raw = try Regex(Self.pattern)
        var found: [String: [String]] = [:]
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), try raw.firstMatch(in: String(line)) != nil else { continue }
                found[file.lastPathComponent, default: []].append(trimmed)
            }
        }
        var strays: [String] = []
        for (name, lines) in found.sorted(by: { $0.key < $1.key }) {
            let allowance = Self.allowed[name]?.count ?? 0
            if lines.count > allowance {
                strays.append("\(name) (\(lines.count), \(allowance) allowed): \(lines.first ?? "")")
            }
        }
        #expect(strays.isEmpty, """
                type that stays at 100% whatever Settings ▸ Text size says — use .scaledFont, \
                or Text.scaledFont(_:scale:) on a Text run:
                \(strays.joined(separator: "\n"))
                """)
        // Every allowance is still spent, so a fixed site that goes away takes its entry with it.
        for (name, entry) in Self.allowed {
            #expect(found[name]?.count == entry.count,
                    "\(name) is allowed \(entry.count) raw font(s) (\(entry.why)) but has \(found[name]?.count ?? 0)")
        }
    }

    /// The scan has to be able to fail, and must not fire on the scaled forms.
    @Test func thePatternTellsRawFromScaled() throws {
        let raw = try Regex(Self.pattern)
        for planted in [".font(.system(size: 12, weight: .medium))", "Text(x).font(.caption)",
                        ".font(.caption.weight(.semibold))", ".font(.callout)", ".font(.title2)"] {
            #expect(try raw.firstMatch(in: planted) != nil, "missed \(planted)")
        }
        for scaled in [".scaledFont(.system(size: 12))", ".scaledFont(.caption)",
                       ".font(font.resolved(scale: scale))", ".scaledFont(.callout.weight(.semibold))",
                       ".font(.custom(\"x\", size: 3))"] {
            #expect(try raw.firstMatch(in: scaled) == nil, "matched the scaled form \(scaled)")
        }
    }
}
