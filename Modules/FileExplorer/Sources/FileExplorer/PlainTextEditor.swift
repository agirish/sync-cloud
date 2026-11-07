import SwiftUI
import AppKit
import Design
import Events

/// The writable text surface: an `NSTextView` in a scroll view, kept plain on purpose.
///
/// AppKit, not `TextEditor`: SwiftUI's editor gives no access to the undo manager, no way to switch
/// smart substitutions off, and no first responder for the standard editing chords (see
/// ``Coordinator/undoManager(for:)`` for the one that matters most). ⌘X / ⌘C / ⌘V / ⌘A need no
/// registration: `TextEditingChord` routes them to any first responder that `is NSTextView`.
struct PlainTextEditor: NSViewRepresentable {

    /// The open document's text storage, which this view is built around rather than owning (see
    /// ``EditorSourceStorage``).
    ///
    /// Edit and Split mount this view from two `switch` arms, so a mode switch builds a new view,
    /// and an `NSTextView` registers undo against its own storage. With a storage per view, ⌘Z after
    /// a switch would revert text nobody can see; this one outlives the view, so every view of a
    /// document edits the same storage and the buffer follows it.
    var source: EditorSourceStorage
    /// Read-only documents are shown, not hidden: a lossy decode is still worth reading.
    var isEditable: Bool
    /// Settings ▸ Text size, so the monospace ramp scales with the rest of the app.
    var fontScale: CGFloat

    /// Which document these keystrokes belong to: the open file's path, or nil when none is. A path,
    /// not the text, since two files can hold identical bytes (the case `EditorParseKey` exists
    /// for). The coordinator reads it to decide whether the Markup verbs apply.
    var documentID: String?

    /// The editor's own undo stack, owned by the window rather than this view.
    ///
    /// Separate because an `NSTextView` with `allowsUndo` vends its manager to the responder chain,
    /// and the window's manager is bound to `FileSyncManager`: the banner's Undo button reads it,
    /// and the engine matches file operations by `undoActionName`. Shadowing each other, ⌘Z in the
    /// editor and the banner's Undo would act on two different stacks.
    ///
    /// Passed in, not held by the coordinator, because `surfaces(for:)` mounts this view from two
    /// `switch` arms, so a coordinator's own stack would end the history at every Source ↔ Split
    /// switch. ``source`` keeps the storage the stack's actions name.
    var undoManager: UndoManager

    /// Called whenever the selection moves, with its UTF-16 range in the buffer.
    ///
    /// The status line's line and column, and the outline's current heading, both start here.
    var onSelectionChange: (NSRange) -> Void = { _ in }
    /// How many ranges are selected (more than one after an ⌥-drag or a ⌘-drag), reported just
    /// before ``onSelectionChange`` hands over the first. The status line counts only a single
    /// selection, so it needs to know when there are more.
    var onSelectionRangeCount: (Int) -> Void = { _ in }

    /// Where to put the caret next, or `nil` for "leave it alone".
    ///
    /// A request carrying a token, not a line number, for the reason `namingFocus` is a counter:
    /// clicking the same outline row twice is two requests, and a plain `Int?` would not change, so
    /// the second click (made after scrolling away) would do nothing.
    var scrollRequest: EditorScrollRequest?

    /// Where to put the caret when this text view is created: a UTF-16 offset, 0 for the top.
    ///
    /// Always applied, never optional: left alone, AppKit puts the caret at the end of the assigned
    /// text (see `restoreCaret`), invisibly, and the status line would disagree. A caller with
    /// nothing remembered passes 0; ``EditorCaretAnchors/offset(for:)`` answers nil for an unread
    /// file, and the host decides that means the top.
    ///
    /// Read by `makeNSView` alone: a workspace switch rebuilds the representable, which is when the
    /// reader comes back; read in `updateNSView` too, it would fight every click and arrow key. It
    /// loses to a ``scrollRequest`` in the same pass, which `updateNSView` applies after it. The
    /// caller clamps against the text, this against the storage (see
    /// ``EditorCaretAnchors/clamped(_:in:)`` for why the store can't).
    var initialSelection: Int = 0

    /// Called when the topmost visible line changes, which is what the split's preview follows.
    ///
    /// Fired from the clip view's bounds notification rather than polled: the text view scrolls for
    /// reasons SwiftUI never hears about (a scroll wheel, a trackpad flick, a drag past the bottom).
    ///
    /// `nil` when nobody is listening, which is the gate: only `.split` follows the text, and in the
    /// other modes the line is then never computed on a scroll tick.
    var onVisibleLineChange: ((Int) -> Void)?

    /// Where every line begins, for the two questions that would otherwise walk the buffer.
    ///
    /// Rebuilt off the main actor on the status line's debounce, so it can lag a burst of typing
    /// (see ``EditorLineIndex``). The scroll sync accepts that; the caret checks the length first.
    var lineIndex: EditorLineIndex = .empty

    /// Bumped to open the find bar. A counter for the reason ``scrollRequest`` carries a token:
    /// asking twice is two requests, and the second comes after the bar was closed.
    var findRequest: Int = 0

    /// Whether the markup verbs are offered on the context menu. `false` on a document that can't
    /// be saved (see ``EditorDocument/readOnlyReason``).
    var offersMarkup: Bool = true

    /// Whether the open file is Markdown, which turns on the edits in
    /// `PlainTextEditor+MarkdownTyping`: lists carried on and moved, a web address pasted onto
    /// words, an image dropped or pasted. Each also checks the view is editable.
    var editsMarkdown: Bool = false

    /// Where a dropped or pasted image goes, or `nil` when images are not taken here (see
    /// ``EditorImageImporter``).
    var imageImport: EditorImageImporter?

    /// Split, with Preview editable: bring this line to the top as the person scrolls Preview, the
    /// view only. Not ``scrollRequest``, which moves the caret and takes focus: following must do
    /// neither, or scrolling Preview would pull the caret out of it.
    var followRequest: EditorScrollRequest? = nil

    /// Where this view leaves a weak reference to its text view, for the format bar above it (see
    /// ``EditorTextViewHandle``). `nil` where nothing beside the text acts on it.
    var textViewHandle: EditorTextViewHandle?

    /// Room under the last line for what floats over the text's foot: the disk banner. The scroll
    /// view's content inset, so the text runs under the banner, its last lines scroll clear of it,
    /// and nothing moves when it comes or goes.
    var bottomInset: CGFloat = 0

    // Read here rather than threaded in, the way `EditorWorkspaceView` reads the window's glass
    // settings: these are preferences, not state a caller owns. See `EditorTextSettings`.
    @AppStorage(EditorTextSettings.wrapsKey) private var wrapsLines: Bool
        = EditorTextSettings.wrapsDefault
    @AppStorage(EditorTextSettings.readableLineLengthKey) private var readableLineLength: Bool
        = EditorTextSettings.readableLineLengthDefault
    @AppStorage(EditorTextSettings.typewriterScrollingKey) private var typewriterScrolling: Bool
        = EditorTextSettings.typewriterScrollingDefault
    @AppStorage(EditorTextSettings.checksSpellingKey) private var checksSpelling: Bool
        = EditorTextSettings.checksSpellingDefault
    @AppStorage(EditorTextSettings.drawsPageKey) private var drawsPage: Bool
        = EditorTextSettings.drawsPageDefault
    @AppStorage(EditorTextSettings.continuesListsKey) private var continuesLists: Bool
        = EditorTextSettings.continuesListsDefault

    /// The editor's base size before the app's text scale is applied. 13 is the platform's own
    /// monospace reading size and matches the keycaps elsewhere in the app.
    static let baseFontSize: CGFloat = 13

    /// Through `FontSize.scaledPointSize`, not a bare multiply: every other string in the app takes
    /// that curve, which damps growth above an 11pt knee. The two agree below 1.0, but at Larger a
    /// multiply would draw the text noticeably bigger than the editor's own header and rail.
    static func font(scale: CGFloat) -> NSFont {
        .checkedMonospacedSystemFont(ofSize: FontSize.scaledPointSize(baseFontSize, scale: scale),
                                     weight: .regular)
    }

    // `@MainActor` because it holds an `UndoManager`, whose initialiser is main-actor isolated, and
    // every delegate callback below arrives on the main thread anyway.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSMenuItemValidation {
        /// The storage the text view shows, re-assigned every pass like ``onSelectionChange``.
        var source: EditorSourceStorage
        /// The window's editor stack, handed over so text edits never reach the engine's.
        var undoManager: UndoManager
        /// The document the stack currently holds edits for.
        var documentID: String?
        /// Re-assigned on every update pass, like ``source``: a closure captured once at
        /// construction would go on writing into the view that built it after a re-render.
        var onSelectionChange: (NSRange) -> Void
        /// Re-assigned every pass, like ``onSelectionChange``.
        var onSelectionRangeCount: (Int) -> Void = { _ in }
        /// `nil` in every mode but `.split` (see ``PlainTextEditor/onVisibleLineChange``).
        var onVisibleLineChange: ((Int) -> Void)?
        /// The last request acted on, so the same one is not replayed on every render pass.
        var lastScrollRequest: EditorScrollRequest?
        var lastFollowRequest: EditorScrollRequest?
        /// The last find request acted on, seeded with the request standing when this view was
        /// built, so a text view answers only presses made while it is on screen (see
        /// ``PlainTextEditor/makeCoordinator()``).
        var lastFindRequest: Int = 0
        /// The last line reported upward, so an ordinary scroll does not publish the same number
        /// sixty times a second.
        var lastVisibleLine: Int?
        /// Where every line begins, so the bounds observer, which fires outside a render pass, can
        /// do line maths without reaching back into SwiftUI or walking the buffer.
        var lineIndex: EditorLineIndex = .empty
        /// The view these callbacks belong to. Weak: the coordinator outlives a torn-down view, and
        /// a strong reference here would be a retain cycle through the delegate.
        weak var textView: NSTextView?
        /// Re-assigned every pass, like ``offersMarkup`` (see ``PlainTextEditor/editsMarkdown``).
        var editsMarkdown = false
        /// Text ▸ Continue Lists. While off, Return, Tab and ⇧Tab do what they normally do.
        var continuesLists = EditorTextSettings.continuesListsDefault
        /// See ``PlainTextEditor/imageImport``.
        var imageImport: EditorImageImporter?
        /// Where the right-click menu's switches are read and written. Always `.standard` in the
        /// app; a test hands in a scratch suite, because under `swift test` the standard domain
        /// belongs to `swiftpm-testing-helper` and is shared by every test process on the machine.
        var defaults: UserDefaults = .standard
        private var boundsObserver: (any NSObjectProtocol)?

        init(source: EditorSourceStorage, undoManager: UndoManager, documentID: String?,
             onSelectionChange: @escaping (NSRange) -> Void) {
            self.source = source
            self.undoManager = undoManager
            self.documentID = documentID
            self.onSelectionChange = onSelectionChange
        }

        /// Drops the bounds observer.
        ///
        /// Called from `dismantleNSView`, not `deinit`: a block-based observer must be removed by
        /// hand, and a nonisolated `deinit` may not touch a main-actor stored property.
        func stopWatchingScrolling() {
            boundsObserver.map(NotificationCenter.default.removeObserver)
            boundsObserver = nil
        }

        /// Starts reporting the topmost visible line.
        ///
        /// `postsBoundsChangedNotifications` has to be turned on: a clip view doesn't post by
        /// default, and without it the observer silently never fires and the split never syncs.
        func watchScrolling(of scroll: NSScrollView, textView: NSTextView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated {
                    // Nothing is computed when nothing follows the text. This fires once per
                    // scrolled row, and at the end of a long file once per keystroke (typing there
                    // autoscrolls); the dedupe below comes after the work, so it saves none of it.
                    guard let report = self.onVisibleLineChange else { return }
                    guard let line = Self.topVisibleLine(of: textView, using: self.lineIndex) else {
                        return
                    }
                    guard line != self.lastVisibleLine else { return }
                    self.lastVisibleLine = line
                    report(line)
                }
            }
        }

        /// The 1-based source line at the top of what is on screen.
        ///
        /// `characterIndexForInsertion(at:)`, not the layout manager: on a TextKit 2 view, merely
        /// reading `NSTextView.layoutManager` drops it to TextKit 1 for the rest of its life. Not
        /// from the scroll offset and a line height either: soft-wrapped lines have no fixed height.
        ///
        /// The offset becomes a line by a binary search of ``EditorLineIndex``, not a grapheme walk
        /// on every scroll tick. A table that hasn't caught up with a burst of typing is accepted:
        /// the preview follows a line off for a moment, and only the caret needs exactness.
        /// ``EditorLineIndex/line(atUTF16Offset:)`` is total, so no upper bound is needed; the
        /// lower bound stays because `characterIndexForInsertion(at:)` can answer `NSNotFound`.
        static func topVisibleLine(of view: NSTextView, using index: EditorLineIndex) -> Int? {
            guard let clip = view.enclosingScrollView?.contentView else { return nil }
            // A point just inside the top-left of what is visible, in the text view's coordinates,
            // past the container inset, or the answer is the character nearest the margin above.
            let point = NSPoint(x: view.textContainerInset.width + 1,
                                y: clip.bounds.origin.y + view.textContainerInset.height + 1)
            let offset = view.characterIndexForInsertion(at: point)
            guard offset >= 0, offset != NSNotFound else { return nil }
            return index.line(atUTF16Offset: offset)
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        /// The storage publishes the buffer (see ``EditorSourceStorage``); this only catches up an
        /// edit it held back while an input method was composing. A safety net: in the factory's
        /// view the composition is already cleared by then, so this is one integer compare, but a
        /// TextKit 2 view can deliver `unmarkText`'s edit still marked, which would otherwise leave
        /// the committed word out of the document until the next keystroke. Never the only path:
        /// on TextKit 2 an `NSTextView` undo doesn't send this at all.
        func textDidChange(_ notification: Notification) {
            source.publishIfNeeded()
        }

        var offersMarkup = true

        /// The Markup section of the text view's context menu.
        ///
        /// The delegate hook, not an `NSTextView` subclass: AppKit asks the delegate before showing
        /// the menu, so the standard items (Cut, Copy, Look Up, spelling) stay AppKit's own, where a
        /// `menu(for:)` override would have to rebuild them.
        ///
        /// The key equivalents are the Markup menu's, read from `MarkupVerb.chord`. They are only a
        /// display: AppKit doesn't dispatch keys to a context menu, and the menu bar's registration
        /// answers them.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent,
                      at charIndex: Int) -> NSMenu? {
            guard offersMarkup else {
                // Read-only: no verbs, but the view switches still apply.
                insertTextSettings(into: menu, at: 0)
                return menu
            }
            let tables = MarkdownTables.reading(view.string as NSString, view.selectedRange())
            let markup = Self.markupMenu(target: self, action: #selector(applyMarkup(_:)),
                                         tables: tables.available, inTable: tables.touches,
                                         crossesCells: MarkdownEdits.crossesCells(view.string as NSString, view.selectedRange(),
                                                                                  touches: tables.touches),
                                         abutsTable: tables.abuts,
                                         enabled: isMarkdownDocument)
            let host = NSMenuItem(title: "Markup", action: nil, keyEquivalent: "")
            host.submenu = markup
            menu.insertItem(host, at: 0)
            menu.insertItem(.separator(), at: 1)
            insertTextSettings(into: menu, at: 2)
            return menu
        }

        /// The switches that change how the text is drawn rather than what it says: Wrap Lines,
        /// Readable Line Length, Check Spelling While Typing, and Format Bar where it applies.
        ///
        /// Below Markup and above the standard items: the verbs act on the selection, these on the
        /// view, and Cut/Copy/Look Up on the word under the pointer. Offered on a read-only document
        /// too, unlike the verbs, since none of them changes anything on disk.
        func insertTextSettings(into menu: NSMenu, at index: Int) {
            let wraps = defaults.object(forKey: EditorTextSettings.wrapsKey) as? Bool
                ?? EditorTextSettings.wrapsDefault
            let checks = defaults.object(forKey: EditorTextSettings.checksSpellingKey) as? Bool
                ?? EditorTextSettings.checksSpellingDefault

            let wrapItem = NSMenuItem(title: "Wrap Lines", action: #selector(toggleWrapping(_:)),
                                      keyEquivalent: "")
            wrapItem.target = self
            wrapItem.state = wraps ? .on : .off

            let readableItem = NSMenuItem(title: Self.readableLineLengthTitle,
                                          action: #selector(toggleReadableLineLength(_:)), keyEquivalent: "")
            readableItem.target = self
            readableItem.state = Self.storedReadableLineLength(in: defaults) ? .on : .off
            // Greyed while lines don't wrap, where it changes nothing: here for a menu that doesn't
            // validate, and by `validateMenuItem` for the one AppKit hands over, which does.
            readableItem.isEnabled = Self.readableLineLengthApplies(in: defaults)

            let spellItem = NSMenuItem(title: "Check Spelling While Typing",
                                       action: #selector(toggleSpellChecking(_:)), keyEquivalent: "")
            spellItem.target = self
            spellItem.state = checks ? .on : .off

            menu.insertItem(spellItem, at: index)
            menu.insertItem(readableItem, at: index)
            menu.insertItem(wrapItem, at: index)
            var next = index + 3
            // Format Bar, where the bar can be drawn: a writable Markdown file. A hidden bar takes
            // its own right-click menu with it, and right-clicking the text is where somebody
            // looking for it will try next.
            if offersMarkup && editsMarkdown {
                let shows = defaults.object(forKey: EditorTextSettings.showsFormatBarKey) as? Bool
                    ?? EditorTextSettings.showsFormatBarDefault
                let barItem = NSMenuItem(title: Self.formatBarTitle, action: #selector(toggleFormatBar(_:)),
                                         keyEquivalent: "")
                barItem.target = self
                barItem.state = shows ? .on : .off
                menu.insertItem(barItem, at: next)
                next += 1
            }
            menu.insertItem(.separator(), at: next)
        }

        /// The item's title: View ▸ Format Bar's, so the two read as one switch.
        static let formatBarTitle = "Format Bar"

        /// View ▸ Format Bar's setting, flipped and logged, since this is the way back from the
        /// bar's own Hide Format Bar.
        @objc func toggleFormatBar(_ sender: NSMenuItem) {
            let shows = !(defaults.object(forKey: EditorTextSettings.showsFormatBarKey) as? Bool
                ?? EditorTextSettings.showsFormatBarDefault)
            defaults.set(shows, forKey: EditorTextSettings.showsFormatBarKey)
            Logger.shared.info("[edit] Format bar \(shows ? "shown" : "hidden") from the text's right-click menu")
        }

        /// Written to `UserDefaults`, not the view: `PlainTextEditor`'s `@AppStorage` observes it,
        /// so every mounted editor re-renders and `updateNSView` applies it, keeping both halves of
        /// a split in step.
        @objc func toggleWrapping(_ sender: NSMenuItem) {
            let current = defaults.object(forKey: EditorTextSettings.wrapsKey) as? Bool
                ?? EditorTextSettings.wrapsDefault
            defaults.set(!current, forKey: EditorTextSettings.wrapsKey)
        }

        /// The item's title: Text ▸ Readable Line Length's, so the two read as one switch.
        static let readableLineLengthTitle = "Readable Line Length"

        static func storedReadableLineLength(in defaults: UserDefaults) -> Bool {
            defaults.object(forKey: EditorTextSettings.readableLineLengthKey) as? Bool
                ?? EditorTextSettings.readableLineLengthDefault
        }

        /// Written to `UserDefaults` like ``toggleWrapping(_:)``, for the same reason: every mounted
        /// editor, both halves of a split, re-renders from the key.
        @objc func toggleReadableLineLength(_ sender: NSMenuItem) {
            let on = !Self.storedReadableLineLength(in: defaults)
            defaults.set(on, forKey: EditorTextSettings.readableLineLengthKey)
            Logger.shared.info("[edit] Readable Line Length \(on ? "on" : "off") from the text's right-click menu")
        }

        /// Readable Line Length is greyed while Wrap Lines is off, as in the Text menu. The text
        /// view's own context menu auto-enables its items, which asks this and ignores `isEnabled`;
        /// every other item here is always available.
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard menuItem.action == #selector(toggleReadableLineLength(_:)) else { return true }
            return Self.readableLineLengthApplies(in: defaults)
        }

        /// Whether Readable Line Length can do anything: only while lines wrap.
        static func readableLineLengthApplies(in defaults: UserDefaults) -> Bool {
            defaults.object(forKey: EditorTextSettings.wrapsKey) as? Bool ?? EditorTextSettings.wrapsDefault
        }

        @objc func toggleSpellChecking(_ sender: NSMenuItem) {
            let current = defaults.object(forKey: EditorTextSettings.checksSpellingKey) as? Bool
                ?? EditorTextSettings.checksSpellingDefault
            defaults.set(!current, forKey: EditorTextSettings.checksSpellingKey)
        }

        /// The Markup submenu, built from ``MarkupVerb/menuOrder`` with each verb's chord drawn on
        /// its item. Static so a test can build it without a text view and read the key
        /// equivalents back.
        ///
        /// The table verbs go in a Table submenu where their run starts in `menuOrder`, divided by
        /// ``MarkupVerb/tableSections``, each item tagged with its place in `menuOrder`. A table item
        /// is enabled only if it is in `tables` (what would do something at the selection); `nil`
        /// enables them all. The rest are enabled by hand, as the format bar does:
        /// - `inTable` greys the verbs that would break a table (``MarkupVerb/breaksTables``).
        /// - `abutsTable` greys the list and quote verbs, which would swallow the table the
        ///   paragraph runs into (``MarkupVerb/continuesLazily``).
        /// - `crossesCells` greys the marks and Link, which would break the table they cross.
        /// - `enabled: false` greys every item, for a file that isn't Markdown, where the verbs
        ///   would write `**` into a `.txt` or `.json`. The submenu stays, so the menu reads the
        ///   same in every file.
        static func markupMenu(target: AnyObject?, action: Selector, tables: Set<TableVerb>? = nil,
                               inTable: Bool = false, crossesCells: Bool = false, abutsTable: Bool = false,
                               enabled: Bool = true) -> NSMenu {
            let markup = NSMenu(title: "Markup")
            markup.autoenablesItems = false
            let table = NSMenu(title: MarkupVerb.tableMenuTitle)
            table.autoenablesItems = false
            for (index, verb) in MarkupVerb.menuOrder.enumerated() {
                guard let verb else {
                    markup.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: verb.title, action: action,
                                      keyEquivalent: verb.chord?.appKitKeyEquivalent ?? "")
                if let chord = verb.chord { item.keyEquivalentModifierMask = chord.appKitModifierMask }
                item.target = target
                item.tag = index
                if case .table(let op) = verb {
                    if table.items.isEmpty {
                        // The run's first item: the submenu goes here, and fills as the run goes on.
                        let host = NSMenuItem(title: MarkupVerb.tableMenuTitle, action: nil, keyEquivalent: "")
                        host.submenu = table
                        markup.addItem(host)
                    } else if MarkupVerb.tableSections.dropFirst().contains(where: { $0.first == verb }) {
                        table.addItem(.separator())
                    }
                    item.isEnabled = enabled && (tables?.contains(op) ?? true)
                    table.addItem(item)
                } else {
                    item.isEnabled = enabled && !(inTable && verb.breaksTables) && !(crossesCells && verb.wrapsWords)
                        && !(abutsTable && verb.continuesLazily)
                    markup.addItem(item)
                }
            }
            return markup
        }

        /// Whether the open file is Markdown, read off its path: what decides that the Markup verbs
        /// apply at all. The path, not ``editsMarkdown``, which is assigned on each update pass and
        /// `false` until the first, while a coordinator always knows its document. No path, no
        /// document to refuse for.
        var isMarkdownDocument: Bool {
            documentID.map { PairContentKind.isMarkdown(path: $0) } ?? true
        }

        /// Applies a verb to the view's own selection, as an edit the view can undo.
        @objc func applyMarkup(_ sender: NSMenuItem) {
            guard let view = textView, isMarkdownDocument,
                  MarkupVerb.menuOrder.indices.contains(sender.tag),
                  let verb = MarkupVerb.menuOrder[sender.tag] else { return }
            PlainTextEditor.apply(verb, to: view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onSelectionRangeCount(view.selectedRanges.count)
            onSelectionChange(view.selectedRange())
        }
    }

    /// Turns soft wrapping on or off.
    ///
    /// Leave any of these properties out and the view half-wraps. Off: the container stops
    /// tracking the view's width and gets unbounded width, the view becomes horizontally
    /// resizable, and the scroll view grows a horizontal scroller, or long lines are clipped. On:
    /// the view's width is reset to the visible width, since an unwrapped view has grown to its
    /// longest line and a container tracking that would wrap at the wrong column.
    static func applyWrapping(_ wraps: Bool, to view: NSTextView, in scroll: NSScrollView) {
        guard let container = view.textContainer else { return }
        let visible = scroll.contentSize.width
        if wraps {
            container.widthTracksTextView = true
            container.size = NSSize(width: visible, height: CGFloat.greatestFiniteMagnitude)
            view.isHorizontallyResizable = false
            view.frame.size.width = visible
            scroll.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
            view.isHorizontallyResizable = true
            scroll.hasHorizontalScroller = true
        }
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
    }

    /// The widest the text may run here, or `nil` for edge to edge (see ``EditorReadableColumn``).
    var readableColumn: CGFloat? {
        EditorReadableColumn.column(enabled: readableLineLength, wraps: wrapsLines, fontScale: fontScale)
    }

    /// Applies a markup verb to the view's selection as one undoable edit, never merged with the
    /// typing either side.
    ///
    /// The one implementation, reached from three doors: the context menu through
    /// `Coordinator.applyMarkup`, the menu bar and the format bar through
    /// `EditorDocumentSurface.applyMarkup(_:in:)`, so the undo grouping and selection arithmetic
    /// live in one place.
    ///
    /// - Returns: whether the verb applied; `false` when `MarkdownEdits` has nothing to do for this
    ///   selection, and the buffer and undo stack are untouched.
    @discardableResult
    static func apply(_ verb: MarkupVerb, to view: NSTextView) -> Bool {
        // A CRLF file becomes LF before the verb reads it, since the selection it hands back is
        // measured on the text it read (see `EditorLineEndings`). Asked first on the converted text,
        // so a verb with nothing to do converts nothing. The storage is asked for a CR, not
        // `view.string`, so an LF file pays no copy and no scan.
        if let editor = view as? EditorTextView, case let changes = editor.pendingCarriageReturns(),
           !changes.isEmpty {
            guard MarkdownEdits.apply(verb, to: EditorLineEndings.normalized(view.string),
                                      selection: EditorLineEndings.mapped(view.selectedRange(), through: changes)) != nil
            else { return false }
            // Not while a word is being composed: the conversion waits for the marked text, and the
            // verb written anyway would put LF breaks into a CRLF file. An LF file needs no
            // conversion, so there the verb commits the word and applies.
            guard !editor.convertLineEndingsToLF(on: "Markup ▸ \(verb.title)").isEmpty else {
                Logger.shared.info("Markup ▸ \(verb.title) did nothing: "
                                   + (view.hasMarkedText()
                                      ? "a word is being composed in a file that is not LF yet — finish the word, then try again"
                                      : "the file could not be converted to LF"))
                return false
            }
        }
        let text = view.string
        let selected = view.selectedRange()
        guard let edit = MarkdownEdits.apply(verb, to: text, selection: selected) else { return false }
        let change = MarkdownEdits.minimalReplacement(from: text, to: edit.text)
        // ⌘Z gives back the selection the verb was pressed over, and ⌘⇧Z the one it left; the
        // view's own undo of a replacement leaves a bare caret. Registered either side of the edit,
        // in its group: undo replays last-first, so the one registered before the edit runs after
        // the text is back, and the one registered after runs last on redo.
        let undo = view.undoManager
        if let undo { registerSelection(of: view, undoTo: selected, redoTo: nil, in: undo) }
        // `insertText(_:replacementRange:)`, the path typing takes: it registers the undo, applies
        // the typing attributes, and posts the change notification that updates the document,
        // three things a direct `textStorage` splice would do by hand. The view then coalesces it
        // with the typing either side, so the breaks make the verb its own step
        // (`MarkupVerbUndoTests` pins both sides, through all three doors).
        view.breakUndoCoalescing()
        view.insertText(change.text, replacementRange: change.range)
        view.breakUndoCoalescing()
        view.setSelectedRange(edit.selection)
        if let undo { registerSelection(of: view, undoTo: nil, redoTo: edit.selection, in: undo) }
        // Named after the verb, as Preview names it: to the view the insert is typing, so Edit ▸
        // Undo would otherwise read "Undo Typing" after Bold.
        undo?.setActionName(verb.title)
        return true
    }

    /// One half of a verb's selection in its undo step: on undo it selects `undoTo`, if any, and
    /// files its mirror for redo, which selects `redoTo`, so the pair holds however many times the
    /// step is undone and redone. A range the text no longer holds is left alone.
    private static func registerSelection(of view: NSTextView, undoTo: NSRange?, redoTo: NSRange?,
                                          in undo: UndoManager) {
        undo.registerUndo(withTarget: view) { [weak undo] view in
            if let undoTo, NSMaxRange(undoTo) <= (view.string as NSString).length {
                view.setSelectedRange(undoTo)
            }
            guard let undo else { return }
            registerSelection(of: view, undoTo: redoTo, redoTo: undoTo, in: undo)
        }
    }

    /// Opens the find bar over the text view, with its Replace row showing.
    ///
    /// Through a tagged sender: `performTextFinderAction(_:)` reads the action off the sender's
    /// `tag`, with no typed entry point. `.showReplaceInterface`, not `.showFindInterface`, under
    /// which AppKit hides the Replace field with no control to bring it back, though the header's
    /// button promises find and replace. `theFindBarOpensWithItsReplaceRowShowing` measures the
    /// field. The find field still takes the caret, so a plain find costs one row, no keystrokes.
    public static func showFindBar(in view: NSTextView) {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        view.performTextFinderAction(sender)
    }

    /// Sets the room under the last line (``bottomInset``), only when it changed, so an update
    /// that leaves it alone doesn't retile the scroll view. The automatic insets go off once one is
    /// set: they follow the window's title bar, which this card is nowhere near.
    static func applyBottomInset(_ inset: CGFloat, to scroll: NSScrollView) {
        guard scroll.contentInsets.bottom != inset else { return }
        scroll.automaticallyAdjustsContentInsets = false
        var insets = scroll.contentInsets
        insets.bottom = inset
        scroll.contentInsets = insets
    }

    /// Ends the find bar's work over `view`, for a text view that is about to be let go.
    ///
    /// AppKit's find indicator can outlive the finder it reports to: Find Next, and an incremental
    /// search's first match, ask it to redraw a few milliseconds later, keeping the indicator alive
    /// but not the finder. A text view freed in that window leaves the redraw messaging freed memory
    /// and the process dies (`-[NSTextFinderIndicatorManager _delayedUpdate]`). See "A find
    /// indicator's redraw outlives the text view it was asked for" in `docs/flaky-tests.md`.
    ///
    /// Two steps, because neither covers the other:
    /// - Hiding the bar retires a search still in flight, whose first match could otherwise land
    ///   after the document has closed.
    /// - Nothing public cancels a redraw already asked for, so the view is held by a run-loop timer
    ///   due well after it: timers in one mode fire in date order, so the hold ends after the
    ///   redraw even on a busy main thread.
    static func retireFindBar(of view: NSTextView) {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.hideFindInterface.rawValue
        view.performTextFinderAction(sender)
        nonisolated(unsafe) let held = view
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in withExtendedLifetime(held) {} }
    }

    /// Points `view` at `source`'s text storage, at construction and whenever the document changes.
    ///
    /// The factory builds the view and this re-points its `NSTextContentStorage`, which keeps it on
    /// TextKit 2 with typing and undo landing on the storage shown. The attributes are the view's
    /// typing attributes over the whole storage, as `view.string = text` would set them, and they
    /// register no undo, so a mode switch mounts a view without adding a step to the history.
    ///
    /// Never through `layoutManager` on a TextKit 2 view: merely reading it drops the view to
    /// TextKit 1 for good. The fallback reads it only where the view is TextKit 1 already.
    static func show(_ source: EditorSourceStorage, in view: NSTextView) {
        let storage = source.textStorage
        if view.textStorage !== storage {
            if let content = view.textContentStorage {
                content.textStorage = storage
            } else {
                view.layoutManager?.replaceTextStorage(storage)
            }
        }
        storage.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: storage.length))
        source.textView = view
    }

    /// The document changed under a mounted view: show the incoming storage, with the caret where
    /// it was, clamped to the new length, and scrolled into view, or a caret at 0 in a freshly
    /// opened file is left behind a scroller still where the previous document was.
    ///
    /// - Returns: whether the view was re-pointed.
    @discardableResult
    static func follow(_ source: EditorSourceStorage, in view: NSTextView) -> Bool {
        guard view.textStorage !== source.textStorage else { return false }
        let selected = view.selectedRange()
        show(source, in: view)
        let range = NSRange(location: min(selected.location, source.textStorage.length), length: 0)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        return true
    }

    /// Where a 1-based line begins, from the table when it describes this buffer and from the walk
    /// when it does not.
    ///
    /// Unlike the scroll sync, the caret can't accept a stale table: the table is rebuilt on a
    /// debounce, so opening a file straight at a heading would read the previous document's line
    /// starts. So the length is compared first, and a mismatch falls back to
    /// ``EditorCaret/utf16Offset(ofLine:in:)``, which walks and is always right. A UTF-16 length is
    /// O(n) for a native Swift string, fine on an outline click but not on every scroll tick.
    static func utf16Offset(ofLine line: Int, in text: String,
                            using index: EditorLineIndex) -> Int? {
        guard index.utf16Length == (text as NSString).length else {
            return EditorCaret.utf16Offset(ofLine: line, in: text)
        }
        return index.utf16Offset(ofLine: line)
    }

    /// Where a scroll request puts the caret: a heading's line start, or for Go to Line, which
    /// carries a column, the typed line and column clamped to the text as it is now.
    static func offset(for request: EditorScrollRequest, in text: String,
                       using index: EditorLineIndex) -> Int? {
        guard let column = request.column else { return utf16Offset(ofLine: request.line, in: text, using: index) }
        return EditorGoToLine.utf16Offset(of: EditorGoToLine.Target(line: request.line, column: column),
                                          in: text, using: index)
    }

    /// The storage forgets this view as it goes, unless a newer one already took its place: a mode
    /// switch can build the next view before this one is taken down, and undo actions keep a
    /// dismantled view alive, so a weak reference alone would go on naming it.
    ///
    /// The find bar is retired too, so closing the document as a search lands can't leave AppKit's
    /// find indicator a redraw to send to a freed finder (see ``retireFindBar(of:)``).
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.stopWatchingScrolling()
            if let view = scroll.documentView as? NSTextView {
                retireFindBar(of: view)
                if coordinator.source.textView === view { coordinator.source.textView = nil }
            }
        }
    }

    /// The standing find request is taken as already answered. The counter lives in the workspace,
    /// which outlives this text view, so a new coordinator starting at `0` would read the last Find
    /// press as fresh and open the find bar over the next document opened.
    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(source: source, undoManager: undoManager, documentID: documentID,
                                      onSelectionChange: onSelectionChange)
        coordinator.onSelectionRangeCount = onSelectionRangeCount
        coordinator.lastFindRequest = findRequest
        // The scroll request too, for the same reason: a view rebuilt by a mode switch would
        // replay the last heading jump over wherever the caret went since. A request made while no
        // text view is up (from Preview) has already moved the caret's anchor, where a new text
        // view puts the caret.
        coordinator.lastScrollRequest = scrollRequest
        // A follow standing from before this view was built is not news to it, and replayed would
        // land over the restored caret.
        coordinator.lastFollowRequest = followRequest
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The subclass, for its paste and drop (see ``EditorTextView``), built by the same factory
        // on the same TextKit 2 engine.
        let scroll = EditorTextView.scrollableTextView()
        // Marked, so a chord fired from outside can tell this text view from every other one (see
        // `EditorDocumentSurface` for why `responder is NSTextView` is the wrong question).
        scroll.identifier = EditorDocumentSurface.identifier
        // ⌘Z from the find bar is the document's (see `EditorDocumentScrollView`).
        (scroll as? EditorDocumentScrollView)?.documentUndoManager = undoManager
        Self.applyBottomInset(bottomInset, to: scroll)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }

        // The delegate is wired at the end of this method; the reason is there.
        view.allowsUndo = true
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        // The find bar is on: unlike a substitution, it only reads the file. AppKit's own bar
        // brings find, replace, replace-all, next/previous and a live match count, behaving as in
        // every other Mac app, for one property and the action below.
        view.usesFindBar = true
        // Highlights as you type rather than on Return, which makes the count worth having.
        view.isIncrementalSearchingEnabled = true
        // Every substitution off. This edits real files: a curly quote or an em dash for `--` is a
        // silent change to somebody's YAML, shell script or Markdown.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        // Checking is a choice; correcting is not. Everything above rewrites the file unasked; this
        // only draws a red line, so it is the one a person may turn on
        // (`EditorTextSettings.checksSpellingKey`).
        view.isContinuousSpellCheckingEnabled = checksSpelling
        view.isGrammarCheckingEnabled = false
        view.drawsBackground = false
        view.textContainerInset = EditorReadableColumn.baseInset
        view.font = Self.font(scale: fontScale)
        // The document's own storage, shared with every view of it before this one, which is what
        // lets ⌘Z after a mode switch reach the screen.
        Self.show(source, in: view)
        view.isEditable = isEditable
        Self.applyWrapping(wrapsLines, to: view, in: scroll)
        context.coordinator.lineIndex = lineIndex
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.textView = view
        context.coordinator.offersMarkup = offersMarkup
        context.coordinator.editsMarkdown = editsMarkdown
        context.coordinator.continuesLists = continuesLists
        context.coordinator.imageImport = imageImport
        (view as? EditorTextView)?.handler = context.coordinator
        textViewHandle?.textView = view
        context.coordinator.watchScrolling(of: scroll, textView: view)
        Self.restoreCaret(to: initialSelection, in: view, text: source.text)
        // Wired last, after the text and the caret. `NSTextView` reports programmatic selection
        // moves to its delegate, and building this view makes two: showing the text leaves the
        // caret at its end, then `restoreCaret` moves it. Reported, both would write `@State`
        // inside SwiftUI's update pass, and the host would record "end of document" as the caret's
        // anchor for a file never clicked in. Nothing above needs a delegate, so there is none to
        // call yet; `EditorCaretAnchorTests` pins the silence.
        view.delegate = context.coordinator
        return scroll
    }

    /// Puts a rebuilt text view's caret back where the reader left it.
    ///
    /// Clamped against the text being assigned, not what the anchor remembers: the file can be
    /// shorter than when the offset was recorded, and `setSelectedRange` past the end raises
    /// `NSRangeException`, taking the app down with every unsaved buffer. The same hazard the undo
    /// store's fingerprint check guards, reached through the caret.
    ///
    /// The selection lands now; the scroll takes a hop. In `makeNSView` the scroll view has no
    /// geometry yet, so `scrollRangeToVisible` would be silently dropped, the reason
    /// `FileTreeView`'s and `PaneColumnsView`'s reveals hop too. The caret is set at once so a
    /// keystroke before the hop goes to the right place.
    ///
    /// Placed unconditionally, a zero included: a fresh text view puts the caret at the end of its
    /// text while the scroll view shows the top, so skipping `offset == 0` would leave the caret
    /// invisibly at the end.
    private static func restoreCaret(to offset: Int, in view: NSTextView, text: String) {
        let bounded = EditorCaretAnchors.clamped(offset, in: text)
        let range = NSRange(location: bounded, length: 0)
        view.setSelectedRange(range)
        // Nothing to bring into view at the top: the fresh scroll view is already there.
        guard bounded > 0 else { return }
        DispatchQueue.main.async { [weak view] in
            // The document can have been replaced before the hop runs (a rail click lands in
            // `updateNSView`), so the range is re-checked against the storage as it stands now.
            // `textStorage?.length`, never `view.string`, which copies the whole document to
            // answer a count; the storage's length is in `NSRange`'s own units.
            guard let view, bounded <= (view.textStorage?.length ?? 0) else { return }
            view.scrollRangeToVisible(range)
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // No echo guard: the view shows the document's own storage and the buffer follows it, so
        // typing is never handed back. What can change under a mounted view is which storage (a
        // file switch), and that is an identity check in `follow`.
        context.coordinator.undoManager = undoManager
        (scroll as? EditorDocumentScrollView)?.documentUndoManager = undoManager
        Self.applyBottomInset(bottomInset, to: scroll)
        // The undo stack goes with the document. `NSTextView` registers undo by character range,
        // so replaying one document's ranges into another splices text or throws
        // `NSRangeException`, taking the app down with every unsaved buffer. `EditorUndoStore`
        // hands this view the shown document's own stack, beside the storage its actions edit
        // (`follow` below re-points the view at it), so two documents' registrations never meet;
        // it also refuses a stack whose fingerprint no longer fits the buffer. Keyed on the path,
        // not the text, since two files can hold the same bytes.
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
        }
        Self.follow(source, in: view)
        if view.isEditable != isEditable { view.isEditable = isEditable }
        if view.isContinuousSpellCheckingEnabled != checksSpelling {
            view.isContinuousSpellCheckingEnabled = checksSpelling
        }
        if (view.textContainer?.widthTracksTextView ?? true) != wrapsLines {
            Self.applyWrapping(wrapsLines, to: view, in: scroll)
        }
        let font = Self.font(scale: fontScale)
        if view.font != font {
            view.font = font
        }
        // Here only, not in `makeNSView` too: SwiftUI runs this straight after building the view.
        // Its order against the wrapping doesn't matter, since the width wrapping resets re-centres
        // the column through `setFrameSize` either way. The view ignores a value it already has.
        (view as? EditorTextView)?.readableColumnWidth = readableColumn
        (view as? EditorTextView)?.drawsPage = drawsPage
        // Here only, as the column is: SwiftUI runs this straight after building the view.
        (view as? EditorTextView)?.typewriterScrolling = typewriterScrolling
        context.coordinator.source = source
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onSelectionRangeCount = onSelectionRangeCount
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.lineIndex = lineIndex
        context.coordinator.textView = view
        context.coordinator.offersMarkup = offersMarkup
        context.coordinator.editsMarkdown = editsMarkdown
        context.coordinator.continuesLists = continuesLists
        context.coordinator.imageImport = imageImport
        // Every pass, not only at construction: Source and Split mount this view from two `switch`
        // arms, so the text view the handle names changes with the mode.
        if textViewHandle?.textView !== view { textViewHandle?.textView = view }

        if findRequest != context.coordinator.lastFindRequest {
            context.coordinator.lastFindRequest = findRequest
            Self.showFindBar(in: view)
        }

        // After the storage has been followed, never before: opening a file straight at a heading
        // sends the request in the same pass as the text, and an offset computed against the
        // previous buffer points into the wrong document.
        if let followRequest, followRequest != context.coordinator.lastFollowRequest {
            context.coordinator.lastFollowRequest = followRequest
            let text = source.text
            if let offset = Self.utf16Offset(ofLine: followRequest.line, in: text, using: lineIndex) {
                // The line's own report is the echo of this scroll: not sent on.
                context.coordinator.lastVisibleLine = followRequest.line
                PreviewTextView.scrollLineToTop(view, at: min(offset, (text as NSString).length))
            }
        }
        if let scrollRequest, scrollRequest != context.coordinator.lastScrollRequest {
            context.coordinator.lastScrollRequest = scrollRequest
            let text = source.text
            if let offset = Self.offset(for: scrollRequest, in: text, using: lineIndex) {
                let range = Self.selection(for: scrollRequest, at: offset, length: (text as NSString).length)
                view.setSelectedRange(range)
                view.scrollRangeToVisible(range)
                // The caret is where the reader was sent, so it should also be where typing goes.
                view.window?.makeFirstResponder(view)
                if scrollRequest.seedsFind, range.length > 0 { Self.seedFind(in: view, selecting: range) }
            }
        }
    }

    /// The range a request selects: from `offset`, its ``EditorScrollRequest/length`` clamped to
    /// the text; a bare caret for every request but a Contents result's.
    static func selection(for request: EditorScrollRequest, at offset: Int, length: Int) -> NSRange {
        let location = min(max(offset, 0), length)
        return NSRange(location: location, length: max(0, min(request.length, length - location)))
    }

    /// The match becomes Find's text, as ⌘E would make it, and the find bar shows it, so the word
    /// searched for in the Files list is the one ⌘G steps through here.
    ///
    /// Then the selection and the keys are put back where the result left them: showing the bar
    /// gives its field the keyboard, and the reader was sent to the match, not to the field.
    static func seedFind(in view: NSTextView, selecting range: NSRange) {
        view.setSelectedRange(range)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.setSearchString.rawValue
        view.performTextFinderAction(sender)
        showFindBar(in: view)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(view)
    }
}
