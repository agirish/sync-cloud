import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// Pins that resolving a row's fonts once per pane draws exactly what resolving them per row would.
///
/// `PaneRowFonts` exists to cut layers out of the per-row modifier chain, which dominates a click's
/// main-thread time. It is worth nothing if it changes what rows look like, and a font regression
/// is one no functional test notices and every user does. So each font is asserted against the
/// `ScaledFont` specification its call site would pass.
///
/// The scale-1 cases matter most: `ScaledFont.resolved(scale:)` short-circuits there and hands back
/// the very `Font` value the call site would build, so at the default text size this is identical,
/// not just equivalent.
@Suite struct PaneRowFontsTests {

    // MARK: Default size — must be the identical Font, not merely a similar one

    @Test("At the default text size every row font is the one the call site used to build")
    func defaultSizeIsUnchanged() {
        let fonts = PaneRowFonts(scale: 1)
        #expect(fonts.name == Font.system(.body, design: .rounded))
        #expect(fonts.secondary == Font.caption)
        #expect(fonts.cloudBadge == Font.caption)
        #expect(fonts.differenceBadge == Font.subheadline)
        #expect(fonts.countPill == Font.caption2.weight(.semibold))
        #expect(fonts.chevron == Font.caption2.weight(.semibold))
    }

    @Test("The unscaled convenience is the default size")
    func unscaledIsScaleOne() {
        #expect(PaneRowFonts.unscaled == PaneRowFonts(scale: 1))
    }

    // MARK: Other sizes — must match what scaledFont would have resolved

    /// Every non-default size, against `ScaledFont`'s own resolution of the same specification.
    /// This makes the type a relocation of the existing rule rather than a second copy that can
    /// drift. At `.small` it is also the badges' legibility floor: their glyphs start below
    /// `FontSize.legibilityFloor`, which lives in `ScaledFont`.
    @Test("A scaled row font matches ScaledFont's resolution of the same specification",
          arguments: [FontSize.small, .medium, .large, .extraLarge])
    func scaledMatchesScaledFont(size: FontSize) {
        let scale = size.scale
        let fonts = PaneRowFonts(scale: scale)
        #expect(fonts.name == ScaledFont.system(.body, design: .rounded).resolved(scale: scale))
        #expect(fonts.secondary == ScaledFont.caption.resolved(scale: scale))
        #expect(fonts.cloudBadge == ScaledFont.caption.resolved(scale: scale))
        #expect(fonts.differenceBadge == ScaledFont.subheadline.resolved(scale: scale))
        #expect(fonts.countPill == ScaledFont.caption2.weight(.semibold).resolved(scale: scale))
        #expect(fonts.chevron == ScaledFont.caption2.weight(.semibold).resolved(scale: scale))
    }

    /// Every assertion above would still pass if `PaneRowFonts` ignored its `scale` argument and
    /// always returned the default fonts, because `.medium` is scale 1. So the setting has to be
    /// shown to reach the rows.
    @Test("A larger text size genuinely produces different fonts")
    func scaleIsNotIgnored() {
        let base = PaneRowFonts(scale: 1)
        let large = PaneRowFonts(scale: FontSize.extraLarge.scale)
        #expect(base != large)
        #expect(base.name != large.name)
        #expect(base.secondary != large.secondary)
        #expect(base.differenceBadge != large.differenceBadge)
    }
}
