import Design
import SwiftUI

/// The fonts one pane row draws, resolved ONCE for the whole pane instead of once per row.
///
/// **Why this exists, measured rather than assumed.** A `sample` of the main thread taken while
/// clicking through a pane put ~50% of it in `ModifiedContent._makeViewList` — SwiftUI expanding
/// the modifier chain of every list row — against ~0.1% in SyncCloud's own code. The click cost is
/// not what the rows *compute*, it is how many layers SwiftUI has to materialize for each of them.
///
/// `scaledFont(_:)` is one of those layers, five times over on a single row (name, secondary
/// detail, cloud badge, difference badge, count pill), and it is a comparatively expensive one: it
/// is a custom `ViewModifier`, so each use costs a `ModifiedContent` wrapper *plus* the modifier's
/// own body (which applies `.font` — another wrapper) *plus* an `@Environment` read installed as a
/// per-instance dynamic property. Five uses per row is five custom modifiers, five extra wrappers
/// and five environment dependencies, each recreated for every row every time the list expands.
///
/// Resolving up front collapses each of those to a single `.font(_:)`. The pane reads
/// `\.appFontScale` once and hands rows plain `Font` values, which is the same answer every row was
/// computing independently — the environment is uniform down that subtree.
///
/// **Rendering is unchanged, exactly.** `ScaledFont.resolved(scale:)` short-circuits at scale 1 and
/// returns the very `Font` value the call site built, so at the default text size every row draws
/// the identical font it did before. At other sizes it returns what `scaledFont` would have
/// produced from the same specification.
///
/// The pane's `@Environment` read is what keeps the setting live: changing the text size
/// invalidates the pane (dynamic properties drive invalidation independently of
/// `FileTreeView`'s `==`, the same way its `@AppStorage` hue already does) and the new fonts flow
/// down. Rows no longer observe the scale themselves, and no longer need to.
struct PaneRowFonts: Equatable {
    /// The file or folder name — the row's primary label.
    let name: Font
    /// The trailing size / date detail, shown at comfortable density only.
    let secondary: Font
    /// The cloud-only placeholder glyph, and the hidden twin that reserves its width.
    let cloudBadge: Font
    /// The per-row difference glyph.
    let differenceBadge: Font
    /// The cloud-hostile-name marker that sits beside the name.
    let riskyNameBadge: Font
    /// The contained-differences count pill on a folder row.
    let countPill: Font
    /// The disclosure chevron a Columns row adds to a folder.
    let chevron: Font

    init(scale: CGFloat) {
        name = ScaledFont.system(.body, design: .rounded).resolved(scale: scale)
        secondary = ScaledFont.caption.resolved(scale: scale)
        cloudBadge = ScaledFont.caption.resolved(scale: scale)
        differenceBadge = ScaledFont.subheadline.resolved(scale: scale)
        // Caption, matching the cloud badge rather than the difference glyph: this one sits INSIDE
        // the name's own reading line, so it has to stay subordinate to the name it qualifies.
        riskyNameBadge = ScaledFont.caption.resolved(scale: scale)
        countPill = ScaledFont.caption2.weight(.semibold).resolved(scale: scale)
        chevron = ScaledFont.caption2.weight(.semibold).resolved(scale: scale)
    }

    /// Unscaled, for callers with no pane around them (previews, and the row tests that assert
    /// layout rather than type size).
    static let unscaled = PaneRowFonts(scale: 1)
}
