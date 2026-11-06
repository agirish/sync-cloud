import Testing
import Foundation
@testable import Sync

/// A move that leaves its original parked says so.
///
/// A cross-volume move cleans up its source with `trashItem`. Under a provider's refusal, that
/// cleanup parks the original under a hidden sibling name to re-register it, and if the move back
/// fails the original stays there: a hidden full-size `.synccloud-trash-retry-<UUID>` duplicate in
/// the source folder. The move has landed, so it is a success, but it must not be reported as only
/// that. The delete path reports the same strand with `SyncError.trashParkedAndNotRestored`.
@Suite struct MoveParkedLeftoverTests {

    /// The mock models the whole chain: `shouldFailMove` sends the move down the staged
    /// cross-volume path, `trashRefusedUntilMovedIn` refuses the source's trash, and
    /// `failMoveToPathsOnce` lets the park land and refuses the move back.
    @MainActor
    @Test func aMoveWhoseOriginalIsParkedAndNotRestoredPresentsTheLeftover() async throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.shouldFailMove = true
        fm.trashRefusedUntilMovedIn = true
        fm.failMoveToPathsOnce = ["/src/data.bin"]
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()

        let moved = await manager.moveItems(nodes: [FileNode(id: "/src/data.bin", name: "data.bin", isDirectory: false)],
                                            toPath: "/dst", fileManager: fm)

        // The premise: the move landed and the original is stranded under the parked name.
        #expect(moved.map(\.id) == ["/src/data.bin"])
        #expect(fm.virtualDisk["/dst/data.bin"] != nil)
        let parked = fm.virtualDisk.keys.filter { $0.hasPrefix("/src/.synccloud-trash-retry-") }
        #expect(parked.count == 1, "the fixture no longer models a strand: \(fm.virtualDisk.keys.sorted())")

        let error = try #require(manager.currentError, "the move reported plain success over a hidden duplicate")
        #expect(error.title == "Moved, Original Left Behind")
        #expect(error.path == parked.first, "Reveal in Finder would not land on the leftover")
        #expect(error.message.contains((try #require(parked.first) as NSString).lastPathComponent),
                "the message does not name the leftover")
        #expect(error.message.contains("data.bin"))
    }

    /// A later failure in the same move doesn't hide the leftover. The leftover is presented as the
    /// operation ends and the batch's failure right after, and `present` replaces, so the failure's
    /// alert must mention the leftover itself.
    @MainActor
    @Test func aFailureInTheSameMoveStillMentionsTheLeftover() async throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.shouldFailMove = true
        fm.trashRefusedUntilMovedIn = true
        fm.failMoveToPathsOnce = ["/src/data.bin"]
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        let nodes = [FileNode(id: "/src/data.bin", name: "data.bin", isDirectory: false),
                     FileNode(id: "/src/missing.bin", name: "missing.bin", isDirectory: false)]

        _ = await manager.moveItems(nodes: nodes, toPath: "/dst", fileManager: fm)

        let parked = try #require(fm.virtualDisk.keys.first { $0.hasPrefix("/src/.synccloud-trash-retry-") },
                                  "the fixture no longer models a strand")
        let error = try #require(manager.currentError)
        #expect(error.title == "Move Failed", "premise: the second item did not fail")
        #expect(error.message.contains((parked as NSString).lastPathComponent), "the leftover went unmentioned: \(error.message)")
        #expect(error.path == parked)
    }

    /// An undo that strands says so in undo's words. Move, then arm the same strand for the undo's
    /// own cleanup of the item at the destination it moves back from.
    @MainActor
    @Test func aMoveUndoThatStrandsSaysItMovedBack() async throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        _ = await manager.moveItems(nodes: [FileNode(id: "/src/data.bin", name: "data.bin", isDirectory: false)],
                                    toPath: "/dst", fileManager: fm)
        try #require(fm.virtualDisk["/dst/data.bin"] != nil && manager.currentError == nil)
        // The moved-in item would pass `trashRefusedUntilMovedIn`, so the refusal is armed outright.
        fm.shouldFailMove = true
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        fm.failMoveToPathsOnce = ["/dst/data.bin"]

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }

        #expect(fm.virtualDisk["/src/data.bin"] != nil, "premise: the undo did not move it back: \(fm.virtualDisk.keys.sorted()) \(String(describing: manager.currentError)) \(String(describing: manager.banner))")
        let parked = try #require(fm.virtualDisk.keys.first { $0.hasPrefix("/dst/.synccloud-trash-retry-") },
                                  "the fixture no longer models a strand: \(fm.virtualDisk.keys.sorted())")
        let error = try #require(manager.currentError)
        #expect(error.title == "Moved Back, Copy Left Behind")
        #expect(!error.message.contains("reached its destination"))
        // Renaming the copy back would only make a second item at the destination.
        #expect(!error.message.contains("or rename it back to"), "\(error.message)")
        #expect(error.path == parked)
    }

    /// The ordinary cross-volume move, whose source reaches the Trash, reports nothing extra.
    @MainActor
    @Test func aMoveWhoseOriginalReachesTheTrashPresentsNothing() async throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.shouldFailMove = true
        fm.trashRefusedUntilMovedIn = true
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()

        _ = await manager.moveItems(nodes: [FileNode(id: "/src/data.bin", name: "data.bin", isDirectory: false)],
                                    toPath: "/dst", fileManager: fm)

        #expect(fm.virtualDisk["/dst/data.bin"] != nil)
        #expect(manager.currentError == nil, "error: \(manager.currentError?.title ?? "")")
    }
}
