import Testing
import Foundation
import Sync
import Settings
@testable import Dashboard

/// **A write reached by a key during a long run is refused and told why** (decision BZ).
///
/// The window greys every write control while `activeProgress` is set, but ⌫ in a list, ⌘V, ↩ to
/// rename and the palette's New Folder are keys, not controls, and land straight on these methods.
/// Each must refuse before it asks anything or touches a file, and put the run's own reason in the
/// banner — the same words the greyed controls carry as their tooltip.
@MainActor
@Suite struct FileActionHandlerRunLockTests {

    private final class Asked { var count = 0 }

    /// No discovery, isolated defaults — `FileActionHandlerTests.scratchSettings`' reason.
    private func scratchSettings() -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: ScratchDefaults("FileActionHandlerRunLockTests"))
    }

    private func handler(_ manager: FileSyncManager, asked: Asked) -> FileActionHandler {
        FileActionHandler(syncManager: manager, settings: scratchSettings(),
                          renamePrompter: { _, _ in asked.count += 1; return nil },
                          newFolderPrompter: { _ in asked.count += 1; return nil },
                          deleteConfirmer: { _ in asked.count += 1; return false })
    }

    private func runningMerge() -> Progress {
        let progress = Progress(totalUnitCount: 10)
        progress.localizedDescription = "Merging “Photos”"
        progress.runLockReason = Progress.runLockReason(waitingFor: "the merge")
        return progress
    }

    @Test func everyKeyedWriteIsRefusedWithTheRunsReason() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RunLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Keep me.txt")
        try Data("x".utf8).write(to: file)
        let node = FileNode(id: file.path, name: file.lastPathComponent, isDirectory: false)

        let manager = FileSyncManager()
        let asked = Asked()
        let handler = handler(manager, asked: asked)
        manager.activeProgress = runningMerge()

        let refusals: [(String, () -> Void)] = [
            ("delete", { handler.confirmDelete([node]) }),
            ("rename", { handler.beginRename(node) }),
            ("new folder", { handler.beginCreateFolder(in: root.path) }),
            ("paste", { handler.pasteItems([node], toPath: root.path, isCut: true) }),
            ("clipboard paste", { handler.pasteClipboard(toPath: root.path) }),
            ("move to path", { handler.moveItems([node], toPath: root.path) }),
        ]
        for (what, act) in refusals {
            manager.banner = nil
            act()
            #expect(manager.banner?.message == "Wait for the merge to finish", "\(what) was not refused with the run's reason")
        }
        #expect(asked.count == 0, "a refused write still asked its question")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(manager.activeFileOperationsCount == 0, "a refused write still queued an operation")
    }

    /// With nothing running, the same calls go ahead — so the refusals above are the lock's.
    @Test func withNoRunTheyGoAhead() {
        let manager = FileSyncManager()
        let asked = Asked()
        let handler = handler(manager, asked: asked)
        handler.beginCreateFolder(in: NSTemporaryDirectory())
        #expect(asked.count == 1)
        #expect(manager.banner == nil)
    }

    /// A run that named no reason still says something true.
    @Test func aRunWithNoReasonUsesTheGenericWords() {
        let manager = FileSyncManager()
        let handler = handler(manager, asked: Asked())
        manager.activeProgress = Progress(totalUnitCount: 1)
        handler.beginCreateFolder(in: NSTemporaryDirectory())
        #expect(manager.banner?.message == Progress.genericRunLockReason)
    }
}
