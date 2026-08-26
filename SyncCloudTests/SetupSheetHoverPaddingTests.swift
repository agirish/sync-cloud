import Foundation
import Testing
@testable import SyncCloud

/// The first-run sheet's hover affordances use the **padding-compensation idiom**: a control too
/// small to hold a wash is padded IN inside the button's label and the same amount is taken back
/// OUT with a negative padding on the button, so the wash has somewhere to land while the row's
/// resting footprint does not move.
///
/// **The idiom shipped at four sites with no test of any kind.** Its whole promise — "at rest the
/// row's footprint is byte-identical to before" — rests on two numbers agreeing, written eight
/// lines apart with a `buttonStyle` between them and nothing connecting them. Change one and the
/// row silently shifts by the difference: no build error, no failing assertion, and a wash that no
/// longer sits over the control. This is the pairing check `InlineSpinner` got — its footprint is
/// pinned against the recipe it replaced — and this idiom did not.
///
/// **Paired per button, not per file.** The first draft of this test counted negative paddings
/// across the whole source and immediately failed on the selected-hue ring, which is
/// `Circle().strokeBorder(…).padding(-3)` — a negative padding that expands an overlay beyond its
/// content and has nothing to do with compensation. Two different uses of the same spelling, so
/// locality is what distinguishes them: a compensating padding is one that follows a `buttonStyle`.
@Suite struct SetupSheetHoverPaddingTests {

    /// One `buttonStyle` and the paddings on either side of it.
    struct Site {
        var line: Int
        /// `.padding(N)` between the enclosing `Button`/`label:` and the style — inside the label.
        var inside: [String: Int] = [:]
        /// `.padding(-N)` after the style — on the button itself.
        var outside: [String: Int] = [:]
    }

    static func setupSheetSource() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()               // …/SyncCloudTests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("MacApp/SetupSheet.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read SetupSheet.swift — every check below would be vacuous")
        return text.components(separatedBy: .newlines)
    }

    /// `(edgeKey, magnitude, isNegative)` for a `.padding(…)` line, or nil if it is not one with a
    /// literal number — `.padding(LiquidGlass.cardInset)` and friends are not part of this idiom.
    static func padding(in rawLine: String) -> (key: String, negative: Bool)? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("//"), let open = line.range(of: ".padding(") else { return nil }
        var arg = String(line[open.upperBound...])
        guard let close = arg.firstIndex(of: ")") else { return nil }
        arg = String(arg[..<close])
        let parts = arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let value = Int(last) else { return nil }
        let edge = parts.count == 2 ? parts[0] : "all"
        return ("\(edge):\(abs(value))", value < 0)
    }

    /// Every `.buttonStyle(.hoverAffordance…)` in the file, with the paddings that bracket it.
    static func sites(_ lines: [String]) -> [Site] {
        var found: [Site] = []
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), line.contains(".buttonStyle(.hoverAffordance") else { continue }
            var site = Site(line: i + 1)

            // Forward: the compensating paddings sit immediately after the style, comments allowed.
            var j = i + 1
            while j < lines.count {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("//") || next.isEmpty { j += 1; continue }
                guard let p = padding(in: next) else { break }
                if p.negative { site.outside[p.key, default: 0] += 1 }
                j += 1
            }

            // Backward: paddings inside the label, up to the `Button` that opens it.
            var k = i - 1
            while k >= 0, i - k < 40 {
                let prev = lines[k].trimmingCharacters(in: .whitespaces)
                if prev.hasPrefix("Button ") || prev.hasPrefix("Button{") || prev.hasPrefix("Button {") { break }
                if let p = padding(in: prev), !p.negative { site.inside[p.key, default: 0] += 1 }
                k -= 1
            }
            found.append(site)
        }
        return found
    }

    @Test func everyCompensatedControlPairsItsTwoPaddings() throws {
        let lines = try Self.setupSheetSource()
        let all = Self.sites(lines)
        #expect(all.count >= 7, "expected the sheet's hover-affordance buttons, saw \(all.count)")

        let compensated = all.filter { !$0.outside.isEmpty }
        #expect(compensated.count == 4, """
            expected 4 compensated controls (hue swatch, Remove, Change, dismiss glyph), \
            saw \(compensated.count) at lines \(compensated.map(\.line))
            """)

        for site in compensated {
            for (key, count) in site.outside {
                #expect(site.inside[key, default: 0] >= count, """
                    the button at line \(site.line) takes back \(count) × .padding(-\(key)) but its \
                    label only adds \(site.inside[key, default: 0]) matching .padding(\(key)). The \
                    pair has drifted, so the row's resting footprint has moved by the difference.
                    """)
            }
        }
    }

    /// The scan must be able to SEE a broken pair, or the assertion above is decoration.
    @Test func theScanFindsADriftedPair() throws {
        var lines = try Self.setupSheetSource()
        // Edit the INSIDE half of a compensated control, exactly as a careless tweak would.
        //
        // Targeted by walking back from the button's OWN style, not by the first `.padding(4)` in
        // the file — the first draft did that, hit an unrelated one several hundred lines earlier,
        // mutated nothing that any site could see, and reported that the scan was blind when it
        // was the mutation that had missed.
        let styleLine = try #require(lines.firstIndex {
            $0.contains(".buttonStyle(.hoverAffordance") && $0.contains("shape: .circle")
        }, "the hue swatch's button style moved — retarget this mutation")
        let target = try #require((0..<styleLine).reversed().first {
            lines[$0].trimmingCharacters(in: .whitespaces) == ".padding(4)"
        }, "the hue swatch's inside padding moved — retarget this mutation")
        lines[target] = lines[target].replacingOccurrences(of: ".padding(4)", with: ".padding(6)")

        let drifted = Self.sites(lines).filter { site in
            site.outside.contains { key, count in site.inside[key, default: 0] < count }
        }
        #expect(!drifted.isEmpty, "the scan cannot see a pair that no longer matches")
    }
}
