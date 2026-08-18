import Design
import SwiftUI

/// The "this provider will reject this name" marker, drawn beside a file's name wherever files are
/// listed: both panes, the Columns view, and the Differences table.
///
/// **Why it exists.** Folding Rename into Organize made a cloud-hostile name cheap to *act on* — a
/// finding in Organize's header when the scan turns one up, and "Fix name…" in any row's context
/// menu. It did not make one cheap to *notice*: a name the cloud will reject looked exactly like
/// every other name until you either ran Organize or right-clicked the file for an unrelated reason.
/// This is the other half — the discovery.
///
/// **Same finding, same clothes.** Glyph and colour are `RiskyNameGlyph.risky` and
/// `SemanticColor.caution`, which is what Organize's own risky-names chip and its list rows already
/// wear. A finding that changed appearance depending on which surface reported it would read as two
/// different findings.
///
/// **A bare glyph, not the mockup's tinted chip.** Every other per-row marker in this app — the
/// cloud-only badge, the difference badge — is an unadorned tinted symbol, and a row is a dense
/// place: a filled background here would be the only boxed thing on the line, and would have to
/// fight the accent selection wash for contrast on a selected row. The wash is 0.22 opacity (see
/// `PaneSelectionWash`), which is exactly why the difference glyphs keep their own colours on a
/// selected row without special-casing; this one follows the same rule for the same reason.
///
/// **Nothing is reserved when there is no badge.** Unlike the cloud badge — which arrives *after*
/// the row, one `lstat` at a time, and so needs a slot held open or the trailing cluster ripples —
/// this answer is known synchronously, at the moment the row is built. There is nothing to arrive
/// late, so an absent badge takes no space rather than an empty 16pt of it on every clean name in
/// the pane.
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
                // A GLYPH whose colour is the meaning: the 3:1 treatment, not the body-text one.
                // (The audit listed this beside three prose sites; it is an `Image`, so the bar is
                // different and so is the fix.)
                .foregroundStyle(ChromeInk.semantic(colorScheme, SemanticColor.caution))
                // The reason itself, not a generic "risky name": the tooltip is the only place the
                // *why* is available without opening a menu, and "ends with a space" is the part
                // that makes the mark actionable rather than merely alarming.
                .help(reason)
                .accessibilityLabel("Risky name. \(reason)")
        }
    }
}
