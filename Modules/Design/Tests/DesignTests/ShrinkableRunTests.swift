import AppKit
import SwiftUI
import Testing
@testable import Design

/// The three widths `ShrinkableRun` exists to report (ideal = content, maximum = content,
/// minimum = 0), measured through a real layout rather than asserted on the arithmetic.
///
/// Each is something an ordinary tool gets wrong: a run of `.fixedSize()` views has minimum ==
/// ideal and overflows its row; a `ScrollView` has maximum = infinity and soaks up a row's slack.
/// Either is invisible in a screenshot at the width the author happened to try.
@MainActor
@Suite struct ShrinkableRunTests {

    /// The natural width of the three-box fixture: the boxes plus two gaps. Typed `CGFloat`:
    /// `#expect` type-checks the two sides independently, so an untyped sum becomes an `Int` and
    /// never equals the measured width.
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

    /// The ideal is exactly the content, never more: a roomy row leaves the run at its natural
    /// width and hands the surplus to its siblings, or a sibling such as To File's survey sentence
    /// is starved at every window width.
    @Test func aRoomyRowLeavesTheRunAtItsContentWidth() {
        let result = placed(rowWidth: 600, boxes: [50, 60, 70])
        #expect(result.run == Self.threeBoxIdeal)
        #expect(result.xs == [0, 58, 126], "the items are laid out in order at their own widths")
    }

    /// Every subview, not the first: a `@ViewBuilder` slot filled with a `Group` arrives as several
    /// subviews, and sizing on `subviews.first` alone reports the leading item's width as the whole
    /// run's and leaves the rest unplaced.
    @Test func aRunReportsAllOfItsItemsNotJustTheFirst() {
        let one = placed(rowWidth: 600, boxes: [50])
        let three = placed(rowWidth: 600, boxes: [50, 60, 70])
        #expect(one.run == 50)
        #expect(three.run > one.run + 100,
                "three items measured \(three.run) against one item's \(one.run)")
    }

    /// The minimum is zero: a row too narrow for the run squeezes it rather than being widened by
    /// it, which would push a header card past both edges of its pane.
    @Test func aTightRowSqueezesTheRunInsteadOfBeingWidenedByIt() {
        for rowWidth: CGFloat in [120, 60, 10] {
            let result = placed(rowWidth: rowWidth, boxes: [50, 60, 70])
            #expect(result.run <= rowWidth,
                    "the run drew \(result.run) in a \(rowWidth)pt row")
            #expect(result.run < Self.threeBoxIdeal, "a positive control: this row really is tight")
        }
    }

    /// A squeeze cuts the tail. The items keep their own widths and the run loses its end, so a
    /// pill is either fully legible or absent, never compressed.
    @Test func aSqueezeCutsTheTailRatherThanCompressingEachItem() {
        let roomy = placed(rowWidth: 600, boxes: [50, 60, 70])
        let tight = placed(rowWidth: 120, boxes: [50, 60, 70])
        #expect(tight.xs == roomy.xs,
                "the items moved when the row tightened — \(tight.xs) against \(roomy.xs)")
    }

    @Test func anEmptyRunIsZeroWide() {
        #expect(placed(rowWidth: 600, boxes: []).run == 0)
    }

    /// The cache re-measures when the content changes, in the same host, the only place a
    /// `Layout` cache can be wrong. `ShrinkableRun` caches the subviews' natural sizes so a pass
    /// measures each subtree once; that is sound because they are taken at `.unspecified`, so only
    /// the subviews can change them, and SwiftUI calls `updateCache` exactly then.
    ///
    /// A fresh host builds a fresh cache and would pass with `updateCache` gutted, so the root view
    /// is replaced on the laid-out host. The run's width and the second item's origin both move,
    /// so a stale cache is caught in size and placement.
    @Test func theCachedSizesAreRefreshedWhenAnItemChangesWidth() {
        final class Report { var run: CGFloat = -1; var secondX: CGFloat = -1 }
        let report = Report()

        func fixture(firstWidth: CGFloat) -> some View {
            HStack(spacing: 0) {
                ShrinkableRun(spacing: 8) {
                    Color.red.frame(width: firstWidth, height: 12)
                    Color.blue.frame(width: 60, height: 12)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX }
                            action: { report.secondX = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report.run = $0 }
                Spacer(minLength: 0)
            }
            .frame(width: 600, height: 40)
        }

        // Typed, for the same reason as `threeBoxIdeal`.
        let narrowIdeal: CGFloat = 50 + 60 + 8
        let wideIdeal: CGFloat = 150 + 60 + 8

        let host = NSHostingView(rootView: AnyView(fixture(firstWidth: 50)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()
        #expect(report.run == narrowIdeal, "the first layout is wrong, so this scan measures nothing")
        #expect(report.secondX == CGFloat(58))

        host.rootView = AnyView(fixture(firstWidth: 150))
        host.layoutSubtreeIfNeeded()
        #expect(report.run == wideIdeal,
                "the run reported \(report.run) after its first item grew by 100pt — the cached sizes were not refreshed")
        #expect(report.secondX == CGFloat(158),
                "the second item drew at \(report.secondX) — placed from cached sizes taken before the first item grew")
    }
}
