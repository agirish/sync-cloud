import Foundation

/// Where a node sits in a walked tree is the names down to it from the walk's root, not its id.
///
/// The walk names most nodes by their parent's id plus their name, and two things break that:
/// - `contentsOfDirectory(at:)` returns symlink-resolved URLs for a folder reached through a link,
///   so ids follow the link from two levels below any folder symlink (`R/link → T` lists
///   `R/link/sub`, then `T/sub/deeper`), and from the first level under a root reached through one
///   (a root spelled `/var/…` lists `/private/var/…`);
/// - the walk lists a folder linked in from outside as the folder it points at
///   (`FileSyncManager.buildTree`; iCloud Drive's `Desktop` and `Documents`).
///
/// A path composed from a root and folder names (a pane's focus, every Columns directory) follows
/// this shape, so a lookup by id prefix misses wherever the two part. `FileDiffEngine.filesInfo`
/// and `PaneChildrenIndex` key by the same shape.
public enum TreeShape {

    /// The last component of `id`, as a slice of its storage — the node's name in the shape.
    ///
    /// Cut on the scalar view, where a boundary after a `/` is always exact; a name can open with a
    /// combining mark, so it isn't always a Character boundary. The id's leaf, not `FileNode.name`:
    /// the same bytes, but `name` stays bridged (`FileSyncManager.nativePath`), and comparing on it
    /// pays the bridge on every node.
    public static func leaf(of id: String) -> Substring {
        guard let slash = id.utf8.lastIndex(of: UInt8(ascii: "/")) else { return id[...] }
        return Substring(id.unicodeScalars[id.utf8.index(after: slash)...])
    }

    /// The directories `names` walks through from `nodes` down, outermost first; stops at the first
    /// name no directory answers to.
    public static func folders<Name: StringProtocol>(along names: [Name], in nodes: [FileNode]) -> [FileNode] {
        var chain: [FileNode] = []
        var level = nodes
        for name in names {
            guard let folder = level.first(where: { isFolder($0, named: name) }) else { break }
            chain.append(folder)
            level = folder.children ?? []
        }
        return chain
    }

    /// Where the directory at `path` sits in a tree walked at `root` — its index at each level,
    /// outermost first — or nil when the tree does not hold it as a directory.
    ///
    /// By the names down from `root` first: that is how a column composes its paths, and below a
    /// link it is the only thing that finds them. Failing that, by id prefix: the outline asks with
    /// a row's id, which still works where the walk spelled every id one way from the top. Either
    /// way the node found is the folder at `path`.
    static func position(of path: String, under root: String, in nodes: [FileNode],
                         links: PathBoundary.LinkedFolders) -> [Int]? {
        if let names = PathBoundary.relativize(path, under: root, links: links)?.split(separator: "/"),
           !names.isEmpty {
            var position: [Int] = []
            var level = nodes
            for name in names {
                guard let index = level.firstIndex(where: { isFolder($0, named: name) }) else { break }
                position.append(index)
                level = level[index].children ?? []
            }
            if position.count == names.count { return position }
        }
        var position: [Int] = []
        var level = nodes
        while let index = level.firstIndex(where: { $0.isDirectory && ($0.id == path || path.hasPrefix($0.id + "/")) }) {
            position.append(index)
            if level[index].id == path { return position }
            level = level[index].children ?? []
        }
        return nil
    }

    /// The node at `position` — which `position(of:under:in:links:)` found in these same `nodes`.
    static func node(at position: [Int], in nodes: [FileNode]) -> FileNode? {
        var level = nodes
        var node: FileNode?
        for index in position {
            guard level.indices.contains(index) else { return nil }
            node = level[index]
            level = level[index].children ?? []
        }
        return node
    }

    /// The names down `nodes` to the node whose id is `id`, outermost first, or nil when no node has
    /// it. A whole-tree search: below a link an id says nothing about which branch holds it.
    public static func names(downTo id: String, in nodes: [FileNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [String(leaf(of: node.id))] }
            if let children = node.children, let below = names(downTo: id, in: children) {
                return [String(leaf(of: node.id))] + below
            }
        }
        return nil
    }

    /// ``names(downTo:in:)`` for many ids in one walk: the names down to each id found, by id. A
    /// pane transfer asks this for many rows on the main actor, where a walk per row is too slow.
    /// Stops once every id is found.
    public static func names(downTo ids: Set<String>, in nodes: [FileNode]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        guard !ids.isEmpty else { return found }
        var trail: [String] = []
        func walk(_ level: [FileNode]) {
            for node in level {
                if found.count == ids.count { return }
                trail.append(String(leaf(of: node.id)))
                if ids.contains(node.id), found[node.id] == nil { found[node.id] = trail }
                if let children = node.children { walk(children) }
                trail.removeLast()
            }
        }
        walk(nodes)
        return found
    }

    private static func isFolder<Name: StringProtocol>(_ node: FileNode, named name: Name) -> Bool {
        node.isDirectory && leaf(of: node.id) == name
    }
}
