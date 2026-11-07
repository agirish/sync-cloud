import Foundation
import Testing
@testable import Sync

/// A dangling symlink is still an item on disk, and Delete removes it. `fileExists(atPath:)`
/// follows the link, so a link whose target is deleted or unmounted answers `false`; gating the
/// trash on it would skip the entry silently, report success, and leave the link in place.
/// `setAsideUnreadable` probes with `attributesOfItem` for the same reason: the link is still a
/// directory entry.
@Suite @MainActor struct DeleteDanglingSymlinkTests {

    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests()
    }

    /// The fixture, and the premise it rests on: the two probes must disagree, or this test is
    /// about an ordinary file and proves nothing.
    private func makeDisk() throws -> MockFileManager {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        fm.virtualDisk["/docs/link-to-nowhere"] = .file(0)
        fm.danglingSymlinks = ["/docs/link-to-nowhere"]
        #expect(!fm.fileExists(atPath: "/docs/link-to-nowhere"),
                "fixture: a dangling link must not answer the followed probe")
        #expect((try? fm.attributesOfItem(atPath: "/docs/link-to-nowhere")) != nil,
                "fixture: the link itself is still there to be described")
        return fm
    }

    @Test func aDanglingSymlinkIsTrashedRatherThanSkipped() async throws {
        let manager = makeManager()
        let fm = try makeDisk()

        let outcome = await manager.deleteItems(at: ["/docs/link-to-nowhere"], fileManager: fm)

        #expect(outcome.removed == 1, "the link was reported as nothing to do")
        #expect(fm.virtualDisk["/docs/link-to-nowhere"] == nil, "the link is still on disk")
        #expect(fm.trashedPaths.contains { $0.hasSuffix("link-to-nowhere") })
    }

    /// Mixed selection: the ordinary file still goes and the count covers both, which a count of
    /// only one kind would fail.
    @Test func aDanglingSymlinkBesideAnOrdinaryFileTakesBoth() async throws {
        let manager = makeManager()
        let fm = try makeDisk()
        fm.virtualDisk["/docs/real.txt"] = .file(120)

        let outcome = await manager.deleteItems(at: ["/docs/link-to-nowhere", "/docs/real.txt"],
                                                fileManager: fm)

        #expect(outcome.removed == 2)
        #expect(fm.virtualDisk["/docs/link-to-nowhere"] == nil)
        #expect(fm.virtualDisk["/docs/real.txt"] == nil)
    }

    /// A genuinely absent path is still nothing to do: the guard must not become "trash everything
    /// asked for".
    @Test func aPathThatIsGenuinelyAbsentIsStillSkipped() async throws {
        let manager = makeManager()
        let fm = try makeDisk()

        let outcome = await manager.deleteItems(at: ["/docs/never-existed"], fileManager: fm)

        #expect(outcome.removed == 0)
        #expect(fm.trashedPaths.isEmpty)
    }

    /// ⌘Z brings it back like any other delete: the link is an item, so its removal is an ordinary
    /// undoable one.
    @Test func trashingADanglingSymlinkIsUndoable() async throws {
        let manager = makeManager()
        let fm = try makeDisk()

        _ = await manager.deleteItems(at: ["/docs/link-to-nowhere"], fileManager: fm)
        #expect(fm.virtualDisk["/docs/link-to-nowhere"] == nil)

        #expect(manager.undoManager?.canUndo == true, "trashing the link registered no undo")
        manager.undoManager?.undo()
        await waitUntil("the link comes back") { fm.virtualDisk["/docs/link-to-nowhere"] != nil }
    }
}
