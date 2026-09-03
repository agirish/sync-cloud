import Foundation
import Testing
@testable import FileExplorer

/// How much of one line the diff pane will lay out.
///
/// **The row the word budget refuses is the row that has to be capped.** `TextPairDiff` declines to
/// compare a 4 MiB single-line file word by word — minified JavaScript, JSON saved on one line, a
/// log whose writer never flushed — and the pane then handed that whole line to a `Text` with
/// `.textSelection(.enabled)` on it. Refusing the diff and then laying out millions of glyphs in a
/// lazy cell spends the cost the refusal existed to avoid, in the layout engine instead.
@MainActor
@Suite struct TextPairDiffRowRenderTests {

    /// An ordinary line is drawn exactly as the file holds it — nothing is added, nothing is lost.
    /// The pane's whole claim is fidelity.
    @Test func anOrdinaryLineIsDrawnUntouched() {
        let line = "    let total  =   4   // trailing"
        #expect(TextPairDiffView.rendered(line) == line)
    }

    /// An empty line still draws something, so the row has a height — the behaviour the cap
    /// replaced a literal with and must not have dropped.
    @Test func anEmptyLineStillDrawsASpace() {
        #expect(TextPairDiffView.rendered("") == " ")
    }

    /// A line right at the ceiling is untouched; one past it is cut, and SAYS how much is missing.
    /// Both sides of the boundary, so a green cannot mean the cap is off or that it eats everything.
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

    /// **The 4 MiB single line, end to end.** The diff refuses its word pass and the pane refuses
    /// its layout, and what the reader is left with is a readable head, a note, and the diff's own
    /// "marked whole" caption above it.
    @Test func theFourMegabyteLineIsBoundedInBothPlaces() throws {
        let left = String(repeating: "abcd ", count: 400_000)
        let right = String(repeating: "abce ", count: 400_000)
        let diff = TextPairDiff.make(left: [left], right: [right])
        #expect(diff.coarseRows == 1, "the fixture no longer exercises the word budget")
        let row = try #require(diff.rows.first)
        let text = try #require(row.left)
        let drawn = TextPairDiffView.rendered(text)
        #expect(drawn.utf8.count < 5_000,
                "the pane would lay out \(drawn.utf8.count) bytes of one line in one Text")
    }

    /// A cut line must not cut a character in half — the truncation is by CHARACTER while the
    /// measure is in bytes, which is the only reason that is safe to say.
    @Test func multibyteCharactersSurviveTheCut() {
        let line = String(repeating: "é👩‍👩‍👧‍👦", count: 5_000)
        let drawn = TextPairDiffView.rendered(line)
        #expect(drawn.hasPrefix("é"), "the cut landed inside a character")
        #expect(!drawn.unicodeScalars.contains("\u{FFFD}"), "the cut produced a replacement character")
    }
}
