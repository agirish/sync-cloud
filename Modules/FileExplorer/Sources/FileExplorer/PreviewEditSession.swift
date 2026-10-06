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
    var undoManager: UndoManager?
    /// What the view draws: the projection's text, coloured, plus an empty phantom paragraph while one
    /// is open (§3.5).
    let display = NSTextStorage()
    private(set) var projection: MarkdownProjection
    private(set) var context = PreviewEditContext()

    var style: MarkdownProjection.Style {
        didSet { if style != oldValue { followSource() } }
    }

    /// Told about every refusal: the view shows the hint.
    var onRefusal: ((PreviewRefusal) -> Void)?
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
        self.style = style
        // Before the first decoration below, which starts the images loading against it.
        self.documentFolder = documentFolder
        projection = MarkdownProjection.project(source.textStorage.string, style: style)
        display.setAttributedString(decorated(projection.rendered))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: source.textStorage,
            queue: nil) { [weak self] note in
                let storage = note.object as? NSTextStorage
                let mask = storage?.editedMask ?? []
                let end = storage.map { NSMaxRange($0.editedRange) } ?? 0
                MainActor.assumeIsolated { self?.sourceDidChange(mask: mask, endingAt: end) }
            })
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     .NSUndoManagerDidCloseUndoGroup] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil) { [weak self] note in
                    let manager = (note.object as AnyObject?).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated { self?.undoManagerChanged(name, manager) }
                })
        }
    }

    // `NotificationCenter` holds the blocks, not this object; nothing to remove at deinit that a
    // dead `self` would act on, but the observers are dropped with it all the same.
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Edits

    /// Makes `edit` — or refuses it — and says where the selection goes.
    @discardableResult
    func perform(_ edit: RenderedEdit) -> Result {
        var edit = edit
        if let held {
            let end = held.at + (held.text as NSString).length
            dropHeld()
            if [.typing, .paste].contains(edit.action), edit.range == NSRange(location: end, length: 0) {
                edit.range = NSRange(location: held.at, length: 0)
                edit.text = held.text + edit.text
            } else if edit.range.location >= end {
                edit.range.location -= (held.text as NSString).length
            }
        }
        // An edit anywhere but into the phantom closes it first; one into it is the translator's.
        if let phantom = phantomOffset {
            // Typing, or a list, heading or quote verb, aimed at the opened paragraph itself.
            let typesIntoIt = ([.typing, .paste].contains(edit.action) || Self.isLineVerb(edit.action))
                && edit.range.location == phantom + 1 && edit.range.length == 0
            if typesIntoIt {
                edit.range = NSRange(location: phantom, length: 0)
            } else {
                closePhantom()
                if edit.range.location > phantom { edit.range.location -= 1 }
            }
        }
        let context = self.context
        let result = resolve(edit.action, quiet: Self.isTrailingSpace(edit)) {
            PreviewEditTranslator.translate(edit, in: $0, context: context)
        }
        if result == .unchanged, Self.isTrailingSpace(edit), lastRefusal == .unverified {
            return hold(edit.text, at: edit.range.location)
        }
        return result
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
        let attributes = offset > 0 ? display.attributes(at: offset - 1, effectiveRange: nil) : [:]
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
        dropHeld()
        closePhantom()
        return resolve(.typing, all: true) { PreviewEditTranslator.translateAll(edits, in: $0) }
    }

    /// Puts ``display`` back to the projection — after an input method's composition, which sits in
    /// the display until it is committed, was cancelled or refused.
    func redisplay() {
        held = nil
        phantomOffset = nil
        context.phantomAfterBlock = nil
        changeDisplay { Self.splice(decorated(projection.rendered), into: display) }
    }

    /// The last refusal ``resolve`` met, for the held-space rule.
    private var lastRefusal: PreviewRefusal?

    private func resolve(_ action: RenderedEdit.Action, all: Bool = false, quiet: Bool = false,
                         _ translate: (MarkdownProjection) -> PreviewEditOutcome) -> Result {
        lastRefusal = nil
        // Measured on the text as it will be written: LF only. A CRLF or CR file is converted in
        // the same step as this edit — and only if the edit is made.
        let needsConversion = source.textStorage.mutableString.range(of: "\r").location != NSNotFound
        let measured = needsConversion
            ? MarkdownProjection.project(EditorLineEndings.normalized(source.textStorage.string), style: style)
            : projection
        switch translate(measured) {
        case .apply(let application):
            write(application, for: action, converting: needsConversion, own: all)
            return .select(application.renderedSelection)
        case .moveCaret(let offset):
            breakTypingRun()
            return .select(NSRange(location: offset, length: 0))
        case .openPhantom(let block):
            breakTypingRun()
            return .select(NSRange(location: openPhantom(after: block) + 1, length: 0))
        case .setPending(let pending):
            context.pending = pending
            return .unchanged
        case .refuse(let reason):
            lastRefusal = reason
            // A space at a line's end is held, not refused: no hint for it.
            if quiet, reason == .unverified { return .unchanged }
            Logger.shared.debug("[edit] preview refused \(reason)")
            onRefusal?(reason)
            return .unchanged
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

    private func write(_ application: PreviewEditApplication, for action: RenderedEdit.Action,
                       converting: Bool, own: Bool) {
        isWriting = true
        defer { isWriting = false }
        if converting { source.convertLineEndingsToLF(undoManager: undoManager) }
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
        if source.text != application.source {
            // The translator's copy and the storage disagree — a bug, and one the display must not
            // hide: show what the file holds.
            Logger.shared.info("[edit] preview wrote a source that differs from the one it verified")
            projection = MarkdownProjection.project(source.textStorage.string, style: style)
        } else {
            projection = application.projection
        }
        changeDisplay { Self.splice(decorated(projection.rendered), into: display) }
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

    private func undoManagerChanged(_ name: Notification.Name, _ manager: ObjectIdentifier?) {
        guard let undoManager, manager == ObjectIdentifier(undoManager) else { return }
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
        projection = MarkdownProjection.project(source.textStorage.string, style: style)
        changeDisplay { Self.splice(decorated(projection.rendered), into: display) }
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

    /// The text column's width, which a rule spans and a table must fit to be editable. The view
    /// sets it as the window resizes.
    var columnWidth: CGFloat = 676 {
        didSet { if columnWidth != oldValue { style.columnWidth = columnWidth } }
    }

    // MARK: Images

    /// The open document's folder, which an image's relative path is relative to.
    var documentFolder: String?
    /// Every image this session has decoded, by its source as written — or why it could not be.
    private var images: [String: Swift.Result<NSImage, ImageRefusal>] = [:]
    private var loadingImages: Set<String> = []
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
            self.redrawImages(raw)
            self.onImageLoaded?(raw)
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

    /// The projection's text with what the view adds — colour, and something for each attachment to
    /// draw. The projection carries layout only.
    func decorated(_ rendered: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: rendered)
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
            if value != nil { text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range) }
        }
        return text
    }

    /// Replaces only what differs between `display` and `fresh` — characters or attributes — so the
    /// view keeps its layout and scroll position (§3.7: never replace the whole storage).
    static func splice(_ fresh: NSAttributedString, into display: NSTextStorage) {
        let old = display.string as NSString
        let new = fresh.string as NSString
        let shorter = min(old.length, new.length)
        var prefix = 0
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix),
              sameAttributes(display, at: prefix, fresh, at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix),
              sameAttributes(display, at: old.length - 1 - suffix, fresh, at: new.length - 1 - suffix) {
            suffix += 1
        }
        let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = NSRange(location: prefix, length: new.length - prefix - suffix)
        guard replaced.length > 0 || replacement.length > 0 else { return }
        display.beginEditing()
        display.replaceCharacters(in: replaced, with: fresh.attributedSubstring(from: replacement))
        display.endEditing()
    }

    /// Attachments compare by what they stand for: every projection makes new attachment objects.
    private static func sameAttributes(_ a: NSAttributedString, at i: Int,
                                       _ b: NSAttributedString, at j: Int) -> Bool {
        var left = a.attributes(at: i, effectiveRange: nil)
        var right = b.attributes(at: j, effectiveRange: nil)
        guard (left.removeValue(forKey: .attachment) == nil) == (right.removeValue(forKey: .attachment) == nil)
        else { return false }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}
