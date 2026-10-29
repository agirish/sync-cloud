import Testing
import Foundation
@testable import Sync

/// **`pruneSelection` looks the selection up in the per-version path index** (speed audit item 8)
/// rather than collecting every path in the tree into a set of its own. These pin that the answer
/// did not move: the same pruned selection as the full walk it replaced, on generated trees, and
/// never an answer about a tree that has since been replaced.
@MainActor
@Suite struct PruneSelectionIndexTests {

    /// A deterministic tree of folders and files, `width` per level and `depth` levels deep.
    private static func tree(root: String, width: Int, depth: Int, drop: (String) -> Bool = { _ in false }) -> [FileNode] {
        func level(_ parent: String, _ remaining: Int) -> [FileNode] {
            (0..<width).compactMap { i in
                let isDirectory = remaining > 1 && i % 2 == 0
                let path = "\(parent)/\(isDirectory ? "dir" : "file")\(i)"
                guard !drop(path) else { return nil }
                return FileNode(id: path, name: (path as NSString).lastPathComponent,
                                isDirectory: isDirectory,
                                children: isDirectory ? level(path, remaining - 1) : nil)
            }
        }
        return level(root, depth)
    }

    private static func allPaths(_ nodes: [FileNode]) -> [String] {
        nodes.flatMap { [$0.id] + allPaths($0.children ?? []) }
    }

    /// The rule the index replaced, kept here as the reference: every path in the tree, collected.
    private static func referencePrune(_ selection: Set<String>, in tree: [FileNode]) -> Set<String> {
        let all = Set(allPaths(tree))
        return selection.filter { all.contains($0) }
    }

    @Test func prunesExactlyAsTheFullWalkDid() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<20 {
            let manager = FileSyncManager()
            let before = Self.tree(root: "/l\(trial)", width: 6, depth: 4)
            let paths = Self.allPaths(before)
            // Drop a random tenth of the tree — a deleted folder takes its whole subtree with it.
            let dropped = Set(paths.filter { _ in Int.random(in: 0..<10, using: &rng) == 0 })
            let after = Self.tree(root: "/l\(trial)", width: 6, depth: 4, drop: dropped.contains)
            var selection = Set(paths.filter { _ in Bool.random(using: &rng) })
            selection.insert("/l\(trial)/never-there")
            manager.leftTree = before
            // The action bar's read, so the index for the OLD tree is cached before the publish.
            _ = manager.leftNodes(for: selection)
            manager.selectedLeftPaths = selection
            manager.leftTree = after

            manager.pruneSelection()

            let expected = Self.referencePrune(selection, in: after)
            #expect(manager.selectedLeftPaths == expected, "trial \(trial)")
            // The fixture really removed something, or the comparison proves nothing.
            #expect(expected.count < selection.count, "trial \(trial) pruned nothing")
        }
    }

    /// The index is cached against the published tree version; a prune after a publish must see
    /// the new tree, on both sides, even when the old tree’s index was the last one built.
    @Test func neverPrunesAgainstAReplacedTree() {
        let manager = FileSyncManager()
        let a = FileNode(id: "/r/a.txt", name: "a.txt", isDirectory: false)
        let b = FileNode(id: "/r/b.txt", name: "b.txt", isDirectory: false)
        manager.rightTree = [a]
        _ = manager.rightNodes(for: ["/r/a.txt"])        // index built for a tree without b
        manager.rightTree = [a, b]                       // b arrives
        manager.selectedRightPaths = ["/r/a.txt", "/r/b.txt"]
        manager.pruneSelection()
        #expect(manager.selectedRightPaths == ["/r/a.txt", "/r/b.txt"],
                "a path the new tree holds was pruned against the old tree's index")

        manager.rightTree = [b]                          // a leaves
        manager.pruneSelection()
        #expect(manager.selectedRightPaths == ["/r/b.txt"])
    }
}
