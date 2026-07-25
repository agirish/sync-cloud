import Testing
import Foundation
@testable import Sync

/// Pins that the orphaned-temp sweep stands down while a file operation is in flight.
///
/// The age gate does not make a live staging file safe, though the sweep's own doc comment used
/// to claim it did. `replaceDestinationByMoving` stages the source into `.tmp_<UUID>` by a
/// same-volume rename, which PRESERVES the source's modification date (and the cross-volume
/// fallback uses `copyItem`, which preserves attributes too) — so staging any file that has sat
/// untouched for an hour produces a temp that is already older than `minimumAge` the instant it
/// exists. A refresh landing while `replaceItem` is still in flight would then Trash the live
/// operation's only staged copy, and the failure it caused would report the content as lost to a
/// system item-replacement folder rather than sitting in the Trash.
///
/// Touching the temp's mtime at staging time would NOT be a safe fix — `replaceItem` moves that
/// same staged file into place, so its date becomes the destination's, and this app compares
/// files by date. Standing down while the counter is up costs nothing instead: an orphan is
/// still an orphan at the next refresh.
@Suite struct SweepInFlightExclusionTests {

    /// A tree holding one staging artifact whose mtime is old — exactly what a rename-staged temp
    /// looks like the moment it is created from an hour-old source.
    @MainActor
    private func makeManagerWithAnOldTempInTheTree() -> (FileSyncManager, MockFileManager, String) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let tempPath = "/dst/.tmp_\(UUID().uuidString)"
        mockFM.virtualDisk[tempPath] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.rawLeftTree = [
            FileNode(
                id: tempPath,
                name: (tempPath as NSString).lastPathComponent,
                isDirectory: false,
                modificationDate: Date().addingTimeInterval(-(OrphanSweeper.minimumAge + 600))
            )
        ]
        return (manager, mockFM, tempPath)
    }

    @MainActor
    @Test func aLiveOperationsStagingFileIsNotSwept() async throws {
        let (manager, mockFM, tempPath) = makeManagerWithAnOldTempInTheTree()

        // One operation in flight — the counter is bumped before the operation is enqueued and
        // cleared after it completes, so this is the whole replaceItem window.
        manager.activeFileOperationsCount = 1
        let looked = manager.sweepOrphanedTempArtifacts()

        // The RETURN VALUE is the assertion that matters. Removal is dispatched to a detached
        // task, so checking the disk immediately after the call cannot tell "never swept" from
        // "not swept yet" — an earlier draft of this test asserted exactly that and passed
        // happily with the guard mutated out.
        #expect(looked == false)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(mockFM.virtualDisk[tempPath] != nil)
    }

    @MainActor
    @Test func theSameArtifactIsSweptOnceOperationsHaveSettled() async throws {
        let (manager, mockFM, tempPath) = makeManagerWithAnOldTempInTheTree()

        manager.activeFileOperationsCount = 0
        manager.sweepOrphanedTempArtifacts()

        // Removal runs on a detached task; wait for the observable effect rather than a duration.
        await waitUntil("the orphaned staging file should have been swept") {
            mockFM.virtualDisk[tempPath] == nil
        }
        // Trash-only: it left by way of the Trash, recoverable, not by an unlink. (The mock
        // emulates trashing as copy-then-remove, so the recoverable copy — not the absence of a
        // removeItem call — is what distinguishes the two here.)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.trashedPaths.first.map { ($0 as NSString).lastPathComponent }
                == (tempPath as NSString).lastPathComponent)
    }

    @MainActor
    @Test func theManualSweepSaysWhyItDeclinedInsteadOfClaimingItChecked() async throws {
        let (manager, mockFM, tempPath) = makeManagerWithAnOldTempInTheTree()

        manager.activeFileOperationsCount = 2
        manager.sweepOrphanedTempArtifactsNow()

        // A success banner here would claim a check that never happened.
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message == "Wait for the current operation to finish before checking for orphaned files")
        #expect(mockFM.virtualDisk[tempPath] != nil)
    }
}
