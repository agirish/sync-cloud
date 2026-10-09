import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// TE67.3 through the real text view: a keystroke in Preview reaching the source, the document's
/// buffer and the document's undo stack — and every door that must refuse, follow, or stay out of
/// the way.
@MainActor
@Suite(.serialized) struct PreviewEditorViewTests {

    @MainActor
    final class Box {
        let buffer = EditorBuffer()
        var refusals: [PreviewRefusal] = []
        var anchors: [String] = []
    }

    struct Rig {
        let view: PreviewTextView
        let coordinator: PreviewEditorView.Coordinator
        let source: EditorSourceStorage
        let undo: UndoManager
        let box: Box
        let window: NSWindow
        var display: String { view.string }
    }

    /// The view built as `makeNSView` builds it, in a window, the caret at the end.
    private func rig(_ text: String, folder: String? = nil) -> Rig {
        let box = Box()
        box.buffer.text = text
        let source = EditorSourceStorage(text: text)
        box.buffer.follow(source)
        let undo = UndoManager()
        let coordinator = PreviewEditorView.Coordinator(
            session: PreviewEditSession(source: source, undoManager: undo, documentFolder: folder))
        coordinator.onRefusal = { reason, _ in box.refusals.append(reason) }
        coordinator.onFollowAnchor = { box.anchors.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = PreviewTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! PreviewTextView
        coordinator.attach(view)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        spin()
        return Rig(view: view, coordinator: coordinator, source: source, undo: undo, box: box, window: window)
    }

    /// One turn of the run loop: what separates two keystrokes and closes the first one's undo group.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    private func caret(after needle: String, in r: Rig) {
        let found = (r.display as NSString).range(of: needle)
        r.view.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
        spin()
    }

    private func type(_ text: String, in r: Rig) {
        r.view.insertText(text, replacementRange: r.view.selectedRange())
        spin()
    }

    // MARK: Typing

    @Test func typingGoesIntoTheSourceAndPreviewShowsIt() {
        let r = rig("Salt the **pasta** well.")
        caret(after: "pasta", in: r)
        type("!", in: r)
        #expect(r.source.text == "Salt the **pasta!** well.")
        #expect(r.display == "Salt the pasta! well.")
        #expect(r.box.buffer.text == r.source.text)   // the document heard it
        #expect(r.view.selectedRange() == NSRange(location: 15, length: 0))
    }

    /// Typing coalesces as it does in Source: one ⌘Z takes back the run, ⌘⇧Z makes it again.
    @Test func aRunOfTypingIsOneUndoStep() {
        let r = rig("Hello")
        type(" ", in: r); type("w", in: r); type("o", in: r)
        #expect(r.source.text == "Hello wo")
        r.undo.undo(); spin()
        #expect(r.source.text == "Hello")
        #expect(r.display == "Hello")
        r.undo.redo(); spin()
        #expect(r.source.text == "Hello wo")
        #expect(r.display == "Hello wo")
    }

    /// A space at a line's end renders as nothing, so it is shown and held — not refused — and
    /// written with the next character. Moved away from, it goes, and nothing is lost.
    @Test func aSpaceAtALinesEndIsHeldUntilTheNextCharacter() {
        let r = rig("Hello\n\nworld")
        caret(after: "Hello", in: r)
        type(" ", in: r)
        #expect(r.source.text == "Hello\n\nworld")
        #expect(r.display == "Hello \nworld")
        #expect(r.box.refusals.isEmpty)
        type("x", in: r)
        #expect(r.source.text == "Hello x\n\nworld")
        type(" ", in: r)
        caret(after: "world", in: r)
        #expect(r.display == "Hello x\nworld")
        #expect(r.source.text == "Hello x\n\nworld")
    }

    /// Return at a paragraph's end opens an empty one; Bullets there starts a list in it, and the
    /// paragraph above is untouched.
    @Test func bulletsOnTheOpenedParagraphStartsAListThere() {
        let r = rig("one")
        r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); spin()
        #expect(r.source.text == "one")              // nothing written until something is typed
        r.view.performMarkup(.bulletList); spin()
        #expect(r.source.text == "one\n\n- ")
        type("salt", in: r)
        #expect(r.source.text == "one\n\n- salt")
    }

    /// Moving the caret ends the run: typing elsewhere is a step of its own.
    @Test func movingTheCaretStartsANewUndoStep() {
        let r = rig("one two")
        type("!", in: r)
        caret(after: "one", in: r)
        type("?", in: r)
        #expect(r.source.text == "one? two!")
        r.undo.undo(); spin()
        #expect(r.source.text == "one two!")
    }

    /// Backspace at the start of a paragraph would join two blocks: refused, the file untouched, and
    /// the hint raised.
    @Test func aRefusalChangesNothingAndRaisesTheHint() {
        let r = rig("one\n\ntwo")
        let before = r.display
        caret(after: "one\n", in: r)
        r.view.deleteBackward(nil); spin()
        #expect(r.source.text == "one\n\ntwo")
        #expect(r.display == before)
        #expect(r.box.refusals == [.joinsBlocks])
        #expect(!r.undo.canUndo)
    }

    /// Several lines pasted into a paragraph are refused (A10 allows them only in code).
    @Test func pastingSeveralLinesOutsideCodeIsRefused() {
        let r = rig("one")
        let board = NSPasteboard(name: NSPasteboard.Name("PreviewEditorViewTests.\(UUID())"))
        board.clearContents(); board.setString("a\nb", forType: .string)
        _ = r.view.readSelection(from: board, type: .string); spin()
        board.releaseGlobally()
        #expect(r.source.text == "one")
        #expect(r.box.refusals == [.notSupported])
    }

    // MARK: Line endings

    /// Edit writes LF only: a CRLF file is converted by its first edit in Preview too, and one ⌘Z
    /// gives back its bytes.
    @Test func aCRLFFileIsConvertedByItsFirstEditAndOneUndoGivesItBack() {
        let text = "one\r\n\r\ntwo\r\n"
        let r = rig(text)
        caret(after: "one", in: r)
        type("!", in: r)
        #expect(r.source.text == "one!\n\ntwo\n")
        r.undo.undo(); spin()
        #expect(r.source.text == text)
        #expect(r.box.buffer.text == text)
    }

    // MARK: Undo belongs to the document

    /// ⌘Z in editable Preview is the document's, never a file operation's: the text view vends the
    /// document's stack, and with `allowsUndo` off registers nothing of its own.
    @Test func undoInPreviewIsTheDocumentsStack() {
        let r = rig("Hello")
        #expect(r.view.undoManager === r.undo)
        #expect(!r.view.allowsUndo)
        type("!", in: r)
        #expect(r.undo.canUndo)
        #expect(r.undo.undoActionName == "Typing")
    }

    /// An undo arriving from outside — Source, the Edit menu — is followed: Preview re-renders, and
    /// the caret goes to where the change was.
    @Test func aChangeFromOutsideIsFollowed() {
        let r = rig("one two")
        r.source.replace(NSRange(location: 3, length: 0), with: " and", undoManager: r.undo); spin()
        #expect(r.display == "one and two")
        #expect(r.view.selectedRange() == NSRange(location: 7, length: 0))
    }

    // MARK: Input methods (A12)

    /// Marked text stays in Preview until it is committed; the commit is one edit in the source.
    @Test func aCompositionIsWrittenWhenItIsCommitted() {
        let r = rig("ab")
        r.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(r.source.text == "ab")
        #expect(r.display == "abk")
        r.view.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(r.source.text == "abか")
        #expect(r.display == "abか")
        #expect(!r.view.hasMarkedText())
        r.undo.undo(); spin()
        #expect(r.source.text == "ab")
        #expect(!r.undo.canUndo)   // the composition registered nothing of its own
    }

    /// `unmarkText` accepts the marked text — focus leaving mid-composition keeps the word.
    @Test func unmarkingCommitsTheComposition() {
        let r = rig("ab")
        r.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        r.view.unmarkText(); spin()
        #expect(r.source.text == "abか")
        #expect(r.display == "abか")
    }

    /// Escape: the input method clears the marked text, and nothing reaches the source.
    @Test func aCancelledCompositionLeavesNothing() {
        let r = rig("ab")
        r.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        r.view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        r.view.unmarkText(); spin()
        #expect(r.source.text == "ab")
        #expect(r.display == "ab")
        #expect(!r.undo.canUndo)
    }

    // MARK: Links and task boxes

    /// A plain click on a link places the caret; ⌘-click follows it (§1.2).
    @Test func aPlainClickOnALinkPlacesTheCaretAndCommandClickFollowsIt() {
        let r = rig("See [the end](#end).")
        r.coordinator.clickedOnLink(URL(string: "#end")!, at: 6, command: false); spin()
        #expect(r.view.selectedRange() == NSRange(location: 6, length: 0))
        #expect(r.box.anchors.isEmpty)
        r.coordinator.clickedOnLink(URL(string: "#end")!, at: 6, command: true); spin()
        #expect(r.box.anchors == ["end"])
    }

    /// A click on a task box ticks it in the source — now with undo (A8).
    @Test func clickingATaskBoxTicksItWithUndo() throws {
        let r = rig("- [ ] salt")
        let box = try #require((0..<(r.display as NSString).length).first {
            r.view.textStorage?.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "task"
        })
        let onScreen = r.view.firstRect(forCharacterRange: NSRange(location: box, length: 1), actualRange: nil)
        let point = r.view.convert(r.window.convertFromScreen(onScreen), from: nil)
        #expect(r.view.taskBox(at: NSPoint(x: point.midX, y: point.midY)) == box)
        r.coordinator.perform(RenderedEdit(range: NSRange(location: box, length: 1), action: .tickTask)); spin()
        #expect(r.source.text == "- [x] salt")
        #expect(r.undo.undoActionName == EditorWorkspaceView.taskActionName)
        r.undo.undo(); spin()
        #expect(r.source.text == "- [ ] salt")
    }

    // MARK: Drawing

    /// Quote bars and code bands come from TextKit 2's fragment hook — and the view stays on
    /// TextKit 2 having drawn them.
    @Test func quotesAndCodeGetTheirFragmentsOnTextKit2() throws {
        let r = rig("> said\n\n```\nlet x\n```\n\nplain")
        let manager = try #require(r.view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        var kinds: [String] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            guard let block = fragment as? PreviewBlockFragment else { kinds.append("other"); return true }
            kinds.append(block.isCode ? "code" : block.quoteDepth > 0 ? "quote\(block.quoteDepth)" : "plain")
            return true
        }
        #expect(kinds == ["quote1", "code", "plain"])
        #expect(r.view.textLayoutManager != nil)
    }

    // MARK: The toggle

    /// Offered in Preview and Split, for a writable Markdown document — never in Source, never for
    /// a read-only or non-Markdown file, never where the document was refused.
    @Test func thePillIsOfferedOnlyForAWritableMarkdownPreview() {
        func offered(_ mode: EditorMode, markdown: Bool = true, readOnly: Bool = false,
                     refused: Bool = false, document: Bool = true) -> Bool {
            PreviewEditToggle.isOffered(hasDocument: document, isRefused: refused, isMarkdown: markdown,
                                        isReadOnly: readOnly, mode: mode)
        }
        #expect(offered(.preview))
        #expect(offered(.split))
        #expect(!offered(.edit))
        #expect(!offered(.preview, markdown: false))
        #expect(!offered(.preview, readOnly: true))
        #expect(!offered(.preview, refused: true))
        #expect(!offered(.preview, document: false))
    }

    /// **Past 256 KB Preview is read-only, and the pill says so** (plan C23): still offered — the
    /// setting is kept — but the gate the workspace and the menus mount by says no.
    ///
    /// Mutation: drop `isTooLong` from `editsInPreview`, and the over-long note is editable.
    @Test func aDocumentOverTheLimitIsReadOnlyInPreview() {
        func edits(_ length: Int) -> Bool {
            EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                               isMarkdown: true, isReadOnly: false, mode: .preview, length: length)
        }
        #expect(PreviewEditToggle.maximumLength == 262_144)
        #expect(edits(PreviewEditToggle.maximumLength))
        #expect(!edits(PreviewEditToggle.maximumLength + 1))
        #expect(PreviewEditToggle.isOffered(hasDocument: true, isRefused: false, isMarkdown: true, isReadOnly: false,
                                            mode: .preview), "the pill stays, dimmed")
        #expect(PreviewEditToggle.tooLongTooltip == "Too long to edit in Preview — use Source.")
    }

    /// The intro shows the first time editing is turned on, and only then; off by default.
    @Test func theIntroShowsOnceAndEditingStartsOff() {
        #expect(PreviewEditToggle.showsIntro(turningOn: true, introSeen: false))
        #expect(!PreviewEditToggle.showsIntro(turningOn: true, introSeen: true))
        #expect(!PreviewEditToggle.showsIntro(turningOn: false, introSeen: false))
        #expect(EditorTextSettings.editsInPreviewDefault == false)
    }

    // MARK: The hint

    /// The hint replaces the counts, so it must never be what pushes the line past its edge: the
    /// link alone fits the narrowest document column at every text size, and the whole sentence
    /// fits it at the default size.
    @Test func theHintFitsTheNarrowestColumn() {
        let facts = EditorDocumentFacts(words: 4_218, characters: 24_907, lines: 412, lineEnding: .lf,
                                        encoding: "UTF-8")
        func width(_ rung: EditorStatusHint.Rung, _ scale: CGFloat) -> CGFloat {
            let line = EditorStatusLine(facts: facts, caret: EditorCaret(line: 408, column: 118),
                                        hint: EditorStatusHint(token: 1, onShowInSource: {}, forcedRung: rung))
            return NSHostingView(rootView: AnyView(line.environment(\.appFontScale, scale))).fittingSize.width
        }
        for size in FontSize.allCases {
            #expect(width(.link, size.scale) <= EditorLayoutMetrics.minDocumentWidth, "\(size)")
        }
        #expect(width(.sentence, 1) <= EditorLayoutMetrics.minDocumentWidth)
    }

    /// A second refusal while the first is up is a new hint — its token restarts the host's timer.
    @Test func eachRefusalIsANewHint() {
        #expect(EditorStatusHint(token: 1, onShowInSource: {}) != EditorStatusHint(token: 2, onShowInSource: {}))
        #expect(EditorStatusHint(token: 1, onShowInSource: {}) == EditorStatusHint(token: 1, onShowInSource: {}))
        #expect(EditorStatusHint.needsSource == "That change needs Source.")
    }

    /// **Markdown only** (his decision, 2026-10-05): with the setting on, a `.txt` — and anything
    /// else that is not Markdown — still gets no editable Preview, in any mode.
    @Test func onlyMarkdownEverGetsTheEditablePreview() {
        for mode in EditorMode.allCases {
            #expect(!EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                                        isMarkdown: PairContentKind.isMarkdown(path: "/n/notes.txt"),
                                                        isReadOnly: false, mode: mode, length: 0), "\(mode)")
            #expect(!EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                                        isMarkdown: PairContentKind.isMarkdown(path: "/n/letter.rtf"),
                                                        isReadOnly: false, mode: mode, length: 0), "\(mode)")
        }
        #expect(EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                                   isMarkdown: PairContentKind.isMarkdown(path: "/n/Notes.MD"),
                                                   isReadOnly: false, mode: .preview, length: 0))
        #expect(!EditorWorkspaceView.editsInPreview(preference: false, hasDocument: true, isRefused: false,
                                                    isMarkdown: true, isReadOnly: false, mode: .preview, length: 0))
    }

    // MARK: Routing

    /// The Markup menu and its chords reach Preview when the caret is in it — through the mark on
    /// its scroll view, and into the SOURCE, never the display.
    @Test func markupChordsReachPreviewWhenItHasTheCaret() {
        let r = rig("Salt the pasta well.")
        let found = (r.display as NSString).range(of: "pasta")
        r.view.setSelectedRange(found); spin()
        #expect(EditorDocumentSurface.caretTextView(in: r.window) === r.view)
        #expect(EditorDocumentSurface.applyMarkup(.bold, in: r.window))
        spin()
        #expect(r.source.text == "Salt the **pasta** well.")
        #expect(r.display == "Salt the pasta well.")
        r.undo.undo(); spin()
        #expect(r.source.text == "Salt the pasta well.")
    }

    // MARK: Images

    private static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// An awaiting wait, not a run-loop spin: the load is a main-actor task, and a synchronous spin
    /// starves it.
    private func waitForImage(_ r: Rig, _ done: @escaping () -> Bool) async {
        _ = await LayoutPumpWait.pump(r.view, upTo: 5, until: done)
    }

    private func imageAttachment(in r: Rig) -> NSTextAttachment? {
        let storage = r.view.textStorage!
        for i in 0..<storage.length where storage.attribute(.previewImageSource, at: i, effectiveRange: nil) != nil {
            return storage.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment
        }
        return nil
    }

    /// An image block draws the picture — from the document's folder, off the main actor — at its
    /// own size within the column, not a placeholder.
    @Test func anImageBlockDrawsThePicture() async throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let folder = (note as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder + "/Images", withIntermediateDirectories: true)
        try Self.png(width: 120, height: 80).write(to: URL(fileURLWithPath: folder + "/Images/Pic.png"))
        let r = rig("Before\n\n![a pic](Images/Pic.png)\n\nAfter", folder: folder)
        await waitForImage(r) { imageAttachment(in: r)?.image?.size.width == 120 }
        let attachment = try #require(imageAttachment(in: r))
        #expect(attachment.image?.size == CGSize(width: 120, height: 80))
        #expect(attachment.bounds.size == CGSize(width: 120, height: 80))
        // Typing elsewhere keeps it: the splice leaves an unchanged attachment where it was.
        caret(after: "After", in: r)
        type("!", in: r)
        #expect(imageAttachment(in: r)?.image?.size == CGSize(width: 120, height: 80))
    }

    /// An image Preview may not draw keeps a placeholder that says why.
    @Test func aRemoteImageSaysWhyItIsNotDrawn() async throws {
        let r = rig("![x](https://example.com/a.png)", folder: "/tmp")
        let placeholder = try #require(imageAttachment(in: r)).bounds.width
        await waitForImage(r) { (imageAttachment(in: r)?.bounds.width ?? 0) > placeholder }
        // "Image — Remote images aren’t downloaded." is wider than the loading "Image".
        #expect(try #require(imageAttachment(in: r)).bounds.width > placeholder)
    }

    /// Wide or tall pictures are scaled to the column and the preview's height cap, keeping shape.
    @Test func picturesFitTheColumnAndTheHeightCap() {
        #expect(PreviewEditSession.fitted(CGSize(width: 2000, height: 1000), column: 500, scale: 1)
                == CGSize(width: 500, height: 250))
        #expect(PreviewEditSession.fitted(CGSize(width: 400, height: 1680), column: 500, scale: 1)
                == CGSize(width: 100, height: 420))
        #expect(PreviewEditSession.fitted(CGSize(width: 50, height: 40), column: 500, scale: 1)
                == CGSize(width: 50, height: 40))
    }

    // MARK: Split (TE67.4)

    /// No feedback loop: the pane the person scrolls leads, the other's echo within the window is
    /// dropped, and after it the other pane may lead.
    @Test func splitScrollingHasNoFeedbackLoop() {
        var follow = SplitScrollFollow()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        func ask(_ pane: SplitScrollFollow.Pane, _ after: TimeInterval) -> Bool {
            follow.shouldFollow(from: pane, now: t0.addingTimeInterval(after))
        }
        let led = ask(.source, 0), stillScrolling = ask(.source, 0.05)
        let echo = ask(.preview, 0.1), later = ask(.preview, 0.4), itsEcho = ask(.source, 0.45)
        #expect(led && stillScrolling)
        #expect(!echo)          // the follower's programmatic scroll, reported back
        #expect(later)          // a person scrolling Preview, after the window
        #expect(!itsEcho)
        #expect(follow.leader == .preview)
    }

    /// Preview follows a source line by moving the view, never the caret — and then reports that
    /// line as the one at the top.
    @Test func previewFollowsALineWithoutMovingTheCaret() {
        let paragraphs = (1...60).map { "Paragraph number \($0) with some words in it." }
        let r = rig(paragraphs.joined(separator: "\n\n"))
        r.view.setSelectedRange(NSRange(location: 3, length: 0)); spin()
        let caret = r.view.selectedRange()
        r.coordinator.follow(line: 81); spin()     // the 41st paragraph
        #expect(r.view.selectedRange() == caret)
        #expect(r.view.visibleRect.minY > 200)
        #expect(r.coordinator.topVisibleLine() == 81)
    }

    /// Both halves of Split are views of one storage: Preview's typing is in Source at once, and
    /// Source's typing in Preview.
    @Test func anEditInEitherPaneIsInTheOther() {
        let r = rig("one two")
        let sourceScroll = EditorTextView.scrollableTextView()
        sourceScroll.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        r.window.contentView?.addSubview(sourceScroll)
        let sourceView = sourceScroll.documentView as! EditorTextView
        sourceView.allowsUndo = true
        PlainTextEditor.show(r.source, in: sourceView)
        r.window.makeFirstResponder(r.view)
        caret(after: "one", in: r)
        type("!", in: r)
        #expect(sourceView.string == "one! two")
        r.window.makeFirstResponder(sourceView)
        sourceView.setSelectedRange(NSRange(location: 8, length: 0))
        sourceView.insertText("?", replacementRange: sourceView.selectedRange()); spin()
        #expect(r.source.text == "one! two?")
        #expect(r.display == "one! two?")
    }

    // MARK: Tables (TE67.5)

    /// Typing in an aligned table re-aligns it as you go (decision T) — and the run of typing, each
    /// keystroke of which re-padded the whole table, is still one ⌘Z, giving back the table's bytes.
    @Test func typingInATableIsOneUndoStepThatGivesBackItsBytes() {
        let table = "| a   | b   |\n| --- | --- |\n| c   | d   |"
        let r = rig(table)
        caret(after: "c", in: r)
        type("x", in: r); type("y", in: r); type("z", in: r); type("w", in: r)
        #expect(r.source.text == "| a     | b   |\n| ----- | --- |\n| cxyzw | d   |")
        #expect(r.display == "a\tb\ncxyzw\td")
        r.undo.undo(); spin()
        #expect(r.source.text == table)
        #expect(!r.undo.canUndo)
    }

    // MARK: Review fixes, 2026-10-05

    /// ⌫ after two held spaces takes a held space — never the next paragraph's first letter.
    @Test func backspaceAfterHeldSpacesTakesASpaceNotTheNextLetter() {
        let r = rig("Hello\n\nworld")
        caret(after: "Hello", in: r)
        type(" ", in: r); type(" ", in: r)
        r.view.deleteBackward(nil); spin()
        #expect(r.source.text == "Hello\n\nworld")
        #expect(r.display == "Hello \nworld")
        r.view.deleteBackward(nil); spin()
        #expect(r.display == "Hello\nworld")
        #expect(r.source.text == "Hello\n\nworld")
        #expect(r.box.refusals.isEmpty)
    }

    /// ⌫ in the empty paragraph Return opened closes it, quietly.
    @Test func backspaceInAnOpenedParagraphClosesIt() {
        let r = rig("one\n\ntwo")
        caret(after: "one", in: r)
        r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); spin()
        #expect(r.display == "one\n\ntwo")
        r.view.deleteBackward(nil); spin()
        #expect(r.display == "one\ntwo")
        #expect(r.source.text == "one\n\ntwo")
        #expect(r.box.refusals.isEmpty)
    }

    /// A word composed on the opened paragraph is written there — not into the next one.
    @Test func aCompositionOnAnOpenedParagraphIsWrittenThere() {
        let r = rig("one\n\ntwo")
        caret(after: "one", in: r)
        r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); spin()
        r.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        r.view.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(r.source.text == "one\n\nか\n\ntwo")
    }

    /// Replace All measures on the display: its ranges are mapped past a held space.
    @Test func replaceAllIsMappedPastAHeldSpace() {
        let r = rig("Hello\n\nworld and world")
        caret(after: "Hello", in: r)
        type(" ", in: r)
        let display = r.display as NSString
        let first = display.range(of: "world")
        let second = display.range(of: "world", options: .backwards)
        r.coordinator.apply(r.coordinator.session.performAll([
            RenderedEdit(range: first, text: "earth", action: .typing),
            RenderedEdit(range: second, text: "earth", action: .typing)])); spin()
        #expect(r.source.text == "Hello\n\nearth and earth")
    }

    /// Another undo manager's group closing is none of this run's business.
    @Test func anotherUndoManagerDoesNotEndTheRun() {
        let r = rig("x")
        type("a", in: r)
        let other = UndoManager()
        other.registerUndo(withTarget: r.view) { _ in }
        spin()
        type("b", in: r)
        r.undo.undo(); spin()
        #expect(r.source.text == "x")
    }

    /// ⌘B with nothing selected, then typing: the bold character is a step of its own.
    @Test func aStyledCharacterIsItsOwnUndoStep() {
        let r = rig("x")
        type("a", in: r)
        r.view.performMarkup(.bold); spin()
        type("b", in: r)
        #expect(r.source.text == "xa**b**")
        r.undo.undo(); spin()
        #expect(r.source.text == "xa")
    }

    /// A space held after a task's box is a space: it does not draw a second box.
    @Test func aHeldSpaceAfterABoxIsNoBox() {
        let r = rig("- [ ] ")
        type(" ", in: r)
        let storage = r.view.textStorage!
        let boxes = (0..<storage.length).filter { storage.attribute(.attachment, at: $0, effectiveRange: nil) != nil }
        #expect(boxes.count == 1)
    }

    /// A table wider than the column is read-only at the column's default width too — and the rule
    /// survives a text-size change.
    @Test func theWideTableRuleHoldsAtEveryWidthAndSize() {
        let cells = String(repeating: "wide ", count: 40)
        let source = "| a | b |\n| --- | --- |\n| \(cells) | \(cells) |"
        let session = PreviewEditSession(source: EditorSourceStorage(text: source), undoManager: nil)
        #expect(session.projection.blocks[0].readOnly == .wideTable)
        session.style = .init(scale: 1.2, columnWidth: session.style.columnWidth)
        #expect(session.projection.blocks[0].readOnly == .wideTable)
    }

    /// A rule spans the column it is in, after the column changes too.
    @Test func attachmentsAreSizedAgainWhenTheColumnChanges() throws {
        let session = PreviewEditSession(source: EditorSourceStorage(text: "a\n\n---\n\nb"), undoManager: nil)
        func rule() -> NSTextAttachment? {
            (0..<session.display.length).lazy.compactMap {
                session.display.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "rule"
                    ? session.display.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment : nil
            }.first
        }
        let wide = try #require(rule()).bounds.width
        session.columnWidth = 300
        #expect(try #require(rule()).bounds.width < wide)
        #expect(try #require(rule()).bounds.width <= 300)
    }

    /// In Split, typing in Source leaves Preview's caret and scroll alone — Preview moving would
    /// scroll Source after it.
    @Test func typingInSourceLeavesPreviewsCaretAlone() {
        let r = rig("one two three")
        let sourceScroll = EditorTextView.scrollableTextView()
        sourceScroll.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        r.window.contentView?.addSubview(sourceScroll)
        let sourceView = sourceScroll.documentView as! EditorTextView
        PlainTextEditor.show(r.source, in: sourceView)
        r.view.setSelectedRange(NSRange(location: 2, length: 0)); spin()
        r.window.makeFirstResponder(sourceView)
        sourceView.setSelectedRange(NSRange(location: 13, length: 0))
        sourceView.insertText("!", replacementRange: sourceView.selectedRange()); spin()
        #expect(r.display == "one two three!")
        #expect(r.view.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// The heading menu, the outline and a `#fragment` link go to a line in Preview too: caret and
    /// scroll — not only in Split.
    @Test func navigatingToALinePutsTheCaretThere() {
        let paragraphs = (1...60).map { "Paragraph number \($0) with some words in it." }
        let r = rig(paragraphs.joined(separator: "\n\n"))
        r.coordinator.navigate(toLine: 81); spin()
        #expect(r.coordinator.topVisibleLine() == 81)
        let block = r.coordinator.session.projection.blocks.first { $0.line == 81 }!
        #expect(r.view.selectedRange() == NSRange(location: block.rendered.location, length: 0))
    }

    /// Preview's right-click menu carries the Markup verbs and the Format Bar switch, as Source's.
    @Test func theRightClickMenuIsSources() throws {
        let r = rig("Salt the pasta.")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: r.window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(r.coordinator.textView(r.view, menu: NSMenu(), for: event, at: 0))
        #expect(menu.items.first?.title == "Markup")
        #expect(menu.items.contains { $0.title == PlainTextEditor.Coordinator.formatBarTitle })
    }

    /// A refusal says where it was, so Show in Source can put the caret there.
    @Test func aRefusalCarriesItsSourceOffset() {
        let r = rig("one\n\ntwo")
        var offsets: [Int] = []
        r.coordinator.onRefusal = { _, offset in offsets.append(offset) }
        caret(after: "one\n", in: r)
        r.view.deleteBackward(nil); spin()
        #expect(offsets == [5])     // the start of "two"
    }

    /// Links say how to follow them; text Preview cannot edit says where to.
    @Test func linksAndReadOnlyTextExplainThemselves() {
        let r = rig("See [it](http://x.y).\n\n<div>raw</div>")
        let storage = r.view.textStorage!
        let link = (r.display as NSString).range(of: "it")
        #expect(storage.attribute(.toolTip, at: link.location, effectiveRange: nil) as? String == PreviewEditSession.linkTip)
        let raw = (r.display as NSString).range(of: "raw")
        #expect(storage.attribute(.toolTip, at: raw.location, effectiveRange: nil) as? String == PreviewEditSession.readOnlyTip)
    }
}
