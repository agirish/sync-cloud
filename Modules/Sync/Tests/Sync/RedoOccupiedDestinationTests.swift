import Foundation
import Testing
@testable import Sync

/// **A redo does not replace what it did not put there** (FR25).
///
/// The copy-redo and the move-redo called `safeCopyItem`/`safeMoveItem` straight onto the
/// destination, and those replace whatever they find. Copy `report.pdf` to `Shared/`, ⌘Z, save a
/// different `Shared/report.pdf` in another app, ⌘⇧Z: the new file went to the Trash, with no
/// prompt and no banner. The copy-redo's own comment said "the user is asked"; nothing asked.
///
/// The one occupant a redo MAY replace is the one the undo left there — the original the first
/// operation replaced with the user's say-so, which the undo restored. Each refusal below is paired
/// with that control, so neither can pass on a guard that refuses everything.
@Suite struct RedoOccupiedDestinationTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int, modified: Date) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [.size: size, .modificationDate: modified], contents: nil)
    }

    private func size(_ fm: MockFileManager, _ path: String) -> Int? {
        fm.virtualDisk[path]?.attributes?[.size] as? Int
    }

    private func disk(_ root: String, originalAtDestination: Bool) throws -> MockFileManager {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "\(root)/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "\(root)/Shared"), withIntermediateDirectories: true)
        fm.virtualDisk["\(root)/src/report.pdf"] = file(64, modified: Date(timeIntervalSince1970: 1_000))
        if originalAtDestination {
            fm.virtualDisk["\(root)/Shared/report.pdf"] = file(5, modified: Date(timeIntervalSince1970: 500))
        }
        return fm
    }

    private func transfer(_ manager: FileSyncManager, _ fm: MockFileManager, root: String, isMove: Bool) async {
        let node = FileNode(id: "\(root)/src/report.pdf", name: "report.pdf", isDirectory: false)
        if isMove {
            await manager.moveItems(nodes: [node], toPath: "\(root)/Shared", fileManager: fm)
        } else {
            await manager.copyItems(nodes: [node], toPath: "\(root)/Shared", fileManager: fm)
        }
    }

    /// The reported case: nothing was at the destination, the undo left nothing there, and a
    /// different file was saved there before the redo. It stays; the redo says why.
    @MainActor
    @Test(arguments: [false, true])
    func aRedoLeavesAFileSavedAtItsDestinationSinceTheUndo(isMove: Bool) async throws {
        let root = "/redo-occupied-\(isMove ? "move" : "copy")"
        let manager = makeManager()
        let fm = try disk(root, originalAtDestination: false)
        await transfer(manager, fm, root: root, isMove: isMove)
        try #require(size(fm, "\(root)/Shared/report.pdf") == 64)

        manager.undoManager?.undo()
        await waitUntil("the undo clears the destination") { fm.virtualDisk["\(root)/Shared/report.pdf"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // Another app saves its own report.pdf there.
        fm.virtualDisk["\(root)/Shared/report.pdf"] = file(555, modified: Date(timeIntervalSince1970: 8_888))
        let trashedBefore = fm.trashedPaths.count
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo refuses") { manager.banner?.severity == .warning }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message == "Redo left “report.pdf” alone — a different item is at its destination now",
                "got \(String(describing: manager.banner?.message))")
        #expect(size(fm, "\(root)/Shared/report.pdf") == 555, "the file another app saved was replaced")
        #expect(fm.trashedPaths.count == trashedBefore, "the redo put something in the Trash")
        if isMove {
            #expect(size(fm, "\(root)/src/report.pdf") == 64, "the refused move-redo still moved the source")
        }
    }

    /// The control: the original the first operation replaced, put back by the undo, is replaced
    /// again by the redo — that is what redoing a Replace means — and it goes to the Trash, not away.
    @MainActor
    @Test(arguments: [false, true])
    func aRedoStillReplacesTheOriginalItsUndoPutBack(isMove: Bool) async throws {
        let root = "/redo-replaces-\(isMove ? "move" : "copy")"
        let manager = makeManager()
        let fm = try disk(root, originalAtDestination: true)
        await transfer(manager, fm, root: root, isMove: isMove)
        try #require(size(fm, "\(root)/Shared/report.pdf") == 64)

        manager.undoManager?.undo()
        await waitUntil("the undo puts the original back") { size(fm, "\(root)/Shared/report.pdf") == 5 }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        let trashedBefore = fm.trashedPaths.count
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies") { size(fm, "\(root)/Shared/report.pdf") == 64 }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner == nil, "got \(String(describing: manager.banner?.message))")
        #expect(fm.trashedPaths.count == trashedBefore + 1, "the replaced original did not go to the Trash")
    }
}
