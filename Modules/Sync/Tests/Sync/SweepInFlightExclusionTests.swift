import Testing
import Foundation
@testable import Sync

/// Pins that the orphaned-temp sweep stands down while a file operation is in flight. The age gate
/// doesn't make a live staging file safe: `replaceDestinationByMoving` stages the source into
/// `.tmp_<UUID>` by a same-volume rename (or `copyItem` across volumes), both of which keep the
/// source's modification date, so an hour-old source makes a temp already past `minimumAge`. A
/// refresh during `replaceItem` would then Trash the operation's only staged copy, and its failure
/// would report the content lost to a system item-replacement folder.
///
/// Touching the temp's mtime at staging is not a safe fix: `replaceItem` moves that file into
/// place, so its date becomes the destination's, and this app compares files by date. Standing
/// down costs nothing: an orphan is still an orphan at the next refresh.
@Suite struct SweepInFlightExclusionTests {

    /// A tree holding one staging artifact with an old mtime, as a rename-staged temp looks the
    /// moment it is made from an hour-old source.
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

        // One operation in flight: the counter is bumped before the operation is enqueued and
        // cleared after it completes, so this covers the whole replaceItem window.
        manager.activeFileOperationsCount = 1
        let looked = manager.sweepOrphanedTempArtifacts()

        // The return value is the assertion that matters: removal runs on a detached task, so the
        // disk right after the call can't tell "never swept" from "not swept yet".
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
        // Trash-only: it left by way of the Trash, recoverable, not by an unlink. (The mock trashes
        // by copy-then-remove, so the recoverable copy, not the absence of a removeItem call, is
        // what tells the two apart here.)
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
