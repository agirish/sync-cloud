import Testing
import Foundation
@testable import Dashboard

/// The arithmetic behind a drag, where the risk in reordering lives: an off-by-one puts the row one
/// place from where the user aimed, which reads as a broken gesture.
@Suite struct SidebarReorderTests {

    /// Four rows of unequal height, the real case: a favorite with a parent qualifier draws a second
    /// line, so an index computed as `translation / rowHeight` drifts the further you drag.
    static let midpoints: [CGFloat] = [10, 30, 65, 90]

    @Test func draggingAboveEverythingLandsAtTheTop() {
        #expect(SidebarReorder.insertionIndex(forY: 0, midpoints: Self.midpoints) == 0)
        #expect(SidebarReorder.insertionIndex(forY: 9.9, midpoints: Self.midpoints) == 0)
    }

    @Test func draggingBelowEverythingLandsAtTheEnd() {
        #expect(SidebarReorder.insertionIndex(forY: 500, midpoints: Self.midpoints) == 4)
    }

    /// The gaps between midpoints, walked. Catches a `<=` where a `<` belongs.
    @Test func eachGapResolvesToItsOwnIndex() {
        #expect(SidebarReorder.insertionIndex(forY: 20, midpoints: Self.midpoints) == 1)
        #expect(SidebarReorder.insertionIndex(forY: 45, midpoints: Self.midpoints) == 2)
        #expect(SidebarReorder.insertionIndex(forY: 80, midpoints: Self.midpoints) == 3)
    }

    /// Exactly on a midpoint counts as past it, so the boundary has one answer rather than
    /// depending on floating-point noise a pointer position is full of.
    @Test func aPointerExactlyOnAMidpointIsPastIt() {
        #expect(SidebarReorder.insertionIndex(forY: 30, midpoints: Self.midpoints) == 2)
    }

    /// Midpoints rather than a row height handle unequal rows by construction: here the gaps are
    /// 20pt and 35pt, and both resolve correctly.
    @Test func unequalRowHeightsResolveCorrectly() {
        // Just below row 3's midpoint (65) is still index 2; a uniform-height rule would put this
        // boundary at the wrong pitch.
        #expect(SidebarReorder.insertionIndex(forY: 64, midpoints: Self.midpoints) == 2)
        #expect(SidebarReorder.insertionIndex(forY: 66, midpoints: Self.midpoints) == 3)
    }

    @Test func anEmptyListAcceptsOnlyIndexZero() {
        #expect(SidebarReorder.insertionIndex(forY: 0, midpoints: []) == 0)
        #expect(SidebarReorder.insertionIndex(forY: 999, midpoints: []) == 0)
    }

    // MARK: - The move itself

    /// Dragging down: `to` is measured against the original list, so moving item 0 into the gap
    /// after item 2 is `to == 3` and must give `[b, c, a]`, not `[b, a, c]`, or every downward drag
    /// lands one place short.
    @Test func movingDownAccountsForTheLiftedRow() {
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 0, to: 3) == ["b", "c", "a", "d"])
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 0, to: 4) == ["b", "c", "d", "a"])
    }

    /// Dragging up needs no adjustment, because nothing below the destination has moved.
    @Test func movingUpInsertsWhereAimed() {
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 2, to: 1) == ["a", "c", "b", "d"])
    }

    /// A move to where it already is changes nothing, asserted on the result and through `isNoOp`,
    /// because only `isNoOp` is consulted before the write.
    @Test func aMoveToItsOwnPlaceChangesNothing() {
        for (from, to) in [(1, 1), (1, 2), (0, 0), (0, 1), (3, 3), (3, 4)] {
            #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: from, to: to) == ["a", "b", "c", "d"],
                    "moving \(from) to \(to) reordered a list it should have left alone")
            #expect(SidebarReorder.isNoOp(from: from, to: to),
                    "isNoOp says \(from)->\(to) is a change, so it would write to defaults for nothing")
        }
    }

    /// And real moves are not mistaken for no-ops, which a too-eager guard would swallow.
    @Test func realMovesAreNotReportedAsNoOps() {
        for (from, to) in [(0, 2), (0, 3), (2, 0), (3, 1)] {
            #expect(!SidebarReorder.isNoOp(from: from, to: to),
                    "isNoOp swallows the real move \(from)->\(to)")
        }
    }

    /// Out-of-range indices return the list untouched rather than trapping. `from` comes from a row
    /// identity that can go stale mid-drag (a background refresh can remove a favorite while the
    /// pointer is down), and a trap would crash the app.
    @Test func outOfRangeIndicesAreRefusedRatherThanTrapping() {
        #expect(SidebarReorder.moved(["a", "b"], from: 5, to: 0) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: -1, to: 0) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: 0, to: 9) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: 0, to: -1) == ["a", "b"])
        #expect(SidebarReorder.moved([String](), from: 0, to: 0) == [])
    }
}

/// The order that survives a relaunch, and what it does with entries it has never heard of.
@Suite struct FavoriteOrderTests {

    private func visit(_ root: String, _ path: String) -> RememberedVisit {
        RememberedVisit(root: root, relativePath: path,
                        name: (path as NSString).lastPathComponent, visitedAt: nil)
    }

    private func key(_ root: String, _ path: String) -> String {
        FolderJumpStore.favoriteKey(root: root, relativePath: path)
    }

    /// With no stored order (before the first drag) the section keeps its deterministic order, so
    /// nothing jumps and nothing needs migrating.
    @Test func anEmptyOrderLeavesTheListAlone() {
        let list = [visit("/a", "One"), visit("/b", "Two")]
        #expect(FolderJumpStore.orderedFavorites(list, order: []).map(\.relativePath) == ["One", "Two"])
    }

    /// The stored order wins across sources, since the section is one flat list with badges and no
    /// visible boundary between sources.
    @Test func theStoredOrderReordersAcrossSources() {
        let list = [visit("/iCloud", "Taxes"), visit("/Dropbox", "Health"), visit("/iCloud", "Scans")]
        let out = FolderJumpStore.orderedFavorites(
            list, order: [key("/Dropbox", "Health"), key("/iCloud", "Scans"), key("/iCloud", "Taxes")])
        #expect(out.map(\.relativePath) == ["Health", "Scans", "Taxes"])
        #expect(out.map(\.root) == ["/Dropbox", "/iCloud", "/iCloud"])
    }

    /// A favorite added after the last drag appends rather than jumping to the front or vanishing,
    /// which makes the design safe without a migration pass.
    @Test func aFavoriteTheOrderHasNeverSeenGoesToTheEnd() {
        let list = [visit("/a", "Old"), visit("/a", "New"), visit("/a", "Older")]
        let out = FolderJumpStore.orderedFavorites(list, order: [key("/a", "Older"), key("/a", "Old")])
        #expect(out.map(\.relativePath) == ["Older", "Old", "New"])
    }

    /// A key naming a favorite that no longer exists is ignored — no hole, and no resurrection.
    @Test func aStaleKeyInTheOrderIsIgnored() {
        let list = [visit("/a", "Kept")]
        let out = FolderJumpStore.orderedFavorites(
            list, order: [key("/a", "Removed"), key("/a", "Kept")])
        #expect(out.map(\.relativePath) == ["Kept"])
    }

    /// The unranked tail keeps a stable order between runs. Swift's sort is not stable, so one
    /// `sorted(by:)` over an optional rank could shuffle the newest entries on every launch.
    @Test func theUnrankedTailDoesNotShuffleBetweenRuns() {
        let list = [visit("/a", "P"), visit("/a", "Q"), visit("/a", "R"), visit("/a", "S")]
        let order = [key("/a", "S")]
        let answers = Set((0..<40).map { _ in
            FolderJumpStore.orderedFavorites(list, order: order).map(\.relativePath).joined(separator: ">")
        })
        #expect(answers == ["S>P>Q>R"], "the unranked tail varies between runs: \(answers)")
    }

    /// The composite key can't confuse two folders: `/a` + `b/c` and `/a/b` + `c` are in different
    /// sources, and a `/` or `:` separator would give them one key, so a drag moves the wrong row.
    @Test func theCompositeKeyDistinguishesRootFromPath() {
        #expect(key("/a", "b/c") != key("/a/b", "c"))
    }

    /// Duplicate keys in a stored order don't crash or drop a row: the first occurrence wins, which
    /// keeps the list the same length as its input.
    @Test func aDuplicatedKeyInTheOrderIsTolerated() {
        let list = [visit("/a", "One"), visit("/a", "Two")]
        let out = FolderJumpStore.orderedFavorites(
            list, order: [key("/a", "Two"), key("/a", "Two"), key("/a", "One")])
        #expect(out.map(\.relativePath) == ["Two", "One"])
    }
}

/// Reordering part of a list without disturbing the rest, and keeping a drop inside its band.
///
/// A Locations drag reports a position in `locationRows`, what is drawn, which differs from
/// `enabledProviders` whenever a provider's folder is a canonical place and is drawn in Favorites
/// instead (`~/Desktop` as a folder source, say). Indexing the full list by a drawn position would
/// move the wrong source.
@Suite struct SidebarSubsetReorderTests {

    /// The members take the positions the members already held, in their new order. Everything else
    /// stays at its own index.
    @Test func nonMembersKeepTheirExactPositions() {
        let all = ["a", "desktop", "b", "downloads", "c"]
        let reordered = SidebarReorder.reordering(all, subsetInNewOrder: ["c", "b", "a"])
        #expect(reordered == ["c", "desktop", "b", "downloads", "a"])
    }

    /// Untouched sources stay put. Appending them after the reordered ones would move them to the
    /// end of the pane header's dropdown as a side effect of a drag in another section.
    @Test func untouchedSourcesAreNotShovedToTheEnd() {
        let all = ["a", "desktop", "b"]
        let reordered = SidebarReorder.reordering(all, subsetInNewOrder: ["b", "a"])
        #expect(reordered.firstIndex(of: "desktop") == 1,
                "an untouched source moved because a visible one was dragged: \(reordered)")
    }

    @Test func aSubsetThatChangesNothingChangesNothing() {
        let all = ["a", "b", "c"]
        #expect(SidebarReorder.reordering(all, subsetInNewOrder: ["a", "c"]) == all)
    }

    /// An id in the subset that is not in the list is ignored, not inserted, and never displaces a
    /// member. The subset is a new order for existing members, never a membership change.
    @Test func aStrangerInTheSubsetIsIgnoredEntirely() {
        #expect(SidebarReorder.reordering(["a", "b"], subsetInNewOrder: ["stranger", "a"]) == ["a", "b"],
                "a stranger displaced a real member")
        #expect(SidebarReorder.reordering(["a", "b"], subsetInNewOrder: ["b", "stranger", "a"]) == ["b", "a"])
    }

    /// Reordering never changes what is in the list, only where.
    @Test func reorderingPreservesMembershipExactly() {
        let all = ["a", "b", "c", "d"]
        for subset in [["c", "a"], ["d", "b", "a"], [], ["a", "b", "c", "d"]] {
            let out = SidebarReorder.reordering(all, subsetInNewOrder: subset)
            #expect(Set(out) == Set(all), "membership changed for subset \(subset): \(out)")
            #expect(out.count == all.count, "length changed for subset \(subset): \(out)")
        }
    }

    // MARK: - The band clamp

    /// A cloud row can't be dropped into the device band: the bands are re-applied when rows are
    /// built, so the row would snap back and the move the insertion line promised would do nothing.
    @Test func aCloudDropIsClampedToTheCloudBand() {
        #expect(SidebarReorder.clampedToBand(7, bandStart: 0, bandEnd: 4) == 4)
        #expect(SidebarReorder.clampedToBand(2, bandStart: 0, bandEnd: 4) == 2)
    }

    @Test func aDeviceDropIsClampedToTheDeviceBand() {
        #expect(SidebarReorder.clampedToBand(0, bandStart: 4, bandEnd: 7) == 4)
        #expect(SidebarReorder.clampedToBand(9, bandStart: 4, bandEnd: 7) == 7)
        #expect(SidebarReorder.clampedToBand(5, bandStart: 4, bandEnd: 7) == 5)
    }

    /// The end of a band is a legal insertion index: the gap after the last row, where a downward
    /// drag within the band lands.
    @Test func aBandsOwnEndIsReachable() {
        #expect(SidebarReorder.clampedToBand(4, bandStart: 0, bandEnd: 4) == 4)
    }
}

/// The drag's order has to reach the rows. `FolderJumpStore.orderedFavorites` is tested above, but
/// a rule with no caller passes its own tests forever, so this asserts against the builder,
/// `FolderSidebarModel.rows`. If it skipped the rule, a drag would persist its order and the column
/// would come back in the old order on the next refresh.
@Suite struct FavoriteOrderReachesTheRowsTests {

    private func source(_ root: String, _ favorites: [String]) -> FolderSidebarModel.Source {
        .init(root: root, name: (root as NSString).lastPathComponent,
              favorites: favorites, isAvailable: true)
    }

    private func key(_ root: String, _ path: String) -> String {
        FolderJumpStore.favoriteKey(root: root, relativePath: path)
    }

    private func favorites(_ rows: [FolderSidebarRow]) -> [String] {
        FolderSidebarModel.rows(rows, in: .pinned).map(\.name)
    }

    /// Across sources, which per-root arrays can't express, so it proves the sequence is read.
    @Test func thePersistedSequenceDecidesTheDrawnOrder() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes", "Scans"]), source("/Dropbox", ["Health"])],
            recents: [],
            favoriteOrder: [key("/Dropbox", "Health"), key("/iCloud", "Scans"), key("/iCloud", "Taxes")])
        #expect(favorites(rows) == ["Health", "Scans", "Taxes"])
    }

    /// With no sequence stored (before the first drag) the section stays in the caller's source
    /// order.
    @Test func withNoStoredSequenceTheSourceOrderStands() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes"]), source("/Dropbox", ["Health"])],
            recents: [], favoriteOrder: [])
        #expect(favorites(rows) == ["Taxes", "Health"])
    }

    /// A favorite the sequence has never heard of appends beside its own account rather than
    /// jumping to the front or disappearing, so the sequence needs no migration pass.
    @Test func aFavoriteTheSequenceDoesNotNameStillDraws() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes", "New"]), source("/Dropbox", ["Health"])],
            recents: [],
            favoriteOrder: [key("/Dropbox", "Health"), key("/iCloud", "Taxes")])
        #expect(favorites(rows) == ["Health", "Taxes", "New"])
    }

    /// The sequence reorders Favorites and touches nothing else: Recents are ordered by when you
    /// were there, and a key naming one must not move it.
    @Test func theSequenceDoesNotReachRecents() {
        let visits = ["First", "Second"].map {
            RememberedVisit(root: "/iCloud", relativePath: $0, name: $0, visitedAt: nil)
        }
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", [])], recents: visits,
            favoriteOrder: [key("/iCloud", "Second"), key("/iCloud", "First")])
        #expect(FolderSidebarModel.rows(rows, in: .recents).map(\.name) == ["First", "Second"])
    }

    /// A sequence naming a favorite that is no longer reachable (its folder deleted, so `reachable`
    /// dropped it) leaves no hole and doesn't resurrect the row.
    @Test func aSequenceNamingAnUndrawnFavoriteLeavesNoHole() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes"])], recents: [],
            favoriteOrder: [key("/iCloud", "Deleted"), key("/iCloud", "Taxes")])
        #expect(favorites(rows) == ["Taxes"])
    }
}
