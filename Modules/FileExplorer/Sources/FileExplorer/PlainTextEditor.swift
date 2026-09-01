import SwiftUI
import AppKit
import Design

/// The writable text surface: an `NSTextView` in a scroll view, kept plain on purpose.
///
/// **Why AppKit and not `TextEditor`.** SwiftUI's editor gives no access to the undo manager, no
/// way to switch smart substitutions off, and no first responder to hand the standard editing
/// chords to. All three matter here — see ``Coordinator/undoManager(for:)`` for the one that
/// matters most.
///
/// **⌘X / ⌘C / ⌘V / ⌘A arrive with the responder, not from a registration.** `TextEditingChord`
/// routes those four by asking whether the first responder `is NSTextView`; being one is the whole
/// qualification, so there is deliberately nothing to register here.
struct PlainTextEditor: NSViewRepresentable {

    @Binding var text: String
    /// Read-only documents are shown, not hidden — a lossy decode is still worth reading.
    var isEditable: Bool
    /// Settings ▸ Text size, so the monospace ramp scales with the rest of the app.
    var fontScale: CGFloat

    /// **Which document these keystrokes belong to** — the open file's path, or nil when none is.
    ///
    /// The undo stack is cleared when this changes, and *only* when this changes. It used to be
    /// cleared inside `if view.string != text`, which is the one condition that is false exactly
    /// when the document changes without the buffer's contents changing: open `a.md`, edit it, then
    /// open `b.md` holding an identical copy, and ⌘Z replayed the edit made against `a.md` into a
    /// file the user never touched. The codebase already knew this case existed — `EditorParseKey`
    /// was invented for it, in the same words — and the reasoning reached the parse key and not the
    /// text bridge.
    var documentID: String?

    /// **The editor's own undo stack, owned by the WINDOW rather than by this view.**
    ///
    /// Two reasons, and the first is why the stack is separate at all. An `NSTextView` with
    /// `allowsUndo` vends an undo manager to the responder chain, and the window's manager is bound
    /// to `FileSyncManager` — the one the operation banner's Undo button reads and the one the
    /// engine matches file operations against by `undoActionName`. Left to shadow each other, ⌘Z
    /// inside the editor and the banner's Undo button would be two names for two different stacks,
    /// and a typo could sit where "undo the last move" was expected.
    ///
    /// The second is why it is passed IN rather than held by the coordinator. `surfaces(for:)`
    /// mounts this view from two different `switch` arms, so `.edit` and `.split` are two
    /// structural identities and switching between them built a fresh coordinator with a fresh,
    /// empty stack — clicking Split to check the render and clicking back silently ended the undo
    /// history. `document`, `mode` and the split fraction were all hoisted to the host so a
    /// workspace switch could not reset them; this is the fourth thing that needed it.
    var undoManager: UndoManager

    /// Called whenever the selection moves, with its UTF-16 range in the buffer.
    ///
    /// **The only way out of an `NSTextView` for where the caret is.** SwiftUI's `TextEditor` has
    /// no selection at all, which is one of the reasons this is AppKit; the status line's line and
    /// column, and the outline's idea of which heading you are in, both start here.
    var onSelectionChange: (NSRange) -> Void = { _ in }

    /// Where to put the caret next, or `nil` for "leave it alone".
    ///
    /// **A request carrying a token, not a line number**, for the reason `namingFocus` is a counter
    /// rather than a flag: clicking the same outline row twice is two requests for the same line,
    /// and a plain `Int?` would be unchanged between them — so the second click, the one somebody
    /// makes precisely because they have scrolled away since the first, would do nothing.
    var scrollRequest: EditorScrollRequest?

    /// Called when the topmost visible line changes, which is what the split's preview follows.
    ///
    /// Fired from the clip view's own bounds notification rather than polled: the text view scrolls
    /// for reasons SwiftUI never hears about — a scroll wheel, a trackpad flick, the caret being
    /// dragged past the bottom edge.
    var onVisibleLineChange: (Int) -> Void = { _ in }

    /// Bumped to open the find bar. A counter for the reason ``scrollRequest`` carries a token:
    /// asking twice is two requests, and the second one is the one made after the bar was closed.
    var findRequest: Int = 0

    /// Whether the markup verbs are offered on the context menu. `false` on a document that cannot
    /// be saved — see ``EditorDocument/readOnlyReason``.
    var offersMarkup: Bool = true

    /// The editor's base size before the app's text scale is applied. 13 is the platform's own
    /// monospace reading size and matches the keycaps elsewhere in the app.
    static let baseFontSize: CGFloat = 13

    /// **Through `FontSize.scaledPointSize`, not a bare multiply.** Every other string in the app
    /// goes through that curve, which damps growth above an 11pt knee — a plain `base * scale` put
    /// the editor's text 11% larger than its own header and rail at the Larger setting (17.55pt
    /// against the ramp's 15.85). Below 1.0 the two agree, which is why a multiply reads fine at
    /// Small and Default and only parts company at the sizes someone chooses because they need it.
    static func font(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: FontSize.scaledPointSize(baseFontSize, scale: scale),
                              weight: .regular)
    }

    // `@MainActor` because it holds an `UndoManager`, whose initialiser is main-actor isolated —
    // and because every delegate callback below arrives on the main thread anyway.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The window's editor stack, handed over so text edits never reach the engine's.
        var undoManager: UndoManager
        /// The document the stack currently holds edits for.
        var documentID: String?
        /// Re-assigned on every update pass, like ``text`` — a closure captured once at
        /// construction would go on writing into the view that built it after a re-render.
        var onSelectionChange: (NSRange) -> Void
        var onVisibleLineChange: (Int) -> Void = { _ in }
        /// The last request acted on, so the same one is not replayed on every render pass.
        var lastScrollRequest: EditorScrollRequest?
        /// The last find request acted on. `0` is "never asked", which is why the request is a
        /// counter starting there rather than an optional.
        var lastFindRequest: Int = 0
        /// The last line reported upward, so an ordinary scroll does not publish the same number
        /// sixty times a second.
        var lastVisibleLine: Int?
        /// Kept so the bounds observer — which fires outside a render pass — can do line maths
        /// without reaching back into SwiftUI for the buffer.
        var currentText: String = ""
        /// The view these callbacks belong to. Weak: the coordinator outlives a torn-down view, and
        /// a strong reference here would be a retain cycle through the delegate.
        weak var textView: NSTextView?
        private var boundsObserver: (any NSObjectProtocol)?

        init(text: Binding<String>, undoManager: UndoManager, documentID: String?,
             onSelectionChange: @escaping (NSRange) -> Void) {
            self.text = text
            self.undoManager = undoManager
            self.documentID = documentID
            self.onSelectionChange = onSelectionChange
        }

        /// Drops the bounds observer.
        ///
        /// **Called from `dismantleNSView`, not from `deinit`.** A block-based observer has to be
        /// removed by hand, and a nonisolated `deinit` may not touch a main-actor stored property —
        /// so the tear-down hook AppKit already provides is both the correct place and the only
        /// legal one.
        func stopWatchingScrolling() {
            boundsObserver.map(NotificationCenter.default.removeObserver)
            boundsObserver = nil
        }

        /// Starts reporting the topmost visible line.
        ///
        /// **`postsBoundsChangedNotifications` has to be turned on**; a clip view does not post by
        /// default, and an observer registered without it is a silent no-op — the split would
        /// simply never sync, with nothing anywhere saying why.
        func watchScrolling(of scroll: NSScrollView, textView: NSTextView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                MainActor.assumeIsolated {
                    guard let line = Self.topVisibleLine(of: textView, in: self.currentText) else {
                        return
                    }
                    guard line != self.lastVisibleLine else { return }
                    self.lastVisibleLine = line
                    self.onVisibleLineChange(line)
                }
            }
        }

        /// The 1-based source line at the top of what is on screen.
        ///
        /// **`characterIndexForInsertion(at:)`, not the layout manager** — and that is not a style
        /// preference. `NSTextView.layoutManager` is TextKit 1's; on a view AppKit built with
        /// TextKit 2, merely *reading* that property drops the view back to the TextKit 1
        /// compatibility path for the rest of its life. Asking through a public method that both
        /// engines answer keeps the split's scroll sync from quietly re-engineering the editor
        /// underneath it.
        ///
        /// Not computed from the scroll offset and a line height either: the view soft-wraps, so
        /// one source line can occupy four rows and there is no height to divide by.
        static func topVisibleLine(of view: NSTextView, in text: String) -> Int? {
            guard let clip = view.enclosingScrollView?.contentView else { return nil }
            // A point just inside the top-left of what is visible, in the text view's own
            // coordinates — past the container inset, or the answer is the character nearest a
            // point in the margin above the first line.
            let point = NSPoint(x: view.textContainerInset.width + 1,
                                y: clip.bounds.origin.y + view.textContainerInset.height + 1)
            let index = view.characterIndexForInsertion(at: point)
            guard index >= 0, index <= (text as NSString).length else { return nil }
            return EditorCaret.at(utf16Offset: index, in: text).line
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        var offersMarkup = true

        /// The Markup section of the text view's context menu.
        ///
        /// **The delegate hook, not an `NSTextView` subclass.** AppKit asks the delegate before it
        /// shows the menu, so the standard items — Cut, Copy, Look Up, the spelling submenu — are
        /// still AppKit's own and keep working; a subclass overriding `menu(for:)` would have to
        /// rebuild them or risk dropping one.
        ///
        /// **No key equivalents on these items.** The chords they will eventually carry belong to
        /// menu-bar items that do not exist yet, and a context menu advertising `⌘B` for a chord
        /// nothing registers would be telling the reader something untrue.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent,
                      at charIndex: Int) -> NSMenu? {
            guard offersMarkup else { return menu }
            let markup = NSMenu(title: "Markup")
            for (index, verb) in MarkupVerb.menuOrder.enumerated() {
                guard let verb else {
                    markup.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: verb.title, action: #selector(applyMarkup(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = index
                markup.addItem(item)
            }
            let host = NSMenuItem(title: "Markup", action: nil, keyEquivalent: "")
            host.submenu = markup
            menu.insertItem(host, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        /// Applies a verb to the view's own selection, as an edit the view can undo.
        @objc func applyMarkup(_ sender: NSMenuItem) {
            guard let view = textView,
                  MarkupVerb.menuOrder.indices.contains(sender.tag),
                  let verb = MarkupVerb.menuOrder[sender.tag],
                  let edit = MarkdownEdits.apply(verb, to: view.string,
                                                 selection: view.selectedRange()) else { return }
            let change = MarkdownEdits.minimalReplacement(from: view.string, to: edit.text)
            // **`insertText(_:replacementRange:)`, which is the path typing takes.** It registers
            // the undo, applies the view's own typing attributes to what it inserts, and posts the
            // change notification that pushes the new buffer back into the document — three things
            // a direct `textStorage` splice would each have to be made to do by hand.
            view.insertText(change.text, replacementRange: change.range)
            view.setSelectedRange(edit.selection)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onSelectionChange(view.selectedRange())
        }
    }

    /// Opens the find bar over the text view.
    ///
    /// **Through a tagged sender, which is the only way in.** `performTextFinderAction(_:)` reads
    /// which action to run off the sender's `tag` — there is no typed entry point — so a menu item
    /// that is never in a menu is the standard way to ask for one by hand.
    static func showFindBar(in view: NSTextView) {
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.stopWatchingScrolling() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undoManager: undoManager, documentID: documentID,
                    onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }

        view.delegate = context.coordinator
        view.allowsUndo = true
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        // **The find bar is on, and this line used to read `false`.** It sat in the "keep it plain"
        // list with the substitutions, which is where it did not belong: a substitution rewrites
        // somebody's file behind their back and a find bar reads it. Off, there was no way to
        // search the open document at all — the app's ⌘F is Find in Pane, which in this workspace
        // expands the search field of a source pane that is collapsed by default.
        //
        // AppKit's own bar rather than one drawn here: it brings find, replace, replace-all,
        // next/previous and a live match count, all of them behaving the way every other Mac app's
        // does, for one property and the action below.
        view.usesFindBar = true
        // Highlights as you type rather than on Return, which is what makes the count worth having.
        view.isIncrementalSearchingEnabled = true
        // **Every substitution off.** This edits real files: a quote turned into a curly quote, or
        // `--` into an em dash, is a silent change to somebody's YAML, shell script or Markdown.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.font = Self.font(scale: fontScale)
        view.string = text
        view.isEditable = isEditable
        context.coordinator.currentText = text
        context.coordinator.textView = view
        context.coordinator.offersMarkup = offersMarkup
        context.coordinator.watchScrolling(of: scroll, textView: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        // **`view.string != text` is the whole echo guard, and it has to be.** Typing writes the
        // binding, which re-renders, which lands here — by which point the view already holds the
        // string being pushed at it, so this is false and the caret is left alone. An `isPushing`
        // flag set and cleared inside `textDidChange` looks like the guard and is not: SwiftUI runs
        // this pass *after* that method has returned, so the flag is always back to false by the
        // time it would be read.
        context.coordinator.undoManager = undoManager
        // **The undo stack goes with the DOCUMENT**, and this is the one line standing between the
        // editor and a crash. `NSTextView`'s registrations name character RANGES in the buffer they
        // were made against; assigning `string` replaces the buffer and clears nothing, so a ⌘Z
        // after switching files replays an edit from the previous document against this one —
        // splicing its characters out where the ranges happen to land, or throwing
        // `NSRangeException` (`substringWithRange: … out of bounds`) and taking the app down with
        // every unsaved buffer in it when they do not. Keyed on the path rather than on the text,
        // because two files can hold the same bytes.
        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            undoManager.removeAllActions()
        }
        if view.string != text {
            let selected = view.selectedRange()
            view.string = text
            // Keep the caret where it was when the change came from outside (a reload, a file
            // switch), clamped to the new length — and scrolled back into view, since a caret at
            // offset 0 in a freshly opened file is otherwise left behind a scroller still sitting
            // where the previous document was.
            let location = min(selected.location, (text as NSString).length)
            let range = NSRange(location: location, length: 0)
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
        }
        if view.isEditable != isEditable { view.isEditable = isEditable }
        let font = Self.font(scale: fontScale)
        if view.font != font {
            view.font = font
        }
        context.coordinator.text = $text
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onVisibleLineChange = onVisibleLineChange
        context.coordinator.currentText = text
        context.coordinator.textView = view
        context.coordinator.offersMarkup = offersMarkup

        if findRequest != context.coordinator.lastFindRequest {
            context.coordinator.lastFindRequest = findRequest
            Self.showFindBar(in: view)
        }

        // **After the string has been pushed, never before.** A request arrives in the same render
        // pass as the text it names when a file is opened straight at a heading, and an offset
        // computed against the previous buffer is an offset into the wrong document.
        if let scrollRequest, scrollRequest != context.coordinator.lastScrollRequest {
            context.coordinator.lastScrollRequest = scrollRequest
            if let offset = EditorCaret.utf16Offset(ofLine: scrollRequest.line, in: text) {
                let range = NSRange(location: min(offset, (text as NSString).length), length: 0)
                view.setSelectedRange(range)
                view.scrollRangeToVisible(range)
                // The caret is where the reader was sent, so it should also be where typing goes.
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
