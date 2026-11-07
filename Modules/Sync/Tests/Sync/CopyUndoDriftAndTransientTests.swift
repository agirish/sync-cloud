import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins two copy-undo guards:
///
/// 1. Drift: `registerCopyUndo` records each copied item's `ItemIdentity` (files and folders), and
///    the undo refuses to trash a destination that is no longer that item, as the move- and
///    delete-undos do. A refused item stays out of the redo params.
/// 2. Transient trash failures: a busy or locked destination (EBUSY and the like) is reported as
///    retryable rather than escalating to the permanent-delete prompt, by the same
///    `isTransientTrashFailure` rule `deleteItems` uses. `registerCreateFolderUndo` does the same.
@Suite struct CopyUndoDriftAndTransientTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    private static func transientBusyError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
    }

    // MARK: Drift guard

    /// The copy was replaced by a different-size item before the undo: the undo refuses to trash
    /// it (warning banner), leaves it on disk, keeps its overwritten backup in the Trash, and keeps
    /// it out of the redo params.
    @MainActor
    @Test func copyUndoRefusesWhenDestinationSizeDrifted() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5) // will be overwritten (collision .replace) and trashed

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backupPath = try #require(mockFM.trashedPaths.first)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // A different item (size 777) takes the copy's place before the undo.
        mockFM.virtualDisk["/dst/f.txt"] = file(777)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("copy undo refuses the drifted destination") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.message.contains("changed since") == true)
        // The drifted item is untouched, and the 5-byte backup was NOT restored over it.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 777)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // Redo must skip the refused item: nothing is re-copied over the drifted survivor.
        manager.banner = nil
        manager.undoManager?.redo()
        // The drain is a real gate: `registerCopyRedo`'s handler pre-counts the operation inside
        // `redo()`, even with no params, and `enqueueFileOperation` decrements only after its
        // body returns, so a zero count means finished, not "not started".
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 777)
    }

    /// Control: an unchanged copy still undoes cleanly — trashed, backup restored, no banner.
    @MainActor
    @Test func copyUndoStillRemovesUnchangedCopy() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo restores the overwritten original") {
            mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil)
    }

    // MARK: Duplicate registrations

    /// The duplicate-registration guard holds on the permanent-delete path too. One path
    /// registered twice (the second copy replaced the first) on a Trash-less volume puts both items
    /// in `trashFailures`; without the guard, item B's `removeItem` would permanently unlink the
    /// pre-batch original item A just restored (silent data loss), and the prompt names it twice.
    @MainActor
    @Test func copyUndoDuplicateRegistrationOnTrashlessVolumeRemovesOnce() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/srcA"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/srcB"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/srcA/f.txt"] = file(100)
        mockFM.virtualDisk["/srcB/f.txt"] = file(200)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)      // the pre-batch original

        // Installed BEFORE the copy: the undo registration captures the confirmer.
        var promptedPaths: [String] = []
        manager.permanentDeleteConfirmer = { paths in promptedPaths = paths; return true }

        // One batch, two same-named sources: the replace resolver registers /dst/f.txt twice.
        await manager.copyItems(nodes: [FileNode(id: "/srcA/f.txt", name: "f.txt", isDirectory: false),
                                        FileNode(id: "/srcB/f.txt", name: "f.txt", isDirectory: false)],
                                toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 200)

        mockFM.shouldFailTrash = true                    // Trash-less volume from here on

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(promptedPaths == ["/dst/f.txt"])         // named once, not per registration — and by PATH
        // The pre-batch original survived its restore: item B must not unlink it.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5)
    }

    /// The duplicate gate also recognizes case-variant registrations of one on-disk file. After the
    /// first variant is handled, the second's exact string misses the set, and the vanished branch
    /// would restore its backup, resurrecting content the undo just removed. The folded check is
    /// volume-gated: on a case-sensitive destination two variants are two real files.
    @MainActor
    @Test func copyUndoCaseVariantDuplicateNeverResurrectsThroughTheVanishedBranch() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/F.txt"] = file(100)
        mockFM.virtualDisk["/src/f.txt"] = file(200)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)       // displaced by the second copy → its backup

        await manager.copyItems(nodes: [FileNode(id: "/src/F.txt", name: "F.txt", isDirectory: false),
                                        FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)],
                                toPath: "/dst", fileManager: mockFM)

        // The user deletes the lowercase variant, then undoes. The mock disk keeps the variants as
        // separate keys, but the real volume that gates the folded check is the case-insensitive
        // macOS default, where they name one file.
        try mockFM.removeItem(at: URL(fileURLWithPath: "/dst/f.txt"))
        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The folded gate swallows the second variant: no backup resurrected at the vanished path.
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    // MARK: Vanished copies

    /// A copied folder the user already deleted raises no phantom permanent-delete prompt on ⌘Z.
    /// The `fileExists` branch ahead of the drift guard makes it a clean no-op: without it the
    /// missing copy would reach the guard and refuse with a "changed" banner, and a no-such-file
    /// error from `trashItem` isn't transient, so it would escalate to the prompt.
    @MainActor
    @Test func copyUndoOfVanishedDirectorySkipsThePermanentDeletePrompt() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/folder"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/folder/inner.txt"] = file(50)

        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in promptFired = true; return true }

        let node = FileNode(id: "/src/folder", name: "folder", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/folder"] != nil)

        // The user deletes the copy in Finder, then presses ⌘Z.
        try mockFM.removeItem(at: URL(fileURLWithPath: "/dst/folder"))
        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(promptFired == false)                        // no phantom "permanently delete?"
        #expect(mockFM.virtualDisk["/dst/folder"] == nil)    // still gone; nothing resurrected
    }

    /// The vanished-copy undo still restores the overwritten backup: the path is free, so the
    /// original the copy displaced goes back rather than staying stranded in the Trash.
    @MainActor
    @Test func copyUndoOfVanishedFileRestoresTheOverwrittenBackup() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)           // will be displaced into the backup

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)

        try mockFM.removeItem(at: URL(fileURLWithPath: "/dst/f.txt"))
        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The displaced original is back at its path.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5)
    }

    // MARK: Transient trash failures

    /// A transiently busy copy (EBUSY on trash) never reaches the permanent-delete prompt: the item
    /// stays on disk for a retry and a warning banner is raised.
    @MainActor
    @Test func copyUndoTransientTrashFailureNeverPromptsPermanentDelete() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

        // The prompt must never fire for a transient failure, even one that would answer yes.
        // Installed before the copy so the undo registration captures it.
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        mockFM.trashErrorOnce = Self.transientBusyError()
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("transient trash failure surfaces a warning") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.message.contains("looks busy") == true)
        // The copy survives, neither trashed nor removed. `safeCopyItem`'s `.tmp_` cleanup shows
        // in `attemptedRemovePaths`; only the real file matters.
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(!mockFM.attemptedRemovePaths.contains("/dst/f.txt"))
        #expect(promptFired == false)
    }

    /// A genuinely Trash-less volume (ENOTSUP) still escalates to the permanent-delete
    /// confirmation.
    @MainActor
    @Test func copyUndoNonTransientTrashFailureStillEscalates() async throws {
        let manager = makeManager()
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return false
        }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        mockFM.shouldFailTrash = true // ENOTSUP — non-transient
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the declined-confirm undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(promptFired, "a Trash-less volume did not offer the permanent delete")
        // Declined permanent delete: the copy stays.
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    // MARK: Create-folder undo

    /// Undoing New Folder on a transiently busy folder doesn't offer the permanent-delete prompt
    /// either: the folder stays for a retry, with a warning banner.
    @MainActor
    @Test func createFolderUndoTransientTrashFailureNeverPromptsPermanentDelete() async throws {
        let manager = makeManager()
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)

        mockFM.trashErrorOnce = Self.transientBusyError()
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("transient folder-trash failure surfaces a warning") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        // The folder survives — not trashed, not permanently removed, no prompt.
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
        #expect(promptFired == false)
    }

    /// Control: a Trash-less volume (ENOTSUP) still prompts, and a confirmed prompt removes the
    /// folder permanently.
    @MainActor
    @Test func createFolderUndoNonTransientFailureStillPromptsAndRemoves() async throws {
        let manager = makeManager()
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)

        mockFM.shouldFailTrash = true // ENOTSUP — non-transient

        manager.undoManager?.undo()
        await waitUntil("the confirmed permanent delete removes the folder") {
            mockFM.virtualDisk["/dst/New Folder"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(promptFired == true)
    }

    /// Undoing New Folder, alone or as the last step of a Restructure ⌘Z, removes the folder only
    /// when it is empty. A file inside arrived after the folder was made: the user put it there, or
    /// the group's move-back refused it and said it was left in place, which a trash would make false.
    @MainActor
    @Test func createFolderUndoLeavesAFolderThatHoldsAFile() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        // The mock makes no intermediate folders, so each level is made by hand.
        for path in ["/dst", "/dst/Archive", "/dst/Archive/Taxes"] {
            try mockFM.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/Archive"), fileManager: mockFM)
        mockFM.virtualDisk["/dst/Archive/Taxes/edited.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/dst/Archive/Taxes/edited.pdf"] != nil)
        #expect(mockFM.virtualDisk["/dst/Archive"] != nil)
        #expect(manager.banner?.message.contains("isn’t empty") == true)
    }

    /// A link is content too: the user put it in the folder, pointing anywhere or nowhere.
    @Test func createFolderUndoLeavesAFolderHoldingOnlyALink() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fr24l-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("New Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Shared"),
                                                   withDestinationURL: base.appendingPathComponent("gone"))
        #expect(FileSyncManager.visibleFileCount(atPath: folder.path, fm: FileManager.default) == 1)
    }

    /// The other direction: Finder's droppings and what the OS keeps under `.Trashes` don't count,
    /// so the folder the action made still goes. Skipping `.Trashes` must skip what is inside it
    /// too. A real folder, as below.
    @MainActor
    @Test func createFolderUndoStillRemovesAFolderHoldingOnlyNoise() async throws {
        let base = try makeCanonicalTempRoot(prefix: "fr24n")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".Trashes/501"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".Trashes/501/old.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let manager = makeManager()
        let disk = ScratchTrash(in: base)
        manager.registerCreateFolderUndo(url: folder, fileManager: disk)

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "banner: \(String(describing: manager.banner?.message))")
    }

    /// Folders the user made inside are content, empty or not: the folder stays "if anything is
    /// still inside it", so a tree of folders with no file yet must not go to the Trash. A real
    /// folder, since the mock's entries don't say which are folders.
    @MainActor
    @Test func createFolderUndoLeavesAFolderHoldingOnlyEmptyFolders() async throws {
        let base = try makeCanonicalTempRoot(prefix: "l4f")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026/Q1"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let manager = makeManager()
        let disk = ScratchTrash(in: base)
        manager.registerCreateFolderUndo(url: folder, fileManager: disk)

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026/Q1").path))
        #expect(manager.banner?.message == "Undo left “Archive” in place — it isn’t empty")
    }

    /// …and a folder an action made inside it still goes with it. A landing that creates `Archive`
    /// and `Archive/2026` registers both in one ⌘Z, parent first (as `applyPlan` and the scaffold
    /// do), so the child's undo runs first and the parent is empty by its turn. Counting folders as
    /// content rests on that order.
    @MainActor
    @Test func oneUndoStillRemovesAFolderAndTheFolderMadeInsideIt() async throws {
        let base = try makeCanonicalTempRoot(prefix: "l4n")
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("Archive")
        let child = parent.appendingPathComponent("2026")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let manager = makeManager()
        let undo = try #require(manager.undoManager)
        let disk = ScratchTrash(in: base)
        undo.beginUndoGrouping()
        manager.registerCreateFolderUndo(url: parent, fileManager: disk)
        manager.registerCreateFolderUndo(url: child, fileManager: disk)
        undo.endUndoGrouping()

        undo.undo()
        await waitUntil("undo ops drain") { manager.activeFileOperationsCount == 0 }
        #expect(!FileManager.default.fileExists(atPath: parent.path),
                "banner: \(String(describing: manager.banner?.message))")
        #expect(disk.names == ["2026", "Archive"], "the undone folders never reached the test's own Trash")
    }

    /// A cloud-only folder inside is read with a bound. A plain enumerator would let a dataless
    /// subfolder whose app has stopped hold the serial file queue, and everything behind it, until
    /// the app answers. It reads as unknown within the deadline, and the folder is left in place.
    @MainActor
    @Test(.parksAThread) func createFolderUndoGivesUpOnAFolderInsideThatDoesNotAnswer() async throws {
        let f = UnansweredFolderTests.Fixture(root: "/fr24-dataless")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        defer { gate.release.signal() }
        let cloud = URL(fileURLWithPath: f.root + "/home/Cloud")
        let manager = makeManager()
        manager.registerCreateFolderUndo(url: cloud, fileManager: disk)

        manager.undoManager?.undo()
        await waitUntil("the undo sat on the provider past the deadline") { manager.activeFileOperationsCount == 0 }
        #expect(disk.providerReads == 1, "premise: the undo never reached the folder that does not answer")
        #expect(disk.fileExists(atPath: cloud.path))
        // Unread, not "not empty": nobody knows what is in it.
        #expect(manager.banner?.message == "Undo left “Cloud” in place — its contents couldn’t be read",
                "\(String(describing: manager.banner?.message))")
    }

    /// A confirmed permanent delete that then fails is reported: the folder is still on disk after
    /// the user agreed to destroy it, and silence would make the undo look done. The copy-undo
    /// reports its twin through `reportUndoRemoveFailure`.
    @MainActor
    @Test func createFolderUndoReportsAConfirmedPermanentDeleteThatFailed() async throws {
        let log = LogCapture()
        let manager = makeManager()
        manager.permanentDeleteConfirmer = { _ in true }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)

        mockFM.shouldFailTrash = true                                  // ENOTSUP — non-transient
        mockFM.failRemovePathsOnce = ["/dst/New Folder"]               // …and the removal fails too
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the failed permanent delete is surfaced") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("Undo couldn’t remove") == true)
        #expect(manager.banner?.message.contains("New Folder") == true)
        // The folder is still there, which is why silence would be wrong.
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        #expect(await log.entries.contains {
            $0.level == .error && $0.message.contains("Undo (New Folder): FAILED to permanently delete")
        })
    }

    /// The user declines the permanent delete, so the folder stays. Legitimate, but it is logged,
    /// or "User triggered Undo: New Folder" followed by nothing reads as a completed undo.
    @MainActor
    @Test func createFolderUndoRecordsThatTheUserDeclinedThePermanentDelete() async throws {
        let log = LogCapture()
        let manager = makeManager()   // confirmer declines
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)
        mockFM.shouldFailTrash = true

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        #expect(await log.entries.contains {
            $0.message.contains("Undo (New Folder)") && $0.message.contains("declined")
        })
    }
}
