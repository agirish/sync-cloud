import Testing
import Foundation
@testable import Sync

/// Pins the safeMoveItem same-volume happy path (a single rename, no copy+delete fallback — the
/// cross-volume fallback is covered in FileOperationsTests) and the undo edge cases the coverage
/// review found untested: a move undo-then-redo round trip, undo of a keep-both copy, and undo
/// after a partial (some-items-failed) operation.
@Suite struct UndoAndSafeMovePinTests {

    /// Wraps MockFileManager and counts calls at the FileManaging seam. The mock's own moveItem
    /// is implemented as copy+delete internally, so only a wrapper can distinguish "safeMoveItem
    /// issued one rename" from "safeMoveItem fell back to copy+delete".
    private final class CallRecordingFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        private(set) var copyCalls = 0
        private(set) var moveCalls = 0
        private(set) var trashCalls = 0
        private(set) var removeCalls = 0

        init(inner: MockFileManager) { self.inner = inner }

        func copyItem(at srcURL: URL, to dstURL: URL) throws {
            copyCalls += 1
            try inner.copyItem(at: srcURL, to: dstURL)
        }
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moveCalls += 1
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashCalls += 1
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func removeItem(at URL: URL) throws {
            removeCalls += 1
            try inner.removeItem(at: URL)
        }
        func fileExists(atPath path: String) -> Bool {
            inner.fileExists(atPath: path)
        }
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        }
    }

    /// Polls a main-actor condition until it holds or the timeout expires (recording a failure).
    @MainActor
    private func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), what)
    }

    /// A manager with every alert seam mocked so no test can ever pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
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
    @Test func testMoveUndoThenRedoRoundTrip() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
        #expect(manager.undoManager?.canUndo == true)

        // Undo moves the file back to its origin.
        manager.undoManager?.undo()
        await waitUntil("undo restores the moved file to its source") { mockFM.virtualDisk["/src/f.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        #expect(manager.undoManager?.canRedo == true)

        // Redo re-applies the move.
        manager.undoManager?.redo()
        await waitUntil("redo re-applies the move") { mockFM.virtualDisk["/dst/f.txt"] != nil }
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
        // The redo registered a fresh undo, so the cycle can continue.
        #expect(manager.undoManager?.canUndo == true)
    }

    @MainActor
    @Test func testUndoOfKeepBothCopyRemovesOnlyUniquifiedCopy() async throws {
        let manager = makeManager()
        manager.collisionResolver = { _, _ in .keepBoth }
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
    /// removeItem: when the user declines the confirmation, the copied item survives.
    @MainActor
    @Test func testCopyUndoWithTrashFailureKeepsItemWhenConfirmerDeclines() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(false)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        // The volume loses Trash support before the undo (network share behavior).
        mockFM.shouldFailTrash = true
        manager.undoManager?.undo()

        await waitUntil("undo asks for permanent-delete confirmation") { spy.called }
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(mockFM.trashedPaths.isEmpty)
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
    /// (it may have been filled since creation) and keeps it when the user declines.
    @MainActor
    @Test func testCreateFolderUndoWithTrashFailureRequiresConfirmation() async throws {
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
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
    }
}
