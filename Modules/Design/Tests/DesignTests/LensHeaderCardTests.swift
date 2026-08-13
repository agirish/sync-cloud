import AppKit
import SwiftUI
import Testing
@testable import Design

/// Measures a view the way AppKit will: a real `NSHostingView` in a real (never-ordered-in)
/// window, laid out at a fixed width, reporting the height the layout system actually resolved.
///
/// This is the point of these tests. The card-gap regression in `4b1f611` survived 523 green
/// tests because the suite asserted `cardInset * 2 == cardGutter` — a constant agreeing with
/// itself — while the view that was supposed to read it never did. Only the laid-out result can
/// catch a component that stops applying its own geometry.
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

    /// A card carrying the content the Duplicates lens actually puts in it — five tabs, two
    /// controls, a folder chip and four pills — so the measurement is of a real card, not of an
    /// empty shell whose rows could never overflow.
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
            surfaceStyle: .unified,
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

    /// Row 1's leading slot: the lens's name, which is what replaced the tabs when they moved to
    /// the window's workspace bar. Semibold 13 — the tallest thing the row carries, so if this
    /// row's height is ever going to overflow 27 it will be here.
    @ViewBuilder
    private static var titleRow: some View {
        Text("Duplicates")
            .font(.system(size: 13, weight: .semibold))
    }

    // MARK: The line

    /// The whole spec in one number: at rest the card occupies 86pt in its parent — 2.5 inset +
    /// 81 visible + 2.5 inset — so its VISIBLE bottom edge lands at 83.5, exactly where the file
    /// pane's header meets its list (`cardInset` + `headerHeight`).
    @Test func restsAt86Total() {
        #expect(laidOutHeight(Self.card(), width: 700) == 86.0)
    }

    /// The visible height, stated against the constant BOTH headers read. If `PaneHeader` and
    /// this card ever disagree, one of this test and `paneHeaderRestsAtHeaderHeight` (in the
    /// Dashboard suite) fails — they are pinned to the same number from opposite sides.
    @Test func restsAt81Visible() {
        let visible = laidOutHeight(Self.card(), width: 700) - 2 * LiquidGlass.cardInset
        #expect(visible == LiquidGlass.headerHeight)
        #expect(visible == 81.0)
    }

    /// The derived geometry must reproduce the constant. Cheap, and it localizes the failure: if
    /// this passes but `restsAt81Visible` fails, the rows are right and the *card* stopped
    /// applying them.
    @Test func metricsDeriveTheHeaderHeight() {
        #expect(LensHeaderMetrics.restingHeight == LiquidGlass.headerHeight)
        #expect(LensHeaderMetrics.restingTotalHeight == 86.0)
    }

    // MARK: Growth

    /// Search open: +8 gap +28 field = 122 total. The card GROWS rather than swapping the field
    /// in over the pills — the pills are the filter's live readout (12 groups → 3), which is most
    /// of the value of typing.
    @Test func searchOpenGrowsTo122() {
        #expect(laidOutHeight(Self.card(isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A parsed token adds the chip row: +8 gap +22 chips = 152 total. Only once a token
    /// actually parses — free text alone leaves the card at 122.
    @Test func chipsGrowTo152() {
        let chips = [
            TokenChipsRow.Item(label: "kind: pdf", word: "kind:pdf", isActive: true),
            TokenChipsRow.Item(label: "> 5 MB", word: ">5mb", isActive: true)
        ]
        #expect(laidOutHeight(Self.card(searchText: "kind:pdf >5mb", isSearchExpanded: true, chips: chips),
                              width: 700) == 152.0)
    }

    /// Free text with no parsable token stays at the open height — no empty chip row.
    @Test func freeTextWithoutTokensStaysAt122() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A live query keeps the field showing even if the host clears `isSearchExpanded`: a filter
    /// narrowing the list must never be on behind a hidden field.
    @Test func liveQueryKeepsFieldShowing() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: false), width: 700) == 122.0)
    }

    // MARK: Ungated

    /// The empty/scanning state — no results, so no pills and no actions — is still 86. This is
    /// the property the old two-mechanism header could not hold: it rendered at 42/53/83/115pt
    /// depending on lens and state, because it was gated on having results.
    @Test func emptyStateHoldsTheSameHeight() {
        let bare = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .unified,
            level: .frosted,
            title: { Self.titleRow }
        )
        #expect(laidOutHeight(bare, width: 700) == 86.0)
    }

    /// Cards mode adds a shadow and a hairline but must not change the height — the inset is the
    /// same half-gutter in both shapes.
    @Test func cardsShapeHoldsTheSameHeight() {
        let cards = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .cards,
            level: .frosted,
            title: { Self.titleRow }
        )
        #expect(laidOutHeight(cards, width: 700) == 86.0)
    }

    // MARK: A lens that answers no query does not offer the control

    /// A header with nothing but a title, so row 1's trailing half holds the search toggle **and
    /// nothing else** — which is what lets the pixel check below attribute the ink.
    ///
    /// It is also the real shape: the Organize header passes `actions: { EmptyView() }`, having
    /// moved its controls to row 2.
    private static func plainCard(showsSearch: Bool, searchText: String = "") -> some View {
        LensHeaderCard(
            searchText: .constant(searchText),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            showsSearch: showsSearch,
            accent: .blue,
            surfaceStyle: .unified,
            level: .frosted,
            title: { Self.titleRow }
        )
    }

    /// **The height is the promise, and dropping the toggle must not spend it.**
    ///
    /// The toggle lives in a fixed-height row, so this should hold by construction — which is
    /// exactly why it is worth pinning: the card's 81pt is what the pane's header↔list boundary is
    /// aligned to, and a header that shrank on two pages would break that alignment there only.
    @Test func aHeaderThatOffersNoSearchIsStillTheSameHeight() {
        #expect(laidOutHeight(Self.plainCard(showsSearch: false), width: 700) == 86.0)
        #expect(laidOutHeight(Self.plainCard(showsSearch: true), width: 700) == 86.0)
    }

    /// **A query parked by another lens cannot open a field here.**
    ///
    /// `isSearching` is `isExpanded || !searchText.isEmpty`, and the second half is reachable: the
    /// overview shares To File's query slot, so a query typed there is still in the binding when
    /// the overview draws. Without the gate the field row would appear over a page that filters
    /// nothing — the taller card being the visible half of the bug this parameter closes.
    ///
    /// The `true` case is the control: it proves the fixture really does carry a query, so the
    /// `false` case is measuring the gate rather than an empty string.
    @Test func aParkedQueryCannotOpenAFieldOnAHeaderThatOffersNoSearch() {
        #expect(laidOutHeight(Self.plainCard(showsSearch: false, searchText: "tax"), width: 700) == 86.0)
        #expect(laidOutHeight(Self.plainCard(showsSearch: true, searchText: "tax"), width: 700) > 86.0,
                "the fixture's query does not open a field even when search IS offered — the check above is vacuous")
    }

    /// **And the toggle is actually gone from the pixels**, which no height can see: it sits in a
    /// fixed-height row, so `showsSearch` could be ignored entirely and every measurement above
    /// would still pass.
    ///
    /// Measured over row 1's trailing corner — where the toggle is the only thing drawn on this
    /// fixture — against the same corner of a card that offers search.
    @Test func theToggleIsNotPaintedWhenSearchIsNotOffered() throws {
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
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

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

/// The toggle's drawn width, named here rather than reached for from `FileExplorer` — Design
/// cannot see that module, and `OrganizeRailMetrics.searchToggleWidth` (36) is that module's
/// *reserve* for it, which is a different number from what it paints.
private enum OrganizeToggleProbe {
    static let width: CGFloat = 36
}
