import Testing
import Foundation
@testable import Sync

/// Pins `isNodeIgnored`'s currentPath stripping to path-component boundaries: a pane rooted
/// at "/root/ab" must not claim "/root/abc/x" via a bare string prefix, which would alias a
/// sibling root's nodes into bogus relative paths and match the wrong ignore entries.
@Suite struct IsNodeIgnoredBoundaryTests {

    private func node(_ id: String) -> FileNode {
        FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: false)
    }

    @MainActor
    @Test func testChildUnderCurrentPathMatchesRelativeEntry() {
        let manager = FileSyncManager()
        manager.ignoredPaths = ["x"]
        #expect(manager.isNodeIgnored(node("/root/ab/x"), currentPath: "/root/ab"))
    }

    @MainActor
    @Test func testPrefixOverlappingSiblingRootIsNotStripped() {
        let manager = FileSyncManager()
        manager.ignoredPaths = ["c/x"]
        // Old bare-hasPrefix stripping turned "/root/abc/x" into "c/x" against base
        // "/root/ab"; the node is outside the pane and must keep its absolute path.
        #expect(!manager.isNodeIgnored(node("/root/abc/x"), currentPath: "/root/ab"))
        manager.ignoredPaths = ["/root/abc/x"]
        #expect(manager.isNodeIgnored(node("/root/abc/x"), currentPath: "/root/ab"))
    }

    @MainActor
    @Test func testAncestorEntryStillCoversDescendantNodes() {
        let manager = FileSyncManager()
        manager.ignoredPaths = ["docs"]
        #expect(manager.isNodeIgnored(node("/root/docs/report.txt"), currentPath: "/root"))
    }

    @MainActor
    @Test func testTrailingSlashCurrentPathStripsLikeBefore() {
        let manager = FileSyncManager()
        manager.ignoredPaths = ["x"]
        // A root pane's currentPath can legitimately end in "/" (e.g. "/"); stripping must
        // still land on the same relative form the ignore set stores.
        #expect(manager.isNodeIgnored(node("/x"), currentPath: "/"))
        #expect(manager.isNodeIgnored(node("/root/ab/x"), currentPath: "/root/ab/"))
    }
}
