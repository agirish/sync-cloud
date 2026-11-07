import AppKit
import SwiftUI

/// Which undo stack ⌘Z reaches while Edit shows a document.
///
/// `NSWindow` handles `undo:` for any first responder that doesn't. For a text view that allows
/// undo it uses, and titles the menu from, the stack the view's delegate returns from
/// `undoManager(for:)`; overriding the view's own `undoManager` changes nothing. For anything else
/// it undoes its own stack, which in this app is the file operations' (`FileSyncManager`, via
/// `ContentView`'s `.rewireUndoManager`).
///
/// The rule: while Edit shows a document, ⌘Z acts on the document's stack when the first responder
/// is the window, the document's text view, its find or replace fields, or read-only Preview; on
/// the file operations' only when the file pane or another control has the keyboard. AppKit's own
/// resolution is kept where it reaches the document; elsewhere the responder answers `undo:` and
/// `redo:` itself (``EditorUndoCommands``), so the Edit menu always names the step ⌘Z will take.
/// Not `windowWillReturnUndoManager`: SwiftUI owns that delegate, and the window's stack must stay
/// the file operations' everywhere.
///
/// The find bar's field editor undoes the field's own typing, then forwards up the responder
/// chain; ``EditorDocumentScrollView`` names the document's stack so the forwarding stops there
/// instead of reaching the window. When nothing has the keyboard, see ``EditorUndoAnchor``.

/// The scroll view a document's text view and its find bar sit in, Source's and editable
/// Preview's.
final class EditorDocumentScrollView: NSScrollView {

    /// The document's stack. Weak: the store owns it, and a scroll view a mode switch has let go of
    /// must not keep a closed document's history alive.
    weak var documentUndoManager: UndoManager?

    /// The document's stack, for every responder inside: the text view names it through its
    /// delegate already, and the find bar's fields reach it once their own typing is undone.
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
}

// MARK: - Nothing has the keyboard (UND-1, UND-2)

/// Keeps the window from being left as first responder while Edit shows a document. Mounted beside
/// the document, never seen and never clicked.
///
/// Left as first responder, the window undoes the file operations' stack, so ⌘Z would undo a move
/// instead of the typing. Two ordinary states leave it there: a mode switch (each mode builds its
/// own text view, and the one with the keyboard goes away), and read-only Preview, which has no
/// text view at all.
///
/// So whenever the window holds the keyboard, the document's text view takes it, and where there
/// is none (read-only Preview, a refusal) the anchor takes it and answers ⌘Z with the document's
/// stack. A text view arriving while the anchor holds it takes over. **Never** moves the keyboard
/// off something that has it: the file pane, the rail's filter and the naming row keep theirs.
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

    /// ⌘Z and ⇧⌘Z answered here, on the document's stack. Otherwise the window answers them, and
    /// for a plain view it undoes its own stack whatever ``undoManager`` says.
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
        // `firstResponder` is KVO-observable: act the moment the window is left holding the
        // keyboard, as when a mode switch tears down the view that had it.
        observation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard window.firstResponder == nil || window.firstResponder === window else { return }
                self?.claimSoon()
            }
        }
    }

    /// A document text view has come into `window`, such as the new Source view a mode switch built.
    /// It takes the keyboard if nobody holds it, or only this anchor does.
    static func textViewArrived(in window: NSWindow?) {
        guard let window else { return }
        anchors.object(forKey: window)?.claimSoon()
    }

    /// A turn later, so the triggering switch has finished: old text view gone, new one in the
    /// window and the handle. Re-checked then, so a field SwiftUI focused meanwhile (the naming row,
    /// Go to Line) is left alone.
    func claimSoon() {
        DispatchQueue.main.async { [weak self] in self?.claimIfNobodyHasTheKeyboard() }
    }

    /// Gives the keyboard to the document's text view, or to this anchor where there is none, when
    /// the window holds it, or this anchor does and a text view has since arrived.
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
    /// A text view a mode switch let go of can still be alive (undo actions hold their views), so
    /// only one in this window counts.
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
    /// whatever the stack holds, for editable Preview's composition, which they commit.
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

/// The stack Edit ▸ Undo acts on when sent to a responder, this file's rule as AppKit applies it,
/// for whoever must know before sending: the run lock greys Undo only when it would step the file
/// operations' stack, so typing undo in Edit goes on (`RunUndoGate`).
public enum UndoStackReached {

    /// A responder that answers `undo:` itself (the anchor, Fill & Sign's overlay, editable Preview)
    /// acts on the stack it names. The window acts on a text view's when one that allows undo has
    /// the keyboard: the stack its delegate returns, else the window's. Otherwise its own.
    @MainActor
    public static func stack(for target: Any?) -> UndoManager? {
        guard let window = target as? NSWindow else { return (target as? NSResponder)?.undoManager }
        if let text = window.firstResponder as? NSTextView, text.allowsUndo {
            return text.delegate?.undoManager?(for: text) ?? window.undoManager
        }
        return window.undoManager
    }

    /// The responder `action` reaches from `window`'s keyboard holder, up the chain: what
    /// `NSApp.target(forAction:)` answers for the key window.
    @MainActor
    public static func target(of action: Selector, in window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let candidate = responder, !candidate.responds(to: action) { responder = candidate.nextResponder }
        return responder
    }
}
