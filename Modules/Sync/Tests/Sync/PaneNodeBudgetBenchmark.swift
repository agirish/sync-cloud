import Foundation
import Testing
@testable import Sync

/// What `paneNodeBudget` costs, measured on a real oversized tree. This is where the numbers in
/// the budget's doc comment come from.
///
/// Inert unless `SYNCCLOUD_BUDGET_BENCHMARK` names a root (tilde allowed), so an ordinary
/// `swift test` and CI never walk somebody's home folder:
///
/// ```sh
/// SYNCCLOUD_BUDGET_BENCHMARK="~" swift test -c release --filter PaneNodeBudgetBenchmark
/// ```
///
/// `.serialized` for `TreeWalkBenchmark`'s reason: a benchmark must be the only thing running.
@Suite(.serialized) struct PaneNodeBudgetBenchmark {

    private static var root: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SYNCCLOUD_BUDGET_BENCHMARK"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    private static func count(_ nodes: [FileNode]) -> (total: Int, unexplored: Int) {
        var total = 0, unexplored = 0
        func visit(_ node: FileNode) {
            total += 1
            if node.isDirectory, node.isUnexplored == true { unexplored += 1 }
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
        return (total, unexplored)
    }

    /// A capped walk of an unbounded tree finishes in seconds. On a ~200,000-directory home folder,
    /// warm cache, Release, the production budget of 200,000 took about 1.3 s with ~0.2% overshoot,
    /// where an unbounded walk did not finish in ten minutes. A cold cache is slower.
    ///
    /// The overshoot grows with the budget (up to 12.7% at 400,000): more subtrees are in flight
    /// when it runs out. Re-measure before raising `paneNodeBudget`. Printed, not asserted: a
    /// wall-clock threshold on a shared machine is a flake.
    @Test func aCappedWalkOfAnUnboundedTreeFinishesInSeconds() async throws {
        guard let root = Self.root else { return }
        for limit in [FileSyncManager.paneNodeBudget, 50_000, 400_000] {
            let start = Date()
            let tree = await FileSyncManager.buildTree(url: root, sortOption: .name, budget: .init(limit))
            let elapsed = Date().timeIntervalSince(start)
            let c = Self.count(tree)
            print(String(format: "[budget] limit %7d → %7d nodes (%6d unexplored) in %6.2f s",
                         limit, c.total, c.unexplored, elapsed))
        }
    }

    /// The whole deferred path on a real tree. The budget and the graft are unit-tested on fixtures,
    /// but only a tree big enough for the budget to engage shows they compose: walk at the
    /// production budget, list a directory the walk stopped at as `loadColumnChildren` does, graft
    /// it, and check it came back filled and unmarked.
    @Test func aBudgetedOutDirectoryFillsInWhenAColumnAsksForIt() async throws {
        guard let root = Self.root else { return }
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name,
                                                   budget: .init(FileSyncManager.paneNodeBudget))

        // Pick a stopped directory that is readable: the budget marks unreadable ones the same way,
        // and grafting one correctly does nothing. Its path is built from the root and the names
        // down to it, the way a column asks for it.
        var target: String?
        func find(_ nodes: [FileNode], in directory: String) {
            for node in nodes where target == nil {
                let path = directory + "/" + TreeShape.leaf(of: node.id)
                if node.isDirectory, node.isUnexplored == true,
                   (try? FileManager.default.contentsOfDirectory(atPath: node.id).isEmpty) == false {
                    target = path
                } else if node.isDirectory {
                    find(node.children ?? [], in: path)
                }
            }
        }
        find(tree, in: root.path)
        let path = try #require(target, "the walk left no readable directory unexplored — nothing to graft")
        print("[budget] grafting “\(path)”")

        #expect(FileSyncManager.isUnexplored(atPath: path, under: root.path, in: tree),
                "the guard disagrees with the walk about what was left unread")

        let children = await FileSyncManager.buildTree(url: URL(fileURLWithPath: path),
                                                       sortOption: .name, maxDepth: 1)
        let filled = try #require(FileSyncManager.grafting(children: children, atPath: path, under: root.path,
                                                           into: tree),
                                  "the graft could not find a path the same walk produced")
        #expect(!FileSyncManager.isUnexplored(atPath: path, under: root.path, in: filled),
                "the directory is still marked unread after being filled — the column would ask forever")
        let position = try #require(TreeShape.position(of: path, under: root.path, in: filled,
                                                       links: PathBoundary.discoveredLinkedFolders))
        let grafted = try #require(TreeShape.node(at: position, in: filled))
        #expect(grafted.children?.isEmpty == false, "the graft landed but the directory came back empty")
        print("[budget] filled \(grafted.children?.count ?? 0) entries")
    }

    /// The overshoot is bounded. Exhaustion is checked before a directory is listed, so the walk
    /// can exceed its limit only by work already committed, never by another descent.
    @Test func theWalkStopsNearItsBudgetRatherThanRunningOn() async throws {
        guard let root = Self.root else { return }
        let limit = 50_000
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name, budget: .init(limit))
        let c = Self.count(tree)
        print("[budget] overshoot check: \(c.total) nodes against a \(limit) limit")
        #expect(c.total < limit * 4,
                "the walk produced \(c.total) nodes against a \(limit) budget — the pre-listing check is not stopping descents")
        #expect(c.unexplored > 0, "nothing came back unexplored — the budget never engaged, so this measured nothing")
    }
}
