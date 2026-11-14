import Testing
import Foundation
import Events
@testable import Sync

/// Duplicate-removal gates fail closed: a gate whose manager is gone refuses everything, a nested
/// path pruned in favour of its ancestor is still verified, and every refusal logs paths, not
/// basenames.
@Suite struct DuplicatesGateFailClosedTests {

    private func stub(size: Int, modified: Date = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [.size: size, .modificationDate: modified],
                                 contents: nil)
    }

    private func group(keeper: String, redundant: String, reclaim: Int = 1000,
                       modified: Date = Date(timeIntervalSince1970: 1_000)) -> DuplicateGroup {
        .stub([.stub(keeper, keeper: true, size: reclaim, modified: modified),
               .stub(redundant, keeper: false, size: reclaim, modified: modified)], reclaimable: reclaim)
    }

    // MARK: A gate whose manager is gone refuses EVERYTHING

    /// The three removal gates: a group's, a merge's and a single pair's (Compare Copies).
    enum Gate: String, CaseIterable { case duplicates, merge, pair }

    /// With no manager, a gate refuses every path (`Set(about)`), never `[]`: "nothing has
    /// re-verified this" and "this may be destroyed" must never be the same outcome. The call
    /// sites hold `self` on the awaiting frame, so the closure is reached here directly.
    @MainActor
    @Test(arguments: Gate.allCases)
    func aGateRefusesEverythingWhenItsManagerIsGone(_ kind: Gate) async throws {
        var gate: (@Sendable ([String]) async -> Set<String>)?
        weak var weakManager: FileSyncManager?
        let g = group(keeper: "/a/x", redundant: "/b/x")
        do {
            let manager = FileSyncManager(fileManager: MockFileManager())
            weakManager = manager
            switch kind {
            case .duplicates:
                gate = manager.duplicateRemovalGate(groups: [g], refusals: FileSyncManager.DuplicateRemovalRefusals())
            case .merge:
                gate = manager.mergeRemovalGate(group: g, folds: [], refusals: FileSyncManager.MergeRemovalRefusals())
            case .pair:
                gate = manager.duplicatePairRemovalGate(copy: g.copies[1], keeper: g.copies[0])
            }
        }
        try #require(weakManager == nil,
                     "the manager outlived its scope — the nil-self branch was never reached, so this pins nothing")
        let closure = try #require(gate)
        let about = kind == .duplicates ? ["/b/x", "/c/y"] : ["/b/x"]
        let refused = await closure(about)
        #expect(refused == Set(about), "a \(kind) gate with no manager waved paths through unverified: \(refused)")
    }

    // MARK: A path pruned in favour of an ancestor is still verified — and condemns the ancestor

    /// `deleteItems` prunes nested paths so only the ancestor is trashed, but hands the gate the
    /// unpruned list: otherwise the child is verified by nothing and destroyed with its ancestor,
    /// unseen by the gate's `unattributed` block. A refused child condemns the ancestor that would
    /// take it down.
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
        let line = await loggedLineOnDisk(containing: "which is nested inside it")
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

    /// Three copies named `IMG_0421.jpg` can't be told apart by a log line naming `IMG_0421.jpg`.
    /// The single resolve's pre-checks log keeper path and culprit path, as the gate and the batch
    /// do, so the two report identically.
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
        // by this suite's sibling tests over the same constant paths, so the last such line in the
        // process log is often another test's.
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
    /// first pass has trashed what it could. A group whose remaining copy is refused there must not
    /// be called "left alone" by the partial banner: some of its copies are already in the Trash.
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
        let when = Date(timeIntervalSince1970: 1_000)
        let g = DuplicateGroup.stub([.stub("/a/x", keeper: true, modified: when),
                                     .stub("/b/x", keeper: false, modified: when),
                                     .stub("/ccc/x", keeper: false, modified: when)])
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
        #expect(await loggedLineOnDisk(containing: "after part of them had already been removed") != nil)
    }

    // MARK: The merge's refusals are identified by path, not basename

    /// Overlapping-group copies often share a basename (usually why they grouped), so
    /// de-duplicating on the name would collapse two refused folds into one.
    @Test func mergeRefusalsAreDeDuplicatedByPathNotByName() {
        let refusals = FileSyncManager.MergeRemovalRefusals()
        refusals.record("Photos", path: "/Volumes/A/Photos")
        refusals.record("Photos", path: "/Volumes/B/Photos")
        refusals.record("Photos", path: "/Volumes/A/Photos/")   // the same fold, another spelling

        #expect(refusals.all == ["Photos", "Photos"],
                "two distinct refused folds sharing a name collapsed into one: \(refusals.all)")
        #expect(refusals.paths == ["/Volumes/A/Photos", "/Volumes/B/Photos"])
    }
}
