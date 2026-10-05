import AppKit
import Events

/// **The four things a key, a paste or a drop does differently in a writable Markdown file**
/// (TE54–TE56): Return carries a list on, Tab and ⇧Tab move an item, a web address pasted onto
/// words links them, and an image dropped or pasted is saved and linked.
///
/// **Each is a narrow exception to "Edit never writes what you did not type"**, so each asks every
/// question first and does what the key or the paste always did when any answer is no: not Markdown,
/// not writable, the IME composing (marked text), the caret in code or the front matter — and, for
/// Return and Tab alone, Continue Lists off. See ``MarkdownListEdits`` and ``MarkdownPasteEdits``
/// for the rest.
///
/// **Every edit is its own undo step, apart from the typing on either side of it** —
/// `breakUndoCoalescing()` before and after the `insertText(_:replacementRange:)` that typing itself
/// goes through. Without the breaks the edit joins the run of typing before it, and one ⌘Z takes
/// the words back too (measured 2026-10-04, with a run-loop turn between keys). Everything one key
/// does lands in that key's single undo step — the undo manager groups by event — which is why
/// Return and the marker it adds come back together, never one without the other.
extension PlainTextEditor.Coordinator: EditorTextViewHandling {

    /// Whether the Markdown-only edits apply in `view` at all.
    private func typesMarkdown(in view: NSTextView) -> Bool {
        editsMarkdown && view.isEditable && !view.hasMarkedText()
    }

    /// The buffer as the storage holds it — **not `view.string`, which copies the whole document**
    /// out of the text storage to answer one keystroke (see ``EditorSourceStorage/text``, the copy
    /// kept so nothing else has to).
    private func buffer(of view: NSTextView) -> NSString {
        view.textStorage?.mutableString ?? (view.string as NSString)
    }

    // MARK: Return, Tab, ⇧Tab

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard continuesLists, typesMarkdown(in: view) else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return carryOnList(in: view)
        case #selector(NSResponder.insertTab(_:)):
            return moveListItem(in: view, outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            return moveListItem(in: view, outdent: true)
        default:
            return false
        }
    }

    /// Return at the end of a list item: the line break EXACTLY as Return makes it, and the
    /// opening after it — or the empty item's opening taken off before it.
    private func carryOnList(in view: NSTextView) -> Bool {
        guard let edit = MarkdownListEdits.returnEdit(in: buffer(of: view), selection: view.selectedRange())
        else { return false }
        view.breakUndoCoalescing()
        switch edit {
        case .continueWith(let opening):
            view.insertNewline(nil)
            view.insertText(opening, replacementRange: view.selectedRange())
        case .endList(let range, let indent, let separatesNext):
            view.insertText("", replacementRange: range)
            view.insertNewline(nil)
            if !indent.isEmpty { view.insertText(indent, replacementRange: view.selectedRange()) }
            if separatesNext {
                // The second break goes in after the caret, which stays on the line to type on.
                let caret = view.selectedRange()
                view.insertNewline(nil)
                view.setSelectedRange(caret)
            }
        }
        view.breakUndoCoalescing()
        return true
    }

    /// Tab or ⇧Tab on a list item's line.
    private func moveListItem(in view: NSTextView, outdent: Bool) -> Bool {
        guard let edit = MarkdownListEdits.tabEdit(in: buffer(of: view), selection: view.selectedRange(),
                                                   outdent: outdent) else { return false }
        guard case .rewrite(let range, let text, let selection) = edit else { return true }
        replace(range, with: text, in: view)
        view.setSelectedRange(selection)
        return true
    }

    /// One edit, one undo step: see the extension's note.
    private func replace(_ range: NSRange, with text: String, in view: NSTextView) {
        view.breakUndoCoalescing()
        view.insertText(text, replacementRange: range)
        view.breakUndoCoalescing()
    }

    // MARK: Paste

    func handlePaste(from pasteboard: NSPasteboard, in view: NSTextView) -> Bool {
        // **One selection.** With several (⌘-drag), AppKit's paste replaces the first and deletes
        // the rest; neither edit here has an answer for the rest, so it is AppKit's paste.
        guard typesMarkdown(in: view), view.selectedRanges.count == 1 else { return false }
        let selection = view.selectedRange()

        // TE56: image FILES, copied in Finder or a pane — copied in as a drop copies them. Their
        // names come along as text, and the names are not what anybody meant — except where no
        // image may go (code, raw HTML, the front matter), where the names paste as they always did.
        if let importer = imageImport, let files = EditorTextView.imageFiles(on: pasteboard),
           Self.imageCanGo(count: files.count, at: selection, in: buffer(of: view)) {
            insertImages(files.map(EditorImageImport.Source.file), at: selection, in: view, importer: importer)
            return true
        }
        let string = pasteboard.string(forType: .string)

        // TE55: one web address, pasted over words. "Nothing else" on the clipboard: a file copied
        // in Finder carries its name as a string too, and is not an address. An address put there
        // as a URL alone, with no text beside it, is the same address.
        let address = string ?? Self.webURL(on: pasteboard)
        if let address, selection.length > 0, !pasteboard.canReadObject(forClasses: [NSURL.self],
                                                                        options: [.urlReadingFileURLsOnly: true]),
           let splice = MarkdownPasteEdits.linkPaste(address, over: selection, in: buffer(of: view)) {
            replace(splice.range, with: splice.text, in: view)
            view.setSelectedRange(splice.selection)
            Logger.shared.info("[edit] Pasted a web address onto \(selection.length) selected characters as a link")
            return true
        }

        // TE56: image data and no text — a screenshot, or a picture copied in a browser, which puts
        // its address beside it as a URL. Anything carrying text pastes the text, as it always did:
        // rich text copied from a document often carries a picture OF itself too.
        guard string == nil, let importer = imageImport, let png = Self.pngData(on: pasteboard) else {
            return false
        }
        insertImages([.png(png)], at: selection, in: view, importer: importer)
        return true
    }

    /// The one web URL on the clipboard when it holds a URL and no text — what a URL written as an
    /// object alone puts there. `nil` for none, several, or a file.
    static func webURL(on pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              urls.count == 1, let url = urls.first, !url.isFileURL else { return nil }
        return url.absoluteString
    }

    /// The clipboard's image as PNG: PNG as it came, anything else AppKit can read converted.
    static func pngData(on pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Drop

    func handleDrop(imageFiles: [String], at index: Int, in view: NSTextView) -> EditorDropOutcome {
        guard typesMarkdown(in: view), let importer = imageImport else { return .notMine }
        let location = min(max(index, 0), buffer(of: view).length)
        return insertImages(imageFiles.map(EditorImageImport.Source.file),
                            at: NSRange(location: location, length: 0), in: view, importer: importer)
            ? .handled : .refused
    }

    // MARK: Images

    /// **Whether `count` images may go at `range`, asked of the text as it will read with them in
    /// it** — placeholder links, the same lines. A link inside a code block, raw HTML, a link
    /// definition or the front matter is literal text, and the image would be a file nothing shows.
    /// Asked of the result and not only of the drop point, because on a blank line the blank lines
    /// added decide it: inside a fence they are code, after an HTML block they end it.
    static func imageCanGo(count: Int, at range: NSRange, in ns: NSString) -> Bool {
        guard let trial = MarkdownPasteEdits.imageBlock(Array(repeating: "x", count: max(count, 1)),
                                                        replacing: range, in: ns) else { return false }
        return !MarkdownSourceContext.isLiteral(at: trial.selection.location,
                                                in: ns.replacingCharacters(in: trial.range, with: trial.text) as NSString)
    }

    /// Saves the images and links them at `range` — or says why not, and writes nothing.
    @discardableResult
    private func insertImages(_ sources: [EditorImageImport.Source], at range: NSRange,
                              in view: NSTextView, importer: EditorImageImporter) -> Bool {
        // **Asked before anything is written** — see `imageCanGo`.
        let ns = buffer(of: view)
        guard Self.imageCanGo(count: sources.count, at: range, in: ns) else {
            importer.report(.refused("An image can't go in a code block, raw HTML, a link definition or the "
                                     + "front matter — drop or paste it somewhere else in the note."))
            return false
        }
        let report = EditorImageImport.importImages(sources, forNote: importer.notePath, linkedIn: ns as String)
        guard case .wrote(_, _, let links, _) = report, !links.isEmpty,
              let splice = MarkdownPasteEdits.imageBlock(links, replacing: range, in: ns) else {
            importer.report(report)
            return false
        }
        replace(splice.range, with: splice.text, in: view)
        view.setSelectedRange(splice.selection)
        importer.report(report)
        return true
    }
}
