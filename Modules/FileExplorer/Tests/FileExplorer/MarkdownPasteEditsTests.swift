import Testing
import Foundation
import cmark_gfm
@testable import FileExplorer

/// TE55 (a web address pasted onto words) and TE56's text half (where an image's link goes), as
/// pure edits — every case where the paste stays a plain paste is here as much as the one where it
/// does not.
struct MarkdownPasteEditsTests {

    /// `"See «the long-ferment version» for"` → the buffer and the selection.
    private func selecting(_ marked: String) -> (text: String, selection: NSRange) {
        let ns = marked as NSString
        let open = ns.range(of: "«")
        let without = ns.replacingCharacters(in: open, with: "") as NSString
        let close = without.range(of: "»")
        return (without.replacingCharacters(in: close, with: ""),
                NSRange(location: open.location, length: close.location - open.location))
    }

    private func paste(_ pasted: String, over marked: String) -> (String, NSRange)? {
        let (text, selection) = selecting(marked)
        return MarkdownPasteEdits.linkPaste(pasted, over: selection, in: text).map {
            ($0.applied(to: text), $0.selection)
        }
    }

    // MARK: - TE55

    @Test func wordsBecomeALink() throws {
        let result = try #require(paste("https://example.com/sourdough",
                                        over: "See «the long-ferment version» for a weekend."))
        #expect(result.0 == "See [the long-ferment version](https://example.com/sourdough) for a weekend.")
        // The caret after the link, where a plain paste leaves it.
        let link = "See [the long-ferment version](https://example.com/sourdough)" as NSString
        #expect(result.1 == NSRange(location: link.length, length: 0))
    }

    @Test(arguments: [
        "http://example.com",
        "HTTPS://Example.com/a?b=c#d",
        // A trailing newline from the copy is forgiven.
        "https://example.com/x\n",
        "  https://example.com/x  ",
    ])
    func anyOneWebAddressLinks(_ pasted: String) throws {
        let result = try #require(paste(pasted, over: "«word»"))
        #expect(result.0 == "[word](\(pasted.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }

    /// **The spaces a drag took stay outside the link.**
    @Test func edgeWhitespaceStaysOutside() throws {
        #expect(try #require(paste("https://e.com", over: "a« word »b")).0 == "a [word](https://e.com) b")
    }

    /// Wikipedia's addresses carry parentheses; balanced ones are fine bare, an odd one needs `<…>`.
    @Test func parenthesesInTheAddressSurvive() throws {
        #expect(try #require(paste("https://en.wikipedia.org/wiki/Foo_(bar)", over: "«Foo»")).0
                == "[Foo](https://en.wikipedia.org/wiki/Foo_(bar))")
        #expect(try #require(paste("https://e.com/a)b", over: "«x»")).0 == "[x](<https://e.com/a)b>)")
        // And the preview reads both back as the address pasted.
        for text in ["[Foo](https://en.wikipedia.org/wiki/Foo_(bar))", "[x](<https://e.com/a)b>)"] {
            guard case .paragraph(let line)? = MarkdownBlocks.blocks(from: text).first?.kind else {
                Issue.record("not a paragraph: \(text)")
                continue
            }
            #expect(line.runs.first?.link?.hasPrefix("https://") == true, "\(text) did not parse as a link")
        }
    }

    /// **Spaces of every kind stay outside, scalar for scalar** — a no-break space from the web, an
    /// ideographic one between CJK words.
    @Test func everyKindOfEdgeSpaceIsKept() throws {
        #expect(try #require(paste("https://e.com", over: "«price\u{00A0}»list")).0 == "[price](https://e.com)\u{00A0}list")
        #expect(try #require(paste("https://e.com", over: "«東京\u{3000}»大阪")).0 == "[東京](https://e.com)\u{3000}大阪")
        #expect(try #require(paste("https://e.com", over: "a«\u{00A0}word»")).0 == "a\u{00A0}[word](https://e.com)")
    }

    /// **A marker opening the line stays outside the link** — selecting a whole list line or
    /// heading links its words, and the line is still a list item or a heading.
    @Test(arguments: [
        ("«- milk»", "- [milk](https://e.com)"),
        ("«1. milk»", "1. [milk](https://e.com)"),
        ("«- [ ] milk»", "- [ ] [milk](https://e.com)"),
        ("«## Method»", "## [Method](https://e.com)"),
        ("«> quoted»", "> [quoted](https://e.com)"),
        ("  «- milk»", "  - [milk](https://e.com)"),
    ])
    func aBlockMarkerStaysOutside(_ marked: String, _ after: String) throws {
        #expect(try #require(paste("https://e.com", over: marked)).0 == after)
    }

    /// **Every marker on the line, not the first**: a quoted list item stays a quoted list item —
    /// and the preview still draws it as one. A heading's closing `#`s stay outside too.
    @Test(arguments: [
        ("«> - milk»", "> - [milk](https://e.com)"),
        ("> 1. one\n«> 2. two»", "> 1. one\n> 2. [two](https://e.com)"),
        ("«> > deep»", "> > [deep](https://e.com)"),
        ("«# Title #»", "# [Title](https://e.com) #"),
    ])
    func everyMarkerStaysOutside(_ marked: String, _ after: String) throws {
        let result = try #require(paste("https://e.com", over: marked)).0
        #expect(result == after)
        if after.contains("- [milk]") || after.contains("2. [two]") {
            let items = MarkdownBlocks.blocks(from: result).filter {
                if case .listItem = $0.kind { return true } else { return false }
            }
            #expect(!items.isEmpty && items.allSatisfy { $0.quoteDepth == 1 }, "\(result.debugDescription) lost its list")
        }
    }

    /// A combining mark after the marker belongs to the words, and is kept with them.
    @Test func aCombiningMarkAfterTheMarkerIsKept() throws {
        #expect(try #require(paste("https://e.com", over: "«- \u{301}abc»")).0 == "- [\u{301}abc](https://e.com)")
    }

    /// **One address carrying another in its path or query is still one address.**
    @Test(arguments: ["https://web.archive.org/web/2020/https://example.com/",
                      "https://www.google.com/url?q=https://example.com&sa=D"])
    func anAddressInsideAnAddressIsOne(_ pasted: String) throws {
        #expect(try #require(paste(pasted, over: "«word»")).0 == "[word](\(pasted))")
    }

    /// Prose that only looks like syntax is not refused: a `<` in a comparison, a `[` inside a code
    /// span, a closed double-backtick span before the words.
    @Test(arguments: ["a < b «c»", "x <= 5 «y»", "`a[` «b»", "``code with ` inside`` «x»"])
    func proseThatLooksLikeSyntaxStillLinks(_ marked: String) {
        #expect(paste("https://e.com", over: marked) != nil, "\(marked.debugDescription)")
    }

    @Test(arguments: [
        // Not one web address.
        ("ftp://example.com", "«word»"),
        ("mailto:a@b.com", "«word»"),
        ("example.com", "«word»"),
        ("https://", "«word»"),
        ("https://a.com https://b.com", "«word»"),
        ("https://a.com\nhttps://b.com", "«word»"),
        ("see https://a.com", "«word»"),
        ("", "«word»"),
        // Nothing selected.
        ("https://e.com", "wo«»rd"),
        // The selection is itself an address — this is replacing one with another.
        ("https://new.com", "«https://old.com»"),
        ("https://new.com", "«http://old.com/x»"),
        // Across a line, or only whitespace.
        ("https://e.com", "«one\ntwo»"),
        ("https://e.com", "a«   »b"),
        // Brackets, a backtick or a trailing backslash: each ends the link text early or nests a
        // link in a link, which CommonMark does not allow.
        ("https://e.com", "«a] b»"),
        ("https://e.com", "«[a b»"),
        ("https://e.com", "«see [1]»"),
        ("https://e.com", "see `«foo bar` here»"),
        // A backtick the selection holds alone — even parity before it, so only this rule refuses.
        ("https://e.com", "«a `b» c`"),
        ("https://e.com", "«C:\\Temp\\»"),
        // Already inside a link: its address — what Markup ▸ Link… leaves selected for this very
        // paste — its words, an image's source, a reference definition, an autolink.
        ("https://e.com/page", "See [the docs](«url») for more."),
        ("https://cdn.e.com/cat.png", "![a cat](«cat.png»)"),
        ("https://e.com", "[the «docs»](https://a.com)"),
        ("https://e.com", "[docs]: «/old/page»"),
        ("https://e.com", "<«https://old.com»>"),
        // Not one address, run together, or not writable as a destination.
        ("https://a.comhttps://b.com", "«word»"),
        ("https://a.com,https://b.com", "«word»"),
        ("https://e.com/\\", "«word»"),
        ("https://e.com/a\u{07}b", "«word»"),
        ("https://e.com/a>b(", "«word»"),
        // A link whose words wrap onto the next line, and a reference definition in a list.
        ("https://e.com", "See the [installation guide for\n«macOS»](https://example.com)"),
        ("https://e.com", "- [foo]: «/url»"),
        // An address with balanced parentheses, selected inside.
        ("https://e.com", "[w](https://en.wikipedia.org/wiki/Foo_(bar)_«baz»)"),
        // After `!` it would be an image; after `\` its `[` would be escaped.
        ("https://e.com", "Wow!«great»"),
        ("https://e.com", "C:\\Users\\«name»"),
        // Inside a double-backtick code span.
        ("https://e.com", "``a ` «b» c``"),
        // Literal places.
        ("https://e.com", "```\n«code»\n```"),
        ("https://e.com", "para\n\n    «code»"),
        ("https://e.com", "---\ntitle: «x»\n---\n"),
        ("https://e.com", "<div>\n«x»\n</div>"),
        ("https://e.com", "a `co«de»` b"),
    ])
    func everyOtherPasteIsAPlainPaste(_ pasted: String, _ marked: String) {
        #expect(paste(pasted, over: marked) == nil, "\(pasted.debugDescription) over \(marked.debugDescription)")
    }

    /// The positive control for the code-span case: past the span's closing backtick it is prose.
    @Test func afterACodeSpanIsProse() {
        #expect(paste("https://e.com", over: "a `code` «b»") != nil)
    }

    // MARK: - Found by the review of TE55

    /// **A line selected whole — a triple-click takes its line break — is linked**, the break kept
    /// after the link. Before, the break made it a plain paste, which joined the two lines.
    @Test(arguments: [
        ("«- milk\n»- eggs", "- [milk](https://e.com)\n- eggs"),
        ("«- milk\r\n»- eggs", "- [milk](https://e.com)\r\n- eggs"),
        ("«Just words\n»", "[Just words](https://e.com)\n"),
    ])
    func aWholeLineSelectedWithItsBreakIsLinked(_ marked: String, _ expected: String) throws {
        #expect(try #require(paste("https://e.com", over: marked)).0 == expected)
    }

    /// **The line's markers stay outside the link wherever the selection starts** — after a quote's
    /// `> `, and part-way through a marker.
    @Test(arguments: [
        ("> «- milk»", "> - [milk](https://e.com)"),
        ("> «## Title»", "> ## [Title](https://e.com)"),
        ("> > «1. [ ] milk»", "> > 1. [ ] [milk](https://e.com)"),
        ("1«. milk»", "1. [milk](https://e.com)"),
        ("#«# Method»", "## [Method](https://e.com)"),
        ("  - «milk»", "  - [milk](https://e.com)"),
    ])
    func markersStayOutsideTheLinkWhereverTheSelectionStarts(_ marked: String, _ expected: String) throws {
        #expect(try #require(paste("https://e.com", over: marked)).0 == expected)
    }

    /// **A `|` in the address is escaped**, so a table cell is not cut at it — and GFM takes the
    /// escape out before reading the link, as a backslash before punctuation does anywhere else.
    @Test func aPipeInTheAddressIsEscaped() throws {
        let address = "https://fonts.example.com/css?family=Roboto|Open+Sans"
        let table = try #require(paste(address, over: "| a | b |\n|---|---|\n| «milk» | 2 |")).0
        #expect(table == "| a | b |\n|---|---|\n| [milk](https://fonts.example.com/css?family=Roboto\\|Open+Sans) | 2 |")
        guard case .table(_, let rows)? = MarkdownBlocks.blocks(from: table).first?.kind else {
            Issue.record("the table is not a table")
            return
        }
        #expect(rows.first?.count == 2, "the row was cut at the address's |")
        #expect(rows.first?.last?.plain == "2")
        #expect(try #require(paste(address, over: "«milk»")).0 == "[milk](https://fonts.example.com/css?family=Roboto\\|Open+Sans)")
    }

    /// Words that cross a table's cells, or sit inside a link written as HTML, an email autolink
    /// or an HTML tag, are a plain paste.
    @Test(arguments: [
        "| a | b |\n|---|---|\n| «milk | 2» |",
        "<a href=\"https://x.com\">«click»</a>",
        "<A HREF='https://x.com'>see «this» here</A>",
        "<me@«example».com>",
        "<img alt=\"«words»\" src=\"a.png\">",
    ])
    func insideHTMLOrAcrossCellsIsAPlainPaste(_ marked: String) {
        #expect(paste("https://e.com", over: marked) == nil, "\(marked.debugDescription)")
    }

    /// The positive controls: after an HTML link has closed, and beside a `<` that opens no tag.
    @Test func afterAClosedHTMLLinkWordsAreLinked() throws {
        #expect(try #require(paste("https://e.com", over: "<a href=\"x\">a</a> and «b»")).0
                == "<a href=\"x\">a</a> and [b](https://e.com)")
        #expect(try #require(paste("https://e.com", over: "if a < b then «c»")).0 == "if a < b then [c](https://e.com)")
        // A `<` before a letter with no `>` after the words opens no tag either, nor one before a digit.
        #expect(try #require(paste("https://e.com", over: "x <y then «c»")).0 == "x <y then [c](https://e.com)")
        #expect(try #require(paste("https://e.com", over: "Files <10 MB are «inlined»; files >10 MB are linked")).0
                == "Files <10 MB are [inlined](https://e.com); files >10 MB are linked")
    }

    // MARK: - TE56: where the image's line goes

    private func caret(_ marked: String) -> (text: String, range: NSRange) {
        let ns = marked as NSString
        let at = ns.range(of: "|")
        return (ns.replacingCharacters(in: at, with: ""), NSRange(location: at.location, length: 0))
    }

    private func image(_ marked: String, _ links: [String] = ["Images/Pasta-1.jpg"]) -> (String, NSRange)? {
        let (text, range) = caret(marked)
        return MarkdownPasteEdits.imageBlock(links, replacing: range, in: text as NSString)
            .map { ($0.applied(to: text), $0.selection) }
    }

    @Test(arguments: [
        // On a line with words, after the block that line is in — never in the middle of it.
        ("foo|bar", "foobar\n\n![](Images/Pasta-1.jpg)"),
        ("foo|bar\n\nnext", "foobar\n\n![](Images/Pasta-1.jpg)\n\nnext"),
        // A paragraph's lines are one block: after its last.
        ("foo|\nbar", "foo\nbar\n\n![](Images/Pasta-1.jpg)"),
        ("foo\n\n|bar", "foo\n\nbar\n\n![](Images/Pasta-1.jpg)"),
        ("|foo", "foo\n\n![](Images/Pasta-1.jpg)"),
        // An empty line between paragraphs: right there.
        ("foo\n|\nbar", "foo\n\n![](Images/Pasta-1.jpg)\n\nbar"),
        // Blank lines already there are used, not doubled.
        ("foo\n\n|\n\nbar", "foo\n\n![](Images/Pasta-1.jpg)\n\nbar"),
        // Nothing added at the very start or end.
        ("foo|", "foo\n\n![](Images/Pasta-1.jpg)"),
        ("|", "![](Images/Pasta-1.jpg)"),
        // A blank line's own spaces go — four of them would make the image code.
        ("foo\n\n    |\n\nbar", "foo\n\n![](Images/Pasta-1.jpg)\n\nbar"),
        // A Windows file keeps its line ending.
        ("foo|\r\nbar", "foo\r\nbar\r\n\r\n![](Images/Pasta-1.jpg)"),
        ("foo\r\n\r\n|\r\nbar", "foo\r\n\r\n![](Images/Pasta-1.jpg)\r\n\r\nbar"),
    ])
    func theImageIsOnALineOfItsOwn(_ before: String, _ after: String) throws {
        #expect(try #require(image(before)).0 == after)
    }

    /// **The real check: the preview draws it as a picture** — an image paragraph, the only shape
    /// `MarkdownBlocks` turns into one — with the text either side still its own paragraph.
    @Test(arguments: ["foo|bar", "- list item|", "# Heading|\nText", "> quote|", "foo|", "foo\r\n|bar",
                      "- a\n  - b|\n  - c"])
    func thePreviewDrawsWhatWasInserted(_ marked: String) throws {
        let result = try #require(image(marked)).0
        let images = MarkdownBlocks.blocks(from: result).filter {
            if case .image(let source, _) = $0.kind { return source == "Images/Pasta-1.jpg" }
            return false
        }
        #expect(images.count == 1, "\(result.debugDescription) drew \(images.count) pictures")
    }

    @Test func severalImagesAreSeveralPictures() throws {
        let (result, selection) = try #require(image("foo|", ["Images/a-1.png", "Images/a-2.png"]))
        #expect(result == "foo\n\n![](Images/a-1.png)\n\n![](Images/a-2.png)")
        let drawn = MarkdownBlocks.blocks(from: result).filter {
            if case .image = $0.kind { return true } else { return false }
        }
        #expect(drawn.count == 2)
        // The caret after the last link.
        #expect(selection == NSRange(location: (result as NSString).length, length: 0))
    }

    /// A selection is replaced, as any paste replaces it — and the image goes where the caret then
    /// is, by the same rule.
    @Test func aSelectionIsReplaced() throws {
        let text = "keep this, drop this\nand this line"
        let range = NSRange(location: 11, length: 9)
        let splice = try #require(MarkdownPasteEdits.imageBlock(["Images/x-1.png"], replacing: range, in: text as NSString))
        #expect(splice.applied(to: text) == "keep this, \nand this line\n\n![](Images/x-1.png)")
        #expect(splice.selection == NSRange(location: (splice.applied(to: text) as NSString).length, length: 0))
        // A whole line selected: the image takes its place.
        let whole = try #require(MarkdownPasteEdits.imageBlock(["Images/x-1.png"], replacing: NSRange(location: 4, length: 4),
                                                               in: "one\ntwo\n\nthree" as NSString))
        #expect(whole.applied(to: "one\ntwo\n\nthree") == "one\n\n![](Images/x-1.png)\n\nthree")
    }

    /// **A written line no image may break gives no splice at all**: raw HTML, indented code, a code
    /// fence's own line, a link definition, the front matter.
    @Test(arguments: [
        "<p al‸ign=\"center\">\n  <img src=\"x.png\">\n</p>",
        "    let ‸x = 1",
        "``‸`py\ncode\n```",
        "[logo]: https://ex‸ample.com/logo.png",
        "---\nti‸tle: x\n---\n\nBody",
        "<!--\nnote\n-‸->",
    ])
    func aLiteralLineTakesNoImage(_ marked: String) {
        let ns = marked as NSString
        let at = ns.range(of: "‸")
        let text = ns.replacingCharacters(in: at, with: "") as NSString
        #expect(MarkdownPasteEdits.imageBlock(["Images/x-1.png"], replacing: NSRange(location: at.location, length: 0),
                                              in: text) == nil, "\(marked.debugDescription)")
    }

    /// **An image never splits the block it lands in** (review of TE56): a table stays one table,
    /// a heading keeps its words, a quote stays whole — and in a list item, the image joins the item
    /// at its words' column, so the items after it keep their nesting.
    @Test(arguments: [
        ("| a | b |\n|---|---|\n| 1‸ | 2 |\n| 3 | 4 |\n\nafter",
         "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\n![](Images/x-1.png)\n\nafter"),
        // A line straight under a table is one of its rows, to GFM: the image goes after it too.
        ("| a |\n|---|\n| 1‸ |\nmore", "| a |\n|---|\n| 1 |\nmore\n\n![](Images/x-1.png)"),
        ("# Week‸night Pasta\nText", "# Weeknight Pasta\n\n![](Images/x-1.png)\n\nText"),
        ("> quote‸\n> more\n\nafter", "> quote\n> more\n\n![](Images/x-1.png)\n\nafter"),
        ("- a\n  - b‸\n  - c", "- a\n  - b\n\n    ![](Images/x-1.png)\n\n  - c"),
        ("1. a‸\n2. b", "1. a\n\n   ![](Images/x-1.png)\n\n2. b"),
        // A blank line inside an item is the item's; after its last line it is not.
        ("- a\n‸\n  more", "- a\n\n  ![](Images/x-1.png)\n\n  more"),
        ("- a\n‸\n- b", "- a\n\n![](Images/x-1.png)\n\n- b"),
        // A setext heading: after its underline, not after the line the next block opens on — nor
        // past the blank line cmark reports it ending on.
        ("Tit‸le\n=====\nText", "Title\n=====\n\n![](Images/x-1.png)\n\nText"),
        ("Tit‸le\n=====\n\nText", "Title\n=====\n\n![](Images/x-1.png)\n\nText"),
        ("- a\n‸- \n\nText", "- a\n- \n\n![](Images/x-1.png)\n\nText"),
    ])
    func anImageNeverSplitsTheBlockItLandsIn(_ marked: String, _ expected: String) throws {
        // `‸` for the caret: a table's own `|` would be read as one.
        let ns = marked as NSString
        let at = ns.range(of: "‸")
        let text = ns.replacingCharacters(in: at, with: "")
        let splice = try #require(MarkdownPasteEdits.imageBlock(["Images/x-1.png"],
                                                                replacing: NSRange(location: at.location, length: 0),
                                                                in: text as NSString))
        let result = splice.applied(to: text)
        #expect(result == expected)
        // The rest of the document reads as it did — the same words, every item at its depth — and
        // the picture is one block of its own (an image paragraph has no words of its own).
        func shape(_ text: String) -> [String] {
            MarkdownSourceContext.leaves(in: text as NSString).compactMap { leaf in
                leaf.kind == CMARK_NODE_ITEM.rawValue ? "item at \(leaf.depth)" : leaf.text.isEmpty ? nil : leaf.text
            }
        }
        #expect(shape(result) == shape(text), "\(result.debugDescription)")
        let pictures = MarkdownBlocks.blocks(from: result).filter {
            if case .image = $0.kind { return true } else { return false }
        }
        #expect(pictures.count == 1, "\(result.debugDescription) draws \(pictures.count) pictures")
    }
}
