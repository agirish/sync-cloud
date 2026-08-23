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
            tabs: { tabsRow },
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

    @ViewBuilder
    private static var tabsRow: some View {
        HStack(spacing: 2) {
            ForEach(["Duplicates", "Rename", "Organize", "Automations", "Storage"], id: \.self) { title in
                Text(title)
                    .font(.system(size: 12, weight: title == "Duplicates" ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    // The active-tab underline: an overlay adds ZERO height, which is exactly why
                    // the tab row can be 27 and not 29. If this ever becomes a border or a VStack
                    // row, `restsAt81Visible` below is what fails.
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(title == "Duplicates" ? Color.blue : .clear).frame(height: 2)
                    }
            }
        }
    }

    // MARK: The line

    /// The whole spec in one number: at rest the card occupies 86pt in its parent — 2.5 inset +
    /// 81 visible + 2.5 inset — so its VISIBLE bottom edge lands at 83.5, exactly where the file
    /// pane's header meets its list (`cardInset` + `headerHeight`).
    @Test(.machinePinned(.layoutMetrics)) func restsAt86Total() {
        #expect(laidOutHeight(Self.card(), width: 700) == 86.0)
    }

    /// The visible height, stated against the constant BOTH headers read. If `PaneHeader` and
    /// this card ever disagree, one of this test and `paneHeaderRestsAtHeaderHeight` (in the
    /// Dashboard suite) fails — they are pinned to the same number from opposite sides.
    @Test(.machinePinned(.layoutMetrics)) func restsAt81Visible() {
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
    @Test(.machinePinned(.layoutMetrics)) func searchOpenGrowsTo122() {
        #expect(laidOutHeight(Self.card(isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A parsed token adds the chip row: +8 gap +22 chips = 152 total. Only once a token
    /// actually parses — free text alone leaves the card at 122.
    @Test(.machinePinned(.layoutMetrics)) func chipsGrowTo152() {
        let chips = [
            TokenChipsRow.Item(label: "kind: pdf", word: "kind:pdf", isActive: true),
            TokenChipsRow.Item(label: "> 5 MB", word: ">5mb", isActive: true)
        ]
        #expect(laidOutHeight(Self.card(searchText: "kind:pdf >5mb", isSearchExpanded: true, chips: chips),
                              width: 700) == 152.0)
    }

    /// Free text with no parsable token stays at the open height — no empty chip row.
    @Test(.machinePinned(.layoutMetrics)) func freeTextWithoutTokensStaysAt122() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: true), width: 700) == 122.0)
    }

    /// A live query keeps the field showing even if the host clears `isSearchExpanded`: a filter
    /// narrowing the list must never be on behind a hidden field.
    @Test(.machinePinned(.layoutMetrics)) func liveQueryKeepsFieldShowing() {
        #expect(laidOutHeight(Self.card(searchText: "invoice", isSearchExpanded: false), width: 700) == 122.0)
    }

    // MARK: Ungated

    /// The empty/scanning state — no results, so no pills and no actions — is still 86. This is
    /// the property the old two-mechanism header could not hold: it rendered at 42/53/83/115pt
    /// depending on lens and state, because it was gated on having results.
    @Test(.machinePinned(.layoutMetrics)) func emptyStateHoldsTheSameHeight() {
        let bare = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .unified,
            level: .frosted,
            tabs: { Self.tabsRow }
        )
        #expect(laidOutHeight(bare, width: 700) == 86.0)
    }

    /// Cards mode adds a shadow and a hairline but must not change the height — the inset is the
    /// same half-gutter in both shapes.
    @Test(.machinePinned(.layoutMetrics)) func cardsShapeHoldsTheSameHeight() {
        let cards = LensHeaderCard(
            searchText: .constant(""),
            isSearchExpanded: .constant(false),
            searchPlaceholder: "kind:pdf, >5mb…",
            searchHelp: "Search duplicate groups",
            accent: .blue,
            surfaceStyle: .cards,
            level: .frosted,
            tabs: { Self.tabsRow }
        )
        #expect(laidOutHeight(cards, width: 700) == 86.0)
    }
}
