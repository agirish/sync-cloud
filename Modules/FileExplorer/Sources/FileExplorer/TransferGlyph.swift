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
/// Two axes, deliberately: whether the direction is FIXED at the call site, and whether the verb
/// is copy or move. A menu row that resolves each item in its own direction takes the plain
/// `copy` / `move`; a button that always goes one way takes `copy(toRight:)` / `move(toRight:)`
/// and points at the pane it targets.
///
/// The fixed-direction copy used to be non-directional too — it returned the duplicate glyph
/// (`doc.on.doc`) on the grounds that the button's text named the target pane anyway. Two things
/// undid that. The Differences header now fixes its primary to left-to-right rather than electing
/// it by count, so direction is a *constant* of that button and belongs in the icon rather than
/// re-read from the label each time; and the same header sheds its destination name first when the
/// window narrows, which left the direction carried by the one run of text that disappears. A bare
/// arrow for copy against the boxed arrow for move also makes the modifier legible as a change of
/// verb: same direction, different container.
public enum TransferGlyph {
    /// Copy to the other pane, direction unresolved: for menus that name their target in text
    /// and for "remaining", which resolves each item its own way. Matches `copy(toRight:)`'s
    /// right-pointing default no more than `move` does — it is a duplicate glyph, not an arrow.
    public static let copy = "doc.on.doc"

    /// Move to the other pane, non-directional: for menus that name their target pane in text
    /// and can't assume a fixed side. Matches `move(toRight:)`'s right-pointing default.
    public static let move = "arrow.right.square"

    /// Copy where the direction is fixed: a bare arrow pointing at the target pane. Paired with
    /// `move(toRight:)`'s boxed arrow — same direction, and the box is what marks the move.
    public static func copy(toRight: Bool) -> String {
        toRight ? "arrow.right" : "arrow.left"
    }

    /// Move where the direction is fixed: a box-with-arrow pointing at the target pane — right
    /// when the selection is on the left, and vice versa.
    public static func move(toRight: Bool) -> String {
        toRight ? "arrow.right.square" : "arrow.left.square"
    }
}
