import SwiftUI

// MARK: - Risky-name glyph vocabulary

/// The iconography for a name that will not store cleanly, kept distinct from the duplicate
/// finder's (`wand.and.stars` / `checkmark.seal.fill`) and Filing's (`folder.badge.gearshape` /
/// trays) so the lenses never share a symbol.
///
/// One constant for three surfaces (the pane badge, the tree's "Fix name" item and the to-fix
/// rows in `RenamePassLens.toFixSection`), so a risky name looks the same in all of them.
enum RiskyNameGlyph {
    /// Signature symbol — text with a warning, for the tree's "Fix name" item.
    static let lens = "textformat.abc.dottedunderline"
    /// The per-row "this name is risky" marker.
    static let risky = "exclamationmark.triangle.fill"
}
