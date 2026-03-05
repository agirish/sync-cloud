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
        await waitForOperationsToFinish(manager)
        
        let movedFile = dstDir.appendingPathComponent(node.name)
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
}
