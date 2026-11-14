import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// Pins that resolving a row's fonts once per pane (`PaneRowFonts`, which cuts layers from the
/// per-row modifier chain) draws exactly what resolving them per row would: each font against the
/// `ScaledFont` specification its call site would pass. At scale 1 `resolved(scale:)` returns the
/// call site's very `Font`.
@Suite struct PaneRowFontsTests {

    // MARK: Default size — must be the identical Font, not merely a similar one

    @Test("At the default text size every row font is the one the call site used to build")
    func defaultSizeIsUnchanged() {
        let fonts = PaneRowFonts(scale: 1)
        #expect(fonts.name == Font.system(.body, design: .rounded))
        #expect(fonts.secondary == Font.caption)
        #expect(fonts.cloudBadge == Font.caption)
        #expect(fonts.differenceBadge == Font.subheadline)
        #expect(fonts.riskyNameBadge == Font.caption)
        #expect(fonts.countPill == Font.caption2.weight(.semibold))
        #expect(fonts.chevron == Font.caption2.weight(.semibold))
    }

    @Test("The unscaled convenience is the default size")
    func unscaledIsScaleOne() {
        #expect(PaneRowFonts.unscaled == PaneRowFonts(scale: 1))
    }

    // MARK: Other sizes — must match what scaledFont would have resolved

    /// Every size, against `ScaledFont`'s own resolution of the same specification. At `.small` it
    /// is also the badges' `FontSize.legibilityFloor`.
    @Test("A scaled row font matches ScaledFont's resolution of the same specification",
          arguments: [FontSize.small, .medium, .large, .extraLarge])
    func scaledMatchesScaledFont(size: FontSize) {
        let scale = size.scale
        let fonts = PaneRowFonts(scale: scale)
        #expect(fonts.name == ScaledFont.system(.body, design: .rounded).resolved(scale: scale))
        #expect(fonts.secondary == ScaledFont.caption.resolved(scale: scale))
        #expect(fonts.cloudBadge == ScaledFont.caption.resolved(scale: scale))
        #expect(fonts.differenceBadge == ScaledFont.subheadline.resolved(scale: scale))
        #expect(fonts.riskyNameBadge == ScaledFont.caption.resolved(scale: scale))
        #expect(fonts.countPill == ScaledFont.caption2.weight(.semibold).resolved(scale: scale))
        #expect(fonts.chevron == ScaledFont.caption2.weight(.semibold).resolved(scale: scale))
    }
}
