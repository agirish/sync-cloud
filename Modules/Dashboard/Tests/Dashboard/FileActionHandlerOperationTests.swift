import Testing
import AppKit
import Foundation
import os
@testable import Sync
import Settings
@testable import Dashboard

/// Coverage for FileActionHandler's real operations (clipboard and paste routes, pane-to-pane
/// moves, delete, rename, new folder) through the constructor-injected seams: prompts and
/// delete confirmation. File I/O runs in real temp directories. Waits poll for
/// the effect on disk or on the manager, because the operation counter's 0 means both "not
/// started" and "finished" under a contended main actor.
@Suite struct FileActionHandlerOperationTests {

    // MARK: - Fixtures

    /// A fresh temp directory, removed by the caller's `defer`.
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FAH-ops-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One temp root holding two empty folders, removed by the caller's single `defer`.
    private func makeTempPair(_ label: String) throws -> (root: URL, src: URL, dst: URL) {
        let root = try makeTempDir(label)
        let (src, dst) = (root.appendingPathComponent("src"), root.appendingPathComponent("dst"))
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
        return (root, src, dst)
    }

    @discardableResult
    private func makeFile(in dir: URL, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    /// Waits for the manager's file-operation bookkeeping to drain. **Not a wait on its own:**
    /// `activeFileOperationsCount == 0` also holds before the operation starts (`docs/flaky-tests.md`,
    /// "Fixed pumps and fixed sleeps"), so every caller first waits for the outcome on disk.
    /// The trailing sleep is a fixed pump: the banner publishes a turn after the count drops, so
    /// without it a banner assertion can see `nil`.
    @MainActor
    private func waitForOperationsToFinish(_ manager: FileSyncManager,
                                           sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("the file operations to drain", sourceLocation: sourceLocation) {
            manager.activeFileOperationsCount == 0
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    // MARK: - Clipboard

    @MainActor
    @Test func testHandleCopyToClipboardStoresNodesAndCutFlag() {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let node = FileNode(id: "/tmp/a.txt", name: "a.txt", isDirectory: false)

        handler.handleCopyToClipboard([node], isCut: false)
        #expect(manager.clipboardNodes.map(\.id) == [node.id])
        #expect(manager.clipboardIsCut == false)

        handler.handleCopyToClipboard([node], isCut: true)
        #expect(manager.clipboardNodes.map(\.id) == [node.id])
        #expect(manager.clipboardIsCut == true)
    }

    // MARK: - Paste routes

    @MainActor
    @Test func testPasteItemsToDirectoryNodeCopiesIntoIt() async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let (root, src, dst) = try makeTempPair("paste")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: src, named: "copy-me.txt")
        let node = FileNode(id: file.path, name: "copy-me.txt", isDirectory: false)
        let dirNode = FileNode(id: dst.path, name: dst.lastPathComponent, isDirectory: true)

        handler.pasteItems([node], to: dirNode, isCut: false)

        let copied = dst.appendingPathComponent("copy-me.txt")
        await waitUntil("the copy to appear at \(copied.lastPathComponent)") {
            FileManager.default.fileExists(atPath: copied.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(FileManager.default.fileExists(atPath: file.path)) // copy, not move
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message.hasPrefix("Copied “copy-me.txt”") == true)
        #expect(manager.banner?.severity == .success)
        #expect(manager.banner?.isUndoable == true)
    }

    /// Pasting "onto" a file targets that file's parent directory (Finder semantics).
    @MainActor
    @Test func testPasteItemsToFileNodeCopiesIntoItsParentDirectory() async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let (root, src, dst) = try makeTempPair("pastefile")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: src, named: "copy-me.txt")
        let neighbor = try makeFile(in: dst, named: "existing.txt")
        let node = FileNode(id: file.path, name: "copy-me.txt", isDirectory: false)
        let fileTarget = FileNode(id: neighbor.path, name: "existing.txt", isDirectory: false)

        handler.pasteItems([node], to: fileTarget, isCut: false)

        let copied = dst.appendingPathComponent("copy-me.txt")
        await waitUntil("the copy to appear at \(copied.lastPathComponent)") {
            FileManager.default.fileExists(atPath: copied.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    /// An empty clipboard pastes nothing, through either entry point.
    @MainActor
    @Test(arguments: [true, false])
    func testPasteClipboardWithEmptyClipboardDoesNothing(ontoANode: Bool) async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager, label: "emptypaste-\(ontoANode)")
        let dst = try makeTempDir("emptypaste-\(ontoANode)")
        defer { try? FileManager.default.removeItem(at: dst) }

        if ontoANode {
            handler.pasteClipboard(to: FileNode(id: dst.path, name: dst.lastPathComponent, isDirectory: true))
        } else {
            handler.pasteClipboard(toPath: dst.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(manager.banner == nil)
        #expect(manager.currentError == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
    }

    /// Copy-paste from the clipboard: the item lands, and the clipboard is retained so it can be
    /// pasted again (only a cut-paste clears it).
    @MainActor
    @Test func testPasteClipboardToNodeCopiesAndRetainsClipboard() async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let (root, src, dst) = try makeTempPair("clip")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: src, named: "clip.txt")
        let node = FileNode(id: file.path, name: "clip.txt", isDirectory: false)
        handler.handleCopyToClipboard([node], isCut: false)

        handler.pasteClipboard(to: FileNode(id: dst.path, name: dst.lastPathComponent, isDirectory: true))

        let copied = dst.appendingPathComponent("clip.txt")
        await waitUntil("the copy to appear at \(copied.lastPathComponent)") {
            FileManager.default.fileExists(atPath: copied.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(manager.clipboardNodes.map(\.id) == [node.id])
        #expect(manager.clipboardIsCut == false)
    }

    /// Extends the cut-paste contract to the `pasteClipboard(toPath:)` entry point: the clipboard
    /// clears (and the cut flag drops) only after the move actually succeeded.
    @MainActor
    @Test func testPasteClipboardToPathCutMovesAndClearsClipboardAfterSuccess() async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let (root, src, dst) = try makeTempPair("clipcut")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeFile(in: src, named: "cut.txt")
        let node = FileNode(id: file.path, name: "cut.txt", isDirectory: false)
        handler.handleCopyToClipboard([node], isCut: true)

        handler.pasteClipboard(toPath: dst.path)

        let moved = dst.appendingPathComponent("cut.txt")
        await waitUntil("the cut-paste to move the file and clear the clipboard") {
            FileManager.default.fileExists(atPath: moved.path) && manager.clipboardNodes.isEmpty
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(manager.clipboardNodes.isEmpty)
        #expect(manager.clipboardIsCut == false)
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message.hasPrefix("Moved “cut.txt”") == true)
    }

    // MARK: - Pane-to-pane move

    /// Both directions: two providers rooted at real temp dirs, a file in the source pane, and a
    /// move via the pane-to-pane entry point.
    @MainActor
    @Test(arguments: [true, false])
    func movingBetweenPanesLandsInTheOtherPane(fromLeft: Bool) async throws {
        let manager = FileSyncManager()
        let (root, left, right, settings) = try twoPanes("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = scratchHandler(manager, settings: settings, label: "runPaneMove-\(fromLeft)")

        let sourceDir = fromLeft ? left : right
        let destDir = fromLeft ? right : left
        let file = try makeFile(in: sourceDir, named: "move-me.txt")
        let node = FileNode(id: file.path, name: "move-me.txt", isDirectory: false)

        let moved = await handler.moveItems([node], fromLeft: fromLeft, leftProviderId: "L", rightProviderId: "R")
        await waitForOperationsToFinish(manager)

        let landed = destDir.appendingPathComponent("move-me.txt")
        #expect(moved.map(\.id) == [node.id])
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let expectedTarget = fromLeft ? "RightSide" : "LeftSide"
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message == "Moved “move-me.txt” to \(expectedTarget)")
        #expect(manager.banner?.isUndoable == true)
    }

    /// The pane-to-pane copy happy path: the file lands in the other pane, the source is kept,
    /// and the banner names the destination provider.
    @MainActor
    @Test func testCopyItemsFromLeftCopiesToRightPane() async throws {
        let manager = FileSyncManager()
        let (root, left, right, settings) = try twoPanes("copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = scratchHandler(manager, settings: settings)
        let file = try makeFile(in: left, named: "copy-me.txt")
        let node = FileNode(id: file.path, name: "copy-me.txt", isDirectory: false)

        handler.copyItems([node], fromLeft: true, leftProviderId: "L", rightProviderId: "R")

        let landed = right.appendingPathComponent("copy-me.txt")
        await waitUntil("the copy to land in the other pane") {
            FileManager.default.fileExists(atPath: landed.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(FileManager.default.fileExists(atPath: file.path)) // copy keeps the source
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message == "Copied “copy-me.txt” to RightSide")
        #expect(manager.banner?.isUndoable == true)
    }

    /// A vanished destination provider (source pane intact) aborts before any I/O, blaming the
    /// destination side: the transferRoots guard opposite the one the source tests cover.
    @MainActor
    @Test func testMoveItemsWithUnknownDestinationProviderPresentsErrorForDestinationSide() async throws {
        let manager = FileSyncManager()
        let left = try makeTempDir("move-dst-gone")
        defer { try? FileManager.default.removeItem(at: left) }
        let settings = scratchSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", rootPath: left.path, type: .iCloud),
        ])
        let handler = scratchHandler(manager, settings: settings)
        let file = try makeFile(in: left, named: "keep-me.txt")
        let node = FileNode(id: file.path, name: "keep-me.txt", isDirectory: false)

        let moved = await handler.moveItems([node], fromLeft: true, leftProviderId: "L", rightProviderId: "vanished")

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.currentError?.message.contains("right") == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// A vanished provider (empty root) aborts before any I/O: nothing moves, nothing returns,
    /// and the same pane-unavailable error copyItems presents is shown.
    @MainActor
    @Test func testMoveItemsWithUnknownProviderReturnsEmptyAndPresentsError() async throws {
        let manager = FileSyncManager()
        let handler = scratchHandler(manager)
        let src = try makeTempDir("move-guard")
        defer { try? FileManager.default.removeItem(at: src) }
        let file = try makeFile(in: src, named: "keep-me.txt")
        let node = FileNode(id: file.path, name: "keep-me.txt", isDirectory: false)

        let moved = await handler.moveItems([node], fromLeft: true, leftProviderId: "gone-left", rightProviderId: "gone-right")

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager.banner == nil)
    }

    /// When every item fails to move (source file vanished), no success banner appears: nothing
    /// was transferred.
    @MainActor
    @Test func testMoveItemsWithMissingSourceFileShowsNoSuccessBanner() async throws {
        let manager = FileSyncManager()
        let (root, left, right, settings) = try twoPanes("move-miss")
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = scratchHandler(manager, settings: settings)
        let node = FileNode(id: left.appendingPathComponent("ghost.txt").path, name: "ghost.txt", isDirectory: false)

        let moved = await handler.moveItems([node], fromLeft: true, leftProviderId: "L", rightProviderId: "R")
        await waitForOperationsToFinish(manager)

        #expect(moved.isEmpty)
        // No wait for a banner, on purpose: the contract is that no success banner appears, which
        // `nil` satisfies. Waiting for one would only time out.
        #expect(manager.banner?.severity != .success)
    }

    // MARK: - Delete

    /// A cancelled prompt leaves the item, whether the setting asked or the pane bar's Delete did
    /// (`alwaysConfirm`) with the setting off. Paired with
    /// `anUnconfirmedDeleteSaysWhatTheFilterHidInTheResult`, so confirmation turning unconditional fails.
    @MainActor
    @Test(arguments: [false, true])
    func aCancelledDeleteLeavesTheItem(alwaysConfirmWithTheSettingOff: Bool) async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("del-cancel-\(alwaysConfirmWithTheSettingOff)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "keep.txt")
        let defaults = ScratchDefaults("FAH-del-cancel")
        if alwaysConfirmWithTheSettingOff { defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey) }
        var promptedNames: [String]? = nil
        let handler = scratchHandler(manager, defaults: defaults, label: "del-cancel-\(alwaysConfirmWithTheSettingOff)",
                                     deleteConfirmer: { names, _ in
            promptedNames = names
            return false
        })

        handler.confirmDelete([FileNode(id: file.path, name: "keep.txt", isDirectory: false)],
                              alwaysConfirm: alwaysConfirmWithTheSettingOff)
        await waitForOperationsToFinish(manager)

        #expect(promptedNames == ["keep.txt"])
        // Asked and obeyed: a prompt whose "no" was ignored would be worse than no prompt.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager.banner == nil)
    }

    /// A folder carries everything in it, so both the Trash prompt and a copy's result say how much
    /// the pane's type filter is hiding, the result in the banner the handler sets last (the one on
    /// screen).
    @MainActor
    @Test func aFilteredFolderSaysWhatTheFilterHidesInThePromptAndTheResult() async throws {
        let (root, src, dst) = try makeTempPair("filter")
        defer { try? FileManager.default.removeItem(at: root) }
        let box = src.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let pdf = try makeFile(in: box, named: "a.pdf")
        let jpg = try makeFile(in: box, named: "b.jpg")
        let manager = FileSyncManager()
        manager.rawLeftTree = [FileNode(id: box.path, name: "box", isDirectory: true, children: [
            FileNode(id: pdf.path, name: "a.pdf", isDirectory: false),
            FileNode(id: jpg.path, name: "b.jpg", isDirectory: false),
        ])]
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        await manager.applyFilters()
        let shown = manager.leftTree
        #expect(shown.first?.children?.map(\.name) == ["a.pdf"])
        var told: Int?
        let handler = scratchHandler(manager, deleteConfirmer: { _, hidden in
            told = hidden
            return false
        })

        handler.confirmDelete(shown)
        #expect(told == 1)

        handler.pasteItems(shown, toPath: dst.path, isCut: false)
        await waitUntil("the copy's banner") { manager.banner?.message.hasPrefix("Copied “box”") == true }
        #expect(manager.banner?.message == "Copied “box” to the other pane. Includes 1 item the filter is hiding")
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("box/b.jpg").path))
    }

    @MainActor
    @Test func testConfirmDeleteConfirmedTrashesItems() async throws {
        let dir = try makeTempDir("del-confirm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let trash = ScratchTrash(in: dir)
        let manager = FileSyncManager(fileManager: trash)
        // Wired so the delete registers its undo, which is what makes the banner undoable.
        manager.undoManager = UndoManager()
        let file = try makeFile(in: dir, named: "trash-me.txt")
        let handler = scratchHandler(manager, deleteConfirmer: { _, _ in true })

        handler.confirmDelete([FileNode(id: file.path, name: "trash-me.txt", isDirectory: false)])

        await waitUntil("the delete to remove \(file.lastPathComponent)") {
            !FileManager.default.fileExists(atPath: file.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message == "Moved “trash-me.txt” to the Trash")
        #expect(manager.banner?.isUndoable == true)
        #expect(trash.names == ["trash-me.txt"],
                "the file left the disk but never reached the test's own Trash")
    }

    /// With "Confirm before deleting" off, the delete runs without consulting the confirmer, and
    /// with no prompt to say it, the result says what the filter was hiding inside the folder, in
    /// the same clause the prompt and a copy's result use.
    @MainActor
    @Test func anUnconfirmedDeleteSaysWhatTheFilterHidInTheResult() async throws {
        let dir = try makeTempDir("del-filter-noprompt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let trash = ScratchTrash(in: dir)
        let manager = FileSyncManager(fileManager: trash)
        manager.undoManager = UndoManager()
        let box = dir.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let pdf = try makeFile(in: box, named: "a.pdf")
        let jpg = try makeFile(in: box, named: "b.jpg")
        manager.rawLeftTree = [FileNode(id: box.path, name: "box", isDirectory: true, children: [
            FileNode(id: pdf.path, name: "a.pdf", isDirectory: false),
            FileNode(id: jpg.path, name: "b.jpg", isDirectory: false),
        ])]
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        await manager.applyFilters()
        let defaults = ScratchDefaults("FAH-del-filter-noprompt")
        defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        var confirmerCalls = 0
        let handler = scratchHandler(manager, defaults: defaults, deleteConfirmer: { _, _ in
            confirmerCalls += 1
            return false // would cancel: must never be consulted
        })

        handler.confirmDelete(manager.leftTree)
        await waitUntil("the result to name what the filter hid") {
            manager.banner?.message.hasSuffix("the filter is hiding") == true
        }
        await waitForOperationsToFinish(manager)
        #expect(manager.banner?.message == "Moved “box” to the Trash. Includes 1 item the filter is hiding")
        #expect(manager.banner?.isUndoable == true, "the clause keeps the delete's own Undo")
        #expect(!FileManager.default.fileExists(atPath: box.path))
        #expect(confirmerCalls == 0)
        #expect(trash.names == ["box"], "the folder left the disk but never reached the test's own Trash")
    }

    // MARK: - Rename

    @MainActor
    @Test func testBeginRenameCancelledDoesNothing() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("rename-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "original.txt")
        var promptedCurrentName: String? = nil
        var validateRejectsSlash = false
        var validateAcceptsPlainName = false
        let handler = scratchHandler(manager, renamePrompter: { currentName, validate in
            promptedCurrentName = currentName
            // The prompt is wired to the engine's name validation (rejects "/" like Finder).
            validateRejectsSlash = validate("bad/name") != nil
            validateAcceptsPlainName = validate("fine-name") == nil
            return nil // user cancelled
        })

        handler.beginRename(FileNode(id: file.path, name: "original.txt", isDirectory: false))
        await waitForOperationsToFinish(manager)

        #expect(promptedCurrentName == "original.txt")
        #expect(validateRejectsSlash)
        #expect(validateAcceptsPlainName)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Re-entering the unchanged name is a no-op, not a rename-onto-itself.
    @MainActor
    @Test func testBeginRenameToSameNameDoesNothing() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("rename-same")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "same.txt")
        let handler = scratchHandler(manager, renamePrompter: { currentName, _ in currentName })

        handler.beginRename(FileNode(id: file.path, name: "same.txt", isDirectory: false))
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager.currentError == nil)
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testBeginRenameRenamesItemOnDisk() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("rename-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "before.txt")
        let handler = scratchHandler(manager, renamePrompter: { _, _ in "after.txt" })

        handler.beginRename(FileNode(id: file.path, name: "before.txt", isDirectory: false))

        let renamed = dir.appendingPathComponent("after.txt")
        await waitUntil("the rename to produce \(renamed.lastPathComponent)") {
            FileManager.default.fileExists(atPath: renamed.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(manager.currentError == nil)
    }

    // MARK: - New folder

    @MainActor
    @Test func testBeginCreateFolderCancelledCreatesNothing() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("newfolder-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        var validateSeen = false
        let handler = scratchHandler(manager, newFolderPrompter: { validate in
            validateSeen = validate("bad:name") != nil // engine validation is wired through
            return nil // user cancelled
        })

        handler.beginCreateFolder(in: dir.path)
        await waitForOperationsToFinish(manager)

        #expect(validateSeen)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(manager.currentError == nil)
    }

    @MainActor
    @Test func testBeginCreateFolderCreatesFolderOnDisk() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("newfolder-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let handler = scratchHandler(manager, newFolderPrompter: { _ in "Fresh Folder" })

        handler.beginCreateFolder(in: dir.path)

        let created = dir.appendingPathComponent("Fresh Folder")
        await waitUntil("the new folder \(created.lastPathComponent) to exist") {
            FileManager.default.fileExists(atPath: created.path)
        }
        await waitForOperationsToFinish(manager)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(manager.currentError == nil)
    }

    // MARK: - Every operation runs on the manager's own file manager

    /// A real `FileManager` that notes the destination of every move and new folder, the call each
    /// operation ends in. A call site that dropped `fileManager:` would land the same on disk via
    /// `FileManager.default` but leave no note.
    private final class RecordingFileManager: FileManager, @unchecked Sendable {
        private let notes = OSAllocatedUnfairLock(initialState: [String]())
        var destinations: [String] { notes.withLock { $0 } }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            notes.withLock { $0.append(dstURL.lastPathComponent) }
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            notes.withLock { $0.append(url.lastPathComponent) }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates,
                                      attributes: attributes)
        }
    }

    /// Waits for `landed`, then checks it was the manager's own file manager that put it there.
    @MainActor
    private func expectTheManagersFileManagerLanded(_ landed: URL, _ recorder: RecordingFileManager,
                                                    _ manager: FileSyncManager,
                                                    sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("\(landed.lastPathComponent) to land") {
            FileManager.default.fileExists(atPath: landed.path)
        }
        await waitForOperationsToFinish(manager)
        #expect(recorder.destinations.contains(landed.lastPathComponent),
                "\(landed.lastPathComponent) landed, but not through the manager's file manager: \(recorder.destinations)",
                sourceLocation: sourceLocation)
    }

    /// Two providers rooted at fresh temp dirs, for the pane-to-pane routes.
    @MainActor
    private func twoPanes(_ label: String) throws -> (root: URL, left: URL, right: URL, settings: SettingsManager) {
        let (root, left, right) = try makeTempPair(label)
        let settings = scratchSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", rootPath: left.path, type: .iCloud),
            CloudProvider(id: "R", displayName: "RightSide", imageName: "icloud", rootPath: right.path, type: .iCloud),
        ])
        return (root, left, right, settings)
    }

    /// Every route that lands a file: the pane copy and move, a drop's move, a cut and a copy
    /// paste, a rename and a new folder.
    enum Route: String, CaseIterable, Sendable {
        case paneCopy, paneMove, dropMove, cutPaste, copyPaste, rename, newFolder
    }

    @MainActor
    @Test(arguments: Route.allCases)
    func everyRouteRunsOnTheManagersFileManager(_ route: Route) async throws {
        let recorder = RecordingFileManager()
        let manager = FileSyncManager(fileManager: recorder)
        let panes = try twoPanes("fm-\(route.rawValue)")
        defer { try? FileManager.default.removeItem(at: panes.root) }
        // Only the pane routes resolve providers; the rest run with none, as the app's drop and
        // paste targets are plain paths.
        let paneRoute = route == .paneCopy || route == .paneMove
        let handler = scratchHandler(manager,
                                     settings: paneRoute ? panes.settings : scratchSettings(providers: []),
                                     label: "fm-\(route.rawValue)",
                                     renamePrompter: { _, _ in "new-name.txt" },
                                     newFolderPrompter: { _ in "Recorded Folder" })
        func node(_ name: String) throws -> FileNode {
            let file = try makeFile(in: panes.left, named: name)
            return FileNode(id: file.path, name: name, isDirectory: false)
        }

        let landed: URL
        switch route {
        case .paneCopy:
            handler.copyItems([try node("pane-copy.txt")], fromLeft: true, leftProviderId: "L", rightProviderId: "R")
            landed = panes.right.appendingPathComponent("pane-copy.txt")
        case .paneMove:
            _ = await handler.moveItems([try node("pane-move.txt")], fromLeft: true,
                                        leftProviderId: "L", rightProviderId: "R")
            landed = panes.right.appendingPathComponent("pane-move.txt")
        case .dropMove:
            handler.moveItems([try node("dropped.txt")], toPath: panes.right.path)
            landed = panes.right.appendingPathComponent("dropped.txt")
        case .cutPaste:
            handler.pasteItems([try node("cut-paste.txt")], toPath: panes.right.path, isCut: true)
            landed = panes.right.appendingPathComponent("cut-paste.txt")
        case .copyPaste:
            handler.pasteItems([try node("copy-paste.txt")], toPath: panes.right.path, isCut: false)
            landed = panes.right.appendingPathComponent("copy-paste.txt")
        case .rename:
            handler.beginRename(try node("old-name.txt"))
            landed = panes.left.appendingPathComponent("new-name.txt")
        case .newFolder:
            handler.beginCreateFolder(in: panes.left.path)
            landed = panes.left.appendingPathComponent("Recorded Folder")
        }

        await expectTheManagersFileManagerLanded(landed, recorder, manager)
    }
}
