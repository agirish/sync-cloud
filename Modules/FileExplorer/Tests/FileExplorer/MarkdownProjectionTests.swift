import Testing
import Foundation
import AppKit
@testable import FileExplorer

/// The editable preview's projection: what it draws, and which source characters each drawn
/// character came from.
///
/// **The map is checked against the parser, not against itself.** The sentinel tests insert a
/// character into the SOURCE at the offset the map gives, parse again, and require the new
/// rendering to be the old one with that character at the expected place. A map that pointed one
/// character off — into a `**`, past an escape, into a stripped indent — renders the sentinel
/// somewhere else, or not at all.
@Suite struct MarkdownProjectionTests {

    // MARK: Helpers

    private func project(_ source: String) -> MarkdownProjection {
        MarkdownProjection.project(source)
    }

    private func slice(_ p: MarkdownProjection, _ range: NSRange) -> String {
        (p.source as NSString).substring(with: range)
    }

    private func renderedSlice(_ p: MarkdownProjection, _ range: NSRange) -> String {
        (p.renderedString as NSString).substring(with: range)
    }

    /// The source text behind each non-empty content segment, in order.
    private func contentSources(_ p: MarkdownProjection) -> [String] {
        p.segments.filter { $0.kind == .content && $0.rendered.length > 0 }.map { slice(p, $0.source) }
    }

    /// §3.2's invariants: a gap-free rendered cover, increasing source ranges, and content whose
    /// boundary map runs from the start of its source to the end.
    private func checkInvariants(_ p: MarkdownProjection,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        var renderedCursor = 0
        var sourceCursor = 0
        for segment in p.segments {
            #expect(segment.rendered.location == renderedCursor,
                    "gap in the rendered cover at \(renderedCursor): \(segment)",
                    sourceLocation: sourceLocation)
            renderedCursor = NSMaxRange(segment.rendered)
            #expect(segment.source.location >= sourceCursor,
                    "source ranges overlap at \(segment.source): \(segment)",
                    sourceLocation: sourceLocation)
            sourceCursor = max(sourceCursor, NSMaxRange(segment.source))
            #expect(NSMaxRange(segment.source) <= p.index.length, sourceLocation: sourceLocation)
            guard segment.kind == .content else { continue }
            if let map = segment.charMap {
                #expect(map.count == segment.rendered.length + 1, sourceLocation: sourceLocation)
                #expect(map.first == 0 && map.last == segment.source.length,
                        sourceLocation: sourceLocation)
                let known = map.filter { $0 >= 0 }
                #expect(known == known.sorted(), sourceLocation: sourceLocation)
            } else {
                #expect(slice(p, segment.source) == renderedSlice(p, segment.rendered),
                        "identity segment does not match its source: \(segment)",
                        sourceLocation: sourceLocation)
            }
        }
        #expect(renderedCursor == (p.renderedString as NSString).length,
                "the cover stops short of the rendered string", sourceLocation: sourceLocation)
    }

    /// For every content segment, at its start, middle and end: insert a sentinel into the SOURCE
    /// at the mapped offset, re-parse, and require the sentinel in the RENDERING at the matching
    /// place. Returns how many insertions were checked, so a caller can see it did something.
    @discardableResult
    private func checkSentinels(_ source: String,
                                sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        let sentinel = "龘"
        let p = project(source)
        var checked = 0
        for segment in p.segments where segment.kind == .content {
            guard p.blocks[segment.block].readOnly == nil else { continue }
            let length = segment.rendered.length
            for boundary in Set([0, length / 2, length]) {
                guard let at = segment.sourceOffset(forRenderedBoundary: boundary) else { continue }
                var edit = (range: NSRange(location: at, length: 0), text: sentinel)
                // An empty line in a fenced block: the line is rewritten with the block's prefix,
                // which is what the translator will do (see `PreviewBlock.linePrefix`).
                let line = p.index.line(p.index.lineNumber(containing: at))!
                if length == 0, case .codeBlock = p.blocks[segment.block].kind,
                   (p.source as NSString).substring(with: NSRange(location: line.start,
                                                                  length: line.end - line.start))
                       .allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) {
                    edit = (NSRange(location: line.start, length: line.end - line.start),
                            p.blocks[segment.block].linePrefix + sentinel)
                }
                let edited = (source as NSString).replacingCharacters(in: edit.range, with: edit.text)
                let expected = (p.renderedString as NSString).replacingCharacters(
                    in: NSRange(location: segment.rendered.location + boundary, length: 0),
                    with: sentinel)
                let actual = project(edited).renderedString
                #expect(actual == expected,
                        "sentinel at source \(at) (rendered \(segment.rendered.location + boundary)) in \(String(reflecting: source))",
                        sourceLocation: sourceLocation)
                checked += 1
            }
        }
        return checked
    }

    // MARK: The source index

    @Test func utf8ColumnsBecomeUTF16Offsets() {
        let index = MarkdownSourceIndex("Café **naïve**\na😀b 中文")
        // "Café " is six bytes and five units, so `**` is at column 7 and offset 5.
        #expect(index.utf16Offset(line: 1, utf8Column: 7) == 5)
        #expect(index.utf16Offset(line: 2, utf8Column: 1) == 15)
        // "a" 1 byte + 😀 4 bytes: "b" is column 6, and two units after "a".
        #expect(index.utf16Offset(line: 2, utf8Column: 6) == 18)
        // Column 3 is inside the emoji's four bytes: no such position.
        #expect(index.utf16Offset(line: 2, utf8Column: 3) == nil)
        // 中 is three bytes: "文" at column 11.
        #expect(index.utf16Offset(line: 2, utf8Column: 11) == 21)
        #expect(index.utf16Offset(line: 3, utf8Column: 1) == nil)
    }

    @Test func linesEndAtEveryTerminatorTheParserHonours() {
        let index = MarkdownSourceIndex("a\r\nb\rc\nd")
        #expect(index.lines.map(\.start) == [0, 3, 5, 7])
        #expect(index.lines.map(\.terminatorLength) == [2, 1, 1, 0])
        #expect(index.lineNumber(containing: 4) == 2)
        #expect(index.lineNumber(containing: 1) == 1)   // on the terminator: its own line
    }

    // MARK: The two cases the parser reports wrongly (measured, swift-markdown 0.8.0)

    /// A continuation line's leading whitespace is stripped before the parser counts columns, so
    /// `bar` is reported at column 1. Mapped as reported, typing would land in the indent.
    @Test func aContinuationLineIndentIsNotWhereTheTextIs() {
        let p = project("foo\n   bar baz\n\tqux")
        #expect(contentSources(p) == ["foo", "bar baz", "qux"])
        let bar = p.segments.first { $0.kind == .content && slice(p, $0.source) == "bar baz" }
        #expect(bar?.source.location == 7)
        #expect(p.blocks.allSatisfy { $0.readOnly == nil })
        checkInvariants(p)
        #expect(checkSentinels("foo\n   bar baz\n\tqux") > 0)
    }

    @Test func aQuotedContinuationIsMappedPastItsMarkersAndIndent() {
        let source = ">   lead *x* y\n>    cont *z*"
        let p = project(source)
        #expect(contentSources(p) == ["lead ", "x", " y", "cont ", "z"])
        #expect(p.blocks.map(\.readOnly) == [nil])
        checkInvariants(p)
        checkSentinels(source)
    }

    /// The paragraph's own indent shifts the other way: `cont` is reported a column LATE.
    @Test func anIndentedParagraphsNextLineIsNotReportedLate() {
        let source = "   indented para *x*\n  cont"
        let p = project(source)
        #expect(contentSources(p) == ["indented para ", "x", "cont"])
        checkSentinels(source)
    }

    /// A backslash break does not advance the parser's line count. Every later line of the
    /// paragraph is reported one too high, and the line straight after it past the end of the
    /// line before.
    @Test func textAfterABackslashBreakIsMappedToItsRealLine() {
        let source = "foo\\\n   bar *em* x\\\nbaz\n  qux **b**"
        let p = project(source)
        #expect(contentSources(p) == ["foo", "bar ", "em", " x", "baz", "qux ", "b"])
        let breaks = p.segments.filter { $0.kind == .hardBreak }.map { slice(p, $0.source) }
        #expect(breaks == ["\\\n   ", "\\\n"])
        #expect(p.renderedString == "foo\u{2028}bar em x\u{2028}baz qux b")
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func quotedBackslashBreaksAndTwoSpaceBreaksBothMap() {
        checkSentinels("> a\\\n> b\n> c")
        let source = "a  \n  b\\\n\tc"
        let p = project(source)
        #expect(contentSources(p) == ["a", "b", "c"])
        #expect(p.segments.filter { $0.kind == .hardBreak }.map { slice(p, $0.source) }
                == ["  \n  ", "\\\n\t"])
        checkSentinels(source)
    }

    /// The parser reports `b \| c` as five bytes. The text is aligned from its start instead, so
    /// the escape is inside the segment and the cell after it is where it should be.
    @Test func anEscapedPipeInACellIsMappedThroughItsBackslash() {
        let source = "| a | b \\| c |\n|---|:-:|\n| x \\| y | **z** |"
        let p = project(source)
        #expect(p.renderedString == "a\tb | c\nx | y\tz")
        #expect(contentSources(p) == ["a", "b \\| c", "x \\| y", "z"])
        let cell = p.segments.first { slice(p, $0.source) == "b \\| c" }
        // After "b " the rendered "|" is two source units, so " c" starts one unit later.
        #expect(cell?.sourceOffset(forRenderedBoundary: 3) == (cell?.source.location ?? 0) + 4)
        checkInvariants(p)
        checkSentinels(source)
    }

    /// Two more table-cell cases, measured: an unmatched `~~` arrives as text with no range, and
    /// every `\|` in a cell shifts the positions after it a unit early.
    @Test func aCellsUnpositionedTextAndEscapedPipesStillMap() {
        let unmatched = "| a | b~~ |\n|---|:-:|\n| c | d |"
        let p = project(unmatched)
        #expect(p.blocks.map(\.readOnly) == [nil])
        #expect(contentSources(p) == ["a", "b~~", "c", "d"])
        checkSentinels(unmatched)
        let pipes = "| a |\n|---|\n| *x*\\|*y* \\| z |"
        let q = project(pipes)
        #expect(q.blocks.map(\.readOnly) == [nil])
        #expect(contentSources(q) == ["a", "x", "\\|", "y", " \\| z"])
        checkSentinels(pipes)
    }

    // MARK: Escapes, entities, multibyte

    @Test func escapesAndEntitiesMapAsUnits() {
        let source = "a\\*b &amp; c &#x1F600; d"
        let p = project(source)
        #expect(p.renderedString == "a*b & c 😀 d")
        let segment = try! #require(p.segments.first { $0.kind == .content })
        #expect(segment.source == NSRange(location: 0, length: (source as NSString).length))
        // Rendered "a*" is source "a\*".
        #expect(segment.sourceOffset(forRenderedBoundary: 2) == 3)
        // Deleting the rendered "&" deletes the whole entity: its two boundaries are 5 apart.
        #expect(segment.sourceOffset(forRenderedBoundary: 4) == 5)
        #expect(segment.sourceOffset(forRenderedBoundary: 5) == 10)
        // Between the emoji's two units there is no source position.
        #expect(segment.sourceOffset(forRenderedBoundary: 9) == nil)
        checkInvariants(p)
        checkSentinels(source)
    }

    /// The parser curls quotes and joins dashes, so the rendered characters are not the file's.
    @Test func smartPunctuationMapsBackToTheStraightCharacters() {
        let source = "Don't \"quote\" a -- b --- c ... d ---- e ----- f"
        let p = project(source)
        #expect(p.renderedString == "Don’t “quote” a – b — c … d –– e —– f")
        let segment = try! #require(p.segments.first)
        #expect(segment.kind == .content)
        // "a – b": the en dash is two source units.
        let dash = (p.renderedString as NSString).range(of: "–").location
        #expect(segment.sourceOffset(forRenderedBoundary: dash + 1)
                == (segment.sourceOffset(forRenderedBoundary: dash) ?? 0) + 2)
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func multibyteTextMapsByUnitsNotBytes() {
        let source = "Café **naïve** 中文 😀 *ok*"
        let p = project(source)
        #expect(contentSources(p) == ["Café ", "naïve", " 中文 😀 ", "ok"])
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func codeSpansMapTheirContentAndNotTheirBackticks() {
        let source = "Use `` a`b `` and ` c ` here"
        let p = project(source)
        #expect(p.renderedString == "Use a`b and c here")
        #expect(contentSources(p) == ["Use ", "a`b", " and ", "c", " here"])
        let code = p.spans.filter { $0.kind == .code }.map { slice(p, $0.source) }
        #expect(code == ["`` a`b ``", "` c `"])
        checkSentinels(source)
    }

    @Test func aCodeSpanThatWrapsIsReadOnlyAndTheTextAfterItStillMaps() {
        let source = "`code\nspan` after"
        let p = project(source)
        #expect(p.renderedString == "code span after")
        #expect(p.segments.contains { $0.kind == .readOnly(.multilineCode) })
        #expect(contentSources(p) == [" after"])
        checkInvariants(p)
    }

    // MARK: Inline spans

    @Test func spansCarryTheirDelimitedSourceRanges() {
        let source = "Hello **plenty** of [the *docs*](http://x.y) ~~old~~"
        let p = project(source)
        let spans = p.spans.map { slice(p, $0.source) }
        #expect(spans == ["**plenty**", "[the *docs*](http://x.y)", "*docs*", "~~old~~"])
        let docs = try! #require(p.segments.first { slice(p, $0.source) == "docs" })
        #expect(docs.spans.map { p.spans[$0].kind }
                == [.link(destination: "http://x.y"), .emphasis])
        checkSentinels(source)
    }

    @Test func linkAndStyleAttributesAreOnTheRenderedText() {
        let p = project("**bold** [link](http://x.y) ~~gone~~")
        let rendered = p.rendered
        let bold = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let linkAt = (p.renderedString as NSString).range(of: "link").location
        #expect(rendered.attribute(.link, at: linkAt, effectiveRange: nil) as? String == "http://x.y")
        let goneAt = (p.renderedString as NSString).range(of: "gone").location
        #expect(rendered.attribute(.strikethroughStyle, at: goneAt, effectiveRange: nil) != nil)
    }

    // MARK: Blocks

    @Test func frontMatterIsReadOnlyAndShiftsEveryLineAfterIt() {
        let source = "---\ntitle: x\n---\n# Head\n\ntext *here*"
        let p = project(source)
        #expect(p.blocks.map(\.kind) == [.frontMatter, .heading(level: 1), .paragraph])
        #expect(p.blocks[0].readOnly == .frontMatter)
        #expect(p.blocks.map(\.line) == [1, 4, 6])
        #expect(contentSources(p) == ["Head", "text ", "here"])
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func crlfFilesMapLikeAnyOther() {
        let source = "x\r\ny **b**\r\n\r\n> q\r\n> r"
        let p = project(source)
        #expect(contentSources(p) == ["x", "y ", "b", "q", "r"])
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func fencedCodeMapsEachLineAsTheTailOfItsSourceLine() {
        let source = "1. one\n   ```swift\n   let x = 1\n\n     y\n   ```"
        let p = project(source)
        #expect(p.blocks.map(\.kind) == [.listItem(marker: .ordered(1)), .codeBlock(language: "swift")])
        let code = p.segments.filter { $0.block == 1 && $0.kind == .content }.map { slice(p, $0.source) }
        #expect(code == ["let x = 1", "", "  y"])
        #expect(p.blocks[1].readOnly == nil)
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func anEmptyFencedBlockStillHasSomewhereToType() {
        let p = project("```\n```")
        let anchor = try! #require(p.segments.first { $0.kind == .content })
        #expect(anchor.rendered.length == 0)
        #expect(anchor.source.location == 4)
    }

    @Test func indentedCodeHtmlAndRulesAreNotText() {
        let p = project("<div>\nhi\n</div>\n\n    indented\n\n---\n\npara")
        #expect(p.blocks.map(\.kind) == [.html, .codeBlock(language: nil), .thematicBreak, .paragraph])
        #expect(p.blocks.map(\.readOnly) == [.html, .indentedCode, nil, nil])
        #expect(p.segments.contains { $0.kind == .decoration && $0.block == 2 })
        checkInvariants(p)
    }

    @Test func taskBoxesAreDecorationsOverTheirBrackets() {
        let source = "- [ ] open\n- [x] done\n-\n- plain"
        let p = project(source)
        #expect(p.blocks.map(\.kind) == [.listItem(marker: .task(done: false)),
                                         .listItem(marker: .task(done: true)),
                                         .listItem(marker: .bullet), .listItem(marker: .bullet)])
        let boxes = p.segments.filter { $0.kind == .decoration }.map { slice(p, $0.source) }
        #expect(boxes == ["[ ]", "[x]"])
        #expect(contentSources(p) == ["open", "done", "plain"])
        checkInvariants(p)
        checkSentinels(source)
    }

    @Test func nestedListsGetNestedTextLists() {
        let p = project("3. three\n   - inner\n4. four")
        let style = { (offset: Int) in
            p.rendered.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
        }
        let inner = (p.renderedString as NSString).range(of: "inner").location
        #expect(style(0)?.textLists.count == 1)
        #expect(style(0)?.textLists.first?.startingItemNumber == 3)
        #expect(style(inner)?.textLists.count == 2)
        #expect(p.blocks.map(\.indent) == [0, 1, 0])
    }

    @Test func aShortTableRowIsPaddedWithSeparatorsThatHaveNoSource() {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |\n|  | 2 | 3 |"
        let p = project(source)
        #expect(p.renderedString == "a\tb\tc\n1\t\t\n\t2\t3")
        // The empty first cell of the last row still has an insertion point, inside its padding.
        let empty = p.segments.filter { $0.kind == .content && $0.rendered.length == 0 }
        #expect(empty.map { slice(p, NSRange(location: $0.source.location - 1, length: 2)) } == ["  "])   // between the two padding spaces
        #expect(p.blocks.map(\.readOnly) == [nil])
        checkInvariants(p)
        checkSentinels(source)
    }

    /// A tab the parser expands inside a list item's code block does not survive as a suffix, so
    /// the block is shown — its text intact — and left alone.
    @Test func aBlockThatDoesNotLineUpIsShownReadOnly() {
        let source = "- a\n\n  ```\n\tx\n  ```"
        let p = project(source)
        let code = try! #require(p.blocks.firstIndex { if case .codeBlock = $0.kind { true } else { false } })
        #expect(p.blocks[code].readOnly == .unalignable)
        #expect(renderedSlice(p, p.blocks[code].rendered).hasSuffix("x"))
        checkInvariants(p)
    }

    // MARK: The corpus

    /// The fixed regression inputs: every case above in one place, plus a note-shaped document.
    /// A swift-markdown bump that changes how it reports any of them turns this red.
    static let corpus: [String] = [
        """
        ---
        title: Weeknight pasta
        tags: [dinner]
        ---
        # Weeknight pasta

        Serves **two**, takes *twenty* minutes. See [the notes](notes.md) and `pasta.txt`.
        Salt the water &amp; taste it \\*first\\*.

        ## Ingredients

        - [x] 200 g spaghetti
        - [ ] 2 cloves garlic
          - sliced *thin*
        - plenty of ~~cheddar~~ parmesan

        1. Boil
        2. Toss

           ```swift
           let salt = "plenty"
           ```

        > Don't **rinse** the pasta.
        > It keeps the sauce.

        | Item | Grams | Note |
        |:-----|:-----:|-----:|
        | pasta | 200 | dry \\| fresh |
        | cheese | 40 |

        ---

        ![plate](plate.png)

        <details>
        hidden
        </details>

            indented code
        """,
        "foo\n   bar baz\n\tqux",
        ">   lead *x* y\n>    cont *z*",
        "   indented para *x*\n  cont",
        "foo\\\n   bar *em* x\\\nbaz\n  qux **b**",
        "> a\\\n> b\n> c",
        "a  \n  b\\\n\tc",
        "| a | b \\| c |\n|---|:-:|\n| x \\| y | **z** |",
        "a\\*b &amp; c &#x1F600; d",
        "Café **naïve** 中文 😀 *ok*",
        "x\r\ny **b**\r\n\r\n> q\r\n> r",
        "## Title ##\n\nSetext *heading*\n===",
        "- a\n\n  para two\n    cont *w*\n  - nested\n    more",
        "emph *spans\nlines* ok",
        "| a | b~~ |\n|---|:-:|\n| c | d |",
        "| a |\n|---|\n| *x*\\|*y* \\| z |",
    ]

    @Test(arguments: corpus)
    func theCorpusHoldsTheInvariants(_ source: String) {
        let p = project(source)
        checkInvariants(p)
        #expect(checkSentinels(source) > 0)
    }

    /// The fixture should be editable almost everywhere; a regression that quietly turned blocks
    /// read-only would pass every map test, so count them.
    @Test func theNoteFixtureIsReadOnlyOnlyWhereItShouldBe() {
        let p = project(Self.corpus[0])
        let readOnly = p.blocks.compactMap(\.readOnly)
        #expect(readOnly == [.frontMatter, .html, .indentedCode])
    }

    // MARK: Parity with the read-only preview

    /// Both renderers must show the same words, block for block, so the editable preview cannot
    /// drift from what the read-only one — and PDF export and printing — show.
    @Test(arguments: corpus)
    func theTextMatchesTheReadOnlyPreview(_ source: String) {
        let old = MarkdownBlocks.blocks(from: source)
        let new = project(source)
        #expect(old.count == new.blocks.count, "block counts differ for \(String(reflecting: source))")
        for (before, after) in zip(old, new.blocks) {
            #expect(before.line == after.line)
            #expect(before.indent == after.indent && before.quoteDepth == after.quoteDepth)
            let text = renderedSlice(new, after.rendered)
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            switch (before.kind, after.kind) {
            case (.heading(let a, let words), .heading(let b)):
                #expect(a == b); #expect(words.plain == text)
            case (.paragraph(let words), .paragraph), (.paragraph(let words), .other):
                if !words.plain.contains("🖼") { #expect(words.plain == text) }
            case (.listItem(let a, let words), .listItem(let b)):
                #expect(a == b); #expect(words.plain == text)
            case (.codeBlock(let language, let code), .codeBlock(let other)):
                #expect(language == other)
                #expect(MarkdownProjectionTestsSupport.droppingFinalNewline(code) == text)
            case (.codeBlock("html", let code), .html):
                #expect(MarkdownProjectionTestsSupport.droppingFinalNewline(code) == text)
            case (.table(let header, let rows), .table(let columns)):
                #expect(header.count == columns)
                let words = ([header] + rows).map { $0.map(\.plain).joined(separator: "\t") }
                #expect(words.joined(separator: "\n") == text)
            case (.thematicBreak, .thematicBreak), (.frontMatter, .frontMatter), (.image, .image):
                break
            default:
                Issue.record("kinds differ: \(before.kind) vs \(after.kind)")
            }
        }
    }
}

private enum MarkdownProjectionTestsSupport {
    static func droppingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}

/// TE67.5: how a table is laid out in the editable Preview.
@Suite struct MarkdownProjectionTableLayoutTests {

    // MARK: Table layout (TE67.5)

    private func tableStyle(_ p: MarkdownProjection) -> NSParagraphStyle? {
        let table = p.blocks.firstIndex { if case .table = $0.kind { true } else { false } }
        return table.flatMap { p.rendered.attribute(.paragraphStyle, at: p.blocks[$0].rendered.location,
                                                    effectiveRange: nil) as? NSParagraphStyle }
    }

    /// `:---:` and `---:` are honoured — the read-only preview ignores both — with centre and right
    /// tab stops; the first column is leading-aligned, where every row starts.
    @Test func columnAlignmentBecomesTabStops() throws {
        let p = MarkdownProjection.project("| a | b | c |\n|:--|:-:|--:|\n| one | two | three |")
        let style = try #require(tableStyle(p))
        #expect(style.tabStops.map(\.alignment) == [.center, .right])
    }

    /// Each column is as wide as its widest cell: the stops increase, and the table's right edge is
    /// at least the width of its widest row's cells laid end to end.
    @Test func columnsFitTheirWidestCell() throws {
        let p = MarkdownProjection.project("| a | b |\n|---|---|\n| a much longer cell | x |")
        let style = try #require(tableStyle(p))
        let edges = try #require(p.rendered.attribute(.previewTableColumns, at: p.blocks[0].rendered.location,
                                                      effectiveRange: nil) as? [CGFloat])
        let wide = NSAttributedString(string: "a much longer cell",
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
        #expect(edges.count == 3)
        #expect(edges[1] - edges[0] >= wide)
        #expect(style.tabStops[0].location > wide)
    }

    /// C28: a table that does not fit the column is read-only — drawn, and left to Source.
    @Test func aTableWiderThanTheColumnIsReadOnly() {
        let source = "| a | b | c |\n|---|---|---|\n| some words here | more words here | and more |"
        let narrow = MarkdownProjection.project(source, style: .init(scale: 1, columnWidth: 120))
        let roomy = MarkdownProjection.project(source, style: .init(scale: 1, columnWidth: 2000))
        #expect(narrow.blocks[0].readOnly == .wideTable)
        #expect(roomy.blocks[0].readOnly == nil)
        let typed = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 1, length: 0), text: "x", action: .typing), in: narrow)
        guard case .refuse = typed else { Issue.record("typed into a wide table: \(typed)"); return }
    }
}
