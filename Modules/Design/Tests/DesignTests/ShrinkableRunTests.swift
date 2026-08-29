import AppKit
import SwiftUI
import Testing
@testable import Design

/// The three widths `ShrinkableRun` exists to report — ideal = content, maximum = content,
/// minimum = 0 — measured through a real layout rather than asserted on the arithmetic.
///
/// Each is the thing some ordinary tool gets wrong: a run of `.fixedSize()` views has minimum ==
/// ideal and overflows its row; a `ScrollView` has maximum = infinity and soaks up a row's slack.
/// Getting either wrong is invisible in a screenshot at the width the author happened to try.
@MainActor
@Suite struct ShrinkableRunTests {

    /// The natural width of the three-box fixture: the boxes plus two gaps. A `CGFloat` rather
    /// than an integer expression — `#expect` type-checks the two sides independently, so an
    /// untyped `50 + 60 + 70 + 8 * 2` becomes an `Int` and never equals the measured width.
    static let threeBoxIdeal: CGFloat = 50 + 60 + 70 + 8 * 2

    /// Lays out three rigid boxes in a row of the given width and reports what each one drew.
    private func placed(rowWidth: CGFloat, boxes: [CGFloat],
                        spacing: CGFloat = 8) -> (run: CGFloat, xs: [CGFloat]) {
        var runWidth: CGFloat = -1
        var xs = [CGFloat](repeating: -1, count: boxes.count)
        let content = ShrinkableRun(spacing: spacing) {
            ForEach(Array(boxes.enumerated()), id: \.offset) { index, width in
                Color.red.frame(width: width, height: 12)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                        xs[index] = $0
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { runWidth = $0 }

        let host = NSHostingView(rootView: HStack(spacing: 0) { content; Spacer(minLength: 0) }
            .frame(width: rowWidth, height: 40))
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: 40)
        host.layoutSubtreeIfNeeded()
        return (runWidth, xs)
    }

    /// **The ideal: exactly the content, never more.** A row wide enough for everything must leave
    /// the run at its natural width and hand the surplus to its siblings — the failure that starved
    /// To File's survey sentence to a constant 414pt at every window width.
    @Test func aRoomyRowLeavesTheRunAtItsContentWidth() {
        let result = placed(rowWidth: 600, boxes: [50, 60, 70])
        #expect(result.run == Self.threeBoxIdeal)
        #expect(result.xs == [0, 58, 126], "the items are laid out in order at their own widths")
    }

    /// **Every subview, not the first.** A `@ViewBuilder` slot filled with a `Group` arrives as
    /// several subviews; sizing on `subviews.first` alone reports the leading item's width as the
    /// whole run's and leaves the rest unplaced.
    @Test func aRunReportsAllOfItsItemsNotJustTheFirst() {
        let one = placed(rowWidth: 600, boxes: [50])
        let three = placed(rowWidth: 600, boxes: [50, 60, 70])
        #expect(one.run == 50)
        #expect(three.run > one.run + 100,
                "three items measured \(three.run) against one item's \(one.run)")
    }

    /// **The minimum: zero.** A row too narrow for the run must squeeze it rather than be widened
    /// by it — the whole reported defect, where the header card drew past both edges of its pane.
    @Test func aTightRowSqueezesTheRunInsteadOfBeingWidenedByIt() {
        for rowWidth: CGFloat in [120, 60, 10] {
            let result = placed(rowWidth: rowWidth, boxes: [50, 60, 70])
            #expect(result.run <= rowWidth,
                    "the run drew \(result.run) in a \(rowWidth)pt row")
            #expect(result.run < Self.threeBoxIdeal, "a positive control: this row really is tight")
        }
    }

    /// What a squeeze cuts is the tail. The items keep their own widths and the run loses the end
    /// of itself, so a pill is either fully legible or absent — never a compressed pill.
    @Test func aSqueezeCutsTheTailRatherThanCompressingEachItem() {
        let roomy = placed(rowWidth: 600, boxes: [50, 60, 70])
        let tight = placed(rowWidth: 120, boxes: [50, 60, 70])
        #expect(tight.xs == roomy.xs,
                "the items moved when the row tightened — \(tight.xs) against \(roomy.xs)")
    }

    @Test func anEmptyRunIsZeroWide() {
        #expect(placed(rowWidth: 600, boxes: []).run == 0)
    }
}
