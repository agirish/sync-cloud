import Testing
import Foundation
@testable import Dashboard

/// **The arithmetic behind a drag.** All of the risk in reordering is here: an off-by-one puts the
/// row one place from where the user aimed, which reads as the gesture being broken rather than as a
/// rounding choice — and it is invisible in a build that compiles and a suite that never asks.
@Suite struct SidebarReorderTests {

    /// Four rows of unequal height, which is the real case: a favorite carrying a parent qualifier
    /// draws a second line, so any rule computing an index as `translation / rowHeight` is wrong the
    /// moment one row differs, and wrong by more the further you drag.
    static let midpoints: [CGFloat] = [10, 30, 65, 90]

    @Test func draggingAboveEverythingLandsAtTheTop() {
        #expect(SidebarReorder.insertionIndex(forY: 0, midpoints: Self.midpoints) == 0)
        #expect(SidebarReorder.insertionIndex(forY: 9.9, midpoints: Self.midpoints) == 0)
    }

    @Test func draggingBelowEverythingLandsAtTheEnd() {
        #expect(SidebarReorder.insertionIndex(forY: 500, midpoints: Self.midpoints) == 4)
    }

    /// The gaps between midpoints, walked. This is the assertion that would catch a `<=` where a
    /// `<` belongs.
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

    /// **Unequal row heights are handled by construction**, which is the point of taking midpoints
    /// rather than a height: the third row here is 35pt from its neighbour and the first is 20pt,
    /// and both resolve correctly.
    @Test func unequalRowHeightsResolveCorrectly() {
        // Just below row 3's midpoint (65) is still index 2 — a uniform-height rule would have
        // guessed this boundary from the wrong pitch.
        #expect(SidebarReorder.insertionIndex(forY: 64, midpoints: Self.midpoints) == 2)
        #expect(SidebarReorder.insertionIndex(forY: 66, midpoints: Self.midpoints) == 3)
    }

    @Test func anEmptyListAcceptsOnlyIndexZero() {
        #expect(SidebarReorder.insertionIndex(forY: 0, midpoints: []) == 0)
        #expect(SidebarReorder.insertionIndex(forY: 999, midpoints: []) == 0)
    }

    // MARK: - The move itself

    /// **Dragging down.** `to` is measured against the original list, so moving item 0 into the gap
    /// after item 2 is `to == 3` — and the result must be `[b, c, a]`, not `[b, a, c]`. This is the
    /// off-by-one that makes every downward drag land one place short.
    @Test func movingDownAccountsForTheLiftedRow() {
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 0, to: 3) == ["b", "c", "a", "d"])
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 0, to: 4) == ["b", "c", "d", "a"])
    }

    /// **Dragging up** needs no adjustment, because nothing below the destination has moved.
    @Test func movingUpInsertsWhereAimed() {
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: 2, to: 1) == ["a", "c", "b", "d"])
    }

    /// A move to where it already is changes nothing — asserted on the result as well as through
    /// `isNoOp`, because the two are used at different moments and only one of them is consulted
    /// before the write.
    @Test func aMoveToItsOwnPlaceChangesNothing() {
        for (from, to) in [(1, 1), (1, 2), (0, 0), (0, 1), (3, 3), (3, 4)] {
            #expect(SidebarReorder.moved(["a", "b", "c", "d"], from: from, to: to) == ["a", "b", "c", "d"],
                    "moving \(from) to \(to) reordered a list it should have left alone")
            #expect(SidebarReorder.isNoOp(from: from, to: to),
                    "isNoOp says \(from)->\(to) is a change, so it would write to defaults for nothing")
        }
    }

    /// And the moves that *are* changes are not mistaken for no-ops — the other direction, which a
    /// too-eager guard would silently swallow.
    @Test func realMovesAreNotReportedAsNoOps() {
        for (from, to) in [(0, 2), (0, 3), (2, 0), (3, 1)] {
            #expect(!SidebarReorder.isNoOp(from: from, to: to),
                    "isNoOp swallows the real move \(from)->\(to)")
        }
    }

    /// Out-of-range indices return the list untouched rather than trapping. The `from` comes from a
    /// row identity that can go stale mid-drag — a background refresh can remove a favorite while
    /// the pointer is down — and a trap there would take the app out.
    @Test func outOfRangeIndicesAreRefusedRatherThanTrapping() {
        #expect(SidebarReorder.moved(["a", "b"], from: 5, to: 0) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: -1, to: 0) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: 0, to: 9) == ["a", "b"])
        #expect(SidebarReorder.moved(["a", "b"], from: 0, to: -1) == ["a", "b"])
        #expect(SidebarReorder.moved([String](), from: 0, to: 0) == [])
    }
}

/// **The order that survives a relaunch**, and what it does about entries it has never heard of.
@Suite struct FavoriteOrderTests {

    private func visit(_ root: String, _ path: String) -> RememberedVisit {
        RememberedVisit(root: root, relativePath: path,
                        name: (path as NSString).lastPathComponent, visitedAt: nil)
    }

    private func key(_ root: String, _ path: String) -> String {
        FolderJumpStore.favoriteKey(root: root, relativePath: path)
    }

    /// With no stored order — every install before the first drag — the section keeps the
    /// deterministic order it already had. Nothing jumps, nothing needs migrating.
    @Test func anEmptyOrderLeavesTheListAlone() {
        let list = [visit("/a", "One"), visit("/b", "Two")]
        #expect(FolderJumpStore.orderedFavorites(list, order: []).map(\.relativePath) == ["One", "Two"])
    }

    /// The stored order wins, **across sources** — which is the whole point, since the section is
    /// one flat list with badges and no visible boundary to snap back at.
    @Test func theStoredOrderReordersAcrossSources() {
        let list = [visit("/iCloud", "Taxes"), visit("/Dropbox", "Health"), visit("/iCloud", "Scans")]
        let out = FolderJumpStore.orderedFavorites(
            list, order: [key("/Dropbox", "Health"), key("/iCloud", "Scans"), key("/iCloud", "Taxes")])
        #expect(out.map(\.relativePath) == ["Health", "Scans", "Taxes"])
        #expect(out.map(\.root) == ["/Dropbox", "/iCloud", "/iCloud"])
    }

    /// **A favorite added after the last drag appends** rather than jumping to the front or
    /// vanishing. This is what makes the empty-tail design safe without a migration pass.
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

    /// **The unranked tail keeps a stable order between runs.** A single `sorted(by:)` over an
    /// optional rank would leave it free to shuffle, because Swift's sort is not stable — and a
    /// Favorites list that rearranged its newest entries on every launch would look broken.
    @Test func theUnrankedTailDoesNotShuffleBetweenRuns() {
        let list = [visit("/a", "P"), visit("/a", "Q"), visit("/a", "R"), visit("/a", "S")]
        let order = [key("/a", "S")]
        let answers = Set((0..<40).map { _ in
            FolderJumpStore.orderedFavorites(list, order: order).map(\.relativePath).joined(separator: ">")
        })
        #expect(answers == ["S>P>Q>R"], "the unranked tail varies between runs: \(answers)")
    }

    /// **The composite key cannot confuse two different folders.** `/a` + `b/c` and `/a/b` + `c` are
    /// two folders in two sources; a `/` or `:` separator would give them one key and the drag would
    /// move the wrong row.
    @Test func theCompositeKeyDistinguishesRootFromPath() {
        #expect(key("/a", "b/c") != key("/a/b", "c"))
    }

    /// Duplicate keys in a stored order do not crash or drop a row — the first occurrence wins,
    /// which is the only answer that keeps the list the same length as its input.
    @Test func aDuplicatedKeyInTheOrderIsTolerated() {
        let list = [visit("/a", "One"), visit("/a", "Two")]
        let out = FolderJumpStore.orderedFavorites(
            list, order: [key("/a", "Two"), key("/a", "Two"), key("/a", "One")])
        #expect(out.map(\.relativePath) == ["Two", "One"])
    }
}

/// **Reordering part of a list without disturbing the rest**, and keeping a drop inside its band.
///
/// Both exist because the Locations drag was indexed against the wrong list. It reported a position
/// in `locationRows` — what is drawn — while the handler indexed `enabledProviders`, and the two
/// differ whenever a provider's folder is a canonical place: that provider is claimed and drawn in
/// Favorites instead. With `~/Desktop` and `~/Downloads` as folder sources, an ordinary setup, the
/// cloud band is the provider list minus two and every index past the first claimed one addressed
/// the wrong source.
@Suite struct SidebarSubsetReorderTests {

    /// The members take the positions the members already held, in their new order. Everything else
    /// stays at its own index.
    @Test func nonMembersKeepTheirExactPositions() {
        let all = ["a", "desktop", "b", "downloads", "c"]
        let reordered = SidebarReorder.reordering(all, subsetInNewOrder: ["c", "b", "a"])
        #expect(reordered == ["c", "desktop", "b", "downloads", "a"])
    }

    /// **The failure this replaced.** Appending the untouched sources after the reordered ones
    /// moves every one of them to the end of the pane header's dropdown as a side effect of a drag
    /// in a different section — a change the user did not ask for and would not connect to it.
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

    /// **An id in the subset that is not in the list is ignored, not inserted.** The subset is a
    /// new ORDER for existing members, never a membership change — a reorder that could grow or
    /// shrink a list is a different operation wearing this one's name.
    ///
    /// The first version of this test asserted a disjunction, which is what writing an assertion
    /// against behaviour you have not decided on looks like: it passed while a stranger REPLACED a
    /// member. Both the function and the test say one thing now.
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

    /// A cloud row cannot be dropped into the device band: the bands are re-applied when the rows
    /// are built, so it would be re-grouped back and the move would appear to do nothing while the
    /// insertion line had promised it.
    @Test func aCloudDropIsClampedToTheCloudBand() {
        #expect(SidebarReorder.clampedToBand(7, bandStart: 0, bandEnd: 4) == 4)
        #expect(SidebarReorder.clampedToBand(2, bandStart: 0, bandEnd: 4) == 2)
    }

    @Test func aDeviceDropIsClampedToTheDeviceBand() {
        #expect(SidebarReorder.clampedToBand(0, bandStart: 4, bandEnd: 7) == 4)
        #expect(SidebarReorder.clampedToBand(9, bandStart: 4, bandEnd: 7) == 7)
        #expect(SidebarReorder.clampedToBand(5, bandStart: 4, bandEnd: 7) == 5)
    }

    /// The end of a band is a legal insertion index — it is the gap AFTER the last row, which is
    /// where a downward drag within the band lands.
    @Test func aBandsOwnEndIsReachable() {
        #expect(SidebarReorder.clampedToBand(4, bandStart: 0, bandEnd: 4) == 4)
    }
}

/// **The drag's order has to reach the rows**, which is the half that was missing.
///
/// `FolderJumpStore.orderedFavorites` was written for this, tested seven ways in the suite above,
/// and then called by nobody on the path that builds rows: `FolderSidebarModel.rows` concatenated
/// the per-root favorite lists in source order and stopped. So every folder-favorite drag persisted
/// a sequence, logged that it had, and the column came back in the old order on the next refresh —
/// with no error anywhere, because both halves were individually correct.
///
/// Asserted against the BUILDER rather than against the rule, for that reason: a rule with no
/// caller passes its own tests forever.
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

    /// **Across sources**, which is the case per-root arrays cannot express at all and therefore the
    /// one that proves the sequence is being read.
    @Test func thePersistedSequenceDecidesTheDrawnOrder() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes", "Scans"]), source("/Dropbox", ["Health"])],
            recents: [],
            favoriteOrder: [key("/Dropbox", "Health"), key("/iCloud", "Scans"), key("/iCloud", "Taxes")])
        #expect(favorites(rows) == ["Health", "Scans", "Taxes"])
    }

    /// No sequence stored — every install before its first drag — leaves the section exactly where
    /// it was, in the caller's source order.
    @Test func withNoStoredSequenceTheSourceOrderStands() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes"]), source("/Dropbox", ["Health"])],
            recents: [], favoriteOrder: [])
        #expect(favorites(rows) == ["Taxes", "Health"])
    }

    /// A favorite the sequence has never heard of appends beside its own account rather than
    /// jumping to the front or disappearing — the property that makes the sequence safe with no
    /// migration pass.
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

    /// A sequence naming a favorite that is no longer reachable — its folder deleted, so
    /// `reachable` dropped it — leaves no hole and does not resurrect the row.
    @Test func aSequenceNamingAnUndrawnFavoriteLeavesNoHole() {
        let rows = FolderSidebarModel.rows(
            sources: [source("/iCloud", ["Taxes"])], recents: [],
            favoriteOrder: [key("/iCloud", "Deleted"), key("/iCloud", "Taxes")])
        #expect(favorites(rows) == ["Taxes"])
    }
}
