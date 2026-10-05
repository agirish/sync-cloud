import Testing
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// Every way Source writes a line break, in an LF, a CRLF and a lone-CR file — and the rule they all
/// now follow: Edit writes LF only, converting a file on its first edit (``EditorLineEndings``).
///
/// **Through the real text view and coordinator**, built as `EditorMarkdownTypingTests` builds them
/// (mounting the representable in this process segfaults). Paste and drop are both
/// `readSelection(from:type:)` under AppKit's own handling, given a private pasteboard so the test
/// never touches the clipboard; Replace is the text view's own ask-replace-announce, which is what the find bar's replace does.
@MainActor
@Suite(.serialized) struct LineEndingPathsTests {

    /// The document's own buffer, following the storage the view is built around (TE67.0).
    @MainActor
    final class Box {
        let buffer = EditorBuffer()
        var text: String { buffer.text }
    }

    struct Rig {
        let view: EditorTextView
        let coordinator: PlainTextEditor.Coordinator
        let undo: UndoManager
        let box: Box
        let window: NSWindow
        let source: EditorSourceStorage
    }

    private func rig(_ text: String, caret: Int, editable: Bool = true,
                     importer notePath: String? = nil) -> Rig {
        let box = Box()
        box.buffer.text = text
        let source = EditorSourceStorage(text: text)
        box.buffer.follow(source)
        let undo = UndoManager()
        let coordinator = PlainTextEditor.Coordinator(
            source: source, undoManager: undo,
            documentID: "/scratch/a.md", onSelectionChange: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = EditorTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! EditorTextView
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isEditable = editable
        PlainTextEditor.show(source, in: view)
        coordinator.textView = view
        coordinator.editsMarkdown = true
        coordinator.imageImport = notePath.map { EditorImageImporter(notePath: $0, report: { _ in }) }
        view.handler = coordinator
        view.delegate = coordinator
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: caret, length: 0))
        spin()
        return Rig(view: view, coordinator: coordinator, undo: undo, box: box, window: window,
                   source: source)
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    /// The three files, each holding the same two lines in its own endings.
    enum Ending: String, CaseIterable, CustomStringConvertible {
        case lf = "\n", crlf = "\r\n", cr = "\r"
        var description: String { ["\n": "LF", "\r\n": "CRLF", "\r": "CR"][rawValue]! }
        var reading: EditorLineEnding { [.lf: .lf, .crlf: .crlf, .cr: .cr][self]! }
    }

    /// One path, run on a document written in `ending`. Returns the buffer afterwards.
    private typealias Path = (_ ending: Ending) -> String

    /// Two lines before every path's text, so every edit happens AFTER line breaks — where the
    /// conversion moves offsets. An edit before the first break would pass with no mapping at all.
    private func pre(_ e: Ending) -> String { "x" + e.rawValue + e.rawValue }
    private func at(_ offset: Int, _ e: Ending) -> Int { pre(e).utf16.count + offset }

    private func paragraph(_ e: Ending) -> String { pre(e) + "one" + e.rawValue + e.rawValue + "two" + e.rawValue }

    private var paths: [(String, Path)] {
        [
            ("Return", { e in
                let r = self.rig(self.paragraph(e), caret: self.at(3, e))
                r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); self.spin()
                return r.view.string
            }),
            ("Return in a list", { e in
                let text = self.pre(e) + "- one" + e.rawValue + "- two" + e.rawValue
                let r = self.rig(text, caret: self.at(5, e))
                r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); self.spin()
                return r.view.string
            }),
            ("Return on an empty item", { e in
                let text = self.pre(e) + "- one" + e.rawValue + "- " + e.rawValue + "two" + e.rawValue
                let r = self.rig(text, caret: self.at(5 + e.rawValue.utf16.count + 2, e))
                r.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); self.spin()
                return r.view.string
            }),
            ("Code Block verb", { e in
                let r = self.rig(self.paragraph(e), caret: self.at(1, e))
                PlainTextEditor.apply(.codeBlock, to: r.view); self.spin()
                return r.view.string
            }),
            ("Horizontal Rule verb", { e in
                let r = self.rig(self.paragraph(e), caret: self.at(1, e))
                PlainTextEditor.apply(.horizontalRule, to: r.view); self.spin()
                return r.view.string
            }),
            ("Insert Table verb", { e in
                let r = self.rig(self.paragraph(e), caret: self.at(3, e))
                PlainTextEditor.apply(.table(.insert), to: r.view); self.spin()
                return r.view.string
            }),
            ("Add Row Below verb", { e in
                let text = self.pre(e) + "| a | b |" + e.rawValue + "|---|---|" + e.rawValue + "| c | d |" + e.rawValue
                let r = self.rig(text, caret: self.at(2, e))
                PlainTextEditor.apply(.table(.addRowBelow), to: r.view); self.spin()
                return r.view.string
            }),
            ("Paste of two lines", { e in
                let r = self.rig(self.paragraph(e), caret: self.at(3, e))
                let board = NSPasteboard(name: NSPasteboard.Name("LineEndingPathsTests.\(UUID())"))
                board.clearContents(); board.setString("x\ny", forType: .string)
                r.view.readSelection(from: board, type: .string); self.spin()
                board.releaseGlobally()
                return r.view.string
            }),
            ("Image paste", { e in
                let note = try! TestTextFiles.write(self.paragraph(e), named: "Note.md")
                let r = self.rig(self.paragraph(e), caret: self.at(3, e), importer: note)
                let board = NSPasteboard(name: NSPasteboard.Name("LineEndingPathsTests.\(UUID())"))
                board.clearContents(); board.setData(Self.pngData(), forType: .png)
                _ = r.view.handledPaste(from: board); self.spin()
                board.releaseGlobally()
                return r.view.string
            }),
            ("Image drop", { e in
                let note = try! TestTextFiles.write(self.paragraph(e), named: "Note.md")
                let image = try! TestTextFiles.write("", named: "Photo.png")
                try! Self.pngData().write(to: URL(fileURLWithPath: image))
                let r = self.rig(self.paragraph(e), caret: 0, importer: note)
                // What `performDragOperation` does: convert, then measure the drop point.
                r.view.convertLineEndingsToLF()
                _ = r.coordinator.handleDrop(imageFiles: [image], at: self.at(3, .lf), in: r.view); self.spin()
                return r.view.string
            }),
            ("Checkbox tick", { e in
                let text = self.pre(e) + "- [ ] one" + e.rawValue + "- [ ] two" + e.rawValue
                let r = self.rig(text, caret: 0)
                EditorWorkspaceView.toggleTask(onLine: 4, in: r.source, undoManager: r.undo); self.spin()
                return r.view.string
            }),
            ("Replace with a line break", { e in
                let r = self.rig(self.paragraph(e), caret: 0)
                let target = NSRange(location: self.at(1, e), length: 1)   // the "n" of "one"
                // What the find bar's replace does to a text view: ask, replace, announce.
                if r.view.shouldChangeText(inRanges: [NSValue(range: target)], replacementStrings: ["x\ny"]) {
                    r.view.textStorage?.replaceCharacters(in: target, with: "x\ny")
                    r.view.didChangeText()
                }
                self.spin()
                return r.view.string
            }),
        ]
    }

    /// What each path wrote in an LF file on `main` before LF-only — measured 2026-10-05 and pinned,
    /// so "LF files behave as today" is a claim with bytes behind it.
    static let lfBaseline: [String: String] = [
        "Return": "x\n\none\n\n\ntwo\n",
        "Return in a list": "x\n\n- one\n- \n- two\n",
        "Return on an empty item": "x\n\n- one\n\n\n\ntwo\n",
        "Code Block verb": "x\n\n```\none\n```\n\ntwo\n",
        "Horizontal Rule verb": "x\n\none\n\n---\n\ntwo\n",
        "Insert Table verb": "x\n\none\n\n| Column 1 | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n|          |          |          |\n|          |          |          |\n\ntwo\n",
        "Add Row Below verb": "x\n\n| a   | b   |\n| --- | --- |\n|     |     |\n| c   | d   |\n",
        "Paste of two lines": "x\n\nonex\ny\n\ntwo\n",
        "Replace with a line break": "x\n\nox\nye\n\ntwo\n",
        "Image paste": "x\n\none\n\n![](Images/Note-1.png)\n\ntwo\n",
        "Image drop": "x\n\none\n\n![](Images/Note-1.png)\n\ntwo\n",
        "Checkbox tick": "x\n\n- [ ] one\n- [x] two\n",
    ]

    static func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// Every path: an LF file exactly as before, and a CRLF or CR file converted on that edit — so
    /// it comes out byte for byte what the LF file did, and the status line reads LF.
    @Test func everyPathWritesLFAndConvertsTheFileOnItsFirstEdit() {
        for (name, path) in paths {
            let lf = path(.lf)
            #expect(lf == Self.lfBaseline[name], "\(name): an LF file changed behaviour: \(String(reflecting: lf))")
            for ending in [Ending.crlf, .cr] {
                let after = path(ending)
                #expect(after == lf, "\(name) in a \(ending) file: \(String(reflecting: after))")
                #expect(EditorDocumentFacts.of(after, encoding: nil).lineEnding == .lf, "\(name), \(ending)")
            }
        }
    }

    @Test func aMixedFileIsConvertedToo() {
        let r = rig("one\r\ntwo\nthree\rfour", caret: 3)
        r.view.insertText("!", replacementRange: r.view.selectedRange()); spin()
        #expect(r.view.string == "one!\ntwo\nthree\nfour")
        #expect(r.box.text == r.view.string)   // and the document heard about it
    }

    /// A pasted CRLF goes in as LF, in an LF file too — nothing Edit writes is anything but LF.
    @Test func aPastedCRLFIsWrittenAsLF() {
        let r = rig("one\n", caret: 3)
        let board = NSPasteboard(name: NSPasteboard.Name("LineEndingPathsTests.\(UUID())"))
        board.clearContents(); board.setString("x\r\ny\rz", forType: .string)
        r.view.readSelection(from: board, type: .string); spin()
        board.releaseGlobally()
        #expect(r.view.string == "onex\ny\nz\n")
        #expect(r.view.selectedRange() == NSRange(location: 8, length: 0))
    }

    /// Opening, reading, moving the caret and selecting change nothing: a file is converted by an
    /// edit, never by being looked at — and a read-only one never.
    @Test func aFileThatIsOnlyReadKeepsItsBytes() {
        let text = "one\r\ntwo\r\n"
        let r = rig(text, caret: 0)
        r.view.setSelectedRange(NSRange(location: 2, length: 4)); spin()
        r.view.moveDown(nil); spin()
        #expect(r.view.string == text)
        let locked = rig(text, caret: 3, editable: false)
        locked.view.doCommand(by: #selector(NSResponder.insertNewline(_:))); spin()
        #expect(locked.view.string == text)
    }

    /// The conversion rides in the first edit's undo step — AppKit groups undo by event — so one ⌘Z
    /// gives back the file exactly as it was opened, and ⌘⇧Z makes both again. Later edits are
    /// ordinary steps of their own.
    @Test func undoTakesBackTheFirstEditAndTheConversionTogether() {
        let text = "one\r\n\r\ntwo\r\n"
        let r = rig(text, caret: 3)
        r.view.insertText("!", replacementRange: r.view.selectedRange()); spin()
        #expect(r.view.string == "one!\n\ntwo\n")
        r.view.breakUndoCoalescing()
        r.view.insertText("?", replacementRange: r.view.selectedRange()); spin()
        r.undo.undo(); spin()
        #expect(r.view.string == "one!\n\ntwo\n")      // the second edit alone
        r.undo.undo(); spin()
        #expect(r.view.string == text)                   // the first edit and the conversion
        r.undo.redo(); spin()
        #expect(r.view.string == "one!\n\ntwo\n")
    }

    /// While an input method is composing, the marked text sits in the buffer: nothing moves under it.
    @Test func nothingIsConvertedWhileAnInputMethodComposes() {
        let text = "one\r\ntwo"
        let r = rig(text, caret: 3)
        r.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(r.view.string.contains("\r\n"))
        r.view.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        #expect(!r.view.hasMarkedText())
    }

    /// A verb reads the buffer and hands back a selection measured on it: the conversion happens
    /// before the read, so the selection lands on the word, not a line's worth of breaks early.
    @Test func aVerbsSelectionIsRightInAConvertedFile() {
        let text = "a\r\nb\r\nc\r\nplenty here"
        let r = rig(text, caret: 0)
        let word = (text as NSString).range(of: "plenty")
        r.view.setSelectedRange(word); spin()
        PlainTextEditor.apply(.bold, to: r.view); spin()
        #expect(r.view.string == "a\nb\nc\n**plenty** here")
        #expect((r.view.string as NSString).substring(with: r.view.selectedRange()) == "plenty")
    }

    /// The paths that set a selection from offsets measured BEFORE they edit — Tab on a list item,
    /// a link pasted over words, a verb — land it in the same place in a converted CRLF file as in
    /// an LF one. Each relies on the conversion happening first; mapped afterwards, its selection
    /// would be a line's worth of breaks early.
    @Test func selectionsMeasuredBeforeTheEditLandRightInAConvertedFile() {
        typealias Run = (_ e: Ending) -> (String, NSRange)
        let runs: [(String, Run)] = [
            ("Tab", { e in
                let text = "a" + e.rawValue + "b" + e.rawValue + "- one" + e.rawValue + "- two" + e.rawValue
                    + e.rawValue + "end"
                // At the end of "- two", with a line after it: a caret set late lands in "end".
                let r = self.rig(text, caret: (text as NSString).range(of: "two").location + 3)
                r.view.doCommand(by: #selector(NSResponder.insertTab(_:))); self.spin()
                return (r.view.string, r.view.selectedRange())
            }),
            ("Link paste", { e in
                let text = "a" + e.rawValue + "b" + e.rawValue + "see plenty here" + e.rawValue + "end"
                let r = self.rig(text, caret: 0)
                r.view.setSelectedRange((text as NSString).range(of: "plenty")); self.spin()
                let board = NSPasteboard(name: NSPasteboard.Name("LineEndingPathsTests.\(UUID())"))
                board.clearContents(); board.setString("https://example.com", forType: .string)
                _ = r.view.handledPaste(from: board); self.spin()
                board.releaseGlobally()
                return (r.view.string, r.view.selectedRange())
            }),
            ("Bold", { e in
                let text = "a" + e.rawValue + "b" + e.rawValue + "see plenty here" + e.rawValue + "end"
                let r = self.rig(text, caret: 0)
                r.view.setSelectedRange((text as NSString).range(of: "plenty")); self.spin()
                PlainTextEditor.apply(.bold, to: r.view); self.spin()
                return (r.view.string, r.view.selectedRange())
            }),
        ]
        for (name, run) in runs {
            let lf = run(.lf)
            #expect(lf.0 != "a\nb\n- one\n- two\n\nend" && lf.0 != "a\nb\nsee plenty here\nend",
                    "\(name) did nothing")
            let crlf = run(.crlf)
            #expect(crlf.0 == lf.0, "\(name): \(String(reflecting: crlf.0))")
            #expect(crlf.1 == lf.1, "\(name): selection \(crlf.1) in a CRLF file, \(lf.1) in an LF one")
        }
    }

    /// A tick — the one edit made from outside the text view today, and the door TE67's Preview
    /// writes will use — converts too, in its own undo step: one ⌘Z gives back the file's bytes, and
    /// the document's buffer follows the storage back.
    @Test func aTickConvertsAndOneUndoGivesBackTheBytes() {
        let text = "- [ ] one\r\n- [ ] two\r\n"
        let r = rig(text, caret: 0)
        EditorWorkspaceView.toggleTask(onLine: 2, in: r.source, undoManager: r.undo); spin()
        #expect(r.view.string == "- [ ] one\n- [x] two\n")
        #expect(r.box.text == r.view.string)
        r.undo.undo(); spin()
        #expect(r.view.string == text)
        #expect(r.box.text == text)
        r.undo.redo(); spin()
        #expect(r.view.string == "- [ ] one\n- [x] two\n")
        #expect(r.box.text == r.view.string)
    }

    /// `replace` writes LF whatever it is handed, in an LF file too.
    @Test func replaceWritesWhatItIsHandedAsLF() {
        let r = rig("a\nb", caret: 0)
        r.source.replace(NSRange(location: 1, length: 0), with: "x\r\ny\rz", undoManager: r.undo); spin()
        #expect(r.view.string == "ax\ny\nz\nb")
    }

    /// A tick while a word is being composed: `replace` converts nothing under the marked text, the
    /// tick ends the composition and keeps the word (AppKit's doing, measured 2026-10-04), and that
    /// commit — an edit like any other — converts the file. The word lands whole, where it was typed.
    @Test func aTickWhileAWordIsComposedKeepsTheWord() {
        let text = "- [ ] one\r\nab"
        let r = rig(text, caret: (text as NSString).length)
        r.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0)); spin()
        EditorWorkspaceView.toggleTask(onLine: 1, in: r.source, undoManager: r.undo); spin()
        #expect(r.view.string == "- [x] one\nabか")
        #expect(!r.view.hasMarkedText())
        #expect(r.box.text == r.view.string)
    }

    /// The pure rules.
    @Test func carriageReturnsMapAndNormalise() {
        let text = "a\r\nb\rc\n" as NSString
        let changes = EditorLineEndings.carriageReturns(in: text)
        #expect(changes == [.init(range: NSRange(location: 1, length: 1), replacement: ""),
                            .init(range: NSRange(location: 4, length: 1), replacement: "\n")])
        #expect(EditorLineEndings.normalized("a\r\nb\rc\n") == "a\nb\nc\n")
        #expect(EditorLineEndings.mapped(5, through: changes) == 4)        // after the CRLF: one earlier
        #expect(EditorLineEndings.mapped(1, through: changes) == 1)        // at the CR itself: unmoved
        #expect(EditorLineEndings.mapped(2, through: changes) == 1)        // between CR and LF: on the LF
    }
}
