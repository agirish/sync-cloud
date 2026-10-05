import Testing
import SwiftUI
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// TE54–TE56 through the real text view and the real coordinator: the key reaching the delegate,
/// the paste reaching the subclass, what one ⌘Z takes back — and every door that must still do
/// what it always did.
///
/// **Driven directly, not through SwiftUI**, for `PlainTextEditorBridgeTests`' reason: mounting the
/// representable in this process segfaults. `doCommand(by:)` is the path a key takes to the
/// delegate; the paste is handed a private pasteboard, so the test never touches the clipboard.
@MainActor
@Suite(.serialized) struct EditorMarkdownTypingTests {

    /// What the rig hears back. `text` is the document's own buffer, which follows the storage the
    /// view is built around (TE67.0) — so asserting it is asserting the document heard the edit.
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
        // Every substitution off, as `makeNSView` has them — or the machine's own settings decide
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

    /// One turn of the run loop — what separates two keystrokes, and closes the undo group of the
    /// first. Without it every edit in a test is one group and "one ⌘Z" proves nothing.
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

    /// **`makeNSView` builds the subclass, and it still runs on TextKit 2** — the engine
    /// `EditorTextSettings` explains the editor must not drop off.
    @Test func theFactoryBuildsTheSubclassOnTextKit2() {
        let scroll = EditorTextView.scrollableTextView()
        let view = scroll.documentView as? EditorTextView
        #expect(view != nil)
        #expect(view?.textLayoutManager != nil)
    }

    // MARK: - TE54 Return

    /// **Return and the marker it adds are ONE undo step, and never part of the typing before
    /// them** — so one ⌘Z after Return always lands back on the item's line as it was, whatever was
    /// pressed before it.
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

    /// The case the review measured: **Return as the first edit**, nothing typed before it. One ⌘Z
    /// is the whole Return, as above — not the marker with the line break left behind, nor more.
    @Test func returnWithNothingTypedBeforeItIsOneStepToo() {
        let rig = rig("- milk")
        press(returnKey, in: rig)
        #expect(rig.view.string == "- milk\n- ")
        undo(rig)
        #expect(rig.view.string == "- milk")
        #expect(!rig.undo.canUndo, "something else was recorded with it")
    }

    /// **Return on an empty item ends the list for real**: the marker comes off and the Return goes
    /// in, so the line it was on is the blank line between the list and what is typed next — a
    /// paragraph of its own, not more of the last item. One ⌘Z puts the item back.
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

    /// **Return on an empty item with more of the list below** ends the list there with a line to
    /// type on and a blank line under it, so what is typed is a paragraph and `3. Bake` stays an
    /// item. One ⌘Z puts the item back.
    /// **An empty sub-item ends its sub-list and keeps the caret in the item above** — indented to
    /// it, so what is typed is a paragraph of that item and the sub-items after stay its own.
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

    /// **Return in the middle of an item is a Return** — at the end of a line its words carry on from.
    @Test func returnMidItemIsAReturn() {
        let rig = rig("- Preheat the oven to\n  200 degrees")
        rig.view.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: returnKey))
    }

    /// **Each door that must leave Return alone**, by what reaches the buffer: a plain newline.
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

    // MARK: - TE54 Tab and ⇧Tab

    @Test func tabNestsTheItemAndOneUndoTakesItBack() {
        let rig = rig("- a\n- b")
        press(tabKey, in: rig)
        #expect(rig.view.string == "- a\n  - b")
        #expect(rig.view.selectedRange() == NSRange(location: 9, length: 0))
        // **The host hears where the caret went** — the status line's Ln/Col and the format bar's
        // lit state are derived from this, so a stale report is a stale bar.
        #expect(rig.box.selections.last == rig.view.selectedRange())
        press(backtabKey, in: rig)
        #expect(rig.view.string == "- a\n- b")
        undo(rig)
        #expect(rig.view.string == "- a\n  - b")
        undo(rig)
        #expect(rig.view.string == "- a\n- b")
    }

    /// The first item has nothing to nest under: the key is taken, and nothing changes — no tab
    /// character lands in the list.
    @Test func tabOnTheFirstItemChangesNothing() {
        let rig = rig("- a")
        #expect(rig.coordinator.textView(rig.view, doCommandBy: tabKey))
        #expect(rig.view.string == "- a")
    }

    /// **Outside a list, Tab and ⇧Tab are what they always were** — the delegate declines, and the
    /// text view's own Tab inserts a tab.
    @Test func tabOutsideAListIsATab() {
        let rig = rig("plain words")
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: tabKey))
        #expect(!rig.coordinator.textView(rig.view, doCommandBy: backtabKey))
        press(tabKey, in: rig)
        #expect(rig.view.string == "plain words\t")
    }

    /// **Each door that must leave Tab and ⇧Tab alone** — the same doors as Return's.
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

    /// **Every other paste is AppKit's** — the handler declines, and `paste(_:)` goes on to `super`.
    @Test(arguments: ["no selection", "not an address", "plain text file", "read-only", "a file"])
    func everyOtherPasteIsAppKits(_ why: String) {
        let rig = rig("See the words", markdown: why != "plain text file", editable: why != "read-only")
        if why != "no selection" { rig.view.setSelectedRange(NSRange(location: 4, length: 3)) }
        let board = pasteboard { board in
            switch why {
            case "not an address": board.setString("just words", forType: .string)
            case "a file":
                // What Finder puts on the clipboard for a copied file: its URL, and its name. Not
                // an image, which would be copied in — see `anImageFileCopiedInFinderIsCopiedIn`.
                board.writeObjects([URL(fileURLWithPath: "/tmp/https:/x.txt") as NSURL])
                board.setString("https://example.com", forType: .string)
            default: board.setString("https://example.com", forType: .string)
            }
        }
        defer { board.releaseGlobally() }
        #expect(!rig.coordinator.handlePaste(from: board, in: rig.view), "\(why): the paste was taken")
        #expect(rig.view.string == "See the words")
    }

    /// **Several selections are AppKit's paste** — it replaces the first and deletes the rest, and
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

    /// **An address put on the clipboard as a URL alone**, with no text beside it, is the same one
    /// address — and is linked.
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

    /// **A text view rebuilt by a mode switch takes the standing heading jump as already made**, as
    /// it takes the find request — or every Source ↔ Split switch put the caret back on the last
    /// heading chosen, over wherever it had gone since.
    @Test func aRebuiltTextViewDoesNotReplayTheLastHeadingJump() {
        let request = EditorScrollRequest(line: 12, token: 7)
        let editor = PlainTextEditor(source: EditorSourceStorage(text: "x"), isEditable: true, fontScale: 1, documentID: "/a.md",
                                     undoManager: UndoManager(), scrollRequest: request)
        #expect(editor.makeCoordinator().lastScrollRequest == request)
    }

    // MARK: - TE56 an image pasted or dropped

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

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

    /// A TIFF on the clipboard — what some apps copy — is written as a PNG too.
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

    /// **Image data with text beside it pastes the text**, as it always did — a file copied in
    /// Finder is its name plus its icon, and the icon is not what anybody meant.
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

    /// **An image file copied in Finder is copied in** — its name comes along as text, and the
    /// name is not what anybody meant. The file is copied, never moved.
    @Test func anImageFileCopiedInFinderIsCopiedIn() throws {
        let note = try TestTextFiles.write("x", named: "Pasta.md")
        let source = try TestTextFiles.write("", named: "IMG_4120.png")
        try pngData().write(to: URL(fileURLWithPath: source))
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

    /// **Where no image may go, an image file copied in Finder pastes its name**, as it always did
    /// — not a refusal, and nothing written.
    @Test func anImageFileCopiedIntoCodePastesItsName() throws {
        let note = try TestTextFiles.write("x", named: "Pasta.md")
        let source = try TestTextFiles.write("", named: "IMG_4125.png")
        try pngData().write(to: URL(fileURLWithPath: source))
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

    /// **A drop on a written line of raw HTML is refused** before anything is written — it would
    /// cut the tag in two.
    @Test func aDropOnAnHTMLLineIsRefused() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let source = try TestTextFiles.write("", named: "IMG_4126.png")
        try pngData().write(to: URL(fileURLWithPath: source))
        let rig = rig("<p align=\"center\">\n  hi\n</p>", importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 5, in: rig.view) == .refused)
        #expect(rig.view.string == "<p align=\"center\">\n  hi\n</p>")
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
    }

    /// **A picture copied in a browser** — image data with its address beside it as a URL, and no
    /// text — is the picture, written as a PNG. With words selected, the address links them (TE55).
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
        let source = try TestTextFiles.write("", named: "IMG_4120.png")
        try pngData().write(to: URL(fileURLWithPath: source))
        let rig = rig("one\n\ntwo", importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 3, in: rig.view) == .handled)
        #expect(rig.view.string == "one\n\n![](Images/Pasta-1.png)\n\ntwo")
        #expect(FileManager.default.fileExists(atPath: source), "the dropped file was moved")
    }

    /// **A drop lands after the block it falls in**, never inside it — here, a table row.
    @Test func aDropInATableGoesAfterTheTable() throws {
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
        let note = try TestTextFiles.write(text, named: "Pasta.md")
        let source = try TestTextFiles.write("", named: "IMG_4121.png")
        try pngData().write(to: URL(fileURLWithPath: source))
        let rig = rig(text, importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: [source], at: 22, in: rig.view) == .handled)
        #expect(rig.view.string == "| a | b |\n|---|---|\n| 1 | 2 |\n\n![](Images/Pasta-1.png)\n\nafter")
    }

    /// **A blank line inside a code block is code** — refused before anything is written, though the
    /// drop point itself is a blank line; and a blank line after raw HTML is not, and takes the image.
    @Test func aBlankLineIsLiteralOnlyWhereTheImageWouldBe() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let source = try TestTextFiles.write("", named: "IMG_4122.png")
        try pngData().write(to: URL(fileURLWithPath: source))
        let fenced = rig("```\ncode\n\nmore\n```", importer: note)
        #expect(fenced.coordinator.handleDrop(imageFiles: [source], at: 9, in: fenced.view) == .refused)
        #expect(fenced.view.string == "```\ncode\n\nmore\n```")
        #expect(!FileManager.default.fileExists(atPath: (note as NSString).deletingLastPathComponent + "/Images"))
        let html = rig("<details>\nx\n</details>\n\nmore", importer: note)
        #expect(html.coordinator.handleDrop(imageFiles: [source], at: 23, in: html.view) == .handled)
        #expect(html.view.string == "<details>\nx\n</details>\n\n![](Images/Note-1.png)\n\nmore")
    }

    /// A read-only Markdown note takes no image: the drop is AppKit's, which a read-only view refuses.
    @Test func aDropOnAReadOnlyNoteIsAppKits() throws {
        let note = try TestTextFiles.write("x", named: "Note.md")
        let rig = rig("x", editable: false, importer: note)
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

    /// **A handled drop puts the caret in the text**, as AppKit's own drop does — so the next ⌘Z
    /// is the editor's, taking the link back, and not the window's, which is the file operations'.
    @Test func aHandledDropPutsTheCaretInTheText() throws {
        let note = try TestTextFiles.write("one\n\ntwo", named: "Pasta.md")
        let source = try TestTextFiles.write("", named: "IMG_4123.png")
        try pngData().write(to: URL(fileURLWithPath: source))
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

    /// **A refused drop is rejected** — `false` back to AppKit, the text untouched, the host told.
    @Test func aRefusedDropIsRejected() throws {
        let note = try TestTextFiles.write("```\ncode", named: "Pasta.md")
        let source = try TestTextFiles.write("", named: "IMG_4124.png")
        try pngData().write(to: URL(fileURLWithPath: source))
        let rig = rig("```\ncode", importer: note)
        let board = pasteboard { $0.writeObjects([URL(fileURLWithPath: source) as NSURL]) }
        defer { board.releaseGlobally() }
        #expect(!rig.view.performDragOperation(Drag(board, at: rig.view.convert(NSPoint(x: 20, y: 20), to: nil))))
        #expect(rig.view.string == "```\ncode")
        #expect(rig.box.reports.count == 1)
    }

    /// **A drag that started in this view is text being moved**, never a file — the handler is
    /// not asked, whatever the pasteboard holds.
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

    /// **What the editor is handed, from where it is built** — `PlainTextEditor` forwards Continue
    /// Lists, the Markdown flag and the importer on every pass, and the workspace hands them in, the
    /// heading menu its jump, and a jump in Preview moves the caret.
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
        // A file just opened is parsed at once — its heading is not 150ms behind its counts.
        #expect(workspace.contains("if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }"))
    }

    @Test func aDropOnPlainTextIsAppKits() throws {
        let note = try TestTextFiles.write("x", named: "Note.txt")
        let rig = rig("x", markdown: false, importer: note)
        #expect(rig.coordinator.handleDrop(imageFiles: ["/tmp/a.png"], at: 0, in: rig.view) == .notMine)
    }

    /// **All or nothing**: a PDF among the photos makes the whole drop AppKit's — which inserts the
    /// paths, as a drop of files always has here (measured 2026-10-04).
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
