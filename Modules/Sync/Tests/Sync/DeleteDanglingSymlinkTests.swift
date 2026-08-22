import Foundation
import Testing
@testable import Sync

/// **A dangling symlink is still an item on disk, and Delete has to remove it.**
///
/// `deleteItems(at:)` gated the trash on `fileExists(atPath:)`, which FOLLOWS the link. A symlink
/// whose target has been deleted — or lives on a volume that is not mounted — therefore answered
/// `false`, and the branch had no `else`: the entry was skipped with no error, no banner, and no
/// place in the removed count. The user selected it, pressed Delete, and was told the operation
/// succeeded while the link stayed exactly where it was.
///
/// The distinction is one the codebase already relies on elsewhere: `setAsideUnreadable` probes
/// with `attributesOfItem` precisely because "the link is still a directory entry".
@Suite @MainActor struct DeleteDanglingSymlinkTests {

    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    /// The fixture, and the premise it rests on: the two probes must disagree, or this test is
    /// about an ordinary file and proves nothing.
    private func makeDisk() throws -> MockFileManager {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        fm.virtualDisk["/docs/link-to-nowhere"] = file(0)
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

    /// Mixed selection: the ordinary file must still go, and the count must cover both — a fix that
    /// only ever counted one of them would pass the test above.
    @Test func aDanglingSymlinkBesideAnOrdinaryFileTakesBoth() async throws {
        let manager = makeManager()
        let fm = try makeDisk()
        fm.virtualDisk["/docs/real.txt"] = file(120)

        let outcome = await manager.deleteItems(at: ["/docs/link-to-nowhere", "/docs/real.txt"],
                                                fileManager: fm)

        #expect(outcome.removed == 2)
        #expect(fm.virtualDisk["/docs/link-to-nowhere"] == nil)
        #expect(fm.virtualDisk["/docs/real.txt"] == nil)
    }

    /// And a path that is genuinely absent is still nothing to do — the guard must not become
    /// "trash everything asked for", which would send the trash at paths nothing occupies.
    @Test func aPathThatIsGenuinelyAbsentIsStillSkipped() async throws {
        let manager = makeManager()
        let fm = try makeDisk()

        let outcome = await manager.deleteItems(at: ["/docs/never-existed"], fileManager: fm)

        #expect(outcome.removed == 0)
        #expect(fm.trashedPaths.isEmpty)
    }

    /// ⌘Z brings it back, like any other delete — the link is an item, so its removal is an
    /// ordinary undoable one and not a special case.
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
