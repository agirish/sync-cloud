import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer

/// **TE61 — go to a line.** What the field accepts, where it lands (clamped, in characters, on
/// lines of the FILE), and that a mounted text view really puts the caret there — on a logical
/// line, not a row the window wrapped a long one into.
@MainActor
@Suite(.serialized) struct EditorGoToLineTests {

    // MARK: What the field accepts

    @Test func aLineOrALineAndColumnIsAccepted() {
        #expect(EditorGoToLine.parse("48") == .init(line: 48, column: nil))
        #expect(EditorGoToLine.parse("  48 ") == .init(line: 48, column: nil))
        #expect(EditorGoToLine.parse("48:12") == .init(line: 48, column: 12))
        #expect(EditorGoToLine.parse("48 : 12") == .init(line: 48, column: 12))
        #expect(EditorGoToLine.parse("48:") == .init(line: 48, column: nil))
        #expect(EditorGoToLine.parse("007") == .init(line: 7, column: nil))
    }

    /// **0 and junk do nothing (the field beeps)** — and a sign is junk: `Int("+3")` would take it.
    @Test func zeroAndJunkAreRefused() {
        for typed in ["", " ", "0", "-3", "+3", "abc", "12a", "1.5", "12:0", "12:x", ":4", "1:2:3", "٣"] {
            #expect(EditorGoToLine.parse(typed) == nil, "“\(typed)” was accepted")
        }
    }

    /// A number too large to hold is past the end, not junk — it goes to the last line.
    @Test func anEnormousNumberIsPastTheEnd() {
        #expect(EditorGoToLine.parse("99999999999999999999999") == .init(line: .max, column: nil))
        #expect(EditorGoToLine.utf16Offset(of: .init(line: .max, column: nil), in: "a\nb", using: .empty) == 2)
    }

    // MARK: Where it lands

    private let text = "alpha\nbeta\r\ngamma"

    private func offset(_ line: Int, _ column: Int? = nil, in text: String? = nil,
                        index: EditorLineIndex? = nil) -> Int {
        let text = text ?? self.text
        return EditorGoToLine.utf16Offset(of: .init(line: line, column: column), in: text,
                                          using: index ?? EditorLineIndex(text: text))
    }

    @Test func aLineGoesToItsStart() {
        #expect(offset(1) == 0)
        #expect(offset(2) == 6)
        #expect(offset(3) == 12, "the line after a CRLF starts past both units")
    }

    /// **Past the end goes to the last line, past a line's end to its end** — before its CRLF.
    @Test func pastTheEndIsClamped() {
        #expect(offset(99) == 12)
        #expect(offset(2, 3) == 8)
        #expect(offset(2, 99) == 10, "a column past the line's end went past its terminator")
        #expect(offset(3, 99) == 17, "the last line's end is the text's end")
        // A final line break opens no line: the last line is the one with the text, as the field's
        // "This file has 2 lines" counts — not the empty place after the last newline.
        #expect(offset(99, in: "a\nb\n") == 2)
        #expect(offset(99, 9, in: "a\nbc\r\n") == 4, "past the end landed past the last line's text")
        #expect(offset(99, in: "a\n\n") == 2, "an empty line before the final break is a line")
        #expect(offset(5, 5, in: "") == 0)
    }

    /// **The column is in characters, as the status line's is** — the emoji is one column.
    @Test func theColumnCountsCharacters() {
        #expect(offset(1, 3, in: "a👍b\nc") == 3, "the column counted UTF-16 units")
    }

    /// **The inverse of the status line's caret**, everywhere: for every offset the caret can stand
    /// on, its line and column go back to that offset. Mixed endings, an emoji and an empty line,
    /// so a rule that is right for LF only fails here.
    @Test func goingToTheCaretsLineAndColumnLandsOnTheCaret() {
        let text = "one 👍\r\n\ntwo\rthree\nfour"
        // Every character boundary — the places a caret can stand — including the end.
        var offsets = [0]
        for character in text { offsets.append(offsets.last! + character.utf16.count) }
        for offset in offsets {
            let caret = EditorCaret.at(utf16Offset: offset, in: text)
            #expect(self.offset(caret.line, caret.column, in: text) == offset,
                    "Line \(caret.line), Col \(caret.column) is offset \(offset)")
        }
        #expect(offsets.count > 15)
    }

    /// **A stale line table is not trusted** — it describes another text, and its line starts are
    /// another document's. The answer must be this text's.
    @Test func aStaleLineTableIsRebuilt() {
        let stale = EditorLineIndex(text: "a much longer first line\nsecond\nthird")
        #expect(offset(2, index: stale) == 6, "the go landed by another text's line table")
        #expect(offset(3, 2, index: stale) == 13)
    }

    /// A heading jump (no column) still names a line start and still refuses a line that is not
    /// there — the outline's request is unchanged by TE61.
    @Test func aHeadingJumpIsUnchanged() {
        let index = EditorLineIndex(text: text)
        #expect(PlainTextEditor.offset(for: EditorScrollRequest(line: 2, token: 1), in: text, using: index) == 6)
        #expect(PlainTextEditor.offset(for: EditorScrollRequest(line: 9, token: 1), in: text, using: index) == nil)
        #expect(PlainTextEditor.offset(for: EditorScrollRequest(line: 9, token: 1, column: 1), in: text, using: index) == 12)
        #expect(PlainTextEditor.offset(for: EditorScrollRequest(line: 2, token: 1, column: 4), in: text, using: index) == 9)
    }

    // MARK: The status line's door

    private func rings(in host: NSView) -> [NSRect] {
        var rings: [NSRect] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("FocusRing") { rings.append(view.convert(view.bounds, to: host)) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return rings
    }

    private func statusLine(goTo: Bool, rung: EditorStatusLine.Rung? = nil) -> EditorStatusLine {
        EditorStatusLine(facts: EditorDocumentFacts(words: 78, characters: 412, lines: 9, lineEnding: .lf, encoding: "UTF-8"),
                         caret: EditorCaret(line: 48, column: 12), fileSize: "4 KB", forcedRung: rung,
                         goToLine: goTo ? EditorStatusGoToLine(isPresented: .constant(false), lineCount: 9,
                                                               accent: .blue, onGo: { _ in }) : nil)
    }

    /// **"Line, Col" is DRAWN as a button where Go to Line is offered, and as words where it is not**
    /// (Preview) — read off the one handle a hosted SwiftUI button leaves, its focus ring
    /// (`reading-a-hosted-swiftui-control-by-focus-ring`). And being a button costs the line no width
    /// at any rung: the wash's padding is taken back outside it, so the ladder measures as before.
    @Test func theCaretIsAButtonOnlyWhereGoToLineIsOffered() throws {
        func hosted(_ line: EditorStatusLine) -> NSHostingView<AnyView> {
            let host = NSHostingView(rootView: AnyView(line.frame(width: 700)))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 30)
            host.layoutSubtreeIfNeeded()
            return host
        }
        let offered = rings(in: hosted(statusLine(goTo: true)))
        #expect(offered.count == 1, "the line drew \(offered.count) buttons with Go to Line offered")
        #expect(rings(in: hosted(statusLine(goTo: false))).isEmpty, "the caret is a button in Preview")
        // The ring is the caret's: as wide as its words (plus the wash's padding), and right of the
        // two counts — not some other control.
        let words = NSHostingView(rootView: Text(EditorStatusLine.caretCaption(EditorCaret(line: 48, column: 12)))
            .scaledFont(.system(size: 10)).monospacedDigit().fixedSize()).fittingSize.width
        let ring = try #require(offered.first)
        #expect(abs(ring.width - (words + 8)) <= 2, "the button is \(ring.width)pt; the caret's words are \(words)pt")
        #expect(ring.minX > 100, "the button sits at \(ring.minX)pt, not after the counts")
        for rung in EditorStatusLine.Rung.allCases {
            // Measured unframed — inside the 700pt frame above both would read 700.
            let a = NSHostingView(rootView: statusLine(goTo: true, rung: rung)).fittingSize.width
            let b = NSHostingView(rootView: statusLine(goTo: false, rung: rung)).fittingSize.width
            #expect(abs(a - b) < 0.5, "the \(rung) rung is \(a)pt as a button and \(b)pt as words")
        }
    }

    // MARK: A mounted text view

    private func textView(in view: NSView) -> NSTextView? {
        if let found = view as? NSTextView { return found }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    private func spin(_ window: NSWindow) {
        for _ in 0..<10 {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, true)
            window.layoutIfNeeded()
        }
    }

    /// **Line 3 is the third line of the file, however the window wraps the first.** A first line
    /// long enough to take many rows at this width, then a go to line 3, column 4: the caret lands
    /// on the file's third line — where a visual-row count would have put it inside line 1.
    @Test func aMountedEditorGoesToTheLogicalLineNotAWrappedRow() throws {
        let long = String(repeating: "wrapped words ", count: 60)
        let text = long + "\nsecond\nthird line\n"
        let source = EditorSourceStorage(text: text)
        let undo = UndoManager()
        func editor(_ request: EditorScrollRequest?) -> AnyView {
            AnyView(PlainTextEditor(source: source, isEditable: true, fontScale: 1, documentID: "/t.txt",
                                    undoManager: undo, scrollRequest: request)
                .frame(width: 220, height: 120))
        }
        let host = NSHostingView(rootView: editor(nil))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        spin(window)
        let view = try #require(textView(in: host), "no text view mounted — this test sees nothing")
        // The premise: the first line really is wrapped into several rows here.
        try #require(view.textContainer?.widthTracksTextView == true, "wrapping is off, so this proves nothing")
        let rowHeight = try #require(view.font).boundingRectForFont.height
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var firstLineRows = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            firstLineRows = fragment.textLineFragments.count
            return false
        }
        #expect(firstLineRows > 3, "the first line took \(firstLineRows) rows (row height \(rowHeight))")

        host.rootView = editor(EditorScrollRequest(line: 3, token: 1, column: 4))
        spin(window)
        let caret = EditorCaret.at(utf16Offset: view.selectedRange().location, in: view.string)
        #expect(caret == EditorCaret(line: 3, column: 4), "the caret went to \(caret)")
        #expect(view.selectedRange().length == 0)

        // Past the end: the file's last line, "third line" — not the empty place after its break.
        host.rootView = editor(EditorScrollRequest(line: 400, token: 2, column: 1))
        spin(window)
        #expect(EditorCaret.at(utf16Offset: view.selectedRange().location, in: view.string) == EditorCaret(line: 3, column: 1))
    }
}
