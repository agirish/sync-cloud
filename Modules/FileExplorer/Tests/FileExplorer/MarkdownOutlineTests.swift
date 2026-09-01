import Testing
import Foundation
@testable import FileExplorer

/// The outline, and the two lookups the rail and the split sync are built on.
@Suite struct MarkdownOutlineTests {

    private func outline(_ source: String) -> [MarkdownOutlineEntry] {
        MarkdownOutline.entries(from: MarkdownBlocks.blocks(from: source))
    }

    @Test func onlyHeadingsBecomeRows() {
        let rows = outline("""
        # Title

        A paragraph, which is not a heading.

        - a list item, which is not one either

        ## Second
        """)
        #expect(rows.map(\.title) == ["Title", "Second"])
        #expect(rows.map(\.level) == [1, 2])
        #expect(rows.map(\.line) == [1, 7])
    }

    /// A note whose headings start at `##` — every file in a folder that reserves `#` for the
    /// title — draws its top level at the margin, not one step in from it.
    @Test func depthIsRelativeToTheShallowestHeadingInTheDocument() {
        let rows = outline("""
        ## One

        ### Under it

        ## Two
        """)
        #expect(rows.map(\.depth) == [0, 1, 0], "depths came back as \(rows.map(\.depth))")
        // The level is untouched — it is what the document says, and the a11y label reads it.
        #expect(rows.map(\.level) == [2, 3, 2])
    }

    /// Six levels of indent would leave a 232pt rail no room for words, so the drawn depth stops
    /// where the preview's quote bars stop.
    @Test func depthIsClampedForDrawing() {
        let rows = outline("# a\n\n## b\n\n### c\n\n#### d\n\n##### e\n\n###### f\n")
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 3, 3],
                "depths came back as \(rows.map(\.depth))")
        #expect(MarkdownOutline.drawnDepth(9) == MarkdownOutline.maxDepthDrawn)
        #expect(MarkdownOutline.drawnDepth(-1) == 0)
    }

    /// A heading the parser gave no range to cannot be scrolled to, so it is not offered.
    @Test func aHeadingWithNoLineIsLeftOut() {
        let blocks = [
            MarkdownBlock(.heading(level: 1, text: MarkdownText(runs: [MarkdownRun(text: "Real")])),
                          line: 4),
            MarkdownBlock(.heading(level: 1, text: MarkdownText(runs: [MarkdownRun(text: "Ghost")])))
        ]
        #expect(MarkdownOutline.entries(from: blocks).map(\.title) == ["Real"])
    }

    @Test func anEmptyHeadingKeepsItsRow() {
        let rows = outline("##\n\n# Real\n")
        #expect(rows.count == 2, "an empty heading was dropped: \(rows.map(\.title))")
        #expect(rows.first?.title.isEmpty == true)
    }

    // MARK: Which section am I in

    @Test func theCurrentRowIsTheLastHeadingAtOrBeforeTheLine() {
        let rows = outline("# One\n\ntext\n\n## Two\n\nmore\n")
        #expect(MarkdownOutline.currentEntry(forLine: 1, in: rows) == 0)
        #expect(MarkdownOutline.currentEntry(forLine: 3, in: rows) == 0)
        #expect(MarkdownOutline.currentEntry(forLine: 5, in: rows) == 1)
        #expect(MarkdownOutline.currentEntry(forLine: 900, in: rows) == 1)
    }

    /// Text above the first heading is in no section, and saying "the first one" would follow the
    /// caret into a preamble that row does not describe.
    @Test func aboveTheFirstHeadingThereIsNoCurrentRow() {
        let rows = outline("preamble\n\n# One\n")
        #expect(MarkdownOutline.currentEntry(forLine: 1, in: rows) == nil)
        #expect(MarkdownOutline.currentEntry(forLine: 3, in: rows) == 0)
        #expect(MarkdownOutline.currentEntry(forLine: 1, in: []) == nil)
    }

    // MARK: Where the preview scrolls

    @Test func thePreviewScrollsToTheBlockContainingTheLine() {
        let blocks = MarkdownBlocks.blocks(from: "# One\n\npara\n\n## Two\n\nmore\n")
        #expect(MarkdownOutline.blockIndex(forLine: 5, in: blocks) == 2)
        #expect(MarkdownOutline.blockIndex(forLine: 7, in: blocks) == 3)
    }

    /// Scrolled above everything that reported a line, the preview belongs at its top rather than
    /// nowhere — which is the difference between a sync that settles and one that stops working
    /// when you scroll back up.
    @Test func aLineAboveEveryBlockScrollsToTheTop() {
        let blocks = MarkdownBlocks.blocks(from: "\n\n\n# Late\n")
        #expect(MarkdownOutline.blockIndex(forLine: 1, in: blocks) == 0)
        #expect(MarkdownOutline.blockIndex(forLine: 1, in: []) == nil)
    }

    // MARK: Line to offset

    /// The inverse has to be exact: one character out puts the caret at the end of the line before.
    @Test func aLinesOffsetRoundTripsToItsOwnLine() {
        let text = "one\ntwo\nthree\nfour"
        for line in 1...4 {
            let offset = EditorCaret.utf16Offset(ofLine: line, in: text)
            #expect(offset != nil, "line \(line) had no offset")
            #expect(EditorCaret.at(utf16Offset: offset ?? 0, in: text)
                    == EditorCaret(line: line, column: 1),
                    "line \(line) resolved to offset \(offset as Int?)")
        }
    }

    @Test func aLineBeyondTheEndHasNoOffset() {
        #expect(EditorCaret.utf16Offset(ofLine: 9, in: "one\ntwo") == nil)
        #expect(EditorCaret.utf16Offset(ofLine: 0, in: "one") == nil)
        #expect(EditorCaret.utf16Offset(ofLine: 1, in: "") == 0)
    }

    /// CRLF is one Character and two UTF-16 units, so the offset has to count the units while the
    /// line count counts the character.
    @Test func crlfOffsetsCountBothUnits() {
        #expect(EditorCaret.utf16Offset(ofLine: 2, in: "one\r\ntwo") == 5)
    }
}

/// The `#heading` links that scroll the preview instead of leaving the app.
@Suite struct MarkdownAnchorTests {

    private func outline(_ source: String) -> [MarkdownOutlineEntry] {
        MarkdownOutline.entries(from: MarkdownBlocks.blocks(from: source))
    }

    @Test func anAnchorIsTheGitHubSlug() {
        #expect(MarkdownOutline.anchor(for: "The two numbers") == "the-two-numbers")
        #expect(MarkdownOutline.anchor(for: "Cutting it — step 3!") == "cutting-it--step-3")
        #expect(MarkdownOutline.anchor(for: "snake_case and dash-case") == "snake_case-and-dash-case")
    }

    @Test func aFragmentFindsItsHeadingsLine() {
        let rows = outline("# One\n\ntext\n\n## The two numbers\n\nmore\n")
        #expect(MarkdownOutline.line(forAnchor: "the-two-numbers", in: rows) == 5)
        #expect(MarkdownOutline.line(forAnchor: "#the-two-numbers", in: rows) == 5)
        #expect(MarkdownOutline.line(forAnchor: "one", in: rows) == 1)
    }

    /// No match is no scroll. The anchor convention is GitHub's rather than a standard, so a
    /// near-miss must not send the reader somewhere they did not ask to go.
    @Test func aFragmentThatMatchesNothingAnswersNothing() {
        let rows = outline("# One\n")
        #expect(MarkdownOutline.line(forAnchor: "nowhere", in: rows) == nil)
        #expect(MarkdownOutline.line(forAnchor: "", in: rows) == nil)
        #expect(MarkdownOutline.line(forAnchor: "one", in: []) == nil)
    }
}
