import SwiftUI
import Testing
@testable import Design

/// The arithmetic behind resizing a centred floating card — the Help card's rule, now shared with
/// the Compare Copies overlay.
///
/// **The sign table is the whole point.** `.leading` grows the card when dragged LEFT, which is
/// the one thing a hand-rolled resize gets backwards, and it is now written once instead of twice.
@Suite struct ResizableCardTests {

    private let floor = CGSize(width: 100, height: 80)
    private let room = CGSize(width: 2000, height: 2000)
    private let start = CGSize(width: 400, height: 300)

    // MARK: Directions

    /// Dragging the trailing edge right grows the card; dragging the leading edge right SHRINKS
    /// it. Both by twice the translation, because the card is centred.
    @Test func theHorizontalGripsPullInOppositeDirections() {
        let right = ResizableCardSize.resized(from: start, by: CGSize(width: 10, height: 0),
                                              grip: .trailing, minimum: floor, within: room)
        #expect(right.width == 420)
        let left = ResizableCardSize.resized(from: start, by: CGSize(width: 10, height: 0),
                                             grip: .leading, minimum: floor, within: room)
        #expect(left.width == 380)
        #expect(right.height == start.height, "a horizontal grip moved the height")
        #expect(left.height == start.height)
    }

    @Test func theVerticalGripsPullInOppositeDirections() {
        let down = ResizableCardSize.resized(from: start, by: CGSize(width: 0, height: 10),
                                             grip: .bottom, minimum: floor, within: room)
        #expect(down.height == 320)
        let up = ResizableCardSize.resized(from: start, by: CGSize(width: 0, height: 10),
                                           grip: .top, minimum: floor, within: room)
        #expect(up.height == 280)
        #expect(down.width == start.width, "a vertical grip moved the width")
    }

    /// **The doubling is what keeps the pointer on the grip.** The card is centred, so half of any
    /// growth goes to each side: to move an edge 10pt the width has to grow 20. Adding the
    /// translation once would leave the edge drifting at half the pointer's speed.
    @Test func aDragMovesTheEdgeByExactlyTheTranslation() {
        let grown = ResizableCardSize.resized(from: start, by: CGSize(width: 25, height: 0),
                                              grip: .trailing, minimum: floor, within: room)
        #expect((grown.width - start.width) / 2 == 25,
                "the trailing edge moved \((grown.width - start.width) / 2)pt for a 25pt drag")
    }

    /// A corner moves both axes; an edge moves one. Asserted over the whole enum so a new case
    /// cannot be added with a silently missing direction.
    @Test func everyGripsAxesMatchItsName() {
        for grip in ResizableCardGrip.allCases {
            let moved = ResizableCardSize.resized(from: start, by: CGSize(width: 10, height: 10),
                                                  grip: grip, minimum: floor, within: room)
            #expect((moved.width != start.width) == (grip.horizontal != 0), "\(grip) width")
            #expect((moved.height != start.height) == (grip.vertical != 0), "\(grip) height")
            #expect(grip.isCorner == (grip.horizontal != 0 && grip.vertical != 0), "\(grip) corner")
        }
    }

    /// The alignment and the direction describe the same edge. A `.leading` grip drawn at
    /// `.trailing` would resize the card from the side the pointer is not on.
    /// Compared against the real `HorizontalAlignment`/`VerticalAlignment` values, not against a
    /// description: `Alignment`'s `debugDescription` is opaque key bits, so a string match there
    /// fails on every case and would have to be deleted rather than fixed.
    @Test func everyGripsAlignmentAgreesWithItsDirection() {
        for grip in ResizableCardGrip.allCases {
            let expectedH: HorizontalAlignment = grip.horizontal == 1 ? .trailing
                : grip.horizontal == -1 ? .leading : .center
            let expectedV: VerticalAlignment = grip.vertical == 1 ? .bottom
                : grip.vertical == -1 ? .top : .center
            #expect(grip.alignment.horizontal == expectedH,
                    "\(grip) is drawn on the wrong side of the card")
            #expect(grip.alignment.vertical == expectedV,
                    "\(grip) is drawn on the wrong edge of the card")
        }
    }

    // MARK: Bounds

    @Test func aDragCannotTakeTheCardBelowItsFloor() {
        let tiny = ResizableCardSize.resized(from: start, by: CGSize(width: -1000, height: -1000),
                                             grip: .bottomTrailing, minimum: floor, within: room)
        #expect(tiny == floor)
    }

    @Test func aDragCannotTakeTheCardPastTheWindow() {
        let available = CGSize(width: 500, height: 400)
        let huge = ResizableCardSize.resized(from: start, by: CGSize(width: 1000, height: 1000),
                                             grip: .bottomTrailing, minimum: floor,
                                             within: available)
        #expect(huge == available)
    }

    /// **`GeometryReader` reports `.zero` on its first layout pass.** Clamping straight to
    /// `available` there would collapse the card to nothing on the very frame it appears, so the
    /// floor wins when the window is smaller than it — an overflowing card is legible and a 0×0
    /// one is gone.
    @Test func aZeroSizedWindowGivesTheFloorRatherThanNothing() {
        #expect(ResizableCardSize.clamped(start, minimum: floor, within: .zero) == floor)
    }

    @Test func aSizeInsideBothBoundsIsLeftAlone() {
        #expect(ResizableCardSize.clamped(start, minimum: floor, within: room) == start)
    }
}
