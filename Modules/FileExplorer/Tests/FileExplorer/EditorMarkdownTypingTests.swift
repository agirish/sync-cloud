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

    final class Box { var text = ""; var selections: [NSRange] = []; var reports: [EditorImageImport.Report] = [] }

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
        box.text = text
        let undo = UndoManager()
        let coordinator = PlainTextEditor.Coordinator(
            text: Binding(get: { box.text }, set: { box.text = $0 }), undoManager: undo,
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
        view.isEditable = editable
        view.string = text
        coordinator.pushedText = text
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
                // What Finder puts on the clipboard for a copied file: its URL, and its name.
                board.writeObjects([URL(fileURLWithPath: "/tmp/https:/x.png") as NSURL])
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
