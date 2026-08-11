import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// **Does the row stay inside the card it is drawn in?** — the question every width assertion in
/// `OrganizeRailTests` is one step away from, and the one the shipped rail failed.
///
/// The fixture is `TidyView.lensTitle`'s shape rebuilt from the real `RailItemLabel`s: six items at
/// their widest rung inside a `LensHeaderCard`, in a column too narrow to hold them. It is a
/// replica rather than the view itself — `lensTitle` is private to a `TidyView` that needs a
/// `FileSyncManager` — so what it can prove is about the SHAPE: that wrapping the row in the
/// horizontal `ScrollView` is what keeps an over-wide rail from widening its card, and that
/// without it the card grows and takes the space its neighbour is drawn in.
///
/// Both directions on purpose. A one-sided "it fits now" would pass just as happily against a
/// fixture too small to overflow in the first place.
@Suite struct OrganizeRailOverflowTests {

    @MainActor
    private func cardWidth(offered: CGFloat, scrolls: Bool) -> CGFloat {
        var reported: CGFloat = -1
        let items = OrganizeLens.railItems
        let row = HStack(spacing: 6) {
            ForEach(items) { item in
                RailItemLabel(title: item.title, systemImage: item.symbol,
                              state: .reporting(410), isSelected: item == .toFile, accent: .blue)
            }
        }
        let card = LensHeaderCard(
            searchText: .constant(""), isSearchExpanded: .constant(false),
            searchPlaceholder: "", searchHelp: "", chips: [], onRemoveChip: { _ in },
            accent: .blue, surfaceStyle: .unified, level: .frosted,
            title: {
                if scrolls {
                    ScrollView(.horizontal) { row }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.never)
                } else {
                    row
                }
            },
            actions: { EmptyView() }, summary: { EmptyView() }, trailing: { EmptyView() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { reported = $0 }

        let host = NSHostingView(rootView: card.frame(width: offered))
        host.layoutSubtreeIfNeeded()
        return reported
    }

    @MainActor
    @Test func theScrolledRowKeepsTheCardInsideTheColumnAndTheBareRowDoesNot() {
        // 340 is `singleSourceLayout`'s `minWorkspace` — the narrowest column this card is ever
        // drawn in, and narrower than a six-badge rail at any text size.
        let column: CGFloat = 340

        let bare = cardWidth(offered: column, scrolls: false)
        let scrolled = cardWidth(offered: column, scrolls: true)

        #expect(bare > 0 && scrolled > 0, "a geometry read never fired — bare \(bare), scrolled \(scrolled)")
        // The direction that proves the fixture can fail at all: without the scroll the row really
        // does force the card wider than the column it belongs to.
        #expect(bare > column,
                "the bare row no longer overflows a \(column)pt column (\(bare)) — this fixture has stopped reproducing the defect it guards")
        #expect(scrolled == column,
                "the scrolled row still widens its card to \(scrolled) in a \(column)pt column — the rail can overlap the pane beside it again")
    }
}
