import Testing
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// **Natural edits that Preview must WRITE** — each typed through the real text view, as a person
/// would make it, with the exact source it must leave (TE67 review, 2026-10-09).
///
/// The property test only counts refusals, so an edit refused every time it is tried is invisible
/// to it: 2,000 random edits can pass while deleting the first word of a heading never works. Every
/// case here was refused, or written wrongly, before the fix named beside it — and each one is an
/// edit a person makes without thinking.
@MainActor
@Suite(.serialized) struct PreviewEditMustAcceptTests {

    enum Step: Sendable {
        /// The caret straight after the first `needle` in the display.
        case caretAfter(String)
        /// The caret straight before the first `needle`.
        case caretBefore(String)
        /// The first `needle` selected.
        case select(String)
        /// A triple-click's selection: the paragraph holding `needle`, with its line break.
        case selectParagraph(of: String)
        case type(String)
        case backspace(Int)
        case returnKey
        case shiftReturn
        case tab
        case verb(MarkupVerb)
        /// Pasted through a private pasteboard, by the paste path the view's own Paste takes.
        case paste(String)
        /// Replace All: every `find` in the display replaced with `with`.
        case replaceAll(String, with: String)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let source: String
        let steps: [Step]
        let expected: String
        /// What the display must read afterwards, when it says more than the source does.
        var display: String?
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        // T1 — a deletion that leaves a space at a line's edge takes the space, on either side.
        Case(name: "T1 first word of a paragraph", source: "Hello world",
             steps: [.caretAfter("Hello"), .backspace(5)], expected: "world"),
        Case(name: "T1 first word of a heading", source: "# Hello world",
             steps: [.caretAfter("Hello"), .backspace(5)], expected: "# world"),
        Case(name: "T1 first word of a list item", source: "- Hello world",
             steps: [.caretAfter("Hello"), .backspace(5)], expected: "- world"),
        Case(name: "T1 first word of a task", source: "- [ ] Hello world",
             steps: [.caretAfter("Hello"), .backspace(5)], expected: "- [ ] world"),
        Case(name: "T1 first word of a table cell", source: "| a | b |\n|-|-|\n| Hello world | d |",
             steps: [.caretAfter("Hello"), .backspace(5)], expected: "| a | b |\n|-|-|\n| world | d |"),
        Case(name: "T1 first word after a soft break", source: "one\ntwo three",
             steps: [.select("two"), .backspace(1)], expected: "one\nthree"),
        Case(name: "T1 first word after a hard break", source: "one  \ntwo three",
             steps: [.select("two"), .backspace(1)], expected: "one  \nthree"),
        Case(name: "T1 last word before a soft break", source: "one two\nthree",
             steps: [.select("two"), .backspace(1)], expected: "one\nthree"),
        Case(name: "T1 last word before a hard break", source: "one two  \nthree",
             steps: [.select("two"), .backspace(1)], expected: "one  \nthree"),
        Case(name: "T1 last word of a table cell", source: "| a | b |\n|-|-|\n| c d | e |",
             steps: [.select("d"), .backspace(1)], expected: "| a | b |\n|-|-|\n| c | e |"),
        Case(name: "T1 a whole line of a paragraph", source: "one\ntwo\nthree",
             steps: [.select("two"), .backspace(1)], expected: "one\nthree"),

        // T2 — emptying a paragraph leaves an empty line to type on, as a text editor does.
        Case(name: "T2 the only letter of a middle paragraph", source: "x\n\na\n\ny",
             steps: [.caretAfter("a"), .backspace(1)], expected: "x\n\ny", display: "x\n\ny"),
        Case(name: "T2 and then typed into", source: "x\n\na\n\ny",
             steps: [.caretAfter("a"), .backspace(1), .type("b")], expected: "x\n\nb\n\ny"),
        Case(name: "T2 and a second backspace closes the line", source: "x\n\na\n\ny",
             steps: [.caretAfter("a"), .backspace(2)], expected: "x\n\ny", display: "x\ny"),
        Case(name: "T2 the last paragraph", source: "x\n\na",
             steps: [.caretAfter("a"), .backspace(1), .type("b")], expected: "x\n\nb"),
        Case(name: "T2 a paragraph in a quote", source: "> x\n>\n> a\n>\n> y",
             steps: [.caretAfter("a"), .backspace(1), .type("b")], expected: "> x\n>\n> b\n>\n> y"),
        Case(name: "T2 a bold paragraph, selected and deleted", source: "x\n\n**a b**\n\ny",
             steps: [.select("a b"), .backspace(1)], expected: "x\n\ny", display: "x\n\ny"),
        Case(name: "T2 the first paragraph", source: "a\n\ny",
             steps: [.caretAfter("a"), .backspace(1)], expected: "y"),

        // T3 — code keeps its spaces.
        Case(name: "T3 a code line's indent", source: "```\n    x\n```",
             steps: [.caretAfter("x"), .backspace(1)], expected: "```\n    \n```"),
        Case(name: "T3 a code span's inner space", source: "x `a b`",
             steps: [.select("b"), .backspace(1)], expected: "x `a `"),

        // T4 — ⌘B inside bold turns it off for what is typed next.
        Case(name: "T4 bold off at the end of bold", source: "**bold**",
             steps: [.caretAfter("bold"), .verb(.bold), .type(" "), .type("r")], expected: "**bold** r"),
        Case(name: "T4 bold off in the middle of a bold word", source: "**bold**",
             steps: [.caretAfter("bo"), .verb(.bold), .type("x")], expected: "**bo**x**ld**"),
        Case(name: "T4 italic off at the end of italic", source: "*it*",
             steps: [.caretAfter("it"), .verb(.italic), .type("x")], expected: "*it*x"),

        // T5 — a paragraph opened after a block with text on the very next line stays its own.
        Case(name: "T5 after a heading", source: "# Title\nSome text",
             steps: [.caretAfter("Title"), .returnKey, .type("x")], expected: "# Title\n\nx\n\nSome text"),
        Case(name: "T5 after a heading in a quote", source: "> # Title\n> Some text",
             steps: [.caretAfter("Title"), .returnKey, .type("x")],
             expected: "> # Title\n>\n> x\n>\n> Some text"),
        Case(name: "T5 Bullets on it", source: "# Title\nSome text",
             steps: [.caretAfter("Title"), .returnKey, .verb(.bulletList), .type("x")],
             expected: "# Title\n\n- x\n\nSome text"),

        // T6 — a style chosen on the opened paragraph is the opened paragraph's.
        Case(name: "T6 Return, Bold, typing", source: "one",
             steps: [.caretAfter("one"), .returnKey, .verb(.bold), .type("x")], expected: "one\n\n**x**"),
        Case(name: "T6 Return, Italic, typing two", source: "one\n\ntwo",
             steps: [.caretAfter("one"), .returnKey, .verb(.italic), .type("x"), .type("y")],
             expected: "one\n\n*xy*\n\ntwo"),

        // T7 — a triple-clicked paragraph can be typed over, made bold, and deleted.
        Case(name: "T7 typed over", source: "one\n\ntwo",
             steps: [.selectParagraph(of: "one"), .type("x")], expected: "x\n\ntwo"),
        Case(name: "T7 made bold", source: "one\n\ntwo",
             steps: [.selectParagraph(of: "one"), .verb(.bold)], expected: "**one**\n\ntwo"),
        Case(name: "T7 deleted, line and all", source: "x\n\none\n\ntwo",
             steps: [.selectParagraph(of: "one"), .backspace(1)], expected: "x\n\ntwo", display: "x\ntwo"),

        Case(name: "T7 a quote's paragraph deleted, and the list after it stays out of the quote",
             source: "one\n\n> quoted\n\n- item",
             steps: [.selectParagraph(of: "quoted"), .backspace(1)], expected: "one\n\n- item", display: "one\nitem"),

        // T8 — ⇧Return after bold, and at a paragraph's end.
        Case(name: "T8 after bold", source: "**Note** text",
             steps: [.caretAfter("Note"), .shiftReturn, .type("x")], expected: "**Note**  \nxtext"),
        Case(name: "T8 at a paragraph's end", source: "one",
             steps: [.caretAfter("one"), .shiftReturn, .type("x")], expected: "one  \nx"),
        Case(name: "T8 at a list item's end", source: "- one\n- two",
             steps: [.caretAfter("one"), .shiftReturn, .type("x")], expected: "- one  \n  x\n- two"),

        Case(name: "T8 at a task's end, the new line under the words, not the box", source: "- [ ] one",
             steps: [.caretAfter("one"), .shiftReturn, .type("x")], expected: "- [ ] one  \n  x"),

        // T9 — next to a picture or other piece that is not text.
        Case(name: "T9 after an inline image at a paragraph's end", source: "see ![i](a)",
             steps: [.caretAfter("see \u{FFFC}"), .type("x")], expected: "see ![i](a)x"),
        Case(name: "T9 before an inline image at a paragraph's start", source: "![i](a) text",
             steps: [.caretBefore("\u{FFFC}"), .type("x")], expected: "x![i](a) text"),
        Case(name: "T9 after inline HTML at a line's end", source: "a <br>",
             steps: [.caretAfter("<br>"), .type("y")], expected: "a <br>y"),
        Case(name: "T9 a paragraph after an image block", source: "x\n\n![i](a)",
             steps: [.caretAfter("\u{FFFC}"), .returnKey, .type("y")], expected: "x\n\n![i](a)\n\ny"),
        Case(name: "T9 a paragraph after a rule", source: "x\n\n***",
             steps: [.caretAfter("\u{FFFC}"), .returnKey, .type("y")], expected: "x\n\n***\n\ny"),
        Case(name: "T9 a paragraph after an HTML block", source: "<div>\nhi\n</div>",
             steps: [.caretAfter("</div>"), .returnKey, .type("x")], expected: "<div>\nhi\n</div>\n\nx"),
        Case(name: "T9 a paragraph after a table", source: "| a |\n|---|\n| c |",
             steps: [.caretAfter("c"), .returnKey, .type("x")], expected: "| a |\n|---|\n| c |\n\nx"),

        // T10 — only what could be Markdown is escaped.
        Case(name: "T10 a pasted sentence", source: "Start.",
             steps: [.caretAfter("Start."), .paste(" Don't use *foo*, e.g. here.")],
             expected: "Start. Don't use \\*foo\\*, e.g. here."),

        // T11 — Replace All with nothing, before a line's end.
        Case(name: "T11 replace with nothing", source: "hello w\n\nnext w",
             steps: [.replaceAll("w", with: "")], expected: "hello\n\nnext"),

        // T12 — a line copied with its CRLF.
        Case(name: "T12 a line pasted with a CRLF", source: "one two",
             steps: [.caretAfter("one"), .paste(" more\r\n")], expected: "one more two"),

        // T18 — a space typed on an opened paragraph.
        Case(name: "T18 Return, space, letter", source: "Para",
             steps: [.caretAfter("Para"), .returnKey, .type(" "), .type("x")], expected: "Para\n\nx"),

        // T19 — a space typed at a paragraph's start, then a letter.
        Case(name: "T19 space then letter at a paragraph's start", source: "# Title\n\nWords here.",
             steps: [.caretBefore("Words"), .type(" "), .type("x")], expected: "# Title\n\nxWords here."),

        // Round 2, R1 — a line between two blocks that draws nothing — a reference definition, the
        // `[//]: # (note)` comment — stays when a block beside it is deleted.
        Case(name: "R1 a triple-clicked paragraph before a comment", source: "Para A\n\n[//]: # (note)\n\nPara B",
             steps: [.selectParagraph(of: "Para A"), .backspace(1)],
             expected: "[//]: # (note)\n\nPara B", display: "Para B"),
        Case(name: "R1 the last paragraph emptied after a comment", source: "Para A\n\n[//]: # (note)\n\nPara B",
             steps: [.select("Para B"), .backspace(1)], expected: "Para A\n\n[//]: # (note)"),
        Case(name: "R1 and typed into", source: "Para A\n\n[//]: # (note)\n\nPara B",
             steps: [.select("Para B"), .backspace(1), .type("x")], expected: "Para A\n\nx\n\n[//]: # (note)"),
        Case(name: "R1 a middle paragraph emptied after a comment",
             source: "Para A\n\n[//]: # (note)\n\nPara B\n\nPara C",
             steps: [.select("Para B"), .backspace(1)], expected: "Para A\n\n[//]: # (note)\n\nPara C"),
        Case(name: "R1 the first paragraph emptied before a comment", source: "Para A\n\n[//]: # (note)\n\nPara B",
             steps: [.select("Para A"), .backspace(1)], expected: "[//]: # (note)\n\nPara B"),
        Case(name: "R1 a list item triple-clicked before a definition in a quote",
             source: "> - a\n>\n> [x]: /u\n>\n> - b",
             steps: [.selectParagraph(of: "a"), .backspace(1)], expected: "> [x]: /u\n>\n> - b"),

        // R2 — a space typed in a line where it would draw nothing YET — before a span's closing
        // marker, before punctuation — is held for the next character, not dropped.
        Case(name: "R2 a space at the end of bold, mid-line", source: "Hello **world** today",
             steps: [.caretAfter("world"), .type(" "), .type("x")], expected: "Hello **world x** today"),
        Case(name: "R2 a space before punctuation", source: "**Note**: text",
             steps: [.caretAfter("Note"), .type(" "), .type("x")], expected: "**Note x**: text"),

        // R3 — a pasted line separator is a line break like any other: in code, a new line.
        Case(name: "R3 a paste starting with U+2028 in code", source: "```\na\n```",
             steps: [.caretAfter("a"), .paste("\u{2028}x")], expected: "```\na\nx\n```"),

        // R4 — ⇧Return on an opened paragraph writes nothing, and the paragraph stays open.
        Case(name: "R4 Return, ⇧Return, typing", source: "Para",
             steps: [.caretAfter("Para"), .returnKey, .shiftReturn, .type("x")], expected: "Para\n\nx"),

        // R5 — a held line break or held spaces, and a style chosen for what is typed next, keep
        // each other, in either order.
        Case(name: "R5 ⇧Return, Bold, typing", source: "one",
             steps: [.caretAfter("one"), .shiftReturn, .verb(.bold), .type("x")], expected: "one  \n**x**"),
        Case(name: "R5 Bold, ⇧Return, typing", source: "one",
             steps: [.caretAfter("one"), .verb(.bold), .shiftReturn, .type("x")], expected: "one  \n**x**"),
        Case(name: "R5 space, Bold, typing", source: "hello",
             steps: [.caretAfter("hello"), .type(" "), .verb(.bold), .type("x")], expected: "hello **x**"),
        Case(name: "R5 Bold, space, typing", source: "hello",
             steps: [.caretAfter("hello"), .verb(.bold), .type(" "), .type("x")], expected: "hello **x**"),
        Case(name: "R5 ⇧Return at the end of bold, Bold off, typing", source: "**Note**",
             steps: [.caretAfter("Note"), .shiftReturn, .verb(.bold), .type("x")], expected: "**Note**  \nx"),

        // R7 — a line verb on the paragraph opened after HTML is verified, and still made.
        Case(name: "R7 Heading on a paragraph opened after HTML", source: "<div>\nhi\n</div>",
             steps: [.caretAfter("</div>"), .returnKey, .verb(.heading(1)), .type("x")],
             expected: "<div>\nhi\n</div>\n\n# x"),

        // R9 — the first numbered item deleted: the list still starts at its number.
        Case(name: "R9 the first numbered item triple-clicked and deleted", source: "1. a\n2. b\n3. c",
             steps: [.selectParagraph(of: "a"), .backspace(1)], expected: "1. b\n3. c"),
        Case(name: "R9 a list starting at 4", source: "x\n\n4. a\n5. b",
             steps: [.selectParagraph(of: "a"), .backspace(1)], expected: "x\n\n4. b"),
        Case(name: "R9 a middle item leaves the numbers alone", source: "1. a\n2. b\n3. c",
             steps: [.selectParagraph(of: "b"), .backspace(1)], expected: "1. a\n3. c"),
    ]

    @Test(arguments: cases)
    func mustBeWritten(_ c: Case) throws {
        let r = PreviewEditRig(c.source)
        for step in c.steps { try r.run(step) }
        #expect(r.source.text == c.expected,
                "\(c.name): source \(String(reflecting: r.source.text)), refusals \(r.refusals)")
        #expect(r.refusals.isEmpty, "\(c.name): refused \(r.refusals)")
        if let display = c.display {
            #expect(r.display == display, "\(c.name): display \(String(reflecting: r.display))")
        }
    }
}

// MARK: - The rest of the review, 2026-10-09

@MainActor
@Suite(.serialized) struct PreviewEditReviewTests {

    /// T11: Replace All leaves the caret after the last replacement, as `NSTextView`'s does — it
    /// went to the top of the note.
    @Test func replaceAllLeavesTheCaretAfterTheLastReplacement() throws {
        let r = PreviewEditRig("cat and cat, then more")
        try r.run(.replaceAll("cat", with: "dog"))
        #expect(r.source.text == "dog and dog, then more")
        #expect(r.view.selectedRange() == NSRange(location: 11, length: 0))
    }

    /// T13: what an edit may not do is make text read-only — and that is a question of WHICH
    /// pieces, not how many: one tag swapped for another keeps the count, and was let through.
    ///
    /// Measured 2026-10-09: no keystroke found reaches this — the rendering check already refuses
    /// every swap tried, because turning a tag into text costs the character that does it (a `\`, a
    /// backtick). So the comparison itself is what is pinned, on two notes that differ only in it.
    @Test func readOnlyPiecesCompareByWhatTheyAreNotHowMany() {
        let bold = MarkdownProjection.project("x <b>"), italic = MarkdownProjection.project("x <i>")
        #expect(PreviewEditTranslator.readOnlyPieces(bold).isSubset(of: PreviewEditTranslator.readOnlyPieces(bold)))
        #expect(!PreviewEditTranslator.readOnlyPieces(italic).isSubset(of: PreviewEditTranslator.readOnlyPieces(bold)),
                "the same count of pieces, and a different one")
        #expect(PreviewEditTranslator.readOnlyPieces(MarkdownProjection.project("x"))
                    .isSubset(of: PreviewEditTranslator.readOnlyPieces(bold)), "fewer is always allowed")
        // And through the translator: a paste that would be a tag goes in escaped.
        let p = MarkdownProjection.project("x <b>")
        guard case .apply(let result) = PreviewEditTranslator.translate(
            RenderedEdit(range: NSRange(location: 2, length: 0), text: "<i>", action: .paste), in: p) else {
            Issue.record("expected the paste to be written")
            return
        }
        #expect(result.source == "x \\<i\\><b>")
    }

    /// T15: Tab over several list items moves none of them, and says why — it moved the first
    /// alone. (Source's Tab replaces such a selection with a tab character, so there is nothing to
    /// match: the finding's "Source indents them all" is not what Source does.)
    @Test func tabOverSeveralItemsIsRefusedNotHalfDone() throws {
        let r = PreviewEditRig("- one\n- two\n- three")
        let two = try r.find("two")
        r.view.setSelectedRange(NSRange(location: two.location, length: NSMaxRange(try r.find("thr")) - two.location))
        try r.run(.tab)
        #expect(r.source.text == "- one\n- two\n- three")
        #expect(r.refusals == [.crossesBlocks])
    }

    /// T16: ⌘B over two paragraphs says it crosses blocks — it said "not text".
    @Test func boldOverTwoParagraphsSaysItCrossesBlocks() throws {
        let r = PreviewEditRig("one\n\ntwo")
        r.view.selectAll(nil)
        try r.run(.verb(.bold))
        #expect(r.source.text == "one\n\ntwo")
        #expect(r.refusals == [.crossesBlocks])
    }

    /// T17: a refusal says, at INFO, what was refused, where, and by which line — never the text.
    @Test func aRefusalIsLoggedWithItsSiteAndNoText() async throws {
        let log = LogCapture()
        // A first paragraph of 1,111 characters, so the offsets are this case's alone: the suites
        // around it refuse in parallel, and their lines are captured too (round 2, 2026-10-10).
        let r = PreviewEditRig(String(repeating: "w", count: 1_111) + "\n\n**two three**")
        try r.run(.caretBefore("two"))
        try r.run(.backspace(1))
        try r.run(.caretBefore("three"))
        try r.run(.returnKey)
        #expect(r.refusals == [.joinsBlocks, .unverified])
        let lines = await log.entries.filter { $0.message.contains("[edit] preview refused") && $0.message.contains("at source 111") }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.level == .info })
        let joins = try #require(lines.first?.message)
        #expect(joins.contains("delete in paragraph at source 1113: joinsBlocks (translator line "), "\(joins)")
        let unverified = try #require(lines.last?.message)
        #expect(unverified.contains("Return in paragraph at source 1119: unverified (translator line "), "\(unverified)")
        #expect(unverified.contains(", rendering off by "), "\(unverified)")
        for line in lines { #expect(!line.message.contains("two") && !line.message.contains("ww"), "\(line.message)") }
    }

    /// A paragraph emptied where taking its line would move the next block — an indented paragraph
    /// after it would join the list above — is refused, and the file left alone: the characters
    /// alone read right either way, so the blocks around it are checked too.
    @Test func anEmptiedParagraphThatWouldMoveTheNextBlockIsRefused() throws {
        let r = PreviewEditRig("- a\n\nb\n\n  c")
        try r.run(.caretAfter("b"))
        try r.run(.backspace(1))
        #expect(r.source.text == "- a\n\nb\n\n  c")
        #expect(r.refusals == [.unverified])
    }

    /// T20: with a space held, the status line's Line and Column are the held space's — the end of
    /// its line — not the next paragraph's start.
    @Test func theSourceSelectionCountsAHeldSpaceAsItsLine() throws {
        let r = PreviewEditRig("Hello\n\nworld")
        try r.run(.caretAfter("Hello"))
        try r.run(.type(" "))
        #expect(r.display == "Hello \nworld", "the space is held")
        #expect(r.session.sourceSelection(for: r.view.selectedRange()) == NSRange(location: 5, length: 0))
    }
}

/// The editable Preview as `makeNSView` builds it, in a window — for driving it as a person does.
@MainActor
final class PreviewEditRig {
    let view: PreviewTextView
    let coordinator: PreviewEditorView.Coordinator
    let source: EditorSourceStorage
    let undo = UndoManager()
    let window: NSWindow
    var refusals: [PreviewRefusal] = []
    var display: String { view.string }
    var session: PreviewEditSession { coordinator.session }

    init(_ text: String) {
        source = EditorSourceStorage(text: text)
        coordinator = PreviewEditorView.Coordinator(session: PreviewEditSession(source: source, undoManager: undo))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = PreviewTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView?.addSubview(scroll)
        view = scroll.documentView as! PreviewTextView
        coordinator.onRefusal = { [unowned self] reason, _ in self.refusals.append(reason) }
        coordinator.attach(view)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        spin()
    }

    /// One turn of the run loop: what separates two keystrokes and closes the first one's undo group.
    func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    func find(_ needle: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSRange {
        let found = (display as NSString).range(of: needle)
        try #require(found.location != NSNotFound, "\(String(reflecting: needle)) not in \(String(reflecting: display))",
                     sourceLocation: sourceLocation)
        return found
    }

    func run(_ step: PreviewEditMustAcceptTests.Step) throws {
        switch step {
        case .caretAfter(let after):
            view.setSelectedRange(NSRange(location: NSMaxRange(try find(after)), length: 0))
        case .caretBefore(let before):
            view.setSelectedRange(NSRange(location: try find(before).location, length: 0))
        case .select(let needle):
            view.setSelectedRange(try find(needle))
        case .selectParagraph(let needle):
            view.setSelectedRange(NSRange(location: try find(needle).location, length: 0))
            view.selectParagraph(nil)
        case .type(let text):
            view.insertText(text, replacementRange: view.selectedRange())
        case .backspace(let count):
            for _ in 0..<count { view.deleteBackward(nil); spin() }
        case .returnKey:
            view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case .shiftReturn:
            view.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        case .tab:
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
        case .verb(let verb):
            view.performMarkup(verb)
        case .paste(let text):
            let board = NSPasteboard(name: NSPasteboard.Name("te67-must-accept-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            board.setString(text, forType: .string)
            _ = view.readSelection(from: board, type: .string)
        case .replaceAll(let find, let with):
            let text = display as NSString
            var edits: [RenderedEdit] = []
            var search = NSRange(location: 0, length: text.length)
            while case let found = text.range(of: find, range: search), found.location != NSNotFound {
                edits.append(RenderedEdit(range: found, text: with, action: with.isEmpty ? .delete : .typing))
                search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            coordinator.apply(edits.count == 1 ? session.perform(edits[0]) : session.performAll(edits))
        }
        spin()
    }
}
