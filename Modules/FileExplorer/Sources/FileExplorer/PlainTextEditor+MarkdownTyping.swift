import AppKit
import Events

/// **The four things a key, a paste or a drop does differently in a writable Markdown file**
/// (TE54–TE56): Return carries a list on, Tab and ⇧Tab move an item, a web address pasted onto
/// words links them, and an image dropped or pasted is saved and linked.
///
/// **Each is a narrow exception to "Edit never writes what you did not type"**, so each asks every
/// question first and does what the key or the paste always did when any answer is no: not Markdown,
/// not writable, the IME composing (marked text), Continue Lists off, the caret in code or the front
/// matter — see ``MarkdownListEdits`` and ``MarkdownPasteEdits`` for the rest.
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
    /// out of the text storage to answer one keystroke (see `Coordinator.pushedText`).
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
        case .endList(let range):
            view.insertText("", replacementRange: range)
            view.insertNewline(nil)
        case .clearMarker(let range):
            view.insertText("", replacementRange: range)
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

        // TE56: image data and no text — a screenshot. Anything carrying text pastes the text, as
        // it always did: a file copied in Finder is its name plus its icon, and the icon is not
        // what anybody meant.
        guard string == nil, Self.webURL(on: pasteboard) == nil, let importer = imageImport,
              let png = Self.pngData(on: pasteboard) else {
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

    /// Saves the images and links them at `range` — or says why not, and writes nothing.
    @discardableResult
    private func insertImages(_ sources: [EditorImageImport.Source], at range: NSRange,
                              in view: NSTextView, importer: EditorImageImporter) -> Bool {
        // **Asked before anything is written**: a link inside a code block or the front matter is
        // literal text, and the image would be a file nothing shows.
        if MarkdownSourceContext.isLiteral(at: range.location, in: buffer(of: view)) {
            importer.report(.refused("An image can't go in a code block or the front matter — drop or "
                                     + "paste it somewhere else in the note."))
            return false
        }
        let report = EditorImageImport.importImages(sources, forNote: importer.notePath,
                                                    linkedIn: buffer(of: view) as String)
        guard case .wrote(_, _, let links, _) = report, !links.isEmpty,
              let splice = MarkdownPasteEdits.imageBlock(links, at: range, in: buffer(of: view)) else {
            importer.report(report)
            return false
        }
        replace(splice.range, with: splice.text, in: view)
        view.setSelectedRange(splice.selection)
        importer.report(report)
        return true
    }
}
