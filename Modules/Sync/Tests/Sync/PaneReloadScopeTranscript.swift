import Testing
import Foundation
@testable import Sync

/// A controlled fixture for proving a change to pane reloading is behaviour-preserving
/// (`CLAUDE.md` §5). The CLI reaches `FileDiffEngine` directly and never touches
/// `FileSyncManager`, so diffing its binary would exercise none of this; the subject is the
/// manager itself.
///
/// It writes a canonical transcript to `$SYNCCLOUD_TRANSCRIPT` and asserts nothing about it. Run
/// it before and after the change and `diff` the two: trees, item counts, differences,
/// `hasScanned`, the prefetch cache's keys, and the state after a file operation, a forced rescan
/// and a sort change must match, apart from the intended delta. Tree versions are recorded as the
/// proxy for "did this pane reload": every adopt bumps one.
@Suite struct PaneReloadScopeTranscript {

    /// Two roots that differ, so the scan has something to report and a stale comparison would show.
    private static func makeFixture() throws -> (root: URL, left: URL, right: URL) {
        // A directory per call: the tests here run in parallel, and on one shared path each would
        // `removeItem` the others' trees mid-walk. The transcript is path-relative, so a per-call
        // name doesn't affect its diff.
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

    /// Everything about the manager an observer could see, in a stable order.
    ///
    /// Paths are printed relative to the fixture root so the transcript does not carry the temp
    /// directory's name, which changes per run and would swamp the diff.
    @MainActor
    private static func snapshot(_ label: String, _ m: FileSyncManager, root: URL) -> String {
        // Both spellings of the temp root: the manager echoes the provider paths it was handed
        // (`/var/…`) while the walk reports resolved ones (`/private/var/…`), and
        // `resolvingSymlinksInPath()` returns the `/var` form either way. Each is stripped with or
        // without its leading slash, so a transcript whose `FileDifference.relativePath` lost its
        // first character still compares.
        func rel(_ path: String) -> String {
            for base in [root.path, "/private" + root.path] {
                if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
                let bare = String(base.dropFirst())
                if path.hasPrefix(bare) { return String(path.dropFirst(bare.count)) }
            }
            return path
        }
        func paths(_ nodes: [FileNode]) -> [String] {
            var out: [String] = []
            func walk(_ ns: [FileNode]) {
                for n in ns.sorted(by: { $0.id < $1.id }) {
                    out.append(rel(n.id))
                    walk(n.children ?? [])
                }
            }
            walk(nodes)
            return out
        }
        var lines = ["=== \(label)"]
        lines.append("left.focus         \(m.leftRelativePath)")
        lines.append("right.focus        \(m.rightRelativePath)")
        lines.append("left.stack         \(m.leftBrowsePath.components.joined(separator: "/"))")
        lines.append("right.stack        \(m.rightBrowsePath.components.joined(separator: "/"))")
        lines.append("left.treeVersion   \(m.leftPaneTree.version)")
        lines.append("right.treeVersion  \(m.rightPaneTree.version)")
        lines.append("left.itemCount     \(m.leftItemCount)")
        lines.append("right.itemCount    \(m.rightItemCount)")
        lines.append("left.lastLoaded    \(m.lastLoadedLeftFocusPath.map(rel) ?? "nil")")
        lines.append("right.lastLoaded   \(m.lastLoadedRightFocusPath.map(rel) ?? "nil")")
        lines.append("hasScanned         \(m.hasScanned)")
        lines.append("prefetch.keys      \(m.prefetchedTrees.keys.map(rel).sorted().joined(separator: ","))")
        lines.append("left.tree")
        lines.append(contentsOf: paths(m.leftTree).map { "  \($0)" })
        lines.append("right.tree")
        lines.append(contentsOf: paths(m.rightTree).map { "  \($0)" })
        lines.append("differences")
        lines.append(contentsOf: m.differences
            .map { "  \(rel($0.relativePath)) \($0.type)" }
            .sorted())
        return lines.joined(separator: "\n")
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

    /// A left-pane tab switch, as the app performs one: drop the moving pane's tree and the shared
    /// comparison, move the pane, then a one-pane refresh. Kept in one place so a change to it reads
    /// clearly in the diff; steps 01 and 04–06 don't use it and are the controls.
    @MainActor
    private func tabSwitch(_ m: FileSyncManager, to focus: String,
                           left: CloudProvider, right: CloudProvider) async {
        m.invalidatePaneTree(isLeft: true)
        m.invalidateDifferencesForPaneRetarget()
        m.focusOn(relativePath: focus, isLeft: true)
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly)
    }

    /// The script. Each step is a thing a user does; the transcript is taken after each.
    ///
    /// The last three steps check that a file operation, a forced rescan and a sort change each
    /// still rebuild both panes. Every staleness source clears `prefetchedTrees` and nothing else,
    /// so a "this pane already has that focus, skip it" shortcut would show pre-operation state here.
    @MainActor
    @Test func writeTranscript() async throws {
        guard let out = ProcessInfo.processInfo.environment["SYNCCLOUD_TRANSCRIPT"] else {
            // Not a transcript run: nothing to record, and nothing to assert.
            return
        }
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let m = FileSyncManager()
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder",
                                 rootPath: fixture.left.path, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                                  rootPath: fixture.right.path, type: .localFolder)
        var transcript: [String] = []
        func record(_ label: String) {
            transcript.append(Self.snapshot(label, m, root: fixture.root))
        }

        await m.refreshTreesAndScan(left: left, right: right)
        record("01 initial refresh")

        // A tab switch on the left pane, as `applyTab` performs one.
        await tabSwitch(m, to: "Finance/US", left: left, right: right)
        record("02 left tab switch to Finance/US")

        await tabSwitch(m, to: "", left: left, right: right)
        record("03 left tab switch back to the root")

        // A file operation: the disk changed, so both panes must rebuild. It writes into the right
        // root too, or the control would pass with the right pane's reload deleted outright.
        try "new".write(to: fixture.left.appendingPathComponent("added-by-op.txt"),
                        atomically: true, encoding: .utf8)
        try "new".write(to: fixture.right.appendingPathComponent("added-on-the-right.txt"),
                        atomically: true, encoding: .utf8)
        m.prefetchedTrees.removeAll()
        m.noteScanConfigChanged()
        await m.refreshTreesAndScan(left: left, right: right)
        record("04 after a file operation")

        m.prepareForcedRescan()
        await m.refreshTreesAndScan(left: left, right: right)
        record("05 after a forced rescan")

        m.sortOption = .size
        await m.refreshTreesAndScan(left: left, right: right)
        record("06 after a sort change")

        try transcript.joined(separator: "\n\n").appending("\n")
            .write(toFile: out, atomically: true, encoding: .utf8)
    }
}
