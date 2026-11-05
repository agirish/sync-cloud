import AppKit
import SwiftUI
import Testing
@testable import Design

/// A card that can't compress draws over the pane beside it unless its column clips it.
///
/// SwiftUI centres an oversized child, so a card wider than its column spills past both edges,
/// and since the app draws the source pane first, the spill lands on top of it, live controls
/// included. Geometry tests of the shedding model can't see this, because the arithmetic is right.
///
/// These render the card into a canvas wider than its column and count ink outside the column:
/// not "is it wide", but "does it paint where it was given no room".
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct LensHeaderCardOverrunTests {

    /// The column the workspace actually gets at the split's floor.
    static let column: CGFloat = 340
    /// A canvas with room on both sides, so overflow has somewhere to show up.
    static let canvas = CGSize(width: 900, height: 140)

    /// Row 2 with an incompressible half.
    ///
    /// The incompressible half is the trailing controls: the readouts in `summary` yield
    /// (`ShrinkableRun`), so a rigid summary alone no longer overruns and the fixture would pass
    /// with the split's clip removed.
    ///
    /// The trailing set (a filter menu, a rescan control and "Apply 410 recommended") is all
    /// `.fixedSize()`, the last at `layoutPriority(1)` because a destructive button cut in half is
    /// worse than a truncated readout. A rigid stand-in wider than the column takes their place, so
    /// rewording a label can't quietly stop the fixture reproducing the overrun.
    struct Subject: View {
        var body: some View {
            LensHeaderCard(
                searchText: .constant(""),
                isSearchExpanded: .constant(false),
                searchPlaceholder: "Search",
                searchHelp: "Search",
                showsSearch: true,
                chips: [],
                onRemoveChip: { _ in },
                accent: .blue,
                surfaceStyle: .cards,
                level: .frosted,
                hue: .graphite,
                tint: 0,
                title: { Text("Duplicates").fixedSize() },
                actions: { EmptyView() },
                summary: {
                    HStack(spacing: 6) {
                        Text("410 groups").fixedSize()
                        Text("1.7 MB reclaimable").fixedSize()
                        Text("Checked 3,013 folders").fixedSize()
                    }
                },
                trailing: {
                    Color.black.frame(width: LensHeaderCardOverrunTests.column + 40, height: 18)
                }
            )
        }
    }

    /// Ink outside the column, in points-squared of the rendered image.
    ///
    /// Rendered onto an opaque white ground and compared against it, so "ink" is anything the card
    /// drew, its own surface included. The card is constrained to `column` and centred, as the
    /// split lays it out.
    /// - Parameter clipping: whether the column clips its content, as `ContentView+SplitLayout`
    ///   does around the workspace. False renders the unclipped overrun.
    /// - Parameter flexible: frame the column as the split does, one flexible frame with both bounds
    ///   at the column's width (`minWidth == maxWidth`) so the rail's collapse can keep the same
    ///   modifier, rather than with a fixed `width:`.
    static func inkOutsideTheColumn<V: View>(_ view: V, clipping: Bool, flexible: Bool = false) -> Int {
        let framed = flexible
            ? AnyView(view.frame(minWidth: Self.column, maxWidth: Self.column))
            : AnyView(view.frame(width: Self.column))
        let column = clipping ? AnyView(framed.clipped()) : framed
        let subject = ZStack {
            Color.white
            column
        }
        .frame(width: canvas.width, height: canvas.height)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)

        // The band the card was given, in pixels of the representation.
        let scale = CGFloat(rep.pixelsWide) / canvas.width
        let inset = ((canvas.width - Self.column) / 2) * scale
        var outside = 0
        for x in 0..<rep.pixelsWide where CGFloat(x) < inset - 1 || CGFloat(x) > CGFloat(rep.pixelsWide) - inset + 1 {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                // Anything that is not the white ground.
                if c.redComponent < 0.98 || c.greenComponent < 0.98 || c.blueComponent < 0.98 {
                    outside += 1
                }
            }
        }
        return outside
    }

    /// A `.clipped()` on the card itself does nothing: `.frame(maxWidth: .infinity)` reports the
    /// larger of the proposal and what the child insists on, so the card clips to its own width.
    /// The clip has to belong to whoever owns a definite width: the split, which frames the
    /// workspace at `totalWidth - railWidth`. This models both.
    ///
    /// It characterises the clip's placement (in `ContentView+SplitLayout`), not `LensHeaderCard`:
    /// the rigid stand-in overruns for any card implementation. `LensHeaderCardOverflowTests` pins
    /// the card's own behaviour.
    @Test func theCardOverrunsItsColumnAndOnlyTheOwnerOfTheWidthCanClipIt() {
        // Controls, so a number here can't be an artefact of the ink detector.
        #expect(Self.inkOutsideTheColumn(Color.clear, clipping: false) == 0,
                "the ink detector reports ink for an empty canvas")
        #expect(Self.inkOutsideTheColumn(Text("x"), clipping: false) == 0,
                "the ink detector reports ink for a subject that fits")

        // The defect: offered 340pt, the card paints outside it.
        let spilled = Self.inkOutsideTheColumn(Subject(), clipping: false)
        #expect(spilled > 0,
                "the fixture no longer reproduces the overrun — the card now fits its column, so this test would pass with the clip removed")

        // And the fix, applied where the width is definite: nothing outside the column.
        #expect(Self.inkOutsideTheColumn(Subject(), clipping: true) == 0,
                "clipping at the column still let the card paint on its neighbour")

        // The split's own frame, flexible with both bounds at the column: the card overruns it the
        // same way, and the same clip holds it.
        #expect(Self.inkOutsideTheColumn(Subject(), clipping: false, flexible: true) > 0,
                "the flexible frame no longer reproduces the overrun, so its clip below proves nothing")
        #expect(Self.inkOutsideTheColumn(Subject(), clipping: true, flexible: true) == 0,
                "clipping the split's flexible frame still let the card paint on its neighbour")
    }
}
