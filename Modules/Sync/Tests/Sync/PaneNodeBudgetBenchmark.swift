import Foundation
import Testing
@testable import Sync

/// **What `paneNodeBudget` actually costs, measured on a real oversized tree.**
///
/// The budget's whole justification is a pair of numbers — how big the trees that hang the app
/// are, and how long the capped walk takes — and a number that lives in a doc comment rather than
/// in test output has not been checked. This is where the comment's claims come from.
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

    /// The budget's headline claim: a capped walk of an unbounded tree finishes in seconds.
    ///
    /// Measured on `~` (196,726 directories), warm cache, Release, 2026-08-24 — two runs, both
    /// reported because they disagree in a way worth keeping:
    ///
    /// | limit   | nodes             | wall          | overshoot     |
    /// |---------|-------------------|---------------|---------------|
    /// | 50,000  | 50,547 / 50,075   | 0.25s / 0.25s | 1.1% / 0.15%  |
    /// | 200,000 | 200,399 / 200,468 | 1.31s / 1.25s | 0.20% / 0.23% |
    /// | 400,000 | 400,687 / 450,834 | 2.29s / 2.53s | 0.17% / 12.7% |
    ///
    /// **The overshoot grows with the budget**, and the 400,000 row is where it shows: a bigger
    /// budget survives longer into the fan-out, so more subtrees are in flight at the moment it
    /// runs out and more committed levels finish. At the production budget it is a fifth of a
    /// percent across both runs. Anyone raising `paneNodeBudget` should re-measure this column
    /// rather than assume it stays proportional.
    ///
    /// Warm is stated because it is warm — a first click after boot reads a cold cache and will be
    /// slower. It is the right comparison anyway: the unbounded walk this replaces did not finish
    /// in ten minutes on the same tree, warm.
    ///
    /// Reported rather than asserted against a wall-clock threshold — a timing assertion on a
    /// shared machine is a flake, and the point here is the record, not a gate.
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

    /// **The whole deferred path, against the real tree that prompted it.**
    ///
    /// The budget and the graft are unit-tested separately on fixtures; what neither can show is
    /// that they compose on a tree big enough for the budget to engage — a fixture that large is
    /// not a fixture. This walks `~` at the production budget, finds a directory the walk stopped
    /// at, lists it the way `loadColumnChildren` does, grafts it, and checks it came back filled
    /// and unmarked.
    @Test func aBudgetedOutDirectoryFillsInWhenAColumnAsksForIt() async throws {
        guard let root = Self.root else { return }
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name,
                                                   budget: .init(FileSyncManager.paneNodeBudget))

        // Pick a stopped directory that is actually readable — the budget marks unreadable ones
        // identically, and grafting one of those is the case that correctly does nothing.
        var target: String?
        func find(_ nodes: [FileNode]) {
            for node in nodes where target == nil {
                if node.isDirectory, node.isUnexplored == true,
                   (try? FileManager.default.contentsOfDirectory(atPath: node.id).isEmpty) == false {
                    target = node.id
                } else if node.isDirectory {
                    find(node.children ?? [])
                }
            }
        }
        find(tree)
        let path = try #require(target, "the walk left no readable directory unexplored — nothing to graft")
        print("[budget] grafting “\(path)”")

        #expect(FileSyncManager.isUnexplored(atPath: path, in: tree),
                "the guard disagrees with the walk about what was left unread")

        let children = await FileSyncManager.buildTree(url: URL(fileURLWithPath: path),
                                                       sortOption: .name, maxDepth: 1)
        let filled = try #require(FileSyncManager.grafting(children: children, atPath: path, into: tree),
                                  "the graft could not find a path the same walk produced")
        #expect(!FileSyncManager.isUnexplored(atPath: path, in: filled),
                "the directory is still marked unread after being filled — the column would ask forever")
        let grafted = try #require(Self.node(atPath: path, in: filled))
        #expect(grafted.children?.isEmpty == false, "the graft landed but the directory came back empty")
        print("[budget] filled \(grafted.children?.count ?? 0) entries")
    }

    private static func node(atPath path: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes where node.isDirectory {
            if node.id == path { return node }
            if path.hasPrefix(node.id + "/"),
               let found = Self.node(atPath: path, in: node.children ?? []) {
                return found
            }
        }
        return nil
    }

    /// **The overshoot is bounded, and this is what bounds it.** Exhaustion is checked before a
    /// directory is listed, so subtrees already in flight finish the level they are on — the walk
    /// can exceed its limit, but only by the work already committed, never by another descent.
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
