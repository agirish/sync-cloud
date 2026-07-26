import Testing
@testable import FileExplorer

/// Pins the Rename lens's risky-name marking. This view exists for one job — making an invisible
/// character visible before the user decides what to do about it — so "which scalars get a marker"
/// is the feature itself, and a name that renders one marker for two trailing spaces understates
/// the very risk it was opened to show.
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

    @Test func markingAgreesWithNameDisplayOnPlainSpaces() {
        // The panes' text form (`NameDisplay.visibleName`) already walks the whole affix run; this
        // view is the same claim rendered as tinted cells, so the two must not disagree about how
        // many spaces a name has.
        for name in ["Swimming", "Swimming ", "Swimming  ", " Swimming", "  x  ", " ", "   ", "a b"] {
            #expect(rendered(name) == NameDisplay.visibleName(name), "disagreed on \"\(name)\"")
        }
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
        #expect(rendered("a\u{200B}b") == "a◌b")
        #expect(markerCount("a\u{200B}b") == 1)
        #expect(rendered("\u{FEFF}name") == "◌name")
        // A zero-width scalar is NOT whitespace, so it ends the affix run rather than extending it:
        // the space beyond it is interior and stays plain.
        #expect(rendered("a \u{200B} b") == "a ◌ b")
    }
}
