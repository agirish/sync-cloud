import Testing
import Foundation
@testable import FileExplorer

/// Edits made in the editable preview, translated into edits of the Markdown source (TE67 §3.4–3.6).
///
/// **Each case states the SOURCE it must produce**, not just that something was accepted: the
/// claim is about the file on disk, which is what the person audits.
@Suite struct PreviewEditTranslatorTests {

    // MARK: Helpers

    private func project(_ source: String) -> MarkdownProjection { MarkdownProjection.project(source) }

    /// Where `needle` starts in the rendered text, plus `plus`.
    private func at(_ needle: String, in p: MarkdownProjection, plus: Int = 0) -> Int {
        let found = (p.renderedString as NSString).range(of: needle)
        precondition(found.location != NSNotFound, "\(needle) not in \(p.renderedString)")
        return found.location + plus
    }

    private func after(_ needle: String, in p: MarkdownProjection) -> Int {
        at(needle, in: p, plus: (needle as NSString).length)
    }

    private func type(_ text: String, at caret: Int, in source: String,
                      context: PreviewEditContext = PreviewEditContext()) -> PreviewEditOutcome {
        PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: caret, length: 0), text: text, action: .typing),
            in: project(source), context: context)
    }

    private func applied(_ outcome: PreviewEditOutcome,
                         sourceLocation: SourceLocation = #_sourceLocation) -> PreviewEditApplication? {
        guard case .apply(let application) = outcome else {
            Issue.record("expected the edit to apply, got \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return application
    }

    private func refusal(_ outcome: PreviewEditOutcome) -> PreviewRefusal? {
        if case .refuse(let reason, _, _) = outcome { return reason }
        return nil
    }

    // MARK: Typing (A1) and escaping

    /// C1: a `*` that would close emphasis is written escaped — and only because the parser said
    /// the bare one rendered differently.
    @Test func anAsteriskThatWouldMakeEmphasisIsEscaped() {
        let source = "x *y"
        let p = project(source)
        let result = applied(type("*", at: after("y", in: p), in: source))
        #expect(result?.source == "x *y\\*")
        #expect(result?.projection.renderedString == "x *y*")
    }

    /// No escape table is guessed: a `*` the parser leaves alone goes in bare.
    @Test func anAsteriskThatStaysLiteralIsNotEscaped() {
        let source = "a b"
        let p = project(source)
        let result = applied(type("*", at: after("a", in: p), in: source))
        #expect(result?.source == "a* b")
    }

    @Test func typingIntoAnEmptyFileWritesIt() {
        let result = applied(type("Hello", at: 0, in: ""))
        #expect(result?.source == "Hello")
        #expect(result?.undo == .typing)
    }

    /// C2: an intraword `_` is not emphasis to the parser, so it goes in bare.
    @Test func anUnderscoreInsideAWordIsNotEscaped() {
        let source = "snake case"
        let p = project(source)
        let result = applied(type("_", at: after("snake", in: p), in: source))
        // "snake_ case" — the underscore is not followed by a letter yet, and still renders bare.
        #expect(result?.source == "snake_ case")
    }

    /// C3: typing at the end of bold continues the bold.
    @Test func typingAtTheEndOfBoldContinuesIt() {
        let source = "Use **plenty** of"
        let p = project(source)
        let result = applied(type("!", at: after("plenty", in: p), in: source))
        #expect(result?.source == "Use **plenty\\!** of" || result?.source == "Use **plenty!** of")
        let typed = applied(type("x", at: after("plenty", in: p), in: source))
        #expect(typed?.source == "Use **plentyx** of")
    }

    /// C4: at the end of a link's text, typing goes after the `)` — not into the link.
    @Test func typingAtTheEndOfALinkGoesOutsideIt() {
        let source = "See [the docs](http://x.y) now"
        let p = project(source)
        let result = applied(type("x", at: after("the docs", in: p), in: source))
        #expect(result?.source == "See [the docs](http://x.y)x now")
    }

    @Test func typingAtTheStartOfASpanStaysOutsideIt() {
        let source = "**bold** rest"
        let p = project(source)
        let result = applied(type("x", at: 0, in: source))
        #expect(result?.source == "x**bold** rest")
    }

    @Test func aStraightQuoteTypedIsKeptStraightInTheFile() {
        let source = "Dont stop"
        let p = project(source)
        let result = applied(type("'", at: after("Don", in: p), in: source))
        // The file gets the straight quote; the preview shows the parser's curly one.
        #expect(result?.source == "Don't stop")
        #expect(result?.projection.renderedString == "Don’t stop")
    }

    @Test func typingInAContinuationLineLandsPastItsIndent() {
        let source = "> one\n>    two"
        let p = project(source)
        let result = applied(type("x", at: at("two", in: p), in: source))
        #expect(result?.source == "> one\n>    xtwo")
    }

    @Test func theCaretComesBackAfterTheTypedText() {
        let source = "x *y"
        let p = project(source)
        let result = applied(type("*", at: after("y", in: p), in: source))
        // Rendered "x *y*" with the caret after the typed "*"; in the source, after "\\*".
        #expect(result?.renderedSelection == NSRange(location: 5, length: 0))
        #expect(result?.sourceSelection == NSRange(location: 6, length: 0))
    }

    // MARK: Deleting (A2)

    /// C5: deleting across a span's edge removes characters and keeps the markers.
    @Test func deletingAcrossBoldKeepsItsMarkers() {
        let source = "Use **plenty** of parmesan"
        let p = project(source)
        let from = at("nty", in: p)
        let to = after("of", in: p)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: from, length: to - from), action: .delete), in: p))
        #expect(result?.source == "Use **ple** parmesan")
    }

    /// C6: deleting all of a bold word takes its markers with it — no `****` left behind.
    @Test func deletingAllOfASpanRemovesItsMarkers() {
        let source = "Use **plenty** of"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("plenty", in: p), length: 6), action: .delete),
            in: p))
        #expect(result?.source == "Use  of")
    }

    @Test func typingOverAllOfABoldWordKeepsItBold() {
        let source = "Use **plenty** of"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("plenty", in: p), length: 6), text: "lots",
                         action: .typing), in: p))
        #expect(result?.source == "Use **lots** of")
    }

    /// C22: the rendered `&` is the whole `&amp;`.
    @Test func deletingARenderedEntityDeletesAllOfIt() {
        let source = "salt &amp; pepper"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("&", in: p), length: 1), action: .delete), in: p))
        #expect(result?.source == "salt  pepper")
    }

    @Test func deletingASoftBreakJoinsTheLines() {
        let source = "one\ntwo"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 3, length: 1), action: .delete), in: p))
        #expect(result?.source == "onetwo")
    }

    /// C12: Backspace at a block's start would join two blocks.
    @Test func backspaceAtABlocksStartIsRefused() {
        let source = "one\n\ntwo"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 3, length: 1), action: .delete), in: p)
        #expect(refusal(outcome) == .joinsBlocks)
    }

    /// C13: a selection across two paragraphs.
    @Test func typingOverTwoParagraphsIsRefused() {
        let source = "one\n\ntwo"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 1, length: 4), text: "x", action: .typing), in: p)
        #expect(refusal(outcome) == .crossesBlocks)
    }

    @Test func readOnlyBlocksRefuseWithTheirReason() {
        let source = "<div>\nhi\n</div>"
        let outcome = type("x", at: 1, in: source)
        #expect(refusal(outcome) == .readOnly(.html))
    }

    // MARK: Formatting (A3, A4)

    /// C7: ⌘B on a rendered bold word takes the bold off in the source.
    @Test func boldOnABoldWordRemovesIt() {
        let source = "Use **plenty** of"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("plenty", in: p), length: 6), action: .format(.bold)),
            in: p))
        #expect(result?.source == "Use plenty of")
        #expect(result?.undo == .own)
    }

    @Test func boldOnPlainWordsAddsIt() {
        let source = "Use plenty of"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("plenty", in: p), length: 6), action: .format(.bold)),
            in: p))
        #expect(result?.source == "Use **plenty** of")
        #expect(result?.renderedSelection == NSRange(location: at("plenty", in: p), length: 6))
    }

    /// C8: ⌘B with nothing selected writes nothing; the next characters typed are bold.
    @Test func boldWithNothingSelectedWaitsForTyping() {
        let source = "a b"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 1, length: 0), action: .format(.bold)), in: p)
        guard case .setPending(let pending) = outcome else {
            Issue.record("expected a pending style, got \(outcome)")
            return
        }
        #expect(pending == .bold)
        let result = applied(type("new", at: 1, in: source, context: PreviewEditContext(pending: .bold)))
        #expect(result?.source == "a**new** b")
        // The caret is inside the closing asterisks, so the next character continues the bold.
        #expect(result?.sourceSelection == NSRange(location: 6, length: 0))
    }

    /// The Markup-verb undo rule (`MarkupVerbUndoTests`): a verb is its own step, so "foo" then
    /// Bold then ⌘Z gives "foo" — typing coalesces, a verb never joins it.
    @Test func typingCoalescesAndAVerbIsItsOwnStep() {
        let typed = applied(type("foo", at: 0, in: ""))
        #expect(typed?.undo == .typing)
        guard let typed else { return }
        let bold = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 0, length: 3), action: .format(.bold)),
            in: typed.projection))
        #expect(bold?.undo == .own)
        #expect(bold?.source == "**foo**")
        // Undoing the verb's own edits restores exactly the typed text.
        if let bold {
            #expect(PreviewEditTranslatorTests.undo(bold.edits, before: typed.source,
                                                    after: bold.source) == "foo")
        }
    }

    // MARK: Return (A5), ⇧Return (A6)

    /// C9: Return at the end of a paragraph opens a phantom and leaves the file alone.
    @Test func returnAtTheEndOfAParagraphChangesNothingYet() {
        let source = "one"
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 3, length: 0), action: .returnKey), in: project(source))
        guard case .openPhantom(let block) = outcome else {
            Issue.record("expected a phantom paragraph, got \(outcome)")
            return
        }
        #expect(block == 0)
    }

    /// C10: the first character typed into the phantom writes the blank line and the character.
    @Test func typingIntoThePhantomWritesTheParagraph() {
        let result = applied(type("x", at: 3, in: "one", context: PreviewEditContext(phantomAfterBlock: 0)))
        #expect(result?.source == "one\n\nx")
        let quoted = applied(type("x", at: 3, in: "> one",
                                  context: PreviewEditContext(phantomAfterBlock: 0)))
        #expect(quoted?.source == "> one\n>\n> x")
    }

    @Test func returnInTheMiddleOfAParagraphSplitsIt() {
        let source = "one two"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("two", in: p), length: 0), action: .returnKey), in: p))
        #expect(result?.source == "one \n\ntwo")
        #expect(result?.projection.blocks.count == 2)
    }

    @Test func returnInsideBoldIsRefusedRatherThanBreakingIt() {
        let source = "**one two**"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: at("two", in: p), length: 0), action: .returnKey), in: p)
        #expect(refusal(outcome) == .unverified)
    }

    /// C11: Return at the end of a list item writes exactly what Return writes there in Source.
    @Test func returnInAListItemMatchesSourceByteForByte() {
        let source = "- one\n- two"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("one", in: p), length: 0), action: .returnKey),
            in: p))
        guard case .continueWith(let opening) = MarkdownListEdits.returnEdit(
            in: source, selection: NSRange(location: 5, length: 0)) else {
            Issue.record("TE54's rule did not continue the list")
            return
        }
        #expect(result?.source == "- one\n" + opening + "\n- two")
        #expect(result?.undo == .own)
    }

    /// **The end of an item's last words carries the list on, whichever block holds them** (LST-8,
    /// 2026-10-15) — a later paragraph of the item, or words that are a heading — byte for byte as
    /// Source does. Preview opened a paragraph inside the item instead, so one Return wrote two
    /// different documents depending on the half it was pressed in. Where TE54 offers nothing, it is
    /// a paragraph's end as before.
    @Test(arguments: [("- a\n\n  more", "more"), ("- # Groceries\n- Hardware", "Groceries"),
                      ("1. Step\n\n   Notes on it", "Notes on it")])
    func returnAtTheEndOfAnItemsLaterWordsMatchesSource(_ source: String, _ needle: String) {
        let p = project(source)
        let sourceCaret = NSMaxRange((source as NSString).range(of: needle))
        guard case .continueWith(let opening)? = MarkdownListEdits.returnEdit(
            in: source, selection: NSRange(location: sourceCaret, length: 0)) else {
            Issue.record("TE54's rule did not carry \(source.debugDescription) on")
            return
        }
        let expected = (source as NSString).replacingCharacters(in: NSRange(location: sourceCaret, length: 0),
                                                                with: "\n" + opening)
        let result = applied(edit(NSRange(location: after(needle, in: p), length: 0), .returnKey, in: source))
        #expect(result?.source == expected)
        #expect(result?.undo == .own)
    }

    /// …and where the rule offers nothing — more of the item follows — it is a paragraph's end.
    @Test func returnInsideAnItemsLaterWordsStillOpensAParagraph() {
        let source = "- a\n\n  b\n\n  c"
        guard case .openPhantom = edit(NSRange(location: after("b", in: project(source)), length: 0), .returnKey,
                                       in: source) else {
            Issue.record("Return between two paragraphs of an item did not open a paragraph")
            return
        }
    }

    /// Return on an empty sub-list item ends the sub-list, not the list: the line keeps the item's
    /// indent, and a break after the caret keeps `- c` an item — the TE54 review's rule, byte for
    /// byte what `carryOnList` writes in Source.
    ///
    /// **The empty item sits between two items.** Straight under a paragraph, `  - ` is a setext
    /// underline to the parser — `- a\n  - ` makes `a` a heading — so it would never be an item.
    @Test func returnOnAnEmptySubItemEndsTheSubList() {
        let source = "- a\n  - b\n  - \n  - c"
        let p = project(source)
        let empty = try! #require(p.blocks.firstIndex { $0.indent == 1 && $0.rendered.length == 0 })
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: p.blocks[empty].rendered.location, length: 0),
                         action: .returnKey), in: p))
        guard case .endList(let line, let indent, true) = MarkdownListEdits.returnEdit(
            in: source, selection: NSRange(location: 14, length: 0)) else {
            Issue.record("TE54's rule did not end the sub-list here")
            return
        }
        #expect(indent == "  ")
        #expect(result?.source == (source as NSString).replacingCharacters(in: line, with: "\n  \n"))
        #expect(result?.source == "- a\n  - b\n\n  \n\n  - c")
        #expect(result?.sourceSelection == NSRange(location: line.location + 3, length: 0))
    }

    /// **Return at the end of an item with a sub-list shares Source's rule**: TE54 offers no
    /// opening there, because `  - ` straight under `item` would make it a heading (2026-10-09),
    /// so Preview refuses rather than writing one. Above a task sub-list the empty box is an item
    /// as written, and the list carries on as in Source.
    @Test func returnAboveASubListSharesSourcesRule() {
        let source = "- item\n  - sub"
        let p = project(source)
        #expect(MarkdownListEdits.returnEdit(in: source, selection: NSRange(location: 6, length: 0)) == nil)
        #expect(refusal(edit(NSRange(location: after("item", in: p), length: 0), .returnKey, in: source))
                == .notSupported)

        let tasks = "- item\n  - [x] sub"
        let result = applied(edit(NSRange(location: after("item", in: project(tasks)), length: 0), .returnKey, in: tasks))
        #expect(result?.source == "- item\n  - [ ] \n  - [x] sub")
        #expect(result?.projection.blocks.contains { if case .heading = $0.kind { return true } else { return false } } == false)
    }

    /// **Text ▸ Continue Lists off is off in Preview too** (LST-3, 2026-10-15), as Help says it is.
    /// Return at the end of an item writes no marker: it opens a paragraph after the item, as at the
    /// end of any other block — at the item's own indent in a sub-list — and Tab and ⇧Tab move no
    /// item. Where the item holds blocks under its words, a paragraph between would cut them off,
    /// and Return is refused. On, the list carries on as ever.
    @Test func continueListsOffWritesNoMarkerInPreview() {
        let source = "- one\n- two"
        let p = project(source)
        let off = PreviewEditContext(continuesLists: false)
        let end = after("one", in: p)
        guard case .openPhantom(let block) = edit(NSRange(location: end, length: 0), .returnKey, in: source, context: off) else {
            Issue.record("Return with Continue Lists off did not open a paragraph")
            return
        }
        #expect(applied(type("x", at: end, in: source,
                             context: PreviewEditContext(phantomAfterBlock: block, continuesLists: false)))?.source
                == "- one\n\nx\n\n- two")
        let nested = "- a\n  - b\n  - c"
        guard case .openPhantom(let inner) = edit(NSRange(location: after("b", in: project(nested)), length: 0), .returnKey,
                                                  in: nested, context: off) else {
            Issue.record("Return in a sub-list with Continue Lists off did not open a paragraph")
            return
        }
        #expect(applied(type("x", at: after("b", in: project(nested)), in: nested,
                             context: PreviewEditContext(phantomAfterBlock: inner, continuesLists: false)))?.source
                == "- a\n  - b\n\n  x\n\n  - c")
        let parent = "- a\n  - b"
        #expect(refusal(edit(NSRange(location: after("a", in: project(parent)), length: 0), .returnKey, in: parent,
                             context: off)) == .notSupported)
        for key in [RenderedEdit.Action.tab, .backtab] {
            if case .ignore = edit(NSRange(location: after("two", in: p), length: 0), key, in: source, context: off) {} else {
                Issue.record("\(key) moved an item with Continue Lists off")
            }
        }
        // On: the list carries on, and Tab moves the item.
        #expect(applied(edit(NSRange(location: end, length: 0), .returnKey, in: source))?.source == "- one\n- \n- two")
        #expect(applied(edit(NSRange(location: after("two", in: p), length: 0), .tab, in: source))?.source == "- one\n  - two")
    }

    /// The session carries the setting into every edit — it is not part of the context each edit
    /// resets (LST-3).
    @MainActor @Test func theSessionCarriesContinueListsIntoEveryEdit() {
        let source = EditorSourceStorage(text: "- one\n- two")
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        session.continuesLists = false
        let end = NSMaxRange((session.projection.renderedString as NSString).range(of: "one"))
        _ = session.perform(RenderedEdit(range: NSRange(location: end, length: 0), action: .returnKey))
        _ = session.perform(RenderedEdit(range: NSRange(location: end + 1, length: 0), text: "x", action: .typing))
        #expect(source.textStorage.string == "- one\n\nx\n\n- two")
        // A second Return, after the first edit reset the context, is still off.
        let two = NSMaxRange((session.projection.renderedString as NSString).range(of: "two"))
        _ = session.perform(RenderedEdit(range: NSRange(location: two, length: 0), action: .returnKey))
        _ = session.perform(RenderedEdit(range: NSRange(location: two + 1, length: 0), text: "y", action: .typing))
        #expect(source.textStorage.string == "- one\n\nx\n\n- two\n\ny")
    }

    /// **Tab moves an item from anywhere in its words** (LST-9, 2026-10-15) — on screen one
    /// paragraph, in the file two lines. From the second, the caret mapped onto a line with no marker
    /// on it, TE54 read none, and Tab did nothing. The caret stays on the character it was after.
    @Test func tabMovesAWrappedItemFromAnyOfItsLines() {
        let source = "- Groceries\n- Preheat the oven\n  to 200 degrees"
        let p = project(source)
        for needle in ["Preheat", "200"] {
            let result = applied(edit(NSRange(location: after(needle, in: p), length: 0), .tab, in: source))
            #expect(result?.source == "- Groceries\n  - Preheat the oven\n    to 200 degrees", "Tab after \(needle)")
            #expect(result?.renderedSelection == NSRange(location: after(needle, in: p), length: 0), "Tab after \(needle)")
            let back = applied(edit(NSRange(location: after(needle, in: p), length: 0), .backtab,
                                    in: "- Groceries\n  - Preheat the oven\n    to 200 degrees"))
            #expect(back?.source == source, "⇧Tab after \(needle)")
        }
    }

    @Test func returnInCodeAddsALineWithTheBlocksIndent() {
        let source = "1. one\n   ```\n   let x\n   ```"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("let x", in: p), length: 0), action: .returnKey),
            in: p))
        #expect(result?.source == "1. one\n   ```\n   let x\n   \n   ```")
    }

    /// C31: Preview writes LF. (A CRLF file is converted before the edit is measured — the view's
    /// job, through `EditorSourceStorage` — so the translator never sees one.)
    @Test func newLinesAreLF() {
        let result = applied(type("x", at: 3, in: "one\n\ntwo",
                                  context: PreviewEditContext(phantomAfterBlock: 0)))
        #expect(result?.source == "one\n\nx\n\ntwo")
    }

    /// Decision U: ⇧Return writes two trailing spaces, never `\`, and the text after it maps exactly.
    @Test func shiftReturnWritesTwoSpacesAndTheNextLineStillMaps() {
        let source = "> one two"
        let p = project(source)
        let broken = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("one", in: p), length: 0), action: .lineBreak),
            in: p))
        // The space that stood before `two` would start the new line, where it renders as nothing:
        // it goes, rather than being left in the file (2026-10-09).
        #expect(broken?.source == "> one  \n> two")
        guard let broken else { return }
        #expect(broken.projection.renderedString == "one\u{2028}two")
        // Typing straight after the break lands on the new line, not in the old one's spaces.
        let next = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 4, length: 0), text: "x", action: .typing),
            in: broken.projection))
        #expect(next?.projection.renderedString == "one\u{2028}xtwo")
    }

    // MARK: Tables (A1 in a cell, A7)

    /// C14, decision T = re-align as you type (2026-10-05): typing in a cell of an aligned table
    /// re-pads the whole table, so its pipes still line up — its compact delimiter row staying
    /// compact (TBL-4; this pinned `| --- | --- |`).
    @Test func typingInAnAlignedTableReAlignsIt() {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let p = project(source)
        let result = applied(type("x", at: after("c", in: p), in: source))
        #expect(result?.source == "| a   | b   |\n|-----|-----|\n| cx  | d   |")
        #expect(result?.projection.renderedString == "a\tb\ncx\td")
        // The caret is still after the x, in its cell.
        #expect(result.map { ($0.source as NSString).substring(to: $0.sourceSelection.location) }?
                    .hasSuffix("| cx") == true)
    }

    /// …and a ragged table keeps its own spacing, as the Table menu's edits keep it: only the row
    /// typed in changes.
    @Test func typingInARaggedTableChangesOnlyItsRow() {
        let source = "| a | b |\n|-|-|\n| c | d |"
        let p = project(source)
        let result = applied(type("x", at: after("c", in: p), in: source))
        #expect(result?.source == "| a | b |\n|-|-|\n| cx | d |")
    }

    /// C15: a typed `|` in a cell is `\|`.
    @Test func aPipeTypedInACellIsEscaped() {
        let source = "| a | b |\n|-|-|\n| c | d |"
        let p = project(source)
        let result = applied(type("|", at: after("c", in: p), in: source))
        #expect(result?.source == "| a | b |\n|-|-|\n| c\\| | d |")
    }

    /// C16: Tab in a row's last cell moves to the next row's first cell; the source is untouched.
    @Test func tabMovesBetweenCells() {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("b", in: p), length: 0), action: .tab), in: p)
        guard case .moveCaret(let caret) = outcome else {
            Issue.record("expected the caret to move, got \(outcome)")
            return
        }
        #expect(caret == after("c", in: p))
        let back = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("c", in: p), length: 0), action: .backtab), in: p)
        guard case .moveCaret(let previous) = back else {
            Issue.record("expected the caret to move back, got \(back)")
            return
        }
        #expect(previous == after("b", in: p))
    }

    /// Return in a table's last row has no row to move down to: it opens a paragraph after the
    /// table — a note ending in a table could not grow (review, 2026-10-09: refused).
    @Test func returnInTheLastRowOpensAParagraphAfterTheTable() {
        let source = "| a |\n|---|\n| c |"
        let p = project(source)
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("c", in: p), length: 0), action: .returnKey), in: p)
        guard case .openPhantom(let block) = outcome else {
            Issue.record("expected a paragraph opened after the table, got \(outcome)")
            return
        }
        #expect(block == 0)
        // A row above the last still moves down a row.
        let first = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("a", in: p), length: 0), action: .returnKey), in: p)
        guard case .moveCaret = first else {
            Issue.record("expected the caret to move down a row, got \(first)")
            return
        }
    }

    // MARK: Lists (A7, A8)

    @Test func tabIndentsAListItemByTE54sRule() {
        let source = "- one\n- two"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("two", in: p), length: 0), action: .tab), in: p))
        #expect(result?.source == "- one\n  - two")
        #expect(result?.projection.blocks.map(\.indent) == [0, 1])
    }

    /// C25: a tick is an edit with its own undo step now.
    @Test func tickingATaskTogglesItsBox() {
        let source = "- [ ] milk"
        let p = project(source)
        let box = p.segments.first { $0.kind == .decoration }!.rendered
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: box, action: .tickTask), in: p))
        #expect(result?.source == "- [x] milk")
        #expect(result?.undo == .own)
    }

    // MARK: Pastes and Replace All (A9–A11)

    @Test func pastingSeveralLinesIsRefusedOutsideCode() {
        let source = "one"
        let outcome = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 3, length: 0), text: "a\nb", action: .paste),
            in: project(source))
        #expect(refusal(outcome) == .notSupported)
    }

    @Test func pastingSeveralLinesIntoCodeIsVerbatimWithTheIndent() {
        let source = "- x\n\n  ```\n  a\n  ```"
        let p = project(source)
        let result = applied(PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: after("a", in: p), length: 0), text: "\nb\nc",
                         action: .paste), in: p))
        #expect(result?.source == "- x\n\n  ```\n  a\n  b\n  c\n  ```")
    }

    /// C21: one of three matches is in front matter, so none of them is replaced.
    @Test func replaceAllIsAllOrNothing() {
        let source = "---\nkey: cat\n---\ncat and cat"
        let p = project(source)
        let rendered = p.renderedString as NSString
        var matches: [RenderedEdit] = []
        var search = NSRange(location: 0, length: rendered.length)
        while true {
            let found = rendered.range(of: "cat", range: search)
            guard found.location != NSNotFound else { break }
            matches.append(RenderedEdit(range: found, text: "dog", action: .typing))
            search = NSRange(location: NSMaxRange(found), length: rendered.length - NSMaxRange(found))
        }
        // Front matter is one U+FFFC in the preview; add the match a find would see in its text.
        matches.append(RenderedEdit(range: NSRange(location: 0, length: 1), text: "dog", action: .typing))
        #expect(refusal(PreviewEditTranslator.translateAll(matches, in: p)) == .replaceAll(failed: 1, of: 3))
        let body = Array(matches.dropLast())
        let result = applied(PreviewEditTranslator.translateAll(body, in: p))
        #expect(result?.source == "---\nkey: cat\n---\ndog and dog")
    }

    // MARK: Undo arithmetic

    /// The source before `edits`, rebuilt from the source after them — each edit's inverse
    /// carries back the characters it replaced. Equal to `before` exactly when the edit list
    /// describes the change and nothing else moved.
    static func undo(_ edits: [PreviewSourceEdit], before: String, after: String) -> String {
        let old = before as NSString
        var shift = 0
        var inverse: [PreviewSourceEdit] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let length = edit.text.utf16.count
            inverse.append(PreviewSourceEdit(range: NSRange(location: edit.range.location + shift,
                                                            length: length),
                                             text: old.substring(with: edit.range)))
            shift += length - edit.range.length
        }
        return PreviewEditTranslator.applied(inverse, to: after)
    }

    /// A line verb on the empty paragraph Return opened starts the list THERE — a new paragraph
    /// holding the marker — and leaves the paragraph above alone.
    @Test func aLineVerbOnTheOpenedParagraphStartsItThere() {
        let p = project("one")
        for (verb, marker) in [(MarkupVerb.bulletList, "- "), (.numberedList, "1. "), (.taskItem, "- [ ] "),
                               (.blockQuote, "> "), (.heading(2), "## ")] {
            let outcome = PreviewEditTranslator.translate(
                // The opened paragraph is not in the projection: the session hands its edits over
                // at the block's end, where the paragraph will start.
                RenderedEdit(range: NSRange(location: 3, length: 0), action: .format(verb)), in: p,
                context: PreviewEditContext(phantomAfterBlock: 0))
            let result = applied(outcome)
            #expect(result?.source == "one\n\n" + marker, "\(verb): \(String(reflecting: result?.source))")
        }
    }

    // MARK: Review fixes, 2026-10-05

    private func edit(_ range: NSRange, _ action: RenderedEdit.Action, _ text: String = "", in source: String,
                      context: PreviewEditContext = PreviewEditContext()) -> PreviewEditOutcome {
        PreviewEditTranslator.translate(RenderedEdit(range: range, text: text, action: action),
                                        in: project(source), context: context)
    }

    /// Typed text that the parser would take for HTML goes in escaped — never as a tag every other
    /// renderer drops.
    @Test func typedTextThatWouldBeHTMLIsEscaped() {
        let source = "Use Vec<T"
        let result = applied(type(">", at: after("Vec<T", in: project(source)), in: source))
        #expect(result?.source == "Use Vec<T\\>")
        #expect(result?.projection.renderedString == "Use Vec<T>")
    }

    /// ⌫ that would leave a space at a line's end takes the space too: it was refused.
    @Test func deletingTheLastWordTakesTheSpaceBeforeIt() {
        let source = "hello w\n\nnext"
        let p = project(source)
        let result = applied(edit(NSRange(location: at("w", in: p), length: 1), .delete, in: source))
        #expect(result?.source == "hello\n\nnext")
    }

    /// Quote and a Heading on the opened paragraph leave somewhere to type — in the new block.
    @Test func quoteAndHeadingOnTheOpenedParagraphCanBeTypedInto() {
        for (verb, marker) in [(MarkupVerb.blockQuote, "> "), (.heading(2), "## ")] {
            let opened = applied(edit(NSRange(location: 3, length: 0), .format(verb), in: "one",
                                      context: PreviewEditContext(phantomAfterBlock: 0)))
            guard let opened else { continue }
            let typed = PreviewEditTranslator.translate(
                RenderedEdit(range: opened.renderedSelection, text: "x", action: .typing), in: opened.projection)
            #expect(applied(typed)?.source == "one\n\n" + marker + "x", "\(verb)")
        }
    }

    /// Typing over a selection that covers a whole link from before it replaces the link too —
    /// no empty `[](…)` is left in the file.
    @Test func typingOverAWholeLinkFromBeforeItReplacesIt() {
        let source = "See [docs](http://x.y) now"
        let p = project(source)
        let range = NSRange(location: at(" docs", in: p), length: 5)
        #expect(applied(edit(range, .typing, "x", in: source))?.source == "Seex now")
        // From the link's own start, the link keeps its style for the new text.
        let inside = NSRange(location: at("docs", in: p), length: 4)
        #expect(applied(edit(inside, .typing, "x", in: source))?.source == "See [x](http://x.y) now")
    }

    /// Return at the end of a list item that ends in bold carries the list on.
    @Test func returnAfterAnItemEndingInBoldCarriesTheListOn() {
        let source = "- **done**"
        let p = project(source)
        let result = applied(edit(NSRange(location: after("done", in: p), length: 0), .returnKey, in: source))
        #expect(result?.source == "- **done**\n- ")
    }

    /// A compact table is the author's style: typing in it changes only its row.
    @Test func aCompactTableKeepsItsStyle() {
        let source = "|a|b|\n|-|-|\n|c|d|"
        let result = applied(type("x", at: after("c", in: project(source)), in: source))
        #expect(result?.source == "|a|b|\n|-|-|\n|cx|d|")
        // …and so is a table written without its outer pipes, lined up or not.
        let bare = "a | b\n--|--\nc | d"
        let typed = applied(type("x", at: after("c", in: project(bare)), in: bare))
        #expect(typed?.source == "a | b\n--|--\ncx | d")
    }

    /// Bullets over two paragraphs makes two items.
    @Test func aLineVerbOverSeveralBlocksAppliesToEach() {
        let source = "one\n\ntwo"
        let p = project(source)
        let range = NSRange(location: 0, length: (p.renderedString as NSString).length)
        let result = applied(edit(range, .format(.bulletList), in: source))
        #expect(result?.source.contains("- one") == true)
        #expect(result?.source.contains("- two") == true)
    }

    /// Typed on a blank line of fenced code inside a list, the line takes the list's indent first.
    @Test func typingOnABlankCodeLineInAListKeepsItInTheBlock() {
        let source = "- a\n\n  ```\n  b\n\n  c\n  ```"
        let p = project(source)
        let blank = at("b\n", in: p, plus: 2)
        let result = applied(type("x", at: blank, in: source))
        #expect(result?.source == "- a\n\n  ```\n  b\n  x\n  c\n  ```")
    }

    /// Replace All with two matches in one tidy table: both made, the table re-padded once.
    @Test func replaceAllInATidyTableReAlignsItOnce() {
        let source = "| c   | d   |\n| --- | --- |\n| c   | e   |"
        let p = project(source)
        let rendered = p.renderedString as NSString
        let first = rendered.range(of: "c")
        let second = rendered.range(of: "c", options: .backwards)
        let result = applied(PreviewEditTranslator.translateAll(
            [RenderedEdit(range: first, text: "cccc", action: .typing),
             RenderedEdit(range: second, text: "cccc", action: .typing)], in: p))
        #expect(result?.source == "| cccc | d   |\n| ---- | --- |\n| cccc | e   |")
    }

    /// A line pasted with its line break is that line.
    @Test func aLinePastedWithItsBreakIsOneLine() {
        let source = "one two"
        let p = project(source)
        let result = applied(edit(NSRange(location: after("one", in: p), length: 0), .paste, " more\n", in: source))
        #expect(result?.source == "one more two")
    }

    /// Return at the end of an item with a sub-list under it is refused, not written: TE54's
    /// opening there is the sub-list's, straight under the item's words, where `  - ` is a setext
    /// underline — the words became a heading (found 2026-10-09, by the property test). Since
    /// `0cfe5460` the list rule itself declines it, so nothing is offered to verify.
    @Test func returnThatWouldMakeAnItemAHeadingIsRefused() {
        let source = "- item\n  - sub"
        let p = project(source)
        #expect(refusal(edit(NSRange(location: after("item", in: p), length: 0), .returnKey, in: source)) == .notSupported)
        // …and at the end of an item with no sub-list, the list carries on as ever.
        #expect(applied(edit(NSRange(location: after("sub", in: p), length: 0), .returnKey, in: source))?.source
                == "- item\n  - sub\n  - ")
    }

    /// Return right after bold mid-paragraph splits after the `**`, not between the asterisks.
    @Test func returnAfterClosingBoldSplitsAfterIt() {
        let source = "a **b** c"
        let p = project(source)
        let result = applied(edit(NSRange(location: after("b", in: p), length: 0), .returnKey, in: source))
        #expect(result?.source.hasPrefix("a **b**\n\n") == true)
    }
}
