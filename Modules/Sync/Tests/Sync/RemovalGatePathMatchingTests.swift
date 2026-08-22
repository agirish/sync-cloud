import Testing
import Foundation
@testable import Sync

/// **The removal gate's path-matching contract.**
///
/// `deleteItems` asks its caller's `removalGate` about a list of paths and matches the answer back
/// against that list; the duplicates gate in turn matches the paths it is asked about against the
/// group's own `recommendedRemovalPaths`. Both matched by exact string equality, and the two sides
/// do not always hold the same spelling of one path: the post-confirmation invocation is fed
/// `trashFailures.map { $0.path }`, which is URL round-tripped — identical for an ordinary path,
/// but `"/a/Folder/"` comes back as `"/a/Folder"`, `"~/x"` as the expanded home path, and a
/// relative path as an absolute one.
///
/// A mismatch failed OPEN in both places, which is the reason these are pins rather than notes:
/// `deleteItems` dropped the refusal on the floor and removed the item anyway, and the duplicates
/// gate's `Set(paths)` intersection came back empty, so `guard !groupPaths.isEmpty else { continue }`
/// skipped re-verification entirely — silently, immediately before a permanent delete.
///
/// The contract these fix in place: both sides match on `FileSyncManager.canonicalRemovalPath`,
/// which is the exact transform the removal itself applies (`URL(fileURLWithPath:).path`), and
/// anything the gate cannot attribute is REFUSED rather than waved through.
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

    /// A refusal answered in a DIFFERENT SPELLING of the same path must still hold. Red before the
    /// canonicalization: the trailing-slash answer missed the exact-string `contains`, and the file
    /// the gate refused was moved to the Trash regardless.
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

    /// The same mismatch on the UNRECOVERABLE branch: after a confirmed permanent delete the gate
    /// is fed URL round-tripped paths, so a gate holding the scan's own spelling answers in that
    /// spelling — and its refusal must still stop `removeItem`.
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
            // Allow the pre-trash pass so the run reaches the confirmation, refuse the post-confirm
            // one — in the scan's spelling, which is not the one it was handed.
            calls.withLock { $0 += 1; return $0 } == 1 ? [] : ["/a/Folder/"]
        })

        #expect(calls.withLock { $0 } == 2, "the run never reached the post-confirmation gate pass")
        #expect(mockFM.attemptedRemovePaths.isEmpty,
                "a permanent delete ran despite the gate refusing it in a trailing-slash spelling")
        #expect(mockFM.virtualDisk["/a/Folder"] != nil)
        #expect(outcome == DeleteOutcome(refusedByGate: 1), "\(outcome)")
    }

    // MARK: The duplicates gate's side of the match

    /// The gate must recognize a group's path however the caller spelled it. Red before the fix:
    /// the intersection with `recommendedRemovalPaths` came back empty, the group was `continue`d
    /// past, and a drifted copy sailed through the last check before removal.
    @MainActor
    @Test func theDuplicatesGateVerifiesAGroupPathGivenInAnotherSpelling() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        // The copy the group would trash, REWRITTEN since the scan (size 1000 → 4242): drift, so a
        // gate that really looked at it must refuse.
        mockFM.virtualDisk["/b/x"] = stub(size: 4242)
        let g = group(keeper: "/a/x", redundant: "/b/x")

        let refusals = FileSyncManager.DuplicateRemovalRefusals()
        let refused = await manager.refuseDriftedDuplicateRemovals(["/b/x/"], groups: [g], refusals: refusals)

        #expect(refused == ["/b/x/"],
                "a drifted copy asked about in a trailing-slash spelling was not verified at all — the gate returned \(refused)")
        #expect(refusals.all[g.id] == .drifted)
    }

    /// The control, so the pin above cannot pass by refusing everything: the same group, unchanged
    /// on disk, in the same spelling, is NOT refused.
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

    /// **Fail CLOSED.** A path the gate cannot attribute to any of its groups has not been
    /// verified, and the gate's whole job is to answer for what is about to be destroyed. Red
    /// before the fix: unattributable meant unrefused, so the only way a match could fail was the
    /// way that removed the file.
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

    /// What the key actually promises, pinned so a "tidy-up" to `standardized` or
    /// `resolvingSymlinksInPath` cannot slip in: it is exactly the transform the removal applies,
    /// no more. Trailing slashes and `~` fold (both are what `URL(fileURLWithPath:)` does to a path
    /// on its way to `trashItem`); `//` and `/.` are left alone, because the removal leaves them
    /// alone too — the two sides only need to agree with each other and with the syscall.
    @Test func theCanonicalRemovalKeyMatchesWhatTheRemovalItselfActsOn() {
        #expect(FileSyncManager.canonicalRemovalPath("/a/Folder/") == "/a/Folder")
        #expect(FileSyncManager.canonicalRemovalPath("/a/Folder") == "/a/Folder")
        #expect(FileSyncManager.canonicalRemovalPath("~/x")
                == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("x").path)
        #expect(FileSyncManager.canonicalRemovalPath("/a/x") == URL(fileURLWithPath: "/a/x").path)
    }
}
