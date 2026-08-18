import Testing
import Foundation
import Events
@testable import Sync

/// What the blind duplicate batch says when it removes nothing, and what it claims it freed.
///
/// Two ways the batch told the user something untrue. Neither is destructive — both are what the
/// banner *says* after the act — which is why they sat in an audit's "noted but not filed" column;
/// they are still the sentence a person reads to find out what just happened to their files.
///
/// **This line has none of the `DeleteOutcome` family** (see `CLAUDE.md`), so its sibling
/// `DuplicateRemovalHonestyTests` does not exist here and these could not simply travel with it.
/// Nothing below needs it: `deleteItems` answering an `Int` is enough to reach both claims.
@Suite struct DuplicateBatchAccountingTests {

    @MainActor
    private func makeManager(_ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        return manager
    }

    private func stub(size: Int, modified: Date?) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [.size: size]
        if let modified { attrs[.modificationDate] = modified }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
    }

    private func copy(_ path: String, keeper: Bool, protectedFromRemoval: Bool = false) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 1000, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1_000),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper,
                      isProtectedFromRemoval: protectedFromRemoval)
    }

    private func group(keeper: String, redundant: String, reclaim: Int,
                       protectRedundant: Bool = false) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: (keeper as NSString).lastPathComponent,
                       isDirectory: false,
                       copies: [copy(keeper, keeper: true),
                                copy(redundant, keeper: false, protectedFromRemoval: protectRedundant)],
                       reclaimableBytes: reclaim)
    }

    /// **"Nothing to remove" is not "something changed."** Every empty batch produced the drift
    /// warning, and drift is only one of the two ways to get one: a group whose every redundant copy
    /// is PROTECTED contributes no paths while nothing about it has changed at all, so a rescan
    /// finds exactly the same group and the advice sends the user around a loop.
    @MainActor
    @Test func aBatchOfProtectedCopiesIsNotReportedAsDrift() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000, protectRedundant: true)
        try #require(g.recommendedRemovalPaths.isEmpty, "the fixture no longer produces an empty removal list")
        try #require(g.isRecommendedForBatch, "the fixture is not eligible, so it never reaches the banner under test")
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        let said = try #require(manager.banner?.message)
        #expect(!said.contains("no longer at their scanned locations"),
                "a group nothing has touched was reported as drifted — a rescan finds the same thing: “\(said)”")
        #expect(said.contains("protected"), "the banner does not say why nothing was removed: “\(said)”")
        #expect(mockFM.virtualDisk["/b/x"] != nil, "a protected copy was trashed")
    }

    /// …and the drift wording survives for the case it was written for, so the fix above is a
    /// narrowing rather than a removal.
    @MainActor
    @Test func aDriftedBatchStillSaysToRescan() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // The redundant copy was rewritten since the scan — a different size is a KNOWN mismatch.
        mockFM.virtualDisk["/b/x"] = stub(size: 2000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        #expect(manager.banner?.message.contains("no longer at their scanned locations") == true,
                "a genuinely drifted batch stopped telling the user to rescan: “\(manager.banner?.message ?? "nil")”")
        #expect(mockFM.virtualDisk["/b/x"] != nil, "a drifted copy was trashed")
    }

    /// **Space the user never got back must not be reported as reclaimed.**
    ///
    /// A group whose redundant copy vanished externally between the scan and the click still
    /// resolves — every removal path is gone, so it correctly drops off the list — but this run
    /// freed nothing for it. Measured before the fix on `main`, whose accounting is the same: two
    /// identical pairs with one copy already removed by something else reported 5 KB reclaimed from
    /// 2 groups for a run that trashed one 1 KB file.
    ///
    /// **The vanished group's keeper has to match its recorded size**, or the fixture proves
    /// nothing: `keeperStillExists` refuses a drifted keeper, so a keeper stubbed at a different
    /// size drops the group at the batch filter and the accounting line is never reached. A first
    /// draft did exactly that, passed against the unfixed code, and read as evidence that the defect
    /// was unreachable.
    @MainActor
    @Test func bytesAreNotCreditedForCopiesThatVanishedExternally() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/a/y"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // `/b/y` is deliberately NOT on the disk: something else removed it after the scan.

        let here = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1_000)
        let gone = group(keeper: "/a/y", redundant: "/b/y", reclaim: 4_000)
        manager.duplicateGroups = [here, gone]

        await manager.applyRecommendedDuplicates([here, gone])

        let said = try #require(manager.banner?.message)
        #expect(said.contains(FileSyncManager.formatBytes(1_000)),
                "the banner does not name what this run actually freed: “\(said)”")
        #expect(!said.contains(FileSyncManager.formatBytes(5_000)),
                "the banner credited this run with space a copy that had already vanished used to take: “\(said)”")
    }
}
