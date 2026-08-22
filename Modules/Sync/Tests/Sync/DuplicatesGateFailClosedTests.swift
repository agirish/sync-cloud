import Testing
import Foundation
import Events
@testable import Sync

/// The three fail-open seams the duplicates round left behind: a gate closure that refuses nothing
/// when its manager is gone, a nested path pruned out of the gate's input and destroyed anyway via
/// its ancestor, and a refusal that logs a basename where its siblings log a path.
@Suite struct DuplicatesGateFailClosedTests {

    private func stub(size: Int, modified: Date = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [.size: size, .modificationDate: modified],
                                 contents: nil)
    }

    private func group(keeper: String, redundant: String, reclaim: Int = 1000,
                       modified: Date = Date(timeIntervalSince1970: 1_000)) -> DuplicateGroup {
        let k = DuplicateCopy(id: keeper, name: (keeper as NSString).lastPathComponent, isDirectory: false,
                              size: reclaim, itemCount: 1, modificationDate: modified,
                              uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant, name: (redundant as NSString).lastPathComponent, isDirectory: false,
                              size: reclaim, itemCount: 1, modificationDate: modified,
                              uniqueItemCount: 0, depth: 0, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: (keeper as NSString).lastPathComponent,
                              isDirectory: false, copies: [k, r], reclaimableBytes: reclaim)
    }

    @MainActor
    /// Reads the DISK log, not `Logger.shared.entries` — the in-memory array is capped at 1000 and
    /// a parallel run evicts this suite's line before the assertion gets to it. See
    /// `loggedLineOnDisk(containing:)`.
    private func loggedLine(containing fragment: String) async -> String? {
        await loggedLineOnDisk(containing: fragment)
    }

    // MARK: A gate whose manager is gone refuses EVERYTHING

    /// `guard let self else { return [] }` refused nothing and removed everything, in a file whose
    /// two gate BODIES are explicitly fail-closed for exactly this reason: "nothing has re-verified
    /// this" and "this may be destroyed" must never be the same outcome. Unreachable through the
    /// call sites (both hold `self` on the awaiting frame), which is why the closure is reached
    /// here directly — and why `Set(about)` costs the ordinary path nothing.
    @MainActor
    @Test func theDuplicatesGateRefusesEverythingWhenItsManagerIsGone() async throws {
        var gate: (@Sendable ([String]) async -> Set<String>)?
        weak var weakManager: FileSyncManager?
        do {
            let manager = FileSyncManager(fileManager: MockFileManager())
            weakManager = manager
            gate = manager.duplicateRemovalGate(groups: [group(keeper: "/a/x", redundant: "/b/x")],
                                                refusals: FileSyncManager.DuplicateRemovalRefusals())
        }
        try #require(weakManager == nil,
                     "the manager outlived its scope — the nil-self branch was never reached, so this pins nothing")
        let closure = try #require(gate)
        let refused = await closure(["/b/x", "/c/y"])
        #expect(refused == ["/b/x", "/c/y"],
                "a gate with no manager waved paths through unverified: \(refused)")
    }

    @MainActor
    @Test func theMergeGateRefusesEverythingWhenItsManagerIsGone() async throws {
        var gate: (@Sendable ([String]) async -> Set<String>)?
        weak var weakManager: FileSyncManager?
        let g = group(keeper: "/a/x", redundant: "/b/x")
        do {
            let manager = FileSyncManager(fileManager: MockFileManager())
            weakManager = manager
            gate = manager.mergeRemovalGate(group: g, folds: [],
                                            refusals: FileSyncManager.MergeRemovalRefusals())
        }
        try #require(weakManager == nil,
                     "the manager outlived its scope — the nil-self branch was never reached, so this pins nothing")
        let closure = try #require(gate)
        let refused = await closure(["/b/x"])
        #expect(refused == ["/b/x"],
                "a merge gate with no manager waved a fold through unverified: \(refused)")
    }

    // MARK: A path pruned in favour of an ancestor is still verified — and condemns the ancestor

    /// `deleteItems` prunes nested paths so only the ancestor is trashed, and it used to hand the
    /// gate the PRUNED list. The child was then verified by nothing and destroyed anyway, with the
    /// duplicates gate's own fail-closed `unattributed` block blind to it (it is computed from the
    /// list it was given). Now the child is asked about, and a refused child condemns the ancestor
    /// that would take it down.
    @MainActor
    @Test func aRefusedNestedPathAlsoRefusesTheAncestorThatWouldDestroyIt() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.permanentDeleteConfirmer = { _ in false }
        mockFM.virtualDisk["/r"] = stub(size: 100)
        mockFM.virtualDisk["/r/inner"] = stub(size: 10)

        let asked = LockedBox<[[String]]>([])
        let outcome = await manager.deleteItems(at: ["/r", "/r/inner"], fileManager: mockFM,
                                                removalGate: { about in
            asked.withLock { $0.append(about.sorted()) }
            return about.contains("/r/inner") ? ["/r/inner"] : []
        })

        #expect(asked.withLock { $0 }.first?.contains("/r/inner") == true,
                "the pruned child was never put to the gate: \(asked.withLock { $0 })")
        #expect(mockFM.virtualDisk["/r"] != nil,
                "the ancestor was trashed, destroying a path the gate had just refused with it")
        #expect(outcome.removed == 0)
        #expect(mockFM.trashedPaths.isEmpty)
        let line = await loggedLine(containing: "which is nested inside it")
        #expect(line?.contains("/r") == true, "the ancestor refusal was not logged: “\(line ?? "nil")”")
    }

    /// The control: pruning still happens, and a gate that refuses nothing still trashes only the
    /// ancestor — one removal, not two.
    @MainActor
    @Test func pruningStillCollapsesANestedPairWhenTheGateRefusesNothing() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        mockFM.virtualDisk["/r"] = stub(size: 100)
        mockFM.virtualDisk["/r/inner"] = stub(size: 10)

        let outcome = await manager.deleteItems(at: ["/r", "/r/inner"], fileManager: mockFM,
                                                removalGate: { _ in [] })

        #expect(outcome.removed == 1, "the nested pair stopped collapsing to one removal")
        #expect(mockFM.virtualDisk["/r"] == nil)
    }

    // MARK: The single resolve's pre-check refusals log paths, like every sibling refusal

    /// Three copies named `IMG_0421.jpg` are not diagnosable from a log line naming `IMG_0421.jpg`.
    /// The gate logs keeper path + culprit path, the batch logs keeper path + culprit path, and the
    /// gate's own doc claims the single resolve and the batch "report identically" — which was true
    /// of the gate's refusals and false of the pre-checks that share their wording.
    @MainActor
    @Test func theSingleResolveDriftRefusalLogsBothPaths() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.permanentDeleteConfirmer = { _ in false }
        mockFM.virtualDisk["/Pictures/2019/IMG_0421.jpg"] = stub(size: 1000)
        mockFM.virtualDisk["/Desktop/Old/IMG_0421.jpg"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 9_999))
        let g = group(keeper: "/Pictures/2019/IMG_0421.jpg", redundant: "/Desktop/Old/IMG_0421.jpg")
        manager.duplicateGroups = [g]

        // Windowed, not last-match: "refused to remove copies of" is written by five call sites and
        // by this suite's sibling tests, all over the SAME constant paths, so the last line in a
        // per-process log carrying that fragment is routinely another test's. That is what the
        // in-memory read was really failing on once eviction was ruled out.
        let tag = UUID().uuidString
        var resolved = true
        let mine = try await logLines(tag: tag) {
            resolved = await manager.resolveDuplicateGroup(g)
        }
        #expect(resolved == false)

        let line = mine.last { $0.contains("refused to remove copies of") }
        #expect(line?.contains("/Pictures/2019/IMG_0421.jpg") == true,
                "the refusal does not name the keeper's path: “\(line ?? "nil")”")
        #expect(line?.contains("/Desktop/Old/IMG_0421.jpg") == true,
                "the refusal does not name the culprit's path: “\(line ?? "nil")”")
    }

    // MARK: A refusal that arrives AFTER part of the group was removed is not "left alone"

    /// Both gate invocations share one `DuplicateRemovalRefusals`, and the second runs after the
    /// first pass has trashed everything it could. A group whose remaining copy is refused there
    /// was counted into `refused` and then described by the partial banner as having been "left
    /// alone" — false of the copies of it already in the Trash.
    ///
    /// The fixture: one group, two redundant copies. `/b/x` (shortest, so it is attempted first)
    /// hits a Trash-less failure; `/ccc/x` trashes. The user is then asked to confirm the
    /// permanent delete of `/b/x`, and while the sheet is up the KEEPER goes away — so the
    /// post-confirmation gate refuses the group, with one of its copies already trashed.
    @MainActor
    @Test func aGroupRefusedAfterPartOfItWasRemovedIsNotReportedAsLeftAlone() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/ccc/x"] = stub(size: 1000)
        let k = DuplicateCopy(id: "/a/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                              modificationDate: Date(timeIntervalSince1970: 1_000), uniqueItemCount: 0,
                              depth: 0, isRecommendedKeeper: true)
        let r1 = DuplicateCopy(id: "/b/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                               modificationDate: Date(timeIntervalSince1970: 1_000), uniqueItemCount: 0,
                               depth: 0, isRecommendedKeeper: false)
        let r2 = DuplicateCopy(id: "/ccc/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                               modificationDate: Date(timeIntervalSince1970: 1_000), uniqueItemCount: 0,
                               depth: 0, isRecommendedKeeper: false)
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [k, r1, r2], reclaimableBytes: 2000)
        manager.duplicateGroups = [g]
        // Non-transient, so it escalates to the permanent-delete prompt rather than being retried.
        mockFM.trashErrorOnce = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        manager.permanentDeleteConfirmer = { _ in
            mockFM.virtualDisk["/a/x"] = nil     // the keeper leaves while the sheet is open
            return true
        }

        await manager.applyRecommendedDuplicates([g])

        // The premise: one copy really did go, the other really was refused.
        try #require(mockFM.virtualDisk["/ccc/x"] == nil, "no copy was trashed — this is not the partial case")
        try #require(mockFM.virtualDisk["/b/x"] != nil, "the refused copy was destroyed anyway")

        let message = manager.banner?.message ?? ""
        #expect(message.contains("left alone") == false,
                "a group with a copy already in the Trash was reported as left alone: “\(message)”")
        #expect(message.contains("after part of it had already been removed"),
                "the banner does not say what actually happened: “\(message)”")
        #expect(await loggedLine(containing: "after part of them had already been removed") != nil)
    }

    // MARK: The merge's refusals are identified by path, not basename

    /// Overlapping-group copies frequently share a basename — that is generally *why* they
    /// grouped — so de-duplicating on the name collapsed two refused folds into one.
    @Test func mergeRefusalsAreDeDuplicatedByPathNotByName() {
        let refusals = FileSyncManager.MergeRemovalRefusals()
        refusals.record("Photos", path: "/Volumes/A/Photos")
        refusals.record("Photos", path: "/Volumes/B/Photos")
        refusals.record("Photos", path: "/Volumes/A/Photos/")   // the same fold, another spelling

        #expect(refusals.all == ["Photos", "Photos"],
                "two distinct refused folds sharing a name collapsed into one: \(refusals.all)")
        #expect(refusals.paths == ["/Volumes/A/Photos", "/Volumes/B/Photos"])
    }

    /// The keeper refusal was not logged at all — banner only — so the single resolve's most
    /// common refusal left no trace in `~/sync-cloud.log`.
    @MainActor
    @Test func theSingleResolveKeeperRefusalIsLoggedWithItsPath() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        mockFM.virtualDisk["/Desktop/Old/IMG_0421.jpg"] = stub(size: 1000)   // the keeper is NOT on disk
        let g = group(keeper: "/Pictures/2019/IMG_0421.jpg", redundant: "/Desktop/Old/IMG_0421.jpg")
        manager.duplicateGroups = [g]

        let tag = UUID().uuidString
        var resolved = true
        let mine = try await logLines(tag: tag) {
            resolved = await manager.resolveDuplicateGroup(g)
        }
        #expect(resolved == false)

        let line = mine.last { $0.contains("is no longer what the scan saw") }
        #expect(line?.contains("/Pictures/2019/IMG_0421.jpg") == true,
                "the vanished-keeper refusal is still banner-only: “\(line ?? "nil")”")
    }
}
