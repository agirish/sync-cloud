import Testing
import Foundation
@testable import Sync

@Suite struct FileOperationsTests {
    
    @Test func testSafeMoveCrossVolumeFallback() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // This flag isn't natively in our mock yet, but we will add it to mockFM shortly to simulate ENXIO / EXDEV
        mockFM.shouldFailMove = true
        
        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")
        
        // This should trigger the fallback: copyItem -> removeItem
        try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        #expect(mockFM.calledCopyItem == true)
    }
    
    @MainActor
    @Test func testDeleteItemsTriggersPermanentRemovalOnTrashFailure() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // Simulate a network volume that doesn't support the trash bin
        mockFM.shouldFailTrash = true

        let targetURL = URL(fileURLWithPath: "/src/data.bin")

        let manager = FileSyncManager()
        // The trash failure asks for permanent-delete confirmation; the default confirmer
        // refuses, so mock the user confirming.
        manager.permanentDeleteConfirmer = { _ in true }
        await manager.deleteItems(at: [targetURL.path], fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        // Verify it didn't end up in the `.trashedPaths` mock stub array but was physically deleted instead
        #expect(mockFM.trashedPaths.isEmpty == true)
    }

    @MainActor
    @Test func testDeleteItemsTransientTrashFailureDoesNotEscalateToPermanentDelete() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // A transient failure (the file is momentarily busy — e.g. a cloud daemon mid-write), NOT a
        // Trash-less volume. It must not be silently upgraded to an unrecoverable permanent delete.
        mockFM.trashErrorOnce = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))

        let manager = FileSyncManager()
        var permanentDeleteOffered = false
        manager.permanentDeleteConfirmer = { _ in permanentDeleteOffered = true; return true }
        let removed = await manager.deleteItems(at: ["/src/data.bin"], fileManager: mockFM).removed

        #expect(removed == 0)                                // nothing was destroyed
        #expect(permanentDeleteOffered == false)             // no permanent-delete prompt
        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)  // still on disk — a retry could trash it
        #expect(manager.currentError != nil)                 // surfaced as a retryable error instead
    }

    @MainActor
    @Test func testMixedDeleteBatchStillShowsUndoBannerForWhatTrashed() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/b.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // The first trashItem call is transiently busy; the other succeeds.
        mockFM.trashErrorOnce = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))

        let manager = FileSyncManager()
        let removed = await manager.deleteItems(at: ["/src/a.bin", "/src/b.bin"], fileManager: mockFM).removed

        #expect(removed == 1)                                // one trashed, one transiently busy
        // The item that trashed still gets its undoable success banner despite the busy failure...
        #expect(manager.banner?.severity == .success)
        #expect(manager.banner?.isUndoable == true)
        // ...and the failure is still surfaced (not swallowed).
        #expect(manager.currentError != nil)
        // Exactly one file remains on disk.
        #expect(["/src/a.bin", "/src/b.bin"].filter { mockFM.virtualDisk[$0] != nil }.count == 1)
    }

    @MainActor
    @Test func testPrepareForcedRescanClearsCacheAndBumpsConfigEpoch() {
        let manager = FileSyncManager()
        manager.prefetchedTrees["/x"] = [FileNode(id: "/x", name: "x", isDirectory: true)]
        let before = manager.scanConfigGeneration

        manager.prepareForcedRescan()

        // Both are required: the cache clear alone leaves the RefreshKey identical, so a same-target
        // refresh in flight would dedupe the forced rescan away — the epoch bump makes it supersede.
        #expect(manager.prefetchedTrees.isEmpty)
        #expect(manager.scanConfigGeneration == before + 1)
    }

    @Test func testSafeCopyReplaceFallsBackWhenTrashUnsupported() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        mockFM.shouldFailTrash = true
        
        let overwritten = try FileSyncManager.safeCopyItem(
            at: URL(fileURLWithPath: "/src/new.txt"),
            to: URL(fileURLWithPath: "/dst/new.txt"),
            fileManager: mockFM
        )

        #expect(mockFM.virtualDisk["/src/new.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/new.txt"] != nil)
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/new.txt")
        #expect(attrs[.size] as? Int == 100)

        // The replaced file must stay recoverable even without a Trash: the hidden in-place
        // backup survives and is returned as the overwritten handle for undo.
        let backup = try #require(overwritten)
        #expect(backup.lastPathComponent.hasPrefix(".rollback_"))
        #expect(mockFM.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
    }
    
    @Test func testSafeMoveReplaceFallsBackWhenTrashUnsupported() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        mockFM.shouldFailTrash = true

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/new.txt"),
            to: URL(fileURLWithPath: "/dst/new.txt"),
            fileManager: mockFM
        )

        #expect(mockFM.virtualDisk["/src/new.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/new.txt"] != nil)

        // Same recoverability guarantee as the copy variant: the old file survives as a
        // hidden in-place backup and comes back as the overwritten handle.
        let backup = try #require(overwritten)
        #expect(backup.lastPathComponent.hasPrefix(".rollback_"))
        #expect(mockFM.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
    }

    @Test func testSafeMoveCrossVolumeCleanupFailureRollsBack() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.shouldFailMove = true
        mockFM.shouldFailTrash = true
        mockFM.failRemovePathsOnce = ["/src/data.bin"]

        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
        }

        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/dst/data.bin"] == nil)
    }
    
    @Test func testRecursivePathValidation() async throws {
        let parentDir = URL(fileURLWithPath: "/src/folder")
        let targetChildDir = URL(fileURLWithPath: "/src/folder/child")

        // You cannot move/copy `/src/folder` INTO `/src/folder/child`
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(source: parentDir, destination: targetChildDir)
        }

        try #expect(FileSyncManager.validateFileOperation(source: parentDir, destination: URL(fileURLWithPath: "/src/otherFolder")) == ())
    }

    /// On a case-insensitive volume (the macOS default), `/src/Folder` and `/src/folder` are the
    /// same directory: a case-variant destination must not slip past the nesting guard and
    /// trigger a recursive self-copy.
    @Test func testRecursivePathValidationIsCaseInsensitiveOnCaseInsensitiveVolumes() async throws {
        let parentDir = URL(fileURLWithPath: "/src/Folder")
        let caseVariantChild = URL(fileURLWithPath: "/src/folder/child")

        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(source: parentDir, destination: caseVariantChild, caseSensitiveVolume: false)
        }

        // On a case-sensitive volume those really are two distinct directories - allowed.
        try #expect(FileSyncManager.validateFileOperation(source: parentDir, destination: caseVariantChild, caseSensitiveVolume: true) == ())

        // A case-only rename ("folder" -> "Folder", no deeper nesting) stays legitimate on
        // case-insensitive volumes: neither identical nor a nesting violation.
        try #expect(FileSyncManager.validateFileOperation(
            source: URL(fileURLWithPath: "/src/folder"),
            destination: URL(fileURLWithPath: "/src/Folder"),
            caseSensitiveVolume: false
        ) == ())
    }

    /// **A symlink is not a container, so moving one INTO the directory it points at is legal.**
    ///
    /// The nesting guard resolved the source's last component, so a link source read as its
    /// target: `/base/alias` → `/base/realDir/sub` was checked as though the user had asked to move
    /// `/base/realDir` into itself, and an ordinary move of one directory entry was refused with
    /// `nestingViolation`. Moving the link creates no cycle — nothing traverses it.
    ///
    /// The identity check above still follows the link, deliberately, and
    /// `testRecursivePathValidationResolvesSymlinks` pins that: an alias and its target ARE one
    /// item, and moving the alias onto it would replace the real directory with a link to itself.
    /// The two checks ask different questions and take different paths for the source.
    @Test func testMovingASymlinkIntoTheDirectoryItPointsAtIsAllowed() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ValidateLinkMove-\(UUID().uuidString)")
        let realDir = base.appendingPathComponent("realDir")
        let linkURL = base.appendingPathComponent("alias")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: base) }

        // The link, into the directory it points at.
        try #expect(FileSyncManager.validateFileOperation(
            source: linkURL, destination: realDir.appendingPathComponent("sub")) == ())

        // And somewhere unrelated, which was never in doubt but keeps this from passing because
        // validation stopped refusing anything at all.
        try #expect(FileSyncManager.validateFileOperation(
            source: linkURL, destination: base.appendingPathComponent("moved")) == ())

        // The real directory into itself is still refused — the guard this narrows, not removes.
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(
                source: realDir, destination: realDir.appendingPathComponent("sub"))
        }
    }

    /// A destination reached through a symlink that points back inside the source must be
    /// rejected: before symlink resolution, `/tmp/.../link/sub` shares no prefix with the real
    /// source directory, so the guard passed and the copy recursed into itself.
    @Test func testRecursivePathValidationResolvesSymlinks() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ValidateSymlink-\(UUID().uuidString)")
        let realDir = base.appendingPathComponent("realDir")
        let linkURL = base.appendingPathComponent("alias")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: base) }

        // Moving realDir into itself via the alias: alias/sub resolves to realDir/sub.
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(source: realDir, destination: linkURL.appendingPathComponent("sub"))
        }

        // The alias and its target are the same item once resolved.
        #expect(throws: FileSyncManager.FileOperationError.identicalSourceAndDestination) {
            try FileSyncManager.validateFileOperation(source: linkURL, destination: realDir)
        }

        // A sibling destination behind the same symlinked base stays allowed.
        try #expect(FileSyncManager.validateFileOperation(source: realDir, destination: base.appendingPathComponent("elsewhere")) == ())
    }
    
    @MainActor
    @Test func testRenameFileCollision() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/fileA.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/fileB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Rename A to B, causing a collision
        await manager.renameItem(at: "/src/fileA.txt", to: "fileB.txt", fileManager: mockFM)
        
        let errStr = manager.currentError?.message ?? ""
        // Ensure error was set since fileB exists and wasn't case only rename
        #expect(errStr.contains("already exists"))
        
        // Both files should still exist intact
        #expect(mockFM.virtualDisk["/src/fileA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/fileB.txt"] != nil)
    }
    
    @MainActor
    @Test func testCreateFolder() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        await manager.createFolder(named: "New Folder", in: "/src", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/New Folder"] != nil)
        #expect(manager.undoManager?.canUndo == true)
        
        manager.undoManager?.undo()
        // The undo handler removes the folder from inside `Task { await enqueueFileOperation … }`,
        // so it lands at a time the test cannot predict. A fixed 100ms window was ample on an idle
        // machine and short of it under full-suite load on the self-hosted runner, which failed
        // this assertion on a commit that passed on a re-run of the same SHA (v2.x run
        // 30823146574, 2026-08-03). Waiting on the effect makes a genuinely slow undo fail late
        // rather than fail wrongly, and `waitUntil` records the timeout itself — the removal is
        // never asserted only by a wait whose result went unread.
        await waitUntil("undo removes the created folder") {
            mockFM.virtualDisk["/src/New Folder"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
    }
    
    /// An empty parent path means the pane's provider vanished from settings while its stale
    /// tree was still showing. `URL(fileURLWithPath: "")` resolves against the process CWD, so
    /// without a guard New Folder would create `<CWD>/<name>` — nothing may be created and the
    /// destination-unavailable error must be presented instead.
    @MainActor
    @Test func testCreateFolderWithEmptyPathCreatesNothingAndPresentsError() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        await manager.createFolder(named: "New Folder", in: "", fileManager: mockFM)

        #expect(mockFM.virtualDisk.isEmpty)
        #expect(manager.currentError?.title == "Couldn't Create Folder")
        #expect(manager.currentError?.reason?.contains("no longer available") == true)
    }

    /// A parent that vanished from disk (provider unmounted or removed) must fail the same way,
    /// not be silently recreated as a dead local tree or surface a raw file-system error.
    @MainActor
    @Test func testCreateFolderWithVanishedParentCreatesNothingAndPresentsError() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        await manager.createFolder(named: "New Folder", in: "/gone", fileManager: mockFM)

        #expect(mockFM.virtualDisk.isEmpty)
        #expect(manager.currentError?.title == "Couldn't Create Folder")
        #expect(manager.currentError?.reason?.contains("no longer available") == true)
    }

    @MainActor
    @Test func testMoveFiles() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/f1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/f2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let node1 = FileNode(id: "/src/f1.txt", name: "f1.txt", isDirectory: false)
        let node2 = FileNode(id: "/src/f2.txt", name: "f2.txt", isDirectory: false)
        
        await manager.moveItems(nodes: [node1, node2], toPath: "/dst", fileManager: mockFM)
        
        // Assert moved to dest
        #expect(mockFM.virtualDisk["/dst/f1.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/f2.txt"] != nil)
        
        // Assert removed from src
        #expect(mockFM.virtualDisk["/src/f1.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/f2.txt"] == nil)
    }
    
    /// The toPath variants must tilde-expand once and use the expanded value for BOTH the
    /// root-existence guard and the per-item targets (like paneTargetURL). Deriving targets
    /// from the raw "~/…" string relied on URL(fileURLWithPath:)'s expansion behavior, which
    /// is Foundation-version dependent — on runtimes that don't expand, items landed at
    /// "<cwd>/~/…" while the guard (which stats the expanded path) passed, and a move also
    /// removed the sources.
    @MainActor
    @Test func testCopyAndMoveToTildePathExpandBeforeDerivingTargets() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        let home = NSHomeDirectory()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: home + "/dst-tilde"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/copied.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/moved.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.copyItems(
            nodes: [FileNode(id: "/src/copied.txt", name: "copied.txt", isDirectory: false)],
            toPath: "~/dst-tilde",
            fileManager: mockFM
        )
        await manager.moveItems(
            nodes: [FileNode(id: "/src/moved.txt", name: "moved.txt", isDirectory: false)],
            toPath: "~/dst-tilde",
            fileManager: mockFM
        )

        #expect(manager.currentError == nil)
        #expect(mockFM.virtualDisk[home + "/dst-tilde/copied.txt"] != nil)
        #expect(mockFM.virtualDisk[home + "/dst-tilde/moved.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/copied.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/moved.txt"] == nil)
        // Nothing may land under a literal "~" directory (CWD-relative).
        #expect(mockFM.virtualDisk.keys.contains { $0.contains("~") } == false)
    }

    @MainActor
    @Test func testMoveCrossPane() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/cross.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/cross.txt", name: "cross.txt", isDirectory: false)
        
        // Move from source pane to destination pane
        await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Assert moved to dest
        #expect(mockFM.virtualDisk["/dst/cross.txt"] != nil)
        
        // Assert removed from src
        #expect(mockFM.virtualDisk["/src/cross.txt"] == nil)
    }
    
    @MainActor
    @Test func testMoveCrossPaneFromDestination() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/dst/cross2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/dst/cross2.txt", name: "cross2.txt", isDirectory: false)
        
        // Move from destination pane to source pane
        await manager.moveItems(nodes: [node], fromLeft: false, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Assert moved to src
        #expect(mockFM.virtualDisk["/src/cross2.txt"] != nil)
        
        // Assert removed from dst
        #expect(mockFM.virtualDisk["/dst/cross2.txt"] == nil)
    }
    
    @MainActor
    @Test func testMoveDirectoryWithChildren() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        // Mock a deep nested directory structure in source
        mockFM.virtualDisk["/src"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["deep_folder"])
        mockFM.virtualDisk["/src/deep_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["child_folder", "doc.txt"])
        mockFM.virtualDisk["/src/deep_folder/child_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["data.bin"])
        mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/deep_folder/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let folderNode = FileNode(id: "/src/deep_folder", name: "deep_folder", isDirectory: true)
        
        // User moves the entire deep_folder to /dst
        await manager.moveItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        
        // Validate /dst contains the tree
        #expect(mockFM.virtualDisk["/dst/deep_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/doc.txt"] != nil)
        
        // Validate original tree is removed
        #expect(mockFM.virtualDisk["/src/deep_folder"] == nil)
        #expect(mockFM.virtualDisk["/src/deep_folder/child_folder"] == nil)
        #expect(mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] == nil)
    }
    
    @MainActor
    @Test func testCopyDirectoryWithChildren() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        // Form deep hierarchy in Source
        mockFM.virtualDisk["/src"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["copy_folder"])
        mockFM.virtualDisk["/src/copy_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["sub"])
        mockFM.virtualDisk["/src/copy_folder/sub"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["item.png"])
        mockFM.virtualDisk["/src/copy_folder/sub/item.png"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let folderNode = FileNode(id: "/src/copy_folder", name: "copy_folder", isDirectory: true)
        await manager.copyItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        
        // Target should exist
        #expect(mockFM.virtualDisk["/dst/copy_folder/sub/item.png"] != nil)
        
        // Source should STILL exist
        #expect(mockFM.virtualDisk["/src/copy_folder/sub/item.png"] != nil)
    }
    
    @MainActor
    @Test func testRenameDirectory() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        mockFM.virtualDisk["/src/media"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["movies"])
        mockFM.virtualDisk["/src/media/movies"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["vid.mp4"])
        mockFM.virtualDisk["/src/media/movies/vid.mp4"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Rename "media" directory to "Entertainment"
        await manager.renameItem(at: "/src/media", to: "Entertainment", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/Entertainment"] != nil)
        #expect(mockFM.virtualDisk["/src/Entertainment/movies/vid.mp4"] != nil)
        
        #expect(mockFM.virtualDisk["/src/media"] == nil)
    }
    
    @MainActor
    @Test func testRenameCaseOnly() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/Notes.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Case-only rename: Notes.txt -> notes.txt
        await manager.renameItem(at: "/src/Notes.txt", to: "notes.txt", fileManager: mockFM)
        
        // Verify current error is nil (meaning no collision error occurred)
        #expect(manager.currentError == nil)
        
        // Verify the file was physically relinked in RAM dictionary to notes.txt
        #expect(mockFM.virtualDisk["/src/notes.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/Notes.txt"] == nil)
    }

    /// On a case-SENSITIVE volume "foo" and "Foo" are distinct files, so renaming onto the
    /// case variant is a collision like any other: the rename must stop at the "already
    /// exists" alert instead of skipping the check as a case-only rename and then failing
    /// the plain move with a raw "file exists" error. (The mock's disk is case-sensitive.)
    @MainActor
    @Test func testRenameOntoCaseVariantCollidesOnCaseSensitiveVolume() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/foo"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Foo"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.renameItem(at: "/src/foo", to: "Foo", fileManager: mockFM, caseSensitiveVolume: true)

        #expect(manager.currentError?.message.contains("already exists") == true)
        #expect(mockFM.virtualDisk["/src/foo"] != nil)
        #expect(mockFM.virtualDisk["/src/Foo"] != nil)
    }

    /// A case-only rename with NO case-variant sibling stays a plain rename on a
    /// case-sensitive volume — no collision alert, no backup.
    @MainActor
    @Test func testRenameCaseOnlySucceedsOnCaseSensitiveVolumeWithoutCollision() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/foo"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.renameItem(at: "/src/foo", to: "Foo", fileManager: mockFM, caseSensitiveVolume: true)

        #expect(manager.currentError == nil)
        #expect(mockFM.virtualDisk["/src/Foo"] != nil)
        #expect(mockFM.virtualDisk["/src/foo"] == nil)
    }

    /// The same distinction one layer down: safeMoveItem onto a case-variant destination on a
    /// case-sensitive volume is a REPLACEMENT (atomic swap with a recoverable backup), not a
    /// case-only rename excluded from the existence check — which used to end in a raw
    /// "file exists" throw from the plain move.
    @Test func testSafeMoveOntoCaseVariantReplacesOnCaseSensitiveVolume() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/foo"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/Foo"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/foo"),
            to: URL(fileURLWithPath: "/src/Foo"),
            fileManager: mockFM,
            caseSensitiveVolume: true
        )

        #expect(mockFM.virtualDisk["/src/foo"] == nil)
        let attrs = try mockFM.attributesOfItem(atPath: "/src/Foo")
        #expect(attrs[.size] as? Int == 100)
        // The replaced case-variant stays recoverable, like any other replacement.
        #expect(overwritten != nil)
        #expect(mockFM.calledReplaceItem)
    }

    @MainActor
    @Test func testRecursiveConflictHandling() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        mockFM.virtualDisk["/src/folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["file1.txt"])
        mockFM.virtualDisk["/src/folder/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["folder"])
        mockFM.virtualDisk["/dst/folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["file2.txt"])
        mockFM.virtualDisk["/dst/folder/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let node = FileNode(id: "/src/folder", name: "folder", isDirectory: true)

        // /dst/folder already exists, so this hits the collision path. The resolver must be
        // mocked: the default one skips the item.
        manager.collisionResolver = { _ in .replace }
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        // Replace semantics: the old destination directory is backed up out of the way and the
        // source directory takes its place - file1 arrives, file2 (from the replaced dir) is gone.
        #expect(manager.currentError == nil)
        #expect(mockFM.virtualDisk["/dst/folder/file1.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/folder/file2.txt"] == nil)
    }

    /// The collision seam is told whether the colliding destination is a directory, so the
    /// app can warn that Replace trashes the whole folder. A folder collision reports
    /// isDirectory=true and a file collision reports false — and Replace still works either way.
    @MainActor
    @Test func testCollisionResolverReceivesIsDirectoryFlag() async throws {
        // Folder-vs-folder collision.
        let folderManager = FileSyncManager()
        let folderFM = MockFileManager()
        folderFM.virtualDisk["/src/item"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["a.txt"])
        folderFM.virtualDisk["/src/item/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        folderFM.virtualDisk["/dst"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["item"])
        folderFM.virtualDisk["/dst/item"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["b.txt"])
        folderFM.virtualDisk["/dst/item/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var folderSeenIsDirectory: Bool?
        folderManager.collisionResolver = { collision in
            folderSeenIsDirectory = collision.isDirectory
            return .replace
        }
        await folderManager.copyItems(
            nodes: [FileNode(id: "/src/item", name: "item", isDirectory: true)],
            toPath: "/dst",
            fileManager: folderFM
        )
        #expect(folderSeenIsDirectory == true)
        #expect(folderManager.currentError == nil)
        // Replace still happened: source contents arrive, dest-only file is gone.
        #expect(folderFM.virtualDisk["/dst/item/a.txt"] != nil)
        #expect(folderFM.virtualDisk["/dst/item/b.txt"] == nil)

        // File-vs-file collision reports isDirectory=false.
        let fileManager = FileSyncManager()
        let fileFM = MockFileManager()
        fileFM.virtualDisk["/src/item.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fileFM.virtualDisk["/dst"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["item.txt"])
        fileFM.virtualDisk["/dst/item.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var fileSeenIsDirectory: Bool?
        fileManager.collisionResolver = { collision in
            fileSeenIsDirectory = collision.isDirectory
            return .replace
        }
        await fileManager.copyItems(
            nodes: [FileNode(id: "/src/item.txt", name: "item.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: fileFM
        )
        #expect(fileSeenIsDirectory == false)
        #expect(fileManager.currentError == nil)
    }

    // MARK: - Safe Move & Copy Rollback Logic
    
    @Test func testSafeCopyItemRollbackOnError() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil) // Already exists, forces a replacement
        
        let srcURL = URL(fileURLWithPath: "/src/doc.txt")
        let dstURL = URL(fileURLWithPath: "/dst/doc.txt")
        
        // Setup mock to fail during the critical `.tmp_` rename phase
        mockFM.shouldFailMoveOnTempRename = true
        
        do {
            try FileSyncManager.safeCopyItem(at: srcURL, to: dstURL, fileManager: mockFM)
            Issue.record("Expected safeCopyItem to throw due to simulation failure")
        } catch {
            // Expected
        }
        
        // Core verification: The original destination file MUST have been restored from trash
        #expect(mockFM.virtualDisk["/dst/doc.txt"] != nil)
        
        // Also ensure source is untouched (since it was a copy)
        #expect(mockFM.virtualDisk["/src/doc.txt"] != nil)
        
        // Ensure our temp file cleanup deferred block ran correctly by inspecting disk
        let tmpExists = mockFM.virtualDisk.keys.contains { $0.contains(".tmp_") }
        #expect(tmpExists == false)
    }
    
    @Test func testSafeMoveItemRollbackOnError() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil) // Target exists
        
        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")
        
        // 1. Force initial moveItem to fail to trigger EXDEV fallback
        mockFM.shouldFailMove = true
        
        // 2. Force the fallback temp copy to fail during the final rename
        mockFM.shouldFailMoveOnTempRename = true
        
        do {
            try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
            Issue.record("Expected safeMoveItem to throw")
        } catch {
            // Expected
        }
        
        // Rollback check: Dest should be restored securely
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
        
        // Source should still exist safely because it failed before we trashed the source
        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)
    }
    
    /// TOCTOU: a file that appears at the destination after the backup existence check (cloud
    /// placeholder hydration, another sync client, a parallel bulk worker) makes the final
    /// move throw "file exists". With no backup taken, rollback has nothing to restore and
    /// must not delete the newly-appeared file.
    @Test func testSafeCopyPreservesDestinationThatAppearedAfterBackupCheck() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        // Destination is absent when the backup step stats it; plant it immediately after
        // that check so the final moveItem(temp -> destination) hits "file exists".
        mockFM.onFileExists = { path in
            guard path == "/dst/doc.txt" else { return }
            mockFM.onFileExists = nil
            mockFM.virtualDisk["/dst/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        }

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeCopyItem(
                at: URL(fileURLWithPath: "/src/doc.txt"),
                to: URL(fileURLWithPath: "/dst/doc.txt"),
                fileManager: mockFM
            )
        }

        // The appeared file survives untouched - it was never backed up, so it must not be removed.
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/doc.txt")
        #expect(attrs[.size] as? Int == 5)
        #expect(mockFM.virtualDisk["/src/doc.txt"] != nil)
        #expect(mockFM.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    /// Same race through safeMoveItem: the direct move throws "file exists", the same-volume
    /// fallback's final move throws again, and rollback (backup == nil) must leave both the
    /// appeared destination file and the source intact.
    @Test func testSafeMovePreservesDestinationThatAppearedAfterBackupCheck() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.onFileExists = { path in
            guard path == "/dst/data.bin" else { return }
            mockFM.onFileExists = nil
            mockFM.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        }

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/src/data.bin"),
                to: URL(fileURLWithPath: "/dst/data.bin"),
                fileManager: mockFM
            )
        }

        let attrs = try mockFM.attributesOfItem(atPath: "/dst/data.bin")
        #expect(attrs[.size] as? Int == 5)
        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)
        #expect(mockFM.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    /// Case-only rename ("foo" -> "Foo") never takes a backup. If the direct rename fails
    /// (SMB/FUSE volumes) and the copy-to-temp fallback's final move also fails - on a
    /// case-insensitive volume "Foo" IS the source "foo" - rollback must not removeItem the
    /// destination: that path resolves to the source, the only remaining copy of the data.
    @Test func testCaseOnlyRenameFallbackFailureNeverRemovesDestination() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/foo"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.shouldFailMove = true            // direct case-only rename fails
        mockFM.shouldFailMoveOnTempRename = true // fallback's final move fails too

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/src/foo"),
                to: URL(fileURLWithPath: "/src/Foo"),
                fileManager: mockFM
            )
        }

        // Source survives, and - the real pin, since the mock disk is case-sensitive - no
        // removal was ever attempted at the destination path (only the temp copy's cleanup).
        #expect(mockFM.virtualDisk["/src/foo"] != nil)
        #expect(mockFM.attemptedRemovePaths.contains("/src/Foo") == false)
        #expect(mockFM.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    @Test func testSafeMoveNonExistentSource() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let srcURL = URL(fileURLWithPath: "/src/phantom.txt")
        let dstURL = URL(fileURLWithPath: "/dst/phantom.txt")
        
        do {
            try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
            Issue.record("Expected to throw NSFileReadNoSuchFileError")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSCocoaErrorDomain)
            #expect(nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
        }
    }
}
