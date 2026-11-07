/// The one source of the copy/move action glyphs used on the window toolbar, the Differences
/// header and row menu, and the tree's right-click menu, so MacApp and this module can't drift.
/// Separate from `DifferenceGlyph`, which encodes a difference's status, not an action.
///
/// Two axes: whether the direction is fixed at the call site, and copy or move. A menu that
/// resolves each item its own way takes plain `copy` / `move`; a one-way button takes
/// `copy(toRight:)` / `move(toRight:)`, pointing at its target pane. The fixed copy is an arrow
/// because the Differences header sheds its destination name when narrow, and a bare arrow beside
/// the move's boxed arrow reads as the same direction with a different verb.
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
