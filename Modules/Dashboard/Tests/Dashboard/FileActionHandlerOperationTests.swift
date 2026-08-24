import Testing
import AppKit
import Foundation
import Sync
import Settings
@testable import Dashboard

/// Coverage for FileActionHandler's real operations — the clipboard/paste routes, pane-to-pane
/// moves, delete, rename, new folder, and Get Info — through the constructor-injected seams
/// (prompts, delete confirmation, AppleScript runner). File I/O runs against real temp
/// directories, following FileActionHandlerTests; waits are outcome-based (poll for the effect
/// on disk / on the manager) because the operation counter's 0 means both "not started" and
/// "finished" under a contended main actor.
@Suite struct FileActionHandlerOperationTests {

    /// A pasteboard of this **test's** own, cleared as it is handed over.
    ///
    /// **`handleCopyToClipboard` writes to the system pasteboard as of v4.2**, so a handler built
    /// on `.general` here would replace whatever the developer had copied — and did: with the real
    /// pasteboard in play, `testPasteClipboardToNodeWithEmptyClipboardDoesNothing` pasted the
    /// preceding test's `clip.txt` into its temp directory and failed on a banner it never asked
    /// for. That failure is the reason the handler takes a pasteboard at all.
    ///
    /// **`label` is what keeps that fix from being half a fix.** Moving off `.general` took the
    /// developer's clipboard out of the blast radius and left twelve tests sharing one *named*
    /// board — and swift-testing runs a suite's tests in **parallel**, so they overlap for as long
    /// as their real file I/O and outcome polling take. A board is global state keyed by its name:
    /// one test's `clearContents()` lands between another's copy and its paste (that paste then
    /// resolves `.none` and copies nothing), or one test's copy lands after another's clear (that
    /// test then pastes real files into its temp dir — which is the *same* failure quoted above,
    /// reproduced with a different board). Naming the board after the test that owns it is what
    /// makes the isolation real; `SystemClipboardTests` already does exactly this, one file over.
    ///
    /// `SystemClipboard.hasFiles`'s memo is keyed on `(name, changeCount)` for this reason too, so
    /// distinct names keep the memo honest as well as the board.
    /// The pid scopes the board to this process on top of the per-test label: named boards live
    /// in the machine-global pasteboard server, so a concurrent test process — CI beside a local
    /// run on this same machine — shares an unsuffixed name and writes into its sibling's
    /// assertions (see `SystemClipboardTests.board(_:)` for the incident).
    static func scratchPasteboard(_ label: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name(
            "SyncCloudTests.fileActionHandler.\(label).\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        return board
    }

    // MARK: - Fixtures

    /// Settings with a deterministic provider list: no background discovery, isolated defaults.
    @MainActor
    private func makeSettings(providers: [CloudProvider]) -> SettingsManager {
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: ScratchDefaults("FileActionHandlerOperationTests"),
            cloudStorageLister: { .read([]) },
            pathValidator: { _ in true }
        )
        settings.availableProviders = providers
        return settings
    }

    /// A fresh temp directory, removed by the caller's `defer`.
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FAH-ops-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeFile(in dir: URL, named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    /// Waits for the manager's file-operation bookkeeping to drain.
    ///
    /// **On its own this is not a wait at all, and every caller is what makes it one.** The old
    /// body returned the moment `activeFileOperationsCount == 0` — *including before the operation
    /// had started*, which is "quiescence cannot tell finished from not started" verbatim
    /// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). It is safe here only because every
    /// call site waits for the operation's own OUTCOME first, with `waitUntil` on the file
    /// appearing or disappearing. Keep that order: outcome, then drain — polling for zero cannot
    /// distinguish the two ends on its own, and no change to this helper can make it.
    ///
    /// **What is fixed here** is the pair that could fail in silence: it gave up after a fixed 50
    /// iterations, a budget that shrinks under load exactly when it is needed, and then returned as
    /// though it had drained. The drain now goes through the shared `waitUntil`, which has a poll
    /// floor and says so at the caller when the condition never holds.
    ///
    /// **The trailing settle stays, and it stays because removing it failed.** `FileOperations
    /// .swift` documents building its history records synchronously so a caller waiting on
    /// completion cannot observe done early, which is easy to read as "`banner` is published before
    /// the count reaches zero". It is not: dropping this sleep failed
    /// `testCopyItemsFromLeftCopiesToRightPane` on an **idle** machine — load 4.1, banner `nil`, in
    /// 2.9s — so the publication lands on a later turn than the decrement.
    ///
    /// It is a fixed pump, which this repo's own flake doc names as a smell, and it is left as one
    /// **knowingly**. The honest fix is for the tests that assert a banner to wait on
    /// `manager.banner` instead of on the drain — a dozen assertions, six of which assert the
    /// banner is *absent* and would need the wait written the other way round. Worth doing; not
    /// this commit.
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
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testHandleCopyToClipboardStoresNodesAndCutFlag"))
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
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteItemsToDirectoryNodeCopiesIntoIt"))
        let src = try makeTempDir("paste-src")
        let dst = try makeTempDir("paste-dst")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
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
        #expect(manager.banner?.message.hasPrefix("Copied \"copy-me.txt\"") == true)
        #expect(manager.banner?.severity == .success)
        #expect(manager.banner?.isUndoable == true)
    }

    /// Pasting "onto" a file targets that file's parent directory (Finder semantics).
    @MainActor
    @Test func testPasteItemsToFileNodeCopiesIntoItsParentDirectory() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteItemsToFileNodeCopiesIntoItsParentDirectory"))
        let src = try makeTempDir("pastefile-src")
        let dst = try makeTempDir("pastefile-dst")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
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

    @MainActor
    @Test func testPasteClipboardToNodeWithEmptyClipboardDoesNothing() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteClipboardToNodeWithEmptyClipboardDoesNothing"))
        let dst = try makeTempDir("emptypaste")
        defer { try? FileManager.default.removeItem(at: dst) }

        handler.pasteClipboard(to: FileNode(id: dst.path, name: dst.lastPathComponent, isDirectory: true))
        await waitForOperationsToFinish(manager)

        #expect(manager.banner == nil)
        #expect(manager.currentError == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
    }

    @MainActor
    @Test func testPasteClipboardToPathWithEmptyClipboardDoesNothing() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteClipboardToPathWithEmptyClipboardDoesNothing"))
        let dst = try makeTempDir("emptypaste-path")
        defer { try? FileManager.default.removeItem(at: dst) }

        handler.pasteClipboard(toPath: dst.path)
        await waitForOperationsToFinish(manager)

        #expect(manager.banner == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
    }

    /// Copy-paste from the clipboard: the item lands, and the clipboard is retained so it can be
    /// pasted again (only a cut-paste clears it).
    @MainActor
    @Test func testPasteClipboardToNodeCopiesAndRetainsClipboard() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteClipboardToNodeCopiesAndRetainsClipboard"))
        let src = try makeTempDir("clip-src")
        let dst = try makeTempDir("clip-dst")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
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
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testPasteClipboardToPathCutMovesAndClearsClipboardAfterSuccess"))
        let src = try makeTempDir("clipcut-src")
        let dst = try makeTempDir("clipcut-dst")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
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
        #expect(manager.banner?.message.hasPrefix("Moved \"cut.txt\"") == true)
    }

    // MARK: - Pane-to-pane move

    /// Both-directions harness: two providers rooted at real temp dirs, a file in the source
    /// pane, and a move via the pane-to-pane entry point.
    @MainActor
    private func runPaneMove(fromLeft: Bool) async throws {
        let manager = FileSyncManager()
        let left = try makeTempDir("move-left")
        let right = try makeTempDir("move-right")
        defer {
            try? FileManager.default.removeItem(at: left)
            try? FileManager.default.removeItem(at: right)
        }
        let settings = makeSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", path: left.path, type: .iCloud),
            CloudProvider(id: "R", displayName: "RightSide", imageName: "icloud", path: right.path, type: .iCloud),
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        pasteboard: Self.scratchPasteboard("runPaneMove-\(fromLeft)"))

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
        #expect(manager.banner?.message == "Moved \"move-me.txt\" to \(expectedTarget)")
        #expect(manager.banner?.isUndoable == true)
    }

    @MainActor
    @Test func testMoveItemsFromLeftLandsInRightPane() async throws {
        try await runPaneMove(fromLeft: true)
    }

    @MainActor
    @Test func testMoveItemsFromRightLandsInLeftPane() async throws {
        try await runPaneMove(fromLeft: false)
    }

    /// The pane-to-pane copy happy path: the file lands in the other pane, the source is kept,
    /// and the banner names the destination provider.
    @MainActor
    @Test func testCopyItemsFromLeftCopiesToRightPane() async throws {
        let manager = FileSyncManager()
        let left = try makeTempDir("copy-left")
        let right = try makeTempDir("copy-right")
        defer {
            try? FileManager.default.removeItem(at: left)
            try? FileManager.default.removeItem(at: right)
        }
        let settings = makeSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", path: left.path, type: .iCloud),
            CloudProvider(id: "R", displayName: "RightSide", imageName: "icloud", path: right.path, type: .iCloud),
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        pasteboard: Self.scratchPasteboard("testCopyItemsFromLeftCopiesToRightPane"))
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
        #expect(manager.banner?.message == "Copied \"copy-me.txt\" to RightSide")
        #expect(manager.banner?.isUndoable == true)
    }

    /// A vanished DESTINATION provider (source pane intact) aborts before any I/O, blaming the
    /// destination side — the transferRoots guard opposite the one the source tests cover.
    @MainActor
    @Test func testMoveItemsWithUnknownDestinationProviderPresentsErrorForDestinationSide() async throws {
        let manager = FileSyncManager()
        let left = try makeTempDir("move-dst-gone")
        defer { try? FileManager.default.removeItem(at: left) }
        let settings = makeSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", path: left.path, type: .iCloud),
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        pasteboard: Self.scratchPasteboard("testMoveItemsWithUnknownDestinationProviderPresentsErrorForDestinationSide"))
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
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []),
                                        pasteboard: Self.scratchPasteboard("testMoveItemsWithUnknownProviderReturnsEmptyAndPresentsError"))
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

    /// When every item fails to move (source file vanished), no success banner appears —
    /// the "no banner when nothing was actually transferred" contract.
    @MainActor
    @Test func testMoveItemsWithMissingSourceFileShowsNoSuccessBanner() async throws {
        let manager = FileSyncManager()
        let left = try makeTempDir("move-miss-left")
        let right = try makeTempDir("move-miss-right")
        defer {
            try? FileManager.default.removeItem(at: left)
            try? FileManager.default.removeItem(at: right)
        }
        let settings = makeSettings(providers: [
            CloudProvider(id: "L", displayName: "LeftSide", imageName: "icloud", path: left.path, type: .iCloud),
            CloudProvider(id: "R", displayName: "RightSide", imageName: "icloud", path: right.path, type: .iCloud),
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        pasteboard: Self.scratchPasteboard("testMoveItemsWithMissingSourceFileShowsNoSuccessBanner"))
        let node = FileNode(id: left.appendingPathComponent("ghost.txt").path, name: "ghost.txt", isDirectory: false)

        let moved = await handler.moveItems([node], fromLeft: true, leftProviderId: "L", rightProviderId: "R")
        await waitForOperationsToFinish(manager)

        #expect(moved.isEmpty)
        // No wait for a banner here, deliberately: this test's contract is that **no success
        // banner appears**, and `banner?.severity != .success` is satisfied by `nil`. Waiting for
        // one would spend five seconds proving the opposite of what the test is named for.
        #expect(manager.banner?.severity != .success)
    }

    // MARK: - Delete

    @MainActor
    @Test func testConfirmDeleteCancelledLeavesItemsUntouched() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("del-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "keep.txt")
        var promptedNames: [String]? = nil
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            defaults: ScratchDefaults("FAH-del-cancel"), // unset key → confirm (default true)
            deleteConfirmer: { names in
                promptedNames = names
                return false
            }
        )

        handler.confirmDelete([FileNode(id: file.path, name: "keep.txt", isDirectory: false)])
        await waitForOperationsToFinish(manager)

        #expect(promptedNames == ["keep.txt"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testConfirmDeleteConfirmedTrashesItems() async throws {
        let manager = FileSyncManager()
        // Wire an UndoManager so the trashed file can be restored afterwards — the test then
        // leaves nothing behind in the user's Trash.
        let undoManager = UndoManager()
        manager.undoManager = undoManager
        let dir = try makeTempDir("del-confirm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "trash-me.txt")
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            defaults: ScratchDefaults("FAH-del-confirm"),
            deleteConfirmer: { _ in true }
        )

        handler.confirmDelete([FileNode(id: file.path, name: "trash-me.txt", isDirectory: false)])

        await waitUntil("the delete to remove \(file.lastPathComponent)") {
            !FileManager.default.fileExists(atPath: file.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        await waitUntil("the completion banner to publish") { manager.banner != nil }
        #expect(manager.banner?.message == "Deleted \"trash-me.txt\"")
        #expect(manager.banner?.isUndoable == true)

        // Cleanup: restore from Trash via the registered undo (best-effort).
        if undoManager.canUndo {
            undoManager.undo()
            await waitBestEffort { FileManager.default.fileExists(atPath: file.path) }
            await waitForOperationsToFinish(manager)
        }
    }

    /// With "Confirm before deleting" switched off, the delete proceeds without ever consulting
    /// the confirmer.
    @MainActor
    @Test func testConfirmDeleteSkipsPromptWhenSettingDisabled() async throws {
        let manager = FileSyncManager()
        let undoManager = UndoManager()
        manager.undoManager = undoManager
        let dir = try makeTempDir("del-noprompt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "silent.txt")
        let defaults = ScratchDefaults("FAH-del-noprompt")
        defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        var confirmerCalls = 0
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            defaults: defaults,
            deleteConfirmer: { _ in
                confirmerCalls += 1
                return false // would cancel — must never be consulted
            }
        )

        handler.confirmDelete([FileNode(id: file.path, name: "silent.txt", isDirectory: false)])

        await waitUntil("the delete to remove \(file.lastPathComponent)") {
            !FileManager.default.fileExists(atPath: file.path)
        }
        await waitForOperationsToFinish(manager)

        #expect(confirmerCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Cleanup: restore from Trash via the registered undo (best-effort).
        if undoManager.canUndo {
            undoManager.undo()
            await waitBestEffort { FileManager.default.fileExists(atPath: file.path) }
            await waitForOperationsToFinish(manager)
        }
    }

    /// The pane bar's Delete asks even with the setting off — `alwaysConfirm: true`.
    ///
    /// Paired with `testConfirmDeleteSkipsPromptWhenSettingDisabled` above, which is the half that
    /// makes this one mean anything: the same defaults domain, the same setting, and the only
    /// difference is the flag. Without its sibling this could pass just as well against a build
    /// where confirmation had become unconditional for everybody — which is precisely the change
    /// the tooltip promises has NOT been made.
    ///
    /// Cancelling rather than confirming, so the file survives and the test leaves nothing in the
    /// user's Trash to restore.
    @MainActor
    @Test func testAlwaysConfirmAsksEvenWithTheSettingOff() async throws {
        let manager = FileSyncManager()
        let dir = try makeTempDir("del-always")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try makeFile(in: dir, named: "asked.txt")
        let defaults = ScratchDefaults("FAH-del-always")
        defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        var promptedNames: [String]? = nil
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            defaults: defaults,
            deleteConfirmer: { names in
                promptedNames = names
                return false
            }
        )

        handler.confirmDelete([FileNode(id: file.path, name: "asked.txt", isDirectory: false)],
                              alwaysConfirm: true)
        await waitForOperationsToFinish(manager)

        #expect(promptedNames == ["asked.txt"])
        // Asked AND obeyed: a prompt whose "no" was ignored would be worse than no prompt.
        #expect(FileManager.default.fileExists(atPath: file.path))
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
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            renamePrompter: { currentName, validate in
                promptedCurrentName = currentName
                // The prompt is wired to the engine's name validation (rejects "/" like Finder).
                validateRejectsSlash = validate("bad/name") != nil
                validateAcceptsPlainName = validate("fine-name") == nil
                return nil // user cancelled
            }
        )

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
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            renamePrompter: { currentName, _ in currentName }
        )

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
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            renamePrompter: { _, _ in "after.txt" }
        )

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
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            newFolderPrompter: { validate in
                validateSeen = validate("bad:name") != nil // engine validation is wired through
                return nil // user cancelled
            }
        )

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
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            newFolderPrompter: { _ in "Fresh Folder" }
        )

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

    // MARK: - Get Info

    @MainActor
    @Test func testOpenGetInfoBuildsFinderScriptWithEscapedPath() {
        var capturedScript: String? = nil
        let handler = FileActionHandler(
            syncManager: FileSyncManager(),
            settings: makeSettings(providers: []),
            appleScriptRunner: { script in
                capturedScript = script
                return nil // success
            }
        )

        handler.openGetInfo(for: #"/tmp/we"ird\name.txt"#)

        let script = capturedScript ?? ""
        #expect(script.contains(#"tell application "Finder""#))
        #expect(script.contains("open information window"))
        // The POSIX path is embedded with AppleScript escaping (backslash first, then quote).
        #expect(script.contains(#"POSIX file "/tmp/we\"ird\\name.txt""#))
    }

    /// The failure branch only logs (a failed Get Info is cosmetic): no error, no banner.
    @MainActor
    @Test func testOpenGetInfoScriptFailureIsSwallowed() {
        let manager = FileSyncManager()
        var runnerCalls = 0
        let handler = FileActionHandler(
            syncManager: manager,
            settings: makeSettings(providers: []),
            appleScriptRunner: { _ in
                runnerCalls += 1
                return ["NSAppleScriptErrorMessage": "Finder got an error"] as NSDictionary
            }
        )

        handler.openGetInfo(for: "/tmp/somewhere.txt")

        #expect(runnerCalls == 1)
        #expect(manager.currentError == nil)
        #expect(manager.banner == nil)
    }
}
