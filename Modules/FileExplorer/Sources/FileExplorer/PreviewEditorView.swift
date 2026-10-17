import SwiftUI
import AppKit
import Events

/// **The editable Preview** (TE67.3): a TextKit 2 text view drawing ``PreviewEditSession/display``,
/// with every edit sent through the session to the document's source.
///
/// Mounted instead of ``MarkdownPreview`` when Edit in Preview is on, for a writable Markdown
/// document. The read-only preview is untouched and stays what Preview is with the toggle off.
struct PreviewEditorView: NSViewRepresentable {

    let source: EditorSourceStorage
    /// The document's undo stack — the one Source uses, so ⌘Z here undoes the text and never a
    /// file operation (§3.9).
    let undoManager: UndoManager
    var fontScale: CGFloat = 1
    /// A refused edit, and where in the source it was: the status line shows "That change needs
    /// Source.", and Show in Source puts the caret there.
    var onRefusal: ((PreviewRefusal, Int) -> Void)?
    /// The selection, mapped into the source — for Line and Column, and for Show in Source.
    var onSourceSelection: ((NSRange) -> Void)?
    /// The styles ⌘B, ⌘I and friends set for what is typed next, as the verbs that set them — what
    /// the format bar lights for them (FMT-15).
    var onPendingStyles: ((Set<MarkupVerb>) -> Void)?
    /// A `#fragment` link, ⌘-clicked.
    var onFollowAnchor: ((String) -> Void)?
    /// Where the format bar finds the text it formats — this view, while it is on screen.
    var textViewHandle: EditorTextViewHandle?
    /// Split: this view is the handle's ``EditorTextViewHandle/splitPreview``, beside Source's view.
    var isSplitHalf = false
    /// The open document's folder, which an image's relative path is relative to.
    var documentFolder: String?
    /// Split: bring this source line's block to the top — the view only, never the caret (TE67.4).
    var followRequest: EditorScrollRequest?
    /// Split: the source line of the block at the top of what is on screen, as the person scrolls.
    var onVisibleLineChange: ((Int) -> Void)?
    /// Preview: go to this source line — the heading menu, the outline, a `#fragment` link: the caret
    /// there and the line at the top, as Source does (review: these were dropped outside Split).
    var scrollRequest: EditorScrollRequest?
    /// Where the caret goes when this view is BUILT — the document's remembered caret, as Source
    /// opens there: a mode switch or a reload no longer opens Preview at the top.
    var initialSourceOffset: Int?
    /// Bumped to open the find bar — the header's magnifying glass, as over Source.
    var findRequest: Int = 0
    /// Text ▸ Check Spelling While Typing, followed here as Source follows it (review V10).
    @AppStorage(EditorTextSettings.checksSpellingKey) private var checksSpelling: Bool
        = EditorTextSettings.checksSpellingDefault

    func makeCoordinator() -> Coordinator {
        Coordinator(session: PreviewEditSession(source: source, undoManager: undoManager,
                                                style: .init(scale: fontScale), documentFolder: documentFolder))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PreviewTextView.scrollableTextView()
        let view = scroll.documentView as! PreviewTextView
        (scroll as? EditorDocumentScrollView)?.documentUndoManager = undoManager
        context.coordinator.attach(view)
        context.coordinator.watchScrolling(of: scroll)
        update(context.coordinator)
        register(view)
        // Requests already standing are not news to a view built after them: replaying one would
        // jump somewhere asked for long ago (review).
        context.coordinator.lastFollowRequest = followRequest
        context.coordinator.lastScrollRequest = scrollRequest
        context.coordinator.lastFindRequest = findRequest
        if let offset = initialSourceOffset {
            // After the first layout, which is what a line's place is measured against.
            DispatchQueue.main.async { [coordinator = context.coordinator] in coordinator.place(atSource: offset) }
        }
        return scroll
    }

    /// Its find bar is retired as it goes, as Source's is — see ``PlainTextEditor/retireFindBar(of:)``.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            if let view = scroll.documentView as? NSTextView { PlainTextEditor.retireFindBar(of: view) }
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll as? EditorDocumentScrollView)?.documentUndoManager = undoManager
        update(context.coordinator)
        context.coordinator.take(follow: followRequest, scroll: scrollRequest)
        if findRequest != context.coordinator.lastFindRequest, let view = context.coordinator.textView {
            context.coordinator.lastFindRequest = findRequest
            view.window?.makeFirstResponder(view)
            PlainTextEditor.showFindBar(in: view)
        }
        if let view = scroll.documentView as? PreviewTextView { register(view) }
    }

    /// Tells the handle where this view is — its text view, or in Split its Preview half.
    private func register(_ view: PreviewTextView) {
        guard let handle = textViewHandle else { return }
        view.coordinator?.handle = handle
        if isSplitHalf {
            if handle.splitPreview !== view { handle.splitPreview = view }
        } else if handle.textView !== view {
            handle.textView = view
        }
    }

    private func update(_ coordinator: Coordinator) {
        if let view = coordinator.textView, view.isContinuousSpellCheckingEnabled != checksSpelling {
            view.isContinuousSpellCheckingEnabled = checksSpelling
        }
        coordinator.session.undoManager = undoManager
        coordinator.session.documentFolder = documentFolder
        if coordinator.session.style.scale != fontScale {
            // The column stays as it was: only the text size moved.
            coordinator.session.style = .init(scale: fontScale, columnWidth: coordinator.session.style.columnWidth)
            coordinator.fragments.scale = fontScale
            if let manager = coordinator.textView?.textLayoutManager {
                manager.invalidateLayout(for: manager.documentRange)
            }
        }
        coordinator.onRefusal = onRefusal
        coordinator.onSourceSelection = onSourceSelection
        coordinator.onPendingStyles = onPendingStyles
        coordinator.onFollowAnchor = onFollowAnchor
        coordinator.onVisibleLineChange = onVisibleLineChange
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: PreviewEditSession
        weak var textView: PreviewTextView?
        var onRefusal: ((PreviewRefusal, Int) -> Void)?
        var onSourceSelection: ((NSRange) -> Void)?
        var onPendingStyles: ((Set<MarkupVerb>) -> Void)?
        /// What ``onPendingStyles`` was last told, so an unchanged set is not said again.
        private var reportedPending: PreviewPendingStyle = []
        var onFollowAnchor: ((String) -> Void)?
        /// Set while this coordinator moves the selection itself, so the move is not taken for the
        /// person's.
        private var isSelecting = false
        /// Held here: a layout manager's delegate is weak.
        let fragments = PreviewFragmentDelegate()
        var onVisibleLineChange: ((Int) -> Void)?
        var lastFollowRequest: EditorScrollRequest?
        var lastScrollRequest: EditorScrollRequest?
        var lastFindRequest = 0
        /// The handle this view registered with — the bar's, so a test can ask it what it targets.
        weak var handle: EditorTextViewHandle?

        /// **The workspace's follow and go-to requests, acted on a turn later** (review V6,
        /// 2026-10-09). Handed over in `updateNSView`, and each reports back into the workspace's
        /// state — `navigate` the caret it placed, a follow's scroll the line now on top — and a
        /// write to SwiftUI state from inside a view update is the one SwiftUI warns is undefined.
        /// Marked taken now, so the next pass does not hand the same request over again.
        func take(follow: EditorScrollRequest?, scroll: EditorScrollRequest?) {
            if let follow, follow != lastFollowRequest {
                lastFollowRequest = follow
                DispatchQueue.main.async { [weak self] in self?.follow(line: follow.line) }
            }
            if let scroll, scroll != lastScrollRequest {
                lastScrollRequest = scroll
                DispatchQueue.main.async { [weak self] in self?.navigate(toLine: scroll.line) }
            }
        }

        /// The caret at source `offset`'s place, scrolled to — the view only just built.
        func place(atSource offset: Int) {
            guard let view = textView else { return }
            let rendered = PreviewEditRules.renderedOffset(forSource: offset, in: session.projection)
            isSelecting = true
            view.setSelectedRange(NSRange(location: min(rendered, session.display.length), length: 0))
            isSelecting = false
            isScrollingItself = true
            PreviewTextView.scrollLineToTop(view, at: min(rendered, session.display.length))
            isScrollingItself = false
        }

        /// The heading menu, the outline, a `#fragment` link: the caret at the start of the block
        /// for source `line`, that block at the top, and the keyboard here.
        func navigate(toLine line: Int) {
            guard let view = textView else { return }
            let blocks = session.projection.blocks
            guard let block = blocks.last(where: { ($0.line ?? .max) <= line }) ?? blocks.first else { return }
            let at = min(block.rendered.location, session.display.length)
            session.selectionMoved(to: NSRange(location: at, length: 0))
            isSelecting = true
            view.setSelectedRange(NSRange(location: at, length: 0))
            isSelecting = false
            isScrollingItself = true
            PreviewTextView.scrollLineToTop(view, at: at)
            isScrollingItself = false
            view.window?.makeFirstResponder(view)
            reportSelection()
        }
        private var lastVisibleLine: Int?
        nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

        deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

        /// Reports the top block's line as the view scrolls — computed only when somebody follows.
        func watchScrolling(of scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A scroll this coordinator made — following a caret it placed — is not the
                    // person scrolling, and must not lead the other pane.
                    guard let self, !self.isScrollingItself, let report = self.onVisibleLineChange,
                          let line = self.topVisibleLine(), line != self.lastVisibleLine else { return }
                    self.lastVisibleLine = line
                    report(line)
                }
            }
        }

        /// The source line of the block at the top of the visible text. `characterIndexForInsertion`,
        /// never the layout manager (TextKit 2 stays TextKit 2).
        func topVisibleLine() -> Int? {
            guard let view = textView else { return nil }
            let top = NSPoint(x: view.textContainerInset.width + 1,
                              y: view.visibleRect.minY + view.textContainerInset.height + 1)
            let index = view.characterIndexForInsertion(at: top)
            let blocks = session.projection.blocks
            let block = blocks.last { $0.rendered.location <= index && $0.line != nil } ?? blocks.first
            return block?.line
        }

        /// Brings the block for source `line` — the last one starting at or above it — to the top.
        func follow(line: Int) {
            guard let view = textView else { return }
            let blocks = session.projection.blocks
            guard let block = blocks.last(where: { ($0.line ?? .max) <= line }) ?? blocks.first else { return }
            lastVisibleLine = block.line
            PreviewTextView.scrollLineToTop(view, at: min(block.rendered.location, session.display.length))
        }

        init(session: PreviewEditSession) {
            self.session = session
            super.init()
            session.onRefusal = { [weak self] reason, offset in self?.onRefusal?(reason, offset) }
            session.onSourceChange = { [weak self] offset in
                // An undo or redo made here puts the caret where it landed. A change made in Source
                // (Split) leaves this pane alone: moving its caret and scrolling to it there would
                // scroll Source after it, and overwrite the caret Source reports (review).
                guard let self, let view = self.textView, view.window?.firstResponder === view else { return }
                self.select(NSRange(location: min(offset, self.session.display.length), length: 0))
            }
        }

        func attach(_ view: PreviewTextView) {
            textView = view
            view.coordinator = self
            view.delegate = self
            fragments.scale = session.style.scale
            view.textLayoutManager?.delegate = fragments
            if let content = view.textContentStorage, content.textStorage !== session.display {
                content.textStorage = session.display
            }
        }

        /// A picture or a file, pasted or dropped: not something Preview can write (V5). Said — the
        /// hint, and a line in the log naming the door, never the files.
        func refuseImport(_ door: String) {
            Logger.shared.info("[preview-edit] Refused \(door): images and files go in through Source")
            let caret = textView?.selectedRange().location ?? 0
            onRefusal?(.notSupported, session.sourceOffset(near: min(caret, session.display.length)))
        }

        /// **A Markup verb over the selection** — the menu, a chord and the bar all land here. A
        /// refusal is logged once, at INFO, by the session, naming the verb as the menu does (review
        /// V9, 2026-10-09; round 2: this wrote a second line for the same refusal).
        func performMarkup(_ verb: MarkupVerb) {
            guard let view = textView else { return }
            perform(RenderedEdit(range: view.selectedRange(), action: .format(verb)))
        }

        /// Sends `edit` through the session and puts the selection where it says.
        func perform(_ edit: RenderedEdit) {
            apply(session.perform(edit))
        }

        func apply(_ result: PreviewEditSession.Result) {
            if case .select(let range) = result { select(range) }
            reportPending()
        }

        /// **Tells the format bar which styles wait for the next character** (FMT-15). ⌘B with
        /// nothing selected writes nothing in Preview — it sets Bold for what is typed next — and
        /// the bar never showed it: Bold stayed dark, and a second press to check turned it off
        /// unseen. Reported whenever it may have changed, and only when it did.
        func reportPending() {
            let pending = session.context.pending
            guard pending != reportedPending else { return }
            reportedPending = pending
            onPendingStyles?(Self.verbs(for: pending))
        }

        /// The verbs that set `pending`.
        static func verbs(for pending: PreviewPendingStyle) -> Set<MarkupVerb> {
            var verbs: Set<MarkupVerb> = []
            if pending.contains(.bold) { verbs.insert(.bold) }
            if pending.contains(.italic) { verbs.insert(.italic) }
            if pending.contains(.strikethrough) { verbs.insert(.strikethrough) }
            if pending.contains(.code) { verbs.insert(.inlineCode) }
            return verbs
        }

        func select(_ range: NSRange) {
            guard let view = textView else { return }
            isSelecting = true
            view.setSelectedRange(NSRange(location: min(range.location, session.display.length),
                                          length: min(range.length, max(0, session.display.length - range.location))))
            isScrollingItself = true
            view.scrollRangeToVisible(view.selectedRange())
            isScrollingItself = false
            isSelecting = false
            reportSelection()
        }

        fileprivate var isScrollingItself = false

        private func reportSelection() {
            guard let view = textView, view.window?.firstResponder === view,
                  let mapped = session.sourceSelection(for: view.selectedRange()) else { return }
            onSourceSelection?(mapped)
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? { session.undoManager }

        /// Every change the text view would make to its own storage — typing, deleting, a paste, a
        /// spelling correction, Replace — is made in the source instead, and refused here.
        func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue],
                      replacementStrings strings: [String]?) -> Bool {
            guard let view = textView as? PreviewTextView else { return false }
            // An input method's composition lives in the display until it is committed (A12).
            if view.isComposing { return true }
            // **`nil` strings are a style change, not a deletion** — Underline, an alignment, the
            // writing direction, the Font and Colors panels, a colour swatch dropped on the text:
            // "keep these characters, change how they look". Read as empty strings it deleted the
            // whole selection, which in a one-paragraph note was the note (review V1, 2026-10-09).
            // The display is a rendering of the Markdown, which has no fonts or colours to change.
            guard let strings else {
                // Once per run at INFO — the Colors panel dragged across the text sends one per
                // step — and again after something is typed (round 2, 2026-10-10).
                let message = "[preview-edit] A style change from AppKit was ignored over \(ranges.count) range(s): Preview's text is the Markdown's rendering"
                if loggedStyleChange { Logger.shared.debug(message) } else { Logger.shared.info(message) }
                loggedStyleChange = true
                return false
            }
            loggedStyleChange = false
            let edits = zip(ranges, strings).map { range, text in
                RenderedEdit(range: range.rangeValue, text: text,
                             action: text.isEmpty ? .delete : (view.isPasting ? .paste : .typing))
            }
            apply(edits.count == 1 ? session.perform(edits[0]) : session.performAll(edits))
            return false
        }

        /// Whether a style change has been logged at INFO since the last edit.
        private var loggedStyleChange = false

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            command(selector, in: textView, shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        }

        /// Return, ⇧Return, Tab and ⇧Tab become edits; every other command is AppKit's.
        func command(_ selector: Selector, in textView: NSTextView, shift: Bool) -> Bool {
            let range = textView.selectedRange()
            let action: RenderedEdit.Action
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                action = shift ? .lineBreak : .returnKey
            case #selector(NSResponder.insertLineBreak(_:)): action = .lineBreak
            case #selector(NSResponder.insertTab(_:)): action = .tab
            case #selector(NSResponder.insertBacktab(_:)): action = .backtab
            default: return false
            }
            perform(RenderedEdit(range: range, action: action))
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Not while an input method composes: the caret moves inside the marked text, and the
            // opened paragraph or held space the composition began in must outlive it (review) —
            // its commit too, which takes the marks away before it moves the caret.
            guard !isSelecting, let view = textView, !view.hasMarkedText(), !view.isComposing else { return }
            session.selectionMoved(to: view.selectedRange())
            reportSelection()
            reportPending()
        }

        /// **The text's right-click menu, as Source's**: AppKit's own items, with the Markup verbs and
        /// the Format Bar switch on top — what Help says right-clicking the text offers (review:
        /// Preview had AppKit's menu alone).
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let selection = session.sourceSelection(for: view.selectedRange()) ?? NSRange(location: 0, length: 0)
            let tables = MarkdownTables.reading(session.source.text as NSString, selection)
            let markup = PlainTextEditor.Coordinator.markupMenu(
                target: self, action: #selector(applyMarkupItem(_:)),
                tables: tables.available, inTable: tables.touches,
                crossesCells: MarkdownEdits.crossesCells(session.source.text as NSString, selection,
                                                         touches: tables.touches),
                abutsTable: tables.abuts)
            let host = NSMenuItem(title: "Markup", action: nil, keyEquivalent: "")
            host.submenu = markup
            let shows = UserDefaults.standard.object(forKey: EditorTextSettings.showsFormatBarKey) as? Bool
                ?? EditorTextSettings.showsFormatBarDefault
            let bar = NSMenuItem(title: PlainTextEditor.Coordinator.formatBarTitle,
                                 action: #selector(toggleFormatBar(_:)), keyEquivalent: "")
            bar.target = self
            bar.state = shows ? .on : .off
            // Check Spelling, as Source's menu has it (review V10) — and no Wrap Lines: Preview's
            // column always wraps, so the item would do nothing here.
            let checks = UserDefaults.standard.object(forKey: EditorTextSettings.checksSpellingKey) as? Bool
                ?? EditorTextSettings.checksSpellingDefault
            let spelling = NSMenuItem(title: Self.checkSpellingTitle,
                                      action: #selector(toggleSpellChecking(_:)), keyEquivalent: "")
            spelling.target = self
            spelling.state = checks ? .on : .off
            menu.insertItem(host, at: 0)
            menu.insertItem(.separator(), at: 1)
            menu.insertItem(spelling, at: 2)
            menu.insertItem(bar, at: 3)
            menu.insertItem(.separator(), at: 4)
            return menu
        }

        @objc func applyMarkupItem(_ sender: NSMenuItem) {
            guard MarkupVerb.menuOrder.indices.contains(sender.tag),
                  let verb = MarkupVerb.menuOrder[sender.tag] else { return }
            textView?.performMarkup(verb)
        }

        /// Source's item's title, so the two read as one switch.
        static let checkSpellingTitle = "Check Spelling While Typing"

        /// Written to the defaults, which every editor follows — Source's halves and this one.
        @objc func toggleSpellChecking(_ sender: NSMenuItem) {
            let defaults = UserDefaults.standard
            let checks = !(defaults.object(forKey: EditorTextSettings.checksSpellingKey) as? Bool
                ?? EditorTextSettings.checksSpellingDefault)
            defaults.set(checks, forKey: EditorTextSettings.checksSpellingKey)
        }

        @objc func toggleFormatBar(_ sender: NSMenuItem) {
            let defaults = UserDefaults.standard
            let shows = !(defaults.object(forKey: EditorTextSettings.showsFormatBarKey) as? Bool
                ?? EditorTextSettings.showsFormatBarDefault)
            defaults.set(shows, forKey: EditorTextSettings.showsFormatBarKey)
            Logger.shared.info("[edit] Format bar \(shows ? "shown" : "hidden") from Preview's right-click menu")
        }

        /// **A plain click on a link places the caret, as in every editor; ⌘-click opens it** (§1.2).
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            clickedOnLink(link, at: charIndex,
                          command: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return true
        }

        func clickedOnLink(_ link: Any, at charIndex: Int, command: Bool) {
            guard command else {
                select(NSRange(location: charIndex, length: 0))
                return
            }
            open(link)
        }

        func open(_ link: Any) {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return }
            if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
                onFollowAnchor?(fragment)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// The editable Preview's text view: the delegate's AppKit, plus what no delegate method reaches — an
/// input method's composition, a paste, and a click on a task box.
final class PreviewTextView: NSTextView {

    weak var coordinator: PreviewEditorView.Coordinator?

    /// True while an input method's marked text is in the display, uncommitted.
    private(set) var isComposing = false
    /// The rendered range the composition replaces — the selection when it began.
    private var compositionRange = NSRange(location: 0, length: 0)
    private(set) var isPasting = false

    /// **Where the line holding `offset` starts, in `view`'s coordinates** — laid out first, and
    /// asked of TextKit 2's own fragment. TextKit 2 lays out lazily, and `firstRect` for a place far
    /// below the screen answered a zero rectangle (measured: following line 81 of a long note
    /// landed on line 37). Never `layoutManager`, which would drop the view to TextKit 1.
    static func lineTop(in view: NSTextView, at offset: Int) -> CGFloat? {
        guard let manager = view.textLayoutManager, let content = view.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let range = NSTextRange(location: content.documentRange.location, end: location) else { return nil }
        manager.ensureLayout(for: range)
        guard let fragment = manager.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
    }

    /// Scrolls `view` so the line holding `offset` is the first on screen, below the text's inset.
    ///
    /// **The frame is grown first**: until the view's next pass it is sized to TextKit 2's
    /// estimate, and a scroll past the estimate is clamped short of the line (measured: 778 for a
    /// line at 1,095).
    static func scrollLineToTop(_ view: NSTextView, at offset: Int) {
        guard let top = lineTop(in: view, at: offset) else { return }
        // Room for the line at the top of a screen. TextKit 2's own measure of what is used has
        // not caught up with the layout just made (measured: still the estimate), so this asks
        // for exactly what the scroll needs; the view sizes itself to the truth on its next pass.
        let needed = top + view.visibleRect.height
        if needed > view.frame.height { view.setFrameSize(NSSize(width: view.frame.width, height: needed)) }
        view.scroll(NSPoint(x: 0, y: max(0, top - view.textContainerInset.height)))
    }

    /// The widest the text column grows (§3.8): the measure a reader's eye can hold, as the read-only
    /// preview's `maxWidth: 720`.
    static let maxColumn: CGFloat = 720
    static let inset = NSSize(width: 22, height: 18)

    override class func scrollableTextView() -> NSScrollView {
        // The document's stack for ⌘Z from Preview's find bar, as Source's (UND-3).
        let scroll = EditorDocumentScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = PreviewTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.importsGraphics = false
        // No Font panel, as Source has none: its changes are styles Markdown cannot write (V1).
        view.usesFontPanel = false
        view.isGrammarCheckingEnabled = false
        view.allowsUndo = false
        view.isEditable = true
        view.isSelectable = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = inset
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityLabel("Preview")
        // Find works here as in Source: Replace goes through the same translation as typing.
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        // The document's surface, as Source's scroll view is: the Markup menu, ⌘F and Find Next
        // find this text view by this mark when the caret is in it (`EditorDocumentSurface`).
        scroll.identifier = EditorDocumentSurface.identifier
        scroll.documentView = view
        return scroll
    }

    /// **The document's undo stack, with `allowsUndo` off.** An `NSTextView` that does not allow
    /// undo vends none (measured: `nil`), and ⌘Z would fall through to the window's — the file
    /// operations'. Allowing it would register the view's own edits to the display — marked text,
    /// a commit — against a storage that is only a rendering. So: vend the document's, register none.
    /// **And none at all while an input method's text goes into the display**: `NSTextView`
    /// registers "Typing" for marked text even with `allowsUndo` off, once it can find a manager
    /// (measured 2026-10-05) — against the display, where an undo would edit a rendering.
    override var undoManager: UndoManager? { isComposing ? nil : coordinator?.session.undoManager }

    /// **⌘Z here is answered here, on the document's stack** — not left to the window, which
    /// answers `undo:` for a text view and, for one with `allowsUndo` off, undoes its OWN stack
    /// whatever ``undoManager`` says: measured 2026-10-16, a keystroke here and ⌘Z undid a stand-in
    /// file operation and left the keystroke (UND-1). Answered here, it is the stack this view vends.
    ///
    /// **While a word is being composed, ⌘Z commits it and takes nothing back** (UND-8). Preview
    /// registers nothing for marked text, so ⌘Z went past the composition to the document's last
    /// step, and the redraw that followed threw the half-composed word away — measured: "Hello
    /// world" with か being composed, ⌘Z, and the file read "Hello". The word is kept, committed
    /// into the source as the input method's own commit would be; the next ⌘Z takes it back with
    /// the typing it joined.
    @objc func undo(_ sender: Any?) {
        if hasMarkedText() {
            unmarkText()
            return
        }
        undoManager?.undo()
    }

    /// ⇧⌘Z, the same way — a composition is committed, and nothing is redone.
    @objc func redo(_ sender: Any?) {
        if hasMarkedText() {
            unmarkText()
            return
        }
        undoManager?.redo()
    }

    /// Edit ▸ Undo and Redo, titled and enabled from the document's stack — and enabled while a word
    /// is composed, which they commit.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        EditorUndoCommands.validate(item, on: undoManager, alsoWhen: hasMarkedText())
            ?? super.validateUserInterfaceItem(item)
    }

    /// Takes the keyboard when nobody else holds it, as Source's view does (UND-1) — see
    /// ``EditorUndoAnchor``.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        EditorUndoAnchorView.textViewArrived(in: window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let column = max(40, min(newSize.width, Self.maxColumn) - 2 * Self.inset.width)
        if textContainer?.size.width != column {
            textContainer?.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
            coordinator?.session.columnWidth = column
        }
    }

    // MARK: Input methods (A12)

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { compositionRange = self.selectedRange() }
        isComposing = true
        defer { isComposing = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard hasMarkedText() else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        // The commit: let AppKit end the composition in the display, then make it in the source.
        let committed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        isComposing = true
        super.insertText(string, replacementRange: replacementRange)
        isComposing = false
        guard let coordinator else { return }
        // Cancelled (Escape): nothing was typed and nothing replaced — just take the marks away.
        guard !committed.isEmpty || compositionRange.length > 0 else {
            coordinator.session.redisplay()
            return
        }
        let result = coordinator.session.perform(RenderedEdit(
            range: compositionRange, text: committed, action: committed.isEmpty ? .delete : .typing))
        if result == .unchanged { coordinator.session.redisplay() }
        coordinator.apply(result)
    }

    /// AppKit's `unmarkText` ACCEPTS the marked text as it stands — a commit like any other.
    override func unmarkText() {
        guard hasMarkedText(), let storage = textStorage else {
            super.unmarkText()
            return
        }
        let marked = markedRange()
        insertText(storage.attributedSubstring(from: marked).string, replacementRange: marked)
    }

    // MARK: Paste — plain text only (A9, A10)

    override func paste(_ sender: Any?) {
        paste(from: .general, sender: sender)
    }

    /// The paste, from `pasteboard` — its own method so a test can hand it a private one rather than
    /// the person's clipboard. Plain text only, from the general pasteboard as AppKit reads it.
    func paste(from pasteboard: NSPasteboard, sender: Any? = nil) {
        if Self.carriesFilesOrPicture(pasteboard, text: pasteboard.string(forType: .string)) {
            coordinator?.refuseImport("a paste of a picture or a file")
            return
        }
        isPasting = true
        defer { isPasting = false }
        if pasteboard === NSPasteboard.general {
            pasteAsPlainText(sender)
        } else if pasteboard.availableType(from: [.string]) != nil {
            _ = readSelection(from: pasteboard, type: .string)
        }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isPasting = true
        defer { isPasting = false }
        return super.readSelection(from: pboard, type: type)
    }

    // MARK: Pictures and files (review V5)

    /// **Files, or a picture with no text — which Preview cannot take** (review V5, 2026-10-09).
    /// Source imports a picture into the note's Images folder and links it (TE56); Preview has no
    /// such import, and AppKit's own handling typed a dropped file's PATH into the paragraph, and a
    /// copied file's NAME, as text that reached the Markdown. A screenshot found nothing to paste,
    /// and said nothing. Each is refused with the hint now. The full fix is Source's import, its
    /// link written as a block after the caret's — a translation Preview does not have yet.
    static func carriesFilesOrPicture(_ pasteboard: NSPasteboard, text: String?) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return text == nil && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // A drag that started in this view is its own text being moved; any other with files on it
        // is refused rather than typed in as their paths.
        if (sender.draggingSource as AnyObject?) !== self,
           Self.carriesFilesOrPicture(sender.draggingPasteboard, text: sender.draggingPasteboard.string(forType: .string)) {
            coordinator?.refuseImport("a drop of a picture or a file")
            return false
        }
        return super.performDragOperation(sender)
    }

    // MARK: Markup (A3, A4)

    /// A Markup verb — from the menu, a chord or the format bar — over this view's selection, made
    /// in the source like every other edit here. Never `PlainTextEditor.apply`, which would write
    /// into the display.
    func performMarkup(_ verb: MarkupVerb) {
        coordinator?.performMarkup(verb)
    }

    // MARK: Read-only text (§1.2)

    /// The arrow over text Preview cannot edit — front matter, HTML, a table too wide — so it does
    /// not look typeable until a keystroke is refused. Its tooltip says where to edit it.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let storage = textStorage, storage.length > 0 else { return }
        let index = min(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)), storage.length - 1)
        if storage.attribute(.previewReadOnly, at: index, effectiveRange: nil) != nil { NSCursor.arrow.set() }
    }

    // MARK: Task boxes (A8)

    override func mouseDown(with event: NSEvent) {
        if let box = taskBox(at: convert(event.locationInWindow, from: nil)) {
            // The first click only: a double-click's second arrives as a mouse-down of its own, and
            // ticked the box back (review V11, 2026-10-09). Swallowed, so it selects no word either.
            if event.clickCount == 1 {
                coordinator?.perform(RenderedEdit(range: NSRange(location: box, length: 1), action: .tickTask))
            }
            return
        }
        super.mouseDown(with: event)
    }

    /// The task box under `point`, as a character index, or `nil`.
    func taskBox(at point: NSPoint) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            let kind = storage.attribute(.previewAttachment, at: candidate, effectiveRange: nil) as? String
            guard kind == PreviewAttachments.Kind.task.rawValue || kind == PreviewAttachments.Kind.taskDone.rawValue,
                  let window else { continue }
            let onScreen = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            let inWindow = window.convertFromScreen(onScreen)
            if convert(inWindow, from: nil).insetBy(dx: -2, dy: -2).contains(point) { return candidate }
        }
        return nil
    }
}
