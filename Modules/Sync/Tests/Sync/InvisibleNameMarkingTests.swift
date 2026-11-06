import Testing
@testable import Sync

/// Pins the risky-name marking shared by the Rename lens's card and the kept-names list in
/// Settings ▸ Organize. Both exist to make an invisible character visible before the user decides,
/// so which scalars get a marker is the feature itself: one marker for two trailing spaces
/// understates the risk. `markingAgreesWithNameDisplayOnPlainSpaces` lives in FileExplorer's
/// `NameDisplayTests`, since `NameDisplay` is a FileExplorer type.
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
        // Every scalar of the run is an edge, not just the outermost: one "␣" plus an invisible
        // space would read as one trailing space when there are two.
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
        // All four, not a sample: the marking uses `NameNormalizer.zeroWidthScalars`, the set that
        // decides a name is risky, and listing them here proves it holds exactly these four.
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
