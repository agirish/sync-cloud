import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// Pins that resolving a row's fonts once per pane draws exactly what resolving them per row did.
///
/// `PaneRowFonts` exists purely to cut layers out of the per-row modifier chain — the thing a main
/// thread sample showed owning ~50% of a click. It is worth nothing if it also changes what the
/// rows look like, and a font regression is the kind that no functional test notices and every user
/// does. So each font is asserted against the exact `ScaledFont` specification the call site it
/// replaced used to pass.
///
/// The scale-1 cases are the load-bearing ones: `ScaledFont.resolved(scale:)` short-circuits there
/// and hands back the very `Font` value the old call site built, so at the default text size this
/// is not "equivalent", it is *identical*.
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
    /// This is what makes the type a *relocation* of the existing rule rather than a second copy of
    /// it that can drift.
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

    /// The mutation check. Every assertion above would still pass if `PaneRowFonts` ignored its
    /// `scale` argument entirely and always returned the default fonts — because the scale-1 cases
    /// dominate and `.medium` IS scale 1. So the setting has to be shown to actually reach the rows.
    @Test("A larger text size genuinely produces different fonts")
    func scaleIsNotIgnored() {
        let base = PaneRowFonts(scale: 1)
        let large = PaneRowFonts(scale: FontSize.extraLarge.scale)
        #expect(base != large)
        #expect(base.name != large.name)
        #expect(base.secondary != large.secondary)
        #expect(base.differenceBadge != large.differenceBadge)
    }

    /// The badge glyphs start below `FontSize.legibilityFloor`, and the floor exists so shrinking
    /// never makes them illegible. Asserted here because the floor lives in `ScaledFont` and this
    /// type is now the thing that decides what a badge is drawn at.
    @Test("Shrinking honours the legibility floor the badges rely on")
    func smallSizeHonoursTheFloor() {
        let small = PaneRowFonts(scale: FontSize.small.scale)
        #expect(small.countPill == ScaledFont.caption2.weight(.semibold).resolved(scale: FontSize.small.scale))
        #expect(small.cloudBadge == ScaledFont.caption.resolved(scale: FontSize.small.scale))
    }
}
