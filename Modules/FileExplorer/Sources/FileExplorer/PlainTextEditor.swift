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

        init(text: Binding<String>, undoManager: UndoManager, documentID: String?) {
            self.text = text
            self.undoManager = undoManager
            self.documentID = documentID
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undoManager: undoManager, documentID: documentID)
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
        view.usesFindBar = false
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
    }
}
