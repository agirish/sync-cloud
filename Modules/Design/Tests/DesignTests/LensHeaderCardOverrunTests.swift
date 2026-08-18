import AppKit
import SwiftUI
import Testing
@testable import Design

/// **A card that cannot compress draws over the pane beside it.**
///
/// Found by rendering the real view offscreen and looking at the PNG, which is the only thing that
/// showed it: every geometry and unit test of the shedding model passes, because the arithmetic was
/// never wrong. At the 340pt `minWorkspace` floor with Duplicates selected the card measured ~600pt
/// inside a 340pt column, and SwiftUI CENTRES an oversized child — so it spilled ~130pt past each
/// edge, and since the app draws the source pane first, the overflow landed on top of it. Rail
/// items and a live "Apply" control were painted on the neighbouring pane.
///
/// These render the card into a canvas WIDER than the column it is given and count ink outside the
/// column. That is the defect stated as a measurement: not "is it wide", but "does it paint where
/// it was not given room".
@MainActor
@Suite struct LensHeaderCardOverrunTests {

    /// The column the workspace actually gets at the split's floor.
    static let column: CGFloat = 340
    /// A canvas with room on both sides, so overflow has somewhere to show up.
    static let canvas = CGSize(width: 900, height: 140)

    /// Row 2 as Duplicates draws it: prose and pills that refuse to compress (`SummaryRun` uses
    /// `.fixedSize()`), plus a live control on the trailing edge.
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
                    Button("Apply 410 recommended") {}.fixedSize()
                }
            )
        }
    }

    /// Ink outside the column, in points-squared of the rendered image.
    ///
    /// Rendered onto an opaque white ground and compared against it, so "ink" is anything the card
    /// drew — its own surface included. The card is constrained to `column` and centred, exactly as
    /// the split lays it out.
    /// - Parameter clipping: whether the COLUMN clips its content, which is what
    ///   `ContentView+SplitLayout` does around the workspace. False renders the app's old behaviour.
    static func inkOutsideTheColumn<V: View>(_ view: V, clipping: Bool) -> Int {
        let column = clipping
            ? AnyView(view.frame(width: Self.column).clipped())
            : AnyView(view.frame(width: Self.column))
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

    /// **The measurement, and the two halves it separates.**
    ///
    /// A `.clipped()` on the card itself does nothing: `.frame(maxWidth: .infinity)` reports the
    /// larger of the proposal and what the child insists on, so the card resolves to its own ~600pt
    /// and clips to that. The clip has to belong to whoever owns a DEFINITE width — the split,
    /// which frames the workspace at `totalWidth - railWidth`. This models both.
    @Test func theCardOverrunsItsColumnAndOnlyTheOwnerOfTheWidthCanClipIt() {
        // Controls, so a number here cannot be an artefact of the ink detector.
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
    }
}
