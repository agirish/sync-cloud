import Testing
import Foundation
import EventsTestSupport
@testable import Sync

/// Pins the safeMoveItem same-volume happy path (a single rename, no copy+delete fallback; the
/// cross-volume fallback is in FileOperationsTests) and undo edge cases: undo of a keep-both
/// copy, undo after a partly failed operation, and trash-less volumes.
@Suite struct UndoAndSafeMovePinTests {

    /// Wraps MockFileManager and counts calls at the FileManaging seam. The mock's moveItem is
    /// copy+delete inside, so only a wrapper can tell one rename from the copy+delete fallback.
    private final class CallRecordingFileManager: ForwardingFileManaging<MockFileManager>, @unchecked Sendable {
        private(set) var copyCalls = 0
        private(set) var moveCalls = 0
        private(set) var trashCalls = 0
        private(set) var removeCalls = 0
        private(set) var replaceCalls = 0

        override func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
            replaceCalls += 1
            return try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            copyCalls += 1
            try inner.copyItem(at: srcURL, to: dstURL)
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moveCalls += 1
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashCalls += 1
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        override func removeItem(at URL: URL) throws {
            removeCalls += 1
            try inner.removeItem(at: URL)
        }
    }

    /// A manager with every alert seam mocked so no test can ever pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, false))
    }

    // MARK: safeMoveItem same-volume happy path

    @Test func testSafeMoveSameVolumeIsSingleRenameWithoutFallback() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        inner.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let spy = CallRecordingFileManager(inner: inner)

        let trashed = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/data.bin"),
            to: URL(fileURLWithPath: "/dst/data.bin"),
            fileManager: spy
        )

        // Nothing was overwritten, the file moved, and it took exactly one rename:
        // no copy+delete fallback, no trash backup, no temp-file cleanup.
        #expect(trashed == nil)
        #expect(inner.virtualDisk["/dst/data.bin"] != nil)
        #expect(inner.virtualDisk["/src/data.bin"] == nil)
        #expect(spy.moveCalls == 1)
        #expect(spy.copyCalls == 0)
        #expect(spy.trashCalls == 0)
        #expect(spy.removeCalls == 0)
    }

    // MARK: Undo edge cases

    @MainActor
    @Test func testUndoOfKeepBothCopyRemovesOnlyUniquifiedCopy() async throws {
        let manager = makeManager()
        manager.collisionResolver = { _ in .keepBoth }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let node = FileNode(id: "/src/report.txt", name: "report.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/report 2.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/report.txt"] != nil)

        // Undo removes the uniquified copy; the pre-existing destination file and the source
        // are untouched (nothing was overwritten, so there is nothing to restore).
        manager.undoManager?.undo()
        await waitUntil("undo removes the keep-both copy") { mockFM.virtualDisk["/dst/report 2.txt"] == nil }
        #expect(mockFM.virtualDisk["/dst/report.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/report.txt"] != nil)
    }

    @MainActor
    @Test func testUndoAfterPartialFailureRemovesOnlySuccessfulItems() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/good.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // phantom.txt is selected but does not exist on disk, so its copy fails.

        let good = FileNode(id: "/src/good.txt", name: "good.txt", isDirectory: false)
        let phantom = FileNode(id: "/src/phantom.txt", name: "phantom.txt", isDirectory: false)
        let copied = await manager.copyItems(nodes: [good, phantom], toPath: "/dst", fileManager: mockFM)

        #expect(copied.map(\.id) == ["/src/good.txt"])
        #expect(mockFM.virtualDisk["/dst/good.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/phantom.txt"] == nil)
        #expect(manager.currentError?.title == "Copy Failed")

        // The registered undo covers only the item that actually transferred.
        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        await waitUntil("undo removes the one successful copy") { mockFM.virtualDisk["/dst/good.txt"] == nil }
        #expect(mockFM.virtualDisk["/src/good.txt"] != nil)
    }

    // MARK: Trash-less volumes (network shares)

    /// Records whether the permanent-delete confirmation was requested. Runs on the main actor
    /// (the confirmer seam is @MainActor), so plain state is race-free with the polling tests.
    @MainActor
    private final class ConfirmerSpy {
        private(set) var called = false
        func confirm(_ answer: Bool) -> @MainActor ([String]) -> Bool {
            { [weak self] _ in
                self?.called = true
                return answer
            }
        }
    }

    /// Undoing a copy on a volume without Trash must not fall back to a silent permanent
    /// removeItem: it asks, and when the user declines the confirmation the undo is a safe no-op:
    /// the copy stays, nothing is restored, no failure shows.
    @MainActor
    @Test func testCopyUndoWithTrashFailureKeepsItemWhenConfirmerDeclines() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = .file(100)
        // No pre-existing /dst/f.txt: the copy creates it fresh, so there is no overwrite backup.

        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(false)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)

        // The volume loses Trash support (ENOTSUP, not transient) before the undo (network share
        // behavior).
        mockFM.shouldFailTrash = true
        manager.banner = nil
        // preCountFileOperation runs synchronously inside undo(), so the count is ≥1 on return;
        // wait for the undo's enqueued operation to drain back to 0.
        manager.undoManager?.undo()

        await waitUntil("undo asks for permanent-delete confirmation") { spy.called }
        await waitUntil("the declined-confirm undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.banner == nil)
    }

    /// The same undo removes the copy once the user confirms the permanent deletion.
    @MainActor
    @Test func testCopyUndoWithTrashFailureRemovesItemWhenConfirmerAccepts() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(true)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        mockFM.shouldFailTrash = true
        manager.undoManager?.undo()

        await waitUntil("undo removes the copy after confirmation") { mockFM.virtualDisk["/dst/f.txt"] == nil }
        #expect(spy.called)
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil)
    }

    /// End-to-end Replace + Undo on a trash-less volume: the replaced file survives as a hidden
    /// in-place backup, and undoing the copy puts it back where it was.
    @MainActor
    @Test func testReplaceOnTrashlessVolumeIsUndoableViaInPlaceBackup() async throws {
        let manager = makeManager() // collisionResolver is .replace
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        mockFM.shouldFailTrash = true
        manager.permanentDeleteConfirmer = { _ in true }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        // Replace landed, and the old file survives as a hidden .rollback_ backup next to it.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/.rollback_") })

        manager.undoManager?.undo()

        await waitUntil("undo restores the replaced file from the in-place backup") {
            mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5
        }
        #expect(!mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/.rollback_") })
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil)
    }

    /// Undo of New Folder on a trash-less volume asks before permanently removing the folder
    /// (it may have been filled since creation) and keeps it when the user declines. The decline
    /// is legitimate, but it is logged, or "User triggered Undo: New Folder" followed by nothing
    /// reads as a completed undo.
    @MainActor
    @Test func testCreateFolderUndoWithTrashFailureRequiresConfirmation() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(false)

        await manager.createFolder(named: "New Folder", in: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)

        mockFM.shouldFailTrash = true
        manager.undoManager?.undo()

        await waitUntil("folder undo asks for permanent-delete confirmation") { spy.called }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        #expect(await log.entries.contains {
            $0.message.contains("Undo (New Folder)") && $0.message.contains("declined")
        })
    }
}
