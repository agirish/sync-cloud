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

    /// An EMPTY currentPath — a pane whose provider was dropped from settings while its stale tree
    /// is still on screen — is the absence of a root, not the volume root. `PathBoundary` now says
    /// so, and this pins what that means HERE: the node keeps its absolute path and is matched
    /// against the ignore set as an absolute entry.
    ///
    /// The distinction matters because "" and "/" used to be the same answer: an empty root once
    /// stripped the leading slash and produced a near-absolute "root/ab/x", which matched neither
    /// the relative entries the ignore set stores nor the absolute ones — it could only ever be a
    /// false negative, and silently.
    @MainActor
    @Test func testEmptyCurrentPathKeepsTheNodesAbsolutePath() {
        let manager = FileSyncManager()
        manager.ignoredPaths = ["/root/ab/x"]
        #expect(manager.isNodeIgnored(node("/root/ab/x"), currentPath: ""))

        // And the leading-slash-stripped spelling the old empty-root behavior produced must NOT
        // match — that form was never a path the ignore set legitimately holds.
        manager.ignoredPaths = ["root/ab/x"]
        #expect(!manager.isNodeIgnored(node("/root/ab/x"), currentPath: ""))
    }
}
