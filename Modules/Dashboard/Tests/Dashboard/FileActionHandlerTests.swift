import Testing
import Foundation
import Sync
import Settings
@testable import Dashboard

@Suite struct FileActionHandlerTests {
    
    @MainActor
    @Test func testClipboardPersistenceOnCopy() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: SettingsManager())
        let node = FileNode(id: "/tmp/does-not-exist.txt", name: "does-not-exist.txt", isDirectory: false)
        
        manager.clipboardNodes = [node]
        manager.clipboardIsCut = false
        
        handler.pasteItems([node], toPath: "/tmp", isCut: false)
        await waitForOperationsToFinish(manager)
        
        #expect(manager.clipboardNodes.count == 1)
        #expect(manager.clipboardNodes.first?.id == node.id)
        #expect(manager.clipboardIsCut == false)
    }
    
    @MainActor
    @Test func testClipboardClearsOnlyAfterSuccessfulCutPaste() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: SettingsManager())
        
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DashboardTests-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("src")
        let dstDir = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        
        defer { try? FileManager.default.removeItem(at: root) }
        
        let srcFile = srcDir.appendingPathComponent("cut-me.txt")
        try Data("hello".utf8).write(to: srcFile)
        
        let node = FileNode(id: srcFile.path, name: srcFile.lastPathComponent, isDirectory: false)
        manager.clipboardNodes = [node]
        manager.clipboardIsCut = true
        
        handler.pasteItems([node], toPath: dstDir.path, isCut: true)

        // pasteItems spawns a Task. `waitForOperationsToFinish` alone is racy here: it polls a
        // counter whose 0 means both "not started yet" and "finished", so when the main actor is
        // contended (e.g. the snapshot suite rendering offscreen in a parallel test run) the
        // spawned Task can start only after the counter-wait has already returned. Wait for the
        // operation's observable outcome first — the same pattern the moveItems test uses.
        let movedFile = dstDir.appendingPathComponent(node.name)
        for _ in 0..<200 where !(FileManager.default.fileExists(atPath: movedFile.path)
                                 && manager.clipboardNodes.isEmpty) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await waitForOperationsToFinish(manager)

        #expect(FileManager.default.fileExists(atPath: movedFile.path))
        #expect(!FileManager.default.fileExists(atPath: srcFile.path))
        #expect(manager.clipboardNodes.isEmpty)
        #expect(manager.clipboardIsCut == false)
    }
    
    @MainActor
    @Test func testClipboardRemainsWhenCutPasteFails() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: SettingsManager())
        let node = FileNode(id: "/tmp/does-not-exist.txt", name: "does-not-exist.txt", isDirectory: false)
        
        manager.clipboardNodes = [node]
        manager.clipboardIsCut = true
        
        handler.pasteItems([node], toPath: "/tmp", isCut: true)
        await waitForOperationsToFinish(manager)
        
        #expect(manager.clipboardNodes.count == 1)
        #expect(manager.clipboardNodes.first?.id == node.id)
        #expect(manager.clipboardIsCut == true)
    }
    
    /// The drag-drop move route runs headless end-to-end: confirmation is the sync layer's
    /// `transferConfirmer` seam (asked exactly once), NOT a Design-level modal — re-adding
    /// the old NativeAlerts.confirmMove guard here would double-prompt every move and hang
    /// this test on its alert.
    @MainActor
    @Test func testMoveItemsToPathMovesViaSyncLayerWithOneConfirmation() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: SettingsManager())

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DashboardTests-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("src")
        let dstDir = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let srcFile = srcDir.appendingPathComponent("move-me.txt")
        try Data("hello".utf8).write(to: srcFile)
        let node = FileNode(id: srcFile.path, name: srcFile.lastPathComponent, isDirectory: false)

        var prompts = 0
        manager.transferConfirmer = { summary in
            prompts += 1
            #expect(summary.isMove == true)
            return true
        }

        handler.moveItems([node], toPath: dstDir.path)

        // moveItems spawns a Task; wait for the move to land on disk.
        let movedFile = dstDir.appendingPathComponent(node.name)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: movedFile.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: movedFile.path))
        #expect(!FileManager.default.fileExists(atPath: srcFile.path))
        #expect(prompts == 1)
    }

    @MainActor
    private func waitForOperationsToFinish(_ manager: FileSyncManager) async {
        for _ in 0..<50 {
            if manager.activeFileOperationsCount == 0 {
                // Allow clipboard update that runs immediately after awaited move result.
                try? await Task.sleep(nanoseconds: 10_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Pane-root guards (vanished providers, prefix aliasing)

    /// Settings with a deterministic provider list: no background discovery, isolated defaults.
    @MainActor
    private func makeSettings(providers: [CloudProvider]) -> SettingsManager {
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: ScratchDefaults("FileActionHandlerTests"),
            cloudStorageLister: { [] },
            pathValidator: { _ in true }
        )
        settings.availableProviders = providers
        return settings
    }

    @MainActor
    private func waitForError(_ manager: FileSyncManager) async {
        for _ in 0..<50 {
            if manager.currentError != nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A provider id that vanished from settings resolves to an empty root ("" from
    /// `settings.path(for:)`). The copy must abort with an error before reaching the sync
    /// layer — previously the empty root sent files to a CWD-relative destination.
    @MainActor
    @Test func testCopyItemsWithUnknownProviderPresentsErrorAndCopiesNothing() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []))

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let srcFile = root.appendingPathComponent("keep-me.txt")
        try Data("hello".utf8).write(to: srcFile)
        let node = FileNode(id: srcFile.path, name: "keep-me.txt", isDirectory: false)

        handler.copyItems([node], fromLeft: true, leftProviderId: "vanished-left", rightProviderId: "vanished-right")
        await waitForError(manager)

        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.currentError?.message.contains("left") == true)
        #expect(manager.activeFileOperationsCount == 0)
        #expect(FileManager.default.fileExists(atPath: srcFile.path))
    }

    /// A provider that is still known but whose root folder no longer exists on disk (cloud app
    /// unmounted) also aborts, pointing at the missing folder.
    @MainActor
    @Test func testCopyItemsWithVanishedSourceRootPresentsError() async throws {
        let manager = FileSyncManager()
        let existingRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existingRoot) }
        let goneRoot = "/nonexistent/FAH-\(UUID().uuidString)"
        let settings = makeSettings(providers: [
            CloudProvider(id: "gone", displayName: "Gone", imageName: "icloud", path: goneRoot, type: .iCloud),
            CloudProvider(id: "here", displayName: "Here", imageName: "icloud", path: existingRoot.path, type: .iCloud),
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings)
        let node = FileNode(id: goneRoot + "/f.txt", name: "f.txt", isDirectory: false)

        handler.copyItems([node], fromLeft: true, leftProviderId: "gone", rightProviderId: "here")
        await waitForError(manager)

        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.currentError?.message.contains("no longer exists on disk") == true)
        #expect(manager.currentError?.path == goneRoot)
        #expect(manager.activeFileOperationsCount == 0)
    }

    /// focusFolder with an unknown provider (empty root) presents an error instead of focusing
    /// on a garbage relative path derived from the node's absolute path.
    @MainActor
    @Test func testFocusFolderWithUnknownProviderPresentsErrorAndDoesNotNavigate() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []))
        let node = FileNode(id: "/somewhere/folder", name: "folder", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "vanished", rightProviderId: "also-vanished")

        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.leftRelativePath == "")
    }

    /// focusFolder must match the root with a path boundary: a sibling whose path merely starts
    /// with the root string ("/rootX" under root "/root") is outside the pane, not "X" inside it.
    @MainActor
    @Test func testFocusFolderPrefixAliasedNodePresentsErrorAndDoesNotNavigate() async throws {
        let manager = FileSyncManager()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(providers: [
            CloudProvider(id: "p", displayName: "P", imageName: "icloud", path: root.path, type: .iCloud)
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings)
        let aliasedNode = FileNode(id: root.path + "-alias/sub", name: "sub", isDirectory: true)

        handler.focusFolder(aliasedNode, isLeft: true, leftProviderId: "p", rightProviderId: "p")

        #expect(manager.currentError?.title == "Can't Focus Folder")
        #expect(manager.leftRelativePath == "")
    }

    /// beginCreateFolder with an empty pane path (vanished provider) must present an error
    /// before ever prompting for a name — the sync layer would refuse the empty root anyway,
    /// and without the guard the folder used to be created at the process CWD.
    @MainActor
    @Test func testBeginCreateFolderWithEmptyPathPresentsErrorWithoutPrompting() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []))

        handler.beginCreateFolder(in: "")

        // The guard is synchronous; reaching these expectations at all proves no name prompt
        // (a modal alert, which would stall the suite) was shown.
        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.activeFileOperationsCount == 0)
    }

    /// Happy-path regression guard: a folder genuinely under the root still focuses, with the
    /// same relative path as before the boundary fix.
    @MainActor
    @Test func testFocusFolderUnderRootStillNavigates() async throws {
        let manager = FileSyncManager()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-focus-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(providers: [
            CloudProvider(id: "p", displayName: "P", imageName: "icloud", path: root.path, type: .iCloud)
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings)
        let node = FileNode(id: root.path + "/sub/inner", name: "inner", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "p", rightProviderId: "p")

        #expect(manager.currentError == nil)
        #expect(manager.leftRelativePath == "sub/inner")
    }
}
