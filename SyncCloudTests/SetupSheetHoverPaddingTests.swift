import Foundation
import Testing
@testable import SyncCloud

/// The first-run sheet's hover affordances use the padding-compensation idiom: a control too small
/// to hold a wash is padded in inside the button's label, and the same amount is taken back out
/// with a negative padding on the button, so the wash has room while the row's footprint holds.
///
/// The promise rests on two numbers lines apart with a `buttonStyle` between them. Change one and
/// the row silently shifts, with the wash off the control.
///
/// Paired per button, not per file: the selected-hue ring's `.padding(-3)` expands an overlay and
/// is no compensation. A compensating padding is one that follows a `buttonStyle`.
@Suite struct SetupSheetHoverPaddingTests {

    /// One `buttonStyle` and the paddings on either side of it.
    struct Site {
        var line: Int
        /// `.padding(N)` between the enclosing `Button`/`label:` and the style — inside the label.
        var inside: [String: Int] = [:]
        /// `.padding(-N)` after the style — on the button itself.
        var outside: [String: Int] = [:]
    }

    /// Every source file the sheet is made of, as one stream of lines. The sheet is a directory;
    /// `SetupSheet.swift` alone is the host, with no affordance in it, so the file-count floor keeps
    /// the scan from passing on nothing.
    static func setupSheetSource() throws -> [String] {
        let repo = macAppDirectory().deletingLastPathComponent()
        let directory = repo.appendingPathComponent("MacApp/Setup")
        let files = try #require(try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil), "cannot read MacApp/Setup")
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            + [repo.appendingPathComponent("MacApp/SetupSheet.swift")]
        try #require(files.count >= 10, "the setup directory has \(files.count) files — this scan is looking at the wrong place")
        var lines: [String] = []
        for file in files {
            let text = try #require(try? String(contentsOf: file, encoding: .utf8),
                                    "cannot read \(file.lastPathComponent) — every check below would be vacuous")
            lines += text.components(separatedBy: .newlines)
            // A file boundary the backward scan cannot walk across: without it the last button of
            // one file would collect paddings from the next.
            lines.append("Button {")
        }
        return lines
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

        // Two: the accent swatch and a chip's remove glyph. The card's dismiss glyph and Change
        // link are a `CloseButton` and a plain button, which don't need the idiom.
        let compensated = all.filter { !$0.outside.isEmpty }
        #expect(compensated.count == 2, """
            expected 2 compensated controls (the accent swatch, a chip's remove glyph), \
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
        // Edit the inside half of a compensated control, as a careless tweak would. Found by
        // walking back from the button's own style: the first matching padding in the file may
        // belong to no site, and mutating it would prove nothing.
        let styleLine = try #require(lines.firstIndex {
            $0.contains(".buttonStyle(.hoverAffordance(.circular")
        }, "the accent swatch's button style moved — retarget this mutation")
        let target = try #require((0..<styleLine).reversed().first {
            lines[$0].trimmingCharacters(in: .whitespaces) == ".padding(3)"
        }, "the accent swatch's inside padding moved — retarget this mutation")
        lines[target] = lines[target].replacingOccurrences(of: ".padding(3)", with: ".padding(6)")

        let drifted = Self.sites(lines).filter { site in
            site.outside.contains { key, count in site.inside[key, default: 0] < count }
        }
        #expect(!drifted.isEmpty, "the scan cannot see a pair that no longer matches")
    }
}
