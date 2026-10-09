import AppKit
import Events

/// **One editable Preview's working state** (TE67 §3.4–3.7): the projection on screen, what the
/// view knows that the projection does not, and the one path from a keystroke to the source.
///
/// The view hands every edit here as a ``RenderedEdit`` and gets back where the selection goes. The
/// edit is translated against the projection, written to the document's ``EditorSourceStorage`` —
/// so it is in the file, on the document's undo stack, and in Source the moment it is made — and the
/// new projection is spliced into ``display``, which is what the view draws. Nothing on screen is
/// ever edited on its own: ``display`` is always a rendering of the source.
///
/// **No AppKit view in here**, so the rules are testable without a window.
@MainActor
final class PreviewEditSession {

    /// What came of an edit, for the view.
    enum Result: Equatable {
        /// Put the selection here.
        case select(NSRange)
        /// Nothing changed. The hint has been raised — through ``onRefusal`` — when it should be.
        case unchanged
    }

    let source: EditorSourceStorage
    /// The document's undo stack. Its own notifications only are observed — never every undo
    /// manager in the process, any of which may close a group off the main thread.
    var undoManager: UndoManager? {
        didSet { if undoManager !== oldValue { observeUndoManager() } }
    }
    /// What the view draws: the projection's text, coloured, plus an empty phantom paragraph while one
    /// is open (§3.5).
    let display = NSTextStorage()
    private(set) var projection: MarkdownProjection
    private(set) var context = PreviewEditContext()

    var style: MarkdownProjection.Style {
        didSet {
            guard style != oldValue else { return }
            lastDecoration = nil
            followSource()
            redressAttachments()
        }
    }

    /// Told about every refusal, with where in the source the refused edit was — the view shows the
    /// hint, and Show in Source puts the caret there.
    var onRefusal: ((PreviewRefusal, Int) -> Void)?
    /// Where the edit being made was aimed, in the projection — for a refusal's source offset.
    private var attemptedAt = 0

    /// The source offset nearest rendered `offset`: where typing would go, else its block's start.
    func sourceOffset(near offset: Int) -> Int {
        if let point = PreviewEditRules.insertionPoint(at: offset, in: projection) { return point.source }
        if let block = PreviewEditRules.block(at: offset, in: projection) { return projection.blocks[block].source.location }
        return 0
    }
    /// The source changed under the view — an undo, a redo, Source in Split — and the display has
    /// been brought up to it. The rendered offset is where that change ended, for the caret.
    var onSourceChange: ((Int) -> Void)?

    /// Where the phantom paragraph's line break sits in ``display``, while one is open.
    private var phantomOffset: Int?
    /// Spaces typed where Markdown draws none — at the end of a line — shown in ``display`` and not
    /// yet written: they reach the source with the next character typed after them, and are dropped
    /// when the caret leaves, which loses nothing, since a trailing space renders as nothing.
    private var held: (text: String, at: Int)?
    /// Set across the edits this session writes, so its own change is not taken for an outside one.
    private var isWriting = false
    /// Set while this session changes ``display`` — AppKit moves the selection to follow, and that
    /// move is not the person's.
    private var isChangingDisplay = false

    private func changeDisplay(_ body: () -> Void) {
        let was = isChangingDisplay
        isChangingDisplay = true
        defer { isChangingDisplay = was }
        body()
    }
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(source: EditorSourceStorage, undoManager: UndoManager?,
         style: MarkdownProjection.Style = MarkdownProjection.Style(), documentFolder: String? = nil) {
        self.source = source
        self.undoManager = undoManager
        var style = style
        if style.columnWidth == nil { style.columnWidth = Self.defaultColumn }
        self.style = style
        // Before the first decoration below, which starts the images loading against it.
        self.documentFolder = documentFolder
        projection = MarkdownProjection.project(source.textStorage.string, style: style)
        display.setAttributedString(decoratedProjection())
        // Both storages fix their attributes lazily, and left to it they do it on the first edit —
        // the first keystroke, which took 300 ms on a 256 KB note against 11 ms after it. Asked for
        // here it costs 25 ms, at open, beside the projection's 130 (measured 2026-10-08).
        display.ensureAttributesAreFixed(in: NSRange(location: 0, length: display.length))
        source.textStorage.ensureAttributesAreFixed(in: NSRange(location: 0, length: source.textStorage.length))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: source.textStorage,
            queue: nil) { [weak self] note in
                let storage = note.object as? NSTextStorage
                let mask = storage?.editedMask ?? []
                let end = storage.map { NSMaxRange($0.editedRange) } ?? 0
                MainActor.assumeIsolated { self?.sourceDidChange(mask: mask, endingAt: end) }
            })
        observeUndoManager()
    }

    nonisolated(unsafe) private var undoObservers: [NSObjectProtocol] = []

    private func observeUndoManager() {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers = []
        guard let undoManager else { return }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: undoManager, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.undoManagerChanged(name) }
                })
        }
    }

    // `NotificationCenter` holds the blocks, not this object; nothing to remove at deinit that a
    // dead `self` would act on, but the observers are dropped with it all the same.
    deinit {
        for observer in observers + undoObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Edits

    /// Makes `edit` — or refuses it — and says where the selection goes.
    @discardableResult
    func perform(_ edit: RenderedEdit) -> Result {
        // From the keystroke to the display holding its result — the layout after it is AppKit's.
        // `.debug`, so count these lines since a launch with the log level at Debug (§TE67.6).
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Logger.shared.debug("[edit] preview edit \(String(format: "%.2f", ms)) ms, \(source.textStorage.length) characters")
        }
        var edit = edit
        // **Held spaces and an opened paragraph are in the display only**, so an edit's range is
        // measured on text the projection does not have. Each is handled here, and every other
        // range is mapped past them — never left pointing at whatever now stands there (review,
        // 2026-10-05: ⌫ after two held spaces deleted the next paragraph's first letter).
        if let held {
            let heldRange = NSRange(location: held.at, length: (held.text as NSString).length)
            if [.typing, .paste].contains(edit.action), edit.range == NSRange(location: NSMaxRange(heldRange), length: 0) {
                dropHeld()
                edit.range = NSRange(location: held.at, length: 0)
                edit.text = held.text + edit.text
            } else if edit.action == .delete, edit.range.length > 0,
                      NSIntersectionRange(edit.range, heldRange) == edit.range {
                return deleteHeld(edit.range)
            } else {
                guard let mapped = Self.mapped(edit.range, past: heldRange) else { dropHeld(); return refuse(.notSupported) }
                dropHeld()
                edit.range = mapped
            }
        }
        // An edit anywhere but into the phantom closes it first; one into it is the translator's.
        if let phantom = phantomOffset {
            // Typing, or a list, heading or quote verb, aimed at the opened paragraph itself.
            let typesIntoIt = ([.typing, .paste].contains(edit.action) || Self.isLineVerb(edit.action))
                && edit.range.location == phantom + 1 && edit.range.length == 0
            if typesIntoIt {
                edit.range = NSRange(location: phantom, length: 0)
            } else if edit.action == .delete, edit.range == NSRange(location: phantom, length: 1) {
                // ⌫ in the empty paragraph Return opened: it closes, as it never was.
                closePhantom()
                return .select(NSRange(location: phantom, length: 0))
            } else {
                guard let mapped = Self.mapped(edit.range, past: NSRange(location: phantom, length: 1)) else {
                    closePhantom(); return refuse(.notSupported)
                }
                closePhantom()
                edit.range = mapped
            }
        }
        // A deletion is aimed where the caret was — ⌫ at a paragraph's start is about that paragraph,
        // not the line break before it.
        attemptedAt = edit.action == .delete ? NSMaxRange(edit.range) : edit.range.location
        let context = self.context
        let result = resolve(edit.action, quiet: Self.isTrailingSpace(edit)) {
            PreviewEditTranslator.translate(edit, in: $0, context: context)
        }
        if result == .unchanged, Self.isTrailingSpace(edit), lastRefusal == .unverified {
            return hold(edit.text, at: edit.range.location)
        }
        return result
    }

    /// `range`, measured on the display, in the projection's terms once `overlay` — display-only
    /// text — is gone. `nil` when it reaches into the overlay: there is no honest place for it.
    static func mapped(_ range: NSRange, past overlay: NSRange) -> NSRange? {
        if NSMaxRange(range) <= overlay.location { return range }
        if range.location >= NSMaxRange(overlay) {
            return NSRange(location: range.location - overlay.length, length: range.length)
        }
        return nil
    }

    private func refuse(_ reason: PreviewRefusal) -> Result {
        Logger.shared.debug("[edit] preview refused \(reason)")
        onRefusal?(reason, sourceOffset(near: min(attemptedAt, (projection.renderedString as NSString).length)))
        return .unchanged
    }

    /// ⌫ within held spaces takes them away — from the display, where they are; the file never
    /// had them.
    private func deleteHeld(_ range: NSRange) -> Result {
        guard let held else { return .unchanged }
        let text = (held.text as NSString).replacingCharacters(
            in: NSRange(location: range.location - held.at, length: range.length), with: "")
        changeDisplay { display.replaceCharacters(in: range, with: "") }
        self.held = text.isEmpty ? nil : (text, held.at)
        return .select(NSRange(location: range.location, length: 0))
    }

    private static func isLineVerb(_ action: RenderedEdit.Action) -> Bool {
        guard case .format(let verb) = action else { return false }
        switch verb {
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote: return true
        default: return false
        }
    }

    /// Spaces alone, typed with nothing selected: the one edit that can render as nothing.
    private static func isTrailingSpace(_ edit: RenderedEdit) -> Bool {
        edit.action == .typing && edit.range.length == 0 && !edit.text.isEmpty
            && edit.text.allSatisfy { $0 == " " }
    }

    private func hold(_ text: String, at offset: Int) -> Result {
        // At a paragraph's start, the paragraph's own first character: the storage gives a whole
        // paragraph its first character's style, and the break before belongs to the paragraph
        // above — a held space there took the paragraph's spacing away (found 2026-10-08, by the
        // session chains, once the splice stopped replacing the whole page on the next keystroke).
        let units = display.string as NSString
        let startsParagraph = offset == 0 || Self.endsParagraph(units.character(at: offset - 1))
        let from: Int? = startsParagraph && offset < display.length ? offset : offset > 0 ? offset - 1 : nil
        var attributes = from.map { display.attributes(at: $0, effectiveRange: nil) } ?? [:]
        // The text's look, never what the character beside it IS: a box and the gap after it, an
        // image, a link's target.
        for key in [NSAttributedString.Key.attachment, .previewAttachment, .previewImageSource, .link, .toolTip,
                    .kern] {
            attributes.removeValue(forKey: key)
        }
        held = (text, offset)
        changeDisplay {
            display.replaceCharacters(in: NSRange(location: offset, length: 0),
                                      with: NSAttributedString(string: text, attributes: attributes))
        }
        return .select(NSRange(location: offset + (text as NSString).length, length: 0))
    }

    private func dropHeld() {
        guard let held else { return }
        self.held = nil
        changeDisplay {
            display.replaceCharacters(in: NSRange(location: held.at, length: (held.text as NSString).length), with: "")
        }
    }

    /// Replace All and a spelling correction over several ranges (A11): every one or none, as one
    /// ⌘Z. Ranges are in ``display`` and must not reach into an open phantom paragraph.
    @discardableResult
    func performAll(_ edits: [RenderedEdit]) -> Result {
        var edits = edits
        for overlay in [held.map { NSRange(location: $0.at, length: ($0.text as NSString).length) },
                        phantomOffset.map { NSRange(location: $0, length: 1) }].compactMap({ $0 }) {
            let mapped = edits.map { edit -> RenderedEdit? in
                Self.mapped(edit.range, past: overlay).map { var e = edit; e.range = $0; return e }
            }
            guard mapped.allSatisfy({ $0 != nil }) else {
                dropHeld(); closePhantom(); return refuse(.notSupported)
            }
            edits = mapped.compactMap { $0 }
        }
        dropHeld()
        closePhantom()
        attemptedAt = edits.first?.range.location ?? 0
        return resolve(.typing, all: true) { PreviewEditTranslator.translateAll(edits, in: $0) }
    }

    /// Puts ``display`` back to the projection — after an input method's composition, which sits in
    /// the display until it is committed, was cancelled or refused.
    func redisplay() {
        held = nil
        phantomOffset = nil
        context.phantomAfterBlock = nil
        changeDisplay { Self.splice(decoratedProjection(), into: display) }
    }

    /// The last refusal ``resolve`` met, for the held-space rule.
    private var lastRefusal: PreviewRefusal?

    private func resolve(_ action: RenderedEdit.Action, all: Bool = false, quiet: Bool = false,
                         _ translate: (MarkdownProjection) -> PreviewEditOutcome) -> Result {
        lastRefusal = nil
        // Measured on the text as it will be written: LF only. A CRLF or CR file is converted in
        // the same step as this edit — and only if the edit is made.
        let needsConversion = !source.carriageReturns().isEmpty
        let measured = needsConversion
            ? MarkdownProjection.project(EditorLineEndings.normalized(source.textStorage.string), style: style)
            : projection
        switch translate(measured) {
        case .apply(let application):
            // Measured on the LF text: written only once the storage IS that text. The conversion
            // declines while Source (in Split) is composing a word, and then so does this edit.
            if needsConversion, !convertSource() {
                Logger.shared.debug("[edit] preview edit held back: the file could not be converted to LF yet")
                return .unchanged
            }
            write(application, for: action, own: all)
            return .select(application.renderedSelection)
        case .moveCaret(let offset):
            breakTypingRun()
            return .select(NSRange(location: offset, length: 0))
        case .openPhantom(let block):
            breakTypingRun()
            return .select(NSRange(location: openPhantom(after: block) + 1, length: 0))
        case .setPending(let pending):
            // A styled character is a step of its own, as a verb is in Source.
            breakTypingRun()
            context.pending = pending
            return .unchanged
        case .refuse(let reason):
            lastRefusal = reason
            // A space at a line's end is held, not refused: no hint for it.
            if quiet, reason == .unverified { return .unchanged }
            return refuse(reason)
        case .ignore:
            return .unchanged
        }
    }

    /// The caret moved on its own — a click, an arrow key. Pending styles and an open phantom
    /// paragraph belong to the place they were made, and typing elsewhere starts a new undo step.
    func selectionMoved(to selection: NSRange) {
        guard !isWriting, !isChangingDisplay else { return }
        if let held, selection != NSRange(location: held.at + (held.text as NSString).length, length: 0) {
            dropHeld()
        }
        context.pending = []
        breakTypingRun()
        if let phantom = phantomOffset, selection.location != phantom + 1 || selection.length != 0 {
            closePhantom()
        }
    }

    /// The selection in the source, for the status line's Line and Column and for Show in Source.
    func sourceSelection(for rendered: NSRange) -> NSRange? {
        var range = rendered
        if let phantom = phantomOffset, range.location > phantom { range.location -= 1 }
        return PreviewEditTranslator.sourceSelection(for: range, in: projection)
    }

    /// The conversion, as this session's own write — not an outside change to follow.
    private func convertSource() -> Bool {
        isWriting = true
        defer { isWriting = false }
        return source.convertLineEndingsToLF(undoManager: undoManager)
    }

    private func write(_ application: PreviewEditApplication, for action: RenderedEdit.Action,
                       own: Bool) {
        isWriting = true
        defer { isWriting = false }
        if !own, application.undo == .typing, application.edits.count == 1 {
            type(application.edits[0])
        } else {
            breakTypingRun()
            let name = Self.actionName(for: action)
            // Last first: every range is against the source before any of them.
            for edit in application.edits.reversed() {
                source.replace(edit.range, with: edit.text, undoManager: undoManager, actionName: name)
            }
        }
        context = PreviewEditContext()
        phantomOffset = nil
        // Unit for unit: `!=` on two long Strings compares them as Unicode, and their `utf8`
        // walks a storage's String a character at a time — each a sixth of a keystroke, measured.
        if !(source.textStorage.string as NSString).isEqual(to: application.source) {
            // The translator's copy and the storage disagree — a bug, and one the display must not
            // hide: show what the file holds.
            Logger.shared.info("[edit] preview wrote a source that differs from the one it verified")
            projection = MarkdownProjection.project(source.textStorage.string, style: style, after: projection)
        } else {
            projection = application.projection
        }
        changeDisplay { Self.splice(decoratedProjection(), into: display) }
    }

    static func actionName(for action: RenderedEdit.Action) -> String {
        switch action {
        case .paste: return "Paste"
        case .format(let verb): return verb.title
        case .tickTask: return EditorWorkspaceView.taskActionName
        default: return "Typing"
        }
    }

    // MARK: Typing runs — one ⌘Z per run of typing, as in Source

    /// The typing since the caret last moved: where it now stands in the source, and what stood there
    /// before. One undo action covers the whole run; each keystroke widens it instead of registering
    /// another, which is how `NSTextView` coalesces typing in Source.
    private final class TypingRun {
        var range: NSRange
        var original: String
        init(range: NSRange, original: String) { self.range = range; self.original = original }
    }

    private var run: TypingRun?
    /// Set when this session registered the run's action in the current event, so the group that
    /// closes it is known to be the run's own. Any other group closing ends the run.
    private var expectsOwnGroupClose = false

    private func type(_ edit: PreviewSourceEdit) {
        let typed = (edit.text as NSString).length
        // **Any edit touching the run joins it** — typing on at its end, backspacing into it or just
        // before it, and a table re-padded around the cell being typed in (decision T), whose one
        // replacement spans rows above and below. The run grows to cover both, and what it puts
        // back on ⌘Z is what stood over that span before the run began: the run's own original for
        // its part, the text as it still is for the rest, which the run never touched.
        if let run, NSMaxRange(edit.range) >= run.range.location, edit.range.location <= NSMaxRange(run.range) {
            let text = source.textStorage.mutableString
            let start = min(run.range.location, edit.range.location)
            let end = max(NSMaxRange(run.range), NSMaxRange(edit.range))
            let before = text.substring(with: NSRange(location: start, length: run.range.location - start))
            let after = text.substring(with: NSRange(location: NSMaxRange(run.range), length: end - NSMaxRange(run.range)))
            source.replace(edit.range, with: edit.text, undoManager: nil)
            run.original = before + run.original + after
            run.range = NSRange(location: start, length: end - start + typed - edit.range.length)
            return
        }
        let removed = source.textStorage.mutableString.substring(with: edit.range)
        source.replace(edit.range, with: edit.text, undoManager: nil)
        let started = TypingRun(range: NSRange(location: edit.range.location, length: typed), original: removed)
        run = started
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: source) { [weak undoManager] source in
            source.replace(started.range, with: started.original, undoManager: undoManager, actionName: "Typing")
        }
        undoManager.setActionName("Typing")
        expectsOwnGroupClose = true
    }

    private func breakTypingRun() {
        run = nil
        expectsOwnGroupClose = false
    }

    private func undoManagerChanged(_ name: Notification.Name) {
        if name == .NSUndoManagerDidCloseUndoGroup, expectsOwnGroupClose {
            expectsOwnGroupClose = false
            return
        }
        // An undo, a redo, or someone else's step on top of the run: the next keystroke starts anew.
        run = nil
    }

    // MARK: Following the source

    private func sourceDidChange(mask: NSTextStorageEditActions, endingAt end: Int) {
        guard !isWriting, mask.contains(.editedCharacters) else { return }
        breakTypingRun()
        followSource()
        onSourceChange?(PreviewEditRules.renderedOffset(forSource: end, in: projection))
    }

    /// Re-projects the source and splices the difference into ``display``.
    private func followSource() {
        held = nil
        context = PreviewEditContext()
        phantomOffset = nil
        projection = MarkdownProjection.project(source.textStorage.string, style: style, after: projection)
        changeDisplay { Self.splice(decoratedProjection(), into: display) }
    }

    // MARK: The phantom paragraph

    private func openPhantom(after block: Int) -> Int {
        if phantomOffset != nil { closePhantom() }
        let offset = NSMaxRange(projection.blocks[block].rendered)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3 * style.scale
        paragraph.paragraphSpacing = 8 * style.scale
        changeDisplay { display.replaceCharacters(in: NSRange(location: offset, length: 0), with: NSAttributedString(
            string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14 * style.scale),
                                       .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor])) }
        phantomOffset = offset
        context.phantomAfterBlock = block
        return offset
    }

    private func closePhantom() {
        guard let offset = phantomOffset else { return }
        phantomOffset = nil
        changeDisplay { display.replaceCharacters(in: NSRange(location: offset, length: 1), with: "") }
        context.phantomAfterBlock = nil
    }

    // MARK: Drawing

    static let linkTip = "⌘-click to open"
    static let readOnlyTip = "Edit in Source — Preview can't change this part"

    /// The text column's width, which a rule spans and a table must fit to be editable. The view
    /// sets it as the window resizes. **Kept in ``style``, the one place**: held beside it, a scale
    /// change rebuilt the style without it and a table no longer fitted anything (review).
    var columnWidth: CGFloat {
        get { style.columnWidth ?? Self.defaultColumn }
        set { if style.columnWidth != newValue { style.columnWidth = newValue } }
    }
    static let defaultColumn: CGFloat = 676

    /// Every attachment sized again — after the column or the text size changed, which the splice
    /// cannot see: attachments are compared by what they stand for, not by their size.
    private func redressAttachments() {
        changeDisplay {
            display.beginEditing()
            display.enumerateAttribute(.previewAttachment, in: NSRange(location: 0, length: display.length)) { value, range, _ in
                guard let raw = value as? String, let kind = PreviewAttachments.Kind(rawValue: raw),
                      let attachment = display.attribute(.attachment, at: range.location, effectiveRange: nil)
                        as? NSTextAttachment else { return }
                if let image = display.attribute(.previewImageSource, at: range.location, effectiveRange: nil) as? String {
                    dressImage(attachment, source: image)
                } else {
                    PreviewAttachments.dress(attachment, as: kind, scale: style.scale, columnWidth: columnWidth)
                }
                display.edited(.editedAttributes, range: range, changeInLength: 0)
            }
            display.endEditing()
        }
    }

    // MARK: Images

    /// The open document's folder, which an image's relative path is relative to.
    var documentFolder: String?
    /// Every image this session has decoded, by its source as written — or why it could not be.
    private var images: [String: Swift.Result<NSImage, ImageRefusal>] = [:]
    private var loadingImages: Set<String> = []
    private var failedAt: [String: Date] = [:]
    /// How long a picture that could not be shown waits before it is looked for again.
    var imageRetry: TimeInterval = 5
    struct ImageRefusal: Error { var reason: String }
    /// The tallest an image is drawn, as the read-only preview caps it.
    static let maxImageHeight: CGFloat = 420

    /// Told when an image finishes loading — for tests, which have no run loop to watch.
    var onImageLoaded: ((String) -> Void)?

    /// Gives an image block's attachment its picture, or starts loading it.
    private func dressImage(_ attachment: NSTextAttachment, source raw: String) {
        switch images[raw] {
        case .success(let image)?:
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: Self.fitted(image.size, column: columnWidth,
                                                                       scale: style.scale))
        case .failure(let refusal)?:
            PreviewAttachments.dress(attachment, as: .image, scale: style.scale, columnWidth: columnWidth,
                                     label: "Image — \(refusal.reason)")
        case nil:
            loadImage(raw)
        }
    }

    static func fitted(_ size: CGSize, column: CGFloat, scale: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let factor = min(1, column / size.width, maxImageHeight * scale / size.height)
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    /// Resolved and decoded off the main actor, as `MarkdownImageView` does — then every attachment
    /// showing that source gets the picture, and its layout is redone.
    private func loadImage(_ raw: String) {
        guard !loadingImages.contains(raw) else { return }
        loadingImages.insert(raw)
        let folder = documentFolder
        Task { @MainActor [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) {
                MarkdownImageSource.resolve(raw, relativeTo: folder)
            }.value
            let result: Swift.Result<NSImage, ImageRefusal>
            switch resolved {
            case .refused(let reason):
                result = .failure(ImageRefusal(reason: reason))
            case .local(let path):
                let image = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
                result = image.map { .success($0) } ?? .failure(ImageRefusal(reason: "Couldn’t be read as an image."))
            }
            guard let self else { return }
            self.loadingImages.remove(raw)
            self.images[raw] = result
            if case .failure = result { self.failedAt[raw] = Date() } else { self.failedAt[raw] = nil }
            self.redrawImages(raw)
            self.onImageLoaded?(raw)
        }
    }

    /// Looks again, once ``imageRetry`` has passed, for every picture in the note that could not be
    /// shown: the file may be written, or downloaded, after the note names it. At any keystroke, as
    /// when each one decorated the whole page — only the paragraphs that changed are decorated now,
    /// and a picture elsewhere was never looked for again (review, 2026-10-09). Its attachment is
    /// the display's, so the load redraws it there.
    private func retryFailedImages() {
        let now = Date()
        let due = failedAt.filter { now.timeIntervalSince($0.value) > imageRetry && !loadingImages.contains($0.key) }
        guard !due.isEmpty else { return }
        let shown = Set(projection.blocks.compactMap { block -> String? in
            if case .image(let source, _) = block.kind { return source }
            return nil
        })
        for raw in due.keys {
            guard shown.contains(raw) else {
                // Gone from the note: forgotten, so it is looked for afresh if it comes back.
                failedAt[raw] = nil
                images[raw] = nil
                continue
            }
            images[raw] = nil
            loadImage(raw)
        }
    }

    private func redrawImages(_ raw: String) {
        changeDisplay {
            display.beginEditing()
            display.enumerateAttribute(.previewImageSource, in: NSRange(location: 0, length: display.length)) { value, range, _ in
                guard value as? String == raw,
                      let attachment = display.attribute(.attachment, at: range.location, effectiveRange: nil)
                        as? NSTextAttachment else { return }
                dressImage(attachment, source: raw)
                display.edited(.editedAttributes, range: range, changeInLength: 0)
            }
            display.endEditing()
        }
    }

    /// The last decoration, and the rendering it was made from.
    private var lastDecoration: (rendered: NSAttributedString, decorated: NSAttributedString)?

    /// ``decorated(_:)`` of the projection — redone only for the paragraphs whose rendering changed
    /// since the last one, the rest kept. Decorating a 40 KB note whole was most of a keystroke once
    /// the projection stopped re-reading all of it (measured 2026-10-07).
    ///
    /// Paragraphs, because everything decoration adds is per character except the paragraph style
    /// `fixAttributes` evens out across each paragraph.
    private func decoratedProjection() -> NSAttributedString {
        retryFailedImages()
        let rendered = projection.rendered
        guard let last = lastDecoration, last.rendered.length > 0, rendered.length > 0 else {
            let whole = decorated(rendered)
            lastDecoration = (rendered, whole)
            return whole
        }
        if last.rendered === rendered { return last.decorated }
        guard let difference = PreviewAttributeShape.difference(from: last.rendered, to: rendered) else {
            lastDecoration = (rendered, last.decorated)
            return last.decorated
        }
        // Whole paragraphs, and the one after them; then whole lists where a list's identity
        // changed — a list must not be left half one projection's `NSTextList` and half another's,
        // or TextKit numbers it as two — and again, until neither widens it. Against the last
        // DECORATION, whose lists are what the kept part holds: an earlier one's, where a list was
        // kept through a re-read that did not change how it looks.
        let units = PreviewAttributeShape.units(rendered)
        var fresh = Self.followingParagraph(after: Self.paragraphs(around: difference.new, in: units), in: units)
        while true {
            let lists = PreviewListIdentity.wholeLists(around: fresh, in: rendered, against: last.decorated)
            let widened = Self.paragraphs(around: lists, in: units)
            if widened == fresh { break }
            fresh = widened
        }
        let stale = NSRange(location: fresh.location,
                            length: last.rendered.length - (rendered.length - NSMaxRange(fresh)) - fresh.location)
        let whole = NSMutableAttributedString(attributedString: last.decorated)
        whole.replaceCharacters(in: stale, with: decorated(rendered, in: fresh))
        lastDecoration = (rendered, whole)
        return whole
    }

    /// `range` widened to whole paragraphs — from just after a paragraph's end to just after one.
    static func paragraphs(around range: NSRange, in units: [unichar]) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start > 0, !endsParagraph(units[start - 1]) { start -= 1 }
        while end < units.count, !(end > start && endsParagraph(units[end - 1])) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whole paragraphs `range`, and **the paragraph after them**, which may have been the tail of
    /// a longer one before: its last character took that paragraph's style, and keeps it until
    /// decorated again (found 2026-10-09, by Source edits in the session chains: a fence typed into
    /// a quote left the break after it in the quote's style).
    static func followingParagraph(after range: NSRange, in units: [unichar]) -> NSRange {
        var end = NSMaxRange(range)
        guard end < units.count else { return range }
        end += 1
        while end < units.count, !endsParagraph(units[end - 1]) { end += 1 }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Whether `unit` ends a paragraph, as the text system counts them.
    static func endsParagraph(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2029 || unit == 0x85
    }

    /// The projection's text with what the view adds — colour, and something for each attachment to
    /// draw. The projection carries layout, and what is read-only.
    func decorated(_ rendered: NSAttributedString) -> NSAttributedString {
        decorated(rendered, in: NSRange(location: 0, length: rendered.length))
    }

    /// ``decorated(_:)`` of whole paragraphs `range` of `rendered`, which is the projection's.
    private func decorated(_ rendered: NSAttributedString, in range: NSRange) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: rendered.attributedSubstring(from: range))
        let whole = NSRange(location: 0, length: text.length)
        PreviewAttachments.dress(text, scale: style.scale, columnWidth: columnWidth)
        text.enumerateAttribute(.previewImageSource, in: whole) { value, range, _ in
            guard let raw = value as? String,
                  let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil)
                    as? NSTextAttachment else { return }
            dressImage(attachment, source: raw)
        }
        text.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        text.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            // A plain click places the caret here; say how to follow it (§1.2).
            text.addAttribute(.toolTip, value: Self.linkTip, range: range)
        }
        // What cannot be edited here says so where the pointer is, before a keystroke is refused.
        text.enumerateAttribute(.previewReadOnly, in: whole) { value, range, _ in
            guard value != nil else { return }
            text.addAttribute(.toolTip, value: Self.readOnlyTip, range: range)
        }
        // What the display's storage would add on its own — a font for the breaks between blocks,
        // one paragraph style per paragraph — added here, so the splice compares like with like.
        // Unfixed, the first break differed every time, and every keystroke replaced the whole page
        // from there (measured 2026-10-07: 28,592 of 28,612 characters on a 40 KB note).
        text.fixAttributes(in: whole)
        return text
    }

    /// Replaces only what differs between `display` and `fresh` — characters or attributes — so the
    /// view keeps its layout and scroll position (§3.7: never replace the whole storage).
    ///
    /// **Lists compare by shape, and one that changed identity is replaced whole.** A projection
    /// can make new `NSTextList`s, which are equal only to themselves, so comparing them as they are
    /// found "changed" from the note's first list on — and the view re-laid all of it (measured
    /// 2026-10-07: a third of a keystroke on a 40 KB note). But TextKit numbers a list's items by
    /// that same identity, so a list whose identity did change is swapped as a whole, never half
    /// old, half new (`PreviewListIdentity`).
    static func splice(_ fresh: NSAttributedString, into display: NSTextStorage) {
        guard let difference = PreviewAttributeShape.difference(from: display, to: fresh) else { return }
        let whole = PreviewListIdentity.wholeLists(around: difference.new, in: fresh, against: display)
        let replaced = NSRange(location: whole.location,
                               length: display.length - (fresh.length - NSMaxRange(whole)) - whole.location)
        display.beginEditing()
        display.replaceCharacters(in: replaced, with: fresh.attributedSubstring(from: whole))
        display.endEditing()
    }

}
