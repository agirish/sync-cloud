import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
import FileExplorerTestSupport
import EventsTestSupport

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

    /// ⌘Z as AppKit sends it: `undo:` up the responder chain from whatever has the keyboard — never
    /// `undo.undo()`, which names the stack the test expects and so cannot see ⌘Z reaching another
    /// (UND-10: in editable Preview it reached the window's, the file operations').
    private func sendUndo(_ r: Rig) {
        _ = r.window.firstResponder?.tryToPerform(EditorUndoCommands.undo, with: nil)
        spin()
    }

    /// ⇧⌘Z, the same way.
    private func sendRedo(_ r: Rig) {
        _ = r.window.firstResponder?.tryToPerform(EditorUndoCommands.redo, with: nil)
        spin()
    }

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
        sendUndo(r)
        #expect(r.source.text == "Hello")
        #expect(r.display == "Hello")
        sendRedo(r)
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
        sendUndo(r)
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

    // MARK: Attribute-only changes (review V1)

    /// **A style change is not a deletion.** Font ▸ Show Fonts, Colors, Underline, the alignment and
    /// writing-direction items, a colour swatch dropped on the text: AppKit asks the delegate about
    /// the whole selection with `nil` replacement strings — "change the attributes, keep the
    /// characters". Read as empty strings, that was a delete of everything selected (review V1,
    /// 2026-10-09). Through the real actions, over a one-paragraph note selected whole.
    ///
    /// Mutation: map `nil` strings to `""` again, and the note is emptied.
    @Test func aStyleChangeFromAppKitLeavesTheTextAlone() {
        defer { forgetTheColorPanelsGeometry() }
        let text = "Salt the **pasta** well."
        let r = rig(text)
        #expect(!r.view.usesFontPanel, "no Font panel to send a style change from")
        let all = NSRange(location: 0, length: (r.display as NSString).length)
        let doors: [(String, () -> Void)] = [
            ("underline", { r.view.underline(nil) }),
            ("alignCenter", { r.view.alignCenter(nil) }),
            ("changeFont", { r.view.changeFont(NSFontManager.shared) }),
            ("changeColor", { let well = NSColorWell(); well.color = .red; r.view.changeColor(well) }),
            ("writing direction", { r.view.makeTextWritingDirectionRightToLeft(nil) }),
        ]
        for (name, act) in doors {
            r.view.setSelectedRange(all); spin()
            act(); spin()
            #expect(r.source.text == text, "\(name)")
            #expect(r.display == "Salt the pasta well.", "\(name)")
        }
        #expect(!r.undo.canUndo)
    }

    /// **`changeColor` brings up the shared colour panel, whatever its sender**, because
    /// `NSTextView` reads the colour from `NSColorPanel.shared` rather than from the swatch. AppKit
    /// then autosaves the panel's frame, toolbar and split-view geometry into the standard
    /// domain, which under `swift test` is the `swiftpm-testing-helper` plist every test process
    /// on the machine shares. Nothing reads those keys; they go so a package run leaves that
    /// domain without them. Matched by name because AppKit, not this code, picks the keys.
    private func forgetTheColorPanelsGeometry() {
        let standard = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        for key in (standard.persistentDomain(forName: domain) ?? [:]).keys where key.contains("NSColorPanel") {
            standard.removeObject(forKey: key)
        }
    }

    // MARK: Images and files (review V5)

    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("PreviewEditorViewTests.\(UUID())"))
        board.clearContents()
        fill(board)
        return board
    }

    /// **A file dropped on Preview is refused, never written in as its path** (review V5): with rich
    /// text off, AppKit's own drop typed the path into the paragraph, and it reached the Markdown as
    /// a paste — `Hi /tmp/Pasta.jpg`. Source imports an image into Images; Preview says it needs
    /// Source. An image file and any other file alike. Through `performDragOperation`, AppKit's door.
    @Test func aFileDroppedOnPreviewIsRefusedNotTypedAsItsPath() async throws {
        let log = LogCapture()
        let image = try TestTextFiles.write("", named: "Pasta.jpg")
        let other = try TestTextFiles.write("notes", named: "Notes.pdf")
        for path in [image, other] {
            let r = rig("Hi")
            let pasteboard = board { _ = $0.writeObjects([URL(fileURLWithPath: path) as NSURL]) }
            defer { pasteboard.releaseGlobally() }
            let point = r.view.convert(NSPoint(x: 30, y: 25), to: nil)
            _ = r.view.performDragOperation(EditorMarkdownTypingTests.Drag(pasteboard, at: point)); spin()
            #expect(r.source.text == "Hi", "\(path)")
            #expect(r.display == "Hi", "\(path)")
            #expect(r.box.refusals == [.notSupported], "\(path): no hint said why nothing happened")
        }
        #expect(await log.holds(.info, containing: "[preview-edit] Refused a drop of a picture or a file"))
    }

    /// **A picture pasted into Preview says it needs Source** (review V5): a screenshot puts image
    /// data and no text on the clipboard, and Preview's plain-text paste found nothing and said
    /// nothing. A file copied in Finder carries its name as text, which is not what anybody meant
    /// by pasting it. Text pastes as before.
    @Test func anImagePasteInPreviewSaysItNeedsSource() throws {
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        let file = try TestTextFiles.write("", named: "Copied.png")
        for (name, fill) in [("screenshot", { (b: NSPasteboard) in _ = b.setData(png, forType: .png) }),
                             ("Finder copy", { (b: NSPasteboard) in
                                 b.writeObjects([URL(fileURLWithPath: file) as NSURL])
                                 b.addTypes([.string], owner: nil); _ = b.setString("Copied.png", forType: .string) })] {
            let r = rig("Hi")
            let pasteboard = board(fill)
            defer { pasteboard.releaseGlobally() }
            r.view.paste(from: pasteboard); spin()
            #expect(r.source.text == "Hi", "\(name)")
            #expect(r.box.refusals == [.notSupported], "\(name)")
        }
        let r = rig("Hi")
        let text = board { _ = $0.setString("!", forType: .string) }
        defer { text.releaseGlobally() }
        r.view.paste(from: text); spin()
        #expect(r.source.text == "Hi!")
        #expect(r.box.refusals.isEmpty)
    }

    // MARK: Requests from the workspace (review V6)

    /// **A request handed over in a view update reports back a turn later** (review V6): going to
    /// a line puts the caret there and reports it, and a follow scrolls — both into the workspace's
    /// state, which must not be written while SwiftUI is updating. Nothing reports inside the call;
    /// the caret and the report arrive on the next turn. A request already taken is not taken twice.
    ///
    /// Mutation: act on the request at once, and the first check fails.
    @Test func aRequestFromAnUpdateReportsOnTheNextTurn() async throws {
        let paragraphs = (1...30).map { "Paragraph number \($0) with some words in it." }
        let r = rig(paragraphs.joined(separator: "\n\n"))
        var reported: [NSRange] = []
        r.coordinator.onSourceSelection = { reported.append($0) }
        let request = EditorScrollRequest(line: 41, token: 1)
        r.coordinator.take(follow: nil, scroll: request)
        #expect(reported.isEmpty, "the caret was reported inside the update")
        // A main-queue turn — which a synchronous test never yields.
        try await Task.sleep(for: .milliseconds(50))
        let block = r.coordinator.session.projection.blocks.first { $0.line == 41 }!
        #expect(r.view.selectedRange().location == block.rendered.location)
        #expect(reported.count == 1)
        r.coordinator.take(follow: nil, scroll: request)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reported.count == 1, "the same request was taken twice")
    }

    /// **A triple-clicked paragraph, or a run over several blocks, is reported to the format bar**
    /// (FMT-14). A triple-click selects the paragraph AND the break after it, which maps to no one
    /// block, so nothing was reported: the bar kept the last caret's state — dark over a bold
    /// paragraph whose Bold press took the bold off. It is reported as a verb maps it.
    ///
    /// Mutation: have the session map with `sourceSelection` alone again, and nothing is reported.
    @Test func aTripleClickedParagraphIsReportedToTheBar() throws {
        let r = rig("**para**\n\nNext.")
        var reported: [NSRange] = []
        r.coordinator.onSourceSelection = { reported.append($0) }
        let blocks = r.coordinator.session.projection.blocks
        let triple = NSRange(location: blocks[0].rendered.location,
                             length: blocks[1].rendered.location - blocks[0].rendered.location)
        r.view.setSelectedRange(triple); spin()
        let paragraph = try #require(reported.last, "a triple-clicked paragraph was not reported")
        #expect(paragraph == NSRange(location: 2, length: 4), "reported \(paragraph), not the bold word")
        let lit = MarkupFormatState.of(r.source.text, selection: paragraph).lit
        #expect(lit.contains(.bold), "the bar's state over it lights \(lit.map(\.title))")
        // Over two blocks: from the first selected character's place to the last's.
        reported = []
        r.view.setSelectedRange(NSRange(location: 1, length: blocks[1].rendered.location + 2 - 1)); spin()
        let across = try #require(reported.last, "a run over two blocks was not reported")
        #expect(across == NSRange(location: 3, length: 9), "reported \(across)")
    }

    /// **A style set for what is typed next is reported, and lit on the bar** (FMT-15). ⌘B with a
    /// bare caret writes nothing in Preview — it sets Bold for the next character — and the bar
    /// never showed it: Bold stayed dark, and a second press to check turned it off unseen. The
    /// workspace lights what Preview reports while the bar acts on Preview.
    ///
    /// Mutation: drop `reportPending()` from `apply`, and the first report never comes.
    @Test func aPendingStyleIsReportedForTheBarToLight() throws {
        let r = rig("Salt the pasta.")
        var pending: [Set<MarkupVerb>] = []
        r.coordinator.onPendingStyles = { pending.append($0) }
        caret(after: "pasta", in: r)
        r.view.performMarkup(.bold); spin()
        #expect(r.source.text == "Salt the pasta.", "a pending style wrote something")
        #expect(pending.last == [.bold], "Bold pending was reported as \(String(describing: pending.last))")
        r.view.performMarkup(.inlineCode); spin()
        #expect(pending.last == [.bold, .inlineCode])
        r.view.performMarkup(.bold); spin()
        #expect(pending.last == [.inlineCode], "Bold pressed again is still reported pending")
        // The caret moving on drops them.
        caret(after: "Salt", in: r)
        #expect(pending.last == [], "a moved caret kept \(String(describing: pending.last)) pending")
        // The bar lights what is pending, over the selection's own state.
        let state = MarkupFormatState.none.lighting([.italic])
        #expect(state.lit == [.italic])
        let workspace = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/EditorWorkspaceView.swift"), encoding: .utf8)
        #expect(workspace.contains("onPendingStyles: { previewPending = $0 }")
                && workspace.contains("EditorFormatBar(state: formatState.lighting(barActsOnPreview ? previewPending : [])"),
                "the workspace does not light Preview's pending styles on the bar")
    }

    // MARK: Saying why (review V9)

    /// **A Markup verb Preview refuses says so in the log**, as Source's refusals do (review V9):
    /// the session's own line was `.debug`, below the app's INFO level, so a verb from the menu that
    /// did nothing left no trace. It is INFO now, and names the verb as the menu does — the one
    /// line (round 2: the view wrote a second). Bold over two paragraphs crosses blocks.
    ///
    /// Mutation: log the session's refusals at debug, and the capture holds nothing at INFO.
    @Test func aRefusedMarkupVerbIsLogged() async {
        let log = LogCapture()
        let r = rig("one\n\ntwo")
        r.view.setSelectedRange(NSRange(location: 1, length: 4)); spin()
        r.view.performMarkup(.strikethrough); spin()
        #expect(r.source.text == "one\n\ntwo")
        #expect(r.box.refusals.count == 1, "the verb was not refused — this case proves nothing")
        #expect(await log.holds(.info, containing: "[edit] preview refused Markup ▸ Strikethrough in paragraph at source 1: crossesBlocks"))
    }

    /// **A Replace All that could not make every match says how many** (review V9): the reason was
    /// dropped on the way to the status line, which said the generic sentence over a refusal that
    /// had replaced nothing at all.
    @Test func aRefusedReplaceAllSaysHowManyMatchesNeedSource() throws {
        let hint = EditorStatusHint(token: 1, onShowInSource: {}, reason: .replaceAll(failed: 2, of: 5))
        #expect(hint.sentence(.sentence) == "2 of 5 matches need Source — none were replaced.")
        #expect(hint.sentence(.short) == "2 of 5 need Source.")
        #expect(hint.sentence(.link) == nil)
        // ST15: one of one is a match that needs Source, not "1 of 1 matches need Source".
        let one = EditorStatusHint(token: 1, onShowInSource: {}, reason: .replaceAll(failed: 1, of: 1))
        #expect(one.sentence(.sentence) == "1 of 1 match needs Source — none was replaced.")
        #expect(one.sentence(.short) == "1 of 1 needs Source.")
        let oneOfMany = EditorStatusHint(token: 1, onShowInSource: {}, reason: .replaceAll(failed: 1, of: 1_204))
        #expect(oneOfMany.sentence(.sentence) == "1 of 1,204 matches needs Source — none were replaced.")
        // Both counts past a thousand are grouped, as the rest of Edit's counts are (ED15).
        let (many, all) = (1_200.formatted(), 12_500.formatted())
        try #require(many != "1200", "this locale groups no digits — the case below measures nothing")
        let large = EditorStatusHint(token: 1, onShowInSource: {}, reason: .replaceAll(failed: 1_200, of: 12_500))
        #expect(large.sentence(.sentence) == "\(many) of \(all) matches need Source — none were replaced.")
        #expect(large.sentence(.short) == "\(many) of \(all) need Source.")
        #expect(large.sentence(.sentence)?.contains("1200") == false)
        let plain = EditorStatusHint(token: 1, onShowInSource: {}, reason: .joinsBlocks)
        #expect(plain.sentence(.sentence) == EditorStatusHint.needsSource)
        #expect(plain.sentence(.short) == EditorStatusHint.needsSourceShort)
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
        sendUndo(r)
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

    /// **⌘Z while a word is being composed commits the word and takes nothing back** (UND-8).
    /// Preview registers nothing for marked text, so ⌘Z went past the composition to the run of
    /// typing before it, and the redraw threw the half-composed word away: "Hello world" with か
    /// being composed came back as "Hello". The word is committed, and the next ⌘Z takes it back
    /// with the typing it joined. Mutation: drop the `hasMarkedText()` branch from `undo(_:)`.
    @Test func undoWhileAWordIsComposedCommitsTheWord() {
        let r = rig("Hello")
        type(" world", in: r)
        r.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(r.view.hasMarkedText(), "fixture: no composition in progress")
        #expect(r.source.text == "Hello world", "fixture: the half-composed word reached the file")
        let item = NSMenuItem(title: "Undo", action: EditorUndoCommands.undo, keyEquivalent: "z")
        #expect(r.view.validateUserInterfaceItem(item), "Edit ▸ Undo is greyed while a word is composed")

        sendUndo(r)
        #expect(!r.view.hasMarkedText(), "⌘Z left the composition up")
        #expect(r.source.text == "Hello worldか", "⌘Z mid-composition dropped the word or undid the typing before it")
        #expect(r.box.buffer.text == r.source.text)
        sendUndo(r)
        #expect(r.source.text == "Hello", "the next ⌘Z did not take back the typing and the word")
    }

    /// **⌘Z, sent as AppKit sends it, takes back typing in Preview — never a file operation**, and
    /// Edit ▸ Undo names the typing (UND-1). The window answers `undo:` for a text view whose
    /// `allowsUndo` is off with its OWN stack, the file operations', whatever the view's
    /// `undoManager` says; the property above was right and ⌘Z still missed it.
    /// Mutation: delete `PreviewTextView.undo(_:)`.
    @Test func undoSentUpTheResponderChainTakesBackTheTyping() throws {
        let r = rig("Hello")
        final class Moves { var undone = 0 }
        let moves = Moves()
        let windowStack = try #require(r.window.undoManager)
        windowStack.registerUndo(withTarget: moves) { $0.undone += 1 }
        windowStack.setActionName("Move")
        spin()
        type("!", in: r)
        let item = NSMenuItem(title: "Undo", action: EditorUndoCommands.undo, keyEquivalent: "z")
        #expect(r.view.validateUserInterfaceItem(item))
        #expect(item.title == "Undo Typing", "Edit ▸ Undo names \(item.title)")
        sendUndo(r)
        #expect(moves.undone == 0, "⌘Z in Preview undid a FILE OPERATION")
        #expect(r.source.text == "Hello")
        #expect(r.display == "Hello")
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
        sendUndo(r)
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
        sendUndo(r)
        #expect(r.source.text == "- [ ] salt")
    }

    /// **A tick far down a note, and its ⌘Z, are one step and leave the scroll where it was** — in
    /// the editable Preview, the default and the one a tick is clicked in every day (P52). The caret
    /// goes to the box, as the translator says (`caret: box.source.location`): the click was there,
    /// and a click in text puts the caret where it lands. What must not happen is the view scrolling
    /// away from the box — which a tick whose caret lands anywhere else does, since the coordinator
    /// scrolls to the selection.
    /// Mutation: the translator's tick caret at 0 — both scroll checks fail. (`splice` replacing the
    /// whole display does NOT fail it: on this uniform note that moves no scroll, measured 2026-10-17.)
    @Test func aTickFarDownIsOneStepAndKeepsTheScroll() async throws {
        let text = (1...300).map { $0 == 200 ? "- [ ] milk" : "Line \($0) of the note." }.joined(separator: "\n\n")
        let r = rig(text)
        let clip = try #require(r.view.enclosingScrollView?.contentView)
        caret(after: "Line 3 of", in: r)
        let box = try #require((0..<(r.display as NSString).length).first {
            r.view.textStorage?.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "task"
        })
        r.view.scrollRangeToVisible(NSRange(location: box, length: 1))
        // TextKit 2 lays out lazily: settle on a scroll position before measuring from it.
        var top = clip.bounds.origin.y
        let settled = await LayoutPumpWait.pump(r.window, upTo: 5) {
            defer { top = clip.bounds.origin.y }
            return top > 1_000 && clip.bounds.origin.y == top
        }
        try #require(settled.held, "Preview never settled scrolled to the box (at \(top)), so there is nothing to keep")

        r.coordinator.perform(RenderedEdit(range: NSRange(location: box, length: 1), action: .tickTask))
        _ = await LayoutPumpWait.pump(r.window, upTo: 0.5) { false }
        #expect(r.source.text.contains("- [x] milk"), "the tick did not reach the source")
        #expect(r.undo.undoActionName == EditorWorkspaceView.taskActionName)
        #expect(abs(clip.bounds.origin.y - top) < 0.5, "the tick scrolled Preview from \(top) to \(clip.bounds.origin.y)")
        let caret = r.view.firstRect(forCharacterRange: r.view.selectedRange(), actualRange: nil)
        let onScreen = r.view.convert(r.window.convertFromScreen(caret), from: nil)
        #expect(clip.documentVisibleRect.intersects(onScreen.insetBy(dx: -1, dy: -1)),
                "the caret went to \(r.view.selectedRange()), off screen, not to the box at \(box)")

        sendUndo(r)
        _ = await LayoutPumpWait.pump(r.window, upTo: 0.5) { false }
        #expect(r.source.text == text, "⌘Z did not take the tick back")
        #expect(!r.undo.canUndo, "the tick was more than one undo step")
        #expect(abs(clip.bounds.origin.y - top) < 0.5, "⌘Z scrolled Preview from \(top) to \(clip.bounds.origin.y)")

        // The control: a scroll to the top IS seen here, so the checks above could fail.
        r.view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let moved = await LayoutPumpWait.pump(r.window, upTo: 2) { top - clip.bounds.origin.y > 1_000 }
        #expect(moved.held, "a scroll to the top never showed here, so the checks above saw nothing")
    }

    /// **A double-click on a task box is one tick, not a tick and an untick** (review V11): the
    /// second click of a double-click arrives as a mouse-down of its own, with a click count of 2,
    /// and ticked the box back — two undo steps for what reads as one press.
    ///
    /// Mutation: tick on every click count, and the box ends unticked.
    @Test func aDoubleClickOnATaskBoxTicksItOnce() throws {
        let r = rig("- [ ] salt")
        let box = try #require((0..<(r.display as NSString).length).first {
            r.view.textStorage?.attribute(.previewAttachment, at: $0, effectiveRange: nil) as? String == "task"
        })
        let onScreen = r.view.firstRect(forCharacterRange: NSRange(location: box, length: 1), actualRange: nil)
        let inWindow = r.window.convertFromScreen(onScreen)
        let point = NSPoint(x: inWindow.midX, y: inWindow.midY)
        for count in 1...2 {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                        timestamp: 0, windowNumber: r.window.windowNumber, context: nil,
                                                        eventNumber: count, clickCount: count, pressure: 1))
            r.view.mouseDown(with: event); spin()
        }
        #expect(r.source.text == "- [x] salt")
        sendUndo(r)
        #expect(r.source.text == "- [ ] salt")
        #expect(!r.undo.canUndo, "the double-click was two steps")
    }

    /// **The arrow over text Preview cannot edit** (review V14): HTML here, so it does not look
    /// typeable until a keystroke is refused. The text that can be edited is left to AppKit's own
    /// cursor. Through `mouseMoved`, the view's own door.
    ///
    /// Mutation: drop the `NSCursor.arrow.set()`, and the cursor stays the I-beam.
    @Test func theCursorIsTheArrowOverReadOnlyText() throws {
        let r = rig("Plain words here.\n\n<div>raw html</div>")
        func move(over needle: String) throws {
            let range = (r.display as NSString).range(of: needle)
            let onScreen = r.view.firstRect(forCharacterRange: NSRange(location: range.location + 1, length: 1), actualRange: nil)
            let inWindow = r.window.convertFromScreen(onScreen)
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: inWindow.midX, y: inWindow.midY),
                                                        modifierFlags: [], timestamp: 0, windowNumber: r.window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSCursor.iBeam.set()
            r.view.mouseMoved(with: event)
        }
        try move(over: "raw html")
        #expect(NSCursor.current == NSCursor.arrow, "over HTML the cursor still says it can be typed in")
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
                                               isMarkdown: true, isReadOnly: false, mode: .preview,
                                               isTooLong: PreviewEditToggle.isTooLong(length: length))
        }
        #expect(PreviewEditToggle.maximumLength == 262_144)
        #expect(edits(PreviewEditToggle.maximumLength))
        #expect(!edits(PreviewEditToggle.maximumLength + 1))
        #expect(PreviewEditToggle.isOffered(hasDocument: true, isRefused: false, isMarkdown: true, isReadOnly: false,
                                            mode: .preview), "the pill stays, dimmed")
        #expect(PreviewEditToggle.tooLongTooltip == "Too long to edit in Preview — use Source.")
    }

    /// **The dimmed pill is drawn as the window's other unavailable controls are** (review V14):
    /// the tertiary style, as the header's greyed ＋. The review read the secondary colour at half
    /// opacity as a quarter of the ink, which it is — and so is the tertiary style: measured
    /// 2026-10-09, the darkest grey was 194 before, 192 now, 200 for the ＋'s style (139 live). So
    /// the look was already the others'; it is now the others' by construction, and the glass track
    /// is no longer dimmed with it. Rendered and read back, on white.
    @Test func theDimmedPillIsAsLegibleAsTheOtherGreyedControls() {
        func darkest(_ view: some View) -> Int {
            let rig = ProbeRig(AnyView(view.frame(width: 140, height: 40).background(Color.white)
                .environment(\.colorScheme, .light).environment(\.selectionLensAppearance, .today)),
                               size: CGSize(width: 140, height: 40))
            let rep = rig.capture()
            var low = 255
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
                low = min(low, Int((c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255))
            } }
            return low
        }
        let dimmed = darkest(PreviewEditToggle(isOn: .constant(true), showsIntro: .constant(false), accent: .blue, isTooLong: true))
        let live = darkest(PreviewEditToggle(isOn: .constant(false), showsIntro: .constant(false), accent: .blue))
        let greyed = darkest(HStack(spacing: 4) {
            Image(systemName: "pencil").font(.system(size: 11, weight: .medium))
            Text("Edit").font(.system(size: 11, weight: .medium))
        }.foregroundStyle(.tertiary))
        print("[pill-ink] dimmed \(dimmed) · live \(live) · tertiary \(greyed) (darkest grey, 0 black – 255 white)")
        #expect(dimmed < 235, "the dimmed pill draws next to nothing")
        #expect(dimmed > live, "the dimmed pill is as dark as the live one")
        #expect(abs(dimmed - greyed) <= 25, "the dimmed pill is not the tertiary style the other greyed controls wear")
    }

    /// The intro shows the first time editing is turned on, and only then; on by default (v5.5).
    @Test func theIntroShowsOnceAndEditingStartsOn() {
        #expect(PreviewEditToggle.showsIntro(turningOn: true, introSeen: false))
        #expect(!PreviewEditToggle.showsIntro(turningOn: true, introSeen: true))
        #expect(!PreviewEditToggle.showsIntro(turningOn: false, introSeen: false))
        #expect(EditorTextSettings.editsInPreviewDefault == true)
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
                                                        isReadOnly: false, mode: mode, isTooLong: false), "\(mode)")
            #expect(!EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                                        isMarkdown: PairContentKind.isMarkdown(path: "/n/letter.rtf"),
                                                        isReadOnly: false, mode: mode, isTooLong: false), "\(mode)")
        }
        #expect(EditorWorkspaceView.editsInPreview(preference: true, hasDocument: true, isRefused: false,
                                                   isMarkdown: PairContentKind.isMarkdown(path: "/n/Notes.MD"),
                                                   isReadOnly: false, mode: .preview, isTooLong: false))
        #expect(!EditorWorkspaceView.editsInPreview(preference: false, hasDocument: true, isRefused: false,
                                                    isMarkdown: true, isReadOnly: false, mode: .preview, isTooLong: false))
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
        sendUndo(r)
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
        sendUndo(r)
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
        sendUndo(r)
        #expect(r.source.text == "x")
    }

    /// ⌘B with nothing selected, then typing: the bold character is a step of its own.
    @Test func aStyledCharacterIsItsOwnUndoStep() {
        let r = rig("x")
        type("a", in: r)
        r.view.performMarkup(.bold); spin()
        type("b", in: r)
        #expect(r.source.text == "xa**b**")
        sendUndo(r)
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
        // Check Spelling, as Source's (review V10); no Wrap Lines, which would do nothing here.
        let spelling = try #require(menu.items.first { $0.title == "Check Spelling While Typing" })
        #expect(spelling.target === r.coordinator)
        #expect(!menu.items.contains { $0.title == "Wrap Lines" })
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

    // MARK: The real workspace, mounted (review V16)

    /// **The workspace in a window, with the real representable** — `makeNSView` and `updateNSView`
    /// included, which the coordinator rigs above never run. The mode is swapped by swapping the root,
    /// one wrapper for every mode, so the workspace's `@State` survives it as it does in the app.
    @MainActor
    final class Mounted {
        let document: EditorDocument
        let defaults = ScratchDefaults("PreviewEditorViewTests.mounted")
        let undo = UndoManager()
        let probe: ProbeRig<AnyView>
        private(set) var mode: EditorMode

        /// `editing: nil` leaves the setting unset, so the workspace reads its default.
        init(_ text: String, mode: EditorMode, editing: Bool? = true, bar: Bool = true,
             introSeen: Bool = true, size: CGSize = CGSize(width: 900, height: 500)) throws {
            document = try TestTextFiles.document(named: "Mounted.md", text: text)
            self.mode = mode
            if let editing { defaults.set(editing, forKey: EditorTextSettings.editsInPreviewKey) }
            else { defaults.removeObject(forKey: EditorTextSettings.editsInPreviewKey) }
            defaults.set(bar, forKey: EditorTextSettings.showsFormatBarKey)
            defaults.set(introSeen, forKey: EditorTextSettings.editsInPreviewIntroSeenKey)
            defaults.set(SurfaceStyle.unified.rawValue, forKey: LiquidGlass.surfaceStyleKey)
            probe = ProbeRig(AnyView(EmptyView()), size: size)
            probe.host.rootView = root(mode)
            probe.host.layoutSubtreeIfNeeded()
        }

        /// Every 256 KB decision the workspace handed up — what the app's menus gate on.
        var holds: [PreviewLengthHold] = []

        func root(_ mode: EditorMode) -> AnyView {
            AnyView(workspace(mode)
                .defaultAppStorage(defaults)
                .frame(width: probe.size.width, height: probe.size.height, alignment: .topLeading))
        }

        /// `EditorWorkspaceView.fixture`'s arguments, with the length decision listened to.
        private func workspace(_ mode: EditorMode) -> EditorWorkspaceView {
            EditorWorkspaceView(
                document: document, autosavePolicy: EditorAutosavePolicy(), folder: "/n", entries: [],
                showsRail: false, railIsHidden: false, accent: .blue, accentFill: .blue, onAccent: .white,
                mode: .constant(mode), splitFraction: .constant(0.5), isNaming: .constant(false),
                typedName: .constant(""), railFilter: .constant(""), railFilterIsExpanded: .constant(false),
                railTab: .constant(.files), railOutlineAnchors: .constant([:]), undoManager: undo,
                prefilledName: { "Untitled.md" }, refusal: { _ in nil }, onOpen: { _ in }, onCreate: { _ in true },
                onRevealInBrowse: { _ in }, location: nil, onLocationDoor: { _ in },
                railRowActions: .inert,
                onToggleJustTheText: {}, onNewTextFile: {}, onCloseDocument: {},
                onPreviewLengthHold: { [weak self] in self?.holds.append($0) },
                folderTrail: nil, onGoToFolder: nil)
        }

        func switchTo(_ mode: EditorMode) async {
            self.mode = mode
            probe.host.rootView = root(mode)
            await settle()
        }

        /// Passes for SwiftUI's updates and the main-queue hops after them — until `condition`, or
        /// the shared floor's worth when there is none to wait for (an absence is a bounded wait).
        func settle(_ condition: () -> Bool = { false }) async {
            _ = await LayoutPumpWait.pump(probe.window, upTo: 1) { condition() }
        }

        func views<V: NSView>(_ type: V.Type) -> [V] {
            var found: [V] = []
            func walk(_ v: NSView) { if let hit = v as? V { found.append(hit) }; v.subviews.forEach(walk) }
            walk(probe.host)
            return found
        }
        var preview: PreviewTextView? { views(PreviewTextView.self).first }
        var source: NSTextView? { views(EditorTextView.self).first }
    }

    /// **A Markdown file's Preview is editable for somebody who has never touched the setting** — the
    /// default reaches the workspace through its `@AppStorage`, not only the constant (v5.5).
    ///
    /// Mutation: `editsInPreviewDefault = false`, and Preview is the read-only one.
    @Test func previewIsEditableWhenTheSettingWasNeverChosen() async throws {
        let m = try Mounted("Salt the pasta.", mode: .preview, editing: nil)
        await m.settle { m.preview != nil }
        #expect(m.defaults.object(forKey: EditorTextSettings.editsInPreviewKey) == nil, "the setting was written")
        #expect(m.preview != nil, "Preview is read-only with the setting unset")
    }

    /// **Text ▸ Continue Lists reaches an editable Preview** (LST-3) — through the view's own
    /// `@AppStorage`, as Check Spelling does, so turning it off in the menu turns it off here.
    @Test func previewFollowsContinueLists() async throws {
        let m = try Mounted("- one\n- two", mode: .preview, editing: true)
        await m.settle { m.preview != nil }
        #expect(m.preview?.coordinator?.session.continuesLists == true)
        m.defaults.set(false, forKey: EditorTextSettings.continuesListsKey)
        await m.settle { m.preview?.coordinator?.session.continuesLists == false }
        #expect(m.preview?.coordinator?.session.continuesLists == false, "Preview did not hear Continue Lists turned off")
    }

    /// **The intro shows the first time Preview becomes editable, in the default setup** (review V2):
    /// Preview with the format bar on. Turning editing on moves the pill from its own row into the
    /// bar's, and the pill used to keep the popover's state itself — so the intro was raised on the
    /// pill that went away, marked seen, and never shown. Turned on here by the setting, as Text ▸
    /// Edit in Preview turns it on (the pill writes the same binding), which never showed it either.
    ///
    /// Mutations: drop the workspace's `onChange(of: editsInPreview)`, and no popover opens and the
    /// intro is never marked seen.
    @Test func theIntroShowsWhenEditingIsTurnedOnWithTheBarShowing() async throws {
        let m = try Mounted("Salt the pasta.", mode: .preview, editing: false, introSeen: false)
        // Ordered in — the intro is a popover, which presents only from a visible window — and
        // buried, so the editor and its intro open under everything on the user's screen.
        m.probe.window.buryUnderEverything()
        m.probe.window.orderFrontRegardless()
        defer { m.probe.window.orderOut(nil) }
        #expect(BuriedWindow.isBuried(m.probe.window), "the editor is above the desktop, at level \(m.probe.window.level.rawValue)")
        await m.settle()
        #expect(m.preview == nil, "editing starts off")
        func popovers() -> [NSWindow] {
            NSApplication.shared.windows.filter { $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }
        }
        let before = popovers().count
        m.defaults.set(true, forKey: EditorTextSettings.editsInPreviewKey)
        await m.settle { m.preview != nil && popovers().count > before }
        #expect(m.preview != nil, "Preview did not become editable")
        #expect(popovers().count > before, "no intro popover opened")
        for popover in popovers() {
            #expect(BuriedWindow.isBuried(popover), "the intro opened above the desktop, at level \(popover.level.rawValue)")
        }
        #expect(m.defaults.bool(forKey: EditorTextSettings.editsInPreviewIntroSeenKey))
        popovers().forEach { $0.orderOut(nil) }
    }

    /// **A mode switch keeps the caret where it was** (review V3): Source with the caret in the
    /// middle of a long paragraph, then Preview, then Source again. The switch's own request — "open
    /// where the caret is", for the read-only preview — reached the editable one after it was built,
    /// and `navigate(toLine:)` put the caret at the START of the paragraph and reported it, so Source
    /// came back there too.
    ///
    /// **The symptom did not reproduce here** (2026-10-09): the request reached the view before it
    /// was in a window, and the caret `makeNSView` places a turn later overwrote where it put the
    /// caret. Which of the two lands last is an ordering of SwiftUI's update passes against a
    /// main-queue hop, so the request is no longer sent to the editable Preview at all — the last
    /// check pins that.
    ///
    /// Mutation: send the mode switch's request to the editable Preview again, and the last check fails.
    @Test func aModeSwitchKeepsTheCaretMidParagraph() async throws {
        let paragraph = String(repeating: "Salt the pasta water well before it boils. ", count: 12)
        let m = try Mounted("# Title\n\n" + paragraph + "\n\nThe end.", mode: .edit)
        let source = try #require(m.source)
        m.probe.window.makeFirstResponder(source)
        let mid = ("# Title\n\n" as NSString).length + 200
        source.setSelectedRange(NSRange(location: mid, length: 0))
        // Long enough for the caret's 120 ms debounce, so the switch asks for the caret's real line.
        await m.settle(); try await Task.sleep(for: .milliseconds(300)); await m.settle()

        await m.switchTo(.preview)
        let preview = try #require(m.preview, "Preview is not the editable one")
        await m.settle { preview.coordinator?.session.sourceSelection(for: preview.selectedRange())?.location == mid }
        let inPreview = preview.coordinator?.session.sourceSelection(for: preview.selectedRange())?.location
        #expect(inPreview == mid, "Preview opened with the caret at source \(inPreview ?? -1), not \(mid)")
        #expect(m.document.caretAnchors.offset(for: m.document.path) == mid)
        #expect(preview.coordinator?.lastScrollRequest == nil,
                "the mode switch's request reached the editable Preview, which places its own caret")

        await m.switchTo(.edit)
        let back = try #require(m.source)
        await m.settle { back.selectedRange().location == mid }
        #expect(back.selectedRange().location == mid, "Source came back at \(back.selectedRange().location)")
    }

    /// **The 256 KB limit is decided when Preview is opened, and held** (review V4, the lead's
    /// decision): a note that grows past it while being edited stays editable — the caret, the bar
    /// and the pill where they were — until it is next opened in Preview; then it is read-only. In
    /// Split, typing in Source past it does not rebuild Preview's half. The decision is handed up,
    /// so the menus gate on it too.
    ///
    /// Mutation: read the length live again (drop the hold), and the first check fails — Preview
    /// goes read-only mid-edit.
    @Test func theLengthLimitIsHeldWhilePreviewStaysOpen() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let start = String(repeating: line, count: PreviewEditToggle.maximumLength / 100 - 1)
        #expect(!PreviewEditToggle.isTooLong(length: (start as NSString).length))
        let m = try Mounted(start, mode: .preview)
        let preview = try #require(m.preview, "a note under the limit opens editable")
        #expect(m.holds.last?.isTooLong == false)
        // Past the limit, from outside the view (Source's half, a paste): the same storage.
        let grow = String(repeating: line, count: 30)
        m.document.buffer.source.replace(NSRange(location: 0, length: 0), with: grow, undoManager: m.undo)
        await m.settle()
        #expect(PreviewEditToggle.isTooLong(length: m.document.buffer.source.textStorage.length))
        #expect(m.preview === preview, "Preview went read-only, or was rebuilt, as the note crossed the limit")
        #expect(m.holds.last?.isTooLong == false, "the menus were told it is too long mid-edit")

        // Split, then Preview again: opened over the limit, so read-only — and the menus told.
        await m.switchTo(.split)
        #expect(m.preview == nil, "Split opened Preview over the limit editable")
        await m.switchTo(.preview)
        #expect(m.preview == nil, "Preview reopened over the limit editable")
        #expect(m.holds.last == PreviewLengthHold(key: .init(path: m.document.path, mode: .preview, editing: true),
                                                  isTooLong: true))
    }

    /// The hold is for one note, one mode and one setting: another key reads the length afresh.
    @Test func aHoldAnswersOnlyForItsOwnMoment() {
        let key = PreviewLengthHold.Key(path: "/n/a.md", mode: .preview, editing: true)
        let held = PreviewLengthHold(key: key, isTooLong: false)
        let long = PreviewEditToggle.maximumLength + 1
        #expect(!PreviewLengthHold.isTooLong(held, key: key) { long })
        for other in [PreviewLengthHold.Key(path: "/n/b.md", mode: .preview, editing: true),
                      PreviewLengthHold.Key(path: "/n/a.md", mode: .split, editing: true),
                      PreviewLengthHold.Key(path: "/n/a.md", mode: .preview, editing: false)] {
            #expect(PreviewLengthHold.isTooLong(held, key: other) { long }, "\(other)")
        }
        #expect(PreviewLengthHold.isTooLong(nil, key: key) { long })
        #expect(!PreviewLengthHold.isTooLong(nil, key: key) { 10 })
    }

    /// **Split: the format bar acts on the half the caret is in** (review V7). Foo selected in
    /// Source, then bar selected in Preview's half: Bold made `**foo**` — Source's old selection,
    /// the caret moved there. Now the bar's handle targets Preview's half while the caret was last
    /// there, and Source's again once Source reports a selection of its own. Through the mounted
    /// workspace's own handle and both real text views; the press is the bar's call.
    ///
    /// Mutations: drop the Preview report's `caretInSplitPreview = true`, and Bold wraps foo; drop
    /// Source's reset, and the last step wraps Preview's selection again.
    @Test func splitsFormatBarActsOnTheHalfWithTheCaret() async throws {
        let m = try Mounted("foo bar\n", mode: .split)
        let source = try #require(m.source)
        let preview = try #require(m.preview)
        m.probe.window.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: 0, length: 3))
        await m.settle()
        m.probe.window.makeFirstResponder(preview)
        preview.setSelectedRange(NSRange(location: 4, length: 3))
        await m.settle()
        let handle = try #require(preview.coordinator?.handle, "Preview's half never registered with the bar")
        #expect(handle.target === preview, "the bar targets Source with the caret in Preview")
        #expect(handle.applyMarkup(.bold))
        await m.settle()
        #expect(m.document.buffer.text == "foo **bar**\n")
        // Back in Source: its own selection, its own target.
        m.probe.window.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: 0, length: 3))
        await m.settle()
        #expect(handle.target === source)
        // Out of Split, no Preview half to aim at.
        await m.switchTo(.edit)
        #expect(handle.splitPreview == nil)
    }

    /// **Split: typing in Preview's half moves the caret Preview reopens at** (review V8). Preview's
    /// half reported nothing in Split, so the remembered caret stayed wherever Source last had it.
    /// Source's own selection is nudged as Preview's edit lands in the text before it, and Preview
    /// reports after that, so the caret typed at is the one kept.
    ///
    /// Mutation: hand Preview's half no selection callback in Split, and the remembered caret is
    /// Source's.
    @Test func typingInSplitsPreviewMovesTheRememberedCaret() async throws {
        let lines = (1...40).map { "Line number \($0)." }
        let m = try Mounted(lines.joined(separator: "\n\n"), mode: .split)
        let source = try #require(m.source)
        let preview = try #require(m.preview)
        let near = (m.document.text as NSString).length - 2
        m.probe.window.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: near, length: 0))
        await m.settle()
        m.probe.window.makeFirstResponder(preview)
        let at = (preview.string as NSString).range(of: "Line number 3.").location + 4
        preview.setSelectedRange(NSRange(location: at, length: 0))
        preview.insertText("!", replacementRange: preview.selectedRange())
        await m.settle()
        let typed = (m.document.text as NSString).range(of: "Line! number 3.")
        #expect(typed.location != NSNotFound)
        #expect(m.document.caretAnchors.offset(for: m.document.path) == typed.location + 5,
                "Preview would reopen at \(m.document.caretAnchors.offset(for: m.document.path) ?? -1)")
    }

    /// **Preview follows Check Spelling While Typing** (review V10): Help says the switch is the
    /// text's, and Preview never read it — underlines on in Source stayed off in Preview.
    ///
    /// Mutation: drop the setting from `update`, and the first check fails.
    @Test func previewFollowsCheckSpelling() async throws {
        let m = try Mounted("Salt teh pasta.", mode: .preview)
        m.defaults.set(true, forKey: EditorTextSettings.checksSpellingKey)
        let preview = try #require(m.preview)
        await m.settle { preview.isContinuousSpellCheckingEnabled }
        #expect(preview.isContinuousSpellCheckingEnabled)
        m.defaults.set(false, forKey: EditorTextSettings.checksSpellingKey)
        await m.settle { !preview.isContinuousSpellCheckingEnabled }
        #expect(!preview.isContinuousSpellCheckingEnabled)
    }

    /// **A follow Source has not acted on is not replayed later** (review V13): Split with editing
    /// on, Preview scrolled — Source follows; editing off, Source, back to Split (Source rebuilt,
    /// knowing no follow), editing on: the old follow, never cleared, was handed to the new Source,
    /// which jumped to a line scrolled to minutes before.
    ///
    /// Mutation: stop clearing the follow when editing goes off, and Source jumps.
    @Test func aStaleFollowIsNotReplayedToSource() async throws {
        let lines = (1...120).map { "Line number \($0) of the note." }
        let m = try Mounted(lines.joined(separator: "\n\n"), mode: .split)
        let preview = try #require(m.preview)
        let source = try #require(m.source)
        // The person scrolls Preview: the clip view moves, not a scroll this view made.
        let clip = try #require(preview.enclosingScrollView?.contentView)
        await m.settle()
        clip.scroll(to: NSPoint(x: 0, y: 2_000))
        preview.enclosingScrollView?.reflectScrolledClipView(clip)
        await m.settle { (source.enclosingScrollView?.contentView.bounds.minY ?? 0) > 100 }
        #expect((source.enclosingScrollView?.contentView.bounds.minY ?? 0) > 100, "Source never followed — this case proves nothing")

        m.defaults.set(false, forKey: EditorTextSettings.editsInPreviewKey)
        await m.settle()
        await m.switchTo(.edit)
        await m.switchTo(.split)
        let rebuilt = try #require(m.source)
        rebuilt.scroll(.zero)
        await m.settle()
        m.defaults.set(true, forKey: EditorTextSettings.editsInPreviewKey)
        await m.settle { m.preview != nil }
        await m.settle()
        let top = rebuilt.enclosingScrollView?.contentView.bounds.minY ?? -1
        #expect(top < 50, "Source jumped to \(top)pt — an old follow, replayed")
    }
}
