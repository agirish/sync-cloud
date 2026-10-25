import AppKit
import SwiftUI
import Design
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
    /// Text ▸ Continue Lists, handed in by the view and carried into every edit's context — kept
    /// apart from ``context``, which each edit resets (LST-3).
    var continuesLists = true

    var style: MarkdownProjection.Style {
        didSet {
            guard style != oldValue else { return }
            restyle(columnOnly: style.scale == oldValue.scale)
        }
    }

    /// ``context`` with the settings that outlive an edit.
    private var editContext: PreviewEditContext {
        var context = self.context
        context.continuesLists = continuesLists
        return context
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
    private(set) var phantomOffset: Int?
    /// Spaces typed where Markdown draws none — at the end of a line — shown in ``display`` and not
    /// yet written: they reach the source with the next character typed after them, and are dropped
    /// when the caret leaves, which loses nothing, since a trailing space renders as nothing.
    private(set) var held: Held?

    /// Text in the display that the source does not have yet, and where.
    struct Held: Equatable {
        var text: String
        var at: Int
        /// Whether it is a held ⇧Return — with the spaces typed after it, if any. Only ever this
        /// session's own text, which starts with U+2028 only when it held a line break: a typed or
        /// pasted U+2028 is never held.
        var isLineBreak: Bool { text.first == "\u{2028}" }
    }
    /// Set across the edits this session writes, so its own change is not taken for an outside one.
    private var isWriting = false
    /// Set while this session changes ``display`` — AppKit moves the selection to follow, and that
    /// move is not the person's.
    private var isChangingDisplay = false

    private func changeDisplay(_ body: () -> Void) {
        let was = isChangingDisplay
        isChangingDisplay = true
        defer { isChangingDisplay = was }
        displayIsDecoration = false
        body()
    }
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// **The ink a link wears: the window's hue, as read-only Preview draws it (ED5)** — not
    /// `NSColor.linkColor`, which flipped every link between the two each time Edit in Preview was
    /// turned on or off. The view hands in its own (`PreviewEditorView.linkInk`, the hue in a shade
    /// that reads as text — FE2); a new one redecorates the page.
    var linkColor: NSColor {
        didSet {
            guard linkColor != oldValue else { return }
            lastDecoration = nil
            changeDisplay { replaced = Self.splice(overlaid(decoratedProjection()), into: display) }
        }
    }

    init(source: EditorSourceStorage, undoManager: UndoManager?,
         style: MarkdownProjection.Style = MarkdownProjection.Style(), documentFolder: String? = nil,
         linkColor: NSColor = PreviewEditorView.linkInk(LiquidGlassHue.stored().accentColor)) {
        self.source = source
        self.undoManager = undoManager
        self.linkColor = linkColor
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
        displayIsDecoration = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: source.textStorage,
            queue: nil) { [weak self] note in
                let storage = note.object as? NSTextStorage
                let mask = storage?.editedMask ?? []
                let end = storage.map { NSMaxRange($0.editedRange) } ?? 0
                MainActor.assumeIsolated { self?.sourceDidChange(mask: mask, endingAt: end) }
            })
        // An edit to the display this session did not make — an input method's marked text — and
        // the display is no longer the last decoration (``redraw()``).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: display, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isChangingDisplay else { return }
                    self.displayIsDecoration = false
                }
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
            Logger.shared.debug("[edit] preview edit \(String(format: "%.2f", ms)) ms, \(source.textStorage.length) characters, \(redrawNote)")
        }
        // What this keystroke redrew, and nothing a text-size change before it did (round 2).
        replaced = nil
        var edit = edit
        attempted = Self.logName(edit.action)
        // **Held text and an opened paragraph are in the display only**, so an edit's range is
        // measured on text the projection does not have. What is aimed at them is handled here,
        // and every other range is mapped past them — never left pointing at whatever now stands
        // there (review, 2026-10-05: ⌫ after two held spaces deleted the next paragraph's first
        // letter). There is never more than one (``overlay``).
        let caret = edit.range.length == 0 ? edit.range.location : nil
        if let held, let caret, caret == held.at + (held.text as NSString).length,
           [.typing, .paste].contains(edit.action) || Self.isInlineVerb(edit.action) {
            if Self.isInlineVerb(edit.action) {
                // ⌘B after held text: a style for what is typed next, which the held text waits
                // for with it — it dropped them, and wrote `one**x**` (round 2, 2026-10-10).
                return resolve(edit.action) {
                    PreviewEditTranslator.translate(RenderedEdit(range: NSRange(location: held.at, length: 0),
                                                                 action: edit.action), in: $0, context: self.editContext)
                }
            }
            dropHeld()
            // **A held line break is SAID to be one** — its text handed on as what follows it, never
            // sniffed from the text: a paste starting with U+2028 was taken for it (round 2).
            edit = held.isLineBreak
                ? RenderedEdit(range: NSRange(location: held.at, length: 0),
                               text: String(held.text.dropFirst()) + edit.text, action: .lineBreak)
                : RenderedEdit(range: NSRange(location: held.at, length: 0), text: held.text + edit.text,
                               action: edit.action)
        } else if let held, edit.action == .delete, edit.range.length > 0,
                  NSIntersectionRange(edit.range, NSRange(location: held.at, length: (held.text as NSString).length)) == edit.range {
            return deleteHeld(edit.range)
        } else if let phantom = phantomOffset, let caret, caret == phantom + 1,
                  [.typing, .paste, .lineBreak].contains(edit.action) || Self.isLineVerb(edit.action)
                    || Self.isInlineVerb(edit.action) {
            // Typing, a list, heading or quote verb, or a style for what is typed next, aimed at the
            // opened paragraph itself. A style closed it, and the bold text went on the end of the
            // paragraph above (review, 2026-10-09).
            //
            // **And nothing that would draw nothing there**: a space starting the paragraph, which
            // renders as nothing and has nothing to be held before (held, it went in BEFORE the
            // paragraph's line break, and the next character joined the paragraph above — review,
            // 2026-10-09); and ⇧Return, a line break with no line before it — which closed the
            // paragraph and held the break at the end of the one above, so the next letter went
            // there (round 2, 2026-10-10). The paragraph stays open, the caret in it.
            if edit.action == .lineBreak || Self.isBlank(edit) { return .unchanged }
            edit.range = NSRange(location: phantom, length: 0)
        } else if let phantom = phantomOffset, edit.action == .delete, edit.range == NSRange(location: phantom, length: 1) {
            // ⌫ in the empty paragraph Return opened: it closes, as it never was.
            closePhantom()
            return .select(NSRange(location: phantom, length: 0))
        } else if let overlay {
            guard let mapped = Self.mapped(edit.range, past: overlay) else { dropOverlay(); return refuse(.notSupported) }
            dropOverlay()
            edit.range = mapped
        }
        // A deletion is aimed where the caret was — ⌫ at a paragraph's start is about that paragraph,
        // not the line break before it.
        attemptedAt = edit.action == .delete ? NSMaxRange(edit.range) : edit.range.location
        let context = self.editContext
        // **What Markdown draws as nothing until something follows it on the line** — spaces at a
        // line's end, or before a span's closing marker or punctuation (`**world **` is no bold,
        // round 2), and ⇧Return at a paragraph's end: a hard break with nothing after it is no
        // break. Held in the display and written with the next character (`hold`). A space at a
        // line's START renders as nothing whatever follows, so it is not held there, nor written:
        // the next character went in after it and was refused (review, 2026-10-09).
        let blank = Self.isBlank(edit)
        // Asked only of ⇧Return: a walk of the segments for every keystroke was not free (round 2).
        let breaksAtEnd = edit.action == .lineBreak && edit.range.length == 0
            && PreviewEditRules.endsLine(at: edit.range.location, in: projection)
        let result = resolve(edit.action, quiet: blank || breaksAtEnd) {
            PreviewEditTranslator.translate(edit, in: $0, context: context)
        }
        guard result == .unchanged, lastRefusal == .unverified, blank || breaksAtEnd else { return result }
        if breaksAtEnd { return hold("\u{2028}" + edit.text, at: edit.range.location) }
        if !PreviewEditRules.startsLine(at: edit.range.location, in: projection) {
            return hold(edit.text, at: edit.range.location)
        }
        return .unchanged
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

    /// The hint, and a line in the log that lets a report be diagnosed (review, 2026-10-09: there
    /// was one `.debug` line with the reason alone, and a dozen places give each reason): what was
    /// done, in what kind of block, where in the source, which line of which file refused it, and
    /// how far a rendering that did not verify was off. **Never the text** — offsets and kinds only.
    private func refuse(_ reason: PreviewRefusal, by file: String = "session", line: Int = #line,
                        unverified: PreviewEditTranslator.Unverified? = nil) -> Result {
        let at = min(attemptedAt, (projection.renderedString as NSString).length)
        let offset = sourceOffset(near: at)
        let block = PreviewEditRules.block(at: at, in: projection).map { Self.logName(projection.blocks[$0].kind) }
        let why = unverified.map { ", " + $0.detail } ?? ""
        let message = "[edit] preview refused \(attempted) in \(block ?? "no block") at source \(offset): \(reason) (\(file) line \(line)\(why))"
        // **The first of a run at INFO, its repeats at debug** (round 2, 2026-10-10): a key held
        // down in front matter wrote an INFO line per auto-repeat. A repeat is the same thing
        // refused at the same site with no edit made between; the hint is raised for each.
        let site = "\(attempted) \(reason) \(file) \(line)"
        if site == lastRefusedSite {
            Logger.shared.debug(message)
        } else {
            Logger.shared.info(message)
        }
        lastRefusedSite = site
        onRefusal?(reason, offset)
        return .unchanged
    }

    /// The last refusal logged at INFO, until an edit is made — see ``refuse(_:by:line:unverified:)``.
    private var lastRefusedSite: String?

    /// What was being done, for the log.
    private var attempted = "typing"

    private static func logName(_ action: RenderedEdit.Action) -> String {
        switch action {
        case .typing: "typing"
        case .paste: "paste"
        case .delete: "delete"
        case .returnKey: "Return"
        case .lineBreak: "⇧Return"
        case .tab: "Tab"
        case .backtab: "⇧Tab"
        // As the menu names it — a refused verb's one line, where the view once wrote a second.
        case .format(let verb): "Markup ▸ \(verb.title)"
        case .tickTask: "tick"
        }
    }

    /// A block's kind, by name only — an image's path, a code block's language, are the note's.
    private static func logName(_ kind: PreviewBlock.Kind) -> String {
        switch kind {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .listItem: "list item"
        case .codeBlock: "code block"
        case .table: "table"
        case .thematicBreak: "rule"
        case .frontMatter: "front matter"
        case .image: "image"
        case .html: "HTML"
        case .other: "other block"
        }
    }

    /// ⌫ within held spaces takes them away — from the display, where they are; the file never
    /// had them.
    private func deleteHeld(_ range: NSRange) -> Result {
        guard let held else { return .unchanged }
        let text = (held.text as NSString).replacingCharacters(
            in: NSRange(location: range.location - held.at, length: range.length), with: "")
        changeDisplay { display.replaceCharacters(in: range, with: "") }
        self.held = text.isEmpty ? nil : Held(text: text, at: held.at)
        return .select(NSRange(location: range.location, length: 0))
    }

    private static func isInlineVerb(_ action: RenderedEdit.Action) -> Bool {
        guard case .format(let verb) = action else { return false }
        return [.bold, .italic, .strikethrough, .inlineCode].contains(verb)
    }

    private static func isLineVerb(_ action: RenderedEdit.Action) -> Bool {
        guard case .format(let verb) = action else { return false }
        switch verb {
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote: return true
        default: return false
        }
    }

    /// Spaces alone, typed with nothing selected: the edits that can render as nothing. (After a
    /// held line break they come as a ``RenderedEdit/Action/lineBreak``, which is held in its own
    /// right.)
    private static func isBlank(_ edit: RenderedEdit) -> Bool {
        edit.action == .typing && edit.range.length == 0 && !edit.text.isEmpty && edit.text.allSatisfy { $0 == " " }
    }

    private func hold(_ text: String, at offset: Int) -> Result {
        // Never beside an opened paragraph (``overlay``) — and none is open here: every edit but
        // one into it closes it first, and none into it is held.
        closePhantom()
        // At a paragraph's start — a line break held in an empty list item — the paragraph's own
        // first character: the storage gives a whole paragraph its first character's style, and
        // the break before belongs to the paragraph above — a held space there took the paragraph's
        // spacing away (found 2026-10-08, by the session chains, once the splice stopped replacing
        // the whole page on the next keystroke).
        let units = display.string as NSString
        let startsParagraph = offset == 0 || Self.endsParagraph(units.character(at: offset - 1))
        let from: Int? = startsParagraph && offset < display.length ? offset : offset > 0 ? offset - 1 : nil
        var attributes = from.map { display.attributes(at: $0, effectiveRange: nil) } ?? [:]
        // The text's look, never what the character beside it IS: a box and the gap after it, an
        // image, a link's target.
        for key in [NSAttributedString.Key.attachment, .previewAttachment, .previewImageSource, .previewImageAlt,
                    .link, .toolTip, .kern] {
            attributes.removeValue(forKey: key)
        }
        held = Held(text: text, at: offset)
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
        replaced = nil
        var edits = edits
        attempted = "Replace All"
        if let overlay {
            let mapped = edits.map { edit -> RenderedEdit? in
                Self.mapped(edit.range, past: overlay).map { var e = edit; e.range = $0; return e }
            }
            dropOverlay()
            guard mapped.allSatisfy({ $0 != nil }) else { return refuse(.notSupported) }
            edits = mapped.compactMap { $0 }
        }
        attemptedAt = edits.first?.range.location ?? 0
        return resolve(.typing, all: true) { PreviewEditTranslator.translateAll(edits, in: $0) }
    }

    /// Puts ``display`` back to the projection — after an input method's composition, which sits in
    /// the display until it is committed, was cancelled or refused.
    func redisplay() {
        held = nil
        phantomOffset = nil
        context.phantomAfterBlock = nil
        redraw()
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
            if let block = application.opensParagraphAfter {
                // An emptied paragraph's line, shown open for what is typed next. The typing run goes
                // on: the character that writes it joins the deletion's ⌘Z.
                return .select(NSRange(location: openPhantom(after: block) + 1, length: 0))
            }
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
        case .refuse(let reason, let line, let unverified):
            lastRefusal = reason
            // A space at a line's end is held, not refused: no hint for it.
            if quiet, reason == .unverified { return .unchanged }
            return refuse(reason, by: "translator", line: line, unverified: unverified)
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

    /// The selection in the source, for the status line's Line and Column and for Show in Source —
    /// and for the format bar, which lights and greys by it (FMT-14): mapped as a verb would map
    /// it, so a triple-clicked paragraph or a run over several blocks is reported rather than left
    /// standing as the last caret's (``PreviewEditTranslator/reportedSelection(for:in:)``).
    ///
    /// Measured past what is in the display only: a caret after held spaces is where they will be
    /// written — the end of their line, not the next block, whose Line and Column the status line
    /// showed (review, 2026-10-09) — and one in an opened paragraph is at the end of the block above.
    func sourceSelection(for rendered: NSRange) -> NSRange? {
        var range = rendered
        if let overlay {
            let start = Self.collapsed(range.location, past: overlay)
            let end = Self.collapsed(NSMaxRange(range), past: overlay)
            range = NSRange(location: start, length: end - start)
        }
        return PreviewEditTranslator.reportedSelection(for: range, in: projection)
    }

    /// Display offset `offset` with `overlay` taken out: inside it or after it moves back by as
    /// much of it as lies before.
    private static func collapsed(_ offset: Int, past overlay: NSRange) -> Int {
        offset <= overlay.location ? offset : offset - min(overlay.length, offset - overlay.location)
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
        lastRefusedSite = nil
        // Unit for unit: `!=` on two long Strings compares them as Unicode, and their `utf8`
        // walks a storage's String a character at a time — each a sixth of a keystroke, measured.
        if !(source.textStorage.string as NSString).isEqual(to: application.source) {
            // The translator's copy and the storage disagree — a bug, and one the display must not
            // hide: show what the file holds.
            Logger.shared.info("[edit] preview wrote a source that differs from the one it verified")
            projection = kept(MarkdownProjection.project(source.textStorage.string, style: style, after: projection))
        } else {
            projection = kept(application.projection)
        }
        redraw()
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
        projection = kept(MarkdownProjection.project(source.textStorage.string, style: style, after: projection))
        redraw()
    }

    /// `next`, about to be what is on screen: where it was re-read whole, with the lists of the
    /// projection on screen kept in it (``MarkdownProjection/keepingLists(of:)``) — here, once, for
    /// the projection that is kept, never for each one the translator only checks (round 2).
    private func kept(_ next: MarkdownProjection) -> MarkdownProjection {
        guard case .whole = next.reuse, next.style == projection.style else { return next }
        return next.keepingLists(of: projection)
    }

    // MARK: The phantom paragraph

    private func openPhantom(after block: Int) -> Int {
        // One overlay at a time (``overlay``). Both are gone already wherever this is reached from.
        dropOverlay()
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
    static let readOnlyTip = "Edit in Source — Preview can’t change this part"

    /// The text column's width, which a rule spans and a table must fit to be editable. The view
    /// sets it as the window resizes. **Kept in ``style``, the one place**: held beside it, a scale
    /// change rebuilt the style without it and a table no longer fitted anything (review).
    var columnWidth: CGFloat {
        get { style.columnWidth ?? Self.defaultColumn }
        set { if style.columnWidth != newValue { style.columnWidth = newValue } }
    }
    static let defaultColumn: CGFloat = 676

    /// The projection and the display brought to a new ``style``.
    ///
    /// **A new column width re-reads nothing unless a table now fits it differently** (review,
    /// 2026-10-09). Every frame of a live resize set one, and each was a whole re-read, a whole
    /// decoration and a whole comparison — and dropped a held space or an opened paragraph. Now
    /// only the rules and pictures, which span the column, are sized again. Where a table does
    /// flip, or the text size changed, the source is re-read; the text is the same either way, so
    /// what the display holds of its own — held spaces, an opened paragraph — stays where it is.
    private func restyle(columnOnly: Bool) {
        if columnOnly, let same = projection.restyled(style) {
            projection = same
        } else {
            // A new text size changes every run: decorated afresh, as at open.
            if !columnOnly { lastDecoration = nil }
            projection = MarkdownProjection.project(source.textStorage.string, style: style, after: projection)
            changeDisplay { replaced = Self.splice(overlaid(decoratedProjection()), into: display) }
        }
        redressAttachments(columnOnly: columnOnly)
    }

    /// What ``display`` holds that the projection does not — held text, or the opened paragraph — as
    /// a range of the display.
    ///
    /// **Never both** (round 2, 2026-10-10): holding text closes an opened paragraph and opening one
    /// drops held text, so there is one range, and every mapping past it — an edit's, Replace All's,
    /// the status line's — is the same one. Both were mapped in three places, each in its own order.
    var overlay: NSRange? {
        if let held { return NSRange(location: held.at, length: (held.text as NSString).length) }
        return phantomOffset.map { NSRange(location: $0, length: 1) }
    }

    /// The display back to the projection: held text dropped, an opened paragraph closed.
    private func dropOverlay() {
        dropHeld()
        closePhantom()
    }

    /// `fresh`, with what ``display`` holds of its own put back where the display has it.
    private func overlaid(_ fresh: NSAttributedString) -> NSAttributedString {
        guard let overlay, NSMaxRange(overlay) <= display.length, overlay.location <= fresh.length else { return fresh }
        let text = NSMutableAttributedString(attributedString: fresh)
        text.insert(display.attributedSubstring(from: overlay), at: overlay.location)
        return text
    }

    /// Attachments sized again — after the column or the text size changed, which the splice
    /// cannot see: attachments are compared by what they stand for, not by their size. A new
    /// column sizes only what spans it, a rule or a picture; a task's box keeps its size.
    ///
    /// **In the last decoration too**, whose kept parts are what later keystrokes copy into the
    /// display: an attachment there that the display does not share would come back at the old size.
    private func redressAttachments(columnOnly: Bool) {
        var dressed = Set<ObjectIdentifier>()
        func redress(_ text: NSAttributedString, laidOutIn storage: NSTextStorage?) {
            text.enumerateAttribute(.previewAttachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let raw = value as? String, let kind = PreviewAttachments.Kind(rawValue: raw),
                      !columnOnly || kind == .rule || kind == .image,
                      let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil)
                        as? NSTextAttachment else { return }
                if dressed.insert(ObjectIdentifier(attachment)).inserted {
                    if let image = text.attribute(.previewImageSource, at: range.location, effectiveRange: nil) as? String {
                        dressImage(attachment, source: image)
                    } else {
                        PreviewAttachments.dress(attachment, as: kind, scale: style.scale,
                                                 columnWidth: PreviewAttachments.column(columnWidth, at: range.location, in: text))
                    }
                }
                storage?.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        changeDisplay {
            display.beginEditing()
            redress(display, laidOutIn: display)
            display.endEditing()
        }
        if let decorated = lastDecoration?.decorated { redress(decorated, laidOutIn: nil) }
    }

    // MARK: Images

    /// The open document's folder, which an image's relative path is relative to.
    var documentFolder: String? {
        didSet {
            guard documentFolder != oldValue else { return }
            // A new folder can find what the old one could not — even a picture with no folder to
            // be found in, which is otherwise never looked for again: each is looked for afresh.
            for (raw, result) in images {
                if case .failure = result { failedAt[raw] = .distantPast }
            }
        }
    }
    /// Every image this session has decoded, by its source as written — or why it could not be.
    private var images: [String: Swift.Result<NSImage, ImageRefusal>] = [:]
    private var loadingImages: Set<String> = []
    /// When each picture the disk refused was looked for. Only those: a remote URL, or a path with
    /// nothing to resolve against, is refused whatever the disk holds (review, 2026-10-09).
    private var failedAt: [String: Date] = [:]
    /// How long a picture that could not be shown waits before it is looked for again.
    var imageRetry: TimeInterval = 5
    struct ImageRefusal: Error, Equatable { var reason: String }
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
                                     reason: refusal.reason)
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
        let onDisk: Bool
        if case .local = MarkdownImageSource.location(of: raw, relativeTo: folder) { onDisk = true } else { onDisk = false }
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
            let before = self.images[raw]
            self.images[raw] = result
            if case .failure = result, onDisk { self.failedAt[raw] = Date() } else { self.failedAt[raw] = nil }
            // Looked for again and refused for the same reason: what is drawn is already right.
            var same = false
            if case .failure(let now) = result, case .failure(let was)? = before { same = now == was }
            if !same { self.redrawImages(raw) }
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
            // The refusal stays drawn until the new look says otherwise: forgotten first, every
            // paragraph decorated meanwhile drew the bare "Image" label (review, 2026-10-09).
            loadImage(raw)
        }
    }

    /// Every attachment showing `raw` given what is now known of it — in the display, and in the
    /// last decoration, whose copies later keystrokes splice in.
    private func redrawImages(_ raw: String) {
        func redraw(_ text: NSAttributedString, laidOutIn storage: NSTextStorage?) {
            text.enumerateAttribute(.previewImageSource, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard value as? String == raw,
                      let attachment = text.attribute(.attachment, at: range.location, effectiveRange: nil)
                        as? NSTextAttachment else { return }
                dressImage(attachment, source: raw)
                storage?.edited(.editedAttributes, range: range, changeInLength: 0)
            }
        }
        changeDisplay {
            display.beginEditing()
            redraw(display, laidOutIn: display)
            display.endEditing()
        }
        if let decorated = lastDecoration?.decorated { redraw(decorated, laidOutIn: nil) }
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
        decorationChange = nil
        guard let last = lastDecoration, last.rendered.length > 0, rendered.length > 0 else {
            let whole = decorated(rendered)
            lastDecoration = (rendered, whole)
            return whole
        }
        let unchanged = (old: NSRange(location: 0, length: 0), new: NSRange(location: 0, length: 0))
        if last.rendered === rendered {
            decorationChange = unchanged
            return last.decorated
        }
        // Where the projection differs from the one decorated last: known to it where it was made
        // from that one, compared afresh where not.
        let difference: NSRange
        if let changed = projection.lineage.changed, projection.lineage.base === last.rendered {
            difference = changed.new
            if changed.old.length == 0, changed.new.length == 0 {
                lastDecoration = (rendered, last.decorated)
                decorationChange = unchanged
                return last.decorated
            }
        } else if let compared = PreviewAttributeShape.difference(from: last.rendered, to: rendered) {
            difference = compared.new
        } else {
            lastDecoration = (rendered, last.decorated)
            decorationChange = unchanged
            return last.decorated
        }
        // Whole paragraphs, and the one after them; then whole lists where a list's identity
        // changed — a list must not be left half one projection's `NSTextList` and half another's,
        // or TextKit numbers it as two — and again, until neither widens it. Against the last
        // DECORATION, whose lists are what the kept part holds: an earlier one's, where a list was
        // kept through a re-read that did not change how it looks.
        let units = PreviewAttributeShape.units(rendered)
        let fresh = PreviewListIdentity.wholeLists(
            around: Self.followingParagraph(after: Self.paragraphs(around: difference, in: units), in: units),
            in: rendered, against: last.decorated, widening: { Self.paragraphs(around: $0, in: units) })
        let stale = NSRange(location: fresh.location,
                            length: last.rendered.length - (rendered.length - NSMaxRange(fresh)) - fresh.location)
        let whole = NSMutableAttributedString(attributedString: last.decorated)
        whole.replaceCharacters(in: stale, with: decorated(rendered, in: fresh))
        lastDecoration = (rendered, whole)
        decorationChange = (stale, fresh)
        return whole
    }

    /// What the last ``decoratedProjection()`` replaced of the decoration before it, and with what
    /// range of its own — `nil` where it decorated the whole projection.
    private var decorationChange: (old: NSRange, new: NSRange)?

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
            text.addAttribute(.foregroundColor, value: linkColor, range: range)
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

    /// The display brought to the projection, as little of it replaced as differs.
    private func redraw() {
        // **The display IS the last decoration** — spliced from it, and changed by nothing since —
        // then it differs from the new one only where the decoration changed, and only there is
        // compared: two whole comparisons were three fifths of a keystroke at 256 KB (measured
        // 2026-10-09). Anything else the display took — a held space, an opened paragraph, marked
        // text, a picture's new size — and the whole is compared, as before; and `splice` checks
        // the lengths agree with the window whatever it is told.
        let wasDecoration = displayIsDecoration
        changeDisplay {
            let fresh = decoratedProjection()
            replaced = Self.splice(fresh, into: display, changed: wasDecoration ? decorationChange : nil)
        }
        displayIsDecoration = true
    }

    /// Whether ``display`` holds the last decoration, by what it draws — see ``redraw()``.
    private var displayIsDecoration = false

    /// How many characters the last redraw put in the display, until the `[edit]` line says so.
    private var replaced: Int?

    /// For the `[edit]` line: how the projection was made and how much of the display was laid out
    /// anew — which is what says why a keystroke was slow (review, 2026-10-09). Once per keystroke.
    private var redrawNote: String {
        defer { replaced = nil }
        guard let replaced else { return "nothing redrawn" }
        return "reuse=\(projection.reuse), redrew \(replaced) of \(display.length)"
    }

    /// Replaces only what differs between `display` and `fresh` — characters or attributes — so the
    /// view keeps its layout and scroll position (§3.7: never replace the whole storage). Says how
    /// many characters it put in their place.
    ///
    /// **Lists compare by shape, and one that changed identity is replaced whole.** A projection
    /// can make new `NSTextList`s, which are equal only to themselves, so comparing them as they are
    /// found "changed" from the note's first list on — and the view re-laid all of it (measured
    /// 2026-10-07: a third of a keystroke on a 40 KB note). But TextKit numbers a list's items by
    /// that same identity, so a list whose identity did change is swapped as a whole, never half
    /// old, half new (`PreviewListIdentity`).
    ///
    /// `changed`, where given, is where `fresh` differs from what `display` holds — `old` of the
    /// display, `new` of `fresh` — and only there are the two compared.
    @discardableResult
    static func splice(_ fresh: NSAttributedString, into display: NSTextStorage,
                       changed: (old: NSRange, new: NSRange)? = nil) -> Int {
        var difference: PreviewAttributeShape.Difference?
        var compared = false
        if let changed, NSMaxRange(changed.old) <= display.length, NSMaxRange(changed.new) <= fresh.length,
           display.length - changed.old.length == fresh.length - changed.new.length {
            let piece = fresh.attributedSubstring(from: changed.new)
            var found = PreviewAttributeShape.difference(from: display, in: changed.old, to: piece)
            // **The window sees only how its own items pair.** A list in it that is not the display's
            // very own there may pair otherwise with the rest of itself outside — and a join or a
            // split shows only so (`1)` made `1.`; Return making an empty item that ends a list):
            // then the whole is compared (found by the session chains, 2026-10-09).
            if Self.holdsTheSameLists(display, in: changed.old, as: piece,
                                      outside: found?.new ?? NSRange(location: piece.length, length: 0)) {
                found?.new.location += changed.new.location
                difference = found
                compared = true
            }
        }
        if !compared { difference = PreviewAttributeShape.difference(from: display, to: fresh) }
        guard let difference else { return 0 }
        let whole = PreviewListIdentity.wholeLists(around: difference.new, in: fresh, against: display)
        let replaced = NSRange(location: whole.location,
                               length: display.length - (fresh.length - NSMaxRange(whole)) - whole.location)
        display.beginEditing()
        display.replaceCharacters(in: replaced, with: fresh.attributedSubstring(from: whole))
        display.endEditing()
        return whole.length
    }

    /// Whether every list in `piece`, outside `differing` of it, is the very `NSTextList` `display`
    /// has at the same place in `window` — `piece` standing for `window`, `differing` for what in it
    /// changed.
    private static func holdsTheSameLists(_ display: NSAttributedString, in window: NSRange,
                                          as piece: NSAttributedString, outside differing: NSRange) -> Bool {
        let shift = window.length - piece.length
        var same = true
        for (part, offset) in [(NSRange(location: 0, length: differing.location), 0),
                               (NSRange(location: NSMaxRange(differing), length: piece.length - NSMaxRange(differing)), shift)]
            where part.length > 0 && same {
            piece.enumerateAttribute(.paragraphStyle, in: part) { value, run, stop in
                let mine = (value as? NSParagraphStyle)?.textLists ?? []
                guard !mine.isEmpty else { return }
                let theirs = (display.attribute(.paragraphStyle, at: window.location + run.location + offset,
                                                effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
                if mine.count != theirs.count || zip(mine, theirs).contains(where: { $0 !== $1 }) {
                    same = false
                    stop.pointee = true
                }
            }
        }
        return same
    }

}
