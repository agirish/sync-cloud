import Testing
import Foundation
import SwiftUI
@testable import Design

/// The Tint slider's two curves — see "The Tint slider's curve" in `LiquidGlassStyle`.
///
/// The property these pin is the one that made the change safe to make: **Tint 100 paints exactly
/// what it painted before.** Every constant the background and the wash multiply is untouched, so
/// as long as both curves return 1 at the top of the slider, the change is confined to the range
/// below it. A curve that quietly returned 0.98 there would rescale the whole app's ceiling and
/// nothing else in the suite would notice.
struct TintCurveTests {

    // MARK: - The ceiling is untouched

    @Test func bothCurvesReachExactlyOneAtFullTint() {
        #expect(LiquidGlass.tintRamp(1.0) == 1.0)
        #expect(LiquidGlass.backgroundHueStrength(forTint: 1.0) == 1.0)
    }

    @Test func theWashStillTopsOutAtItsOldStrength() {
        // `contentSurface` paints `tintRamp(tint) * 0.32`. The 0.32 is unchanged, so this is the
        // whole of what the surfaces get at 100% — the same accent opacity as before the curve.
        #expect(LiquidGlass.tintRamp(1.0) * 0.32 == 0.32)
    }

    // MARK: - The floor

    @Test func theBackgroundKeepsAQuarterOfItsHueAtZero() {
        // Not zero: the accent picker has to keep meaning something at the bottom of the slider.
        #expect(LiquidGlass.backgroundHueStrength(forTint: 0) == LiquidGlass.tintFloor)
        #expect(LiquidGlass.tintFloor > 0)
        #expect(LiquidGlass.tintFloor < 0.5)
    }

    @Test func theSurfaceWashStartsAtNothing() {
        // The *wash* has no floor — at 0% a pane is the background rather than a wash over it.
        // That is the half of the pair that makes 0% subtle; the floor above is the half that
        // keeps it coloured.
        #expect(LiquidGlass.tintRamp(0) == 0)
    }

    @Test func zeroIsMuchFainterThanItUsedToBe() {
        // The complaint this fixes, as a number. Before, Tint 0 painted the background at full
        // strength (the slider only moved the surface wash); now it paints a quarter of it. Stated
        // as a ratio rather than a colour because the constants it multiplies are free to change.
        #expect(LiquidGlass.backgroundHueStrength(forTint: 0) <= 0.3)
    }

    // MARK: - Shape

    @Test func theRampIsMonotonicAndInRange() {
        var previous = -1.0
        for step in 0...100 {
            let value = LiquidGlass.tintRamp(Double(step) / 100.0)
            #expect(value > previous, "tint \(step)% went backwards")
            #expect((0.0...1.0).contains(value))
            previous = value
        }
    }

    @Test func theBackgroundStrengthIsMonotonicAndInRange() {
        var previous = -1.0
        for step in 0...100 {
            let value = LiquidGlass.backgroundHueStrength(forTint: Double(step) / 100.0)
            #expect(value > previous, "tint \(step)% went backwards")
            #expect((0.0...1.0).contains(value))
            previous = value
        }
    }

    @Test func theCurveSpendsMorePrecisionOnTheSubtleEnd() {
        // The other half of the ask: the bottom of the slider should move slowly, so a subtle
        // setting can be dialled in. Below the midpoint the ramp travels less than a linear one
        // would; above it, more. `tintCurve > 1` is what does this — a linear ramp would make both
        // of these equalities, and this test is what says the exponent is still doing its job.
        #expect(LiquidGlass.tintRamp(0.5) < 0.5)
        #expect(LiquidGlass.tintCurve > 1.0)
        // But mild enough that the percentage readout is not a lie: half the slider still paints
        // at least a third of full strength.
        #expect(LiquidGlass.tintRamp(0.5) > 1.0 / 3.0)
    }

    // MARK: - Out of range

    @Test func valuesOutsideTheSliderAreClamped() {
        // `@AppStorage` will hand back whatever is in the defaults domain, including a value a
        // previous build (or `defaults write`) put there — the clamp is what keeps that from
        // becoming a negative opacity, which SwiftUI does not reject.
        #expect(LiquidGlass.tintRamp(-1) == 0)
        #expect(LiquidGlass.tintRamp(2) == 1)
        #expect(LiquidGlass.backgroundHueStrength(forTint: -1) == LiquidGlass.tintFloor)
        #expect(LiquidGlass.backgroundHueStrength(forTint: 2) == 1.0)
    }
}
