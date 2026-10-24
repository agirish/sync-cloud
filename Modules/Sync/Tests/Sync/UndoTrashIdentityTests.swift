import Testing
import Foundation
@testable import Sync

/// What an undo takes back OUT of the Trash, and what it decides is gone.
///
/// - **FR27** — every undo that restores from the Trash moved whatever sat at the recorded Trash
///   path. Empty the Trash, trash a different file of the same name, and macOS gives it the freed
///   name: ⌘Z then moved that unrelated file into the folder it was restoring.
/// - **FR28** — the copy-undo and move-undo asked `fileExists` whether their item had vanished.
///   It follows links, so a dangling link — what moving a relative link usually leaves — read as
///   gone: never moved back, never removed.
/// - **FR35** — a move's merge put the emptied source folder in the Trash outside the undo record,
///   so ⌘Z made a NEW folder for the children and the original stayed in the Trash.
///
/// Real disk with a `ScratchTrash` throughout: the claims are about where items end up, and the
/// mock's flat paths and link-less stat cannot model either.
@Suite struct UndoTrashIdentityTests {

    @MainActor
    private func manager() -> FileSyncManager {
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.collisionResolver = { _ in .replace }
        m.bulkCollisionResolver = { _ in (.replace, false) }
        m.permanentDeleteConfirmer = { _ in false }
        return m
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Whether any entry — a dangling link included — is at `url`.
    private func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Puts a DIFFERENT item at a Trash backup's path: what emptying the Trash and then trashing
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
    /// path stays there, nothing lands at the original path, and the banner says why.
    @MainActor
    @Test func aDeleteUndoLeavesAStrangerAtItsTrashPathInTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("folder/report.txt")
        try write("the report", original)
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)

        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        try replaceInTrash(backup)

        await undoAndDrain(m)

        #expect(!entryExists(original), "the undo restored an item the delete never put in the Trash")
        #expect(read(backup) == "an unrelated file the user trashed later")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// The control: the same delete, untouched in the Trash, comes back.
    @MainActor
    @Test func aDeleteUndoStillRestoresItsOwnItem() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-delete-control")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("folder/report.txt")
        try write("the report", original)
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)

        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value

        await undoAndDrain(m)

        #expect(read(original) == "the report")
        #expect(!entryExists(backup))
    }

    /// A deleted FOLDER that Finder has written a `.DS_Store` into while it sat in the Trash — the
    /// user opened it there — is still the folder the delete put there, and comes back. A folder
    /// of the same name with different contents does not.
    @MainActor
    @Test func aDeletedFolderComesBackAfterFinderBrowsedItButAStrangerFolderDoesNot() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)

        func deleteFolder(_ name: String) throws -> (original: URL, backup: URL) {
            let original = root.appendingPathComponent("docs/\(name)")
            try write("one", original.appendingPathComponent("one.txt"))
            try write("two", original.appendingPathComponent("sub/two.txt"))
            var trashedURL: NSURL?
            try trash.trashItem(at: original, resultingItemURL: &trashedURL)
            return (original, try #require(trashedURL as URL?))
        }

        let browsed = try deleteFolder("Browsed")
        let m = manager()
        await m.registerRestoreItems(urls: [browsed.original], trashedItems: [browsed.backup],
                                     actionName: "Delete 1 Item", fileManager: trash).value
        try write("finder view state", browsed.backup.appendingPathComponent(".DS_Store"))
        await undoAndDrain(m)
        #expect(read(browsed.original.appendingPathComponent("sub/two.txt")) == "two",
                "a folder Finder merely opened in the Trash was refused as a stranger")

        let swapped = try deleteFolder("Swapped")
        let m2 = manager()
        await m2.registerRestoreItems(urls: [swapped.original], trashedItems: [swapped.backup],
                                      actionName: "Delete 1 Item", fileManager: trash).value
        try FileManager.default.removeItem(at: swapped.backup)
        try write("someone else's", swapped.backup.appendingPathComponent("other.txt"))
        await undoAndDrain(m2)
        #expect(!entryExists(swapped.original), "a different folder of the same name was restored")
        #expect(read(swapped.backup.appendingPathComponent("other.txt")) == "someone else's")
    }

    /// A move that replaced a file: ⌘Z moves the file back, and puts back only the file the move
    /// itself sent to the Trash — not one that has taken its name there since.
    @MainActor
    @Test func aMoveUndoDoesNotPutAStrangerFromTheTrashInPlaceOfTheReplacedFile() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let from = root.appendingPathComponent("src/f.txt")
        let to = root.appendingPathComponent("dst/f.txt")
        try write("moved", from)
        try write("replaced", to)
        let backup = try #require(try FileSyncManager.safeMoveItem(at: from, to: to, fileManager: trash))

        let m = manager()
        await m.registerMoveUndo(items: [(from: from, to: to, overwritten: backup)], actionName: "Move 1 Item", fileManager: trash).value
        try replaceInTrash(backup)

        await undoAndDrain(m)

        #expect(read(from) == "moved", "the move itself was not undone")
        #expect(!entryExists(to), "a file the move never displaced was put at its destination")
        #expect(read(backup) == "an unrelated file the user trashed later")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// The copy-undo's twin: the copy goes, and a stranger in the Trash is not put in its place.
    @MainActor
    @Test func aCopyUndoDoesNotPutAStrangerFromTheTrashInPlaceOfTheReplacedFile() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let source = root.appendingPathComponent("src/f.txt")
        let destination = root.appendingPathComponent("dst/f.txt")
        try write("copied", source)
        try write("replaced", destination)
        let backup = try #require(try FileSyncManager.safeCopyItem(at: source, to: destination, fileManager: trash))

        let m = manager()
        await m.registerCopyUndo(items: [(source: source, destination: destination, overwritten: backup)],
                                 actionName: "Copy 1 Item", fileManager: trash).value
        try replaceInTrash(backup)

        await undoAndDrain(m)

        #expect(!entryExists(destination), "a file the copy never displaced was put at its destination")
        #expect(read(backup) == "an unrelated file the user trashed later")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == true,
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// Makes `folder` unreadable (mode 000), the way a subfolder another account owns or a cloud
    /// folder that does not answer leaves a deep walk partial. Returns the undo for a `defer`.
    private func lock(_ folder: URL) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
    }

    /// A deleted folder holding one unreadable subfolder records `.indeterminate` — nothing could
    /// be known about it when the undo registered — and ⌘Z restores it, as it did before FR27. A
    /// recorded `.indeterminate` is the absence of an identity, not a mismatch with one.
    @MainActor
    @Test func aDeleteUndoRestoresAFolderWhoseIdentityCouldNotBeRecorded() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-unrecorded")
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("docs/Project")
        try write("one", original.appendingPathComponent("one.txt"))
        try write("secret", original.appendingPathComponent("private/s.txt"))
        let unlockOriginal = try lock(original.appendingPathComponent("private"))
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)
        let unlockBackup = { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backup.appendingPathComponent("private").path) }
        defer { unlockBackup(); unlockOriginal(); try? FileManager.default.removeItem(at: root) }
        // The premise: nothing could be recorded.
        #expect(FileSyncManager.backupIdentity(backup, fileManager: trash) == .indeterminate)

        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        await undoAndDrain(m)

        #expect(read(original.appendingPathComponent("one.txt")) == "one",
                "the undo refused the folder this delete put in the Trash: \(m.banner?.message ?? "nil")")
        #expect(!entryExists(backup))
    }

    /// Against an identity that WAS recorded, a backup that cannot be read at ⌘Z still refuses —
    /// and the banner says it couldn't be read, not that it is a stranger.
    @MainActor
    @Test func aDeleteUndoOfABackupThatCannotBeReadNowSaysSo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-unreadable-now")
        let trash = ScratchTrash(in: root)
        let original = root.appendingPathComponent("docs/Project")
        try write("one", original.appendingPathComponent("one.txt"))
        try write("secret", original.appendingPathComponent("private/s.txt"))
        var trashedURL: NSURL?
        try trash.trashItem(at: original, resultingItemURL: &trashedURL)
        let backup = try #require(trashedURL as URL?)
        let m = manager()
        await m.registerRestoreItems(urls: [original], trashedItems: [backup], actionName: "Delete 1 Item", fileManager: trash).value
        let unlock = try lock(backup.appendingPathComponent("private"))
        defer { unlock(); try? FileManager.default.removeItem(at: root) }

        await undoAndDrain(m)

        #expect(!entryExists(original))
        #expect(read(backup.appendingPathComponent("one.txt")) == "one")
        #expect(m.banner?.message == "Undo didn’t restore “Project” — the item in the Trash under that name couldn’t be read",
                "banner: \(m.banner?.message ?? "nil")")
    }

    /// Replaces `dst/Project` with `src/Project` by `transfer` (a copy or a move), so the replaced
    /// folder — holding a `private` subfolder — goes to the Trash as the backup.
    private func replaceFolder(in root: URL, trash: ScratchTrash,
                               by transfer: (URL, URL) throws -> URL?) throws -> (src: URL, dst: URL, backup: URL) {
        let src = root.appendingPathComponent("src/Project")
        let dst = root.appendingPathComponent("dst/Project")
        try write("new", src.appendingPathComponent("new.txt"))
        try write("old", dst.appendingPathComponent("old.txt"))
        try write("old private", dst.appendingPathComponent("private/p.txt"))
        let backup = try #require(try transfer(src, dst))
        return (src, dst, backup)
    }

    /// A copy-undo whose backup was recorded but cannot be read at undo time refuses BEFORE it
    /// trashes the copy: the copy stays at the destination and the original stays in the Trash,
    /// both recoverable, and the banner says the backup couldn't be read — not that it is a
    /// stranger. Trashing the copy first left the destination empty with the original stranded.
    @MainActor
    @Test func aCopyUndoWhoseBackupCannotBeReadLeavesTheCopyInPlace() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-copy-unreadable")
        let trash = ScratchTrash(in: root)
        let (src, dst, backup) = try replaceFolder(in: root, trash: trash) {
            try FileSyncManager.safeCopyItem(at: $0, to: $1, fileManager: trash)
        }
        let m = manager()
        await m.registerCopyUndo(items: [(source: src, destination: dst, overwritten: backup)],
                                 actionName: "Copy 1 Item", fileManager: trash).value
        let unlock = try lock(backup.appendingPathComponent("private"))
        defer { unlock(); try? FileManager.default.removeItem(at: root) }

        await undoAndDrain(m)

        #expect(read(dst.appendingPathComponent("new.txt")) == "new", "the copy was removed though its backup could not be put back")
        #expect(read(backup.appendingPathComponent("old.txt")) == "old")
        #expect(m.banner?.message.contains("couldn’t be read") == true, "banner: \(m.banner?.message ?? "nil")")
        #expect(m.banner?.message.contains("isn’t the one SyncCloud put there") == false)
    }

    /// The move-undo's twin: the moved folder is not moved back while the backup it would restore
    /// in its place cannot be read.
    @MainActor
    @Test func aMoveUndoWhoseBackupCannotBeReadLeavesTheMovedItemInPlace() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-trash-identity-move-unreadable")
        let trash = ScratchTrash(in: root)
        let (src, dst, backup) = try replaceFolder(in: root, trash: trash) {
            try FileSyncManager.safeMoveItem(at: $0, to: $1, fileManager: trash)
        }
        let m = manager()
        await m.registerMoveUndo(items: [(from: src, to: dst, overwritten: backup)],
                                 actionName: "Move 1 Item", fileManager: trash).value
        let unlock = try lock(backup.appendingPathComponent("private"))
        defer { unlock(); try? FileManager.default.removeItem(at: root) }

        await undoAndDrain(m)

        #expect(read(dst.appendingPathComponent("new.txt")) == "new", "the moved item went back though its backup could not be put back")
        #expect(!entryExists(src))
        #expect(read(backup.appendingPathComponent("old.txt")) == "old")
        #expect(m.banner?.message.contains("couldn’t be read") == true, "banner: \(m.banner?.message ?? "nil")")
    }

    // MARK: FR28

    /// A relative link moved to another folder dangles there — and is still the item the move put
    /// there, so ⌘Z moves it back.
    @MainActor
    @Test func aMoveUndoMovesADanglingLinkBack() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-dangling-link-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let from = root.appendingPathComponent("src/link")
        let to = root.appendingPathComponent("dst/link")
        try write("target", root.appendingPathComponent("src/target.txt"))
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

    /// The copy-undo's twin: a copied link that dangles is still the copy, and ⌘Z removes it.
    @MainActor
    @Test func aCopyUndoRemovesADanglingLinkItCopied() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-dangling-link-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let source = root.appendingPathComponent("src/link")
        let destination = root.appendingPathComponent("dst/link")
        try write("target", root.appendingPathComponent("src/target.txt"))
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

    /// A move whose merge emptied its source folder: ⌘Z puts THAT folder back — its own extended
    /// attributes with it — and the children back inside it, rather than a new empty folder while
    /// the original stays in the Trash.
    @MainActor
    @Test func aMergeMoveUndoRestoresTheOriginalSourceFolderFromTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-source-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try write("a", src.appendingPathComponent("a.txt"))
        try write("c", src.appendingPathComponent("sub/c.txt"))
        try write("kept", dst.appendingPathComponent("kept.txt"))
        try write("other c", dst.appendingPathComponent("sub/other.txt"))
        // Marks on both folders a merge empties, standing in for tags, icon and dates.
        let mark = "com.synccloud.test.fr35"
        for folder in [src, src.appendingPathComponent("sub")] {
            let value = Array(folder.lastPathComponent.utf8)
            #expect(setxattr(folder.path, mark, value, value.count, 0, 0) == 0)
        }
        func markOn(_ folder: URL) -> String? {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = getxattr(folder.path, mark, &buffer, buffer.count, 0, 0)
            return n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : nil
        }

        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        // The premise: both emptied folders went to the Trash.
        #expect(!entryExists(src))
        #expect(trash.names.contains("Reports") && trash.names.contains("sub"), "trash: \(trash.names)")

        await undoAndDrain(m)

        #expect(read(src.appendingPathComponent("a.txt")) == "a")
        #expect(read(src.appendingPathComponent("sub/c.txt")) == "c")
        #expect(markOn(src) == "Reports", "the source folder is a new one, not the original")
        #expect(markOn(src.appendingPathComponent("sub")) == "sub", "the nested folder is a new one, not the original")
        #expect(!trash.names.contains("Reports") && !trash.names.contains("sub"),
                "the original folders are still in the Trash: \(trash.names)")
        #expect(read(dst.appendingPathComponent("kept.txt")) == "kept")
        #expect(read(dst.appendingPathComponent("sub/other.txt")) == "other c")
    }

    /// Moves `src/Reports` (holding `a.txt`) into a `dst` that already has a `Reports`, with Merge,
    /// and undoes it: the shape every FR35 redo test starts from.
    @MainActor
    private func mergeMoveAndUndo(in root: URL, trash: ScratchTrash) async throws -> (m: FileSyncManager, src: URL, dst: URL) {
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try write("a", src.appendingPathComponent("a.txt"))
        try write("kept", dst.appendingPathComponent("kept.txt"))
        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        #expect(read(dst.appendingPathComponent("a.txt")) == "a")
        #expect(!entryExists(src))
        await undoAndDrain(m)
        #expect(read(src.appendingPathComponent("a.txt")) == "a")
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
        return (m, src, dst)
    }

    @MainActor
    private func redoAndDrain(_ m: FileSyncManager) async {
        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 }
    }

    /// The redo of a merge-move trashes the source folder only when the merge's own rule holds at
    /// that moment — nothing left in it but a `.DS_Store`. A child whose redo was refused (edited
    /// since the undo) stays inside it, so the folder stays too, and the banner says so; it is not
    /// carried into the Trash under a banner saying the child was left in place.
    @MainActor
    @Test func aMergeMoveRedoLeavesTheSourceFolderHoldingARefusedChild() async throws {
        let root = try makeCanonicalTempRoot(prefix: "redo-merge-refused-child")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, dst) = try await mergeMoveAndUndo(in: root, trash: trash)

        // Edited in place: the folder's own date and child count do not move, so its identity
        // passes the redo's up-front check.
        let handle = try FileHandle(forWritingTo: src.appendingPathComponent("a.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" edited".utf8))
        try handle.close()

        await redoAndDrain(m)

        #expect(read(src.appendingPathComponent("a.txt")) == "a edited",
                "the refused child left its folder; trash: \(trash.names)")
        #expect(!trash.names.contains("Reports"), "the folder went to the Trash: \(trash.names)")
        #expect(!entryExists(dst.appendingPathComponent("a.txt")))
        #expect(m.banner?.message.contains("Redo left \"Reports\" in place") == true,
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

        #expect(read(dst.appendingPathComponent("a.txt")) == "a")
        #expect(!entryExists(src), "the emptied folder was left behind")
        #expect(trash.names.contains("Reports"), "trash: \(trash.names)")
    }

    /// Writes the `.DS_Store` Finder adds to a folder the user opens, into the `Reports` folder in
    /// the Trash. The folder is empty there, so its shallow identity's child count moves for
    /// certain, whatever the clock's resolution does to its date.
    private func browseTrashedReports(_ trash: ScratchTrash) throws {
        let slots = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        let trashed = try #require(slots.map { $0.appendingPathComponent("Reports") }.first(where: entryExists),
                                   "trash: \(trash.names)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trashed.path).isEmpty,
                "the premise: the merge left the folder empty")
        try write("finder view state", trashed.appendingPathComponent(".DS_Store"))
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

    /// The source folder a merge trashed is held to the identity rule of every other Trash backup
    /// (FR27): deep, OS noise ignored. Finder writes a `.DS_Store` into a folder the user merely
    /// opens in the Trash, which moves the folder's own date and child count; a ⌘Z after a look
    /// must still put THAT folder back.
    @MainActor
    @Test func aMergeMoveUndoRestoresTheSourceFolderFinderBrowsedInTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-browsed-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try write("a", src.appendingPathComponent("a.txt"))
        try write("kept", dst.appendingPathComponent("kept.txt"))
        setMark(src)

        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        try browseTrashedReports(trash)
        await undoAndDrain(m)

        #expect(markOn(src) == "original", "the folder Finder browsed in the Trash was refused; banner: \(m.banner?.message ?? "nil")")
        #expect(read(src.appendingPathComponent("a.txt")) == "a")
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
    }

    /// **A stranger at the emptied folder's Trash path is not pulled out as the source folder.** The
    /// merge trashes the folder only once nothing but a `.DS_Store` is left in it, so its contents
    /// digest is the same for every such folder: empty the Trash, trash some other empty `Reports`
    /// — macOS hands it the freed name — and ⌘Z moved THAT folder out as `src/Reports`. The
    /// folder's own file number tells them apart; Finder's `.DS_Store` does not change it, so the
    /// browsed tests above still restore the real one. The stranger stays in the Trash, its mark
    /// with it, and the child goes back into a folder made for it, as before FR35.
    @MainActor
    @Test func aMergeMoveUndoLeavesAnEmptyStrangerFolderAtTheSourceFoldersTrashPathInTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-stranger-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try write("a", src.appendingPathComponent("a.txt"))
        try write("kept", dst.appendingPathComponent("kept.txt"))
        setMark(src)

        let m = manager()
        m.collisionResolver = { _ in .merge }
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        let trashed = try swapTrashedReportsForAnEmptyStranger(trash)

        await undoAndDrain(m)

        #expect(markOn(trashed) == "stranger", "the stranger left the Trash; src mark: \(markOn(src) ?? "nil")")
        #expect(markOn(src) == nil, "the stranger was put back as the source folder")
        #expect(read(src.appendingPathComponent("a.txt")) == "a")
        #expect(read(dst.appendingPathComponent("kept.txt")) == "kept")
    }

    /// The same after a redo, whose own record of the folder it put back in the Trash is the one
    /// the next ⌘Z reads.
    @MainActor
    @Test func aMergeMoveUndoAfterARedoLeavesAnEmptyStrangerFolderInTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-stranger-source-redo")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, _) = try await mergeMoveAndUndo(in: root, trash: trash)
        setMark(src)

        await redoAndDrain(m)
        let trashed = try swapTrashedReportsForAnEmptyStranger(trash)
        await undoAndDrain(m)

        #expect(markOn(trashed) == "stranger", "the stranger left the Trash; src mark: \(markOn(src) ?? "nil")")
        #expect(markOn(src) == nil, "the stranger was put back as the source folder")
        #expect(read(src.appendingPathComponent("a.txt")) == "a")
    }

    /// Empties the `Reports` folder out of the Trash and puts another empty `Reports`, marked
    /// "stranger", at the path it freed — what trashing some other empty folder of that name does.
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

    /// The same after a redo: the redo's own record of the folder it put back in the Trash follows
    /// the same rule, so the next ⌘Z after a look in the Trash still restores it.
    @MainActor
    @Test func aMergeMoveUndoAfterARedoRestoresTheSourceFolderFinderBrowsedInTheTrash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "undo-merge-browsed-source-redo")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let (m, src, _) = try await mergeMoveAndUndo(in: root, trash: trash)
        setMark(src)

        await redoAndDrain(m)
        #expect(!entryExists(src) && trash.names.contains("Reports"), "the redo did not trash the emptied folder: \(trash.names)")
        try browseTrashedReports(trash)
        await undoAndDrain(m)

        #expect(markOn(src) == "original", "the folder Finder browsed in the Trash was refused; banner: \(m.banner?.message ?? "nil")")
        #expect(read(src.appendingPathComponent("a.txt")) == "a")
        #expect(!trash.names.contains("Reports"), "trash: \(trash.names)")
    }
}
