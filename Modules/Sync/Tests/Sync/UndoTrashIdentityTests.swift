import Testing
import Foundation
@testable import Sync

/// What an undo takes back out of the Trash, and what it decides is gone.
///
/// - A restore takes only the item recorded at its Trash path. Empty the Trash, trash a different
///   file of the same name, and macOS gives it the freed name; ⌘Z must leave that stranger.
/// - A dangling link (what moving a relative link usually leaves) is still an item. `fileExists`
///   follows links and would read it as gone, so it would never be moved back or removed.
/// - A move's merge records the source folder it emptied and trashed, so ⌘Z puts that folder
///   back rather than making a new one while the original stays in the Trash.
///
/// Real disk with a `ScratchTrash` throughout: the claims are about where items end up, and the
/// mock's flat paths and link-less stat can't model either.
@Suite struct UndoTrashIdentityTests {

    @MainActor
    private func manager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, false))
    }

    /// Puts a different item at a Trash backup's path, as emptying the Trash and then trashing
    /// another file of the same name does. A different length, so its identity differs.
    private func replaceInTrash(_ backup: URL) throws {
        try FileManager.default.removeItem(at: backup)
        try Data("an unrelated file the user trashed later".utf8).write(to: backup)
    }

    @MainActor
    private func undoAndDrain(_ m: FileSyncManager) async {
        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 }
    }

    // MARK: FR27

    /// A delete's ⌘Z restores only the item the delete put in the Trash. A stranger at its Trash
    /// path stays there, nothing lands at the original path, and the banner says why. The control
    /// (`strangerInTrash: false`): the same delete, untouched in the Trash, comes back.
    @MainActor
    @Test(arguments: [true, false])
    func aDeleteUndoLeavesAStrangerAtItsTrashPathInTheTrash(strangerInTrash: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-delete\(strangerInTrash ? "" : "-control")")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("folder/report.txt")
        try writeText("the report", original)
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)

        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        if strangerInTrash { try replaceInTrash(backup) }

        await undoAndDrain(m)

        if strangerInTrash {
            #expect(!entryExists(original), "the undo restored an item the delete never put in the Trash")
            #expect(readText(backup) == "an unrelated file the user trashed later")
            #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                    "banner: \(m.banner?.message ?? "nil")")
        } else {
            #expect(readText(original) == "the report")
            #expect(!entryExists(backup))
        }
    }

    /// A deleted folder that Finder wrote a `.DS_Store` into while it sat in the Trash (the user
    /// opened it there) is still the folder the delete put there, and comes back. A folder of the
    /// same name with different contents does not.
    @MainActor
    @Test func aDeletedFolderComesBackAfterFinderBrowsedItButAStrangerFolderDoesNot() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)

        func deleteFolder(_ name: String) throws -> (original: URL, backup: URL) {
            let original = root.appendingPathComponent("docs/\(name)")
            try writeText("one", original.appendingPathComponent("one.txt"))
            try writeText("two", original.appendingPathComponent("sub/two.txt"))
            var trashedURL: NSURL?
            try trash.trashItem(at: original, resultingItemURL: &trashedURL)
            return (original, try #require(trashedURL as URL?))
        }

        let browsed = try deleteFolder("Browsed")
        let m = manager()
        await m.registerRestoreItems(urls: [browsed.original], trashedItems: [browsed.backup],
                                     actionName: "Delete 1 Item", fileManager: trash).value
        try writeText("finder view state", browsed.backup.appendingPathComponent(".DS_Store"))
        await undoAndDrain(m)
        #expect(readText(browsed.original.appendingPathComponent("sub/two.txt")) == "two",
                "a folder Finder merely opened in the Trash was refused as a stranger")

        let swapped = try deleteFolder("Swapped")
        let m2 = manager()
        await m2.registerRestoreItems(urls: [swapped.original], trashedItems: [swapped.backup],
                                      actionName: "Delete 1 Item", fileManager: trash).value
        try FileManager.default.removeItem(at: swapped.backup)
        try writeText("someone else's", swapped.backup.appendingPathComponent("other.txt"))
        await undoAndDrain(m2)
        #expect(!entryExists(swapped.original), "a different folder of the same name was restored")
        #expect(readText(swapped.backup.appendingPathComponent("other.txt")) == "someone else's")
    }

    /// A move or copy that replaced a file: ⌘Z moves the file back (or removes the copy), and puts
    /// back only the file the transfer sent to the Trash, not one that has taken its name there since.
    @MainActor
    @Test(arguments: [true, false])
    func aTransferUndoDoesNotPutAStrangerFromTheTrashInPlaceOfTheReplacedFile(isMove: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-\(isMove ? "move" : "copy")")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let from = root.appendingPathComponent("src/f.txt")
        let to = root.appendingPathComponent("dst/f.txt")
        try writeText(isMove ? "moved" : "copied", from)
        try writeText("replaced", to)
        let m = manager()
        let backup: URL
        if isMove {
            backup = try #require(try FileSyncManager.safeMoveItem(at: from, to: to, fileManager: trash))
            await m.registerMoveUndo(items: [(from: from, to: to, overwritten: backup)], actionName: "Move 1 Item", fileManager: trash).value
        } else {
            backup = try #require(try FileSyncManager.safeCopyItem(at: from, to: to, fileManager: trash))
            await m.registerCopyUndo(items: [(source: from, destination: to, overwritten: backup)],
                                     actionName: "Copy 1 Item", fileManager: trash).value
        }
        try replaceInTrash(backup)

        await undoAndDrain(m)

        if isMove { #expect(readText(from) == "moved", "the move itself was not undone") }
        #expect(!entryExists(to), "a file the transfer never displaced was put at its destination")
        #expect(readText(backup) == "an unrelated file the user trashed later")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// Makes `folder` unreadable (mode 000), as a subfolder another account owns or a cloud folder
    /// that doesn't answer leaves a deep walk partial. Returns the undo for a `defer`.
    private func lock(_ folder: URL) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    }

    /// A deleted folder holding an unreadable subfolder can't be digested, so it is recorded by its
    /// own file number, and ⌘Z restores it, unreadable subfolder and all: the number needs only a
    /// stat of the folder, and the move into the Trash keeps it.
    @MainActor
    @Test func aDeleteUndoRestoresAFolderWhoseIdentityCouldNotBeRecorded() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-unrecorded")
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("docs/Project")
        try writeText("one", original.appendingPathComponent("one.txt"))
        try writeText("secret", original.appendingPathComponent("private/s.txt"))
        let unlockOriginal = try lock(original.appendingPathComponent("private"))
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)
        let unlockBackup = { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backup.appendingPathComponent("private").path) }
        defer { unlockBackup(); unlockOriginal(); try? FileManager.default.removeItem(at: root) }
        // The premise: the contents couldn't be read, and the number was recorded instead.
        #expect(ItemIdentity.deepSnapshot(at: backup, fileManager: trash) == .indeterminate)
        guard case .directoryFileNumber = FileSyncManager.backupIdentity(backup, fileManager: trash) else {
            Issue.record("recorded \(FileSyncManager.backupIdentity(backup, fileManager: trash))")
            return
        }

        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        await undoAndDrain(m)

        #expect(readText(original.appendingPathComponent("one.txt")) == "one",
                "the undo refused the folder this delete put in the Trash: \(m.banner?.message ?? "nil")")
        #expect(!entryExists(backup))
    }

    /// …and a stranger given that folder's name in the Trash is refused. Its contents may match,
    /// but its file number differs, so it stays in the Trash rather than landing in the user's
    /// folder.
    @MainActor
    @Test func aDeleteUndoRefusesAStrangerInPlaceOfAFolderItCouldNotRead() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-unread-stranger")
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("docs/Project")
        try writeText("one", original.appendingPathComponent("one.txt"))
        try writeText("secret", original.appendingPathComponent("private/s.txt"))
        let unlockOriginal = try lock(original.appendingPathComponent("private"))
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: backup.appendingPathComponent("private").path)
            unlockOriginal(); try? FileManager.default.removeItem(at: root)
        }
        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value

        // The Trash emptied, and another folder of the same name and contents (only its number
        // can tell) trashed into the freed name.
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: backup.appendingPathComponent("private").path)
        try FileManager.default.removeItem(at: backup)
        try writeText("one", backup.appendingPathComponent("one.txt"))
        try writeText("secret", backup.appendingPathComponent("private/s.txt"))
        let unlockStranger = try lock(backup.appendingPathComponent("private"))
        defer { unlockStranger() }

        await undoAndDrain(m)

        #expect(!entryExists(original), "the undo restored a folder the delete never put in the Trash")
        #expect(readText(backup.appendingPathComponent("one.txt")) == "one")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// Against an identity that was recorded, a backup that can't be read at ⌘Z still refuses, and
    /// the banner says it couldn't be read, not that it is a stranger.
    @MainActor
    @Test func aDeleteUndoOfABackupThatCannotBeReadNowSaysSo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-unreadable-now")
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("docs/Project")
        try writeText("one", original.appendingPathComponent("one.txt"))
        try writeText("secret", original.appendingPathComponent("private/s.txt"))
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)
        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        let unlock = try lock(backup.appendingPathComponent("private"))
        defer { unlock(); try? FileManager.default.removeItem(at: root) }

        await undoAndDrain(m)

        #expect(!entryExists(original))
        #expect(readText(backup.appendingPathComponent("one.txt")) == "one")
        #expect(m.banner?.message == "Undo didn’t restore “Project” — the item in the Trash under that name couldn’t be read",
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// Replaces `dst/Project` with `src/Project` by `transfer` (a copy or a move), so the replaced
    /// folder, holding a `private` subfolder, goes to the Trash as the backup.
    private func replaceFolder(in root: URL, trash: ScratchTrash,
                               by transfer: (URL, URL) throws -> URL?) throws -> (src: URL, dst: URL, backup: URL) {
        let src = root.appendingPathComponent("src/Project")
        let dst = root.appendingPathComponent("dst/Project")
        try writeText("new", src.appendingPathComponent("new.txt"))
        try writeText("old", dst.appendingPathComponent("old.txt"))
        try writeText("old private", dst.appendingPathComponent("private/p.txt"))
        let backup = try #require(try transfer(src, dst))
        return (src, dst, backup)
    }

    /// A copy-undo whose backup was recorded but can't be read at undo time refuses before it
    /// trashes the copy, which would leave the destination empty and the original stranded. Both
    /// stay recoverable, and the banner says the backup couldn't be read, not that it is a stranger.
    /// The move-undo's twin: the moved folder is not moved back while the backup it would restore
    /// in its place can't be read.
    @MainActor
    @Test(arguments: [false, true])
    func aTransferUndoWhoseBackupCannotBeReadLeavesTheItemInPlace(isMove: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-\(isMove ? "move" : "copy")-unreadable")
        let trash = ScratchTrash(in: root)
        let (src, dst, backup) = try replaceFolder(in: root, trash: trash) {
            isMove ? try FileSyncManager.safeMoveItem(at: $0, to: $1, fileManager: trash)
                   : try FileSyncManager.safeCopyItem(at: $0, to: $1, fileManager: trash)
        }
        let m = manager()
        if isMove {
            await m.registerMoveUndo(items: [(from: src, to: dst, overwritten: backup)],
                                     actionName: "Move 1 Item", fileManager: trash).value
        } else {
            await m.registerCopyUndo(items: [(source: src, destination: dst, overwritten: backup)],
                                     actionName: "Copy 1 Item", fileManager: trash).value
        }
        let unlock = try lock(backup.appendingPathComponent("private"))
        defer { unlock(); try? FileManager.default.removeItem(at: root) }

        await undoAndDrain(m)

        #expect(readText(dst.appendingPathComponent("new.txt")) == "new",
                "the item was undone though its backup could not be put back")
        #expect(entryExists(src) == !isMove)
        #expect(readText(backup.appendingPathComponent("old.txt")) == "old")
        #expect(m.banner?.message.contains("couldn’t be read") == true, "banner: \(m.banner?.message ?? "nil")")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == false)
    }

    // MARK: FR28

    /// A relative link moved to another folder dangles there, and is still the item the move put
    /// there, so ⌘Z moves it back.
    @MainActor
    @Test func aMoveUndoMovesADanglingLinkBack() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-dangling-link-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let from = root.appendingPathComponent("src/link")
        let to = root.appendingPathComponent("dst/link")
        try writeText("target", root.appendingPathComponent("src/target.txt"))
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: from.path, withDestinationPath: "target.txt")
        _ = try FileSyncManager.safeMoveItem(at: from, to: to, fileManager: trash)
        // The premise: the moved link dangles where it landed.
        #expect(entryExists(to) && !FileManager.default.fileExists(atPath: to.path))

        let m = manager()
        m.registerMoveUndo(items: [(from: from, to: to, overwritten: nil)], actionName: "Move 1 Item", fileManager: trash)

        await undoAndDrain(m)

        #expect(entryExists(from), "the link was never moved back")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: from.path) == "target.txt")
        #expect(!entryExists(to), "the link is still at the destination")
    }

    /// The redo of that move, once the folder it went to is gone: the link is a source to move,
    /// dangling or not, so the redo makes the folder again and moves it. Asked through
    /// `fileExists`, which follows the link, it would read as no source and the move would fail.
    @MainActor
    @Test func aMoveRedoOfADanglingLinkRemakesTheFolderItGoesTo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "redo-dangling-link-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let from = root.appendingPathComponent("src/link")
        let to = root.appendingPathComponent("dst/new/link")
        try FileManager.default.createDirectory(at: from.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: from.path, withDestinationPath: "/nonexistent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try FileSyncManager.safeMoveItem(at: from, to: to, fileManager: trash)
        let m = manager()
        await m.registerMoveUndo(items: [(from: from, to: to, overwritten: nil)], actionName: "Move 1 Item", fileManager: trash).value
        await undoAndDrain(m)
        try #require(entryExists(from), "premise: the undo moved the link back")
        try FileManager.default.removeItem(at: to.deletingLastPathComponent())
        m.banner = nil

        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 }

        #expect(entryExists(to), "banner: \(String(describing: m.banner?.message))")
        #expect(!entryExists(from))
    }

    /// The copy-undo's twin: a copied link that dangles is still the copy, and ⌘Z removes it.
    @MainActor
    @Test func aCopyUndoRemovesADanglingLinkItCopied() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-dangling-link-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let source = root.appendingPathComponent("src/link")
        let destination = root.appendingPathComponent("dst/link")
        try writeText("target", root.appendingPathComponent("src/target.txt"))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "target.txt")
        _ = try FileSyncManager.safeCopyItem(at: source, to: destination, fileManager: trash)
        #expect(entryExists(destination) && !FileManager.default.fileExists(atPath: destination.path))

        let m = manager()
        await m.registerCopyUndo(items: [(source: source, destination: destination, overwritten: nil)],
                                 actionName: "Copy 1 Item", fileManager: trash).value

        await undoAndDrain(m)

        #expect(!entryExists(destination), "the copied link was left behind as \"already gone\"")
        #expect(trash.names.contains("link"))
        #expect(entryExists(source))
    }

    // MARK: FR35

    /// A move whose merge emptied its source folder: ⌘Z puts that folder back, its own extended
    /// attributes with it, and the children inside it, not a new folder while the original stays
    /// in the Trash.
    @MainActor
    @Test func aMergeMoveUndoRestoresTheOriginalSourceFolderFromTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-source-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("a", src.appendingPathComponent("a.txt"))
        try writeText("c", src.appendingPathComponent("sub/c.txt"))
        try writeText("kept", dst.appendingPathComponent("kept.txt"))
        try writeText("other c", dst.appendingPathComponent("sub/other.txt"))
        // Marks on both folders a merge empties, standing in for tags, icon and dates.
        for folder in [src, src.appendingPathComponent("sub")] {
            let value = Array(folder.lastPathComponent.utf8)
            #expect(setxattr(folder.path, Self.mark, value, value.count, 0, 0) == 0)
        }

        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        // The premise: both emptied folders went to the Trash.
        #expect(!entryExists(src))
        #expect(trash.names.contains("Reports") && trash.names.contains("sub"), "trash: \(trash.names)")

        await undoAndDrain(m)

        #expect(readText(src.appendingPathComponent("a.txt")) == "a")
        #expect(readText(src.appendingPathComponent("sub/c.txt")) == "c")
        #expect(markOn(src) == "Reports", "the source folder is a new one, not the original")
        #expect(markOn(src.appendingPathComponent("sub")) == "sub", "the nested folder is a new one, not the original")
        #expect(!trash.names.contains("Reports") && !trash.names.contains("sub"),
                "the original folders are still in the Trash: \(trash.names)")
        #expect(readText(dst.appendingPathComponent("kept.txt")) == "kept")
        #expect(readText(dst.appendingPathComponent("sub/other.txt")) == "other c")
    }

    /// A merge that moved nothing out still has an undo. Its source held only a `.DS_Store`, so no
    /// child landed, but the emptied folder still went to the Trash and ⌘Z must bring it back.
    @MainActor
    @Test func aMergeMoveThatLandsNoChildStillUndoesItsTrashedSource() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-nothing-landed")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("finder", src.appendingPathComponent(".DS_Store"))
        try writeText("kept", dst.appendingPathComponent("kept.txt"))
        // The destination keeps its own `.DS_Store`, so the source's is skipped, not moved.
        try writeText("its own", dst.appendingPathComponent(".DS_Store"))
        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        try #require(!entryExists(src), "premise: the merge did not trash its emptied source")
        try #require(readText(dst.appendingPathComponent(".DS_Store")) == "its own", "premise: a child landed")
        #expect(m.undoManager?.canUndo == true, "nothing was registered to bring the folder back")

        await undoAndDrain(m)

        #expect(entryExists(src))
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
        #expect(readText(dst.appendingPathComponent("kept.txt")) == "kept")
    }

    /// Moves `src/Reports` (holding `a.txt`) into a `dst` that already has a `Reports`, with Merge,
    /// and undoes it: where every merge redo test starts.
    @MainActor
    private func mergeMoveAndUndo(in root: URL, trash: ScratchTrash) async throws -> (m: FileSyncManager, src: URL, dst: URL) {
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("a", src.appendingPathComponent("a.txt"))
        try writeText("kept", dst.appendingPathComponent("kept.txt"))
        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        #expect(readText(dst.appendingPathComponent("a.txt")) == "a")
        #expect(!entryExists(src))
        await undoAndDrain(m)
        #expect(readText(src.appendingPathComponent("a.txt")) == "a")
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
        return (m, src, dst)
    }

    @MainActor
    private func redoAndDrain(_ m: FileSyncManager) async {
        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 }
    }

    /// The redo of a merge-move trashes the source folder only when the merge's rule holds then:
    /// nothing left in it but a `.DS_Store`. A child whose redo was refused (edited since the undo)
    /// stays inside, so the folder stays too and the banner says so, rather than carrying the
    /// child into the Trash under a banner saying it was left in place.
    @MainActor
    @Test func aMergeMoveRedoLeavesTheSourceFolderHoldingARefusedChild() async throws {
        let root = try makeCanonicalTempRoot(prefix: "redo-merge-refused-child")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, dst) = try await mergeMoveAndUndo(in: root, trash: trash)

        // Edited in place: the folder's child names don't change, so the folder's own identity
        // still passes the redo's check.
        let handle = try FileHandle(forWritingTo: src.appendingPathComponent("a.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" edited".utf8))
        try handle.close()

        await redoAndDrain(m)

        #expect(readText(src.appendingPathComponent("a.txt")) == "a edited",
                "the refused child left its folder; trash: \(trash.names)")
        #expect(!trash.names.contains("Reports"), "the folder went to the Trash: \(trash.names)")
        #expect(!entryExists(dst.appendingPathComponent("a.txt")))
        #expect(m.banner?.message.contains("Redo left “Reports” in place") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// The control: nothing refused, so the redo empties the folder again and trashes it, as the
    /// move itself did.
    @MainActor
    @Test func aMergeMoveRedoStillTrashesTheSourceFolderItEmptied() async throws {
        let root = try makeCanonicalTempRoot(prefix: "redo-merge-emptied")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, dst) = try await mergeMoveAndUndo(in: root, trash: trash)

        await redoAndDrain(m)

        #expect(readText(dst.appendingPathComponent("a.txt")) == "a")
        #expect(!entryExists(src), "the emptied folder was left behind")
        #expect(trash.names.contains("Reports"), "trash: \(trash.names)")
    }

    /// Writes the `.DS_Store` Finder adds to a folder the user opens, into the `Reports` folder in
    /// the Trash. The folder is empty there, so its raw child count moves for certain, whatever
    /// the clock's resolution does to its date.
    private func browseTrashedReports(_ trash: ScratchTrash) throws {
        let slots = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        let trashed = try #require(slots.map { $0.appendingPathComponent("Reports") }.first(where: entryExists),
                                   "trash: \(trash.names)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trashed.path).isEmpty,
                "the premise: the merge left the folder empty")
        try writeText("finder view state", trashed.appendingPathComponent(".DS_Store"))
    }

    private static let mark = "com.synccloud.test.fr35"

    private func setMark(_ folder: URL) {
        let value = Array("original".utf8)
        #expect(setxattr(folder.path, Self.mark, value, value.count, 0, 0) == 0)
    }

    private func markOn(_ folder: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(folder.path, Self.mark, &buffer, buffer.count, 0, 0)
        return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : nil
    }

    /// Moves `src/Reports` (holding `a.txt`, marked "original") into a `dst` that already has a
    /// `Reports`, with Merge. `afterRedo` then undoes and redoes it, so the record the next ⌘Z reads
    /// is the redo's. Returns the moment the move (or redo) does: the callers tamper with the
    /// Trash on the next line (`docs/flaky-tests.md`, entry 41).
    @MainActor
    private func mergeMove(in root: URL, trash: ScratchTrash, afterRedo: Bool) async throws -> (m: FileSyncManager, src: URL, dst: URL) {
        if afterRedo {
            let (m, src, dst) = try await mergeMoveAndUndo(in: root, trash: trash)
            setMark(src)
            await redoAndDrain(m)
            return (m, src, dst)
        }
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("a", src.appendingPathComponent("a.txt"))
        try writeText("kept", dst.appendingPathComponent("kept.txt"))
        setMark(src)
        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        return (m, src, dst)
    }

    /// The source folder a merge trashed is held to the rule of every other Trash backup: deep, OS
    /// noise ignored. Finder writes a `.DS_Store` into a folder the user merely opens in the Trash,
    /// moving its date and child count; a ⌘Z after a look must still put that folder back. The same
    /// after a redo: the redo's record of the folder it put back in the Trash follows the same rule.
    @MainActor
    @Test(arguments: [false, true])
    func aMergeMoveUndoRestoresTheSourceFolderFinderBrowsedInTheTrash(afterRedo: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-browsed-source\(afterRedo ? "-redo" : "")")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, _) = try await mergeMove(in: root, trash: trash, afterRedo: afterRedo)
        if afterRedo {
            #expect(!entryExists(src) && trash.names.contains("Reports"), "the redo did not trash the emptied folder: \(trash.names)")
        }
        try browseTrashedReports(trash)
        await undoAndDrain(m)

        #expect(markOn(src) == "original", "the folder Finder browsed in the Trash was refused; banner: \(m.banner?.message ?? "nil")")
        #expect(readText(src.appendingPathComponent("a.txt")) == "a")
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
    }

    /// A stranger at the emptied folder's Trash path is not pulled out as the source folder. Every
    /// merge-emptied folder has the same contents digest, so another empty `Reports` trashed into
    /// the freed name would match; the folder's own file number tells them apart, and a
    /// `.DS_Store` doesn't change it. The stranger stays in the Trash, its mark with it, and the
    /// child goes back into a folder made for it. The same after a redo, whose record of the folder
    /// it put back in the Trash is the one the next ⌘Z reads.
    @MainActor
    @Test(arguments: [false, true])
    func aMergeMoveUndoLeavesAnEmptyStrangerFolderAtTheSourceFoldersTrashPathInTheTrash(afterRedo: Bool) async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-stranger-source\(afterRedo ? "-redo" : "")")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, dst) = try await mergeMove(in: root, trash: trash, afterRedo: afterRedo)
        let trashed = try swapTrashedReportsForAnEmptyStranger(trash)

        await undoAndDrain(m)

        #expect(markOn(trashed) == "stranger", "the stranger left the Trash; src mark: \(markOn(src) ?? "nil")")
        #expect(markOn(src) == nil, "the stranger was put back as the source folder")
        #expect(readText(src.appendingPathComponent("a.txt")) == "a")
        #expect(readText(dst.appendingPathComponent("kept.txt")) == "kept")
    }

    /// Empties the `Reports` folder out of the Trash and puts another empty `Reports`, marked
    /// "stranger", at the path it freed, as trashing another empty folder of that name does.
    /// Returns that path.
    private func swapTrashedReportsForAnEmptyStranger(_ trash: ScratchTrash) throws -> URL {
        let slots = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        let trashed = try #require(slots.map { $0.appendingPathComponent("Reports") }.first(where: entryExists),
                                   "trash: \(trash.names)")
        #expect(markOn(trashed) == "original", "the premise: the source folder itself is in the Trash")
        try FileManager.default.removeItem(at: trashed)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: false)
        let value = Array("stranger".utf8)
        #expect(setxattr(trashed.path, Self.mark, value, value.count, 0, 0) == 0)
        return trashed
    }
}
