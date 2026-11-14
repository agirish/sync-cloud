import Design
import Testing
import SwiftUI
import AppKit
import cmark_gfm
@testable import FileExplorer
import FileExplorerTestSupport

/// Markdown typing (list keys, link and image paste, image drop) through the real text view and
/// coordinator, and what one ⌘Z takes back. Driven directly, not through SwiftUI, because mounting
/// the representable in this process segfaults (see `PlainTextEditorBridgeTests`); the paste gets
/// a private pasteboard, so the test never touches the clipboard.
@MainActor
@Suite(.serialized) struct EditorMarkdownTypingTests {

    /// What the rig hears back. `text` is the document's own buffer, which follows the storage the
    /// view is built around, so asserting it asserts the document heard the edit.
    @MainActor
    final class Box {
        let buffer = EditorBuffer()
        var text: String { buffer.text }
        var selections: [NSRange] = []
        var reports: [EditorImageImport.Report] = []
    }

    struct Rig {
        let view: EditorTextView
        let coordinator: PlainTextEditor.Coordinator
        let undo: UndoManager
        let box: Box
        let window: NSWindow
    }

    /// A text view built as `makeNSView` builds one, in a window, the caret at the end.
    private func rig(_ text: String, markdown: Bool = true, editable: Bool = true,
                     importer notePath: String? = nil) -> Rig {
        let box = Box()
        box.buffer.text = text
        let source = EditorSourceStorage(text: text)
        box.buffer.follow(source)
        let undo = UndoManager()
        let coordinator = PlainTextEditor.Coordinator(
            source: source, undoManager: undo,
            documentID: "/scratch/a.md", onSelectionChange: { box.selections.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = EditorTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! EditorTextView
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        // Every substitution off, as `makeNSView` has them, or the machine's own settings decide
        // what a typed quote or dash becomes here.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isEditable = editable
        PlainTextEditor.show(source, in: view)
        coordinator.textView = view
        coordinator.editsMarkdown = markdown
        coordinator.imageImport = notePath.map { path in
            EditorImageImporter(notePath: path, report: { box.reports.append($0) })
        }
        view.handler = coordinator
        view.delegate = coordinator
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        spin()
        return Rig(view: view, coordinator: coordinator, undo: undo, box: box, window: window)
    }

    /// One turn of the run loop, which separates two keystrokes and closes the first's undo group.
    /// Without it every edit in a test is one group and "one ⌘Z" proves nothing.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    private func type(_ text: String, in rig: Rig) {
        rig.view.insertText(text, replacementRange: rig.view.selectedRange())
        spin()
    }

    private func press(_ selector: Selector, in rig: Rig) {
        rig.view.doCommand(by: selector)
        spin()
    }

    private func undo(_ rig: Rig) {
        rig.undo.undo()
        spin()
    }

    private let returnKey = #selector(NSResponder.insertNewline(_:))
    private let tabKey = #selector(NSResponder.insertTab(_:))
    private let backtabKey = #selector(NSResponder.insertBacktab(_:))

    // MARK: - The view

    // MARK: - TE54 Return

    /// Return and the marker it adds are one undo step, never part of the typing before them, so
    /// one ⌘Z after Return always lands back on the item's line as it was.
    @Test func returnCarriesTheListOnAndOneUndoTakesItBack() {
        let rig = rig("- eggs\n- milk")
        type("s", in: rig)
        press(returnKey, in: rig)
        #expect(rig.view.string == "- eggs\n- milks\n- ")
        #expect(rig.view.selectedRange() == NSRange(location: 17, length: 0))
        #expect(rig.box.text == rig.view.string, "the document did not hear about the marker")
        type("x", in: rig)

        undo(rig)
        #expect(rig.view.string == "- eggs\n- milks\n- ", "⌘Z did not take the typing back first")
        undo(rig)
        #expect(rig.view.string == "- eggs\n- milks", "⌘Z did not take back the Return and its marker together")
        undo(rig)
        #expect(rig.view.string == "- eggs\n- milk", "the typing before Return was not its own step")
    }

    /// Return as the first edit, nothing typed before it: one ⌘Z is the whole Return, not the
    /// marker with the line break left behind, nor more.
    @Test func returnWithNothingTypedBeforeItIsOneStepToo() {
        let rig = rig("- milk")
        press(returnKey, in: rig)
        #expect(rig.view.string == "- milk\n- ")
        undo(rig)
        #expect(rig.view.string == "- milk")
        #expect(!rig.undo.canUndo, "something else was recorded with it")
    }

    /// Return on an empty item ends the list for real: the marker comes off and the Return goes in,
    /// so its line is the blank line between the list and a new paragraph, not more of the last
    /// item. One ⌘Z puts the item back.
    @Test func returnOnAnEmptyItemEndsTheListAndUndoPutsTheMarkerBack() {
        let rig = rig("- eggs\n- ")
        press(returnKey, in: rig)
        #expect(rig.view.string == "- eggs\n\n")
        #expect(rig.view.selectedRange() == NSRange(location: 8, length: 0))
        type("Then preheat", in: rig)
        let blocks = MarkdownBlocks.blocks(from: rig.view.string)
        #expect(blocks.count == 2, "\(rig.view.string.debugDescription) is \(blocks.count) block(s)")
        if case .paragraph(let text)? = blocks.last?.kind {
            #expect(text.plain == "Then preheat")
        } else {
            Issue.record("what was typed after the list is not a paragraph of its own")
        }
        undo(rig)
        undo(rig)
        #expect(rig.view.string == "- eggs\n- ")
    }

    /// An empty sub-item ends its sub-list and keeps the caret in the item above, indented to it,
    /// so what is typed is a paragraph of that item and the sub-items after stay its own.
    @Test func returnOnAnEmptySubItemStaysInTheItemAbove() {
        let rig = rig("- a\n  - \n  - b")
        rig.view.setSelectedRange(NSRange(location: 8, length: 0))
        spin()
        press(returnKey, in: rig)
        #expect(rig.view.string == "- a\n\n  \n\n  - b")
        #expect(rig.view.selectedRange() == NSRange(location: 7, length: 0))
        undo(rig)
        #expect(rig.view.string == "- a\n  - \n  - b")
    }

    /// Return on an empty item with more of the list below ends the list there, with a line to type
    /// on and a blank line under it, so what is typed is a paragraph and `3. Bake` stays an item.
    /// One ⌘Z puts the item back.
    @Test func returnOnAnEmptyItemMidListLeavesALineToTypeOn() {
        let rig = rig("1. Preheat\n2. \n3. Bake")
        rig.view.setSelectedRange(NSRange(location: 14, length: 0))
        spin()
        press(returnKey, in: rig)
        #expect(rig.view.string == "1. Preheat\n\n\n\n3. Bake")
        #expect(rig.view.selectedRange() == NSRange(location: 12, length: 0))
        #expect(rig.box.text == rig.view.string)
        type("More", in: rig)
        #expect(rig.view.string == "1. Preheat\n\nMore\n\n3. Bake")
        let kinds = MarkdownBlocks.blocks(from: rig.view.string).map(\.kind)
        #expect(kinds.contains { if case .paragraph(let text) = $0 { return text.plain == "More" } else { return false } })
        #expect(kinds.contains { if case .listItem(.ordered(3), let text) = $0 { return text.plain == "Bake" } else { return false } },
                "\(kinds)")
        undo(rig)
        undo(rig)
        #expect(rig.view.string == "1. Preheat\n2. \n3. Bake")
    }

    /// Return at the end of an item with a sub-list never turns the item into a heading. An empty
    /// item can't interrupt a paragraph, so an empty `  - ` straight under the item's words would
    /// be a setext underline and make `- item` a heading. It is a plain Return.
    @Test func returnAboveASubListLeavesTheItemItsWords() {
        let rig = rig("- item\n  - sub")
        rig.view.setSelectedRange(NSRange(location: 6, length: 0))
        spin()
        press(returnKey, in: rig)
        #expect(rig.view.string == "- item\n\n  - sub")
        let kinds = MarkdownBlocks.blocks(from: rig.view.string).map(\.kind)
        #expect(!kinds.contains { if case .heading = $0 { return true } else { return false } },
                "\(rig.view.string.debugDescription) reads \(kinds)")
        #expect(kinds.contains { if case .listItem(_, let text) = $0 { return text.plain == "item" } else { return false } },
                "\(rig.view.string.debugDescription) reads \(kinds)")
    }

    /// …and above a task sub-list it still carries on as the first sub-item: an empty box is an
    /// item as written, so nothing above it changes.
    @Test func returnAboveATaskSubListCarriesItOn() {
        let rig = rig("- item\n  - [x] sub")
        rig.view.setSelectedRange(NSRange(location: 6, length: 0))
        spin()
        press(returnKey, in: rig)
        #expect(rig.view.string == "- item\n  - [ ] \n  - [x] sub")
        #expect(rig.view.selectedRange() == NSRange(location: 15, length: 0))
        #expect(rig.box.text == rig.view.string)
    }

    /// Return in the middle of an item is a Return, at the end of a line its words carry on from.
    @Test func returnMidItemIsAReturn() {
        let rig = rig("- Preheat the oven to\n  200 degrees")
        rig.view.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: returnKey))
    }

    /// Return on the blank line under a list is a Return, and what is typed there is a paragraph,
    /// not one more item of the list (which would also swallow a paragraph below it).
    @Test func returnOnTheBlankLineUnderAListIsAReturn() {
        let rig = rig("- milk\n- eggs\n\n## Next")
        rig.view.setSelectedRange(NSRange(location: 14, length: 0))
        spin()
        press(returnKey, in: rig)
        #expect(rig.view.string == "- milk\n- eggs\n\n\n## Next")
        type("Then", in: rig)
        let leaves = MarkdownSourceContext.leaves(in: rig.view.string as NSString)
        #expect(leaves.filter { $0.depth > 0 }.map(\.text) == ["", "milk", "", "eggs"],
                "\(rig.view.string.debugDescription) reads \(leaves)")
        #expect(leaves.contains { $0.text == "Then" && $0.depth == 0 }, "\(rig.view.string.debugDescription) reads \(leaves)")
    }

    /// Each door that must leave Return alone, by what reaches the buffer: a plain newline.
    @Test(arguments: ["off", "plain text", "read-only", "composing", "selection", "mid-item"])
    func returnIsAReturnWhereTheRuleDoesNotApply(_ why: String) {
        let rig = rig("- eggs", markdown: why != "plain text", editable: why != "read-only")
        switch why {
        case "off": rig.coordinator.continuesLists = false
        case "composing":
            rig.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(rig.view.hasMarkedText(), "the IME case composed nothing, so it proves nothing")
        case "selection": rig.view.setSelectedRange(NSRange(location: 2, length: 4))
        case "mid-item": rig.view.setSelectedRange(NSRange(location: 4, length: 0))
        default: break
        }
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: returnKey), "\(why): the delegate took Return")
    }

    /// Counts reads, from wherever the rule is asked.
    final class ReadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// One key reads the list once in an LF file: each read parses the whole document, and only a
    /// CRLF file, converted to LF first, needs a second read of the LF text it writes into.
    @Test(arguments: [("- a\n- b", 7, "Return", 1), ("- a\r\n- b", 8, "Return", 2),
                      ("- a\n- b", 7, "Tab", 1), ("- a\r\n- b", 8, "Tab", 2)])
    func oneKeyReadsTheListOnceInAnLFFile(_ text: String, _ caret: Int, _ key: String, _ reads: Int) {
        let rig = rig(text)
        rig.view.setSelectedRange(NSRange(location: caret, length: 0))
        spin()
        let count = ReadCount()
        MarkdownListEdits.$onRead.withValue({ count.bump() }) {
            press(key == "Tab" ? tabKey : returnKey, in: rig)
        }
        #expect(rig.view.string == (key == "Tab" ? "- a\n  - b" : "- a\n- b\n- "), "the key did not do its edit")
        #expect(count.value == reads, "\(key) in \(text.debugDescription) read the list \(count.value) times")
    }

    /// A Return key event, as the window hands one to the text view, ⇧ held or not.
    private func returnKeyEvent(shift: Bool, in rig: Rig) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                         isARepeat: false, keyCode: 36)!
    }

    /// ⌃Return writes a plain line break in a Markdown file, never U+2028: AppKit's
    /// `insertLineBreak:` writes a line separator, a new line on screen but none to Markdown, so
    /// two items would read as one. In a plain-text file the key is still AppKit's own.
    @Test func controlReturnWritesAPlainLineBreak() {
        let lineBreak = #selector(NSResponder.insertLineBreak(_:))
        let rig = rig("- eggs")
        press(lineBreak, in: rig)
        type("- milk", in: rig)
        #expect(rig.view.string == "- eggs\n- milk")
        #expect(MarkdownSourceContext.leaves(in: rig.view.string as NSString).filter { $0.kind == CMARK_NODE_ITEM.rawValue }.count == 2)
        let plain = self.rig("- eggs", markdown: false)
        #expect(!plain.coordinator.textView(plain.view, doCommandBy: lineBreak), "a .txt file's ⌃Return was taken")
    }

    /// ⇧Return is a plain Return in a list, as it is a line break in Preview. AppKit sends it as
    /// `insertNewline:`, which would carry the list on, so the ⇧ is read off the key the view is
    /// handling; hence a real key event.
    @Test func shiftReturnIsAPlainReturnInAList() {
        let rig = rig("- eggs")
        rig.view.keyDown(with: returnKeyEvent(shift: true, in: rig))
        spin()
        #expect(rig.view.string == "- eggs\n")
        #expect(!rig.coordinator.command(returnKey, in: rig.view, shift: true))
        // The positive control: the same key without ⇧ carries the list on.
        let control = self.rig("- eggs")
        control.view.keyDown(with: returnKeyEvent(shift: false, in: control))
        spin()
        #expect(control.view.string == "- eggs\n- ")
    }

    // MARK: - TE54 Tab and ⇧Tab

    @Test func tabNestsTheItemAndOneUndoTakesItBack() {
        let rig = rig("- a\n- b")
        press(tabKey, in: rig)
        #expect(rig.view.string == "- a\n  - b")
        #expect(rig.view.selectedRange() == NSRange(location: 9, length: 0))
        // The host hears where the caret went: the status line's Ln/Col and the format bar's lit
        // state derive from it, so a stale report is a stale bar.
        #expect(rig.box.selections.last == rig.view.selectedRange())
        press(backtabKey, in: rig)
        #expect(rig.view.string == "- a\n- b")
        undo(rig)
        #expect(rig.view.string == "- a\n  - b")
        undo(rig)
        #expect(rig.view.string == "- a\n- b")
    }

    /// Tab on a triple-clicked item moves it. The selection runs past the line's break, so the text
    /// view's own Tab would replace the item with a tab.
    @Test func tabOnATripleClickedItemMovesIt() {
        let rig = rig("- milk\n- eggs\n- bread")
        rig.view.setSelectedRange(NSRange(location: 7, length: 7))
        spin()
        press(tabKey, in: rig)
        #expect(rig.view.string == "- milk\n  - eggs\n- bread")
        #expect((rig.view.string as NSString).substring(with: rig.view.selectedRange()) == "- eggs\n")
        undo(rig)
        #expect(rig.view.string == "- milk\n- eggs\n- bread")
    }

    /// Several selections are the key's own: a column selection over two items is a selection over
    /// several lines, so the delegate declines rather than move only the first, as the paste does.
    @Test func tabOverSeveralSelectionsIsTheKeysOwn() {
        let rig = rig("- a\n- b\n- c")
        rig.view.selectedRanges = [NSValue(range: NSRange(location: 6, length: 1)),
                                   NSValue(range: NSRange(location: 10, length: 1))]
        spin()
        #expect(rig.view.selectedRanges.count == 2, "the second selection did not take, so this proves nothing")
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: tabKey))
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: backtabKey))
        #expect(rig.view.string == "- a\n- b\n- c")
        #expect(rig.view.selectedRanges.count == 2)
    }

    /// The first item has nothing to nest under: the key is taken and nothing changes, so no tab
    /// character lands in the list.
    @Test func tabOnTheFirstItemChangesNothing() {
        let rig = rig("- a")
        #expect(rig.coordinator.textView(rig.view, doCommandBy: tabKey))
        #expect(rig.view.string == "- a")
    }

    /// Outside a list, Tab and ⇧Tab are what they always were: the delegate declines, and the text
    /// view's own Tab inserts a tab.
    @Test func tabOutsideAListIsATab() {
        let rig = rig("plain words")
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: tabKey))
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: backtabKey))
        press(tabKey, in: rig)
        #expect(rig.view.string == "plain words\t")
    }

    /// Each door that must leave Tab and ⇧Tab alone, the same doors as Return's.
    @Test(arguments: ["off", "read-only", "composing"])
    func tabIsTheKeysOwnWhereTheRuleDoesNotApply(_ why: String) {
        let rig = rig("- a\n- b", editable: why != "read-only")
        switch why {
        case "off": rig.coordinator.continuesLists = false
        case "composing":
            rig.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(rig.view.hasMarkedText(), "the IME case composed nothing, so it proves nothing")
        default: break
        }
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: tabKey), "\(why): the delegate took Tab")
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: backtabKey), "\(why): the delegate took ⇧Tab")
    }

    @Test func tabInAListInAPlainTextFileIsATab() {
        let rig = rig("- a\n- b", markdown: false)
        press(tabKey, in: rig)
        #expect(rig.view.string == "- a\n- b\t")
    }

    // MARK: - TE55 a link pasted onto words

    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("te55-\(UUID().uuidString)"))
        board.clearContents()
        fill(board)
        return board
    }

    @Test func aWebAddressPastedOntoWordsLinksThemAndOneUndoGivesThemBack() {
        let rig = rig("See the long-ferment version for a weekend.")
        rig.view.setSelectedRange(NSRange(location: 4, length: 24))
        spin()
        let board = pasteboard { $0.setString("https://example.com/sourdough", forType: .string) }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "See [the long-ferment version](https://example.com/sourdough) for a weekend.")
        #expect(rig.box.text == rig.view.string)
        spin()
        undo(rig)
        #expect(rig.view.string == "See the long-ferment version for a weekend.")
    }

    /// Every other paste is AppKit's: the handler declines, and `paste(_:)` goes on to `super`.
    @Test(arguments: ["no selection", "not an address", "plain text file", "read-only", "a file"])
    func everyOtherPasteIsAppKits(_ why: String) {
        let rig = rig("See the words", markdown: why != "plain text file", editable: why != "read-only")
        if why != "no selection" { rig.view.setSelectedRange(NSRange(location: 4, length: 3)) }
        let board = pasteboard { board in
            switch why {
            case "not an address": board.setString("just words", forType: .string)
            case "a file":
                // What Finder puts on the clipboard for a copied file: its URL, and its name. Not
                // an image, which would be copied in (see `anImageFileCopiedInFinderIsCopiedIn`).
                board.writeObjects([URL(fileURLWithPath: "/tmp/https:/x.txt") as NSURL])
                board.setString("https://example.com", forType: .string)
            default: board.setString("https://example.com", forType: .string)
            }
        }
        defer { board.releaseGlobally() }
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view), "\(why): the paste was taken")
        #expect(rig.view.string == "See the words")
    }

    /// Several selections are AppKit's paste, which replaces the first and deletes the rest;
    /// neither edit here has an answer for the rest.
    @Test func severalSelectionsAreAppKitsPaste() {
        let rig = rig("one two three")
        rig.view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 3)),
                                   NSValue(range: NSRange(location: 8, length: 5))]
        let board = pasteboard { $0.setString("https://example.com", forType: .string) }
        defer { board.releaseGlobally() }
        #expect(rig.view.selectedRanges.count == 2, "the second selection did not take, so this proves nothing")
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view))
    }

    /// An address on the clipboard as a URL alone, with no text beside it, is the same address and
    /// is linked.
    @Test func aURLWithNoTextBesideItLinksToo() {
        let rig = rig("See the docs")
        rig.view.setSelectedRange(NSRange(location: 4, length: 8))
        let board = pasteboard { $0.writeObjects([URL(string: "https://example.com/docs")! as NSURL]) }
        defer { board.releaseGlobally() }
        #expect(board.string(forType: .string) == nil, "the URL came with text, so this proves nothing")
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "See [the docs](https://example.com/docs)")
    }

    // MARK: - TE57 the heading jump is not replayed

    /// A text view rebuilt by a mode switch takes the standing heading jump as already made, as it
    /// does the find request, or every Source ↔ Split switch would put the caret back on the last
    /// heading chosen.
    @Test func aRebuiltTextViewDoesNotReplayTheLastHeadingJump() {
        let request = EditorScrollRequest(line: 12, token: 7)
        let editor = PlainTextEditor(source: EditorSourceStorage(text: "x"), isEditable: true, fontScale: 1, documentID: "/a.md",
                                     undoManager: UndoManager(), scrollRequest: request)
        #expect(editor.makeCoordinator().lastScrollRequest == request)
    }

    // MARK: - TE56 an image pasted or dropped

    private func pngData() -> Data { EditorTestRigs.png() }

    @Test func aPastedScreenshotIsSavedLinkedAndUndoLeavesTheFile() throws {
        let note = try TestTextFiles.write("# Pasta\n\nServes 2.", named: "Pasta.md")
        let rig = rig("# Pasta\n\nServes 2.", importer: note)
        let board = pasteboard { $0.setData(pngData(), forType: .png) }
        defer { board.releaseGlobally() }

        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "# Pasta\n\nServes 2.\n\n![](Images/Pasta-1.png)")
        let file = (note as NSString).deletingLastPathComponent + "/Images/Pasta-1.png"
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(rig.box.reports.count == 1)
        guard case .wrote(let files, _, _, _)? = rig.box.reports.first else {
            Issue.record("the host was not told what was written")
            return
        }
        #expect(files == [file])

        spin()
        undo(rig)
        #expect(rig.view.string == "# Pasta\n\nServes 2.", "one ⌘Z did not take the link back")
        #expect(FileManager.default.fileExists(atPath: file), "undo deleted the image")
    }

    /// A TIFF on the clipboard, which some apps copy, is written as a PNG too.
    @Test func aTIFFOnTheClipboardIsWrittenAsPNG() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("x", importer: note)
        let tiff = NSBitmapImageRep(data: pngData())!.tiffRepresentation!
        let board = pasteboard { $0.setData(tiff, forType: .tiff) }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        let data = try Data(contentsOf: URL(fileURLWithPath: (note as NSString).deletingLastPathComponent
                                            + "/Images/Note-1.png"))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not a PNG")
    }

    /// A JPEG or HEIC picture on the clipboard is saved as it came, byte for byte, since re-encoded
    /// as PNG a photo grows several times larger in a synced folder. TIFF still becomes PNG.
    @Test func aPastedJPEGOrHEICIsSavedAsItCame() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("x", importer: note)
        let jpeg = try #require(NSBitmapImageRep(data: pngData())?.representation(using: .jpeg, properties: [:]))
        let board = pasteboard { $0.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")) }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "x\n\n![](Images/Note-1.jpg)")
        let folder = (note as NSString).deletingLastPathComponent + "/Images/"
        #expect(try Data(contentsOf: URL(fileURLWithPath: folder + "Note-1.jpg")) == jpeg, "the JPEG was re-encoded")
        // HEIC is taken as it is, never decoded, so any bytes stand in for it here.
        let heic = Data("heic bytes".utf8)
        let other = pasteboard { $0.setData(heic, forType: NSPasteboard.PasteboardType("public.heic")) }
        defer { other.releaseGlobally() }
        #expect(PlainTextEditor.Coordinator.pastedImage(on: other) == .data(heic, extension: "heic"))
    }

    /// Help says which pictures keep their format, not that every pasted image is saved as a PNG
    /// (an image file copied in Finder never is).
    @Test func theHelpSaysWhichPastedPicturesKeepTheirFormat() throws {
        let images = try EditRepoFile.helpParagraph("To put a picture in a Markdown note")
        #expect(images.contains("is copied as it is"))
        #expect(images.contains("saved as it came if it is a PNG, JPEG, HEIC, GIF or WebP, and as a PNG otherwise"))
        #expect(!images.contains("A pasted image is saved as a PNG"))
        let kept = PlainTextEditor.Coordinator.keptImageFormats.map { $0.fileExtension }
        #expect(kept == ["png", "jpg", "heic", "gif", "webp"], "the Help names five formats")
    }

    /// Image data with text beside it pastes the text: a file copied in Finder is its name plus its
    /// icon, and the icon is not what anybody meant.
    @Test func imageDataWithTextIsATextPaste() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("x", importer: note)
        let board = pasteboard {
            $0.setData(pngData(), forType: .png)
            $0.setString("Note.png", forType: .string)
        }
        defer { board.releaseGlobally() }
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
    }

    /// An image file copied in Finder is copied in, not its name, which comes along as text. The
    /// file is copied, never moved.
    @Test func anImageFileCopiedInFinderIsCopiedIn() throws {
        let note = try TestTextFiles.write("x", named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4120.png")
        let rig = rig("x", importer: note)
        let board = pasteboard {
            $0.writeObjects([URL(fileURLWithPath: source) as NSURL])
            $0.setString("IMG_4120.png", forType: .string)
        }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "x\n\n![](Images/Pasta-1.png)")
        #expect(FileManager.default.fileExists(atPath: source), "the copied file was moved")
        #expect(FileManager.default.contentsEqual(atPath: source, andPath: (note as NSString).deletingLastPathComponent
                                                  + "/Images/Pasta-1.png"))
    }

    /// Where no image may go, an image file copied in Finder pastes its name, not a refusal, and
    /// nothing is written.
    @Test func anImageFileCopiedIntoCodePastesItsName() throws {
        let note = try TestTextFiles.write("x", named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4125.png")
        let rig = rig("```\ncode", importer: note)
        let board = pasteboard {
            $0.writeObjects([URL(fileURLWithPath: source) as NSURL])
            $0.setString("IMG_4125.png", forType: .string)
        }
        defer { board.releaseGlobally() }
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.box.reports.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
    }

    /// A drop on a written line of raw HTML is refused before anything is written: it would cut the
    /// tag in two.
    @Test func aDropOnAnHTMLLineIsRefused() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4126.png")
        let rig = rig("<p align=\"center\">\n  hi\n</p>", importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 5, in: rig.view) == .refused)
        #expect(rig.view.string == "<p align=\"center\">\n  hi\n</p>")
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
    }

    /// A picture copied in a browser (image data with its address as a URL, and no text) is the
    /// picture, written as a PNG.
    @Test func aPictureCopiedInABrowserIsThePicture() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("x", importer: note)
        let board = pasteboard {
            $0.setData(pngData(), forType: .png)
            $0.writeObjects([URL(string: "https://example.com/photo.png")! as NSURL])
        }
        defer { board.releaseGlobally() }
        #expect(board.string(forType: .string) == nil, "the URL came with text, so this proves nothing")
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "x\n\n![](Images/Note-1.png)")
    }

    /// …and still the picture over selected words, not a link to its address. The words go, as any
    /// paste over a selection takes them. An address alone still links them
    /// (`aURLWithNoTextBesideItLinksToo`).
    @Test func aPictureCopiedInABrowserOverWordsIsStillThePicture() throws {
        let note = try TestTextFiles.write("See the docs", named: "Note.md")
        let rig = rig("See the docs", importer: note)
        rig.view.setSelectedRange(NSRange(location: 4, length: 8))
        let board = pasteboard {
            $0.setData(pngData(), forType: .png)
            $0.writeObjects([URL(string: "https://example.com/photo.png")! as NSURL])
        }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "See \n\n![](Images/Note-1.png)")
        #expect(FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images/Note-1.png"))
    }

    /// Help says a browser's picture is the picture, words selected or not.
    @Test func theHelpSaysABrowsersPictureIsThePicture() throws {
        let links = try EditRepoFile.helpParagraph("Select some words and paste a web address")
        #expect(links.contains("a picture copied in a browser carries its address too, and pastes as the picture"))
        let images = try EditRepoFile.helpParagraph("To put a picture in a Markdown note")
        #expect(images.contains("or a picture copied in a browser, over selected words too"))
    }

    @Test func noImporterNoImage() {
        let rig = rig("x")
        let board = pasteboard { $0.setData(pngData(), forType: .png) }
        defer { board.releaseGlobally() }
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view))
    }

    /// In a code block the paste is refused before anything is written, and the host says why.
    @Test func anImageInACodeBlockIsRefusedBeforeAnythingIsWritten() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("```\ncode", importer: note)
        let board = pasteboard { $0.setData(pngData(), forType: .png) }
        defer { board.releaseGlobally() }
        #expect(rig.coordinator.handlePaste(from: board, in: rig.view))
        #expect(rig.view.string == "```\ncode")
        guard case .refused(let reason)? = rig.box.reports.first else {
            Issue.record("no refusal reported")
            return
        }
        #expect(reason.contains("code block"))
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
    }

    @Test func aDroppedImageIsCopiedAndLinkedWhereItWasDropped() throws {
        let note = try TestTextFiles.write("one\n\ntwo", named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4120.png")
        let rig = rig("one\n\ntwo", importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 3, in: rig.view) == .handled)
        #expect(rig.view.string == "one\n\n![](Images/Pasta-1.png)\n\ntwo")
        #expect(FileManager.default.fileExists(atPath: source), "the dropped file was moved")
    }

    /// A drop lands after the block it falls in, never inside it; here, a table row.
    @Test func aDropInATableGoesAfterTheTable() throws {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
        let note = try TestTextFiles.write(text, named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4121.png")
        let rig = rig(text, importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 22, in: rig.view) == .handled)
        #expect(rig.view.string == "| a | b |\n|---|---|\n| 1 | 2 |\n\n![](Images/Pasta-1.png)\n\nafter")
    }

    /// A blank line inside a code block is code, so a drop there is refused before anything is
    /// written; a blank line after raw HTML is not, and takes the image.
    @Test func aBlankLineIsLiteralOnlyWhereTheImageWouldBe() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4122.png")
        let fenced = rig("```\ncode\n\nmore\n```", importer: note)
        #expect(fenced.coordinator.handleDrop(imageFiles: [source], at: 9, in: fenced.view) == .refused)
        #expect(fenced.view.string == "```\ncode\n\nmore\n```")
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
        let html = rig("<details>\nx\n</details>\n\nmore", importer: note)
        #expect(html.coordinator.handleDrop(imageFiles: [source], at: 23, in: html.view) == .handled)
        #expect(html.view.string == "<details>\nx\n</details>\n\n![](Images/Note-1.png)\n\nmore")
    }

    /// A read-only Markdown note, or a plain-text file, takes no image: the drop is AppKit's, which
    /// a read-only view refuses.
    @Test(arguments: [(name: "Note.md", markdown: true, editable: false), (name: "Note.txt", markdown: false, editable: true)])
    func aDropOnAReadOnlyNoteOrPlainTextIsAppKits(_ file: (name: String, markdown: Bool, editable: Bool)) throws {
        let note = try TestTextFiles.write("x", named: file.name)
        let rig = rig("x", markdown: file.markdown, editable: file.editable, importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: ["/tmp/a.png"], at: 0, in: rig.view) == .notMine)
    }

    // MARK: - The view's own doors

    /// A drag, as AppKit hands one to `performDragOperation(_:)`.
    @MainActor final class Drag: NSObject, @MainActor NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint
        let draggingSource: Any?
        @MainActor init(_ pasteboard: NSPasteboard, at location: NSPoint, from source: Any? = nil) {
            draggingPasteboard = pasteboard
            draggingLocation = location
            draggingSource = source
        }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// A handled drop puts the caret in the text, as AppKit's own drop does, so the next ⌘Z is the
    /// editor's, taking the link back, not the window's, which is the file operations'.
    @Test func aHandledDropPutsTheCaretInTheText() throws {
        let note = try TestTextFiles.write("one\n\ntwo", named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4123.png")
        let rig = rig("one\n\ntwo", importer: note)
        let elsewhere = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        rig.window.contentView?.addSubview(elsewhere)
        rig.window.makeFirstResponder(elsewhere)
        #expect(rig.window.firstResponder !== rig.view, "the text already had focus, so this proves nothing")
        let board = pasteboard { $0.writeObjects([URL(fileURLWithPath: source) as NSURL]) }
        defer { board.releaseGlobally() }
        let point = rig.view.convert(NSPoint(x: 20, y: 20), to: nil)
        #expect(rig.view.performDragOperation(Drag(board, at: point)))
        #expect(rig.view.string.contains("![](Images/Pasta-1.png)"))
        #expect(rig.window.firstResponder === rig.view, "the caret did not go to the text")
        spin()
        undo(rig)
        #expect(rig.view.string == "one\n\ntwo")
    }

    /// A refused drop is rejected: `false` back to AppKit, the text untouched, the host told.
    @Test func aRefusedDropIsRejected() throws {
        let note = try TestTextFiles.write("```\ncode", named: "Pasta.md")
        let source = try EditorTestRigs.imageFile(named: "IMG_4124.png")
        let rig = rig("```\ncode", importer: note)
        let board = pasteboard { $0.writeObjects([URL(fileURLWithPath: source) as NSURL]) }
        defer { board.releaseGlobally() }
        #expect(!rig.view.performDragOperation(Drag(board, at: rig.view.convert(NSPoint(x: 20, y: 20), to: nil))))
        #expect(rig.view.string == "```\ncode")
        #expect(rig.box.reports.count == 1)
    }

    /// A drag that started in this view is text being moved, never a file: the handler isn't asked,
    /// whatever the pasteboard holds.
    @Test func aDragFromTheViewItselfIsNotAnImageDrop() throws {
        final class Spy: EditorTextViewHandling {
            var drops = 0
            func handlePaste(from pasteboard: NSPasteboard, in view: NSTextView) -> Bool { false }
            func handleDrop(imageFiles: [String], at index: Int, in view: NSTextView) -> EditorDropOutcome {
                drops += 1
                return .refused
            }
        }
        let rig = rig("one")
        let spy = Spy()
        rig.view.handler = spy
        let board = pasteboard { $0.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL]) }
        defer { board.releaseGlobally() }
        _ = rig.view.performDragOperation(Drag(board, at: .zero, from: rig.view))
        #expect(spy.drops == 0)
        _ = rig.view.performDragOperation(Drag(board, at: .zero))
        #expect(spy.drops == 1, "the positive control: a drag from elsewhere is asked about")
    }

    /// What the editor is handed, from where it is built: `PlainTextEditor` forwards Continue
    /// Lists, the Markdown flag and the importer on every pass; the workspace hands them in and the
    /// heading menu its jump; and a jump in Preview moves the caret.
    @Test func theSettingsAreHandedInFromTheWorkspace() throws {
        let editor = try EditorFormatBarTests.source("PlainTextEditor.swift")
        for forwarded in ["context.coordinator.continuesLists = continuesLists",
                          "context.coordinator.editsMarkdown = editsMarkdown",
                          "context.coordinator.imageImport = imageImport"] {
            #expect(editor.components(separatedBy: forwarded).count - 1 == 2,
                    "\(forwarded) is not on both makeNSView and updateNSView")
        }
        #expect(editor.contains("(view as? EditorTextView)?.handler = context.coordinator"))
        let workspace = try EditorFormatBarTests.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("editsMarkdown: document.isMarkdown,"))
        #expect(workspace.contains("imageImport: imageImporter,"))
        #expect(workspace.contains("onSelect: goToHeading"))
        let jump = try EditorFormatBarTests.slice(workspace, from: "private func goToHeading(", to: "\n    }\n")
        #expect(jump.contains("if resolvedMode == .preview"))
        #expect(jump.contains("caretOffset = clamped"))
        // A mode switch sends the preview it builds to the caret, not to the last heading chosen.
        let modeSwitch = try EditorFormatBarTests.slice(workspace, from: ".onChange(of: mode) { _, _ in",
                                                        to: "\n            }\n")
        #expect(modeSwitch.contains("previewScrollRequest = EditorScrollRequest(line: caret.line, token: scrollToken)"))
        // A file just opened is parsed at once, so its heading isn't 150ms behind its counts.
        #expect(workspace.contains("if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }"))
    }

    /// All or nothing: a PDF among the photos makes the whole drop AppKit's, which inserts the
    /// paths, as a drop of files does here.
    @Test func onlyAnAllImageDropIsAnImageDrop() {
        func board(_ paths: [String]) -> NSPasteboard {
            pasteboard { $0.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }) }
        }
        let images = board(["/tmp/a.png", "/tmp/b.JPG"])
        let mixed = board(["/tmp/a.png", "/tmp/c.pdf"])
        let text = pasteboard { $0.setString("words", forType: .string) }
        defer { [images, mixed, text].forEach { $0.releaseGlobally() } }
        #expect(EditorTextView.imageFiles(on: images) == ["/tmp/a.png", "/tmp/b.JPG"])
        #expect(EditorTextView.imageFiles(on: mixed) == nil)
        #expect(EditorTextView.imageFiles(on: text) == nil)
    }
}
