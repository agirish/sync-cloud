import Combine
import Foundation
import Testing
@testable import Sync

/// **A source switch keeps the walk the OTHER pane is showing, so the Compare after it stays warm.**
///
/// The scan derives its maps from cached pane trees only when BOTH sides hit — `executeScan` asks
/// `prefetchedTrees` for the left focus and the right focus together. A switch emptied the whole
/// cache "for memory", and the refresh after it reloads only the pane that moved, so the still
/// pane's side always missed and the scan walked both folders from disk. On his Home vs Dropbox
/// pair that was 4.2–5.8 s and 19 differences after a switch, against 1.5–1.8 s and 75–78 at
/// launch: the cold walk stops at the 200,000-entry budget somewhere else than the pane's walk did,
/// so the answer moved with the time.
///
/// The memory never came back either: the still pane's entry is the array its pane is showing
/// (`theKeptEntryIsTheArrayThePaneIsShowing`), so dropping it freed nothing.
///
/// A kept walk can be old, though, and the comparison read from it is exactly as old: it is dated
/// by its walks (`lastScanReadAt`), not by when it ran.
///
/// Every fixture is on `MockFileManager`, with an empty link table, so nothing here depends on the
/// iCloud links or folders of the Mac it runs on.
@Suite struct SourceSwitchKeepsTheStillPaneTests {

    /// Two sources for the pane that moves, and one for the pane that stays. No root is a prefix of
    /// another: the mock lists by string prefix, so `/r` would also list the children of an `/rx`.
    private static func disk() throws -> MockFileManager {
        let fm = MockFileManager()
        for dir in ["/alpha", "/alpha/Docs", "/beta", "/beta/Docs", "/beta/OnlyBeta", "/still", "/still/Docs"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        // No file differs only in size or date: a walk through a mock file manager carries no
        // metadata (`buildTree`'s `stat`), so a warm scan here could not see such a difference and a
        // cold one could — a mock artifact, not the comparison this suite is about.
        let files: [String: Int] = [
            "/alpha/Docs/same.txt": 1,
            "/beta/Docs/same.txt": 1, "/beta/OnlyBeta/inside.txt": 4,
            "/still/Docs/same.txt": 1, "/still/OnlyStill.txt": 5,
        ]
        for (path, size) in files {
            fm.virtualDisk[path] = .init(isDirectory: false,
                                         attributes: [.size: NSNumber(value: size), .modificationDate: date],
                                         contents: nil)
        }
        return fm
    }

    private static let alpha = CloudProvider(id: "A", displayName: "Alpha", imageName: "", rootPath: "/alpha", type: .iCloud)
    private static let beta = CloudProvider(id: "B", displayName: "Beta", imageName: "", rootPath: "/beta", type: .dropBox)
    private static let still = CloudProvider(id: "S", displayName: "Still", imageName: "", rootPath: "/still", type: .oneDrive)
    /// Alpha after its Location was edited in Settings: the same source, rooted where Beta is.
    private static let alphaMoved = CloudProvider(id: "A", displayName: "Alpha", imageName: "", rootPath: "/beta", type: .iCloud)

    /// What a comparison answered, without the row ids every scan mints afresh.
    @MainActor
    private static func rows(_ m: FileSyncManager) -> [String] {
        m.rawDifferences.map { "\($0.relativePath) \($0.type) \($0.action)" }.sorted()
    }

    /// The ways one pane is re-rooted while the other stays: the source menu, a tab parked on
    /// another source, and an edit of the pane's source's Location in Settings.
    enum Switch: CaseIterable, CustomTestStringConvertible {
        case sourceMenu, tab, locationEdit
        var testDescription: String {
            switch self {
            case .sourceMenu: "source menu"
            case .tab: "tab"
            case .locationEdit: "Location edit"
            }
        }
    }

    /// Which pane moves, and where the one that stays is focused: its root, or a folder below it,
    /// whose walk is cached under the folder's own path.
    struct Panes: CustomTestStringConvertible, Sendable {
        let movedLeft: Bool
        let stillFocus: String
        var testDescription: String {
            "\(movedLeft ? "left" : "right") moves, still pane at \(stillFocus.isEmpty ? "its root" : stillFocus)"
        }
        static let all = [Panes(movedLeft: true, stillFocus: ""), Panes(movedLeft: false, stillFocus: ""),
                          Panes(movedLeft: true, stillFocus: "Docs"), Panes(movedLeft: false, stillFocus: "Docs")]
    }

    /// **The scan after a switch reads the still pane's tree, not its folder.** Driven the way the
    /// app drives it: the switch, then the refresh `ContentView` runs for the moved pane. Any listing
    /// under the still pane's root after the switch can only be the scan's cold walk — the refresh
    /// walks the moved pane alone, which is what the scope says. Both panes take a turn at moving,
    /// because each call site picks the other pane's walk by side, and the still pane is also met
    /// below its root, where its walk is cached under the folder's path and the scan must compose
    /// the same one.
    @MainActor
    @Test(arguments: Switch.allCases, Panes.all)
    func theScanAfterASwitchReadsTheStillPanesTree(_ how: Switch, _ panes: Panes) async throws {
        let movedLeft = panes.movedLeft
        let fm = try Self.disk()
        let m = FileSyncManager(fileManager: fm)
        m.linkedFolders = [:]
        m.setPaneTabs(PaneTabList(tabs: [PaneTab(providerId: "A"), PaneTab(providerId: "B")]), isLeft: movedLeft)
        /// The pair with `moving` on the moving side and Still on the other.
        func pair(_ moving: CloudProvider) -> (left: CloudProvider, right: CloudProvider) {
            movedLeft ? (moving, Self.still) : (Self.still, moving)
        }
        if !panes.stillFocus.isEmpty { m.focusOn(relativePath: panes.stillFocus, isLeft: !movedLeft) }
        let stillWalk = panes.stillFocus.isEmpty ? "/still" : "/still/" + panes.stillFocus

        await m.refreshTreesAndScan(left: pair(Self.alpha).left, right: pair(Self.alpha).right)
        try #require(m.hasScanned)
        try #require(m.prefetchedTrees[stillWalk] != nil, "premise: launch cached the still pane's walk at \(stillWalk)")

        let reads = LockedBox<[String]>([])
        fm.onEnumerate = { url in reads.withLock { $0.append(url.path) } }
        var scopes: [FileSyncManager.PaneReloadScope] = []
        let subscription = m.refreshSubject.sink { scopes.append($0) }
        switch how {
        case .sourceMenu:
            m.retargetPane(isLeft: movedLeft, landing: "")
            subscription.cancel()
            try #require(scopes == [.movedPane(isLeft: movedLeft)],
                         "premise: the switch asks to reload the moved pane alone")
        case .tab:
            let arrived = m.switchTab(to: m.paneTabs(isLeft: movedLeft).tabs[1].id, isLeft: movedLeft,
                                      currentProviderId: "A")
            subscription.cancel()
            // A tab switch publishes nothing: the host writes the provider id, then reloads the
            // pane the tab moved (`ContentView.refreshForTabSwitch`).
            try #require(scopes.isEmpty, "premise: the tab switch asked for a reload itself")
            try #require(arrived?.providerId == "B", "premise: the tab moved the pane to another source")
            scopes = [.movedPane(isLeft: movedLeft)]
        case .locationEdit:
            // `ContentView`'s enabled-providers handler: the edited pane's scope goes to the
            // invalidation, then to the refresh.
            m.invalidateComparisonState(reloading: .movedPane(isLeft: movedLeft))
            subscription.cancel()
            try #require(scopes.isEmpty, "premise: the invalidation asked for a reload itself")
            scopes = [.movedPane(isLeft: movedLeft)]
        }
        let after = pair(how == .locationEdit ? Self.alphaMoved : Self.beta)
        await m.refreshTreesAndScan(left: after.left, right: after.right, reloading: scopes[0])
        try #require(m.hasScanned)

        let all = reads.withLock { $0 }
        let stillReads = all.filter { $0 == "/still" || $0.hasPrefix("/still/") }
        #expect(stillReads.isEmpty,
                "the Compare after the switch read the still pane's folder from disk again: \(stillReads)")
        #expect(all.contains("/beta"), "premise: the moved pane was walked")

        // **And it gives a launch scan's answer for the same pair** — a sanity check, not the
        // discriminator: on the mock both branches answer this pair alike (see `disk()`), so only the
        // read log above tells a warm scan from a cold one.
        fm.onEnumerate = nil
        let fresh = FileSyncManager(fileManager: fm)
        fresh.linkedFolders = [:]
        if !panes.stillFocus.isEmpty { fresh.focusOn(relativePath: panes.stillFocus, isLeft: !movedLeft) }
        await fresh.refreshTreesAndScan(left: after.left, right: after.right)
        try #require(fresh.hasScanned)
        #expect(Self.rows(m) == Self.rows(fresh), "\(Self.rows(m)) vs a launch scan's \(Self.rows(fresh))")
        // At the root: OnlyBeta and OnlyStill.txt. At Docs: Beta's Docs and OnlyBeta, and the
        // still pane's same.txt, which Beta's root does not hold.
        #expect(Self.rows(m).count == (panes.stillFocus.isEmpty ? 2 : 3),
                "premise: the pair has something on each side only: \(Self.rows(m))")
    }

    /// **A walk that could not list its folder is not kept, so the next Compare reads it.** It knows
    /// nothing — the folder itself marked unexplored — and kept, the scan after a switch compared
    /// against it as a side with nothing to say, and a pane switched onto that folder was served it
    /// empty: once access came back, nothing read the folder until Refresh. Measured in the app on
    /// 2026-10-03, after macOS's Documents prompt: a switch and back found 0 differences, a refresh
    /// 917. Both panes take a turn at staying.
    @MainActor
    @Test(arguments: [true, false])
    func aWalkThatCouldNotListItsFolderIsReadAgain(movedLeft: Bool) async throws {
        let fm = try Self.disk()
        let m = FileSyncManager(fileManager: fm)
        m.linkedFolders = [:]
        func pair(_ moving: CloudProvider) -> (left: CloudProvider, right: CloudProvider) {
            movedLeft ? (moving, Self.still) : (Self.still, moving)
        }
        // The still pane's folder cannot be listed when the panes first load…
        fm.unlistableDirectories = ["/still"]
        await m.refreshTreesAndScan(left: pair(Self.alpha).left, right: pair(Self.alpha).right)
        let cached = try #require(m.prefetchedTrees["/still"], "premise: the walk that could not list was cached")
        try #require(FileSyncManager.isUnreadableRootWalk(cached, at: "/still"),
                     "premise: cached as the folder marked unexplored: \(cached.map(\.id))")
        // …then access comes back, and the other pane changes source.
        fm.unlistableDirectories = []
        m.retargetPane(isLeft: movedLeft, landing: "")
        #expect(m.prefetchedTrees["/still"] == nil, "the switch kept a walk that knows nothing")

        await m.refreshTreesAndScan(left: pair(Self.beta).left, right: pair(Self.beta).right,
                                    reloading: .movedPane(isLeft: movedLeft))
        // Read from disk: Beta's OnlyBeta and the still folder's OnlyStill.txt.
        #expect(Self.rows(m).count == 2,
                "the Compare after the switch compared against the walk that could not list: \(Self.rows(m))")
    }

    /// **The Compare after a switch is as old as the walk it read.** The kept walk was taken when
    /// the still pane last loaded, maybe hours ago, and nothing re-reads it on the way into the
    /// scan — so a comparison dated by when it RAN said "just now" over it, and the pill's hour-old
    /// warning never came. Dated by the older of its two walks, it says how old it is, here and on
    /// the not-scanned card. Both sides take a turn at staying, so reading one side's stamp alone
    /// cannot pass.
    @MainActor
    @Test(arguments: [true, false])
    func theComparisonAfterASwitchIsAsOldAsTheStillPanesWalk(movedLeft: Bool) async throws {
        let m = FileSyncManager(fileManager: try Self.disk())
        m.linkedFolders = [:]
        func pair(_ moving: CloudProvider) -> (left: CloudProvider, right: CloudProvider) {
            movedLeft ? (moving, Self.still) : (Self.still, moving)
        }
        await m.refreshTreesAndScan(left: pair(Self.alpha).left, right: pair(Self.alpha).right)
        try #require(m.prefetchedTrees["/still"] != nil, "premise: launch cached the still pane's walk")
        // As far as the cache knows, the still pane walked two hours ago.
        let walked = Date(timeIntervalSinceNow: -2 * 3600)
        m.prefetchedTreeReadAt["/still"] = walked

        m.retargetPane(isLeft: movedLeft, landing: "")
        await m.refreshTreesAndScan(left: pair(Self.beta).left, right: pair(Self.beta).right,
                                    reloading: .movedPane(isLeft: movedLeft))
        let completed = try #require(m.lastScanDate)
        try #require(completed.timeIntervalSince(walked) > 3600, "premise: the scan itself ran just now")
        #expect(m.lastScanReadAt == walked,
                "a comparison of a two-hour-old walk is dated \(m.lastScanReadAt.map { "\($0)" } ?? "nil")")
        #expect(m.lastScanSummary?.date == walked,
                "the not-scanned card would date a two-hour-old comparison by when it ran")
    }

    /// …and a scan that walks both folders read the disk itself, so it is dated when it ran.
    @MainActor
    @Test func aScanThatWalksBothFoldersIsDatedWhenItRan() async throws {
        let m = FileSyncManager(fileManager: try Self.disk())
        m.linkedFolders = [:]
        try #require(m.prefetchedTrees.isEmpty, "premise: nothing is cached, so the scan walks the disk")
        await m.scanDirectories(left: Self.alpha, leftPath: "/alpha", right: Self.still, rightPath: "/still")
        let completed = try #require(m.lastScanDate)
        #expect(m.lastScanReadAt == completed)
        #expect(m.lastScanSummary?.date == completed)
    }

    /// **The kept entry costs nothing, because it is the array on screen.** Every writer of a pane's
    /// cache entry hands the pane the same array — `adoptFreshDeepTree`, the cache-hit path, a
    /// column's graft — so the two share one buffer, and dropping the entry while the pane shows the
    /// tree frees no memory at all. Asserted on the buffer itself rather than on equality, because
    /// equal arrays can still be two copies.
    @MainActor
    @Test func theKeptEntryIsTheArrayThePaneIsShowing() async throws {
        let m = FileSyncManager(fileManager: try Self.disk())
        m.linkedFolders = [:]
        await m.refreshTreesAndScan(left: Self.alpha, right: Self.still)

        let cached = try #require(m.prefetchedTrees["/still"])
        try #require(!cached.isEmpty)
        let onScreen = m.rawRightTree
        #expect(cached.withUnsafeBufferPointer { $0.baseAddress } == onScreen.withUnsafeBufferPointer { $0.baseAddress },
                "the cache entry is a copy of the pane's tree, so keeping it would cost its size")

        m.retargetPane(isLeft: true, landing: "")
        let kept = try #require(m.prefetchedTrees["/still"], "the switch dropped the still pane's walk")
        #expect(kept.withUnsafeBufferPointer { $0.baseAddress } == m.rawRightTree.withUnsafeBufferPointer { $0.baseAddress })
    }

    /// **One walk is kept with everything that describes it, and nothing else survives.** The four
    /// stores part company at no drop site (`dropPrefetchedTrees()`'s own rule): the walk-stopped
    /// bit is what makes a warm scan banner a truncated tree, the read stamp is the pane's freshness,
    /// and the link targets are what a write below a link drops the entry by. A record with no tree
    /// is cleared too, exactly as the whole-cache drop clears it.
    @MainActor
    @Test func keepingOneWalkKeepsItsRecordsAndDropsEveryOther() {
        let m = FileSyncManager(fileManager: MockFileManager())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for key in ["/still", "/alpha", "/alpha/Docs"] {
            m.prefetchedTrees[key] = [FileNode(id: key + "/f", name: "f", isDirectory: false)]
            m.prefetchedTreeWalkStopped.insert(key)
            m.prefetchedTreeReadAt[key] = stamp
            m.prefetchedTreeLinkTargets[key] = ["/target" + key]
        }
        m.prefetchedTreeWalkStopped.insert("/orphan")
        m.prefetchedTreeReadAt["/orphan"] = stamp
        m.prefetchedTreeLinkTargets["/orphan"] = ["/target/orphan"]

        m.dropPrefetchedTrees(keeping: "/still")

        #expect(Array(m.prefetchedTrees.keys) == ["/still"])
        #expect(m.prefetchedTrees["/still"]?.map(\.id) == ["/still/f"])
        #expect(m.prefetchedTreeWalkStopped == ["/still"])
        #expect(m.prefetchedTreeReadAt == ["/still": stamp])
        #expect(m.prefetchedTreeLinkTargets == ["/still": ["/target/still"]])

        // A kept walk the budget did NOT stop keeps no bit, whatever the others had: marked, a
        // complete walk would be bannered as a partial comparison by the next warm scan.
        m.prefetchedTrees = ["/still": [], "/alpha": []]
        m.prefetchedTreeWalkStopped = ["/alpha"]
        m.dropPrefetchedTrees(keeping: "/still")
        #expect(Array(m.prefetchedTrees.keys) == ["/still"] && m.prefetchedTreeWalkStopped.isEmpty)

        // Nothing to keep is the whole-cache drop.
        m.dropPrefetchedTrees(keeping: nil)
        #expect(m.prefetchedTrees.isEmpty && m.prefetchedTreeWalkStopped.isEmpty
                && m.prefetchedTreeReadAt.isEmpty && m.prefetchedTreeLinkTargets.isEmpty)
    }

    /// **A focus with no walk keeps nothing**, records included: a still pane whose deep walk has
    /// not landed has no entry, and its records — if any were left — would describe some other walk.
    @MainActor
    @Test func keepingAFocusWithNoWalkDropsEverything() {
        let m = FileSyncManager(fileManager: MockFileManager())
        m.prefetchedTrees["/alpha"] = []
        m.prefetchedTreeWalkStopped = ["/alpha", "/still"]
        m.prefetchedTreeReadAt = ["/still": Date()]

        m.dropPrefetchedTrees(keeping: "/still")

        #expect(m.prefetchedTrees.isEmpty && m.prefetchedTreeWalkStopped.isEmpty && m.prefetchedTreeReadAt.isEmpty)
    }
}
