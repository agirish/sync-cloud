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

    /// The batch stat pass runs before the first collision prompt, and a prompt holds the run
    /// for an unbounded time. A destination created externally during that wait must still get
    /// its own overwrite prompt — with only the stale pre-prompt stat it was silently replaced.
    @MainActor
    @Test func testSyncAllPromptsForDestinationCreatedDuringEarlierPrompt() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for name in ["a.txt", "b.txt"] {
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
        // Only a.txt collides when the batch stat runs.
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.rawDifferences = diffs
        manager.differences = diffs

        var prompted: [String] = []
        manager.collisionResolver = { _, _ in .skip } // bulk path must not use the single-file seam
        manager.bulkCollisionResolver = { fileName, _ in
            prompted.append(fileName)
            if fileName == "a.txt" {
                // While the user sits on a's prompt, b's destination appears externally.
                mockFM.virtualDisk["/dst/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            }
            return (.skip, false)
        }

        await manager.syncAll(direction: .copyToRight)

        // b collides by decision time, so it must be prompted too, in list order.
        #expect(prompted == ["a.txt", "b.txt"])
        // Both were skipped: nothing copied, nothing trashed, both still open differences.
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.differences.map(\.relativePath) == ["a.txt", "b.txt"])
    }

    /// A second syncAll started while one is still preparing must be dropped, not interleaved:
    /// the prepare phase suspends (detached stat pass) before any prompt, and a concurrent run
    /// would reset the first run's "Apply to all" cache and tear down its progress on exit.
    @MainActor
    @Test func testSyncAllDropsReentrantRunWhileFirstIsInFlight() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let diff = FileDifference(
            relativePath: "a.txt",
            leftItemPath: "/src/a.txt",
            rightItemPath: "/dst/a.txt",
            type: .differentDates,
            action: .copyToRight,
            description: "Different dates"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        var promptCount = 0
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in
            promptCount += 1
            return (.replace, false)
        }

        let first = Task { await manager.syncAll(direction: .copyToRight) }
        // Let the first run reach its stat-pass suspension; it publishes activeProgress
        // synchronously before that first await.
        for _ in 0..<1_000 where manager.activeProgress == nil { await Task.yield() }
        #expect(manager.activeProgress != nil)

        // Second run while the first is in flight: must return without doing anything.
        await manager.syncAll(direction: .copyToRight)
        await first.value

        // Exactly one run's worth of work: one prompt, one replace.
        #expect(promptCount == 1)
        #expect(mockFM.trashedPaths.count == 1)
        // And the guard resets: a later run is not blocked.
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        await manager.syncAll(direction: .copyToRight)
        #expect(promptCount == 2)
    }

    /// Builds a mock disk where every named file exists on both sides, so each one collides at
    /// the batch stat pass, and a manager whose single-file collision seam is a tripwire: the
    /// bulk path must never consult it (a .skip there would surface as an unresolved item).
    @MainActor
    private func makeBulkCollisionFixture(names: [String]) throws -> (FileSyncManager, MockFileManager, [FileDifference]) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for name in names {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            mockFM.virtualDisk["/dst/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            diffs.append(FileDifference(
                relativePath: name,
                leftItemPath: "/src/\(name)",
                rightItemPath: "/dst/\(name)",
                type: .differentDates,
                action: .copyToRight,
                description: "Different dates"
            ))
        }
        manager.rawDifferences = diffs
        manager.differences = diffs
        manager.collisionResolver = { _, _ in .skip }
        return (manager, mockFM, diffs)
    }

    /// Choosing "Apply to all" on the first collision must resolve every later collision in the
    /// same run from the cache: exactly one prompt, and the chosen resolution applied to each
    /// colliding file — including the per-file unique-URL generation that keep-both needs.
    @MainActor
    @Test func testSyncAllApplyToAllSuppressesLaterPromptsInSameRun() async throws {
        let (manager, mockFM, _) = try makeBulkCollisionFixture(names: ["a.txt", "b.txt", "c.txt"])

        var prompted: [String] = []
        manager.bulkCollisionResolver = { fileName, _ in
            prompted.append(fileName)
            return (.keepBoth, true)
        }

        await manager.syncAll(direction: .copyToRight)

        // Only the first collision prompted; b and c were resolved from the cache.
        #expect(prompted == ["a.txt"])
        // Keep-both was applied to all three: each original untouched, each got a twin.
        for name in ["a", "b", "c"] {
            #expect(mockFM.virtualDisk["/dst/\(name).txt"] != nil)
            #expect(mockFM.virtualDisk["/dst/\(name) 2.txt"] != nil)
        }
        #expect(mockFM.trashedPaths.isEmpty)
        // All three resolved for good.
        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
    }

    /// "Apply to all" is scoped to a single bulk run: a second syncAll after the first completes
    /// must prompt afresh, and its (different) answer must win over the first run's cached one.
    @MainActor
    @Test func testSyncAllApplyToAllDoesNotPersistIntoNextRun() async throws {
        let (manager, mockFM, diffs) = try makeBulkCollisionFixture(names: ["a.txt"])

        var promptCount = 0
        manager.bulkCollisionResolver = { _, _ in
            promptCount += 1
            return promptCount == 1 ? (.replace, true) : (.skip, false)
        }

        await manager.syncAll(direction: .copyToRight)
        #expect(promptCount == 1)
        #expect(mockFM.trashedPaths.count == 1)

        // Second run: the replace left the destination occupied, so a.txt collides again.
        manager.rawDifferences = diffs
        manager.differences = diffs
        await manager.syncAll(direction: .copyToRight)

        // A leaked cache would silently replace again; instead the fresh prompt's skip wins.
        #expect(promptCount == 2)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(manager.differences.map(\.relativePath) == ["a.txt"])
    }

    /// Captures what a bulk run publishes while it is still executing; MainActor-bound so the
    /// mid-run observation task can write to it from inside syncAll's suspension window.
    @MainActor
    private final class BulkRunProbe {
        var progressActiveAtPrompt = false
        var bulkProgressDuringIO: (completed: Int, total: Int)?
        var midRunObservation: Task<Void, Never>?
    }

    /// `bulkSyncProgress` is published for the IO phase of the run and torn down on exit, and
    /// `activeProgress` is up from the first prompt until completion. `bulkSyncProgress` is only
    /// set after the prompt loop, so the resolver seam can't see it directly — instead a task
    /// scheduled from inside the resolver runs at syncAll's next MainActor suspension (the IO
    /// await, which comes after the value is published) and observes it there. Cross-run
    /// clobbering of `activeProgress` needs no test: the reentrancy guard returns before a
    /// second run ever touches it, and the teardown only clears the run's own progress.
    @MainActor
    @Test func testSyncAllPublishesBulkProgressDuringRunAndClearsItAfter() async throws {
        let (manager, mockFM, _) = try makeBulkCollisionFixture(names: ["a.txt"])

        let probe = BulkRunProbe()
        manager.bulkCollisionResolver = { _, _ in
            probe.progressActiveAtPrompt = (manager.activeProgress != nil)
            probe.midRunObservation = Task { @MainActor in
                probe.bulkProgressDuringIO = manager.bulkSyncProgress
            }
            return (.replace, false)
        }

        await manager.syncAll(direction: .copyToRight)
        await probe.midRunObservation?.value

        // Live while running…
        #expect(probe.progressActiveAtPrompt)
        #expect(probe.bulkProgressDuringIO != nil)
        #expect(probe.bulkProgressDuringIO?.total == 1)
        // …and fully torn down after, with the work actually done.
        #expect(manager.bulkSyncProgress == nil)
        #expect(manager.activeProgress == nil)
        #expect(mockFM.trashedPaths.count == 1)
    }
}
