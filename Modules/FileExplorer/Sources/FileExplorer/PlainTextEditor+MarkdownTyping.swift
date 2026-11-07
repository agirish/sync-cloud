import AppKit
import Events
import UniformTypeIdentifiers

/// The four things a key, a paste or a drop does differently in a writable Markdown file: Return
/// carries a list on, Tab and ⇧Tab move an item, a web address pasted onto words links them, and
/// an image dropped or pasted is saved and linked.
///
/// Each is a narrow exception to "Edit never writes what you did not type", so each does what the
/// key or paste normally does unless every check passes: Markdown, writable, no IME composing
/// (marked text), the caret outside code and the front matter, and for Return and Tab, Continue
/// Lists on. See ``MarkdownListEdits`` and ``MarkdownPasteEdits`` for the rest.
///
/// Every edit is its own undo step, apart from the typing either side: `breakUndoCoalescing()`
/// before and after the `insertText(_:replacementRange:)`, or one ⌘Z takes the words back too.
/// The undo manager groups by event, so Return and the marker it adds undo together.
extension PlainTextEditor.Coordinator: EditorTextViewHandling {

    /// Whether the Markdown-only edits apply in `view` at all.
    private func typesMarkdown(in view: NSTextView) -> Bool {
        editsMarkdown && view.isEditable && !view.hasMarkedText()
    }

    /// The buffer as the storage holds it, not `view.string`, which copies the whole document to
    /// answer one keystroke (see ``EditorSourceStorage/text``, the copy kept so nothing else has to).
    private func buffer(of view: NSTextView) -> NSString {
        view.textStorage?.mutableString ?? (view.string as NSString)
    }

    // MARK: Return, Tab, ⇧Tab

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        let modifiers = (view as? EditorTextView)?.keyModifiers ?? NSApp?.currentEvent?.modifierFlags ?? []
        return command(selector, in: view, shift: modifiers.contains(.shift))
    }

    /// The key commands this editor answers in a Markdown file, with ⇧ passed in rather than read
    /// off the current event: the seam a test drives.
    ///
    /// ⇧Return and ⌃Return are a plain line break, whatever Continue Lists says. AppKit sends
    /// ⇧Return as Return, which would carry a list on, and ⌃Return as `insertLineBreak:`, which
    /// writes U+2028: a new line on screen and none to Markdown, so two items would read as one.
    func command(_ selector: Selector, in view: NSTextView, shift: Bool) -> Bool {
        if typesMarkdown(in: view) {
            if selector == #selector(NSResponder.insertLineBreak(_:)) {
                view.insertNewline(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), shift { return false }
        }
        // One selection, as for a paste: a column selection over several items gets the plain key,
        // since moving only the first range's item would drop the rest of the selection.
        guard continuesLists, typesMarkdown(in: view), view.selectedRanges.count == 1 else { return false }
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

    /// Return at the end of a list item: the line break exactly as Return makes it and the opening
    /// after it, or, on an empty item, its opening taken off.
    private func carryOnList(in view: NSTextView) -> Bool {
        guard let first = MarkdownListEdits.returnEdit(in: buffer(of: view), selection: view.selectedRange())
        else { return false }
        // This Return writes: the file to LF first (`EditorLineEndings`), then measured again, but
        // only when that changed something. In an LF file, nearly every file, a second reading would
        // cost a parse or two for the same answer.
        let converted = (view as? EditorTextView)?.convertLineEndingsToLF(on: "Return in a list") ?? []
        guard let edit = converted.isEmpty
                ? Optional(first) : MarkdownListEdits.returnEdit(in: buffer(of: view), selection: view.selectedRange())
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
        guard let first = MarkdownListEdits.tabEdit(in: buffer(of: view), selection: view.selectedRange(),
                                                    outdent: outdent) else { return false }
        // Taken but changing nothing (an item that can't move): no edit, so no conversion either.
        guard case .rewrite = first else { return true }
        // Measured again only on a buffer the conversion changed: a Tab is several parses of the
        // whole document, and in an LF file the second reading would match the first.
        let converted = (view as? EditorTextView)?.convertLineEndingsToLF(on: outdent ? "⇧Tab in a list" : "Tab in a list") ?? []
        guard case .rewrite(let range, let text, let selection)? = converted.isEmpty
                ? Optional(first)
                : MarkdownListEdits.tabEdit(in: buffer(of: view), selection: view.selectedRange(), outdent: outdent)
        else { return true }
        replace(range, with: text, in: view)
        view.setSelectedRange(selection)
        return true
    }

    /// This edit writes: the file to LF first (``EditorLineEndings``), and `range`, measured on the
    /// buffer before, mapped across so the next measurement is on the LF text. Called only once the
    /// edit is certain, so a paste or drop that ends in a refusal converts nothing.
    private func convertedForWriting(_ range: NSRange, in view: NSTextView, on trigger: String) -> NSRange {
        guard let editor = view as? EditorTextView else { return range }
        return EditorLineEndings.mapped(range, through: editor.convertLineEndingsToLF(on: trigger))
    }

    /// One edit, one undo step: see the extension's note.
    private func replace(_ range: NSRange, with text: String, in view: NSTextView) {
        view.breakUndoCoalescing()
        view.insertText(text, replacementRange: range)
        view.breakUndoCoalescing()
    }

    // MARK: Paste

    func handlePaste(from pasteboard: NSPasteboard, in view: NSTextView) -> Bool {
        // One selection. With several (⌘-drag), AppKit's paste replaces the first and deletes the
        // rest; neither edit here has an answer for the rest, so it is AppKit's paste.
        guard typesMarkdown(in: view), view.selectedRanges.count == 1 else { return false }
        let selection = view.selectedRange()

        // Image files copied in Finder or a pane are copied in as a drop copies them. Their names
        // come along as text, which nobody meant, except where no image may go (code, raw HTML,
        // the front matter): there the names paste as text.
        if let importer = imageImport, let files = EditorTextView.imageFiles(on: pasteboard),
           Self.imageCanGo(count: files.count, at: selection, in: buffer(of: view)) {
            insertImages(files.map(EditorImageImport.Source.file), at: selection, in: view, importer: importer)
            return true
        }
        let string = pasteboard.string(forType: .string)

        // One web address, pasted over words, and no file URL: a file copied in Finder carries its
        // name as a string too. An address put there as a URL alone counts, but not one beside a
        // picture: a picture copied in a browser carries its own address, and should paste as the
        // picture, not a link.
        let address = string ?? (Self.carriesImageData(pasteboard) ? nil : Self.webURL(on: pasteboard))
        if let address, selection.length > 0, !pasteboard.canReadObject(forClasses: [NSURL.self],
                                                                        options: [.urlReadingFileURLsOnly: true]),
           MarkdownPasteEdits.linkPaste(address, over: selection, in: buffer(of: view)) != nil {
            // Measured again on the converted text, whose selection it hands back.
            guard let splice = MarkdownPasteEdits.linkPaste(address, over: convertedForWriting(selection, in: view, on: "a link paste"),
                                                            in: buffer(of: view)) else { return false }
            replace(splice.range, with: splice.text, in: view)
            view.setSelectedRange(splice.selection)
            Logger.shared.info("[edit] Pasted a web address onto \(selection.length) selected characters as a link")
            return true
        }

        // Image data and no text: a screenshot, or a picture copied in a browser, which puts its
        // address beside it as a URL. Anything carrying text pastes the text: rich text copied from
        // a document often carries a picture of itself too.
        guard string == nil, let importer = imageImport, let image = Self.pastedImage(on: pasteboard) else {
            return false
        }
        insertImages([image], at: selection, in: view, importer: importer)
        return true
    }

    /// Whether the clipboard holds a picture's data (of a type an image reads), not only an address
    /// or a file's URL.
    static func carriesImageData(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }) != nil
    }

    /// The one web URL on the clipboard when it holds a URL and no text, as a URL written alone
    /// puts there. `nil` for none, several, or a file.
    static func webURL(on pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              urls.count == 1, let url = urls.first, !url.isFileURL else { return nil }
        return url.absoluteString
    }

    /// The formats a pasted picture is saved in as it came: each one Preview draws, and each
    /// already compressed. Anything else (TIFF, PDF, BMP…) is converted to PNG.
    static let keptImageFormats: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), "webp"),
    ]

    /// The clipboard's picture, saved as it came where it is one of ``keptImageFormats``, and
    /// anything else AppKit reads converted to PNG; `nil` for no picture.
    ///
    /// A JPEG photo re-encoded as PNG comes out several times the size, in a synced folder, and can
    /// cross the 25 MB Preview draws. TIFF is uncompressed and PDF is not a picture Preview draws,
    /// so those become PNG.
    static func pastedImage(on pasteboard: NSPasteboard) -> EditorImageImport.Source? {
        for format in keptImageFormats {
            if let data = pasteboard.data(forType: format.type), !data.isEmpty {
                return .data(data, extension: format.fileExtension)
            }
        }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return .png(png)
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

    /// Whether `count` images may go at `range`, asked of the text as it will read with placeholder
    /// links in it. A link inside a code block, raw HTML, a link definition or the front matter is
    /// literal text, and the image would be a file nothing shows. Asked of the result, not the drop
    /// point, because the blank lines added decide it: inside a fence they are code, after an HTML
    /// block they end it.
    static func imageCanGo(count: Int, at range: NSRange, in ns: NSString) -> Bool {
        guard let trial = MarkdownPasteEdits.imageBlock(Array(repeating: "x", count: max(count, 1)),
                                                        replacing: range, in: ns) else { return false }
        return !MarkdownSourceContext.isLiteral(at: trial.selection.location,
                                                in: ns.replacingCharacters(in: trial.range, with: trial.text) as NSString)
    }

    /// Saves the images and links them at `range`, or says why not and writes nothing.
    @discardableResult
    private func insertImages(_ sources: [EditorImageImport.Source], at range: NSRange,
                              in view: NSTextView, importer: EditorImageImporter) -> Bool {
        // Asked before anything is written: see `imageCanGo`.
        let ns = buffer(of: view)
        guard Self.imageCanGo(count: sources.count, at: range, in: ns) else {
            importer.report(.refused("An image can’t go in a code block, raw HTML, a link definition or the "
                                     + "front matter — drop or paste it somewhere else in the note."))
            return false
        }
        let report = EditorImageImport.importImages(sources, forNote: importer.notePath, linkedIn: ns as String)
        // Only once the images are written is the link certain: the file goes to LF then, and the
        // block is measured on it, since its caret is in the units of the text it is written into.
        guard case .wrote(_, _, let links, _) = report, !links.isEmpty,
              let splice = MarkdownPasteEdits.imageBlock(links, replacing: convertedForWriting(range, in: view, on: "an image paste or drop"),
                                                         in: buffer(of: view)) else {
            importer.report(report)
            return false
        }
        replace(splice.range, with: splice.text, in: view)
        view.setSelectedRange(splice.selection)
        importer.report(report)
        return true
    }
}
