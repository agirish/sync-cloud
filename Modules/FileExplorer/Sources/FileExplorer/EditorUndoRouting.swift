import AppKit
import SwiftUI

/// **Which undo stack ⌘Z reaches while Edit shows a document.**
///
/// AppKit answers Edit ▸ Undo and ⌘Z through the window. `NSWindow` handles `undo:` for any first
/// responder that does not. For a text view that allows undo it undoes — and titles the menu item
/// from — the stack the text view's DELEGATE returns from `undoManager(for:)`; overriding the view's
/// own `undoManager` property changes nothing. For anything else it undoes its OWN stack (measured
/// 2026-10-16: a plain view, and editable Preview's text view, whose `allowsUndo` is off, both reach
/// the window's stack despite overriding `undoManager`).
/// In this app the window's own stack is `FileSyncManager`'s, the file operations'
/// (`ContentView`'s `.rewireUndoManager`).
///
/// **The rule:** while Edit shows a document, ⌘Z acts on the document's stack when the first
/// responder is the window itself, the document's text view, its find or replace fields, or the
/// read-only Preview; on the file operations' only when the file pane or another control has the
/// keyboard. Other workspaces mount none of this.
///
/// **AppKit's own resolution is kept wherever it can reach the document** — Source's text view, and
/// the find bar's fields through the scroll view around them — and everywhere else the responder
/// answers `undo:` and `redo:` itself, titling the item from the same stack it acts on
/// (``EditorUndoCommands``). Either way the Edit menu names the step ⌘Z will take. Not the window
/// delegate's `windowWillReturnUndoManager`: SwiftUI owns that delegate, and the window's undo
/// manager is what `FileSyncManager` is wired to, so it must stay the file operations' everywhere.
///
/// **Nothing has the keyboard (UND-1, UND-2)** — see ``EditorUndoAnchor``.
///
/// **The find bar (UND-3).** Its fields' editor answers with a cell undo manager that undoes the
/// field's own typing and then forwards to the responders above the field — up through the scroll
/// view the find bar lives in, to the window. Measured 2026-10-16: ⌘Z with the caret in the Find
/// field undid a stand-in file operation and left the document's edit. The scroll view now names
/// the document's stack (``EditorDocumentScrollView``), so the forwarding stops there.

/// The scroll view a document's text view and its find bar sit in — Source's, and editable
/// Preview's.
final class EditorDocumentScrollView: NSScrollView {

    /// The document's stack. Weak: the store owns it, and a scroll view a mode switch has let go of
    /// must not keep a closed document's history alive.
    weak var documentUndoManager: UndoManager?

    /// **The document's, for every responder inside**: the text view names the same one through its
    /// delegate already; the find bar's fields reach it once their own typing is undone.
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
}

// MARK: - Nothing has the keyboard (UND-1, UND-2)

/// **Keeps the window from being left as first responder while Edit shows a document** — mounted
/// beside the document, never seen and never clicked.
///
/// Left as first responder, the window undoes its OWN stack, the file operations'. Two ordinary
/// states left it there, measured 2026-10-16, each undoing a stand-in move and leaving the edit:
///
/// - **A mode switch** (UND-1). Source, Split and Preview each build their own text view, and the
///   one that had the keyboard goes with the arm it was in. Type, ⌃⌘3 to see the render, ⌘Z — and
///   the last file operation in Browse was undone instead of the typing.
/// - **Read-only Preview** (UND-2). It has no text view at all, so a box ticked there went on the
///   document's stack while its ⌘Z went to the file operations'.
///
/// So whenever the window holds the keyboard, the document's text view takes it — Source's, or
/// editable Preview's where Preview is all there is — and where there is none (read-only Preview, a
/// refusal) the anchor takes it itself and answers ⌘Z with the document's stack. A text view
/// that arrives while the anchor holds it takes it over. **Nothing that has the keyboard is ever
/// moved off it**: the file pane, the rail's filter, the naming row keep it, and ⌘Z there is
/// theirs — the file operations', where that is what they hold.
struct EditorUndoAnchor: NSViewRepresentable {

    /// The open document's stack.
    let undoManager: UndoManager
    /// Where the document's text views are — Source's, editable Preview's, and Split's Preview half.
    let handle: EditorTextViewHandle

    func makeNSView(context: Context) -> EditorUndoAnchorView {
        let view = EditorUndoAnchorView()
        view.documentUndoManager = undoManager
        view.handle = handle
        return view
    }

    func updateNSView(_ view: EditorUndoAnchorView, context: Context) {
        view.documentUndoManager = undoManager
        view.handle = handle
    }
}

/// The anchor itself — see ``EditorUndoAnchor``.
final class EditorUndoAnchorView: NSView, NSUserInterfaceValidations {

    weak var documentUndoManager: UndoManager?
    var handle: EditorTextViewHandle?

    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    /// **⌘Z and ⇧⌘Z answered here, on the document's stack.** The window would answer them for a
    /// first responder that does not, and for a plain view it undid its OWN stack, whatever
    /// ``undoManager`` said (measured 2026-10-16).
    @objc func undo(_ sender: Any?) { documentUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { documentUndoManager?.redo() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        EditorUndoCommands.validate(item, on: documentUndoManager) ?? false
    }

    /// Takes the keyboard only when given it — never by a click (it is never hit) and never by Tab.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    private var observation: NSKeyValueObservation?

    /// The anchor in each window, for a text view arriving there to find.
    private static let anchors = NSMapTable<NSWindow, EditorUndoAnchorView>.weakToWeakObjects()

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let window, window !== newWindow else { return }
        observation?.invalidate()
        observation = nil
        if Self.anchors.object(forKey: window) === self { Self.anchors.removeObject(forKey: window) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, observation == nil else { return }
        Self.anchors.setObject(self, forKey: window)
        // `firstResponder` is observable (measured): the moment the window is left holding the
        // keyboard — the view that had it torn down by a mode switch — is the moment to act.
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard window.firstResponder == nil || window.firstResponder === window else { return }
                self?.claimSoon()
            }
        }
    }

    /// A document text view has come into `window` — the new Source view a mode switch built, or
    /// Preview's. It takes the keyboard if nobody holds it, or only this anchor does.
    static func textViewArrived(in window: NSWindow?) {
        guard let window else { return }
        anchors.object(forKey: window)?.claimSoon()
    }

    /// **A turn later**, so the switch that triggered it has finished: the old text view gone, the
    /// new one in the window and in the handle. Asked again then, so a field SwiftUI focused in the
    /// meantime — the naming row, Go to Line — is left alone.
    func claimSoon() {
        DispatchQueue.main.async { [weak self] in self?.claimIfNobodyHasTheKeyboard() }
    }

    /// The keyboard to the document's text view, or to this anchor where there is none — when the
    /// window holds it, or this anchor does and a text view has since arrived.
    func claimIfNobodyHasTheKeyboard() {
        guard let window else { return }
        let holder = window.firstResponder
        guard holder == nil || holder === window || holder === self else { return }
        if let text = documentTextView {
            window.makeFirstResponder(text)
        } else if holder !== self {
            window.makeFirstResponder(self)
        }
    }

    /// The document's text view in this window: Source's (also Split's), else editable Preview's.
    /// A text view a mode switch let go of can still be alive — undo actions hold the views they
    /// were made in — so only one in this window counts.
    private var documentTextView: NSTextView? {
        guard let window, let handle else { return nil }
        for candidate in [handle.textView, handle.splitPreview] {
            if let view = candidate, view.window === window { return view }
        }
        return nil
    }
}

/// Edit ▸ Undo and Redo as a responder that answers them itself draws them: titled from the stack
/// they act on, and enabled when it has a step to take.
enum EditorUndoCommands {

    static let undo = Selector(("undo:"))
    static let redo = Selector(("redo:"))

    /// The item's answer, or `nil` when it is neither Undo nor Redo. `alsoWhen` enables both
    /// whatever the stack holds — editable Preview's composition, which they commit (UND-8).
    @MainActor
    static func validate(_ item: any NSValidatedUserInterfaceItem, on manager: UndoManager?,
                         alsoWhen extra: Bool = false) -> Bool? {
        switch item.action {
        case undo:
            (item as? NSMenuItem)?.title = manager?.undoMenuItemTitle ?? "Undo"
            return extra || manager?.canUndo == true
        case redo:
            (item as? NSMenuItem)?.title = manager?.redoMenuItemTitle ?? "Redo"
            return extra || manager?.canRedo == true
        default:
            return nil
        }
    }
}

/// **The stack Edit ▸ Undo acts on when sent to a responder** — this file's rule, as AppKit applies
/// it, for whoever must know before sending: the run lock greys Undo only when it would step the
/// file operations' stack, and Edit's typing undo goes on (`RunUndoGate`, Banner Room CF).
public enum UndoStackReached {

    /// A responder that answers `undo:` itself — the anchor, Fill & Sign's overlay, editable
    /// Preview — acts on the stack it names. The window acts on a text view's when one that allows
    /// undo has the keyboard: the stack its delegate returns, else the window's. For anything else
    /// it acts on its own.
    @MainActor
    public static func stack(for target: Any?) -> UndoManager? {
        guard let window = target as? NSWindow else { return (target as? NSResponder)?.undoManager }
        if let text = window.firstResponder as? NSTextView, text.allowsUndo {
            return text.delegate?.undoManager?(for: text) ?? window.undoManager
        }
        return window.undoManager
    }

    /// The responder `action` reaches from `window`'s keyboard holder, up the chain — what
    /// `NSApp.target(forAction:)` answers for the key window.
    @MainActor
    public static func target(of action: Selector, in window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let candidate = responder, !candidate.responds(to: action) { responder = candidate.nextResponder }
        return responder
    }
}
