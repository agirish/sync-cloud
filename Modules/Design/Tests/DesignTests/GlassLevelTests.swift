import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Design

/// The Appearance model's two controls and the migration onto them.
///
/// These pin the fix for the bug that motivated the rework: a stored intensity of 0.15 fell below
/// `glassCardStyle`'s `> 0.33` threshold, so the Settings modal resolved to `.clear` glass and the
/// app behind it read straight through — its only fill was the ~9% accent tint wash.
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
        // Pins the branch `chromeButtonStyle` keys off — the property that helper actually
        // reads, so a level added later must decide its chrome treatment here and can't silently
        // render faint controls (or stack materials) on its cards.
        #expect(GlassLevel.allCases.filter(\.needsChromeFrosting) == [.clear])
        // And the two escalations agree: the level that frosts its controls is the level whose
        // overlays get floored.
        for level in GlassLevel.allCases {
            #expect(level.needsChromeFrosting == (level.flooredForChrome != level))
        }
    }

    @Test func flooringIsIdempotent() {
        for level in GlassLevel.allCases {
            #expect(level.flooredForChrome.flooredForChrome == level.flooredForChrome)
        }
    }

    @Test func clearDeepensTheOverlayScrim() {
        // Apple's guidance for `.clear` glass is to pair it with a dimming layer. The card is
        // floored to frosted; pushing the app further back is what makes it read cleanly.
        #expect(GlassLevel.clear.overlayScrimOpacity > GlassLevel.frosted.overlayScrimOpacity)
        #expect(GlassLevel.frosted.overlayScrimOpacity == GlassLevel.solid.overlayScrimOpacity)
    }

    // MARK: - Background intensity

    @Test func frostedKeepsTheRetiredSliderDefault() {
        // 0.65 was the old `liquidGlassIntensity` default, so a migrated install's window
        // background is pixel-identical to what it rendered before the rework.
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

    // MARK: - Shape is shape

    @Test func surfaceStyleIsShapeOnly() {
        // `solid` was a material answer inside the shape control: it silently overrode the glass
        // setting, so "Solid" meant two different things in two pickers. It lives on GlassLevel now.
        #expect(SurfaceStyle.allCases.map(\.rawValue) == ["unified", "cards"])
        #expect(SurfaceStyle(rawValue: "solid") == nil)
    }

    @Test func everyLevelAndStyleIsLabelledAndExplained() {
        for level in GlassLevel.allCases {
            #expect(!level.displayName.isEmpty)
            #expect(!level.detail.isEmpty)
        }
        for style in SurfaceStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
        }
    }

    // MARK: - Migration

    /// A defaults suite scoped to one test, so migrations can't leak into the real domain. A fresh
    /// UUID suite is already empty, and it removes itself — domain and plist — on release.
    private func makeDefaults() -> ScratchDefaults {
        ScratchDefaults("GlassLevelTests")
    }

    @Test func anyStoredIntensityBecomesFrosted() {
        // The old value can't be read as a number: `surfaceCard` hard-coded `.regular` and ignored
        // it, so the panes rendered frosted at EVERY setting. Frosted preserves what installs
        // actually looked like — including this user's 0.15, which is what surfaced the bug.
        for intensity in [0.0, 0.15, 0.33, 0.65, 1.0] {
            let d = makeDefaults()
            d.set(intensity, forKey: LiquidGlass.intensityKey)
            LiquidGlass.migrateLegacyAppearance(d)
            #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.frosted.rawValue)
        }
    }

    @Test func storedIntensityIsClearedOut() {
        let d = makeDefaults()
        d.set(0.15, forKey: LiquidGlass.intensityKey)
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.object(forKey: LiquidGlass.intensityKey) == nil)
    }

    @Test func retiredSolidSurfaceStyleBecomesSolidGlassOnUnified() {
        // A stored `SurfaceStyle.solid` was a material choice. It becomes `GlassLevel.solid` with
        // the shape reset to unified — which is what those installs already rendered, since the
        // opaque fill hid whether cards floated underneath.
        let d = makeDefaults()
        d.set("solid", forKey: LiquidGlass.surfaceStyleKey)
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.solid.rawValue)
        #expect(d.string(forKey: LiquidGlass.surfaceStyleKey) == SurfaceStyle.unified.rawValue)
    }

    @Test func cardsSurfaceStyleSurvivesMigration() {
        // Shape is orthogonal to material: migrating the material must not disturb it.
        let d = makeDefaults()
        d.set("cards", forKey: LiquidGlass.surfaceStyleKey)
        d.set(0.15, forKey: LiquidGlass.intensityKey)
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.string(forKey: LiquidGlass.surfaceStyleKey) == SurfaceStyle.cards.rawValue)
        #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.frosted.rawValue)
    }

    @Test func migrationNeverOverwritesAChosenLevel() {
        // Runs on every launch (App.init can re-run), so it must be a no-op once the key exists —
        // otherwise it would stamp Frosted back over the user's pick on the next launch.
        let d = makeDefaults()
        d.set(GlassLevel.clear.rawValue, forKey: LiquidGlass.levelKey)
        d.set(0.9, forKey: LiquidGlass.intensityKey)
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.clear.rawValue)
    }

    @Test func migrationIsIdempotent() {
        let d = makeDefaults()
        d.set("solid", forKey: LiquidGlass.surfaceStyleKey)
        LiquidGlass.migrateLegacyAppearance(d)
        LiquidGlass.migrateLegacyAppearance(d)
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.solid.rawValue)
        #expect(d.string(forKey: LiquidGlass.surfaceStyleKey) == SurfaceStyle.unified.rawValue)
    }

    @Test func freshInstallLandsOnFrosted() {
        // Nothing stored at all: the standard Liquid Glass material, matching the @AppStorage
        // defaults every view declares.
        let d = makeDefaults()
        LiquidGlass.migrateLegacyAppearance(d)
        #expect(d.string(forKey: LiquidGlass.levelKey) == GlassLevel.frosted.rawValue)
        #expect(GlassLevel(rawValue: d.string(forKey: LiquidGlass.levelKey)!) == .frosted)
    }

    // MARK: - Gutter

    @Test func cardInsetIsHalfAGutterSoEveryGapMatches() {
        // The gaps used to be non-uniform by construction: a card padded ITSELF by the full gutter,
        // so two touching cards showed 2x what a window edge showed, and the bottom stack
        // hard-coded a third value. Halving it is what makes card↔card and card↔edge agree —
        // each pairing contributes two insets.
        #expect(LiquidGlass.cardInset * 2 == LiquidGlass.cardGutter)
    }

    @Test func cardGutterIsVisibleButTight() {
        // Big enough to read as separation against the 14pt radius (3pt did not), small enough not
        // to make a dense file view airy.
        #expect(LiquidGlass.cardGutter >= 4)
        #expect(LiquidGlass.cardGutter <= 8)
    }

    // MARK: - Every card helper actually applies the inset
    //
    // `cardInsetIsHalfAGutterSoEveryGapMatches` above only checks arithmetic on the constant. It
    // stayed green for the whole time `bottomSectionCard` applied no inset at all — the Differences,
    // Tidy and Storage stacks rendered flush at 0 and nothing failed. These measure the laid-out
    // result instead: a card helper must grow its subject by exactly one gutter (two insets), which
    // is the property the gap model actually depends on.

    /// Lays a view out through a real `NSHostingView` — the same path the snapshot harness uses —
    /// and reports the size SwiftUI settles on.
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
    // `GlassLevel: Sendable` — a production change to suit a test.

    @MainActor
    @Test func surfaceCardInsetsItselfByHalfAGutter() {
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(bare.surfaceCard(level), "surfaceCard at \(level)")
        }
    }

    @MainActor
    @Test func bottomSectionCardInsetsItselfInCards() {
        // The regression: this helper was the only one 62ef02d never gave an inset, while
        // DifferencesView had already dropped to `spacing: 0` on the promise that it had one.
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(
                bare.bottomSectionCard(.cards, level: level), "bottomSectionCard(.cards) at \(level)")
        }
    }

    @MainActor
    @Test func bottomSectionCardInsetsItselfInUnified() {
        // Unified frames its panes region with `panesRegionFrame`, which does inset — so without
        // this the bottom stack sat 2.5 wider per side than the panes above it.
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(
                bare.bottomSectionCard(.unified, level: level), "bottomSectionCard(.unified) at \(level)")
        }
    }

    @MainActor
    @Test func panesRegionFrameInsetsItselfInUnified() {
        for level in GlassLevel.allCases {
            expectGrowsByOneGutter(
                bare.panesRegionFrame(.unified, level: level), "panesRegionFrame(.unified) at \(level)")
        }
    }

    @MainActor
    @Test func cardsOnlyHelpersAreNoOpsInUnified() {
        // `paneCardIfNeeded` no-ops in Unified — which is what keeps the provider-header split a
        // Cards-only idiom, and what makes Cards read as the more separated of the two styles.
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
        // Total padding across the stack is two gutters, laid out as: half a gutter above, the two
        // facing insets meeting as one full gutter between the subjects, half a gutter below. That
        // decomposition is what makes card↔card and card↔window-edge agree. Pre-fix this was 0.
        #expect(height - Self.subject.height * 2 == LiquidGlass.cardGutter * 2)
    }
}
