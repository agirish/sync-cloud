import Testing
import Foundation
@testable import Sync

/// **Which folder a pane's published tree was read at** — the fact Edit's owed selection (TE47)
/// asks before selecting a row, so it never selects against the tree of a folder the pane has just
/// left. `focusOn` moves the pane's folder at once; the walk that answers it lands later.
@MainActor
@Suite struct PaneTreeFolderTests {

    private func manager() throws -> FileSyncManager {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.virtualDisk["/src/sub/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return FileSyncManager(fileManager: fm)
    }

    @Test func aPaneWithNoWalkNamesNoFolder() throws {
        let manager = try manager()
        #expect(manager.paneTreeFolder(isLeft: true) == nil)
        #expect(manager.paneTreeFolder(isLeft: false) == nil)
    }

    /// A walk names the folder it read, for its own pane only; a walk of another folder moves it.
    @Test func aWalkNamesTheFolderItRead() async throws {
        let manager = try manager()
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.paneTreeFolder(isLeft: true) == "/src")
        #expect(manager.paneTreeFolder(isLeft: false) == nil, "loading one pane named the other's folder")
        await manager.loadTree(path: "/src/sub", isLeft: true)
        #expect(manager.paneTreeFolder(isLeft: true) == "/src/sub")
    }

    /// A dropped tree names nothing — it is not a tree of anywhere.
    @Test func aDroppedTreeNamesNoFolder() async throws {
        let manager = try manager()
        await manager.loadTree(path: "/src", isLeft: true)
        manager.invalidatePaneTree(isLeft: true)
        #expect(manager.paneTreeFolder(isLeft: true) == nil)
    }
}
