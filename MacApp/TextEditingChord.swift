import AppKit

/// The one rule for a menu chord that is also a text-editing key.
///
/// **A menu key equivalent outranks the field editor.** AppKit offers the keystroke to the menu
/// before the responder chain sees it, so registering ⌘A, ⌘X, ⌘C, ⌘V or ⌘⌫ on a menu item takes
/// that key away from every text field in the app — the pane search, a rename field, the
/// differences search, the ⌘K field. With files selected, which is the normal state, ⌘C over a
/// caret would copy *files* and leave the typist wondering why nothing was on the pasteboard.
///
/// This is not hypothetical and not new: `DeleteSelectionCommand` has carried exactly this routing
/// for ⌘⌫ since it was registered, because ⌘⌫ is also NSText's delete-to-beginning-of-line and
/// Finder ships that wart. What is new is that four more chords need it at once, so the rule moves
/// here rather than being copied five times — and it moves *before* §3's ⌘↑ / ⌘↓ arrive, which
/// need it too. That ordering is why the menu bar is order step 5 and the chords are step 6.
///
/// **The test is the first responder, not the focused SwiftUI view.** Whenever any text field holds
/// the caret, AppKit's first responder is the shared field editor — an `NSTextView` — regardless of
/// which SwiftUI view owns the field. `@FocusState` cannot see that, which is the whole reason this
/// reads the responder directly.
enum TextEditingChord {

    /// Whether the keystroke belongs to text being edited rather than to a file action.
    ///
    /// Static and injectable so the rule is testable without a window: the live check reads
    /// `NSApp.keyWindow?.firstResponder`, which a unit test has none of.
    static func belongsToTextEditor(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    /// Runs `fileAction`, unless the caret owns the keystroke — in which case `editorAction` hands
    /// it back to the field editor it was taken from.
    ///
    /// **Handing it back is not optional.** Swallowing the keystroke would be worse than the
    /// collision it avoids: ⌘C in a text field would silently do nothing at all, which reads as the
    /// app being broken rather than as a chord being busy.
    static func route(responder: NSResponder?,
                      editorAction: (NSTextView) -> Void,
                      fileAction: () -> Void) {
        if let editor = responder as? NSTextView {
            editorAction(editor)
        } else {
            fileAction()
        }
    }

    /// The live form: reads the key window's first responder for you.
    @MainActor
    static func route(editorAction: (NSTextView) -> Void, fileAction: () -> Void) {
        route(responder: NSApp.keyWindow?.firstResponder,
              editorAction: editorAction, fileAction: fileAction)
    }
}
