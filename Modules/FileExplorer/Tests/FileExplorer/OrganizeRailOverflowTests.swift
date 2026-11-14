import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// Does the rail row stay inside its card? A replica of `LensWorkspaceView.lensTitle` from the real
/// `RailItemLabel`s, in a column too narrow for them, proving the horizontal `ScrollView` keeps an
/// over-wide rail from widening its card into its neighbour. Both directions, so a fixture too small
/// to overflow fails.
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
// 340 is `PaneLogic.minLensWorkspaceWidth` (in MacApp): the narrowest column this card is drawn in.
        let column: CGFloat = 340

        let bare = cardWidth(offered: column, scrolls: false)
        let scrolled = cardWidth(offered: column, scrolls: true)

        #expect(bare > 0 && scrolled > 0, "a geometry read never fired — bare \(bare), scrolled \(scrolled)")
// The direction that proves the fixture can fail: without the scroll the card really is wider.
        #expect(bare > column,
                "the bare row no longer overflows a \(column)pt column (\(bare)) — this fixture has stopped reproducing the defect it guards")
        #expect(scrolled == column,
                "the scrolled row still widens its card to \(scrolled) in a \(column)pt column — the rail can overlap the pane beside it again")
    }

/// And the shipped rail is built that way, or deleting the `ScrollView` would leave the replica
/// green. Scanned in the function's own body.
    @Test func theShippedRailIsTheScrolledArm() throws {
        let body = try SourceText.body(of: "private func lensTitle(_ counts: RailCounts) -> some View {",
                                       in: try SourceText.fileExplorer("LensWorkspaceView.swift"))

        #expect(body.contains("ScrollView(.horizontal) {"),
                "lensTitle no longer wraps the rail in a horizontal ScrollView — an over-wide rail widens its card and draws over the pane beside it")
// Without the first the row rubber-bands at every width; the second keeps a 27pt band from
// spending height on an indicator.
        #expect(body.contains(".scrollBounceBehavior(.basedOnSize)"))
        #expect(body.contains(".scrollIndicators(.never)"))
        // And the half that answers the clip: the chosen rung is scrolled into view, so the item
        // you selected is never the one drawn cut in half.
        #expect(body.contains("rail.scrollTo(id, anchor: .center)"),
                "the selected rung is no longer scrolled into view — at a narrow column it can sit off-screen with nothing saying so")
    }
}
