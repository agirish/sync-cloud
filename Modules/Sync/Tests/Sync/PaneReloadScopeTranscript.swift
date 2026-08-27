import Testing
import Foundation
@testable import Sync

/// A **controlled fixture, driven twice** — once against the code as it stands and once against the
/// change — so that "pane-scoped invalidation is behaviour-preserving" is a measurement rather than
/// an argument. `CLAUDE.md` requires exactly this for a refactor of the scan layer, and the usual
/// vehicle does not work here: `SyncCloudCLI` reaches `FileDiffEngine` directly and never touches
/// `FileSyncManager`, so diffing the CLI binary would exercise none of the changed code. The subject
/// has to be the manager itself.
///
/// It writes a canonical transcript to `$SYNCCLOUD_TRANSCRIPT` and asserts nothing about its
/// contents. Run it at `HEAD`, keep the file, apply the change, run it again, `diff` the two: the
/// intended delta is that a tab switch on ONE pane stops bumping the OTHER pane's tree version and
/// stops clearing its loaded-focus marker. Every other line — trees, item counts, differences,
/// `hasScanned`, the prefetch cache's keys, and the state after a file operation, a forced rescan
/// and a sort change — must be identical, and that is the half that makes the diff worth running.
///
/// The transcript records **tree versions** because they are the observable proxy for "did this pane
/// reload": every adopt bumps one. A saving that did not show up here would be a saving that did not
/// happen.
@Suite struct PaneReloadScopeTranscript {

    /// Two roots that differ, so the scan has something to report and a stale comparison would show.
    private static func makeFixture() throws -> (root: URL, left: URL, right: URL) {
        // **A directory of its own per call.** Three tests in this suite build a fixture, and
        // swift-testing runs them in parallel by default — CI does not pass `--no-parallel`. On one
        // shared path each would `removeItem` the others' trees mid-walk, which is a flake that
        // only ever appears on the machine that runs them concurrently. The transcript is
        // path-relative, so a per-call name costs its diff nothing.
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
        // **Resolved only now that the directories exist.** `NSTemporaryDirectory()` hands back the
        // `/var` symlink while the walk reports `/private/var`, and `resolvingSymlinksInPath()` is a
        // no-op on a path that is not there yet — so resolving before `createDirectory` left the
        // root unresolved, matching no tree node, and the transcript carried absolute temp paths in
        // every tree line. The relativised header fields still looked right, which is what made it
        // look like a formatting quirk rather than the fixture describing a different directory
        // from the one it had just built.
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
        // **Both spellings of the temp root.** `NSTemporaryDirectory()` is under `/var`, which is a
        // symlink to `/private/var`, and the two halves of this transcript disagree about which one
        // they use: the manager echoes back the provider paths it was handed (`/var/…`) while the
        // directory walk reports what the filesystem resolves them to (`/private/var/…`).
        // `resolvingSymlinksInPath()` does not settle it — measured, before AND after the
        // directories exist, it returns the `/var` form either way. Stripping either prefix is what
        // makes the transcript path-free, and a header field relativising while every tree line
        // stayed absolute is exactly what that mismatch looks like.
        // …and **with or without the leading slash**, because `FileDifference.relativePath` for
        // this fixture is the absolute path minus its first character. That field was the one thing
        // left un-relativised, which did not show while the fixture had a fixed directory name and
        // made the transcript unreproducible the moment it got a per-run one.
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

    /// **A `.leftOnly` refresh must not walk the right pane** — the saving itself, asserted rather
    /// than merely diffed.
    ///
    /// The transcript above measures it, but a transcript is a thing a person reads: a change that
    /// made `.leftOnly` quietly load both panes would show up there as a smaller diff and pass every
    /// test in the suite. Proven by changing the disk under the right pane and requiring the pane
    /// NOT to notice: a walk would pick the new file up, so still-7 is the only outcome that means
    /// "this pane was not walked".
    ///
    /// **Both directions**, because the two arms of the scope are separate code: a `.rightOnly`
    /// that walked the left would be invisible to a test that only ever moves the left pane, and
    /// Compare's right pane switches tabs exactly as often as its left one.
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

        // The disk changes under the pane that is NOT moving, and the prefetch cache goes with it —
        // so a walk genuinely would see the new file.
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

        // The control: a `.both` refresh picks the new file up, so the assertion above is about the
        // SCOPE and not about a fixture that could never change.
        await m.refreshTreesAndScan(left: left, right: right)
        #expect(stillCount() == countBefore + 1,
                "a full refresh missed a file that appeared on disk")
    }

    /// **A one-pane refresh must not cancel a two-pane one down to nothing.**
    ///
    /// `refreshTreesAndScan` supersedes whatever is in flight. That was safe while every refresh
    /// loaded both panes; a scoped one is not. Switching tabs while the launch load — or any scan,
    /// which runs about a second on a 39k-node tree — is still walking would cancel the right
    /// pane's load and start nothing in its place, leaving it blank. The scopes are unioned, so any
    /// disagreement with the refresh already running widens the new one to `.both`.
    @MainActor
    @Test func aScopedRefreshWidensRatherThanCancellingAWiderOne() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let m = FileSyncManager()
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder",
                                 rootPath: fixture.left.path, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder",
                                  rootPath: fixture.right.path, type: .localFolder)

        // Stand in for a `.both` refresh already in flight — the key is what the supersede logic
        // reads, and it is the only part of an in-flight refresh this decision depends on. Taken
        // BEFORE the pane moves, as the real one would have been.
        m.activeRefreshKey = m.makeRefreshKey(left: left, right: right, reloading: .both)

        // …then the tab switch: the left pane moves, so the new key differs and this supersedes
        // rather than dedupes. Without the union that is where the right pane's load is lost.
        m.focusOn(relativePath: "Finance/US", isLeft: true)
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly)

        #expect(!m.rightTree.isEmpty,
                "a one-pane refresh cancelled the two-pane one and left the other pane blank")
        #expect(!m.leftTree.isEmpty)
        #expect(m.rightItemCount > 0)
    }

    /// A left-pane tab switch, as the app performs one.
    ///
    /// **This is the only part of the driver the change touches**, and it is stated in one place so
    /// the diff is readable. Before: `invalidateComparisonState()` (both panes' trees) then a
    /// two-pane refresh. After: the moving pane's tree and the shared comparison, then a one-pane
    /// refresh. Steps 01 and 04–06 use byte-identical driver code across both runs — they are the
    /// controls, and they are what shows the change did not alter what a load or a scan produces.
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
    /// The last three steps are the ones that keep the optimisation honest: a file operation, a
    /// forced rescan and a sort change must each still rebuild BOTH panes. Every staleness source in
    /// this manager clears `prefetchedTrees` and nothing else — not the live tree, not the
    /// loaded-focus marker — so a "this pane already has that focus, skip it" shortcut would show
    /// pre-operation state here. That is why the change does not take one.
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

        // A tab switch on the LEFT pane, exactly as `applyTab` performs one: drop what the switch
        // invalidates, move the pane, then reload. This is the sequence the change alters.
        await tabSwitch(m, to: "Finance/US", left: left, right: right)
        record("02 left tab switch to Finance/US")

        await tabSwitch(m, to: "", left: left, right: right)
        record("03 left tab switch back to the root")

        // A file operation: the disk changed, so BOTH panes must rebuild.
        //
        // **It writes into the RIGHT root as well**, and that is the whole value of this step. The
        // first version touched only the left, so `right.itemCount` read 7 in every row of both
        // transcripts — the control would have passed with the right pane's reload deleted
        // outright, which is the one thing it exists to catch. A file only the moving pane can see
        // proves nothing about the pane standing still.
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
