import Foundation

/// An in-memory representation of a file or directory mapped from a local or cloud path.
/// Includes metadata used for UI display, sorting, and differential scanning.
public struct FileNode: Identifiable, Hashable, Codable, Sendable {
    /// The absolute path of the file or directory on the local filesystem.
    public let id: String
    /// The display name of the item.
    public let name: String
    /// True if the node represents a directory.
    public let isDirectory: Bool
    /// Optional array of child nodes if this node is a directory.
    public var children: [FileNode]?
    /// The last modified date, used for differential calculation in the Sync engine.
    public var modificationDate: Date?
    /// The file size in bytes.
    public var fileSize: Int?
    /// Custom metadata tags (e.g. from macOS Finder).
    public var tags: [String]?
    /// The human-readable file type or kind (e.g. "PNG image").
    public var kind: String?
    /// True when this is a directory whose children were NOT walked (the tree builder's
    /// symlink-cycle guard, its hard depth cap, or a depth-capped shallow pass stopped there).
    /// Its `children == []` is a construction artifact, not an observation — consumers that
    /// treat a subtree as authoritative (the prefetch cache's `subtree` slicing, and through
    /// it the in-memory diff) must treat such a node as a miss, never as an empty folder.
    /// Optional so JSON encoded before this field existed still decodes (nil = walked).
    public var isUnexplored: Bool?
    /// True when this entry is a symbolic link (its `fileSize`/`kind`/`isDirectory` describe the
    /// link's TARGET — the walk resolves them for display and diffing). The duplicate finder
    /// excludes symlinks: a link and its in-tree target otherwise hash identically and group as
    /// "copies," and trashing the real target would leave a dangling link as the "kept" copy.
    /// Optional so JSON encoded before this field existed still decodes (nil = not a link).
    public var isSymbolicLink: Bool?
    /// **True when this node's subtree is ALSO reached by a shorter route under the same walk
    /// root**, so anything that adds up the tree must count it once, here or there, never both.
    ///
    /// One shape produces it, and only one: a folder that a root links in from OUTSIDE
    /// (`PathBoundary.LinkedFolders` — iCloud Drive's `Desktop` and `Documents`) while the real
    /// folder is *itself* inside the walk root. Walk `~` and `~/Documents` arrives twice — once
    /// directly, once through the container — carrying the identical id both times, because the
    /// walk deliberately substitutes the link for the folder it points at.
    ///
    /// **`isSymbolicLink` cannot answer this**, which is why the field exists. The substituted node
    /// describes the REAL directory: its id is the real path and it is not a link, so flagging it
    /// as one would be a lie told to every consumer, including those that act on the path. Measured
    /// 2026-09-08 on a real machine — the container's children come back `sym=false` with real-path
    /// ids — and the cost of nothing marking them was a Storage total 10.5 GB over and a Duplicates
    /// group that offered to Trash `~/Documents` as a copy of itself.
    ///
    /// Consumers that SUM or GROUP the tree skip these (`StorageLensAnalyzer`, `DuplicateFinder`,
    /// `SelectionSummary`). Consumers that DISPLAY or navigate must not: the folder really is
    /// browsable at that spot, and the panes drew it long before this flag existed.
    /// Optional so JSON encoded before this field existed still decodes (nil = not a re-reach).
    public var isCoveredElsewhere: Bool?

    /// Initializes a new FileNode with optional metadata.
    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        children: [FileNode]? = nil,
        modificationDate: Date? = nil,
        fileSize: Int? = nil,
        tags: [String]? = nil,
        kind: String? = nil,
        isUnexplored: Bool? = nil,
        isSymbolicLink: Bool? = nil,
        isCoveredElsewhere: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.tags = tags
        self.kind = kind
        self.isUnexplored = isUnexplored
        self.isSymbolicLink = isSymbolicLink
        self.isCoveredElsewhere = isCoveredElsewhere
    }
}

extension Array where Element == FileNode {
    /// Recursively searches for all nodes matching the provided set of absolute path IDs.
    /// - Parameter paths: A set of absolute path IDs.
    /// - Returns: The matching `FileNode`s in pre-order.
    ///
    /// Stops walking once *every distinct requested path* has been matched at least once — a big
    /// win because this runs per render against panes of ~40k nodes (a full walk was ~100ms each
    /// in debug), and a 1-item selection now returns right after its match instead of visiting
    /// every node. Guarantees: no requested path present in the tree is ever dropped, and results
    /// stay pre-ordered. The exit is keyed on distinct paths (not `found.count`), so a tree with
    /// duplicate ids can't satisfy it early and skip a still-unmatched path. The only difference
    /// from an exhaustive walk is that a *trailing duplicate* of an already-matched id — which a
    /// real filesystem tree never produces (paths are unique) — may be omitted; harmless for the
    /// selection consumers, which act per path. A stale path absent from the tree keeps the exit
    /// from ever triggering, so it degrades to a full walk exactly as before.
    public func findNodes(at paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        var found: [FileNode] = []
        found.reserveCapacity(paths.count)
        var unmatched = paths
        _ = collectNodes(matching: paths, unmatched: &unmatched, into: &found)
        return found
    }

    /// Appends matching nodes in pre-order; `unmatched` shrinks as distinct ids are seen, and the
    /// walk unwinds as soon as it is empty (every requested path has a match). Nodes are still
    /// appended whenever their id is requested, so duplicates encountered before the walk
    /// completes are preserved.
    private func collectNodes(matching paths: Set<String>, unmatched: inout Set<String>, into found: inout [FileNode]) -> Bool {
        for node in self {
            if paths.contains(node.id) {
                found.append(node)
                unmatched.remove(node.id)
                if unmatched.isEmpty { return true }
            }
            if let children = node.children,
               children.collectNodes(matching: paths, unmatched: &unmatched, into: &found) {
                return true
            }
        }
        return false
    }
    
    /// Prunes nested nodes from a selection array, keeping only the highest-level parent nodes.
    /// This prevents duplicate operations (e.g., trying to move a child after its parent was already moved).
    public func pruneNestedNodes() -> [FileNode] {
        // Sort paths by length so parents come first.
        //
        // **By BYTES, not by Characters.** `String.count` is a grapheme count — an O(path) walk —
        // and a sort comparator runs it O(n log n) times rather than n, re-walking two full
        // absolute paths per comparison. `utf8.count` is O(1) on a native string and preserves the
        // ordering this depends on: an ancestor is strictly shorter in bytes too, because its path
        // is a byte prefix of its descendants'. Measured over 20,000 paths: 62ms against 17ms, 3.7x.
        // Reached on every transfer entry point.
        let sortedNodes = self.sorted { $0.id.utf8.count < $1.id.utf8.count }
        var pruned: [FileNode] = []
        var acceptedIds = Set<String>()
        acceptedIds.reserveCapacity(count)

        for node in sortedNodes {
            // Check if this node is a child of any already accepted parent
            if !node.id.isInsideDirectory(anyOf: acceptedIds) {
                pruned.append(node)
                acceptedIds.insert(node.id)
            }
        }
        return pruned
    }
}

extension String {
    /// True when the path lies inside one of the given directory paths, i.e. some prefix of it
    /// ending at a "/" separator is a member of `directories`. Equivalent to
    /// `directories.contains { hasPrefix($0 + "/") }` but O(path depth) instead of O(set size),
    /// so selection pruning stays linear-ish over large selections.
    func isInsideDirectory(anyOf directories: Set<String>) -> Bool {
        guard !directories.isEmpty else { return false }
        var searchStart = startIndex
        while let slash = self[searchStart...].firstIndex(of: "/") {
            if directories.contains(String(self[..<slash])) {
                return true
            }
            searchStart = index(after: slash)
        }
        return false
    }
}
