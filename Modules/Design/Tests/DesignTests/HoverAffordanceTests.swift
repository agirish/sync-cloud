import SwiftUI
import XCTest
@testable import Design

/// The affordance is a table of numbers, so it's tested as one. These assert the *properties*
/// the design rests on (nothing grows on hover, disabled stays inert, press always reads as
/// deeper than hover) rather than restating each constant — a test that only echoes the
/// literal it reads passes just as happily when the literal is wrong.
final class HoverAffordanceTests: XCTestCase {

    private let allVariants = HoverAffordanceVariant.allCases

    // MARK: - Rest

    func testEveryVariantIsCompletelyInertAtRest() {
        for variant in allVariants {
            XCTAssertEqual(HoverAffordanceMetrics.resolve(variant: variant, phase: .rest),
                           .none, "\(variant) paints something at rest")
        }
    }

    // MARK: - Hover

    func testEveryVariantChangesVisiblyOnHover() {
        for variant in allVariants {
            let hover = HoverAffordanceMetrics.resolve(variant: variant, phase: .hover)
            XCTAssertNotEqual(hover, .none, "\(variant) is invisible on hover — the whole point")
        }
    }

    func testHoverNeverGrowsTheTarget() {
        // A control that widens under a pointer already resting on it moves its own edges out
        // from under the click. Lift is allowed; scale is not.
        for variant in allVariants {
            let hover = HoverAffordanceMetrics.resolve(variant: variant, phase: .hover)
            XCTAssertEqual(hover.scale, 1, accuracy: 0.0001,
                           "\(variant) scales on hover")
        }
    }

    func testFilledCarriesNoWashBecauseItsOwnFillOccupiesTheShape() {
        let hover = HoverAffordanceMetrics.resolve(variant: .filled, phase: .hover)
        XCTAssertEqual(hover.wash, 0, "a wash under a solid fill is wasted paint")
        XCTAssertGreaterThan(hover.ring, 0, "filled has nothing but the ring and lift to speak with")
        XCTAssertLessThan(hover.lift, 0)
    }

    func testRowWashesMoreQuietlyThanGlyph() {
        // The row covers an order of magnitude more pixels; matching the glyph's alpha would
        // make a settings list flash on every pointer crossing.
        let row = HoverAffordanceMetrics.resolve(variant: .row, phase: .hover)
        let glyph = HoverAffordanceMetrics.resolve(variant: .glyph, phase: .hover)
        XCTAssertLessThan(row.wash, glyph.wash)
    }

    func testOnlyFloatingVariantsLift() {
        // Lift implies a shadow to sit above, and only two variants are meant to leave the plane.
        for variant in allVariants {
            let hover = HoverAffordanceMetrics.resolve(variant: variant, phase: .hover)
            let floats = (variant == .filled || variant == .circular)
            XCTAssertEqual(hover.lift < 0, floats, "\(variant) lift disagrees with its role")
            XCTAssertEqual(hover.shadow > 0, floats, "\(variant) shadow disagrees with its lift")
        }
    }

    // MARK: - Pressed

    func testPressReadsDeeperThanHoverEverywhere() {
        for variant in allVariants {
            let hover = HoverAffordanceMetrics.resolve(variant: variant, phase: .hover)
            let pressed = HoverAffordanceMetrics.resolve(variant: variant, phase: .pressed)
            // Either the wash deepens or the control sinks — a press that looked identical to
            // hover would leave the click unacknowledged.
            let deepens = pressed.wash > hover.wash
            let sinks = pressed.scale < hover.scale
            XCTAssertTrue(deepens || sinks, "\(variant) press is indistinguishable from hover")
        }
    }

    func testPressNeverLifts() {
        // Pressing sinks. `.filled` and `.circular` hover a point above the plane and must
        // return to it under the pointer, not climb further.
        for variant in allVariants {
            let pressed = HoverAffordanceMetrics.resolve(variant: variant, phase: .pressed)
            XCTAssertGreaterThanOrEqual(pressed.lift, 0, "\(variant) lifts while pressed")
        }
    }

    func testPressScaleStaysWithinAHairOfFullSize() {
        for variant in allVariants {
            let pressed = HoverAffordanceMetrics.resolve(variant: variant, phase: .pressed)
            XCTAssertLessThanOrEqual(pressed.scale, 1)
            XCTAssertGreaterThanOrEqual(pressed.scale, 0.95, "\(variant) press is a bounce, not a shrink")
        }
    }

    // MARK: - Disabled

    func testDisabledIsInertInEveryPhase() {
        // SwiftUI keeps delivering onHover to a disabled button, so this guard is what stops a
        // greyed-out control from glowing under the pointer.
        for variant in allVariants {
            for phase in [HoverAffordancePhase.rest, .hover, .pressed] {
                XCTAssertEqual(
                    HoverAffordanceMetrics.resolve(variant: variant, phase: phase, isEnabled: false),
                    .none, "\(variant) reacts to \(phase) while disabled")
            }
        }
    }

    // MARK: - Reduce Motion

    func testReduceMotionDropsMovementAndKeepsColor() {
        for variant in allVariants {
            for phase in [HoverAffordancePhase.hover, .pressed] {
                let plain = HoverAffordanceMetrics.resolve(variant: variant, phase: phase)
                let reduced = HoverAffordanceMetrics.resolve(variant: variant, phase: phase,
                                                             reduceMotion: true)
                XCTAssertEqual(reduced.lift, 0, "\(variant)/\(phase) still moves")
                XCTAssertEqual(reduced.scale, 1, accuracy: 0.0001, "\(variant)/\(phase) still scales")
                XCTAssertEqual(reduced.wash, plain.wash, "\(variant)/\(phase) lost its wash")
                XCTAssertEqual(reduced.ring, plain.ring, "\(variant)/\(phase) lost its ring")
            }
        }
    }

    func testReduceMotionLeavesEveryVariantWithSomethingToShow() {
        // The failure this guards: a variant whose entire hover is a lift would go completely
        // silent under Reduce Motion, which is exactly the state we started from.
        for variant in allVariants {
            let hover = HoverAffordanceMetrics.resolve(variant: variant, phase: .hover,
                                                       reduceMotion: true)
            XCTAssertNotEqual(hover, .none, "\(variant) vanishes entirely under Reduce Motion")
        }
    }

    // MARK: - Shapes

    func testEveryVariantHasADefaultShape() {
        let expected: [HoverAffordanceVariant: HoverAffordanceShape] = [
            .glyph: .roundedRect(8), .segment: .capsule, .filled: .capsule,
            .circular: .circle, .row: .roundedRect(7), .inline: .circle
        ]
        for variant in allVariants {
            XCTAssertEqual(HoverAffordanceShape.default(for: variant), expected[variant],
                           "\(variant) default shape drifted")
        }
    }

    // MARK: - Phase

    func testOnlyRestIsDisengaged() {
        XCTAssertFalse(HoverAffordancePhase.rest.isEngaged)
        XCTAssertTrue(HoverAffordancePhase.hover.isEngaged)
        XCTAssertTrue(HoverAffordancePhase.pressed.isEngaged)
    }
}
