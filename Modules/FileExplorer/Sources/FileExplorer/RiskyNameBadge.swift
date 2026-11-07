import Design
import SwiftUI

/// The "this provider will reject this name" marker, drawn beside a file's name wherever files are
/// listed: both panes, the Columns view, and the Differences table.
///
/// Organize's finding and the row's "Fix name" make a cloud-hostile name easy to act on; this
/// makes it easy to notice.
///
/// Glyph and colour are `RiskyNameGlyph.risky` and `SemanticColor.caution`, as on Organize's
/// risky-names chip and rows, so the same finding looks the same everywhere.
///
/// A bare tinted glyph, like the app's other per-row markers: a filled chip would be the only
/// boxed thing on a dense row and would fight the 0.22-opacity selection wash
/// (`PaneSelectionWash`).
///
/// No space is reserved when there is no badge: unlike the cloud badge, which arrives after the
/// row, this answer is known when the row is built.
struct RiskyNameBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Why the name is hostile; nil draws nothing at all.
    let reason: String?
    /// The pane's resolved fonts — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled

    var body: some View {
        if let reason {
            Image(systemName: RiskyNameGlyph.risky)
                .font(fonts.riskyNameBadge)
                // A glyph whose colour is the meaning: the 3:1 treatment, not the body-text one.
                .foregroundStyle(ChromeInk.semantic(colorScheme, SemanticColor.caution))
                // The reason itself, not a generic "risky name": the tooltip is the only place the
                // why shows without a menu, and "ends with a space" makes the mark actionable.
                .help(reason)
                .accessibilityLabel("Risky name. \(reason)")
        }
    }
}
