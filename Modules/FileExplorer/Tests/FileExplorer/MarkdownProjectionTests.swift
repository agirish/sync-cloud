import Testing
import Foundation
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport
import EventsTestSupport

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
        // One paragraph per block, except where lines are the block's own: a second paragraph in a
        // list item is a second bullet (review, 2026-10-09).
        for block in p.blocks {
            switch block.kind {
            case .codeBlock, .html, .table: continue
            default: break
            }
            let text = renderedSlice(p, block.rendered)
            #expect(!text.utf16.contains { [0x0A, 0x0D, 0x2029, 0x85].contains($0) },
                    "a paragraph break inside \(block.kind): \(String(reflecting: text))",
                    sourceLocation: sourceLocation)
        }
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

    /// A surrogate without its other half is the U+FFFD the parser is given: three bytes, one unit.
    ///
    /// Mutation: step two units over any high surrogate in `MarkdownSourceIndex.advance`.
    @Test func aLoneSurrogateIsOneUnitOfThreeBytes() {
        let units: [unichar] = [0x61, 0xD800, 0x62, 0xDC00, 0x63, 0xD83D, 0xDE00, 0x64]   // a ? b ? c 😀 d
        let index = MarkdownSourceIndex(NSString(characters: units, length: units.count) as String)
        #expect(index.utf16Offset(line: 1, utf8Column: 5) == 2)      // b, after a and three bytes
        #expect(index.utf16Offset(line: 1, utf8Column: 9) == 4)      // c, after a lone low one too
        #expect(index.utf16Offset(line: 1, utf8Column: 14) == 7)     // d, after the pair's four
        #expect(index.utf8Count(from: 0, to: 8) == 14)
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
    /// **A `>` after four spaces is text, not a quote marker** — `a` then `    >b` reads "a >b" —
    /// and skipping it with the markers lined the line up a unit late, so the paragraph was read-only
    /// (review, 2026-10-09). In a quote, the line's own marker is still skipped.
    ///
    /// Mutation: skip every `>` among the leading whitespace in `InlineLines.contentStart`.
    @Test func aGreaterThanAfterFourSpacesIsText() {
        let source = "a\n    >b *c*\n\n> q\n>     >r *s*"
        let p = project(source)
        #expect(p.blocks.map(\.readOnly) == [nil, nil])
        #expect(contentSources(p) == ["a", ">b ", "c", "q", ">r ", "s"])
        checkInvariants(p)
        #expect(checkSentinels(source) > 0)
    }

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

    /// After a backslash break the parser counts a CRLF as one byte, as it counts every line ending,
    /// so the next line's columns are not shifted by the `\r` (review, 2026-10-09: the paragraph
    /// was read-only).
    ///
    /// Mutation: count a grouped line's terminator at its length in `InlineLines.offset`.
    @Test func aBackslashBreakInACRLFFileMaps() {
        let source = "foo\\\r\nbar *x*\r\nbaz\r\n\r\na\\\r\n  b\\\r\nc *d*"
        let p = project(source)
        #expect(p.blocks.map(\.readOnly) == [nil, nil])
        #expect(contentSources(p) == ["foo", "bar ", "x", "baz", "a", "b", "c ", "d"])
        checkInvariants(p)
        #expect(checkSentinels(source) > 0)
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

    /// The Code Block verb's empty block — a fence, an empty line, a fence — has its empty line to
    /// type on.
    /// The Code Block verb's empty block — a fence, an empty line, a fence — has its empty line to
    /// type on; so does a fence left open at the end of the file with a blank line after it, and an
    /// empty line in a quote, after its marker.
    @Test(arguments: [("```\n\n```", 4, "```\nx\n```"), ("before\n\n```\n", 12, "before\n\n```\nx"),
                      ("> ```\n>\n> ```", 7, "> ```\n>x\n> ```")])
    func anEmptyFencedBlockStillHasSomewhereToType(_ source: String, _ at: Int, _ typed: String) throws {
        let p = project(source)
        let code = try #require(p.blocks.firstIndex { $0.kind.isCode })
        let anchor = try #require(p.segments.first { $0.block == code && $0.kind == .content })
        #expect(anchor.rendered.length == 0)
        #expect(anchor.source.location == at)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: anchor.rendered.location, length: 0), text: "x", action: .typing), in: p)
        guard case .apply(let application) = outcome else { Issue.record("refused: \(outcome)"); return }
        #expect(application.source == typed)
    }

    /// **A fenced block with no line inside offers nowhere to type** — its only lines are fences, and
    /// a point on one wrote into the closing fence, or into the language name of a fence left open
    /// at the end of the file (review, 2026-10-09). The re-read refused each; now nothing is built.
    ///
    /// Mutation: anchor an empty block at the line after its fence, whatever that line is.
    @Test(arguments: ["```\n```\n\nafter", "before\n\n```", "before\n\n```swift"])
    func aFenceWithNoLineInsideHasNoInsertionPoint(_ source: String) throws {
        let p = project(source)
        let code = try #require(p.blocks.firstIndex { $0.kind.isCode })
        #expect(!p.segments.contains { $0.block == code && $0.kind == .content }, "\(String(reflecting: source))")
        let typed = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: p.blocks[code].rendered.location, length: 0), text: "x",
                         action: .typing), in: p)
        guard case .refuse = typed else { Issue.record("typed into \(String(reflecting: source)): \(typed)"); return }
    }

    @Test func indentedCodeHtmlAndRulesAreNotText() {
        let p = project("<div>\nhi\n</div>\n\n    indented\n\n---\n\npara")
        #expect(p.blocks.map(\.kind) == [.html, .codeBlock(language: nil), .thematicBreak, .paragraph])
        #expect(p.blocks.map(\.readOnly) == [.html, .indentedCode, nil, nil])
        #expect(p.segments.contains { $0.kind == .decoration && $0.block == 2 })
        checkInvariants(p)
    }

    /// **Indented code whose first line is a fence is still indented code** — read-only for that
    /// reason, with its text as written — not a fence that failed to line up (review, 2026-10-09).
    ///
    /// Mutation: decide a fence by its first character alone in `codeBlock`.
    @Test(arguments: ["para\n\n    ```foo\n    bar", "    ~~~\n    x", "- a\n\n      ```x\n      y"])
    func indentedCodeStartingWithAFenceIsIndentedCode(_ source: String) throws {
        let p = project(source)
        let code = try #require(p.blocks.last)
        #expect(code.readOnly == .indentedCode)
        #expect(renderedSlice(p, code.rendered).hasPrefix("```") || renderedSlice(p, code.rendered).hasPrefix("~~~"))
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
        "foo\\\r\nbar *x*\r\nbaz\r\n\r\na\\\r\n  b\\\r\nc *d*",
        "## Title ##\n\nSetext *heading*\n===",
        "- a\n\n  para two\n    cont *w*\n  - nested\n    more",
        "emph *spans\nlines* ok",
        "| a | b~~ |\n|---|:-:|\n| c | d |",
        "| a |\n|---|\n| *x*\\|*y* \\| z |",
        "- a <span\nclass=x> b</span>\n- c &#10; d\n- e\u{2029}f",
        "- [ ] see <span\n  class=x>y</span>\n- [x] two",
        "| a\tb | `c\td` |\n|---|---|\n| x | y &#9; z |",
        "a\n    >b *c*\n\n> q\n>     >r *s*",
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

    /// **Which corpus blocks are read-only, and why — every one pinned.** The sentinels skip a
    /// read-only block, and the corpus test passes when one sentinel was checked anywhere, so a
    /// construct that quietly stopped lining up — a CRLF backslash break did (review, 2026-10-09) —
    /// passed both. Each entry: the blocks' reasons in order, then the read-only pieces inside
    /// editable blocks.
    ///
    /// Mutation: count a CRLF after a backslash break as two bytes (P6) — entry 11 turns read-only.
    @Test func everyCorpusBlockIsEditableOrReadOnlyAsPinned() {
        let expected: [(blocks: [PreviewReadOnlyReason?], pieces: [PreviewReadOnlyReason])] = [
            ([.frontMatter] + Array(repeating: nil, count: 14) + [.html, .indentedCode], []),
            ([nil], []), ([nil], []), ([nil], []), ([nil], []), ([nil], []), ([nil], []), ([nil], []), ([nil], []),
            ([nil], []),
            ([nil, nil], []),                       // CRLF
            ([nil, nil], []),                       // CRLF, backslash breaks
            ([nil, nil], []),                       // ATX and setext headings
            ([nil, nil, nil], []),                  // item, its second paragraph, a nested item
            ([nil], []), ([nil], []), ([nil], []),
            ([nil, nil, nil], [.inlineHTML, .inlineHTML]),   // a tag wrapping a line, read-only inside its item
            ([.unalignable, nil], []),              // the tag's continuation is indented: no map, box kept
            ([nil], []),                            // tabs in cells
            ([nil, nil], []),                       // `>` after four spaces
        ]
        #expect(expected.count == Self.corpus.count, "pin every corpus entry")
        for (source, pinned) in zip(Self.corpus, expected) {
            let p = project(source)
            #expect(p.blocks.map(\.readOnly) == pinned.blocks, "\(String(reflecting: source))")
            let pieces = p.segments.compactMap { segment -> PreviewReadOnlyReason? in
                guard p.blocks[segment.block].readOnly == nil, case .readOnly(let reason) = segment.kind else { return nil }
                return reason
            }
            #expect(pieces == pinned.pieces, "\(String(reflecting: source))")
        }
    }

    // MARK: Parity with the read-only preview

    /// Both renderers must show the same words, block for block, so the editable preview cannot
    /// drift from what the read-only one — and PDF export and printing — show.
    @Test(arguments: corpus)
    func theTextMatchesTheReadOnlyPreview(_ source: String) {
        let old = MarkdownBlocks.blocks(from: source)
        let new = project(source)
        #expect(old.count == new.blocks.count, "block counts differ for \(String(reflecting: source))")
        // A paragraph separator the file holds is a line break in both; the editable one writes it
        // as U+2028, to stay one paragraph.
        func plain(_ words: MarkdownText) -> String { words.plain.replacingOccurrences(of: "\u{2029}", with: "\n") }
        for (before, after) in zip(old, new.blocks) {
            #expect(before.line == after.line)
            #expect(before.indent == after.indent && before.quoteDepth == after.quoteDepth)
            let text = renderedSlice(new, after.rendered)
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            switch (before.kind, after.kind) {
            case (.heading(let a, let words), .heading(let b)):
                #expect(a == b); #expect(plain(words) == text)
            case (.paragraph(let words), .paragraph), (.paragraph(let words), .other):
                if !words.plain.contains("🖼") { #expect(plain(words) == text) }
            case (.listItem(let a, let words), .listItem(let b)):
                #expect(a == b); #expect(plain(words) == text)
            case (.codeBlock(let language, let code), .codeBlock(let other)):
                #expect(language == other)
                #expect(MarkdownProjectionTestsSupport.droppingFinalNewline(code) == text)
            case (.codeBlock("html", let code), .html):
                #expect(MarkdownProjectionTestsSupport.droppingFinalNewline(code) == text)
            case (.table(let header, let rows), .table(let columns)):
                #expect(header.count == columns)
                // A tab inside a cell is drawn as a space: tabs are the editable one's columns.
                let words = ([header] + rows).map {
                    $0.map { $0.plain.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
                }
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

    /// **A tab inside a cell is drawn as a space** — drawn as itself it jumped to the next column's
    /// stop, and the grid split the row at it, giving the table a column too many (review,
    /// 2026-10-09). It still maps: what is typed beside it goes beside it in the file.
    ///
    /// Mutation: draw a cell's tab as a tab in `MarkdownProjection`'s `drawn(_:inCell:)`.
    @Test func aTabInACellIsASpaceAndStillMaps() throws {
        let source = "| a\tb | `c\td` |\n|---|---|\n| x | y &#9; z |"
        let p = MarkdownProjection.project(source)
        #expect(p.renderedString == "a b\tc d\nx\ty   z")
        #expect(p.blocks.map(\.readOnly) == [nil])
        let edges = try #require(p.rendered.attribute(.previewTableColumns, at: 0, effectiveRange: nil) as? [CGFloat])
        #expect(edges.count == 3, "two columns and the table's right edge")
        let typed = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 2, length: 0), text: "q", action: .typing), in: p)
        guard case .apply(let application) = typed else { Issue.record("refused: \(typed)"); return }
        #expect(application.source == "| a\tqb | `c\td` |\n|---|---|\n| x | y &#9; z |")
    }

    /// **A `^` cell — a row span to the parser, drawn as nothing — offers nowhere to type**: a
    /// point before the `^` made every keystroke `x^`, which is no span, and was refused. The cells
    /// around it still map.
    ///
    /// Mutation: give a cell that rendered nothing an insertion point whatever it holds.
    @Test func aRowSpanCellHasNoInsertionPoint() {
        let source = "| a | b |\n|---|---|\n| x | y |\n| ^ | z |"
        let p = MarkdownProjection.project(source)
        #expect(p.renderedString == "a\tb\nx\ty\n\tz")
        let caret = (p.renderedString as NSString).range(of: "\tz").location
        #expect(!p.segments.contains { $0.kind == .content && $0.rendered.location == caret })
        let typed = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: caret, length: 0), text: "q", action: .typing), in: p)
        guard case .refuse = typed else { Issue.record("typed into a span: \(typed)"); return }
        let z = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: caret + 2, length: 0), text: "q", action: .typing), in: p)
        guard case .apply(let application) = z else { Issue.record("refused: \(z)"); return }
        // Re-padded, as a tidy table is after an edit: the span is still a span.
        #expect(application.source.contains("zq") && application.source.contains("| ^ "),
                "\(String(reflecting: application.source))")
        #expect(application.projection.renderedString == "a\tb\nx\ty\n\tzq")
    }

    /// **An image in a cell is measured at the size it is drawn**, a placeholder labelled with its
    /// alt: measured empty, the column was too narrow and the placeholder ran into the next one.
    ///
    /// Mutation: leave the projection's image attachment without bounds.
    @MainActor
    @Test func anImageInACellIsMeasuredAsDrawn() throws {
        let p = MarkdownProjection.project("| a | b |\n|---|---|\n| ![a long alt text here](p.png) | z |")
        let edges = try #require(p.rendered.attribute(.previewTableColumns, at: 0, effectiveRange: nil) as? [CGFloat])
        let dressed = NSMutableAttributedString(attributedString: p.rendered)
        PreviewAttachments.dress(dressed, scale: 1, columnWidth: 600)
        let at = (p.renderedString as NSString).range(of: "\u{FFFC}").location
        let attachment = try #require(dressed.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.width > 100)
        #expect(edges[1] - edges[0] >= attachment.bounds.width)
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

/// What the adversarial review of Edit in Preview found in the projection (2026-10-09), each
/// through the session a keystroke takes — the translator, the source, the re-read, the display.
@MainActor
@Suite struct MarkdownProjectionReviewTests {

    private func session(_ text: String) -> (PreviewEditSession, EditorSourceStorage) {
        let source = EditorSourceStorage(text: text)
        return (PreviewEditSession(source: source, undoManager: UndoManager()), source)
    }

    private func rendered(_ needle: String, in session: PreviewEditSession, plus: Int = 0) -> Int {
        let found = (session.projection.renderedString as NSString).range(of: needle)
        precondition(found.location != NSNotFound, "\(needle) not in \(session.projection.renderedString)")
        return found.location + plus
    }

    /// The display's paragraph holding rendered `offset`: its style, and its list item's number as
    /// TextKit counts it — the item's place in the unbroken run of paragraphs carrying its list,
    /// from the list's own first number.
    private func drawn(_ session: PreviewEditSession, at offset: Int)
        -> (style: NSParagraphStyle?, number: Int?, attributes: [NSAttributedString.Key: Any]) {
        let display = session.display
        let paragraph = (display.string as NSString).paragraphRange(for: NSRange(location: offset, length: 0))
        let attributes = display.attributes(at: paragraph.location, effectiveRange: nil)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        let number = style?.textLists.last.map {
            $0.startingItemNumber + display.itemNumber(in: $0, at: paragraph.location) - 1
        }
        return (style, number, attributes)
    }

    // MARK: A fence opened on a list marker's line

    /// **A fence on the marker's line: a new line of code gets the item's indent, not its marker.**
    /// The prefix was what stood before the backticks, as written — `- ` — and every new line written
    /// with it was a new list item, so Return in the code was refused.
    ///
    /// Mutation: copy the fence line's prefix as written in `codeBlock`.
    @Test(arguments: [("- ```swift\n  let x = 1\n  ```", "  "),
                      ("1. ```swift\n   let x = 1\n   ```", "   "),
                      ("> - ```swift\n>   let x = 1\n>   ```", ">   ")])
    func returnInCodeOpenedOnAMarkerLineStaysInTheBlock(_ text: String, _ indent: String) {
        let (session, source) = session(text)
        let caret = rendered("let x = 1", in: session, plus: 9)
        session.perform(RenderedEdit(range: NSRange(location: caret, length: 0), action: .returnKey))
        #expect(source.text == text.replacingOccurrences(of: "let x = 1\n", with: "let x = 1\n\(indent)\n"))
        session.perform(RenderedEdit(range: NSRange(location: caret + 1, length: 0), text: "y", action: .typing))
        #expect(source.text == text.replacingOccurrences(of: "let x = 1\n", with: "let x = 1\n\(indent)y\n"))
        #expect(session.projection.renderedString.hasSuffix("let x = 1\ny"))
    }

    /// The same prefix goes on a blank line typed into, and after each line of a pasted run.
    @Test func typingOnABlankLineAndPastingInAMarkerLineFenceKeepTheItem() {
        let (session, source) = session("- ```\n  a\n\n  b\n  ```")
        session.perform(RenderedEdit(range: NSRange(location: rendered("a\n", in: session, plus: 2), length: 0),
                                     text: "x", action: .typing))
        #expect(source.text == "- ```\n  a\n  x\n  b\n  ```")
        session.perform(RenderedEdit(range: NSRange(location: rendered("b", in: session, plus: 1), length: 0),
                                     text: "\nc\nd", action: .paste))
        #expect(source.text == "- ```\n  a\n  x\n  b\n  c\n  d\n  ```")
    }

    // MARK: An empty block's line

    /// **Return in a numbered list: the new, empty item is drawn as an item** — numbered, indented,
    /// and the items after it numbered on from it. Its line is the next item's break, which had no
    /// attributes, so the line had no list and TextKit counted the rest from 1 again.
    ///
    /// Mutation: give a block that rendered nothing no attributes in `endBlock`.
    @Test func anEmptyItemMadeByReturnIsNumberedAndTheListCountsOn() {
        let (session, source) = session("1. a\n2. b\n3. c")
        session.perform(RenderedEdit(range: NSRange(location: rendered("a", in: session, plus: 1), length: 0),
                                     action: .returnKey))
        #expect(source.text.hasPrefix("1. a\n2. \n"), "Return writes an empty item: \(String(reflecting: source.text))")
        let empty = rendered("a", in: session, plus: 2)
        let line = drawn(session, at: empty)
        #expect(line.number == 2)
        #expect((line.style?.headIndent ?? 0) == (drawn(session, at: 0).style?.headIndent ?? -1),
                "the empty item's caret sits where its words will")
        #expect(drawn(session, at: rendered("b", in: session)).number == 3)
        #expect(drawn(session, at: rendered("c", in: session)).number == 4)
    }

    /// The other empty blocks the verbs make: a heading still at its size, a quote with its bar, a
    /// code block with its band — each on the break that is its line.
    @Test func anEmptyHeadingQuoteAndCodeBlockAreDrawnAsWhatTheyAre() {
        let (session, _) = session("## \n\nafter one\n\n> \n\nafter two\n\n```\n```\n\nafter three")
        let heading = drawn(session, at: 0).attributes
        #expect((heading[.font] as? NSFont)?.pointSize == MarkdownBlockView.headingSize(2))
        #expect(heading[.previewBlock] as? String == "heading")
        let quote = drawn(session, at: rendered("after one", in: session, plus: 10)).attributes
        #expect((quote[.previewQuoteBars] as? [CGFloat])?.count == 1)
        let code = drawn(session, at: rendered("after two", in: session, plus: 10)).attributes
        #expect(code[.previewBlock] as? String == "code")
        #expect((code[.font] as? NSFont)?.isFixedPitch == true)
        // The block after each keeps its own look.
        #expect(drawn(session, at: rendered("after three", in: session)).attributes[.previewBlock] as? String == "paragraph")
    }

    // MARK: Numbering after a break in an item

    /// **An item after a second paragraph, a code block or a task is still numbered as the parser
    /// numbers it.** TextKit counts only the unbroken run of paragraphs carrying the list, and each
    /// of these sits between two items without it — `2.` was drawn `1.`. The read-only Preview drew
    /// the parser's number. Read from the display as TextKit counts it, not from the projection.
    ///
    /// Mutation: never start a new list in the ordered-list arm of `append`.
    @Test(arguments: ["1. a\n\n   more\n2. b\n3. c",
                      "1. a\n   ```\n   x\n   ```\n2. b\n3. c",
                      "1. [ ] a\n2. b\n3. c",
                      "1. a\n   > q\n2. b\n3. c"])
    func anItemAfterABreakInTheListKeepsItsNumber(_ text: String) {
        let (session, _) = session(text)
        #expect(drawn(session, at: rendered("b", in: session)).number == 2, "in \(String(reflecting: text))")
        #expect(drawn(session, at: rendered("c", in: session)).number == 3, "in \(String(reflecting: text))")
        // And still, once typing in the item has gone through the partial re-read and the splice.
        session.perform(RenderedEdit(range: NSRange(location: rendered("b", in: session, plus: 1), length: 0),
                                     text: "z", action: .typing))
        #expect(drawn(session, at: rendered("bz", in: session)).number == 2, "typed in \(String(reflecting: text))")
        #expect(drawn(session, at: rendered("c", in: session)).number == 3, "typed in \(String(reflecting: text))")
    }

    /// Nested items do not break their parent's run — the item after them is one list with the one
    /// before, as it always was, and typing in it is not a new list each time.
    @Test func anItemAfterANestedListStaysInItsList() {
        let (session, _) = session("3. a\n   1. x\n   2. y\n4. b")
        let a = drawn(session, at: 0), b = drawn(session, at: rendered("b", in: session))
        #expect(a.number == 3 && b.number == 4)
        #expect(drawn(session, at: rendered("y", in: session)).number == 2)
        #expect(a.style?.textLists.first === b.style?.textLists.first)
    }

    // MARK: One block, one paragraph

    /// **A newline inside one block's rendering made it two paragraphs — in a list, two bullets.**
    /// Three ways in: a tag wrapping a line, an entity decoding to a newline, and a read-only item's
    /// fallback text; and a U+2029 in the file, which the parser keeps and the text system ends a
    /// paragraph at.
    ///
    /// Mutation: render inline HTML's `rawHTML` as written; separately, compare an entity's decode
    /// unswapped in `align`.
    @Test(arguments: ["- a <span\nclass=x> b</span>\n- c", "- a &#10; b\n- c",
                      "- [ ] see <span\n  class=x>y</span>\n- c", "- a\u{2029}b\n- c"])
    func aNewlineInsideAnItemIsNoSecondBullet(_ text: String) {
        let (session, _) = session(text)
        let display = session.display.string as NSString
        var paragraphs = 0, at = 0
        while at < display.length {
            at = NSMaxRange(display.paragraphRange(for: NSRange(location: at, length: 0)))
            paragraphs += 1
        }
        #expect(paragraphs == 2, "\(paragraphs) paragraphs drawn for two items in \(String(reflecting: text))")
    }

    /// The entity and the U+2029 still map: typing after them goes where it is typed.
    @Test func textAfterANewlineEntityOrAParagraphSeparatorStillMaps() {
        for text in ["- a &#10; b", "- a\u{2029}b"] {
            let (session, source) = session(text)
            #expect(session.projection.blocks[0].readOnly == nil, "\(String(reflecting: text))")
            session.perform(RenderedEdit(range: NSRange(location: rendered("b", in: session), length: 0),
                                         text: "z", action: .typing))
            #expect(source.text == text.replacingOccurrences(of: "b", with: "zb"))
        }
    }

    // MARK: A read-only task item

    /// **A task item that cannot be edited here keeps its box, and the box still ticks** — as it did
    /// in the read-only Preview, and as a box on any other item does: the tick is three characters
    /// the translator checks by re-reading, whatever the words after it are.
    ///
    /// Mutation: pass no `box` to `readOnlyBlock` from `listItem`.
    @Test func aReadOnlyTaskItemKeepsItsBoxAndTicks() throws {
        let (session, source) = session("- [ ] see <span\n  class=x>y</span>\n- [x] two")
        let p = session.projection
        #expect(p.blocks[0].readOnly == .unalignable)
        let box = try #require(p.segments.first { $0.block == 0 && $0.kind == .decoration })
        #expect((p.source as NSString).substring(with: box.source) == "[ ]")
        #expect(session.display.attribute(.previewAttachment, at: box.rendered.location, effectiveRange: nil) as? String == "task")
        session.perform(RenderedEdit(range: box.rendered, action: .tickTask))
        #expect(source.text == "- [x] see <span\n  class=x>y</span>\n- [x] two")
    }

    // MARK: A table too wide to edit

    /// **A table too wide for the column says so under the pointer**, as every other read-only
    /// block does: the mark that gives the arrow and the tooltip was set before the table was found
    /// too wide, and never after.
    ///
    /// Mutation: drop the `.previewReadOnly` mark from `layOutColumns`.
    @Test func aTableTooWideToEditCarriesTheReadOnlyMark() {
        let text = "| a | b | c |\n|---|---|---|\n| some words here | more words here | and more |"
        for (width, wide) in [(CGFloat(120), true), (2000, false)] {
            let source = EditorSourceStorage(text: text)
            let session = PreviewEditSession(source: source, undoManager: UndoManager(),
                                             style: .init(scale: 1, columnWidth: width))
            let at = rendered("more words", in: session)
            #expect((session.display.attribute(.previewReadOnly, at: at, effectiveRange: nil) != nil) == wide)
            #expect((session.display.attribute(.toolTip, at: at, effectiveRange: nil) as? String
                     == PreviewEditSession.readOnlyTip) == wide)
        }
    }

    // MARK: An image's alt text

    private func imageAttachment(in session: PreviewEditSession, _ kind: String = "image") -> NSTextAttachment? {
        let display = session.display
        for i in 0..<display.length where display.attribute(.previewAttachment, at: i, effectiveRange: nil) as? String == kind {
            return display.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment
        }
        return nil
    }

    /// Waits on the main actor, which the image's load needs, for `done`.
    private func wait(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// **VoiceOver reads an image's alt text, and a picture that cannot be shown leads with it** —
    /// as the read-only Preview did; the editable one said "Image" for every picture, and
    /// "Image — reason" for a missing one.
    ///
    /// Mutation: make the projection's image attachments plain `NSTextAttachment`s.
    @Test func anImageIsDescribedByItsAltText() async throws {
        let (session, _) = session("![a cat asleep](https://example.com/a.png)\n\nsee ![the dog](d.png) here\n\n![](https://example.com/b.png)")
        session.documentFolder = "/tmp"
        let inline = try #require(imageAttachment(in: session, "inlineImage"))
        #expect(inline.image?.accessibilityDescription == "the dog")
        let block = try #require(imageAttachment(in: session))
        await wait { block.image?.accessibilityDescription?.hasPrefix("a cat asleep — ") == true }
        let described = block.image?.accessibilityDescription ?? ""
        #expect(described.hasPrefix("a cat asleep — ") && described.count > "a cat asleep — ".count,
                "the alt, then why: \(described)")
    }

    /// A picture that loads is described by its alt, and one decoded picture shown twice keeps each
    /// alt to itself.
    @Test func aLoadedPictureIsDescribedByItsOwnAlt() async throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let folder = (note as NSString).deletingLastPathComponent
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/AltPic.png"))
        let source = EditorSourceStorage(text: "![first](AltPic.png)\n\n![second](AltPic.png)")
        let session = PreviewEditSession(source: source, undoManager: UndoManager(), documentFolder: folder)
        var pictures: [NSTextAttachment] = []
        session.display.enumerateAttribute(.attachment, in: NSRange(location: 0, length: session.display.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { pictures.append(attachment) }
        }
        try #require(pictures.count == 2)
        await wait { pictures.allSatisfy { $0.image?.size == CGSize(width: 20, height: 10) } }
        #expect(pictures.map { $0.image?.size } == [CGSize(width: 20, height: 10), CGSize(width: 20, height: 10)])
        #expect(pictures.map { $0.image?.accessibilityDescription } == ["first", "second"])
    }

    // MARK: What the fragments draw, from the block's own indent

    /// The display laid out on TextKit 2 with the view's own fragment delegate, each fragment drawn
    /// into a light-mode bitmap: the fragments, their frames, and the pixels.
    private func render(_ session: PreviewEditSession, width: CGFloat = 500)
        -> (fragments: [(fragment: PreviewBlockFragment, frame: CGRect)], ink: (Int, Int) -> Bool,
            brightness: (Int, Int) -> CGFloat) {
        let content = NSTextContentStorage()
        content.attributedString = NSAttributedString(attributedString: session.display)
        let manager = NSTextLayoutManager()
        let delegate = PreviewFragmentDelegate()
        manager.delegate = delegate
        content.addTextLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        var fragments: [(PreviewBlockFragment, CGRect)] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let block = fragment as? PreviewBlockFragment { fragments.append((block, block.layoutFragmentFrame)) }
            return true
        }
        let height = Int(ceil(fragments.map { $0.1.maxY }.max() ?? 1))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: CGFloat(height)))
            // TextKit draws top-down.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            for (fragment, frame) in fragments { fragment.draw(at: frame.origin, in: context) }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Rows counted from the top, as the frames are.
        let brightness = { (x: Int, y: Int) -> CGFloat in
            guard let color = bitmap.colorAt(x: x, y: y) else { return 1 }
            return min(color.redComponent, color.greenComponent, color.blueComponent)
        }
        return (fragments, { x, y in brightness(x, y) < 0.995 }, brightness)
    }

    /// **A quote in a list item has its bar at the item's text, and a code block its band from
    /// there** — both were drawn from the column's left edge, out under the bullets. Read from the
    /// pixels: nothing drawn left of the item's text on those lines, and the bar and band where the
    /// item's text starts.
    ///
    /// Mutation: draw the code band from the fragment's left edge; separately, give a quote's bar the
    /// list indent 0 in `quoteBars`.
    @Test func aQuoteAndCodeInAListItemAreDrawnFromTheItemsText() throws {
        let (session, _) = session("- item\n\n  > quoted words\n\n  ```\n  let code = 1\n  ```")
        let (fragments, ink, _) = render(session)
        let quote = try #require(fragments.first { !$0.fragment.quoteBars.isEmpty })
        let code = try #require(fragments.first { $0.fragment.isCode })
        // One list level in — the item's text — and two points into the gap the quote leaves.
        #expect(quote.fragment.quoteBars == [22 + 2])
        for (name, part) in [("quote", quote), ("code", code)] {
            let rows = Int(part.frame.minY) + 1..<Int(part.frame.maxY) - 1
            let leftOfItem = rows.contains { y in (0..<20).contains { ink($0, y) } }
            #expect(!leftOfItem, "\(name): drawn under the bullets")
        }
        let mid = Int(quote.frame.midY), codeMid = Int(code.frame.midY)
        #expect((24..<27).allSatisfy { ink($0, mid) }, "the bar, two points into the item's text")
        #expect(ink(480, codeMid), "the band runs on to the column's edge")
    }

    /// **Nesting is drawn no deeper than the read-only Preview draws it** — six levels, then the
    /// same inset — so a forwarded thread fifteen `>` deep keeps a column to read in.
    ///
    /// Mutation: drop `drawnDepth` from the quote term in `paragraphStyle`; separately, from
    /// `quoteBars`.
    @Test func deepNestingIsCappedAtTheDepthTheReadOnlyPreviewDraws() throws {
        let deep = String(repeating: ">", count: 12) + " deep words"
        let (session, _) = session("\(deep)\n\n" + (0..<9).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n"))
        let quote = drawn(session, at: rendered("deep", in: session))
        #expect(quote.style?.headIndent == CGFloat(MarkdownBlockView.maxNestingDrawn) * 14)
        #expect((quote.attributes[.previewQuoteBars] as? [CGFloat])?.count == MarkdownBlockView.maxNestingDrawn)
        let six = drawn(session, at: rendered("level 6", in: session)).style?.headIndent
        #expect(six == CGFloat(MarkdownBlockView.maxNestingDrawn + 1) * 22)
        #expect(drawn(session, at: rendered("level 8", in: session)).style?.headIndent == six)
        // The model keeps the true depth: it is what an edit's prefix is made of.
        #expect(session.projection.blocks[0].quoteDepth == 12)
        let (fragments, _, _) = render(session)
        #expect(fragments.first?.fragment.quoteBars.count == MarkdownBlockView.maxNestingDrawn)
    }

    /// **A rule in a list item spans the column from the item's text**, not the column's whole width
    /// from there — it ran past the edge by the indent. Again after the column changes.
    ///
    /// Mutation: size a rule to the whole column in `PreviewAttachments.dress(_:scale:columnWidth:)`.
    @Test func aRuleInAListItemFitsTheColumnFromItsIndent() throws {
        let (session, _) = session("- item\n\n  ***\n\n- after")
        func rule() throws -> (width: CGFloat, lead: CGFloat) {
            let display = session.display
            let at = try #require((0..<display.length).first {
                display.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "rule" })
            let attachment = try #require(display.attribute(.attachment, at: at, effectiveRange: nil) as? NSTextAttachment)
            let lead = (display.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            return (attachment.bounds.width, lead)
        }
        let first = try rule()
        #expect(first.lead > 0)
        #expect(first.width + first.lead <= session.columnWidth)
        session.columnWidth = 300
        let second = try rule()
        #expect(second.width + second.lead <= 300)
    }

    // MARK: Smaller things

    /// **A code span or a tag that wraps a line is read-only inside an editable paragraph, and says
    /// so under the pointer** — the keystroke there was refused with no warning before it.
    ///
    /// Mutation: drop the mark `appendText` puts on a read-only segment.
    @Test func aReadOnlyPieceOfAParagraphCarriesTheMark() {
        let (session, _) = session("first `code\nspan` mid <span\nclass=x> last")
        for (needle, readOnly) in [("first", false), ("code", true), ("mid", false), ("class", true), ("last", false)] {
            let at = rendered(needle, in: session)
            #expect((session.display.attribute(.previewReadOnly, at: at, effectiveRange: nil) != nil) == readOnly, "\(needle)")
            #expect((session.display.attribute(.toolTip, at: at, effectiveRange: nil) as? String
                     == PreviewEditSession.readOnlyTip) == readOnly, "\(needle)")
        }
        #expect(session.projection.blocks[0].readOnly == nil)
    }

    // MARK: The log

    /// **A projection with parts read-only for want of a map says how many, and why** — one line,
    /// counts only. Nothing said so before, and "Preview won't let me type here" had nothing in the
    /// log to go on.
    ///
    /// Mutation: drop the `logReadOnly` call from `project(_:style:)`.
    @Test func readOnlyPartsAreCountedInTheLog() async {
        let log = LogCapture()
        let note = "- [ ] see <span\n  class=x>y</span>\n\nfirst `code\nspan` mid\n\n<div>\nx\n</div>\n\n"
            + "| a | b | c |\n|---|---|---|\n| some words here | more words here | and more |"
        _ = MarkdownProjection.project(note, style: .init(scale: 1, columnWidth: 120))
        #expect(await log.holds(containing:
            "[edit] Preview projection (note, 4 blocks) has read-only parts: multilineCode 1, unalignable 1, wideTable 1"))
    }

    // MARK: Parity with the read-only Preview's look

    /// **A code block's language is drawn above it, and an HTML block has the code band** — as the
    /// read-only Preview draws both. The language is drawn by the fragment, in room left above the
    /// first line: it is in no rendered character, so nothing can type into it.
    ///
    /// Mutation: drop the language from `PreviewFragmentDelegate`; separately, the `html` tag from
    /// its band.
    @Test func aCodeBlocksLanguageIsDrawnAndAnHTMLBlockHasTheBand() throws {
        let (session, _) = session("Intro\n\n```swift\nlet x = 1\nlet y = 2\n```\n\n<div>\nhi\n</div>")
        #expect(!session.projection.renderedString.contains("swift"))
        let (fragments, ink, brightness) = render(session)
        let code = fragments.filter { $0.fragment.isCode }
        #expect(code.count == 5, "two code lines and three HTML lines on the band")
        #expect(code.map(\.fragment.language) == ["swift", nil, nil, nil, nil])
        let first = try #require(code.first)
        let label = (Int(first.frame.minY) + 3..<Int(first.frame.minY) + 11)
        // Darker than the band, where the name is drawn; nothing but the band where it is not.
        #expect(label.contains { y in (2..<30).contains { x in brightness(x, y) < brightness(480, y) - 0.1 } },
                "the language is drawn above the first line")
        let html = try #require(code.last)
        #expect(ink(480, Int(html.frame.midY)), "the band behind the HTML block")
        // A note that opens with code has no room above it — TextKit drops the first paragraph's
        // spacing — so the name is not drawn on top of the code.
        let (opening, _) = self.session("```swift\nlet x = 1\n```")
        let top = try #require(render(opening).fragments.first)
        #expect(top.fragment.language == "swift")
        let bare = render(self.session("```\nlet x = 1\n```").0)
        let labelled = render(opening)
        let rows = 0..<Int(top.frame.maxY), columns = 0..<60
        #expect(rows.allSatisfy { y in columns.allSatisfy { x in labelled.brightness(x, y) == bare.brightness(x, y) } },
                "drawn over the first line")
    }

    // MARK: The partial re-read

    /// **An empty item's line keeps its list through a partial re-read.** Its line is the break
    /// after it — outside the stretch re-read — and holds the list as it was. An edit that changed
    /// only attributes above — a link's target — was taken to differ all the way to the stretch's
    /// end, which then took a new list while that break kept the old: one list, split in two, and
    /// TextKit numbering the empty item from 1 (seed 6880 of the reuse property test, once empty
    /// items carried their list).
    ///
    /// Mutation: measure the characters' suffix before the prefix is pulled back, in
    /// `PreviewAttributeShape.difference`.
    @Test func anEmptyItemsLineKeepsItsListThroughAPartialReRead() throws {
        let old = MarkdownProjection.project("[x](http://a)\n\n1. a\n2. \n\nend")
        let new = "[x](http://ab)\n\n1. a\n2. \n\nend"
        let partial = try #require(try? old.reread(new).get())
        let text = partial.renderedString as NSString
        func list(_ at: Int) -> NSTextList? {
            (partial.rendered.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first
        }
        // "a", the break that ends its line, then the empty item's line: the break before "end".
        let item = text.range(of: "a\n").location, emptyLine = item + 2
        #expect(list(item) != nil && list(item) === list(emptyLine))
        #expect(MarkdownProjectionReuseTests.sameLists(partial.rendered, MarkdownProjection.project(new).rendered))
    }
}
