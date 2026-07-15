import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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
    /// Optional so drag payloads encoded before this field existed still decode (nil = walked).
    public var isUnexplored: Bool?

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
        isUnexplored: Bool? = nil
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
    }
}

extension FileNode: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

extension Array where Element == FileNode {
    /// Recursively searches for all nodes matching the provided set of absolute path IDs.
    /// - Parameter paths: A set of absolute path IDs.
    /// - Returns: An array of matching `FileNode` objects, in pre-order.
    ///
    /// Stops as soon as every requested path has been found. The result is identical to a full
    /// walk whenever the paths all exist in the tree (the common case — a selection is a subset
    /// of the visible nodes), so this is a pure speed-up, not a behavior change. It matters a
    /// lot: this runs per render against panes of ~40k nodes, and a full walk was ~100ms each —
    /// with a 1-item selection the early exit returns after the first match instead of visiting
    /// every node. A stale path not present in the tree still degrades to a full walk (found <
    /// requested, so the exit never triggers), exactly as before.
    public func findNodes(at paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        var found: [FileNode] = []
        found.reserveCapacity(paths.count)
        _ = collectNodes(matching: paths, into: &found)
        return found
    }

    /// Appends matching nodes in pre-order; returns `true` once `found` holds one node per
    /// requested path so callers can unwind the recursion immediately.
    private func collectNodes(matching paths: Set<String>, into found: inout [FileNode]) -> Bool {
        for node in self {
            if paths.contains(node.id) {
                found.append(node)
                if found.count == paths.count { return true }
            }
            if let children = node.children,
               children.collectNodes(matching: paths, into: &found) {
                return true
            }
        }
        return false
    }
    
    /// Prunes nested nodes from a selection array, keeping only the highest-level parent nodes.
    /// This prevents duplicate operations (e.g., trying to move a child after its parent was already moved).
    public func pruneNestedNodes() -> [FileNode] {
        // Sort paths by length so parents come first
        let sortedNodes = self.sorted { $0.id.count < $1.id.count }
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
