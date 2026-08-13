import SwiftUI

// MARK: - Risky-name glyph vocabulary

/// The iconography for a name that will not store cleanly, kept distinct from the duplicate
/// finder's (`wand.and.stars` / `checkmark.seal.fill`) and Filing's (`folder.badge.gearshape` /
/// trays) so the lenses never share a symbol.
///
/// **All that is left of the standalone Name Normalizer lens.** Its list view, row card and
/// invisible-character card lived in this file — as `NameNormalizeLens.swift`, under the name
/// `RiskyNameGlyph` — until the findings moved into `RenamePassLens.toFixSection` (v4.0 polish
/// P10) and the `.names` rail item was retired outright. The glyph outlived the lens because three
/// live surfaces quote it: the pane badge, the tree's "Fix name…" item, and the to-fix rows. A
/// risky name should look the same in all three, which is why this is one constant and not three.
///
/// `allSafe` went with the views — it was the retired lens's earned all-clean state, and the state
/// that replaced it wears the rename backlog's seal rather than this shield.
enum RiskyNameGlyph {
    /// Signature symbol — text with a warning, for the tree's "Fix name…" item.
    static let lens = "textformat.abc.dottedunderline"
    /// The per-row "this name is risky" marker.
    static let risky = "exclamationmark.triangle.fill"
}
