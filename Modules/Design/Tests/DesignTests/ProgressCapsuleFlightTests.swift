import CoreGraphics
import Testing
@testable import Design

/// The path a capsule message's ring takes into the Activity button.
@Suite struct ProgressCapsuleFlightTests {
    // The toolbar's two ends as the panel sees them: the capsule in the middle, Activity to the
    // right, both on the toolbar's centre line (top-left origin).
    private let capsule = CGPoint(x: 590, y: 26)
    private let activity = CGPoint(x: 1144, y: 26)

    @Test func thePathStartsAtTheCapsuleAndEndsOnTheButton() {
        #expect(ProgressCapsuleFlight.point(at: 0, from: capsule, to: activity) == capsule)
        #expect(ProgressCapsuleFlight.point(at: 1, from: capsule, to: activity) == activity)
        // Clamped, so an overshooting spring could never fly it past the button.
        #expect(ProgressCapsuleFlight.point(at: 1.2, from: capsule, to: activity) == activity)
    }

    @Test func itDipsBelowTheToolbarItemsInsteadOfRunningThroughThem() {
        let middle = ProgressCapsuleFlight.point(at: 0.5, from: capsule, to: activity)
        #expect(middle.y > max(capsule.y, activity.y) + 10)
        // Never further than the dip itself.
        #expect(middle.y <= max(capsule.y, activity.y) + ProgressCapsuleFlight.dip)
    }

    @Test func itOnlyEverMovesTowardTheButton() {
        var last = capsule.x
        for step in 1...20 {
            let x = ProgressCapsuleFlight.point(at: Double(step) / 20, from: capsule, to: activity).x
            #expect(x >= last)
            last = x
        }
    }

    @Test func itShrinksOnTheWayAndFadesOnlyAtTheEnd() {
        #expect(ProgressCapsuleFlight.scale(at: 0) == 1)
        #expect(ProgressCapsuleFlight.scale(at: 1) == ProgressCapsuleFlight.endScale)
        #expect(ProgressCapsuleFlight.opacity(at: 0) == 1)
        #expect(ProgressCapsuleFlight.opacity(at: ProgressCapsuleFlight.fadeFrom) == 1)
        #expect(ProgressCapsuleFlight.opacity(at: 1) == 0)
    }
}
