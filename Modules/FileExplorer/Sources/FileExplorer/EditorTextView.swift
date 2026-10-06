import AppKit

/// **The editor's text view: AppKit's own, plus the two doors no delegate method reaches** — a
/// paste (TE55, TE56) and a drop (TE56).
///
/// Return and Tab arrive through the delegate (`textView(_:doCommandBy:)`), which is why the rest of
/// `PlainTextEditor` still says "the delegate hook, not a subclass". Paste and drop do not: AppKit
/// reads the pasteboard inside `paste(_:)` and `performDragOperation(_:)` with no delegate in the
/// way. So this overrides exactly those two, asks ``handler`` first, and otherwise calls `super` —
/// every paste and drop the handler does not claim is AppKit's, unchanged.
///
/// **And where a typed line ending is decided:** Edit writes LF only, converting a CRLF or CR file
/// on its first edit (``EditorLineEndings``, ``convertLineEndingsToLF()``). An edit from outside the
/// view goes through ``EditorSourceStorage/replace(_:with:undoManager:actionName:)``, which does the same.
///
/// **Built by `EditorTextView.scrollableTextView()`**, the same factory as before: measured
/// 2026-10-04, it builds the subclass and the view still comes up on TextKit 2
/// (`textLayoutManager` non-nil).
final class EditorTextView: NSTextView {

    /// What decides whether a paste or a drop is Markdown's business. Weak: the coordinator owns
    /// the view's delegate relationship, not this view.
    weak var handler: EditorTextViewHandling?

    override func paste(_ sender: Any?) {
        if handledPaste(from: .general) { return }
        super.paste(sender)
    }

    /// Whether the handler took the paste — after the buffer is converted, because the handler
    /// measures where its link or image goes (see ``convertLineEndingsToLF()``). Its own method so a
    /// test can hand it a private pasteboard.
    func handledPaste(from pasteboard: NSPasteboard) -> Bool {
        // Converted only when something can be pasted: an empty clipboard is no edit.
        if pasteboard.availableType(from: readablePasteboardTypes) != nil { convertLineEndingsToLF() }
        return handler?.handlePaste(from: pasteboard, in: self) == true
    }

    // **No conversion on a key command as such** (fixed 2026-10-05). Every key command passes
    // through `doCommand(by:)` — arrows, Page Down, ⌘-arrows, Esc, ⇧Tab on a line that is no list
    // item — and converting there rewrote a file that was only being read: ↓ in an opened CRLF
    // note marked it changed, and autosave wrote it. A command that does write goes through
    // ``shouldChangeText(inRanges:replacementStrings:)``, which converts and maps its range; TE54's
    // list rules, which measure the buffer before they write, convert first themselves — once they
    // know they will write (`PlainTextEditor+MarkdownTyping`).

    /// The storage's carriage returns, asked of its ``EditorSourceStorage`` where it has one — which
    /// knows when there can be none, so an LF file is not scanned per keystroke.
    private func pendingCarriageReturns(in storage: NSTextStorage) -> [EditorLineEndings.Change] {
        if let source = storage.delegate as? EditorSourceStorage { return source.carriageReturns() }
        return EditorLineEndings.carriageReturns(in: storage.mutableString)
    }

    // MARK: LF only — see `EditorLineEndings`

    private var isConvertingLineEndings = false

    /// Turns every CRLF and lone CR in the buffer into LF — on the first edit to a file that is not
    /// LF, and in that edit's undo step: AppKit groups undo by event, so the ⌘Z that takes back the
    /// first edit also puts the carriage returns back, and the file is its original bytes again
    /// (measured 2026-10-05, `undoTakesBackTheFirstEditAndTheConversionTogether`). Does nothing to an LF buffer, a read-only view, or while an input
    /// method is composing (the marked text sits in the buffer and must not move under it).
    ///
    /// **Called before an edit is MEASURED wherever this view can see that moment** — a list
    /// rule once it knows it will write, a paste, a drop — and by ``PlainTextEditor/apply(_:to:)`` before a verb reads the
    /// buffer, because an edit measured on the CRLF text carries offsets that are wrong after it.
    /// ``shouldChangeText(inRanges:replacementStrings:)`` is the net under the rest: plain typing and
    /// Replace measure their range before any of this can run, and it maps the range across.
    ///
    /// The `isEditable` check is belt and braces, not the guard: a non-editable view's own
    /// `shouldChangeText` refuses too (mutation-tested 2026-10-05 — removing the check changes
    /// nothing). It stays so a read-only file is not even scanned.
    @discardableResult
    func convertLineEndingsToLF() -> Bool {
        guard isEditable, !hasMarkedText(), !isConvertingLineEndings, let storage = textStorage else {
            return false
        }
        let changes = pendingCarriageReturns(in: storage)
        guard !changes.isEmpty else { return false }
        let selection = selectedRanges.map(\.rangeValue)
        isConvertingLineEndings = true
        defer { isConvertingLineEndings = false }
        breakUndoCoalescing()
        // One multi-range change rather than one replacement of the whole text: the undo restores
        // exactly the carriage returns, and the view keeps its scroll and layout.
        guard super.shouldChangeText(inRanges: changes.map { NSValue(range: $0.range) },
                                     replacementStrings: changes.map(\.replacement)) else { return false }
        storage.beginEditing()
        for change in changes.reversed() {
            storage.replaceCharacters(in: change.range, with: change.replacement)
        }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        selectedRanges = selection.map { NSValue(range: EditorLineEndings.mapped($0, through: changes)) }
        return true
    }

    /// The net under every edit: a buffer that still holds a carriage return is converted first,
    /// and a line break in what is being inserted — a pasted CRLF, a Replace string — is written as
    /// LF. Either way the edit is made HERE, with its ranges mapped across the conversion, and
    /// `false` tells the caller its own (now stale) edit is not wanted.
    override func shouldChangeText(inRanges affectedRanges: [NSValue],
                                   replacementStrings: [String]?) -> Bool {
        guard !isConvertingLineEndings, !hasMarkedText(), let strings = replacementStrings,
              let storage = textStorage else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let changes = pendingCarriageReturns(in: storage)
        let normalized = strings.map(EditorLineEndings.normalized)
        guard !changes.isEmpty || normalized != strings else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        var ranges = affectedRanges.map(\.rangeValue)
        if !changes.isEmpty {
            guard convertLineEndingsToLF() else {
                return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
            }
            ranges = ranges.map { EditorLineEndings.mapped($0, through: changes) }
        }
        guard super.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                     replacementStrings: normalized) else { return false }
        isConvertingLineEndings = true
        defer { isConvertingLineEndings = false }
        storage.beginEditing()
        for (range, text) in zip(ranges, normalized).sorted(by: { $0.0.location > $1.0.location }) {
            // In the view's typing attributes, as AppKit's own insertion would be — a plain string
            // into an empty storage would carry no font or colour at all.
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        }
        storage.endEditing()
        didChangeText()
        // Where the caller's own edit would have left the caret: after what it inserted.
        if ranges.count == 1 {
            setSelectedRange(NSRange(location: ranges[0].location + normalized[0].utf16.count, length: 0))
        }
        return false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A drag that started in this view is text being moved, never a file.
        if let handler, (sender.draggingSource as AnyObject?) !== self,
           let files = Self.imageFiles(on: sender.draggingPasteboard) {
            // Before the drop point becomes an offset: the offset is into the converted buffer.
            convertLineEndingsToLF()
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            switch handler.handleDrop(imageFiles: files, at: index, in: self) {
            case .handled:
                // **The caret goes to the text, as AppKit's own drop puts it there** — or ⌘Z, sent
                // to whatever had focus (a pane), would undo the last FILE operation rather than
                // this link: the window's undo stack is the file operations', not the editor's.
                window?.makeFirstResponder(self)
                return true
            case .refused: return false
            case .notMine: break
            }
        }
        return super.performDragOperation(sender)
    }

    /// The dragged files when EVERY item on the pasteboard is an image file, or `nil`.
    ///
    /// **All or nothing.** A drop holding a PDF beside two photos is not an image drop, and gets
    /// what a drop of files has always got here — their paths, as text — rather than half of each.
    /// A FOLDER named like an image (`Trip.png`, a package) is not an image file either.
    static func imageFiles(on pasteboard: NSPasteboard) -> [String]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var paths: [String] = []
        for item in items {
            guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL,
                  EditorImageImport.isImageFile(url.path),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { return nil }
            paths.append(url.path)
        }
        return paths
    }
}

/// What a drop came to.
enum EditorDropOutcome: Equatable {
    /// Written and linked.
    case handled
    /// Ours, but refused — the host has said why; the drag is rejected and nothing changes.
    case refused
    /// Not ours: AppKit's drop goes ahead.
    case notMine
}

/// The coordinator's half of ``EditorTextView``.
@MainActor
protocol EditorTextViewHandling: AnyObject {
    /// Whether the paste was taken. `false` sends it to AppKit's own paste.
    func handlePaste(from pasteboard: NSPasteboard, in view: NSTextView) -> Bool
    func handleDrop(imageFiles: [String], at index: Int, in view: NSTextView) -> EditorDropOutcome
}

/// **Where a note's dropped and pasted images go, and who hears about it** — handed to the editor
/// only for a writable Markdown document. `nil` means images are not this editor's business, and a
/// drop or paste of one does what it always did.
struct EditorImageImporter {
    /// The open note. Its folder's `Images` folder is where the images go.
    var notePath: String
    /// Told about every import — what was written, so the panes can be re-read and Compare told,
    /// or why nothing was, for the banner.
    var report: (EditorImageImport.Report) -> Void

    init(notePath: String, report: @escaping (EditorImageImport.Report) -> Void) {
        self.notePath = notePath
        self.report = report
    }
}
