/// Single source of truth for the copy/move ACTION glyphs — the "copy to the other pane" and
/// "move to the other pane" affordances that appear on the window toolbar, the Differences
/// header, the Differences row menu, and the tree right-click menu. Kept in the FileExplorer
/// module so both MacApp (PaneLogic, the window toolbar) and this module (DifferencesView,
/// FileTreeView) draw from one vocabulary and can't drift.
///
/// Deliberately separate from `DifferenceGlyph`, which encodes a difference's STATUS (which
/// side is missing, dates differ, name conflict). Status and action are different axes;
/// conflating them is what let these four surfaces drift to four different copy icons.
///
/// Copy is non-directional in every state: SF Symbols has no left/right duplicate pair that
/// reads as cleanly as the universal duplicate glyph (`doc.on.doc`), so the target pane is
/// named in the button's text ("Copy 21 to Dropbox"), not the icon — `copy(toRight:)` exists
/// only so a fixed-direction call site can stay symmetric with `move(toRight:)`. Move is a
/// box-with-arrow that points toward the target pane wherever the direction is fixed (the
/// toolbar, and the header/row buttons once the move modifier is held).
public enum TransferGlyph {
    /// Copy to the other pane. Non-directional — see the type doc.
    public static let copy = "doc.on.doc"

    /// Move to the other pane, non-directional: for menus that name their target pane in text
    /// and can't assume a fixed side. Matches `move(toRight:)`'s right-pointing default.
    public static let move = "arrow.right.square"

    /// Copy where the direction is fixed. Copy has no directional SF Symbol that reads as well
    /// as the duplicate glyph, so this stays non-directional and equals `copy`; the parameter
    /// only keeps fixed-direction call sites symmetric with `move(toRight:)`.
    public static func copy(toRight: Bool) -> String { copy }

    /// Move where the direction is fixed: a box-with-arrow pointing at the target pane — right
    /// when the selection is on the left, and vice versa.
    public static func move(toRight: Bool) -> String {
        toRight ? "arrow.right.square" : "arrow.left.square"
    }
}
