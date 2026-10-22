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
/// on its first edit (``EditorLineEndings``, ``convertLineEndingsToLF(on:)``). An edit from outside the
/// view goes through ``EditorSourceStorage/replace(_:with:undoManager:actionName:)``, which does the same.
///
/// **Built by `EditorTextView.scrollableTextView()`**, the same factory as before: measured
/// 2026-10-04, it builds the subclass and the view still comes up on TextKit 2
/// (`textLayoutManager` non-nil).
final class EditorTextView: NSTextView {

    /// What decides whether a paste or a drop is Markdown's business. Weak: the coordinator owns
    /// the view's delegate relationship, not this view.
    weak var handler: EditorTextViewHandling?

    /// **The factory's text view, in an ``EditorDocumentScrollView``** — so ⌘Z from the find bar
    /// reaches the document's stack (UND-3). The text view is the factory's own, unchanged; only the
    /// scroll view around it is ours, given every setting the factory gives its own (measured: the
    /// vertical scroller and the two backgrounds are all it changes from a plain scroll view —
    /// `aDocumentScrollViewIsTheFactorysPropertyForProperty` pins the list).
    override class func scrollableTextView() -> NSScrollView {
        let factory = factoryScrollableTextView()
        let scroll = EditorDocumentScrollView(frame: factory.frame)
        // Ours, for typewriter scrolling's room below the last line — `super`'s in every bound while
        // that is off (TE62).
        let clip = EditorDocumentClipView(frame: factory.contentView.frame)
        clip.copiesOnScroll = factory.contentView.copiesOnScroll
        clip.backgroundColor = factory.contentView.backgroundColor
        scroll.contentView = clip
        scroll.autoresizingMask = factory.autoresizingMask
        scroll.borderType = factory.borderType
        scroll.hasVerticalScroller = factory.hasVerticalScroller
        scroll.hasHorizontalScroller = factory.hasHorizontalScroller
        scroll.autohidesScrollers = factory.autohidesScrollers
        scroll.drawsBackground = factory.drawsBackground
        scroll.contentView.drawsBackground = factory.contentView.drawsBackground
        let view = factory.documentView
        factory.documentView = nil
        scroll.documentView = view
        return scroll
    }

    /// AppKit's own construction, scroll view and all — what the one above is measured against.
    class func factoryScrollableTextView() -> NSScrollView { super.scrollableTextView() }

    /// **A Source view a mode switch has just built takes the keyboard** when nobody else holds it
    /// — the one it replaced had it and took it away (UND-1). See ``EditorUndoAnchor``.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorUndoAnchorView.textViewArrived(in: window)
    }

    override func paste(_ sender: Any?) {
        if handledPaste(from: .general) { return }
        super.paste(sender)
    }

    /// Whether the handler took the paste. Its own method so a test can hand it a private pasteboard.
    ///
    /// **Nothing is converted here** (fixed 2026-10-09): the handler converts once it knows it will
    /// write, as the list rules do, and a paste it leaves to AppKit is converted by the net. Converting
    /// up front got both ends wrong — a screenshot is no type a plain-text view reads, so its paste
    /// skipped the conversion and measured its caret on CRLF text; and a paste the importer then
    /// refused had already rewritten the file.
    func handledPaste(from pasteboard: NSPasteboard) -> Bool {
        handler?.handlePaste(from: pasteboard, in: self) == true
    }

    /// The modifiers of the key being handled — set across `keyDown(with:)`, empty otherwise. What
    /// tells ⇧Return from Return (LST-7): AppKit sends both as `insertNewline:`, and the command
    /// carries no event.
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        defer { keyModifiers = [] }
        super.keyDown(with: event)
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
    func pendingCarriageReturns() -> [EditorLineEndings.Change] {
        guard let storage = textStorage else { return [] }
        if let source = storage.delegate as? EditorSourceStorage { return source.carriageReturns() }
        return EditorLineEndings.carriageReturns(in: storage.mutableString)
    }

    // MARK: LF only — see `EditorLineEndings`

    private var isConvertingLineEndings = false
    /// Set while AppKit reads a paste or a drop into the text — text coming in, whose Unicode line
    /// separators come in as LF (``EditorLineEndings/normalizedIncoming(_:)``). Everything else the
    /// net sees can carry the file's own, which stay.
    private var isReadingIncomingText = false

    /// Set while a drag that started in this view is dropped back into it — the file's own text,
    /// moved, which keeps its separators (round 2, R10, 2026-10-10: it lost them, as text coming in).
    private var isDroppingOwnText = false

    /// Paste and a text drop both arrive here, under AppKit's own handling.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isReadingIncomingText = !isDroppingOwnText
        defer { isReadingIncomingText = false }
        return super.readSelection(from: pboard, type: type)
    }

    /// Turns every CRLF and lone CR in the buffer into LF — on the first edit to a file that is not
    /// LF, and in that edit's undo step: AppKit groups undo by event, so the ⌘Z that takes back the
    /// first edit also puts the carriage returns back, and the file is its original bytes again
    /// (measured 2026-10-05, `undoTakesBackTheFirstEditAndTheConversionTogether`). Does nothing to an LF buffer, a read-only view, or while an input
    /// method is composing (the marked text sits in the buffer and must not move under it).
    ///
    /// **Called before an edit is MEASURED wherever this view can see that moment, and only once
    /// the edit is certain** — a list rule, a link or an image paste, a drop, each once it knows it
    /// will write — and by ``PlainTextEditor/apply(_:to:)`` before a verb reads the buffer, because
    /// an edit measured on the CRLF text carries offsets that are wrong after it.
    /// ``shouldChangeText(inRanges:replacementStrings:)`` is the net under the rest: plain typing and
    /// Replace measure their range before any of this can run, and it maps the range across.
    ///
    /// - Returns: the carriage returns taken out — empty when nothing was converted — so a caller
    ///   holding an offset measured before can map it with ``EditorLineEndings/mapped(_:through:)-(NSRange,_)``.
    ///   The view's own selection is mapped here.
    ///
    /// The `isEditable` check is belt and braces, not the guard: a non-editable view's own
    /// `shouldChangeText` refuses too (mutation-tested 2026-10-05 — removing the check changes
    /// nothing). It stays so a read-only file is not even scanned.
    /// - Parameter trigger: what is converting it, for the log line — `Return in a list`, say.
    @discardableResult
    func convertLineEndingsToLF(on trigger: String) -> [EditorLineEndings.Change] {
        guard isEditable, !hasMarkedText(), !isConvertingLineEndings, let storage = textStorage else {
            return []
        }
        let changes = pendingCarriageReturns()
        guard !changes.isEmpty else { return [] }
        let selection = selectedRanges.map(\.rangeValue)
        isConvertingLineEndings = true
        defer { isConvertingLineEndings = false }
        breakUndoCoalescing()
        // One multi-range change rather than one replacement of the whole text: the undo restores
        // exactly the carriage returns, and the view keeps its scroll and layout.
        guard super.shouldChangeText(inRanges: changes.map { NSValue(range: $0.range) },
                                     replacementStrings: changes.map(\.replacement)) else { return [] }
        storage.beginEditing()
        for change in changes.reversed() {
            storage.replaceCharacters(in: change.range, with: change.replacement)
        }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        selectedRanges = selection.map { NSValue(range: EditorLineEndings.mapped($0, through: changes)) }
        if let source = storage.delegate as? EditorSourceStorage {
            source.noteConversion(changes, on: trigger)
        } else {
            EditorLineEndings.logConversion(changes, of: nil, on: trigger)
        }
        return changes
    }

    /// The net under every edit: a buffer that still holds a carriage return is converted first,
    /// and a line break in what is being inserted — a pasted CRLF, a Replace string, a pasted
    /// U+2028 — is written as LF. Either way the edit is made HERE, with its ranges mapped across the conversion, and
    /// `false` tells the caller its own (now stale) edit is not wanted.
    override func shouldChangeText(inRanges affectedRanges: [NSValue],
                                   replacementStrings: [String]?) -> Bool {
        guard !isConvertingLineEndings, !hasMarkedText(), let strings = replacementStrings,
              let storage = textStorage else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        let changes = pendingCarriageReturns()
        let normalized = strings.map(isReadingIncomingText ? EditorLineEndings.normalizedIncoming
                                                           : EditorLineEndings.normalized)
        guard !changes.isEmpty || normalized != strings else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        var ranges = affectedRanges.map(\.rangeValue)
        if !changes.isEmpty {
            guard !convertLineEndingsToLF(on: "typing, a paste, a drop or Replace").isEmpty else {
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
        // Where the caller's own edit would have left the caret: after what it inserted. With more
        // than one range AppKit lands it there itself (measured 2026-10-09, a paste over two).
        if ranges.count == 1 {
            setSelectedRange(NSRange(location: ranges[0].location + normalized[0].utf16.count, length: 0))
        }
        // **And in view**, which the caller's own edit would also have seen to — told no, it never
        // gets there: a long paste left the caret off the bottom of the screen (2026-10-09).
        scrollRangeToVisible(selectedRange())
        return false
    }

    /// **A word an input method commits is an edit too, and converts the file** (2026-10-09). AppKit
    /// asks ``shouldChangeText(inRanges:replacementStrings:)`` for the commit while the word is
    /// still marked, where the net must let it through as it stands — so a CRLF file whose first
    /// edit was a kana word or a dead-key accent was saved CRLF, and the conversion rode in later,
    /// inside the undo step of whatever was typed next. Converted the moment the composition is
    /// over, in the same event: one ⌘Z takes back the word and the conversion together.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let committing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if committing, !hasMarkedText() { convertLineEndingsToLF(on: "a word an input method committed") }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A drag that started in this view is text being moved, never a file.
        if let handler, (sender.draggingSource as AnyObject?) !== self,
           let files = Self.imageFiles(on: sender.draggingPasteboard) {
            // The offset is into the buffer as it stands: the handler converts it, and maps the
            // offset across, once it knows the drop writes — a refused drop changes nothing.
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
        isDroppingOwnText = (sender.draggingSource as AnyObject?) === self
        defer { isDroppingOwnText = false }
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
        if drawsPage {
            needsDisplay = true
            enclosingScrollView?.contentView.needsDisplay = true    // the page past the text's ends
        }
    }

    // MARK: The page — see `EditorTextSettings.drawsPageKey`

    /// Whether the text sits on a page of the system's text background. Set by `PlainTextEditor`
    /// on every pass; the view ignores a value it already has.
    var drawsPage = false {
        didSet {
            guard drawsPage != oldValue else { return }
            needsDisplay = true
            enclosingScrollView?.contentView.needsDisplay = true    // the page past the text's ends
            // Once per change, never per draw. No sizes: the first change arrives from
            // `updateNSView` before the view has a frame, and "0pt of a 0pt editor" would mislead.
            Logger.shared.info("[edit] Paper \(drawsPage ? "on" : "off") under the Source text")
        }
    }

    /// **The page under the text: the column and the margins the text always keeps**, so the
    /// glyphs never touch its edge. With no readable cap the inset is ``EditorReadableColumn/baseInset``
    /// and the page is the whole view; with one, it narrows by what the cap added to each side.
    static func pageRect(in bounds: NSRect, horizontalInset: CGFloat) -> NSRect {
        let side = max(0, horizontalInset - EditorReadableColumn.baseInset.width)
        return bounds.insetBy(dx: min(side, bounds.width / 2), dy: 0)
    }

    var pageRect: NSRect { Self.pageRect(in: bounds, horizontalInset: textContainerInset.width) }

    /// Drawn here rather than through `drawsBackground`, which can only fill the whole view.
    /// `textBackgroundColor` is resolved against the view's own appearance, so the page follows
    /// Light and Dark Mode and the text's default colour stays readable on it.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard drawsPage else { return }
        NSColor.textBackgroundColor.setFill()
        pageRect.intersection(rect).fill()
    }

    // MARK: Typewriter scrolling (TE62)

    /// **Whether the caret's line is held at mid-height** — Text ▸ Typewriter Scrolling, set by
    /// `PlainTextEditor` on every pass. Off, this view scrolls exactly as AppKit's own does.
    ///
    /// On, the clip view lets the text scroll on past its end (``EditorDocumentClipView``), so the
    /// last line can reach mid-height too; turned on, the caret's line is centred at once.
    var typewriterScrolling = false {
        didSet {
            guard typewriterScrolling != oldValue else { return }
            (enclosingScrollView?.contentView as? EditorDocumentClipView)?.allowsTypewriterOverscroll = typewriterScrolling
            Logger.shared.info("[edit] Typewriter scrolling \(typewriterScrolling ? "on" : "off")")
            if typewriterScrolling, window != nil, selectedRange().length == 0 {
                scrollRangeToVisible(selectedRange())
            }
        }
    }

    /// Set across a click and the drag that follows it — AppKit's tracking loop runs inside
    /// `mouseDown(with:)` until the button comes up, autoscroll included. Not
    /// `NSEvent.pressedMouseButtons`, which is the hardware's state: a button held anywhere, for
    /// anything, would have stopped the centring of a keystroke.
    private var isTrackingMouse = false

    override func mouseDown(with event: NSEvent) {
        trackingMouse { super.mouseDown(with: event) }
    }

    /// Runs `body` as the mouse's: no scroll inside it is centred. Its own method so a test can
    /// stand in for AppKit's tracking loop — a synthesized click through `super` ended the test
    /// process outright (measured 2026-10-21).
    func trackingMouse(_ body: () -> Void) {
        isTrackingMouse = true
        defer { isTrackingMouse = false }
        body()
    }

    /// **The one door every caret scroll goes through, and the only place typewriter scrolling acts.**
    ///
    /// Typing, a Return, Delete, an arrow key, Page Down, undo, a paste, Go to Line and a heading
    /// jump all end here with the caret's range. On, a bare caret's line is centred instead of
    /// merely brought into view. Everything else is AppKit's, unchanged:
    ///
    /// - **A selection** (a Find match, a ⇧-arrow, an undone deletion) — normal scrolling, so a
    ///   match is shown where AppKit shows it.
    /// - **An input method composing** — the marked text must not move under the candidate window.
    /// - **The mouse** — a click or a drag-select (decision BI): the text stays where the reader is
    ///   pointing. Trackpad and wheel scrolling never come here at all, and nor does Split's
    ///   Preview leading Source to a line — `scrollLineToTop` moves the clip, not the caret.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard typewriterScrolling, range.length == 0, !hasMarkedText(),
              !isTrackingMouse, centreLine(at: range.location) else {
            super.scrollRangeToVisible(range)
            return
        }
    }

    /// Scrolls so the line holding `offset` sits at mid-height, at once — no animation, so it keeps
    /// up with key repeat. `false` when there is nothing to measure, and AppKit scrolls instead.
    ///
    /// **Measured on TextKit 2's own fragment, laid out from the caret only** — never from the top of
    /// the document, which on a 4 MiB file would be a full layout per keystroke. That is enough for
    /// a caret far off screen too (Go to Line in a 6,000-line file lands centred, on its own line —
    /// `aFarCaretInALongFileIsCentred`). Never `layoutManager` (see ``EditorTextSettings``).
    @discardableResult
    func centreLine(at offset: Int) -> Bool {
        guard let scroll = enclosingScrollView else { return false }
        let clip = scroll.contentView
        guard let caret = caretRect(at: offset) else { return false }
        let bounds = clip.bounds
        let top = clip.contentInsets.top
        var origin = bounds.origin
        // The centre of what is on screen below any top inset.
        origin.y = caret.midY - top - (bounds.height - top) / 2
        // Unwrapped, the caret can be off to either side: bring it in, as AppKit would.
        if caret.minX < bounds.minX { origin.x = max(0, caret.minX - EditorReadableColumn.baseInset.width) }
        else if caret.maxX > bounds.maxX { origin.x = caret.maxX - bounds.width + EditorReadableColumn.baseInset.width }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin
        guard target != bounds.origin else { return true }
        clip.scroll(to: target)
        scroll.reflectScrolledClipView(clip)
        return true
    }

    /// The insertion point at `offset`, in this view's coordinates — TextKit 2's own segment, the
    /// rectangle AppKit draws the caret in. The empty line after a final line break included.
    func caretRect(at offset: Int) -> NSRect? {
        guard let manager = textLayoutManager, let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        let end = content.location(location, offsetBy: 1) ?? location
        if let range = NSTextRange(location: location, end: end) { manager.ensureLayout(for: range) }
        var found: CGRect?
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection,
                                      options: [.rangeNotRequired]) { _, frame, _, _ in
            found = frame
            return false
        }
        guard let found else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: found.minX + origin.x, y: found.minY + origin.y,
                      width: max(found.width, 1), height: found.height)
    }
}

/// **Source's clip view: AppKit's, plus typewriter scrolling's room below the last line (TE62).**
///
/// On, the text may scroll on until its end sits at mid-height, so the last line can be centred
/// like any other. **Room in the clip's bounds, not a content inset**: a bottom inset tells AppKit
/// that half the screen is covered, and its own scrolls then avoid it — measured 2026-10-21, a Find
/// match or a composing caret was pushed up to a fifth of the height. Here every point on screen
/// stays visible to AppKit, and only how far the bounds may run changes.
///
/// **Off, every bound is `super`'s.** Only Source's scroll view has one; Preview's keeps AppKit's.
final class EditorDocumentClipView: NSClipView {

    var allowsTypewriterOverscroll = false {
        didSet {
            guard allowsTypewriterOverscroll != oldValue, !allowsTypewriterOverscroll else { return }
            // Scrolled into the room as it goes: back to the end of the text.
            let settled = constrainBoundsRect(bounds).origin
            guard settled != bounds.origin else { return }
            scroll(to: settled)
            (superview as? NSScrollView)?.reflectScrolledClipView(self)
        }
    }

    /// How far past the end of the text the bounds may run in a clip this tall: half of what is on
    /// screen below any top inset — so the text's last line can sit at mid-height.
    static func overscroll(height: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, ((height - topInset) / 2).rounded())
    }

    /// AppKit's bounds, let run on past the end by ``overscroll(height:topInset:)`` while on —
    /// worked out from the proposed height, so a resize carries it with no bookkeeping.
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard allowsTypewriterOverscroll, let document = documentView,
              proposedBounds.origin.y > rect.origin.y else { return rect }
        // AppKit's own furthest, asked rather than worked out: it is not quite the text's height
        // less the clip's (measured 6pt past it), and the room is added to whatever AppKit allows.
        var furthest = proposedBounds
        furthest.origin.y = document.frame.maxY + proposedBounds.height
        let limit = super.constrainBoundsRect(furthest).origin.y
            + Self.overscroll(height: proposedBounds.height, topInset: contentInsets.top)
        rect.origin.y = max(rect.origin.y, min(proposedBounds.origin.y, limit))
        return rect
    }

    /// **The page goes on past the text's ends.** The text view draws its page only inside its own
    /// frame, and past it is the clip's: typewriter scrolling's room below the last line (measured,
    /// a white column stopped at the last line and the window showed below), and an elastic scroll
    /// past either end, which showed a strip of the window until it sprang back. Same column, same
    /// colour, so the two read as one page; the margins stay the window's.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        onDraw?(dirtyRect)
        guard let band = pageBand else { return }
        NSColor.textBackgroundColor.setFill()
        band.intersection(dirtyRect).fill()
    }

    /// Called with each rect this view draws — for the test that checks the room is redrawn.
    var onDraw: ((NSRect) -> Void)?

    /// Where the page runs in this clip's coordinates, or `nil` with Page off: the text view's
    /// ``EditorTextView/pageRect``, from the top of the bounds to the bottom whatever they are — and
    /// side to side too where it is the whole text view, so a sideways overscroll of unwrapped text
    /// stays on the page as well. Filled under the text view too, which paints the same there.
    var pageBand: NSRect? {
        guard let text = documentView as? EditorTextView, text.drawsPage else { return nil }
        let page = text.pageRect
        guard page.width < text.bounds.width else { return bounds }
        let band = convert(page, from: text)
        return NSRect(x: band.minX, y: bounds.minY, width: band.width, height: bounds.height)
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
