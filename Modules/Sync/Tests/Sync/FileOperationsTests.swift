import Testing
import Foundation
@testable import Sync

@Suite struct FileOperationsTests {

    @Test func testSafeMoveCrossVolumeFallback() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // Fail the plain rename, as across volumes (EXDEV)
        mockFM.shouldFailMove = true

        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")

        // The fallback: copyItem, then removeItem.
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

        // A network volume with no Trash.
        mockFM.shouldFailTrash = true

        let targetURL = URL(fileURLWithPath: "/src/data.bin")

        let manager = FileSyncManager()
        // The trash failure asks for permanent-delete confirmation; the default confirmer
        // refuses, so mock the user confirming.
        manager.permanentDeleteConfirmer = { _ in true }
        await manager.deleteItems(at: [targetURL.path], fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        // Deleted outright, not trashed.
        #expect(mockFM.trashedPaths.isEmpty == true)
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
        // The trashed item still gets its undoable success banner...
        #expect(manager.banner?.severity == .success)
        #expect(manager.banner?.isUndoable == true)
        // ...and the failure is still surfaced (not swallowed).
        #expect(manager.currentError != nil)
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

    @Test(arguments: [false, true])
    func testSafeReplaceFallsBackWhenTrashUnsupported(isMove: Bool) async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/new.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 5], contents: nil)
        mockFM.shouldFailTrash = true

        let src = URL(fileURLWithPath: "/src/new.txt"), dst = URL(fileURLWithPath: "/dst/new.txt")
        let overwritten = isMove
            ? try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: mockFM)
            : try FileSyncManager.safeCopyItem(at: src, to: dst, fileManager: mockFM)

        #expect((mockFM.virtualDisk["/src/new.txt"] != nil) == !isMove)
        #expect(mockFM.virtualDisk["/dst/new.txt"] != nil)
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/new.txt")
        #expect(attrs[.size] as? Int == 100)

        // The replaced file must stay recoverable even without a Trash: the hidden in-place
        // backup survives and is returned as the overwritten handle for undo.
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

    /// Replacing a link that points at the source's folder replaces the link, not the folder it
    /// leads to, so it isn't "a folder the source sits in" and isn't refused. The real folder in the
    /// same place still is.
    @Test func aLinkToTheSourcesFolderCanBeReplaced() throws {
        let base = try makeCanonicalTempRoot(prefix: "p5")
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("T/Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let source = photos.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)
        let link = base.appendingPathComponent("Elsewhere/Photos")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photos)

        try FileSyncManager.validateFileOperation(source: source, destination: link, caseSensitiveVolume: false)
        #expect(throws: FileSyncManager.FileOperationError.destinationContainsSource) {
            try FileSyncManager.validateFileOperation(source: source, destination: photos, caseSensitiveVolume: false)
        }
    }

    /// The Replace the test above lets through works, copy and move alike: `T/Photos/Photos`
    /// (through the link) replaces the link `T/Photos`. The link goes to the Trash and the folder
    /// it led to keeps everything else. `replaceItemAt` can't replace a link ("doesn’t exist").
    @Test(arguments: [false, true])
    func aLinkToTheSourcesFolderIsReplacedOnDisk(isMove: Bool) throws {
        let base = try makeCanonicalTempRoot(prefix: "b1-\(isMove ? "move" : "copy")")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = base.appendingPathComponent("Elsewhere/Photos")
        try fm.createDirectory(at: real.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: real.appendingPathComponent("Photos/inner.txt"))
        try Data("outer".utf8).write(to: real.appendingPathComponent("outer.txt"))
        let link = base.appendingPathComponent("T/Photos")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let source = link.appendingPathComponent("Photos")
        let trash = ScratchTrash(in: base)

        let replaced = isMove
            ? try FileSyncManager.safeMoveItem(at: source, to: link, fileManager: trash, caseSensitiveVolume: false)
            : try FileSyncManager.safeCopyItem(at: source, to: link, fileManager: trash, caseSensitiveVolume: false)

        let kind = try fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(kind == .typeDirectory, "T/Photos is still the link")
        #expect((try? String(contentsOf: link.appendingPathComponent("inner.txt"), encoding: .utf8)) == "inner")
        #expect((try? String(contentsOf: real.appendingPathComponent("outer.txt"), encoding: .utf8)) == "outer",
                "the folder the link led to lost what else it held")
        #expect(fm.fileExists(atPath: real.appendingPathComponent("Photos").path) == !isMove)
        let backup = try #require(replaced, "the replaced link is not recoverable")
        #expect((try? fm.destinationOfSymbolicLink(atPath: backup.path)) == real.path, "the backup is not the link")
        #expect(backup.path.hasPrefix(trash.folder.path))
    }

    /// Pasting `/T/Photos/Photos` into `/T` targets `/T/Photos`, the source's own parent: Replace
    /// would swap the inner folder in and trash the outer one with everything else it holds.
    /// Validation refuses that shape, on either case spelling, and nothing else.
    @Test func aFolderCannotReplaceTheFolderItSitsIn() throws {
        let inner = URL(fileURLWithPath: "/T/Photos/Photos")
        #expect(throws: FileSyncManager.FileOperationError.destinationContainsSource) {
            try FileSyncManager.validateFileOperation(source: inner, destination: URL(fileURLWithPath: "/T/Photos"),
                                                      caseSensitiveVolume: true)
        }
        #expect(throws: FileSyncManager.FileOperationError.destinationContainsSource) {
            try FileSyncManager.validateFileOperation(source: inner, destination: URL(fileURLWithPath: "/T/photos"),
                                                      caseSensitiveVolume: false)
        }
        // A Merge moves only the children, so flattening into the parent stays allowed.
        try FileSyncManager.validateFileOperation(source: inner, destination: URL(fileURLWithPath: "/T/Photos"),
                                                  caseSensitiveVolume: true, merging: true)
        // A sibling that merely starts the same way is not a parent.
        try FileSyncManager.validateFileOperation(source: URL(fileURLWithPath: "/T/Photos2/Photos"),
                                                  destination: URL(fileURLWithPath: "/T/Photos"),
                                                  caseSensitiveVolume: true)
    }

    /// The same shape through a paste's move, Replace answered: the outer folder stays put. Real
    /// disk, because the mock's flat paths leave a moved folder's children listed, so the test
    /// would pass without the guard. The Trash is refused, keeping a regression out of the real one.
    @MainActor
    @Test func replacingTheSourcesOwnParentLeavesItAlone() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fr30-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let inner = base.appendingPathComponent("Photos/Photos")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: base.appendingPathComponent("Photos/other.txt"))
        try Data("inner".utf8).write(to: inner.appendingPathComponent("inner.txt"))
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }
        let node = FileNode(id: inner.path, name: "Photos", isDirectory: true, children: [])

        _ = await manager.moveItems(nodes: [node], toPath: base.path, fileManager: TrashRefusingFileManager())

        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Photos/other.txt").path),
                "the outer folder's other files were replaced away")
        #expect(FileManager.default.fileExists(atPath: inner.appendingPathComponent("inner.txt").path))
    }

    /// The Merge answer to the same paste is how a doubled `Photos/Photos` is flattened, and it
    /// still works: the inner folder's files land in the outer one beside what was already there.
    @MainActor
    @Test func mergingAFolderIntoItsParentStillFlattensIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fr30m-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let inner = base.appendingPathComponent("Photos/Photos")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: base.appendingPathComponent("Photos/other.txt"))
        try Data("inner".utf8).write(to: inner.appendingPathComponent("inner.txt"))
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .merge }
        manager.permanentDeleteConfirmer = { _ in false }
        let node = FileNode(id: inner.path, name: "Photos", isDirectory: true, children: [])

        _ = await manager.moveItems(nodes: [node], toPath: base.path, fileManager: TrashRefusingFileManager())

        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Photos/inner.txt").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Photos/other.txt").path))
        #expect(manager.currentError == nil, "\(manager.currentError?.reason ?? "")")
    }

    /// Moving `/A/f.txt` and `/B/f.txt` into `/D` with Replace lands two items on one name. ⌘Z must
    /// put each file back where it came from, not B's content in `/A` and nothing in `/B`.
    @MainActor
    @Test func undoingAMoveThatLandedTwiceOnOneNamePutsEachFileHome() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fr23-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for dir in ["A", "B", "D"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let a = base.appendingPathComponent("A/f.txt"), b = base.appendingPathComponent("B/f.txt")
        try Data("from A".utf8).write(to: a)
        try Data("from B".utf8).write(to: b)
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }
        let fm = TrashRefusingFileManager()
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f.txt", isDirectory: false, fileSize: 6) }

        _ = await manager.moveItems(nodes: nodes, toPath: base.appendingPathComponent("D").path, fileManager: fm)
        try #require(String(decoding: try Data(contentsOf: base.appendingPathComponent("D/f.txt")), as: UTF8.self) == "from B",
                     "the premise: the second move replaced the first")

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }

        #expect((try? String(decoding: Data(contentsOf: a), as: UTF8.self)) == "from A")
        #expect((try? String(decoding: Data(contentsOf: b), as: UTF8.self)) == "from B")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("D/f.txt").path))
    }

    @Test func testRecursivePathValidation() async throws {
        let parentDir = URL(fileURLWithPath: "/src/folder")
        let targetChildDir = URL(fileURLWithPath: "/src/folder/child")

        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(source: parentDir, destination: targetChildDir)
        }

        try #expect(FileSyncManager.validateFileOperation(source: parentDir, destination: URL(fileURLWithPath: "/src/otherFolder")) == ())
    }

    /// A source whose parent is the volume root. The nesting guard builds the source prefix from
    /// the resolved parent plus the leaf (so a symlinked leaf isn't followed). At the root the
    /// parent is already `"/"`, and a naive join spells `//Users`, which matches no destination, so
    /// a folder could be moved into itself. Only this depth can double the separator.
    @Test func testRecursivePathValidationHoldsForASourceAtTheVolumeRoot() async throws {
        let atRoot = URL(fileURLWithPath: "/Users")

        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(
                source: atRoot, destination: URL(fileURLWithPath: "/Users/child"),
                caseSensitiveVolume: true)
        }
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(
                source: atRoot, destination: URL(fileURLWithPath: "/users/child"),
                caseSensitiveVolume: false)
        }
        // A sibling at the same depth stays legal: the root is not a blanket refusal.
        try #expect(FileSyncManager.validateFileOperation(
            source: atRoot, destination: URL(fileURLWithPath: "/Elsewhere/child"),
            caseSensitiveVolume: true) == ())
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

    /// A symlink is not a container, so moving one into the directory it points at makes no cycle.
    /// The nesting guard must not resolve the source's last component, or `/base/alias` →
    /// `/base/realDir/sub` reads as moving `realDir` into itself. The identity check does follow
    /// the link: moving an alias onto its target would replace the directory with a link to itself.
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

        // And somewhere unrelated, as a plain control.
        try #expect(FileSyncManager.validateFileOperation(
            source: linkURL, destination: base.appendingPathComponent("moved")) == ())

        // The real directory into itself is still refused — the guard this narrows, not removes.
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(
                source: realDir, destination: realDir.appendingPathComponent("sub"))
        }
    }

    /// A destination reached through a symlink back inside the source must be rejected: unresolved,
    /// `/tmp/.../link/sub` shares no prefix with the real source, and the copy would recurse into
    /// itself.
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

        await manager.renameItem(at: "/src/fileA.txt", to: "fileB.txt", fileManager: mockFM)

        let errStr = manager.currentError?.message ?? ""
        #expect(errStr.contains("already exists"))

        // Both files survive.
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
        // The undo removes the folder inside `Task { await enqueueFileOperation … }`, at a time the
        // test can't predict, so wait on the effect: a fixed window runs short under full-suite
        // load. `waitUntil` records its own timeout, so the removal is still asserted.
        await waitUntil("undo removes the created folder") {
            mockFM.virtualDisk["/src/New Folder"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
    }

    /// An empty parent path (the pane's provider left settings while its stale tree showed)
    /// resolves against the process CWD, so New Folder would create `<CWD>/<name>`. A parent gone
    /// from disk (`/gone`) must not be recreated as a dead local tree. Both create nothing and
    /// present the destination-unavailable error.
    @MainActor
    @Test(arguments: ["", "/gone"])
    func testCreateFolderWithNoParentCreatesNothingAndPresentsError(parent: String) async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        await manager.createFolder(named: "New Folder", in: parent, fileManager: mockFM)

        #expect(mockFM.virtualDisk.isEmpty)
        #expect(manager.currentError?.title == "Couldn’t Create Folder")
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

        #expect(mockFM.virtualDisk["/dst/f1.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/f2.txt"] != nil)

        #expect(mockFM.virtualDisk["/src/f1.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/f2.txt"] == nil)
    }

    /// The toPath variants tilde-expand once, for both the root-existence guard and the per-item
    /// targets. Whether URL(fileURLWithPath:) expands "~" depends on the Foundation version; where
    /// it doesn't, items would land at "<cwd>/~/…" while the guard passed, and a move would also
    /// remove the sources.
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
    @Test(arguments: [true, false])
    func testMoveCrossPane(fromLeft: Bool) async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        let (from, to) = fromLeft ? ("/src", "/dst") : ("/dst", "/src")

        mockFM.virtualDisk["\(from)/cross.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "\(from)/cross.txt", name: "cross.txt", isDirectory: false)

        await manager.moveItems(nodes: [node], fromLeft: fromLeft, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(mockFM.virtualDisk["\(to)/cross.txt"] != nil)
        #expect(mockFM.virtualDisk["\(from)/cross.txt"] == nil)
    }

    @MainActor
    @Test(arguments: [false, true])
    func testTransferDirectoryWithChildren(isMove: Bool) async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        mockFM.virtualDisk["/src"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["deep_folder"])
        mockFM.virtualDisk["/src/deep_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["child_folder", "doc.txt"])
        mockFM.virtualDisk["/src/deep_folder/child_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["data.bin"])
        mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/deep_folder/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let folderNode = FileNode(id: "/src/deep_folder", name: "deep_folder", isDirectory: true)

        if isMove {
            await manager.moveItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        } else {
            await manager.copyItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        }

        #expect(mockFM.virtualDisk["/dst/deep_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/doc.txt"] != nil)

        // A move removes the original tree; a copy leaves it
        #expect((mockFM.virtualDisk["/src/deep_folder"] != nil) == !isMove)
        #expect((mockFM.virtualDisk["/src/deep_folder/child_folder"] != nil) == !isMove)
        #expect((mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] != nil) == !isMove)
    }

    @MainActor
    @Test func testRenameDirectory() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        mockFM.virtualDisk["/src/media"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["movies"])
        mockFM.virtualDisk["/src/media/movies"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["vid.mp4"])
        mockFM.virtualDisk["/src/media/movies/vid.mp4"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

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

        // Case-only: Notes.txt -> notes.txt is no collision.
        await manager.renameItem(at: "/src/Notes.txt", to: "notes.txt", fileManager: mockFM)

        #expect(manager.currentError == nil)

        #expect(mockFM.virtualDisk["/src/notes.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/Notes.txt"] == nil)
    }

    /// On a case-SENSITIVE volume (as the mock's disk is) "foo" and "Foo" are distinct files, so
    /// renaming onto the variant must stop at the "already exists" alert, not skip the check as a
    /// case-only rename and fail the move with a raw "file exists" error.
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
    /// case-sensitive volume is a replacement (atomic swap with a recoverable backup), not a
    /// case-only rename skipping the existence check, which would end in a raw "file exists" throw.
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

        // Fail the final `.tmp_` rename.
        mockFM.shouldFailMoveOnTempRename = true

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeCopyItem(at: srcURL, to: dstURL, fileManager: mockFM)
        }

        // The original destination must be restored from the Trash.
        #expect(mockFM.virtualDisk["/dst/doc.txt"] != nil)

        // A copy leaves the source untouched.
        #expect(mockFM.virtualDisk["/src/doc.txt"] != nil)

        // The temp file is cleaned up.
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

        // Fail the direct move (the EXDEV fallback), then the fallback's final rename.
        mockFM.shouldFailMove = true
        mockFM.shouldFailMoveOnTempRename = true

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
        }

        // The destination is restored, and the source survives: the failure came before it was
        // trashed.
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)
    }

    /// TOCTOU: a file that appears at the destination after the backup existence check (placeholder
    /// hydration, another sync client, a parallel bulk worker) makes the final move throw "file
    /// exists". With no backup taken, rollback has nothing to restore and must not delete the newly
    /// appeared file; both it and the source stay intact, through safeMoveItem's fallback too.
    @Test(arguments: [false, true])
    func testSafeTransferPreservesDestinationThatAppearedAfterBackupCheck(isMove: Bool) async throws {
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

        let src = URL(fileURLWithPath: "/src/doc.txt"), dst = URL(fileURLWithPath: "/dst/doc.txt")
        #expect(throws: (any Error).self) {
            if isMove {
                try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: mockFM)
            } else {
                try FileSyncManager.safeCopyItem(at: src, to: dst, fileManager: mockFM)
            }
        }

        // The appeared file survives untouched - it was never backed up, so it must not be removed.
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/doc.txt")
        #expect(attrs[.size] as? Int == 5)
        #expect(mockFM.virtualDisk["/src/doc.txt"] != nil)
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

/// The real disk, with the Trash refused — what a volume without one answers.
private final class TrashRefusingFileManager: ForwardingFileManaging<FileManager>, @unchecked Sendable {
    init() { super.init(inner: .default) }
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw CocoaError(.featureUnsupported)
    }
}
