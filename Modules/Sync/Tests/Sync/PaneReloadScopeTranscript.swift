import Testing
import Foundation
@testable import Sync

/// How a refresh scoped to one pane treats the other: it leaves it alone, and never cancels a
/// wider refresh down to nothing.
@Suite struct PaneReloadScopeTranscript {

    /// Two roots that differ, so the scan has something to report and a stale comparison would show.
    private static func makeFixture() throws -> (root: URL, left: URL, right: URL) {
        // A directory per call: the tests here run in parallel, and on one shared path each would
        // `removeItem` the others' trees mid-walk.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccloud-reload-scope-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        let fm = FileManager.default
        for dir in ["Finance/US", "Finance/India", "Photos"] {
            try fm.createDirectory(at: left.appendingPathComponent(dir), withIntermediateDirectories: true)
            try fm.createDirectory(at: right.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        // Shared, left-only and right-only files, at the root and inside a focusable subfolder.
        try "same".write(to: left.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "same".write(to: right.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "L".write(to: left.appendingPathComponent("left-only.txt"), atomically: true, encoding: .utf8)
        try "R".write(to: right.appendingPathComponent("right-only.txt"), atomically: true, encoding: .utf8)
        try "L".write(to: left.appendingPathComponent("Finance/US/tax.pdf"), atomically: true, encoding: .utf8)
        try "L".write(to: left.appendingPathComponent("Finance/India/pan.pdf"), atomically: true, encoding: .utf8)
        try "R".write(to: right.appendingPathComponent("Finance/US/tax.pdf"), atomically: true, encoding: .utf8)
        // Resolved only once the directories exist: `resolvingSymlinksInPath()` is a no-op on a
        // path that isn't there yet, and an unresolved root would match no tree node, leaving
        // absolute temp paths in every tree line.
        let resolved = root.resolvingSymlinksInPath()
        return (resolved,
                resolved.appendingPathComponent("left", isDirectory: true),
                resolved.appendingPathComponent("right", isDirectory: true))
    }

    /// A one-pane refresh must not walk the other pane, asserted rather than left to a transcript
    /// someone reads. The disk changes under the still pane, and the pane must not notice: a walk
    /// would pick the new file up. Both directions, because each arm of the scope is separate code.
    @MainActor
    @Test(arguments: [true, false])
    func aScopedRefreshLeavesTheOtherPaneExactlyAsItWas(movingLeft: Bool) async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let m = FileSyncManager()
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder",
                                 rootPath: fixture.left.path, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                                  rootPath: fixture.right.path, type: .localFolder)

        await m.refreshTreesAndScan(left: left, right: right)
        let stillRoot = movingLeft ? fixture.right : fixture.left
        let stillCount = { movingLeft ? m.rightItemCount : m.leftItemCount }
        let stillVersion = { movingLeft ? m.rightPaneTree.version : m.leftPaneTree.version }
        let countBefore = stillCount()
        let versionBefore = stillVersion()
        #expect(countBefore > 0, "the fixture never loaded, so this proves nothing")

        // The disk changes under the still pane, and the prefetch cache goes, so a walk would see
        // the new file.
        try "new".write(to: stillRoot.appendingPathComponent("appeared.txt"),
                        atomically: true, encoding: .utf8)
        m.prefetchedTrees.removeAll()

        m.invalidatePaneTree(isLeft: movingLeft)
        m.invalidateDifferencesForPaneRetarget()
        m.focusOn(relativePath: "Finance/US", isLeft: movingLeft)
        await m.refreshTreesAndScan(left: left, right: right,
                                    reloading: .movedPane(isLeft: movingLeft))

        #expect(stillCount() == countBefore,
                "the pane that did not move was walked anyway")
        #expect(stillVersion() == versionBefore,
                "the still pane re-adopted a tree identical to the one it already had")
        // …and the pane that DID move is showing its new folder.
        #expect((movingLeft ? m.leftRelativePath : m.rightRelativePath) == "Finance/US")
        #expect((movingLeft ? m.leftItemCount : m.rightItemCount) == 1)

        // Control: a `.both` refresh picks the new file up, so the assertion above is about the
        // scope, not a fixture that could never change.
        await m.refreshTreesAndScan(left: left, right: right)
        #expect(stillCount() == countBefore + 1,
                "a full refresh missed a file that appeared on disk")
    }

    /// A one-pane refresh must not cancel a two-pane one down to nothing. `refreshTreesAndScan`
    /// supersedes whatever is in flight, so a tab switch during the launch load or a scan would
    /// cancel the other pane's load and start nothing in its place, leaving it blank. The scopes
    /// are unioned, so a refresh that disagrees with the running one widens to `.both`.
    @MainActor
    @Test func aScopedRefreshWidensRatherThanCancellingAWiderOne() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let m = FileSyncManager()
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder",
                                 rootPath: fixture.left.path, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                                  rootPath: fixture.right.path, type: .localFolder)

        // Stands in for a `.both` refresh in flight: the key is all the supersede logic reads.
        // Taken before the pane moves, as the real one would be.
        m.activeRefreshKey = m.makeRefreshKey(left: left, right: right, reloading: .both)

        // …then the tab switch: the left pane moves, so the new key differs and this supersedes
        // rather than dedupes. Without the union the right pane's load is lost here.
        m.focusOn(relativePath: "Finance/US", isLeft: true)
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly)

        #expect(!m.rightTree.isEmpty,
                "a one-pane refresh cancelled the two-pane one and left the other pane blank")
        #expect(!m.leftTree.isEmpty)
        #expect(m.rightItemCount > 0)
    }
}
