import Testing
@testable import Design

/// `ShortcutHint.tooltip` is three lines with no branches, so what is worth pinning is not that it
/// concatenates — it is the **gap**, which is the entire design decision in the function.
@Suite struct ShortcutHintTests {

    @Test func theGapIsThreeSpacesSoItReadsAsAColumnBreak() {
        #expect(ShortcutHint.tooltip("Rescan", "⌘R") == "Rescan   ⌘R")
    }

    /// The assertion above pins the string, but a reader cannot see *why* three. This says it: at
    /// one space the symbol joins the sentence, which is the failure the gap exists to prevent.
    /// Written as a comparison so shrinking the gap fails here with a message about legibility
    /// rather than only as a mismatched literal somewhere else.
    @Test func oneSpaceWouldReadAsPartOfTheSentence() {
        let hint = ShortcutHint.tooltip("Close settings", "esc")
        let gap = hint.dropFirst("Close settings".count).prefix(while: { $0 == " " })
        #expect(gap.count == 3, """
            The description and the symbol are separated by \(gap.count) space(s). A macOS tooltip \
            is a plain string with no columns, so the run of spaces is the only thing that reads \
            as a break between "what this does" and "the key that does it".
            """)
    }

    /// Nothing is trimmed, lowercased or otherwise normalised on the way through. Both halves reach
    /// the tooltip exactly as the call site wrote them — which is what lets a site interpolate
    /// live state into the description (`ReviewCardView` switches "moved"/"copied") and lets the
    /// symbol be a word (`esc`) as easily as a glyph (`␣`).
    @Test func bothHalvesArriveVerbatim() {
        #expect(ShortcutHint.tooltip("Quick Look the copy being moved", "␣")
                == "Quick Look the copy being moved   ␣")
        #expect(ShortcutHint.tooltip("Skip", "esc") == "Skip   esc")
    }
}
