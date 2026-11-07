import Foundation
import Testing
@testable import FileExplorer

/// How much of one line the diff pane will lay out. `TextPairDiff` declines to compare a 4 MiB
/// single-line file word by word (minified JavaScript, one-line JSON, an unflushed log), and that
/// row must be capped too: laying out millions of glyphs in a selectable `Text` would spend in the
/// layout engine the cost the refusal exists to avoid.
@MainActor
@Suite struct TextPairDiffRowRenderTests {

    /// An ordinary line is drawn exactly as the file holds it, nothing added or lost: the pane's
    /// whole claim is fidelity.
    @Test func anOrdinaryLineIsDrawnUntouched() {
        let line = "    let total  =   4   // trailing"
        #expect(TextPairDiffView.rendered(line) == line)
    }

    /// An empty line still draws a space, so the row has a height.
    @Test func anEmptyLineStillDrawsASpace() {
        #expect(TextPairDiffView.rendered("") == " ")
    }

    /// A line right at the ceiling is untouched; one past it is cut and says how much is missing.
    /// Both sides of the boundary, so a green can't mean the cap is off or eats everything.
    @Test func aLinePastTheCeilingIsCutAndSaysSo() {
        let atCeiling = String(repeating: "x", count: TextPairDiffView.maxRenderedCharacters)
        #expect(TextPairDiffView.rendered(atCeiling) == atCeiling,
                "a line exactly at the ceiling was truncated")

        let over = String(repeating: "x", count: TextPairDiffView.maxRenderedCharacters + 5_000)
        let drawn = TextPairDiffView.rendered(over)
        #expect(drawn.count < over.count, "a line past the ceiling was laid out whole")
        #expect(drawn.hasPrefix(String(over.prefix(TextPairDiffView.maxRenderedCharacters))),
                "the head that IS drawn is not the file's own text")
        #expect(drawn.contains("more on this line"),
                "the line trails off with no statement of what was left out")
    }

    /// The 4 MiB single line, end to end: the diff refuses its word pass and the pane refuses its
    /// layout, leaving a readable head, a note, and the diff's own "marked whole" caption above it.
    /// The line is the case the word budget exists for, and it is priced without being tokenised.
    @Test func theFourMegabyteLineIsBoundedInBothPlaces() throws {
        let left = String(repeating: "abcd ", count: 400_000)
        let right = String(repeating: "abce ", count: 400_000)
        #expect(TextPairDiff.wordCount(left) > TextPairDiff.maxWordsForIntraLine,
                "the fixture is no longer past the gate")
        let diff = TextPairDiff.make(left: [left], right: [right])
        #expect(diff.coarseRows == 1, "the row paid for a word pass it could not afford")
        let row = try #require(diff.rows.first)
        #expect(row.leftSegments == nil)
        #expect(row.left == left, "the text itself must survive: the pane draws it")
        let text = try #require(row.left)
        let drawn = TextPairDiffView.rendered(text)
        #expect(drawn.utf8.count < 5_000,
                "the pane would lay out \(drawn.utf8.count) bytes of one line in one Text")
    }

    /// A cut line must not cut a character in half: the truncation counts characters even though
    /// the budget is measured in bytes.
    @Test func multibyteCharactersSurviveTheCut() {
        let line = String(repeating: "é👩‍👩‍👧‍👦", count: 5_000)
        let drawn = TextPairDiffView.rendered(line)
        #expect(drawn.hasPrefix("é"), "the cut landed inside a character")
        #expect(!drawn.unicodeScalars.contains("\u{FFFD}"), "the cut produced a replacement character")
    }
}
