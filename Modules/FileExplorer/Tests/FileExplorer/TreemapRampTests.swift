import Testing
import SwiftUI
import AppKit
import Sync
import Design
@testable import FileExplorer

/// **The treemap's sequential ramp.**
///
/// The ramp replaced a rotating ten-hue palette assigned by index, and it makes one promise the
/// palette never did: *colour is the ranking*. That promise is a numeric property — luminance rises
/// with position — and it is the only thing here a reader can be misled by, so it is asserted
/// directly rather than inferred from a rendered tile.
///
/// The second half is what the palette needed a parallel table for. The old `labelPalette` was ten
/// precomputed label colours for ten fixed fills; a ramp has as many fills as tiles, so the pairing
/// has to be computed per tile, and these check it lands where the fixed table used to.
@Suite struct TreemapRampTests {

    /// Every hue the settings offer, including the two the palette never contained.
    private var hues: [LiquidGlassHue] { LiquidGlassHue.allCases }

    @Test func theRampRisesInLuminanceForEveryHueSoColourReadsAsRank() {
        for hue in hues {
            let ramp = TreemapView.ramp(hue, count: 8)
            #expect(ramp.count == 8, "\(hue) produced \(ramp.count) steps")
            let luminances = ramp.map { luminance(of: srgb($0)) }
            for i in 1..<luminances.count {
                #expect(luminances[i] > luminances[i - 1],
                        "\(hue) step \(i) (\(luminances[i])) is not lighter than step \(i - 1) (\(luminances[i - 1]))")
            }
        }
    }

    /// The deep end is the hue itself, not an invented dark version of it — which is what keeps
    /// amber recognisably amber instead of the brown an absolute luminance band would force.
    @Test func theFirstStepIsTheHuesOwnAccent() {
        for hue in hues where hue != .none {
            let first = srgb(TreemapView.ramp(hue, count: 6)[0])
            let accent = srgb(hue.accentColor)
            #expect(abs(first.redComponent - accent.redComponent) < 0.01
                    && abs(first.greenComponent - accent.greenComponent) < 0.01
                    && abs(first.blueComponent - accent.blueComponent) < 0.01,
                    "\(hue)'s deepest tile is not its accent")
        }
    }

    /// `.none` is the *system* accent — a dynamic colour, which resolves to whatever appearance is
    /// current when its components are read and never re-resolves. The ramp substitutes blue, and
    /// this is the assertion that says so out loud: a future edit that "simplifies" the special
    /// case away reintroduces a colour that silently freezes.
    @Test func theSystemAccentIsSubstitutedBecauseItIsDynamic() {
        let none = srgb(TreemapView.ramp(.none, count: 5)[0])
        let blue = srgb(LiquidGlassHue.blue.accentColor)
        #expect(abs(none.redComponent - blue.redComponent) < 0.01
                && abs(none.greenComponent - blue.greenComponent) < 0.01
                && abs(none.blueComponent - blue.blueComponent) < 0.01)
    }

    /// The plan for this item said the ramp *dissolves* the contrast problem, because "the pale
    /// end lands on the small tiles, which carry no labels anyway". It does not: the fold floors
    /// the smallest visible tile at `labelMinWidth`, which is precisely the width at which a tile
    /// starts drawing its name. So every step, palest included, has to carry a label.
    @Test func everyStepCarriesItsLabelAtLargeTextContrast() {
        for hue in hues {
            for count in [1, 2, 5, 12] {
                for (index, step) in TreemapView.ramp(hue, count: count).enumerated() {
                    let fill = srgb(step)
                    let label = srgb(Color.onFillLabel(step))
                    let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
                    #expect(ratio >= 3.0,
                            "\(hue) step \(index) of \(count) pairs at \(ratio):1, under the 3:1 large-text floor")
                }
            }
        }
    }

    /// The palest steps really do cross the pairing's threshold — otherwise this whole suite would
    /// be measuring white-on-dark twelve times and the per-tile pairing would be dead code kept
    /// alive by a green test. Blue is the default hue and the one the old palette led with.
    @Test func thePaleEndOfTheRampIsWhereTheLabelFlipsToDarkText() {
        let ramp = TreemapView.ramp(.blue, count: 8)
        #expect(Color.onFillLabel(ramp[0]) == Color.white, "the accent itself should keep white text")
        let flips = ramp.filter { Color.onFillLabel($0) != Color.white }
        #expect(!flips.isEmpty, "no step in the ramp is light enough to need dark text — the ramp is not ramping")
    }

    /// Degenerate counts: a one-tile treemap gets the accent, and a zero-tile one gets nothing
    /// rather than a crash on `count - 1`.
    @Test func aSingleTileTakesTheAccentAndZeroTilesTakeNothing() {
        #expect(TreemapView.ramp(.teal, count: 0).isEmpty)
        let one = TreemapView.ramp(.teal, count: 1)
        #expect(one.count == 1)
        #expect(abs(luminance(of: srgb(one[0])) - luminance(of: srgb(LiquidGlassHue.teal.accentColor))) < 0.001)
    }

    // MARK: - Contrast helpers (mirroring `AccentLabelColorTests`, which cannot be imported)

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    private func composite(_ label: NSColor, over fill: NSColor) -> NSColor {
        let a = label.alphaComponent
        func blend(_ l: CGFloat, _ f: CGFloat) -> CGFloat { l * a + f * (1 - a) }
        return NSColor(srgbRed: blend(label.redComponent, fill.redComponent),
                       green: blend(label.greenComponent, fill.greenComponent),
                       blue: blend(label.blueComponent, fill.blueComponent), alpha: 1)
    }

    private func luminance(of color: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: color.redComponent,
                                      green: color.greenComponent, blue: color.blueComponent)
    }

    private func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let (hi, lo) = (max(a, b), min(a, b))
        return (hi + 0.05) / (lo + 0.05)
    }
}
