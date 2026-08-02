import Testing
@testable import Sync

/// Pins the risky-name marking shared by the Rename lens's card and the kept-names list in
/// Settings ▸ Organize. Both exist for one job — making an invisible character visible before the
/// user decides what to do about it — so "which scalars get a marker" is the feature itself, and a
/// name that renders one marker for two trailing spaces understates the very risk it was opened to
/// show.
///
/// `markingAgreesWithNameDisplayOnPlainSpaces` stays in FileExplorer's `NameDisplayTests`: it is a
/// claim about agreement with `NameDisplay`, which is a FileExplorer type.
@Suite struct InvisibleNameMarkingTests {

    private func rendered(_ name: String) -> String {
        InvisibleNameMarking.cells(for: name).map(\.glyph).joined()
    }

    private func markerCount(_ name: String) -> Int {
        InvisibleNameMarking.cells(for: name).filter(\.isMarker).count
    }

    @Test func ordinaryNamesGetNoMarkersAtAll() {
        #expect(rendered("Swimming") == "Swimming")
        #expect(markerCount("Swimming") == 0)
        // An interior space is already visible by the text either side of it.
        #expect(rendered("report final v2.txt") == "report final v2.txt")
        #expect(markerCount("report final v2.txt") == 0)
        #expect(InvisibleNameMarking.cells(for: "").isEmpty)
    }

    @Test func everySpaceInATrailingRunIsMarked() {
        // The defect: only the OUTERMOST scalar was treated as an edge, so this drew one "␣"
        // followed by a still-invisible space — the name reads as having one trailing space when
        // it has two.
        #expect(rendered("Swimming  ") == "Swimming␣␣")
        #expect(markerCount("Swimming  ") == 2)
        #expect(rendered("Swimming   ") == "Swimming␣␣␣")
        #expect(markerCount("Swimming   ") == 3)
    }

    @Test func everySpaceInALeadingRunIsMarked() {
        #expect(rendered("   Swimming") == "␣␣␣Swimming")
        #expect(markerCount("   Swimming") == 3)
    }

    @Test func bothRunsAreMarkedAndTheInteriorIsLeftAlone() {
        #expect(rendered("  a b  ") == "␣␣a b␣␣")
        #expect(markerCount("  a b  ") == 4)
    }

    @Test func aWhollyBlankNameIsEntirelyVisible() {
        // Nothing but spaces: every one is an edge, so the name can't render as a blank row.
        #expect(rendered("   ") == "␣␣␣")
        #expect(markerCount("   ") == 3)
    }

    @Test func nonStandardWhitespaceIsMarkedWhereverItSits() {
        // A no-break space is suspicious anywhere in a name — it isn't an edge-only rule.
        #expect(rendered("a\u{00A0}b") == "a␣b")
        #expect(markerCount("a\u{00A0}b") == 1)
        #expect(rendered("a\tb") == "a␣b")
        // A trailing run mixing a plain space and a no-break space marks both.
        #expect(rendered("x \u{00A0}") == "x␣␣")
        #expect(markerCount("x \u{00A0}") == 2)
    }

    @Test func zeroWidthScalarsGetTheirOwnMarker() {
        // All four, not a sample. Moving this rule into Sync replaced its own mirrored literal
        // (`[0x200B, 0x200C, 0x200D, 0xFEFF]` as UInt32 values) with `NameNormalizer.zeroWidthScalars`
        // — the set that decides a name is risky in the first place. The two are the same four
        // scalars; enumerating them is what proves that rather than assuming it, and ZWNJ and ZWJ
        // were previously covered by neither this test nor any other.
        for scalar in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"] {
            #expect(rendered("a\(scalar)b") == "a◌b", "\(scalar.unicodeScalars.first!.value) went unmarked")
            #expect(markerCount("a\(scalar)b") == 1)
        }
        #expect(rendered("\u{FEFF}name") == "◌name")
        // A zero-width scalar is NOT whitespace, so it ends the affix run rather than extending it:
        // the space beyond it is interior and stays plain.
        #expect(rendered("a \u{200B} b") == "a ◌ b")
    }
}
