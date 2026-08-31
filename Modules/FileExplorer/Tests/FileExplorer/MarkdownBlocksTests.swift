import Testing
import Foundation
@testable import FileExplorer

/// The Markdown walk: source in, preview blocks out.
///
/// **Fixtures rather than round-trips.** The claim being made is not "swift-markdown parses
/// Markdown" — that is its own project's problem — but "this walk turns what it parses into the
/// blocks the preview draws", which is the half that can silently drop a construct.
@Suite struct MarkdownBlocksTests {

    private func blocks(_ source: String) -> [MarkdownBlock] {
        MarkdownBlocks.blocks(from: source)
    }

    // MARK: Blocks

    @Test func headingsKeepTheirLevel() {
        let parsed = blocks("# One\n\n## Two\n\n###### Six\n")
        #expect(parsed.count == 3)
        guard case .heading(let a, let first) = parsed[0].kind,
              case .heading(let b, _) = parsed[1].kind,
              case .heading(let c, _) = parsed[2].kind else {
            Issue.record("the headings did not come back as headings: \(parsed)")
            return
        }
        let levels: [Int] = [a, b, c]
        #expect(levels == [1, 2, 6])
        #expect(first.plain == "One")
    }

    /// A hard-wrapped paragraph is one paragraph — the soft break becomes a space rather than a
    /// line ending, which is what makes wrapped Markdown read as prose.
    @Test func aHardWrappedParagraphIsOneBlockWithItsBreaksAsSpaces() {
        let parsed = blocks("Three folders still carry\nunscanned paper.\n")
        #expect(parsed.count == 1)
        guard case .paragraph(let text) = parsed[0].kind else {
            Issue.record("expected one paragraph, got \(parsed)")
            return
        }
        #expect(text.plain == "Three folders still carry unscanned paper.")
    }

    @Test func bulletsAndNumbersCarryTheirMarkers() {
        let parsed = blocks("- one\n- two\n\n1. first\n2. second\n")
        let markers = parsed.compactMap { block -> MarkdownListMarker? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
        #expect(markers == [.bullet, .bullet, .ordered(1), .ordered(2)])
    }

    @Test func anOrderedListStartingElsewhereKeepsItsNumbering() {
        let parsed = blocks("7. seven\n8. eight\n")
        let markers = parsed.compactMap { block -> MarkdownListMarker? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
        #expect(markers == [.ordered(7), .ordered(8)])
    }

    /// **Task state comes from the parser, not from a pre-pass**, which is the whole argument for
    /// parsing real GFM: a regex over `- [ ]` would also claim a literal bracket pair someone typed.
    @Test func taskItemsCarryTheirCheckedState() {
        let parsed = blocks("- [ ] School forms\n- [x] Passport receipts\n")
        let markers = parsed.compactMap { block -> MarkdownListMarker? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
        #expect(markers == [.task(done: false), .task(done: true)])
    }

    @Test func aBracketPairInProseIsNotATaskItem() {
        let parsed = blocks("- see [x] in the table\n")
        guard case .listItem(let marker, let text) = parsed.first?.kind else {
            Issue.record("expected a list item, got \(parsed)")
            return
        }
        #expect(marker == .bullet, "a literal bracket pair mid-line was read as a checkbox")
        #expect(text.plain.contains("[x]"))
    }

    @Test func nestedListsCarryTheirDepth() {
        let parsed = blocks("- outer\n    - inner\n        - deeper\n")
        let depths = parsed.compactMap { block -> Int? in
            if case .listItem = block.kind { return block.indent }
            return nil
        }
        #expect(depths == [0, 1, 2])
    }

    @Test func quotesCountTheirNesting() {
        let parsed = blocks("> outer\n>\n> > inner\n")
        #expect(parsed.map(\.quoteDepth) == [1, 2], "block quotes came back as \(parsed)")
    }

    /// **Every kind of block records that it is quoted, not only paragraphs.** A `>` containing a
    /// list, a fence or a heading used to emit blocks with no quote level at all, so the preview
    /// drew no quote bar and they read as ordinary body text.
    @Test func aQuotedListAndAQuotedFenceAreStillQuoted() {
        let parsed = blocks("> - one\n> - two\n>\n> ```\n> code\n> ```\n>\n> # heading\n")
        #expect(!parsed.isEmpty)
        #expect(parsed.allSatisfy { $0.quoteDepth == 1 }, "these came back as \(parsed)")
        // …and the kinds really are the varied ones, or the claim above is about one paragraph.
        let kinds = Set(parsed.map { block -> String in
            switch block.kind {
            case .listItem: return "list"
            case .codeBlock: return "code"
            case .heading: return "heading"
            default: return "other"
            }
        })
        #expect(kinds == ["list", "code", "heading"], "the fixture did not produce three kinds: \(kinds)")
    }

    /// The other half of the same correction: content nested under a list item is indented with it.
    @Test func aFenceUnderABulletIsIndentedWithIt() {
        let parsed = blocks("- explain\n\n    ```\n    code\n    ```\n")
        guard let fence = parsed.first(where: {
            if case .codeBlock = $0.kind { return true } else { return false }
        }) else {
            Issue.record("no code block in \(parsed)")
            return
        }
        #expect(fence.indent == 1, "the fence came back at indent \(fence.indent), flush with the margin")
    }

    /// **A list item that opens with a fence keeps its own order.** The lead paragraph used to be
    /// taken from anywhere among the item's children, so an item whose prose came *after* a code
    /// block had the prose hoisted above it — the preview showed the explanation above the code.
    @Test func aListItemKeepsTheOrderItsChildrenWereWrittenIn() {
        let parsed = blocks("- ```\n  code\n  ```\n\n  then prose\n")
        let order = parsed.map { block -> String in
            switch block.kind {
            case .listItem: return "item"
            case .codeBlock: return "code"
            case .paragraph: return "prose"
            default: return "other"
            }
        }
        let code = order.firstIndex(of: "code") ?? Int.max
        let prose = order.firstIndex(of: "prose") ?? Int.max
        #expect(code < prose, "the prose was hoisted above the code it follows: \(order)")
    }

    @Test func fencedCodeKeepsItsLanguageAndItsExactText() {
        let parsed = blocks("```swift\nlet x = 1\n  indented\n```\n")
        guard case .codeBlock(let language, let code) = parsed.first?.kind else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\n  indented\n", "the code block lost its own whitespace")
    }

    @Test func anUnlabelledFenceHasNoLanguageRatherThanAnEmptyOne() {
        let parsed = blocks("```\nplain\n```\n")
        guard case .codeBlock(let language, _) = parsed.first?.kind else {
            Issue.record("expected a code block, got \(parsed)")
            return
        }
        #expect(language == nil)
    }

    /// A `#` inside a fence is code, not a heading — one of the reasons this parses rather than
    /// pattern-matches.
    @Test func markdownInsideAFenceIsNotParsedAsMarkdown() {
        let parsed = blocks("```\n# not a heading\n- not a list\n```\n")
        #expect(parsed.count == 1)
        guard case .codeBlock = parsed[0].kind else {
            Issue.record("the fence's contents were parsed as Markdown: \(parsed)")
            return
        }
    }

    @Test func tablesKeepTheirHeaderAndRows() {
        let parsed = blocks("""
            | Person | Folder |
            |---|---|
            | Ada | People/Ada |
            | Alan | People/Alan |
            """)
        guard case .table(let header, let rows) = parsed.first?.kind else {
            Issue.record("expected a table, got \(parsed)")
            return
        }
        #expect(header.map(\.plain) == ["Person", "Folder"])
        #expect(rows.map { $0.map(\.plain) } == [["Ada", "People/Ada"], ["Alan", "People/Alan"]])
    }

    /// **A short row is padded to the header's width**, so the missing cell stays in its own
    /// column. Left-packed, a gap in the middle shifts every cell after it and the absence appears
    /// at the end of the row — the one place it is not.
    @Test func aRaggedRowKeepsItsCellsInTheRightColumns() {
        let parsed = blocks("| A | B | C |\n|---|---|---|\n| 1 | 2 |\n")
        guard case .table(let header, let rows) = parsed.first?.kind else {
            Issue.record("expected a table, got \(parsed)")
            return
        }
        #expect(header.count == 3)
        #expect(rows.first?.count == 3, "the short row came back with \(rows.first?.count ?? 0) cells")
        #expect(rows.first?.last?.plain == "")
    }

    @Test func aThematicBreakIsItsOwnBlock() {
        let parsed = blocks("above\n\n---\n\nbelow\n")
        #expect(parsed.contains { $0.kind == .thematicBreak })
    }

    // MARK: Inline

    @Test func emphasisAndCodeAndStrikeBecomeStyledRuns() {
        let parsed = blocks("plain **bold** _italic_ `code` ~~gone~~\n")
        guard case .paragraph(let text) = parsed.first?.kind else {
            Issue.record("expected a paragraph, got \(parsed)")
            return
        }
        let styled = text.runs.filter { $0.isBold || $0.isItalic || $0.isCode || $0.isStruck }
        #expect(styled.count == 4, "runs came back as \(text.runs)")
        #expect(styled.first { $0.isBold }?.text == "bold")
        #expect(styled.first { $0.isItalic }?.text == "italic")
        #expect(styled.first { $0.isCode }?.text == "code")
        #expect(styled.first { $0.isStruck }?.text == "gone")
        #expect(text.plain == "plain bold italic code gone")
    }

    /// **Nesting survives as combination**, which is the flattening's whole contract: bold inside a
    /// link is one run that is both, not a link that lost its emphasis.
    @Test func nestedStylesCombineOnOneRun() {
        let parsed = blocks("[**bold link**](https://example.com)\n")
        guard case .paragraph(let text) = parsed.first?.kind,
              let run = text.runs.first else {
            Issue.record("expected a paragraph with runs, got \(parsed)")
            return
        }
        #expect(run.text == "bold link")
        #expect(run.isBold)
        #expect(run.link == "https://example.com")
    }

    /// Ordinary prose arrives as several identically-styled nodes; merging them is what keeps a
    /// paragraph one `Text` and therefore able to wrap as one.
    @Test func neighbouringRunsWithTheSameStylingAreMerged() {
        let parsed = blocks("one two three four five\n")
        guard case .paragraph(let text) = parsed.first?.kind else {
            Issue.record("expected a paragraph, got \(parsed)")
            return
        }
        #expect(text.runs.count == 1, "an unstyled sentence came back as \(text.runs.count) runs")
    }

    @Test func anImageBecomesItsAltTextRatherThanAFetch() {
        let parsed = blocks("![a diagram](https://example.com/x.png)\n")
        guard case .paragraph(let text) = parsed.first?.kind else {
            Issue.record("expected a paragraph, got \(parsed)")
            return
        }
        #expect(text.plain.contains("a diagram"))
    }

    // MARK: Hostile input

    @Test func anEmptyDocumentHasNoBlocks() {
        #expect(blocks("").isEmpty)
        #expect(blocks("\n\n\n").isEmpty)
    }

    @Test func oneEnormousLineIsStillOneParagraph() {
        let long = String(repeating: "word ", count: 40_000)
        let parsed = blocks(long)
        #expect(parsed.count == 1)
        guard case .paragraph(let text) = parsed[0].kind else {
            Issue.record("a very long line did not come back as a paragraph")
            return
        }
        #expect(text.plain.count > 100_000)
    }

    /// Every byte sequence is *some* Markdown document, so the walk has no error path — what it has
    /// to survive is a shape it does not model, and the rule is that such a shape becomes text
    /// rather than disappearing.
    ///
    /// **Each fixture is asserted, not merely run.** The loop body was `_ = blocks(source)` for
    /// every case but the last: five of the six were a crash smoke test wearing a doc comment that
    /// promised the shapes survive, and returning `[]` for indented code, `***`, a link-reference
    /// definition or a ragged table would have gone unnoticed.
    @Test func unusualInputDoesNotCrashAndDoesNotVanish() {
        for source in ["<div>raw html</div>\n", "    indented code\n", "***\n",
                       "[ref]: https://example.com\n\nSee [ref].\n",
                       "| broken | table\n|---\n", "\u{FFFD}\u{0001}\n",
                       // Unterminated: cmark closes the fence at EOF rather than dropping it.
                       "```swift\nlet x = 1\n",
                       // CRLF throughout, which is what a file written on Windows looks like.
                       "# Title\r\n\r\nA paragraph.\r\n\r\n- one\r\n- two\r\n"] {
            #expect(!blocks(source).isEmpty,
                    "the walk dropped everything in \(String(reflecting: source))")
        }
        // The one with content that must survive verbatim: raw HTML is shown as what it is.
        let html = blocks("<div>raw html</div>\n")
        #expect(!html.isEmpty, "an HTML block vanished from the preview")
    }

    /// **A line starting with `@` is prose, not a directive.**
    ///
    /// The walk asked for `.parseBlockDirectives` — a DocC extension, not Markdown. The parser
    /// opens a directive on a bare `@` plus a name, with no parentheses and no braces, and
    /// explicitly accepts "garbage after the opening"; the resulting node fell to the walk's
    /// fallback arm, which renders an unknown node with `markup.format()` — and the formatter
    /// prints a directive by wrapping its arguments in PARENTHESES and dropping the inline styling.
    /// So a note containing `@channel ping me about **the invoice**` was shown to its author with
    /// brackets it had never typed and the bold silently gone. `@media` in an unfenced CSS snippet,
    /// `@2x` and an `@username` at the start of a line all did the same.
    @Test func aLineBeginningWithAnAtSignIsRenderedAsTheProseItIs() {
        let parsed = blocks("@channel ping me about **the invoice**\n")
        let text = try? #require(parsed.first.flatMap { block -> MarkdownText? in
            if case .paragraph(let text) = block.kind { return text }
            return nil
        })
        let plain = text?.plain ?? ""
        #expect(plain == "@channel ping me about the invoice",
                "an @-line rendered as \(String(reflecting: plain))")
        #expect(!plain.contains("("), "the formatter added parentheses the file does not contain")
        #expect(text?.runs.contains { $0.isBold && $0.text == "the invoice" } == true,
                "the bold run was flattened away")
    }

    /// Nesting is carried as a number and the document decides how big it gets; the preview clamps
    /// what it DRAWS, but the walk must still report the real depth rather than capping or
    /// crashing. A forwarded mail thread is routinely eight to fifteen levels.
    @Test func deepNestingIsCountedRatherThanClamped() {
        let quoted = String(repeating: "> ", count: 20) + "deep\n"
        let block = try? #require(blocks(quoted).first)
        #expect(block?.quoteDepth == 20, "the walk reported a depth of \(block?.quoteDepth ?? -1)")
        // And the preview is what refuses to draw twenty bars, so the words keep their column.
        #expect(MarkdownPreview.drawnDepth(20) == MarkdownPreview.maxNestingDrawn)
        #expect(MarkdownPreview.drawnDepth(2) == 2, "the clamp is flattening depths it should draw")
        #expect(MarkdownPreview.drawnDepth(0) == 0)
    }
}
