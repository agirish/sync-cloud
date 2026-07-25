import Testing
import SwiftUI
@testable import Design

/// The action bar's three weights. Asserted from the metrics table rather than a rendered pixel:
/// `.glassEffect` renders nothing offscreen, so a snapshot of these would bless a blank capsule.
@Suite struct ActionBarButtonStyleTests {

    @Test func testWeightsFormAStrictLadder() {
        // Primary is the only full-strength fill; quiet is a wash; outline has none. A change that
        // narrowed the gap would put the bar back where it started — three capsules of one weight.
        #expect(ActionBarWeight.primary.fillOpacity == 1)
        #expect(ActionBarWeight.quiet.fillOpacity == PillVariant.fillOpacity)
        #expect(ActionBarWeight.outline.fillOpacity == 0)
        #expect(ActionBarWeight.primary.fillOpacity > ActionBarWeight.quiet.fillOpacity)
        #expect(ActionBarWeight.quiet.fillOpacity > ActionBarWeight.outline.fillOpacity)
    }

    @Test func testQuietWeightIsThePillRecipeInButtonForm() {
        // Not a fourth surface: a quiet button and a count pill sitting beside it are the same
        // wash and the same hairline, so the bar reads as one system.
        #expect(ActionBarWeight.quiet.fillOpacity == PillVariant.fillOpacity)
        #expect(ActionBarWeight.quiet.strokeOpacity == PillVariant.strokeOpacity)
        #expect(ActionBarMetrics.strokeWidth == PillVariant.strokeWidth)
        #expect(!ActionBarWeight.quiet.strokesInInk)
    }

    @Test func testOnlyOutlineStrokesInNeutralInk() {
        // Tinting the outline's border would make it read as a third coloured weight next to quiet.
        #expect(ActionBarWeight.outline.strokesInInk)
        #expect(!ActionBarWeight.primary.strokesInInk)
        #expect(!ActionBarWeight.quiet.strokesInInk)
    }

    @Test func testPrimaryCarriesNoRestingHairline() {
        // A stroke over a full-strength fill only muddies its edge.
        #expect(ActionBarWeight.primary.strokeOpacity == 0)
    }

    @Test func testHoverVariantMatchesWhetherTheWeightHasAFill() {
        // The tinted weights have something to ring and lift; outline has only a wash to offer.
        #expect(ActionBarWeight.primary.hoverVariant == .filled)
        #expect(ActionBarWeight.quiet.hoverVariant == .filled)
        #expect(ActionBarWeight.outline.hoverVariant == .segment)
    }

    @Test func testEveryWeightRestsWithSomeVisibleEdgeOrFill() {
        // A weight that rested completely invisible would be a button you find by clicking where
        // one might be — the thing HoverAffordance was added to end.
        for weight in ActionBarWeight.allCases {
            #expect(weight.fillOpacity > 0 || weight.strokeOpacity > 0,
                    "\(weight) rests with nothing drawn")
        }
    }

    @Test func testIconOnlyControlIsSquareAndThereforeCircular() {
        // The capsule clip turns a square into a circle; the ⋯ and the collapsed filter rely on it
        // to sit in the row without reading as a stubby pill.
        #expect(ActionBarMetrics.height > 0)
        #expect(ActionBarMetrics.horizontalPadding < ActionBarMetrics.height)
    }

    @Test func testDividerIsShorterThanTheControlsItSeparates() {
        // A full-height rule reads as a border around a group rather than a seam between two.
        #expect(ActionBarMetrics.dividerHeight < ActionBarMetrics.height)
    }
}
