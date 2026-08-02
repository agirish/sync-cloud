import Testing
import Sync
@testable import FileExplorer

/// Pins `NameDisplay`: invisible leading/trailing whitespace becomes a visible "␣" in pane
/// rows and Differences cells, so two on-screen "identical" siblings ("Swimming" and
/// "Swimming ") stop looking like an impossible duplicate. Ordinary names pass through
/// byte-identical.
@Suite struct NameDisplayTests {

    @Test func testOrdinaryNamesPassThroughUntouched() {
        #expect(NameDisplay.visibleName("Swimming") == "Swimming")
        #expect(NameDisplay.visibleName("report (final) v2.txt") == "report (final) v2.txt")
        // Interior whitespace is already visible by the text around it.
        #expect(NameDisplay.visibleName("a b") == "a b")
        #expect(NameDisplay.visibleName("") == "")
    }

    @Test func testAffixWhitespaceBecomesVisible() {
        #expect(NameDisplay.visibleName("Swimming ") == "Swimming␣")
        #expect(NameDisplay.visibleName(" Swimming") == "␣Swimming")
        #expect(NameDisplay.visibleName("  x  ") == "␣␣x␣␣")
        // Whole-whitespace names become fully visible instead of rendering blank.
        #expect(NameDisplay.visibleName(" ") == "␣")
    }

    @Test func testHasInvisibleAffix() {
        #expect(NameDisplay.hasInvisibleAffix("Swimming "))
        #expect(NameDisplay.hasInvisibleAffix(" Swimming"))
        #expect(!NameDisplay.hasInvisibleAffix("Swimming"))
        #expect(!NameDisplay.hasInvisibleAffix("a b"))
        #expect(!NameDisplay.hasInvisibleAffix(""))
    }

    @Test func testVisiblePathMarksEveryComponent() {
        #expect(NameDisplay.visiblePath("Fitness/Swimming /log.txt") == "Fitness/Swimming␣/log.txt")
        #expect(NameDisplay.visiblePath("Fitness/Swimming/log.txt") == "Fitness/Swimming/log.txt")
        #expect(NameDisplay.visiblePath("Swimming ") == "Swimming␣")
    }

    /// The two ways this app makes an invisible affix visible must not disagree about how many
    /// spaces a name has: `NameDisplay` is the panes' text form, `InvisibleNameMarking` (Sync) is
    /// the same claim rendered as tinted cells by the Rename lens and the kept-names list.
    ///
    /// It lives here rather than with the rest of `InvisibleNameMarkingTests`, which moved to Sync
    /// with the rule: `NameDisplay` is a FileExplorer type, and Sync cannot see it.
    @Test func markingAgreesWithNameDisplayOnPlainSpaces() {
        for name in ["Swimming", "Swimming ", "Swimming  ", " Swimming", "  x  ", " ", "   ", "a b"] {
            let marked = InvisibleNameMarking.cells(for: name).map(\.glyph).joined()
            #expect(marked == NameDisplay.visibleName(name), "disagreed on \"\(name)\"")
        }
    }
}
