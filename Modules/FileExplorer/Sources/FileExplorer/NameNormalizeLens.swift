import SwiftUI
import Sync
import Design

// MARK: - Risky-name glyph vocabulary

/// The iconography for a name that will not store cleanly, kept distinct from the duplicate
/// finder's (`wand.and.stars` / `checkmark.seal.fill`) and Filing's (`folder.badge.gearshape` /
/// trays) so the lenses never share a symbol.
///
/// **All that remains of the standalone Name Normalizer lens**, whose list view, row card and
/// invisible-character card lived in this file until the findings moved into
/// `RenamePassLens.toFixSection` (v4.0 polish P10) and the `.names` rail item was retired. The
/// glyph outlived the lens because three live surfaces quote it — the pane badge, the tree's
/// "Fix name…" item, and the to-fix rows — and a risky name should look the same in all three.
///
/// `allSafe` went with the views: it was the retired lens's earned all-clean state, and the state
/// that replaced it (`LensWorkspaceView`'s "Nothing to rename") wears the backlog's seal, not this
/// shield.
enum NameNormalizeGlyph {
    /// Signature symbol — text with a warning, for the tree's "Fix name…" item.
    static let lens = "textformat.abc.dottedunderline"
    /// The per-row "this name is risky" marker.
    static let risky = "exclamationmark.triangle.fill"
}
