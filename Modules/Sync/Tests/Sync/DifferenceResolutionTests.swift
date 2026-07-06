import Testing
import Foundation
@testable import Sync

/// Regression coverage for how resolved differences leave the manager's state:
/// - the verified-copy confirmation dialog must actually copy even though SwiftUI's dismiss
///   binding fires alongside (and possibly before) the confirm button action,
/// - successful syncs must remove items from `rawDifferences` too, so `applyFilters()` cannot
///   resurrect them before the next scan,
/// - a prefetch fast-path load must clear a spinner flag left set by a cancelled slow load.
@Suite struct DifferenceResolutionTests {

    /// Builds a mock disk where the same file exists on both sides (the verified-identical case)
    /// and a manager whose collision seams are mocked so no NSAlert can ever appear.
    @MainActor
    private func makeVerifiedCopyFixture() throws -> (FileSyncManager, MockFileManager, FileDifference) {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let manager = FileSyncManager(fileManager: mockFM)
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in (.replace, true) }

        let diff = FileDifference(
            relativePath: "test.txt",
            leftItemPath: "/src/test.txt",
            rightItemPath: "/dst/test.txt",
            type: .differentDates,
            action: .copyToRight,
            description: "Different dates",
            leftFileSize: 10,
            rightFileSize: 10
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        return (manager, mockFM, diff)
    }

    /// The order SwiftUI ran in the field: the dialog's `isPresented` setter fires BEFORE the
    /// confirm button action. Before the fix, the setter's synchronous cleanup nil'ed
    /// `verifiedIdenticalForCopy`, so the confirm action's guard bailed and nothing was copied.
    @MainActor
    @Test func testConfirmVerifiedCopyCopiesEvenWhenDismissBindingFiresFirst() async throws {
        let (manager, mockFM, diff) = try makeVerifiedCopyFixture()
        manager.verifiedIdenticalForCopy = [diff]

        manager.verifiedCopyDialogDismissed()          // binding setter (dismiss)
        let copyTask = manager.confirmVerifiedCopy()   // confirm button, same main-actor turn

        #expect(copyTask != nil)
        await copyTask?.value
        try await Task.sleep(nanoseconds: 100_000_000) // let the deferred dismiss cleanup run

        // The copy really ran: the existing destination was trashed and replaced.
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
        // Resolved for good: gone from both lists, and not merely hidden as "dismissed".
        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
    }

    /// The opposite order (confirm action first, then the binding setter) must behave identically.
    @MainActor
    @Test func testConfirmVerifiedCopyCopiesWhenConfirmRunsFirst() async throws {
        let (manager, mockFM, diff) = try makeVerifiedCopyFixture()
        manager.verifiedIdenticalForCopy = [diff]

        let copyTask = manager.confirmVerifiedCopy()
        manager.verifiedCopyDialogDismissed()

        await copyTask?.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mockFM.trashedPaths.count == 1)
        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
    }

    /// Cancel keeps its meaning: nothing is copied, the items are hidden until the next scan.
    @MainActor
    @Test func testCancelVerifiedCopyHidesWithoutCopying() async throws {
        let (manager, mockFM, diff) = try makeVerifiedCopyFixture()
        manager.verifiedIdenticalForCopy = [diff]

        manager.dismissVerifiedCopyDialogWithoutCopy() // Cancel button
        manager.verifiedCopyDialogDismissed()          // binding setter also fires

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds.contains(diff.id))
        #expect(manager.differences.isEmpty)           // hidden by applyFilters
        #expect(manager.rawDifferences.count == 1)     // still known until the next scan
    }

    /// A synced difference must not resurrect when `applyFilters()` runs before the next scan
    /// (hidden-files toggle, sort change, or the post-sync refresh itself).
    @MainActor
    @Test func testSyncedDifferenceDoesNotResurrectOnApplyFilters() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in (.replace, true) }
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let diff = FileDifference(
            relativePath: "test.txt",
            leftItemPath: "/src/test.txt",
            rightItemPath: "/dst/test.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
        #expect(manager.differences.isEmpty)

        manager.applyFilters()
        #expect(manager.differences.isEmpty)   // regression: used to reappear from rawDifferences
        #expect(manager.rawDifferences.isEmpty)
    }

    /// Same guarantee for the bulk `syncAll` path.
    @MainActor
    @Test func testSyncAllRemovesSuccessesFromRawDifferences() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in (.replace, true) }
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for i in 1...3 {
            mockFM.virtualDisk["/src/file\(i).txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            diffs.append(FileDifference(
                relativePath: "file\(i).txt",
                leftItemPath: "/src/file\(i).txt",
                rightItemPath: "/dst/file\(i).txt",
                type: .missingOnRight,
                action: .copyToRight,
                description: "Missing"
            ))
        }
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        manager.applyFilters()
        #expect(manager.differences.isEmpty)
    }

    /// The bulk prepare pass stats destinations off the main actor (detached, one pass); the
    /// collision prompts must still fire on the MainActor, in list order, and each colliding
    /// file must get its own resolution when the user doesn't pick "Apply to all".
    @MainActor
    @Test func testSyncAllPromptsCollisionsInOrderWithMixedResolutions() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            diffs.append(FileDifference(
                relativePath: name,
                leftItemPath: "/src/\(name)",
                rightItemPath: "/dst/\(name)",
                type: .missingOnRight,
                action: .copyToRight,
                description: "Missing"
            ))
        }
        // a and c collide on the destination; b does not.
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/c.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.rawDifferences = diffs
        manager.differences = diffs

        var prompted: [String] = []
        manager.collisionResolver = { _, _ in .skip } // bulk path must not use the single-file seam
        manager.bulkCollisionResolver = { fileName, _ in
            prompted.append(fileName)
            return (fileName == "a.txt" ? (.skip, false) : (.keepBoth, false))
        }

        await manager.syncAll(direction: .copyToRight)

        // One prompt per colliding file, in list order; the clean file never prompts.
        #expect(prompted == ["a.txt", "c.txt"])
        // a was skipped: destination untouched, no keep-both twin, still an open difference.
        #expect(mockFM.virtualDisk["/dst/a 2.txt"] == nil)
        #expect(manager.differences.map(\.relativePath) == ["a.txt"])
        // b copied straight over; c resolved as keep-both alongside the existing file.
        #expect(mockFM.virtualDisk["/dst/b.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/c.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/c 2.txt"] != nil)
        #expect(mockFM.trashedPaths.isEmpty)
    }

    /// A prefetch fast-path load must clear the loading spinner left set by the slow load it
    /// cancelled — the cancelled task cannot clear the flag itself once a newer load owns it.
    @MainActor
    @Test func testPrefetchFastPathClearsStaleLoadingSpinner() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.05
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/slow"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/slow/file.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let slowLoad = Task { await manager.loadTree(path: "/slow", isLeft: true) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(manager.isLoadingLeftTree)

        // Switching to a prefetched provider cancels the slow load and takes the fast path.
        manager.prefetchedTrees["/fast"] = [FileNode(id: "/fast/a.txt", name: "a.txt", isDirectory: false)]
        await manager.loadTree(path: "/fast", isLeft: true)
        await slowLoad.value

        #expect(!manager.isLoadingLeftTree)    // regression: spinner used to stick forever
        #expect(manager.leftTree.count == 1)
        #expect(manager.leftTree.first?.name == "a.txt")
    }
}
