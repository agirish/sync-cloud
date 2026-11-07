import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// Does the rail row stay inside the card it is drawn in? The fixture is
/// `LensWorkspaceView.lensTitle`'s shape rebuilt from the real `RailItemLabel`s: six items at their
/// widest rung inside a `LensHeaderCard`, in a column too narrow for them. A replica, because
/// `lensTitle` is private to a view that needs a `FileSyncManager`, so it proves the shape: the
/// horizontal `ScrollView` keeps an over-wide rail from widening its card into its neighbour's
/// space.
///
/// Both directions on purpose: a one-sided "it fits" would pass against a fixture too small to
/// overflow.
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
        // 340 is `PaneLogic.minLensWorkspaceWidth` (in MacApp, unreachable here): the narrowest
        // column this card is drawn in, and narrower than a six-badge rail at any text size.
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

    /// And the shipped rail is built that way. The test above builds both arms itself, so it proves
    /// a fact about SwiftUI; deleting the `ScrollView` from `lensTitle` would leave it green while
    /// the rail overlaps the pane beside it. A source scan, for the replica's reason, of the
    /// function's own body so a `ScrollView` elsewhere in the file can't satisfy it.
    @Test func theShippedRailIsTheScrolledArm() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/Tests/FileExplorer
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer/LensWorkspaceView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private func lensTitle(_ counts: RailCounts) -> some View {"),
                                 "lensTitle has been renamed or removed — this scan is reading nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    private "), "could not find where lensTitle ends")
        let body = rest[..<end.lowerBound]

        #expect(body.contains("ScrollView(.horizontal) {"),
                "lensTitle no longer wraps the rail in a horizontal ScrollView — an over-wide rail widens its card and draws over the pane beside it")
        // The two settings that make it cost nothing when the rail fits: without the first the row
        // rubber-bands at every width; the second keeps a 27pt band from spending height on an
        // indicator.
        #expect(body.contains(".scrollBounceBehavior(.basedOnSize)"))
        #expect(body.contains(".scrollIndicators(.never)"))
        // And the half that answers the clip: the chosen rung is scrolled into view, so the item
        // you selected is never the one drawn cut in half.
        #expect(body.contains("rail.scrollTo(id, anchor: .center)"),
                "the selected rung is no longer scrolled into view — at a narrow column it can sit off-screen with nothing saying so")
    }
}
