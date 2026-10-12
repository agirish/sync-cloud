import AppKit
import Design
import Events

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

    // MARK: Readable line length (TE51) — see `EditorReadableColumn`

    /// The widest the text column may be, or `nil` for edge to edge — what the editor has always
    /// done, and what it does whenever Readable Line Length or Wrap Lines is off. Set by
    /// `PlainTextEditor` on every pass; the side insets follow at once.
    var readableColumnWidth: CGFloat? {
        didSet {
            guard readableColumnWidth != oldValue else { return }
            applyReadableInset(forWidth: frame.width)
            // Once per change of the column, never per resize: enough to tie a report about Source
            // to the switch, and quiet while a window is dragged.
            Logger.shared.info("[edit] Readable line length \(readableColumnWidth.map { "on — a \(Int($0.rounded()))pt column" } ?? "off") in a \(Int(frame.width.rounded()))pt editor, inset \(Int(textContainerInset.width.rounded()))pt")
        }
    }

    /// **Every width change re-centres the column — a resize, a split divider, the rail folding.**
    ///
    /// The frame, not the clip view: the text view is the clip's width by autoresizing while it
    /// wraps, and unwrapped there is no cap to apply.
    ///
    /// **The container is sized once, by hand, while the frame and the inset both move.** A
    /// container that tracks the view's width is resized the moment the inset is set — against the
    /// view's OLD width, `super` not having run — and then again by `super`: two widths for one
    /// resize, the first one wrong (`[630, 720]` going from 1000 to 1100pt, measured 2026-10-10).
    /// TextKit 2 drops the layout of the visible text on any width change, even 721 and back to
    /// 720, and lays it out again from an estimate — so in a scrolled long document the text under
    /// a still pointer moved by 10–15 lines on every frame of a resize or of Expand, and a click
    /// landed on whatever had moved there. Tracking is off for the two steps and back on before
    /// returning, because `updateNSView` reads `widthTracksTextView` to know whether lines wrap.
    override func setFrameSize(_ newSize: NSSize) {
        guard !isSettingReadableInset, readableColumnWidth != nil, newSize.width != frame.width,
              let container = textContainer, container.widthTracksTextView else {
            if !isSettingReadableInset { applyReadableInset(forWidth: newSize.width) }
            super.setFrameSize(newSize)
            return
        }
        container.widthTracksTextView = false
        defer { container.widthTracksTextView = true }
        applyReadableInset(forWidth: newSize.width)
        super.setFrameSize(newSize)
        let width = max(0, newSize.width - 2 * textContainerInset.width)
        if container.size.width != width {
            container.size = NSSize(width: width, height: container.size.height)
        }
    }

    /// **Set while this view moves its own inset, so the resize that move causes cannot undo it.**
    ///
    /// Setting `textContainerInset` makes the text view re-fit itself at its CURRENT width — and
    /// inside `setFrameSize` that is still the old one, because `super` has not run yet. Without
    /// this the nested call recomputed the inset for the old width, and the outer one's own later
    /// re-fit put it back: measured 2026-10-09 in the app, every frame of the Expand animation set
    /// the inset three times — new, old, new — each one a full re-wrap of the visible text, with
    /// the column sliding back and forth under the pointer while it happened.
    private var isSettingReadableInset = false

    /// Called with each inset this view gives itself — for the tests that count them.
    var onReadableInset: ((CGFloat) -> Void)?

    /// Sets the side inset for a view `width` wide, when it differs from the one standing.
    ///
    /// Called before `super.setFrameSize`, with the container's tracking held off around both —
    /// see ``setFrameSize(_:)`` for why the order alone was not enough.
    ///
    /// **No feedback loop, and the reason is the input, not the guard.** The inset is a function of
    /// the view's WIDTH alone, and nothing an inset does changes that width: wrapping, the view is
    /// the clip view's width by autoresizing, whatever its text. A taller text can bring a legacy
    /// vertical scroller and narrow the clip by its width — once, and then this answers for the
    /// narrower width, which is the question it was asked; the column it gives is never wider for a
    /// narrower view, so no width can make the text shorter and take the scroller away again. The
    /// equality check makes a repeat call — the height-only `setFrameSize` a re-wrap causes — do
    /// nothing at all.
    private func applyReadableInset(forWidth width: CGFloat) {
        let inset = EditorReadableColumn.horizontalInset(viewWidth: width, column: readableColumnWidth)
        guard textContainerInset.width != inset else { return }
        isSettingReadableInset = true
        defer { isSettingReadableInset = false }
        textContainerInset = NSSize(width: inset, height: textContainerInset.height)
        onReadableInset?(inset)
    }
}

/// **Source's readable line length (TE51): the text in a centred column as wide as Preview's at
/// the default Text size, made by growing the side insets as the view widens.**
///
/// Insets rather than a narrower container or a narrower view, and the difference is what a
/// reader can do in the margins: the text view still spans the editor, so a click in the margin
/// puts the caret at the near end of the line, a drag there selects, the scroll wheel scrolls and
/// the find bar's highlights land where the text is — all AppKit's own, measuring from the
/// container's origin. The header, format bar and status line are other views and keep the width.
///
/// **No `layoutManager`.** Every number here is the view's own frame and inset; the editor stays
/// on TextKit 2 (see ``EditorTextSettings``). Main-actor, as the editor's font size it reads is.
@MainActor
enum EditorReadableColumn {

    /// The widest column, at the default Text size — the read-only preview's `maxWidth: 720`, so at
    /// that size switching Source ↔ Preview does not move the measure the eye is holding. At other
    /// sizes the two part: this one scales with the font (648pt at 0.9, 878pt at 1.35) to hold the
    /// same number of characters, and Preview stays at 720.
    static let maxColumn: CGFloat = 720

    /// The text view's inset where nothing caps it, which is what the editor always had. A view
    /// narrower than the column plus these keeps exactly them.
    static let baseInset = NSSize(width: 14, height: 12)

    /// The cap for these settings, or `nil` for none.
    ///
    /// **Nothing while lines do not wrap**: there the long line running past the edge is the point
    /// of turning wrapping off, and a column would only move where it starts.
    ///
    /// **Scaled as the editor's glyphs are**, through ``FontSize/scaledBox(_:basePoint:scale:)``
    /// against the editor's own 13pt — so the column holds the same number of characters at every
    /// Text size. A flat `720 × scale` would hold fewer at Largest, where the ramp damps the font
    /// but the multiply would not damp the column.
    static func column(enabled: Bool, wraps: Bool, fontScale: CGFloat) -> CGFloat? {
        guard enabled, wraps else { return nil }
        return FontSize.scaledBox(maxColumn, basePoint: PlainTextEditor.baseFontSize, scale: fontScale)
    }

    /// The side inset that centres a `column`-wide text column in a view `viewWidth` wide — never
    /// less than ``baseInset``, so a view narrower than the column (and every view with no cap) is
    /// exactly what it was before this existed.
    ///
    /// **Not rounded to whole points**, so that past the cap the column is exactly `column` at every
    /// width: a live resize then slides the text without re-wrapping it. Rounded, the column
    /// alternated between 720 and 721 a pixel apart, and a line that fits one and not the other
    /// re-wrapped back and forth as the window was dragged. Glyphs sit at fractional positions
    /// anyway — a monospace advance is not a whole number of points.
    static func horizontalInset(viewWidth: CGFloat, column: CGFloat?) -> CGFloat {
        guard let column else { return baseInset.width }
        return max(baseInset.width, (viewWidth - column) / 2)
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
