import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Design

/// The Appearance model's two controls (glass level and surface style), the migration of older
/// stored values onto them, and the card insets the gap model rests on. A stored value must never
/// leave an overlay card on clear glass with the app reading straight through it.
struct GlassLevelTests {

    // MARK: - The chrome legibility floor

    @Test func clearIsFlooredToFrostedForChrome() {
        // Overlay cards (Settings, Help, first-run, the banner) must stay legible over the app
        // content behind them. The floor can never resolve to no-frost glass, however clear the
        // rest of the app is.
        #expect(GlassLevel.clear.flooredForChrome == .frosted)
    }

    @Test func frostedAndSolidPassThroughTheFloorUnchanged() {
        // The floor raises `.clear` and touches nothing else: at Frosted/Solid the surface
        // underneath already backs the content, and stacking a second material would look heavy.
        #expect(GlassLevel.frosted.flooredForChrome == .frosted)
        #expect(GlassLevel.solid.flooredForChrome == .solid)
    }

    @Test func onlyClearNeedsChromeFrosting() {
        // Pins the property `chromeButtonStyle` reads, so a new level must decide its chrome
        // treatment here and can't silently render faint controls (or stack materials).
        #expect(GlassLevel.allCases.filter(\.needsChromeFrosting) == [.clear])
        // And the two escalations agree: the level that frosts its controls is the level whose
        // overlays get floored.
        for level in GlassLevel.allCases {
            #expect(level.needsChromeFrosting == (level.flooredForChrome != level))
        }
    }

    @Test(arguments: [false, true])
    func clearLightensTheOverlayScrim(dark: Bool) {
        // The cards above the scrim take Clear at face value, so a deeper scrim at Clear would
        // grey the window and hide the setting.
        #expect(GlassLevel.clear.overlayScrimOpacity(dark: dark) < GlassLevel.frosted.overlayScrimOpacity(dark: dark))
        #expect(GlassLevel.frosted.overlayScrimOpacity(dark: dark) == GlassLevel.solid.overlayScrimOpacity(dark: dark))
    }

    @Test func lightClearDimsNothingAndDarkClearStillDims() {
        // Any black over Light's near-white window reads as grey, even at 0.05; over Dark's deep
        // base it reads as depth and still focuses the card. Only Clear splits.
        #expect(GlassLevel.clear.overlayScrimOpacity(dark: false) == 0)
        #expect(GlassLevel.clear.overlayScrimOpacity(dark: true) > 0)
        #expect(GlassLevel.frosted.overlayScrimOpacity(dark: false) == GlassLevel.frosted.overlayScrimOpacity(dark: true))
    }

    @Test func clearGroundsTheCardAtLeastAsThickAsFrosted() {
        // At Clear the card is clear glass in both schemes, so its ground is all that keeps the
        // window behind from reading through the card's text. A thinner ground leaves the rows
        // behind readable through Settings. Frosted and Solid share theirs.
        #expect(GlassLevel.clear.groundedBackingOpacity >= GlassLevel.frosted.groundedBackingOpacity)
        #expect(GlassLevel.clear.groundedBackingOpacity < 1)
        #expect(GlassLevel.frosted.groundedBackingOpacity == GlassLevel.solid.groundedBackingOpacity)
    }

    @Test func onlyNoneInLightAtClearTakesTheWindowsGlass() {
        // Every accent keeps the panels' ground: its hue is what the window shows, and the ground
        // is neutral. None in light at Clear has no hue, so its panels take the window's own white
        // glass instead. Dark keeps its tinted ground at every accent.
        #expect(LiquidGlass.panelTakesWindowGlass(level: .clear, hue: .none, dark: false))
        #expect(!LiquidGlass.panelTakesWindowGlass(level: .clear, hue: .none, dark: true))
        #expect(!LiquidGlass.panelTakesWindowGlass(level: .frosted, hue: .none, dark: false))
        for hue in LiquidGlassHue.allCases where hue != .none {
            #expect(!LiquidGlass.panelTakesWindowGlass(level: .clear, hue: hue, dark: false), "\(hue)")
        }
    }

    // MARK: - Background intensity

    @Test func frostedKeepsTheRetiredSliderDefault() {
        // 0.65 is the retired `liquidGlassIntensity` default, so a migrated install's background
        // matches what it rendered at Tint 100; the Tint slider scales it fainter below that.
        #expect(GlassLevel.frosted.backgroundIntensity == 0.65)
    }

    @Test func backgroundIntensityIsOrderedAndInRange() {
        for level in GlassLevel.allCases {
            #expect((0.0...1.0).contains(level.backgroundIntensity))
        }
        #expect(GlassLevel.clear.backgroundIntensity < GlassLevel.frosted.backgroundIntensity)
        #expect(GlassLevel.frosted.backgroundIntensity < GlassLevel.solid.backgroundIntensity)
    }

    // MARK: - Explicit chrome

    @Test func solidAlwaysDrawsItsOwnChrome() {
        // Native Liquid Glass draws its own edge and shadow; an opaque panel has neither, so it
        // must supply them or it reads as a flat rectangle with no lift.
        #expect(GlassLevel.solid.needsExplicitChrome)
    }

    // MARK: - Raw values are a wire format

    /// Renaming a case compiles clean but silently resets every user's stored choice at the
    /// `?? .frosted` / `?? .blue` read sites, so the literal list is the pin, order included (new
    /// cases append). The unknown-value probes keep the fallbacks honest about being fallbacks.
    @Test func glassLevelRawValuesAreStable() {
        #expect(GlassLevel.allCases.map(\.rawValue) == ["clear", "frosted", "solid"])
        // With a synthesized `init(rawValue:)` these can only fail if a custom case-insensitive
        // one is added; they are tripwires for that, not coverage of the `?? .frosted` reads,
        // which live in private view properties this suite can't reach.
        #expect(GlassLevel(rawValue: "Frosted") == nil, "raw values are case-exact — a near-miss must fall back, not match")
        #expect(GlassLevel(rawValue: "medium") == nil)
    }

    @Test func liquidGlassHueRawValuesAreStable() {
        #expect(LiquidGlassHue.allCases.map(\.rawValue) ==
                ["none", "blue", "cyan", "teal", "green", "amber", "coral",
                 "rose", "purple", "indigo", "graphite"])
        #expect(LiquidGlassHue(rawValue: "Graphite") == nil)
        #expect(LiquidGlassHue(rawValue: "grey") == nil)
    }

    @Test func aStoredSlateMovesToGraphite() {
        // Slate is retired. An install that chose it gets the nearest neutral rather than reading
        // an unknown raw value as the Blue default, and the move happens once.
        let defaults = ScratchDefaults("GlassLevelTests.slate")
        defaults.set("slate", forKey: LiquidGlass.hueKey)
        let moved = LiquidGlass.migrateRetiredHue(defaults)
        #expect(moved?.from == "slate" && moved?.to == .graphite)
        #expect(defaults.string(forKey: LiquidGlass.hueKey) == LiquidGlassHue.graphite.rawValue)
        #expect(LiquidGlass.migrateRetiredHue(defaults) == nil, "a second launch rewrites nothing")

        defaults.set(LiquidGlassHue.teal.rawValue, forKey: LiquidGlass.hueKey)
        #expect(LiquidGlass.migrateRetiredHue(defaults) == nil)
        #expect(defaults.string(forKey: LiquidGlass.hueKey) == LiquidGlassHue.teal.rawValue)
        #expect(LiquidGlassHue(rawValue: "slate") == nil)
    }

    // MARK: - Shape is shape

    @Test func surfaceStyleIsShapeOnly() {
        // Solid is a material, so it lives on GlassLevel; as a shape too, "Solid" would mean two
        // different things in two pickers.
        #expect(SurfaceStyle.allCases.map(\.rawValue) == ["unified", "cards"])
        #expect(SurfaceStyle(rawValue: "solid") == nil)
    }

    @Test func everyLevelAndStyleIsLabelled() {
        for level in GlassLevel.allCases {
            #expect(!level.displayName.isEmpty)
        }
        for style in SurfaceStyle.allCases {
            #expect(!style.displayName.isEmpty)
        }
    }

    // MARK: - Gutter

    @Test func cardGutterIsVisibleButTight() {
        // Big enough to read as separation against the 14pt radius (3pt doesn't), small enough
        // not to make a dense file view airy.
        #expect(LiquidGlass.cardGutter >= 4)
        #expect(LiquidGlass.cardGutter <= 8)
    }

    // MARK: - Every card helper actually applies the inset
    //
    // Measured on the laid-out result: a card helper must grow its subject by exactly one gutter
    // (two half-gutter insets), so card↔card and card↔edge gaps agree.

    /// Lays a view out through a real `NSHostingView`, as the snapshot harness does, and reports
    /// the size SwiftUI settles on.
    @MainActor
    private func laidOutSize(_ view: some View) -> CGSize {
        NSHostingView(rootView: AnyView(view)).fittingSize
    }

    private static let subject = CGSize(width: 100, height: 40)

    @MainActor
    private func expectGrowsByOneGutter(_ decorated: some View, _ label: Comment) {
        let size = laidOutSize(decorated)
        #expect(size.width == Self.subject.width + LiquidGlass.cardGutter, label)
        #expect(size.height == Self.subject.height + LiquidGlass.cardGutter, label)
    }

    private var bare: some View {
        Color.clear.frame(width: Self.subject.width, height: Self.subject.height)
    }

    @MainActor
    @Test func bareSubjectMeasuresAtItsOwnSize() {
        // Pins the measurement itself, so a failure below can only mean the modifier.
        #expect(laidOutSize(bare) == Self.subject)
    }

    // Each of these sweeps every level rather than taking `@Test(arguments:)`, which would need
    // `GlassLevel: Sendable`, a production change to suit a test.

    @MainActor
    @Test func surfaceCardInsetsItselfByHalfAGutter() {
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(bare.surfaceCard(level), "surfaceCard at \(level)")
        }
    }

    @MainActor
    @Test func bottomSectionCardInsetsItselfInCards() {
        // DifferencesView stacks these at `spacing: 0`, relying on the helper's own inset.
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(
                bare.bottomSectionCard(.cards, level: level), "bottomSectionCard(.cards) at \(level)")
        }
    }

    // MARK: - Unified is one box

    @MainActor
    @Test func theWindowRegionIsUnifiedsOnlyInset() {
        // The one outline Unified draws, round everything under the toolbar, takes the window-edge
        // half of a gutter on every side, where a card's edge sits in Cards. Cards has no such
        // region at all.
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(
                bare.windowRegionFrame(.unified, level: level), "windowRegionFrame(.unified) at \(level)")
        }
        #expect(laidOutSize(bare.windowRegionFrame(.cards, level: .frosted)) == Self.subject)
    }

    @MainActor
    @Test func unifiedSectionsInsetNothing() {
        // Inside the window's one region, areas sit flush and meet at a hairline. An inset here
        // would be a gutter between two areas, which is a box per area.
        for level in GlassLevel.allCases {
            #expect(laidOutSize(bare.bottomSectionCard(.unified, level: level)) == Self.subject,
                    "bottomSectionCard(.unified) at \(level)")
            #expect(laidOutSize(bare.panesRegionFrame(.unified, level: level)) == Self.subject,
                    "panesRegionFrame(.unified) at \(level)")
        }
    }

    @MainActor
    @Test func twoUnifiedAreasSideBySideTouch() {
        // The end-to-end property: two neighbours, as the sidebar and the pane or Edit's rail and
        // document are laid, come to exactly their own widths: no gutter between, none outside.
        let row = HStack(spacing: 0) {
            bare.bottomSectionCard(.unified, level: .solid).unifiedSeam(.unified, edge: .trailing)
            bare.panesRegionFrame(.unified, level: .solid)
        }
        #expect(laidOutSize(row) == CGSize(width: Self.subject.width * 2, height: Self.subject.height))
    }

    @MainActor
    @Test func theSeamCostsNoRoom() {
        for style in SurfaceStyle.allCases {
            for edge in [Edge.top, .bottom, .leading, .trailing] {
                #expect(laidOutSize(bare.unifiedSeam(style, edge: edge)) == Self.subject, "\(style) \(edge)")
            }
        }
    }

    @MainActor
    @Test func theGutterIsCardsOnly() {
        // Layout arithmetic that reserves room for a gap reads this; a Cards gutter reserved in
        // Unified would be a blank strip beside the sidebar.
        #expect(LiquidGlass.gutter(.cards) == LiquidGlass.cardGutter)
        #expect(LiquidGlass.gutter(.unified) == 0)
    }

    @MainActor
    @Test func cardsOnlyHelpersAreNoOpsInUnified() {
        // `paneCardIfNeeded` no-ops in Unified, which keeps the provider-header split a Cards-only
        // idiom and makes Cards read as the more separated of the two styles.
        #expect(laidOutSize(bare.paneCardIfNeeded(.unified, level: .frosted)) == Self.subject)
        #expect(laidOutSize(bare.panesRegionFrame(.cards, level: .frosted)) == Self.subject)
    }

    @MainActor
    @Test func paneCardIfNeededInsetsItselfInCards() {
        expectGrowsByOneGutter(bare.paneCardIfNeeded(.cards, level: .frosted), "paneCardIfNeeded(.cards)")
    }

    @MainActor
    @Test func twoStackedCardsComeToExactlyOneGutter() {
        // The end-to-end property every bottom stack relies on: stacked at `spacing: 0`, two
        // sections' facing insets sum to one gutter and no more.
        let stack = VStack(spacing: 0) {
            bare.bottomSectionCard(.cards, level: .frosted)
            bare.bottomSectionCard(.cards, level: .frosted)
        }
        let height = laidOutSize(stack).height
        let cardHeight = Self.subject.height + LiquidGlass.cardGutter
        #expect(height == cardHeight * 2)
    }

    // MARK: - A workspace column: one rule in both styles

    /// A header section over a content section, stacked as every workspace column stacks them
    /// (the file pane aside, which has its own pair).
    @MainActor
    private func column(_ style: SurfaceStyle, level: GlassLevel) -> some View {
        VStack(spacing: 0) {
            bare.columnHeaderRule(style).columnSectionCard(style, level: level)
            bare.columnSectionCard(style, level: level)
        }
        .columnRegionFrame(style, level: level)
    }

    @MainActor
    @Test func aCardsColumnIsTwoCardsAGutterApart() {
        // The bottom stack's property: two cards, their facing insets summing to one gutter, and
        // the region adding nothing.
        for level in GlassLevel.allCases {
            let height = laidOutSize(column(.cards, level: level)).height
            #expect(height == Self.subject.height * 2 + LiquidGlass.cardGutter * 2, "cards at \(level)")
        }
    }

    @MainActor
    @Test func aUnifiedColumnIsOneAreaWithTheContentFlushUnderTheHeader() {
        // Nothing between the sections and nothing round them: the window's one region is the
        // frame. A column drawing per-section boxes in Unified would come to two gutters here, and
        // its content would start one gutter below the file list beside it.
        for level in GlassLevel.allCases {
            let height = laidOutSize(column(.unified, level: level)).height
            #expect(height == Self.subject.height * 2, "unified at \(level)")
        }
    }

    @MainActor
    @Test func theColumnHelpersAreEachOthersNoOps() {
        // In Cards the section helper is the frame and the region helper must be inert, or a
        // column would carry a card inside a card. In Unified neither insets: the window's one
        // region frames every column.
        #expect(laidOutSize(bare.columnSectionCard(.unified, level: .frosted)) == Self.subject)
        #expect(laidOutSize(bare.columnRegionFrame(.cards, level: .frosted)) == Self.subject)
        #expect(laidOutSize(bare.columnRegionFrame(.unified, level: .frosted)) == Self.subject)
        expectGrowsByOneGutter(bare.columnSectionCard(.cards, level: .frosted), "columnSectionCard(.cards)")
    }

    @MainActor
    @Test func theHeaderRuleCostsNoHeight() {
        // Drawn over the header's edge, so the content starts where it would without it.
        for style in SurfaceStyle.allCases {
            #expect(laidOutSize(bare.columnHeaderRule(style)) == Self.subject, "\(style)")
        }
    }
}
