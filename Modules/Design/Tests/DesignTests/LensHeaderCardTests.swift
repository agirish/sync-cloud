import AppKit
import SwiftUI
import Testing
@testable import Design

/// Measures a view the way AppKit will: a real `NSHostingView` in a real (never ordered in)
/// window, laid out at a fixed width, reporting the height the layout system resolved. A check
/// like `cardInset * 2 == cardGutter` only has a constant agree with itself; only the laid-out
/// result catches a component that stops applying its own geometry.
@MainActor
func laidOutHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
    host.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

@MainActor
@Suite(.serialized) struct LensHeaderCardTests {

    // MARK: Fixtures

    /// A card carrying what the Duplicates lens puts in it (a title, two controls, a folder chip and
    /// three pills), so the measurement is of a real card, not an empty shell whose rows could never
    /// overflow.
    private static func card(
        searchText: String = "",
        isSearchExpanded: Bool = false,
        chips: [TokenChipsRow.Item] = []
    ) -> some View {
        LensHeaderCard(
            searchText: .constant(searchText),
            isSearchExpanded: .constant(isSearchExpanded),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            chips: chips,
            onRemoveChip: { _ in },
            accent: .blue,
            surfaceStyle: .cards,
            level: .frosted,
            title: { titleRow },
            actions: {
                Button("Rescan") {}.controlSize(.small)
                Button("Trash all 8") {}.buttonStyle(.borderedProminent).controlSize(.small)
            },
            summary: {
                Label("Documents", systemImage: "folder").font(.system(size: 11, weight: .medium))
                Pill(.standard, tint: .blue, systemImage: "square.on.square", count: 12, label: "groups")
                Pill(.standard, tint: .green, systemImage: "internaldrive", text: "2.1 GB reclaimable")
                Pill(.standard, tint: .secondary, systemImage: "doc.on.doc", count: 8, label: "redundant")
            },
            trailing: {
                Text("3 of 12").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        )
    }

    /// Row 1's leading slot: the lens's name (the tabs live in the window's workspace bar).
    /// Semibold 13, the tallest thing the row carries, so if the row ever overflows 27 it is here.
    @ViewBuilder
    private static var titleRow: some View {
        Text("Duplicates")
            .font(.system(size: 13, weight: .semibold))
    }

    // MARK: The line

    /// The visible height, against the constant both headers read. If `PaneHeader` and this card
    /// ever disagree, this test or `paneHeaderRestsAtHeaderHeight` (in the Dashboard suite) fails:
    /// they pin the same number from opposite sides. At rest the card occupies 86pt in its parent
    /// (2.5 inset + 81 visible + 2.5 inset), so its visible bottom edge lands at 83.5, exactly where
    /// the file pane's header meets its list (`cardInset` + `headerHeight`).
    @Test(.machinePinned(.layoutMetrics)) func restsAt81Visible() {
        let total = laidOutHeight(Self.card(), width: 700)
        #expect(total == 86.0)
        let visible = total - 2 * LiquidGlass.cardInset
        #expect(visible == LiquidGlass.headerHeight)
        #expect(visible == 81.0)
    }

    /// The derived geometry must reproduce the constant. Cheap, and it localizes the failure: if
    /// this passes but `restsAt81Visible` fails, the rows are right and the card stopped applying
    /// them.
    @Test func metricsDeriveTheHeaderHeight() {
        #expect(LensHeaderMetrics.restingHeight == LiquidGlass.headerHeight)
        #expect(LensHeaderMetrics.restingTotalHeight == 86.0)
    }

    // MARK: Growth

    /// Search open: +8 gap +28 field = 122 total. The card grows rather than swapping the field in
    /// over the pills, because the pills are the filter's live readout (12 groups → 3).
    @Test(.machinePinned(.layoutMetrics)) func searchOpenGrowsTo122() {
        #expect(laidOutHeight(Self.card(isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A parsed token adds the chip row: +8 gap +22 chips = 152 total. Free text alone leaves the
    /// card at 122.
    @Test(.machinePinned(.layoutMetrics)) func chipsGrowTo152() {
        let chips = [
            TokenChipsRow.Item(label: "kind: pdf", word: "kind:pdf", isActive: true),
            TokenChipsRow.Item(label: "> 5 MB", word: ">5mb", isActive: true)
        ]
        #expect(laidOutHeight(Self.card(searchText: "kind:pdf >5mb", isSearchExpanded: true, chips: chips),
                              width: 700) == 152.0)
    }

    /// Free text with no parsable token stays at the open height, with no empty chip row.
    @Test(.machinePinned(.layoutMetrics)) func freeTextWithoutTokensStaysAt122() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A live query keeps the field showing even if the host clears `isSearchExpanded`: a filter
    /// narrowing the list must never be on behind a hidden field.
    @Test(.machinePinned(.layoutMetrics)) func liveQueryKeepsFieldShowing() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: false), width: 700) == 122.0)
    }

    // MARK: Ungated

    /// The empty or scanning state (no results, so no pills and no actions) is still 86: the
    /// header's height must not depend on the lens or on having results.
    @Test(.machinePinned(.layoutMetrics)) func emptyStateHoldsTheSameHeight() {
        let bare = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .cards,
            level: .frosted,
            title: { Self.titleRow }
        )
        #expect(laidOutHeight(bare, width: 700) == 86.0)
    }

    /// Unified moves the frame to the window, not the line. The card and its column
    /// (`columnRegionFrame`) draw no frame or inset; the window's one region (`windowRegionFrame`)
    /// is the only frame. So the card alone is 81 visible points, and inside the column and region
    /// it occupies the same 86 with its bottom edge on 83.5. Measured both ways, because a card or
    /// column that kept its own inset would pass the first and land 2.5pt low in the region.
    @Test(.machinePinned(.layoutMetrics)) func unifiedLeavesTheFrameToTheColumnAndKeepsTheLine() {
        let unified = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .unified,
            level: .frosted,
            title: { Self.titleRow }
        )
        #expect(laidOutHeight(unified, width: 700) == LiquidGlass.headerHeight)
        #expect(laidOutHeight(unified.columnRegionFrame(.unified, level: .frosted)
            .windowRegionFrame(.unified, level: .frosted), width: 700) == 86.0)
    }

    // MARK: A lens that answers no query does not offer the control

    /// A header with nothing but a title, so row 1's trailing half holds the search toggle and
    /// nothing else, which lets the pixel check below attribute the ink. It is also the real shape:
    /// the Organize header passes `actions: { EmptyView() }` and keeps its controls on row 2.
    private static func plainCard(showsSearch: Bool, searchText: String = "") -> some View {
        LensHeaderCard(
            searchText: .constant(searchText),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            showsSearch: showsSearch,
            accent: .blue,
            surfaceStyle: .cards,
            level: .frosted,
            title: { Self.titleRow }
        )
    }

    /// Dropping the toggle must not change the height. It lives in a fixed-height row, so this
    /// holds by construction, but the card's 81pt is what the pane's header↔list boundary aligns
    /// to, and a header that shrank on some pages would break the alignment only there.
    @Test(.machinePinned(.layoutMetrics)) func aHeaderThatOffersNoSearchIsStillTheSameHeight() {
        #expect(laidOutHeight(Self.plainCard(showsSearch: false), width: 700) == 86.0)
        #expect(laidOutHeight(Self.plainCard(showsSearch: true), width: 700) == 86.0)
    }

    /// A query parked by another lens can't open a field here.
    ///
    /// `isSearching` is `isExpanded || !searchText.isEmpty`, and the second half is reachable: the
    /// overview shares To File's query slot, so a query typed there is still in the binding when
    /// the overview draws. Without the gate a field row would appear over a page that filters
    /// nothing, and the card would grow.
    ///
    /// The `true` case is the control: it proves the fixture carries a query, so the `false` case
    /// measures the gate rather than an empty string.
    @Test(.machinePinned(.layoutMetrics)) func aParkedQueryCannotOpenAFieldOnAHeaderThatOffersNoSearch() {
        #expect(laidOutHeight(Self.plainCard(showsSearch: false, searchText: "tax"), width: 700) == 86.0)
        #expect(laidOutHeight(Self.plainCard(showsSearch: true, searchText: "tax"), width: 700) > 86.0,
                "the fixture's query does not open a field even when search IS offered — the check above is vacuous")
    }

    /// The toggle is gone from the pixels too, which no height can see: it sits in a fixed-height
    /// row, so every measurement above would pass with `showsSearch` ignored. Measured over row 1's
    /// trailing corner, where the toggle is the only thing drawn, against a card that offers search.
    @Test(.machinePinned(.pixelSampling)) func theToggleIsNotPaintedWhenSearchIsNotOffered() throws {
        let width: CGFloat = 700
        let withSearch = try Self.trailingCornerInk(Self.plainCard(showsSearch: true), width: width)
        let without = try Self.trailingCornerInk(Self.plainCard(showsSearch: false), width: width)
        #expect(withSearch > 0,
                "no ink where the toggle should be — the probe is aimed at the wrong region")
        #expect(without == 0,
                "\(without) pixels are still painted where the toggle was, on a header that offers no search")
    }

    /// Non-background pixels in row 1's trailing corner: x from the trailing padding inward by the
    /// toggle's width, y across the tabs row. Compared against the card's own fill rather than a
    /// fixed colour, so a surface restyle does not read as ink.
    private static func trailingCornerInk(_ view: some View, width: CGFloat) throws -> Int {
        let height = LensHeaderMetrics.restingTotalHeight
        let rep = try #require(offscreenBitmap(AnyView(
            view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))),
            size: CGSize(width: width, height: height), appearance: nil, sRGB: false, close: true))

        let scale = Int(rep.pixelsWide) / Int(width)
        // The toggle is last on row 1, inside the card's 12pt padding plus its 2.5pt inset.
        let right = Int(width - LensHeaderMetrics.padding - LiquidGlass.cardInset)
        let left = right - Int(OrganizeToggleProbe.width)
        let top = Int(LensHeaderMetrics.padding + LiquidGlass.cardInset)
        let bottom = top + Int(LensHeaderMetrics.tabRow)
        // The card's own fill, sampled from a point on row 1 that is definitely empty: just
        // inside the leading padding is the title, so take the middle of the row's blank span.
        let reference = try #require(rep.colorAt(x: (left - 40) * scale, y: (top + 2) * scale))
        var ink = 0
        for x in stride(from: left * scale, to: right * scale, by: 1) {
            for y in stride(from: top * scale, to: bottom * scale, by: 1) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - reference.redComponent) > 0.03
                    || abs(c.greenComponent - reference.greenComponent) > 0.03
                    || abs(c.blueComponent - reference.blueComponent) > 0.03 { ink += 1 }
            }
        }
        return ink
    }
}

/// The toggle's drawn width, named here because Design can't see `FileExplorer`, and
/// `OrganizeRailMetrics.searchToggleWidth` there is the space reserved for it, not what it paints.
private enum OrganizeToggleProbe {
    static let width: CGFloat = 36
}
