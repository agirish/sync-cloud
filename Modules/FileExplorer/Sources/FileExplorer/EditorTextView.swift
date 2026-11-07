import AppKit
import Design
import Events

/// The editor's text view: AppKit's own, plus the two doors no delegate method reaches, paste and
/// drop.
///
/// Return and Tab arrive through the delegate (`textView(_:doCommandBy:)`), but AppKit reads the
/// pasteboard inside `paste(_:)` and `performDragOperation(_:)` with no delegate in the way. So
/// this overrides those two, asks ``handler`` first, and otherwise calls `super`.
///
/// Also where a typed line ending is decided: Edit writes LF only, converting a CRLF or CR file on
/// its first edit (``EditorLineEndings``, ``convertLineEndingsToLF(on:)``). An edit from outside
/// the view goes through ``EditorSourceStorage/replace(_:with:undoManager:actionName:verbatim:)``,
/// which does the same. Built by `EditorTextView.scrollableTextView()`, which still comes up on
/// TextKit 2 (`textLayoutManager` non-nil).
final class EditorTextView: NSTextView {

    /// What decides whether a paste or a drop is Markdown's business. Weak: the coordinator owns
    /// the view's delegate relationship, not this view.
    weak var handler: EditorTextViewHandling?

    /// The factory's text view, in an ``EditorDocumentScrollView``, so ⌘Z from the find bar reaches
    /// the document's stack. Only the scroll view is ours, given every setting the factory gives its
    /// own (`aDocumentScrollViewIsTheFactorysPropertyForProperty` pins the list).
    override class func scrollableTextView() -> NSScrollView {
        let factory = factoryScrollableTextView()
        let scroll = EditorDocumentScrollView(frame: factory.frame)
        // Ours, for typewriter scrolling's room below the last line; `super`'s in every bound while
        // that is off.
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

    /// AppKit's own construction, scroll view and all, which the one above is checked against.
    class func factoryScrollableTextView() -> NSScrollView { super.scrollableTextView() }

    /// A Source view a mode switch has just built takes the keyboard when nobody else holds it,
    /// since the one it replaced took the keyboard away with it. See ``EditorUndoAnchor``.
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
    /// Nothing is converted here: the handler converts once it knows it will write, and a paste it
    /// leaves to AppKit is converted by the net. Converting up front would rewrite the file for a
    /// paste the importer then refuses.
    func handledPaste(from pasteboard: NSPasteboard) -> Bool {
        handler?.handlePaste(from: pasteboard, in: self) == true
    }

    /// The modifiers of the key being handled, set across `keyDown(with:)` and empty otherwise. Tells
    /// ⇧Return from Return: AppKit sends both as `insertNewline:`, with no event.
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }

    // No conversion on a key command as such. Every key command (arrows, Page Down, Esc) passes
    // through `doCommand(by:)`, and converting there would mark a CRLF file that is only being read
    // as changed, for autosave to write. A command that writes goes through
    // ``shouldChangeText(inRanges:replacementStrings:)``, which converts and maps its range; the
    // list rules convert first themselves, once they know they will write
    // (`PlainTextEditor+MarkdownTyping`).

    /// The storage's carriage returns, asked of its ``EditorSourceStorage`` where it has one, which
    /// knows when there can be none, so an LF file is not scanned per keystroke.
    func pendingCarriageReturns() -> [EditorLineEndings.Change] {
        guard let storage = textStorage else { return [] }
        if let source = storage.delegate as? EditorSourceStorage { return source.carriageReturns() }
        return EditorLineEndings.carriageReturns(in: storage.mutableString)
    }

    // MARK: LF only — see `EditorLineEndings`

    private var isConvertingLineEndings = false
    /// Set while AppKit reads a paste or a drop into the text: text coming in, whose Unicode line
    /// separators become LF (``EditorLineEndings/normalizedIncoming(_:)``). Everything else the net
    /// sees may carry the file's own separators, which stay.
    private var isReadingIncomingText = false

    /// Set while a drag that started in this view is dropped back into it: the file's own text,
    /// moved, so it keeps its separators rather than being treated as text coming in.
    private var isDroppingOwnText = false

    /// Paste and a text drop both arrive here, under AppKit's own handling.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isReadingIncomingText = !isDroppingOwnText
        defer { isReadingIncomingText = false }
        return super.readSelection(from: pboard, type: type)
    }

    /// Turns every CRLF and lone CR in the buffer into LF, on the first edit to a file that is not
    /// LF and inside that edit's undo step: AppKit groups undo by event, so the ⌘Z that takes back
    /// the edit restores the original bytes too
    /// (`undoTakesBackTheFirstEditAndTheConversionTogether`). Does nothing to an LF buffer, a
    /// read-only view, or while an input method is composing (the marked text must not move).
    ///
    /// **Call it before an edit is measured, and only once the edit is certain**: a list rule, a
    /// link or image paste, a drop, and ``PlainTextEditor/apply(_:to:)`` before a verb reads the
    /// buffer. An edit measured on CRLF text carries offsets that are wrong after it.
    /// ``shouldChangeText(inRanges:replacementStrings:)`` is the net under plain typing and Replace.
    ///
    /// - Returns: the carriage returns taken out, empty when nothing was converted, so a caller
    ///   holding an offset measured before can map it with ``EditorLineEndings/mapped(_:through:)-(NSRange,_)``.
    ///   The view's own selection is mapped here.
    ///
    /// The `isEditable` check is not the guard (a non-editable view's `shouldChangeText` refuses
    /// too); it stays so a read-only file is not even scanned.
    /// - Parameter trigger: what is converting it, for the log line, such as `Return in a list`.
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
    /// and a line break being inserted (a pasted CRLF, a Replace string, a pasted U+2028) is written
    /// as LF. Either way the edit is made here, its ranges mapped across the conversion, and `false`
    /// tells the caller its own, now stale, edit is not wanted.
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
            // In the view's typing attributes, as AppKit's own insertion would be: a plain string
            // into an empty storage would carry no font or colour at all.
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        }
        storage.endEditing()
        didChangeText()
        // Where the caller's own edit would have left the caret: after what it inserted. With more
        // than one range AppKit lands it there itself.
        if ranges.count == 1 {
            setSelectedRange(NSRange(location: ranges[0].location + normalized[0].utf16.count, length: 0))
        }
        // And in view, as the caller's own edit would have done; told no, it never gets there, and
        // a long paste would leave the caret off screen.
        scrollRangeToVisible(selectedRange())
        return false
    }

    /// A word an input method commits is an edit too, and converts the file. AppKit asks
    /// ``shouldChangeText(inRanges:replacementStrings:)`` while the word is still marked, where the
    /// net must let it through, so the conversion happens here once composition ends, in the same
    /// event: one ⌘Z takes back the word and the conversion together.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let committing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if committing, !hasMarkedText() { convertLineEndingsToLF(on: "a word an input method committed") }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A drag that started in this view is text being moved, never a file.
        if let handler, (sender.draggingSource as AnyObject?) !== self,
           let files = Self.imageFiles(on: sender.draggingPasteboard) {
            // The offset is into the buffer as it stands: the handler converts and maps it once it
            // knows the drop writes, so a refused drop changes nothing.
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            switch handler.handleDrop(imageFiles: files, at: index, in: self) {
            case .handled:
                // The caret goes to the text, as AppKit's own drop puts it, or ⌘Z sent to whatever
                // had focus (a pane) would undo the last file operation instead of this link.
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

    /// The dragged files when every item on the pasteboard is an image file, or `nil`. All or
    /// nothing: a PDF beside two photos is not an image drop and gets its paths as text. A folder
    /// named like an image (`Trip.png`, a package) is not an image file either.
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

    /// The widest the text column may be, or `nil` for edge to edge, as whenever Readable Line
    /// Length or Wrap Lines is off. Set by `PlainTextEditor` on every pass; the insets follow.
    var readableColumnWidth: CGFloat? {
        didSet {
            guard readableColumnWidth != oldValue else { return }
            applyReadableInset(forWidth: frame.width)
            // Once per change of the column, never per resize, so it stays quiet while a window is
            // dragged.
            Logger.shared.info("[edit] Readable line length \(readableColumnWidth.map { "on — a \(Int($0.rounded()))pt column" } ?? "off") in a \(Int(frame.width.rounded()))pt editor, inset \(Int(textContainerInset.width.rounded()))pt")
        }
    }

    /// Every width change re-centres the column: a resize, a split divider, the rail folding. The
    /// frame, not the clip view: wrapping, the text view is the clip's width by autoresizing.
    ///
    /// The container is sized once, by hand. A tracking container is resized the moment the
    /// inset is set, against the old width since `super` hasn't run, then again by `super`: two
    /// widths per resize, the first wrong. TextKit 2 drops the visible layout on any width change
    /// and re-estimates it, so in a scrolled long document the text under a still pointer would
    /// jump lines on every frame of a resize or Expand. Tracking is back on before returning,
    /// because `updateNSView` reads `widthTracksTextView` to know whether lines wrap.
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

    /// Set while this view moves its own inset, so the resize that move causes can't undo it.
    /// Setting `textContainerInset` re-fits the view at its current width, which inside
    /// `setFrameSize` is still the old one; without this the nested call would set the old inset
    /// back, and every frame of Expand would re-wrap the visible text three times.
    private var isSettingReadableInset = false

    /// Called with each inset this view gives itself, for the tests that count them.
    var onReadableInset: ((CGFloat) -> Void)?

    /// Sets the side inset for a view `width` wide, when it differs from the one standing. Called
    /// before `super.setFrameSize`, with container tracking held off (see ``setFrameSize(_:)``).
    ///
    /// No feedback loop: the inset depends on the view's width alone, which no inset changes. A
    /// taller text may bring a legacy scroller and narrow the clip once, but the column is never
    /// wider for a narrower view, so the scroller can't be taken away again. The equality check
    /// makes a repeat call, such as the height-only `setFrameSize` a re-wrap causes, do nothing.
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

    /// The page under the text: the column plus the margins the text always keeps, so glyphs never
    /// touch its edge. With no readable cap the inset is ``EditorReadableColumn/baseInset`` and the
    /// page is the whole view; with one, it narrows by what the cap added to each side.
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

    /// Whether the caret's line is held at mid-height (Text ▸ Typewriter Scrolling), set by
    /// `PlainTextEditor` on every pass. Off, this view scrolls exactly as AppKit's does. On, the
    /// clip view lets the text scroll past its end (``EditorDocumentClipView``) so the last line can
    /// reach mid-height too, and turning it on centres the caret's line at once.
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

    /// Set across a click and the drag that follows it: AppKit's tracking loop runs inside
    /// `mouseDown(with:)` until the button comes up. Not `NSEvent.pressedMouseButtons`, the
    /// hardware's state, where a button held anywhere would stop a keystroke's centring.
    private var isTrackingMouse = false

    override func mouseDown(with event: NSEvent) {
        trackingMouse { super.mouseDown(with: event) }
    }

    /// Runs `body` as the mouse's: no scroll inside it is centred. Its own method so a test can
    /// stand in for AppKit's tracking loop: a synthesized click through `super` kills the test
    /// process.
    func trackingMouse(_ body: () -> Void) {
        isTrackingMouse = true
        defer { isTrackingMouse = false }
        body()
    }

    /// The one door every caret scroll goes through, and the only place typewriter scrolling acts.
    ///
    /// Typing, Return, Delete, arrows, Page Down, undo, a paste, Go to Line and a heading jump all
    /// end here with the caret's range. On, a bare caret's line is centred. AppKit's own scrolling
    /// stays for a selection (so a Find match shows where AppKit shows it), an input method
    /// composing (the marked text must not move under the candidate window) and the mouse (the
    /// text stays where the reader points). Trackpad scrolling and Split's Preview leading Source
    /// (`scrollLineToTop`, which moves the clip) never come here.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard typewriterScrolling, range.length == 0, !hasMarkedText(),
              !isTrackingMouse, centreLine(at: range.location) else {
            super.scrollRangeToVisible(range)
            return
        }
    }

    /// Scrolls so the line holding `offset` sits at mid-height, at once and unanimated so it keeps up
    /// with key repeat. `false` when there is nothing to measure, and AppKit scrolls instead.
    ///
    /// Measured on TextKit 2's own fragment, laid out from the caret only, never from the top: on a
    /// 4 MiB file that would be a full layout per keystroke. Enough for a far caret too
    /// (`aFarCaretInALongFileIsCentred`). Never `layoutManager` (see ``EditorTextSettings``).
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

    /// The insertion point at `offset` in this view's coordinates: TextKit 2's own segment, the
    /// rectangle AppKit draws the caret in, including the empty line after a final line break.
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

/// Source's clip view: AppKit's, plus typewriter scrolling's room below the last line, so the text
/// can scroll until its end sits at mid-height.
///
/// Room in the clip's bounds, not a content inset: a bottom inset tells AppKit half the screen is
/// covered, and its own scrolls then push a Find match or a composing caret up to avoid it. Here
/// every point on screen stays visible to AppKit. Off, every bound is `super`'s. Only Source's
/// scroll view has one; Preview's keeps AppKit's.
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
    /// screen below any top inset, so the last line can sit at mid-height.
    static func overscroll(height: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, ((height - topInset) / 2).rounded())
    }

    /// AppKit's bounds, let run past the end by ``overscroll(height:topInset:)`` while on, worked
    /// out from the proposed height so a resize carries it with no bookkeeping.
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard allowsTypewriterOverscroll, let document = documentView,
              proposedBounds.origin.y > rect.origin.y else { return rect }
        // AppKit's own furthest, asked rather than worked out: it is not quite the text's height
        // less the clip's (about 6pt past it), and the room is added to whatever AppKit allows.
        var furthest = proposedBounds
        furthest.origin.y = document.frame.maxY + proposedBounds.height
        let limit = super.constrainBoundsRect(furthest).origin.y
            + Self.overscroll(height: proposedBounds.height, topInset: contentInsets.top)
        rect.origin.y = max(rect.origin.y, min(proposedBounds.origin.y, limit))
        return rect
    }

    /// The page goes on past the text's ends. The text view draws its page only inside its frame;
    /// past it (typewriter scrolling's room, an elastic scroll past either end) is the clip's, or
    /// the window would show through. Same column and colour, so the two read as one page.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        onDraw?(dirtyRect)
        guard let band = pageBand else { return }
        NSColor.textBackgroundColor.setFill()
        band.intersection(dirtyRect).fill()
    }

    /// Called with each rect this view draws, for the test that checks the room is redrawn.
    var onDraw: ((NSRect) -> Void)?

    /// Where the page runs in this clip's coordinates, or `nil` with Page off: the text view's
    /// ``EditorTextView/pageRect`` stretched over the bounds' full height, and their full width where
    /// it is the whole text view, so a sideways overscroll of unwrapped text stays on the page.
    var pageBand: NSRect? {
        guard let text = documentView as? EditorTextView, text.drawsPage else { return nil }
        let page = text.pageRect
        guard page.width < text.bounds.width else { return bounds }
        let band = convert(page, from: text)
        return NSRect(x: band.minX, y: bounds.minY, width: band.width, height: bounds.height)
    }
}

/// Source's readable line length: the text in a centred column as wide as Preview's at the default
/// Text size, made by growing the side insets as the view widens.
///
/// Insets rather than a narrower container or view, so the margins still behave as AppKit's: the
/// text view spans the editor, so a click there puts the caret at the line's near end, a drag
/// selects, the wheel scrolls and find highlights land on the text. No `layoutManager`: every
/// number is the view's own frame and inset, so the editor stays on TextKit 2
/// (``EditorTextSettings``). Main-actor, as the font size it reads is.
@MainActor
enum EditorReadableColumn {

    /// The widest column at the default Text size: the read-only preview's `maxWidth: 720`, so
    /// switching Source ↔ Preview keeps the measure. At other sizes this one scales with the font
    /// (648pt at 0.9, 878pt at 1.35) to hold the same number of characters; Preview stays at 720.
    static let maxColumn: CGFloat = 720

    /// The text view's inset where nothing caps it. A view narrower than the column plus these
    /// keeps exactly them.
    static let baseInset = NSSize(width: 14, height: 12)

    /// The cap for these settings, or `nil` for none. None while lines don't wrap, where the long
    /// line running past the edge is the point.
    ///
    /// Scaled as the editor's glyphs are, through ``FontSize/scaledBox(_:basePoint:scale:)`` against
    /// the editor's 13pt, so the column holds the same number of characters at every Text size. A
    /// flat `720 × scale` would hold fewer at Largest, where the ramp damps the font.
    static func column(enabled: Bool, wraps: Bool, fontScale: CGFloat) -> CGFloat? {
        guard enabled, wraps else { return nil }
        return FontSize.scaledBox(maxColumn, basePoint: PlainTextEditor.baseFontSize, scale: fontScale)
    }

    /// The side inset that centres a `column`-wide text column in a view `viewWidth` wide, never
    /// less than ``baseInset``, so a narrower view (and any view with no cap) keeps the base inset.
    ///
    /// Not rounded to whole points, so past the cap the column is exactly `column` at every width
    /// and a live resize slides the text without re-wrapping. Rounded, it would alternate between
    /// 720 and 721 and re-wrap a borderline line back and forth. Glyphs sit at fractional positions
    /// anyway.
    static func horizontalInset(viewWidth: CGFloat, column: CGFloat?) -> CGFloat {
        guard let column else { return baseInset.width }
        return max(baseInset.width, (viewWidth - column) / 2)
    }
}

/// What a drop came to.
enum EditorDropOutcome: Equatable {
    /// Written and linked.
    case handled
    /// Ours, but refused: the host has said why, the drag is rejected and nothing changes.
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

/// Where a note's dropped and pasted images go, and who hears about it. Handed to the editor only
/// for a writable Markdown document; `nil` leaves image drops and pastes to AppKit.
struct EditorImageImporter {
    /// The open note. Its folder's `Images` folder is where the images go.
    var notePath: String
    /// Told about every import: what was written, so the panes can be re-read and Compare told, or
    /// why nothing was, for the banner.
    var report: (EditorImageImport.Report) -> Void

    init(notePath: String, report: @escaping (EditorImageImport.Report) -> Void) {
        self.notePath = notePath
        self.report = report
    }
}
