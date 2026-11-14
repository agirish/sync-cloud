import Testing
import Foundation
@testable import FileExplorer

/// The Markdown walk: source in, preview blocks out.
///
/// Fixtures rather than round-trips: the claim is not that swift-markdown parses Markdown but that
/// this walk turns what it parses into the blocks the preview draws, the half that can silently
/// drop a construct.
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

    /// A hard-wrapped paragraph is one paragraph: the soft break becomes a space, not a line
    /// ending, so wrapped Markdown reads as prose.
    @Test func aHardWrappedParagraphIsOneBlockWithItsBreaksAsSpaces() {
        let parsed = blocks("Three folders still carry\nunscanned paper.\n")
        #expect(parsed.count == 1)
        guard case .paragraph(let text) = parsed[0].kind else {
            Issue.record("expected one paragraph, got \(parsed)")
            return
        }
        #expect(text.plain == "Three folders still carry unscanned paper.")
    }

    /// The list markers of every list item in `source`, in order.
    private func markers(_ source: String) -> [MarkdownListMarker] {
        blocks(source).compactMap { block -> MarkdownListMarker? in
            if case .listItem(let marker, _) = block.kind { return marker }
            return nil
        }
    }

    @Test(arguments: [
        ("- one\n- two\n\n1. first\n2. second\n", [.bullet, .bullet, .ordered(1), .ordered(2)]),
        // An ordered list starting elsewhere keeps its numbering.
        ("7. seven\n8. eight\n", [.ordered(7), .ordered(8)]),
        // Task state comes from the parser, not a pre-pass, which is the argument for parsing real
        // GFM: a regex over `- [ ]` would also claim a literal bracket pair someone typed.
        ("- [ ] School forms\n- [x] Passport receipts\n", [.task(done: false), .task(done: true)]),
    ] as [(String, [MarkdownListMarker])])
    func listItemsCarryTheirMarkers(_ source: String, _ expected: [MarkdownListMarker]) {
        #expect(markers(source) == expected)
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

    /// Every kind of block records that it is quoted, not only paragraphs. A `>` holding a list, a
    /// fence or a heading must still draw its quote bar, or those read as ordinary body text.
    @Test func aQuotedListAndAQuotedFenceAreStillQuoted() {
        let parsed = blocks("> - one\n> - two\n>\n> ```\n> code\n> ```\n>\n> # heading\n")
        #expect(!parsed.isEmpty)
        #expect(parsed.allSatisfy { $0.quoteDepth == 1 }, "these came back as \(parsed)")
        // …and the kinds really are varied, or the claim above is about one paragraph.
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

    /// The same rule for lists: content nested under a list item is indented with it.
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

    /// A list item that opens with a fence keeps its own order. Taking the lead paragraph from
    /// anywhere among the item's children would hoist prose written after a code block above it.
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

    /// A `#` inside a fence is code, not a heading: one reason this parses rather than
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

    /// A short row is padded to the header's width, so a missing cell stays in its own column
    /// rather than shifting every cell after it.
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

    /// Nesting survives as combination, the flattening's whole contract: bold inside a link is one
    /// run that is both, not a link that lost its emphasis.
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

    /// A lone image is its own block with its source and alt text; nothing here fetches it, and a
    /// remote source is refused (decided in `MarkdownImageSource`, checked here too).
    @Test func aRemoteImageIsCarriedButNeverFetched() {
        let parsed = blocks("![a diagram](https://example.com/x.png)\n")
        guard case .image(let source, let alt) = parsed.first?.kind else {
            Issue.record("expected an image block, got \(parsed)")
            return
        }
        #expect(alt == "a diagram")
        #expect(source == "https://example.com/x.png")
        #expect(MarkdownImageSource.resolve(source, relativeTo: "/tmp")
                == .refused("Remote images aren’t downloaded."))
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

    /// Every byte sequence is some Markdown document, so the walk has no error path; what it must
    /// survive is a shape it doesn't model, and such a shape becomes text rather than disappearing.
    /// Each fixture is asserted, not merely run, so returning `[]` for any of them fails.
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
    }

    /// A line starting with `@` is prose, not a directive.
    ///
    /// With `.parseBlockDirectives` (a DocC extension, not Markdown) the parser opens a directive
    /// on a bare `@` plus a name, and the walk's fallback renders it with `markup.format()`, which
    /// wraps the arguments in parentheses and drops inline styling: an `@channel` or `@media` line
    /// would show brackets never typed and lose its bold.
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

    /// The walk reports the real nesting depth rather than capping or crashing (a forwarded mail
    /// thread runs eight to fifteen levels); only the preview clamps what it draws.
    @Test func deepNestingIsCountedRatherThanClamped() {
        let quoted = String(repeating: "> ", count: 20) + "deep\n"
        let block = try? #require(blocks(quoted).first)
        #expect(block?.quoteDepth == 20, "the walk reported a depth of \(block?.quoteDepth ?? -1)")
        // And the preview is what refuses to draw twenty bars, so the words keep their column.
        #expect(MarkdownBlockView.drawnDepth(20) == MarkdownBlockView.maxNestingDrawn)
        #expect(MarkdownBlockView.drawnDepth(2) == 2, "the clamp is flattening depths it should draw")
        #expect(MarkdownBlockView.drawnDepth(0) == 0)
    }

    // MARK: Source lines

    /// The outline, the task toggle and the split sync all ask for the line: a walk answering `nil`
    /// everywhere would leave all three inert and passing.
    @Test func everyBlockKnowsTheLineItStartsOn() {
        let parsed = blocks("""
        # Title

        A paragraph.

        ## Second

        - one
        - two
        """)
        #expect(parsed.map(\.line) == [1, 3, 5, 7, 8],
                "the walk reported lines \(parsed.map(\.line))")
    }

    /// Lines are counted in the whole document, not within the construct. A walk that re-parsed
    /// fragments would get the heading after a twenty-line fence wrong, and look correct in every
    /// short fixture.
    @Test func linesAreCountedFromTheTopOfTheDocument() {
        let source = "```\n" + String(repeating: "x\n", count: 20) + "```\n\n# Late\n"
        let parsed = blocks(source)
        let heading = parsed.first { if case .heading = $0.kind { return true } else { return false } }
        #expect(heading?.line == 24, "the late heading landed on line \(heading?.line as Int?)")
    }

    /// A task item's line is the line its checkbox is on, which is what the preview's click has to
    /// rewrite. Nested items report their own line rather than their parent's.
    @Test func taskItemsReportTheLineTheirCheckboxIsOn() {
        let parsed = blocks("""
        Intro.

        - [ ] first
        - [x] second
          - [ ] nested
        """)
        let tasks = parsed.compactMap { block -> Int? in
            guard case .listItem(.task, _) = block.kind else { return nil }
            return block.line
        }
        #expect(tasks == [3, 4, 5], "the task lines came back as \(tasks)")
    }

    /// Quoted content keeps the line it is written on, not the quote's opening line: the quote
    /// recurses into its children and each child carries its own range.
    @Test func aQuotedBlockReportsItsOwnLineNotTheQuotesFirst() {
        let parsed = blocks("> one\n>\n> two\n")
        #expect(parsed.map(\.line) == [1, 3], "quoted blocks reported \(parsed.map(\.line))")
    }
}
