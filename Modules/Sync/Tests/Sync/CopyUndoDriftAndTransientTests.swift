import Testing
import Foundation
import Events
@testable import Sync

/// Pins the two copy-undo gaps closed in round 4:
///
/// 1. **Drift guard** — `registerCopyUndo` snapshots each copied item's identity at
///    registration; the undo REFUSES to trash a destination that is no longer that item —
///    replaced or edited since — matching the "still the same item?" guards the move- and
///    delete-undos already carry. A refused item stays out of the redo params.
///
///    The snapshot was a byte size when this suite was written, and these comments described
///    it that way. `f16aa66a` replaced it with `ItemIdentity`, which covers DIRECTORIES (own
///    modification date + immediate child count) as well as files, and compares a file's
///    modification date alongside its size. So "directories carry no snapshot" and "the drift
///    guard is files-only by design" — both written below — stopped being true then, and are
///    corrected here rather than left asserting the opposite of the code they document.
/// 2. **Transient trash failures** — a busy/locked destination (EBUSY et al.) is reported as
///    retryable instead of escalating to the permanent-delete prompt, the same
///    `isTransientTrashFailure` distinction `deleteItems` applies. `registerCreateFolderUndo`
///    gets the identical treatment.
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

    /// The copied file was replaced by a different-size item before the undo: the undo must
    /// refuse to trash it (warning banner), leave it on disk, keep its overwritten backup in
    /// the Trash, and keep it out of the redo params (redo is a no-op for it).
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
        // The drain is the whole gate, and a real one rather than the quiescence that cannot tell
        // "finished" from "not started": `registerCopyRedo`'s handler runs synchronously inside
        // `redo()` and pre-counts the operation before spawning its Task — unconditionally, even
        // with no params to act on — and `enqueueFileOperation` decrements only once its body has
        // returned. A flat 200ms used to follow this line and settled nothing the drain had not.
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

    /// The duplicate-registration guard must hold on the PERMANENT-delete path too: one path
    /// registered twice (the second copy replaced the first) on a Trash-less volume puts BOTH
    /// items into trashFailures. Without the guard there, item A's removeItem + backup restore
    /// was followed by item B's removeItem PERMANENTLY UNLINKING the just-restored pre-batch
    /// original — silent data loss with a clean log — and the confirmation prompt named the
    /// same file twice.
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
        // The pre-batch original survived its restore — item B must not have unlinked it.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5)
    }

    /// The duplicate gate must also recognize CASE-VARIANT registrations of one on-disk file
    /// (the destination volume folds case; the registered strings need not). After the first
    /// variant is handled, the second's exact string misses the set — and the vanished branch
    /// then restored ITS backup, resurrecting content the undo had just removed. The folded
    /// check is volume-gated: on a case-sensitive destination two variants are two real files
    /// and the exact behavior stands.
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

        // The user deletes the lowercase variant, then undoes. (The mock disk is exact-string,
        // so the two variants are separate keys; the REAL destination volume — which gates the
        // folded check — is the case-insensitive macOS default, where they name one file.)
        try mockFM.removeItem(at: URL(fileURLWithPath: "/dst/f.txt"))
        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The folded duplicate gate must swallow the second variant: no backup resurrection
        // at the vanished path.
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    // MARK: Vanished copies

    /// A copied DIRECTORY the user already deleted themselves must not raise the phantom
    /// permanent-delete prompt on ⌘Z. When this was written, directories carried no size
    /// snapshot at all, so the missing item fell through to `trashItem`, whose no-such-file
    /// error is NOT in the transient list — escalating to a "permanently delete?" confirmation
    /// naming an item that is not on disk. A directory now DOES carry an identity, so the
    /// missing copy would today reach the drift guard and refuse with a "changed" banner
    /// instead; the explicit `fileExists` branch ahead of the guard is what keeps this path a
    /// clean no-op either way, and that branch is what this test pins.
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

    /// The vanished-copy undo still restores the overwritten backup: the destination path is
    /// free, so the original the copy displaced belongs back — skipping it stranded the backup
    /// in the Trash forever.
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

    /// A transiently busy copy (EBUSY on trash) must NOT reach the permanent-delete prompt:
    /// the item stays on disk for a retry and a warning banner is raised.
    @MainActor
    @Test func copyUndoTransientTrashFailureNeverPromptsPermanentDelete() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

        // The permanent-delete prompt must never fire for a transient failure — even one that
        // would answer "yes". Installed BEFORE the copy so the undo registration captures it.
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
        // The copy survives on disk — not trashed, not permanently removed. (safeCopyItem's
        // .tmp_ staging cleanup shows up in attemptedRemovePaths; only the real file matters.)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(!mockFM.attemptedRemovePaths.contains("/dst/f.txt"))
        #expect(promptFired == false)
    }

    /// A genuinely Trash-less volume (ENOTSUP) still escalates to the confirmation, preserving
    /// the pre-existing permanent-delete fallback for real Trash-less volumes.
    @MainActor
    @Test func copyUndoNonTransientTrashFailureStillEscalates() async throws {
        let manager = makeManager() // confirmer declines
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
        // Declined permanent delete: the copy stays, exactly as before this change.
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    // MARK: Create-folder undo

    /// Undoing New Folder with a transiently busy folder must not offer the permanent-delete
    /// prompt either — the folder stays for a retry, with a warning banner.
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

    /// Control: a trash-less volume (ENOTSUP) still prompts, and a confirmed prompt removes the
    /// folder permanently — the pre-existing fallback.
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

    /// The gap this pair closes: when the CONFIRMED permanent delete then fails, the folder is
    /// still on disk after the user has agreed to destroy it — and `try?` swallowed that outcome
    /// entirely. No banner, no log line, nothing: the undo simply appeared to have worked. The
    /// copy-undo's twin of this branch has always reported through `reportUndoRemoveFailure`.
    @MainActor
    @Test func createFolderUndoReportsAConfirmedPermanentDeleteThatFailed() async throws {
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

        #expect(manager.banner?.message.contains("Undo couldn't remove") == true)
        #expect(manager.banner?.message.contains("New Folder") == true)
        // The folder is still there — which is exactly why silence was wrong.
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        await Logger.shared.debug("folder-undo flush marker").value
        #expect(Logger.shared.entries.contains {
            $0.level == .error && $0.message.contains("Undo (New Folder): FAILED to permanently delete")
        })
    }

    /// The other silent exit: the user DECLINES the permanent delete, so the folder stays. That is
    /// a legitimate outcome, but it left no trace at all — the log jumped from "User triggered
    /// Undo: New Folder" to nothing, reading as a completed undo.
    @MainActor
    @Test func createFolderUndoRecordsThatTheUserDeclinedThePermanentDelete() async throws {
        let manager = makeManager()   // confirmer declines
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)
        mockFM.shouldFailTrash = true

        manager.undoManager?.undo()
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        await Logger.shared.debug("folder-undo decline flush marker").value
        #expect(Logger.shared.entries.contains {
            $0.message.contains("Undo (New Folder)") && $0.message.contains("declined")
        })
    }
}
