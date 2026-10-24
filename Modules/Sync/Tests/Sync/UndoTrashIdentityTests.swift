import Testing
import Foundation
@testable import Sync

/// What an undo takes back OUT of the Trash, and what it decides is gone.
///
/// - **FR27** — every undo that restores from the Trash moved whatever sat at the recorded Trash
///   path. Empty the Trash, trash a different file of the same name, and macOS gives it the freed
///   name: ⌘Z then moved that unrelated file into the folder it was restoring.
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
}
