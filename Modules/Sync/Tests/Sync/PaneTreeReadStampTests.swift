import Testing
import Foundation
@testable import Sync

/// When each pane's published tree was read from disk — the fact Browse's status bar puts through
/// `ScanFreshness` (roadmap RD6).
///
/// **The whole of the interesting behaviour is the cache hit.** Stamping the moment a tree is
/// *published* is one line and always compiles; the question is whether a tree served from the
/// prefetch cache carries the age of the walk that built it, or claims to have been read at the
/// moment it was handed over. The second is a freshness segment that resets to "Scanned 0s ago"
/// every time you navigate back into a folder you were just in.
@MainActor
@Suite struct PaneTreeReadStampTests {

    private func manager(_ build: (MockFileManager) throws -> Void) rethrows -> FileSyncManager {
        let fm = MockFileManager()
        try build(fm)
        return FileSyncManager(fileManager: fm)
    }

    /// A cold walk stamps the pane, and a pane that has loaded nothing carries no stamp at all —
    /// which is what makes the bar omit the segment rather than invent a date.
    @Test func aColdWalkStampsThePaneAndAnUnloadedPaneCarriesNothing() async throws {
        let manager = try manager { fm in
            try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
            fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        #expect(manager.leftTreeReadAt == nil, "a pane that has loaded nothing already claims a read")

        let before = Date()
        await manager.loadTree(path: "/src", isLeft: true)
        let stamp = try #require(manager.leftTreeReadAt)
        #expect(stamp >= before && stamp <= Date())
        #expect(manager.rightTreeReadAt == nil, "loading one pane stamped the other")
    }

    /// **A cache hit reports the WALK's time, not the hit's.** Navigating away and back serves the
    /// tree from `prefetchedTrees`, and the age has to survive that round trip — otherwise the
    /// freshest-looking listing in the app is the one nobody has re-read.
    @Test func aCacheHitCarriesTheAgeOfTheWalkThatBuiltIt() async throws {
        let manager = try manager { fm in
            try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
            try fm.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
            fm.virtualDisk["/src/sub/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        await manager.loadTree(path: "/src", isLeft: true)
        let walked = try #require(manager.leftTreeReadAt)

        // Age the walk by hand — the alternative is sleeping, and the point is a difference the
        // clock can see rather than a specific number of seconds.
        let aged = walked.addingTimeInterval(-600)
        manager.prefetchedTreeReadAt["/src"] = aged
        manager.leftTreeReadAt = nil

        // Same root, so this is served straight from the cache without touching the disk.
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftTreeReadAt == aged,
                "a served tree claimed \(String(describing: manager.leftTreeReadAt)) rather than the walk's \(aged)")
    }

    /// A slice drilled out of a cached root inherits that root's stamp, the same way it inherits
    /// the root's walk-stopped bit: the slice is part of that walk, not a walk of its own.
    @Test func aSliceOfACachedRootInheritsTheRootsStamp() async throws {
        let manager = try manager { fm in
            try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
            try fm.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
            fm.virtualDisk["/src/sub/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        await manager.loadTree(path: "/src", isLeft: true)
        let aged = try #require(manager.leftTreeReadAt).addingTimeInterval(-600)
        manager.prefetchedTreeReadAt["/src"] = aged

        manager.leftRelativePath = "sub"
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftTreeReadAt == aged,
                "drilling into a cached folder re-dated the listing to now")
    }

    /// Dropping the cache drops the stamps with it — one verb, so the two stores cannot part
    /// company and leave a stale date to be inherited by the next tree cached at the same path.
    @Test func droppingTheCacheDropsTheStamps() async throws {
        let manager = try manager { fm in
            try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
            fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(!manager.prefetchedTreeReadAt.isEmpty, "the walk cached no stamp — this check is vacuous")
        manager.dropPrefetchedTrees()
        #expect(manager.prefetchedTreeReadAt.isEmpty)
    }

    /// Re-pointing one pane clears its stamp and leaves the other's alone. A pane whose tree has
    /// just been thrown away must not go on being dated by a walk of somewhere else.
    @Test func invalidatingOnePaneClearsItsStampAndOnlyIts() async throws {
        let manager = try manager { fm in
            try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
            fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        await manager.loadTree(path: "/src", isLeft: true)
        await manager.loadTree(path: "/src", isLeft: false)
        #expect(manager.leftTreeReadAt != nil && manager.rightTreeReadAt != nil)

        manager.invalidatePaneTree(isLeft: true)
        #expect(manager.leftTreeReadAt == nil)
        #expect(manager.rightTreeReadAt != nil, "re-pointing the left pane un-dated the right one")
    }
}
