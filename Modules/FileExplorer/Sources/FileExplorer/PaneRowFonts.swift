import Design
import SwiftUI

/// The fonts one pane row draws, resolved once for the whole pane instead of once per row.
///
/// Row clicks cost SwiftUI materializing each row's modifier layers, not what the rows compute.
/// Each `scaledFont(_:)` is a custom modifier: a wrapper, its body's `.font` wrapper, and an
/// `@Environment` dependency, five times per row. Resolving up front makes each a plain `.font(_:)`;
/// the scale is uniform down the subtree, so every row gets the same answer it would have computed.
/// `ScaledFont.resolved(scale:)` returns the call site's own `Font` at scale 1, and what
/// `scaledFont` would produce at other sizes.
///
/// The pane's `@Environment` read keeps the setting live: a text-size change invalidates the pane
/// (dynamic properties invalidate regardless of `FileTreeView`'s `==`) and new fonts flow down.
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
        // Caption, like the cloud badge: it sits inside the name's reading line, so it stays
        // subordinate to the name.
        riskyNameBadge = ScaledFont.caption.resolved(scale: scale)
        countPill = ScaledFont.caption2.weight(.semibold).resolved(scale: scale)
        chevron = ScaledFont.caption2.weight(.semibold).resolved(scale: scale)
    }

    /// Unscaled, for callers with no pane around them (previews, layout tests).
    static let unscaled = PaneRowFonts(scale: 1)
}
