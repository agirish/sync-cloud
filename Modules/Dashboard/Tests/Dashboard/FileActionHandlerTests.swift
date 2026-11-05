import Testing
import Foundation
import Sync
import Settings
@testable import Dashboard

@Suite struct FileActionHandlerTests {
    
    @MainActor
    @Test func testClipboardPersistenceOnCopy() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: scratchSettings())
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
        let handler = FileActionHandler(syncManager: manager, settings: scratchSettings())
        
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

        // pasteItems spawns a Task. `waitForOperationsToFinish` alone races: its counter reads 0
        // both before the Task starts and after it ends, so on a contended main actor the wait can
        // return before the Task starts. Wait for the observable outcome first, as the moveItems
        // test does.
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
        let handler = FileActionHandler(syncManager: manager, settings: scratchSettings())
        let node = FileNode(id: "/tmp/does-not-exist.txt", name: "does-not-exist.txt", isDirectory: false)
        
        manager.clipboardNodes = [node]
        manager.clipboardIsCut = true
        
        handler.pasteItems([node], toPath: "/tmp", isCut: true)
        await waitForOperationsToFinish(manager)
        
        #expect(manager.clipboardNodes.count == 1)
        #expect(manager.clipboardNodes.first?.id == node.id)
        #expect(manager.clipboardIsCut == true)
    }
    
    /// The drag-drop move route runs headless end to end: confirmation is the sync layer's
    /// `transferConfirmer` seam, asked exactly once, not a Design-level modal. A second confirm in
    /// the handler would double-prompt every move and hang this test on its alert.
    @MainActor
    @Test func testMoveItemsToPathMovesViaSyncLayerWithOneConfirmation() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: scratchSettings())

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

    /// Settings for the clipboard and move tests, on a scratch suite with no discovery pass. A bare
    /// `SettingsManager()` discovers the real `~/Library/CloudStorage` and writes it to
    /// `lastKnownAccountFolders` in the standard domain, which under `swift test` is a plist every
    /// test process on the machine shares.
    @MainActor
    private func scratchSettings() -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: ScratchDefaults("FileActionHandlerTests"))
    }

    // MARK: - Pane-root guards (vanished providers, prefix aliasing)

    /// Settings with a deterministic provider list: no background discovery, isolated defaults.
    @MainActor
    private func makeSettings(providers: [CloudProvider]) -> SettingsManager {
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: ScratchDefaults("FileActionHandlerTests"),
            cloudStorageLister: { .read([]) },
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
    /// `settings.rootPath(for:)`). The copy must abort with an error before reaching the sync
    /// layer, or the empty root sends files to a CWD-relative destination.
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
            CloudProvider(id: "gone", displayName: "Gone", imageName: "icloud", rootPath: goneRoot, type: .iCloud),
            CloudProvider(id: "here", displayName: "Here", imageName: "icloud", rootPath: existingRoot.path, type: .iCloud),
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

        handler.focusFolder(node, isLeft: true, leftProviderId: "vanished", rightProviderId: "also-vanished", suppressLinkedNavigation: false)

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
            CloudProvider(id: "p", displayName: "P", imageName: "icloud", rootPath: root.path, type: .iCloud)
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings)
        let aliasedNode = FileNode(id: root.path + "-alias/sub", name: "sub", isDirectory: true)

        handler.focusFolder(aliasedNode, isLeft: true, leftProviderId: "p", rightProviderId: "p", suppressLinkedNavigation: false)

        #expect(manager.currentError?.title == "Can’t Focus Folder")
        #expect(manager.leftRelativePath == "")
    }

    /// beginCreateFolder with an empty pane path (vanished provider) presents an error before
    /// prompting for a name, rather than asking for a name the empty root can't take.
    @MainActor
    @Test func testBeginCreateFolderWithEmptyPathPresentsErrorWithoutPrompting() async throws {
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: []))

        handler.beginCreateFolder(in: "")

        // The guard is synchronous; reaching these expectations proves no name prompt (a modal
        // alert, which would stall the suite) was shown.
        #expect(manager.currentError?.title == "Folder Unavailable")
        #expect(manager.activeFileOperationsCount == 0)
    }

    /// The happy path: a folder genuinely under the root still focuses, with its relative path.
    @MainActor
    @Test func testFocusFolderUnderRootStillNavigates() async throws {
        let manager = FileSyncManager()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-focus-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeSettings(providers: [
            CloudProvider(id: "p", displayName: "P", imageName: "icloud", rootPath: root.path, type: .iCloud)
        ])
        let handler = FileActionHandler(syncManager: manager, settings: settings)
        let node = FileNode(id: root.path + "/sub/inner", name: "inner", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "p", rightProviderId: "p", suppressLinkedNavigation: false)

        #expect(manager.currentError == nil)
        #expect(manager.leftRelativePath == "sub/inner")
    }

    // MARK: - Focus on folders whose id is not spelled under the root

    /// `R/link → T`, with `T` beside `R`, a plain branch, and an empty folder for the other pane.
    private func makeLinkedTree(under base: URL) throws -> (root: URL, other: URL) {
        let fm = FileManager.default
        let root = base.appendingPathComponent("R", isDirectory: true)
        let target = base.appendingPathComponent("T", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: target.appendingPathComponent("sub/deeper/deepest"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("plain/a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        return (root, other)
    }

    /// The node a click hands over: down the pane's published tree by the names on screen.
    private func node(_ names: [String], in tree: [FileNode]) -> FileNode? {
        var level = tree
        var found: FileNode?
        for name in names {
            guard let next = level.first(where: { $0.name == name }) else { return nil }
            found = next
            level = next.children ?? []
        }
        return found
    }

    /// A folder two levels below a folder symlink focuses. The walk lists it where the link leads
    /// (`T/sub/deeper`), so stripping the root off its id would refuse a folder the pane shows.
    /// Then the round trip: the walk at the new focus lists that folder's own contents.
    @MainActor
    @Test func testFocusFolderBelowAFolderLinkNavigates() async throws {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-focus-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        // Canonical, so the root is spelled as the walk spells ids; the `/var` spelling is the next test's.
        let base = URL(fileURLWithPath: try raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? raw.path)
        let (root, otherRoot) = try makeLinkedTree(under: base)
        let pane = CloudProvider(id: "p", displayName: "P", imageName: "folder", rootPath: root.path, type: .localFolder)
        let other = CloudProvider(id: "o", displayName: "O", imageName: "folder", rootPath: otherRoot.path, type: .localFolder)
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: [pane, other]))
        await manager.refreshTreesAndScan(left: pane, right: other, comparing: false)

        let deeper = try #require(node(["link", "sub", "deeper"], in: manager.leftTree), "premise: the walk lists no `deeper`")
        try #require(!deeper.id.hasPrefix(root.path + "/"), "premise: \(deeper.id) is spelled under the root")
        handler.focusFolder(deeper, isLeft: true, leftProviderId: "p", rightProviderId: "o", suppressLinkedNavigation: false)

        #expect(manager.currentError == nil, "\(manager.currentError?.title ?? ""): \(manager.currentError?.message ?? "")")
        #expect(manager.leftRelativePath == "link/sub/deeper")
        await manager.refreshTreesAndScan(left: pane, right: other, reloading: .leftOnly, comparing: false)
        #expect(manager.leftTree.map(\.name) == ["deepest"], "the focus walked \(manager.leftTree.map(\.id))")
    }

    /// Under a root spelled through a link, every folder focuses. A `/var/…` root, where
    /// `NSTemporaryDirectory()` is, lists `/private/var/…` from its first level down, so even a
    /// plain child's id isn't spelled under the root.
    @MainActor
    @Test func testFocusFolderUnderARootSpelledThroughALinkNavigates() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FAH-focus-var-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, otherRoot) = try makeLinkedTree(under: base)
        let pane = CloudProvider(id: "p", displayName: "P", imageName: "folder", rootPath: root.path, type: .localFolder)
        let other = CloudProvider(id: "o", displayName: "O", imageName: "folder", rootPath: otherRoot.path, type: .localFolder)
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: makeSettings(providers: [pane, other]))
        await manager.refreshTreesAndScan(left: pane, right: other, comparing: false)

        let a = try #require(node(["plain", "a"], in: manager.leftTree), "premise: the walk lists no `plain/a`")
        try #require(!a.id.hasPrefix(root.path + "/"), "premise: \(a.id) is spelled under \(root.path)")
        handler.focusFolder(a, isLeft: true, leftProviderId: "p", rightProviderId: "o", suppressLinkedNavigation: false)

        #expect(manager.currentError == nil, "\(manager.currentError?.title ?? ""): \(manager.currentError?.message ?? "")")
        #expect(manager.leftRelativePath == "plain/a")
    }
}
