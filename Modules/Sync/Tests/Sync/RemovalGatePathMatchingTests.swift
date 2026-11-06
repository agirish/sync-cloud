import Testing
import Foundation
@testable import Sync

/// The removal gate's path-matching contract. `deleteItems` matches its `removalGate`'s answer
/// against the paths it asked about, and the duplicates gate matches those paths against each
/// group's `recommendedRemovalPaths`. The two sides can spell one path differently: after a
/// confirmation the gate is fed URL round-tripped paths, so `"/a/Folder/"` becomes `"/a/Folder"`
/// and `"~/x"` the expanded home path. Matched by exact string, a mismatch fails open, removing a
/// refused item or skipping re-verification right before a permanent delete. So both sides match
/// on `FileSyncManager.canonicalRemovalPath`, the transform the removal itself applies, and the
/// gate refuses anything it can't attribute.
@Suite struct RemovalGatePathMatchingTests {

    @MainActor
    private func makeManager(_ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        return manager
    }

    private func stub(size: Int, modified: Date? = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [.size: size]
        if let modified { attrs[.modificationDate] = modified }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
    }

    private func group(keeper: String, redundant: String) -> DuplicateGroup {
        let when = Date(timeIntervalSince1970: 1_000)
        let k = DuplicateCopy(id: keeper, name: (keeper as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: when,
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant, name: (redundant as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: when,
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: k.name, isDirectory: false,
                              copies: [k, r], reclaimableBytes: 1000)
    }

    // MARK: `deleteItems`' side of the match

    /// A refusal answered in a different spelling of the same path still holds; matched by exact
    /// string, the trailing-slash answer would miss and the refused file would go to the Trash.
    @MainActor
    @Test func aRefusalSpelledDifferentlyStillKeepsTheItemOnDisk() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/Folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: nil)

        let outcome = await manager.deleteItems(at: ["/a/Folder"], fileManager: mockFM,
                                                removalGate: { _ in ["/a/Folder/"] })

        #expect(mockFM.virtualDisk["/a/Folder"] != nil,
                "the gate refused this path in a trailing-slash spelling and it was trashed anyway")
        #expect(outcome == DeleteOutcome(refusedByGate: 1),
                "a refusal the matcher missed was also missed by the accounting: \(outcome)")
    }

    /// The same mismatch on the unrecoverable branch: after a confirmed permanent delete the gate is
    /// fed URL round-tripped paths, so a gate answering in the scan's spelling must still stop
    /// `removeItem`.
    @MainActor
    @Test func aRefusalSpelledDifferentlyStopsAConfirmedPermanentDelete() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        manager.permanentDeleteConfirmer = { _ in true }
        mockFM.virtualDisk["/a/Folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: nil)
        let calls = LockedBox<Int>(0)

        let outcome = await manager.deleteItems(at: ["/a/Folder"], fileManager: mockFM,
                                                removalGate: { _ in
            // Allow the pre-trash pass so the run reaches the confirmation, then refuse the
            // post-confirm one in the scan's spelling, not the one it was handed.
            calls.withLock { $0 += 1; return $0 } == 1 ? [] : ["/a/Folder/"]
        })

        #expect(calls.withLock { $0 } == 2, "the run never reached the post-confirmation gate pass")
        #expect(mockFM.attemptedRemovePaths.isEmpty,
                "a permanent delete ran despite the gate refusing it in a trailing-slash spelling")
        #expect(mockFM.virtualDisk["/a/Folder"] != nil)
        #expect(outcome == DeleteOutcome(refusedByGate: 1), "\(outcome)")
    }

    // MARK: The duplicates gate's side of the match

    /// The gate recognizes a group's path however the caller spelled it; otherwise the group is
    /// skipped and a drifted copy passes the last check before removal.
    @MainActor
    @Test func theDuplicatesGateVerifiesAGroupPathGivenInAnotherSpelling() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        // The copy the group would trash, rewritten since the scan (size 1000 → 4242): drift, so a
        // gate that really looked at it must refuse.
        mockFM.virtualDisk["/b/x"] = stub(size: 4242)
        let g = group(keeper: "/a/x", redundant: "/b/x")

        let refusals = FileSyncManager.DuplicateRemovalRefusals()
        let refused = await manager.refuseDriftedDuplicateRemovals(["/b/x/"], groups: [g], refusals: refusals)

        #expect(refused == ["/b/x/"],
                "a drifted copy asked about in a trailing-slash spelling was not verified at all — the gate returned \(refused)")
        #expect(refusals.all[g.id] == .drifted)
    }

    /// The control, so the test above can't pass by refusing everything: the same group, unchanged
    /// on disk, in the same spelling, is not refused.
    @MainActor
    @Test func theDuplicatesGateStillPassesAnUnchangedGroupInAnotherSpelling() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        let g = group(keeper: "/a/x", redundant: "/b/x")

        let refused = await manager.refuseDriftedDuplicateRemovals(
            ["/b/x/"], groups: [g], refusals: FileSyncManager.DuplicateRemovalRefusals())

        #expect(refused.isEmpty, "the fixture refuses even the unchanged case, so the pin above is vacuous")
    }

    /// Fail closed: a path the gate can't attribute to any group hasn't been verified, and the
    /// gate's job is to answer for what is about to be destroyed, so it is refused.
    @MainActor
    @Test func theDuplicatesGateRefusesAPathItCannotAttributeToAnyGroup() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/elsewhere/z"] = stub(size: 7)
        let g = group(keeper: "/a/x", redundant: "/b/x")

        let refused = await manager.refuseDriftedDuplicateRemovals(
            ["/b/x", "/elsewhere/z"], groups: [g], refusals: FileSyncManager.DuplicateRemovalRefusals())

        #expect(refused == ["/elsewhere/z"],
                "a path belonging to none of the gate's groups was waved through unverified: \(refused)")
    }

    // MARK: The canonical form itself

    /// The key is exactly the transform the removal applies, no more, so a "tidy-up" to
    /// `standardized` or `resolvingSymlinksInPath` fails here. Trailing slashes and `~` fold, as
    /// `URL(fileURLWithPath:)` folds them on the way to `trashItem`; `//` and `/.` are left alone,
    /// as the removal leaves them.
    @Test func theCanonicalRemovalKeyMatchesWhatTheRemovalItselfActsOn() {
        #expect(FileSyncManager.canonicalRemovalPath("/a/Folder/") == "/a/Folder")
        #expect(FileSyncManager.canonicalRemovalPath("/a/Folder") == "/a/Folder")
        #expect(FileSyncManager.canonicalRemovalPath("~/x")
                == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("x").path)
        #expect(FileSyncManager.canonicalRemovalPath("/a/x") == URL(fileURLWithPath: "/a/x").path)
    }
}
