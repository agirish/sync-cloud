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
    /// True when this is a directory whose children were not walked (the symlink-cycle guard, the
    /// depth cap, or a shallow pass stopped there). Its `children == []` is not an observation:
    /// anything that trusts a subtree (the prefetch cache's `subtree` slicing, and through it the
    /// in-memory diff) must treat it as a miss, never as an empty folder.
    /// Optional so older JSON still decodes (nil = walked).
    public var isUnexplored: Bool?
    /// True when this entry is a symbolic link; its `fileSize`, `kind` and `isDirectory` describe
    /// the target. The duplicate finder excludes links: a link and its target hash alike, and
    /// trashing the target would leave a dangling link as the "kept" copy.
    /// Optional so older JSON still decodes (nil = not a link).
    public var isSymbolicLink: Bool?
    /// True when this node's subtree is also reached by a shorter route under the same walk root,
    /// so anything that adds up the tree must count it once, never twice.
    ///
    /// Only one shape produces it: a folder a root links in from outside
    /// (`PathBoundary.LinkedFolders`, iCloud Drive's `Desktop` and `Documents`) whose real folder is
    /// inside the walk root too. Walk `~` and `~/Documents` arrives twice with the same id, since
    /// the walk substitutes the real folder for the link. `isSymbolicLink` can't mark it: the node
    /// is the real directory, not a link.
    ///
    /// Consumers that sum or group the tree skip these (`StorageLensAnalyzer`, `DuplicateFinder`,
    /// `SelectionSummary`); unmarked, Storage counts the folder twice and Duplicates offers to Trash
    /// `~/Documents` as a copy of itself. Consumers that display or navigate must not skip them.
    /// Optional so older JSON still decodes (nil = not a re-reach).
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

    /// True when this directory is a package: a `.pages`, `.key`, `.app` or `.photoslibrary` that
    /// is a folder on disk and one document to the user.
    ///
    /// Read off ``kind`` rather than stored, so trees cached as JSON before a stored flag existed
    /// still answer. It agrees with `.isPackageKey` on the common package types; neither sees a
    /// plain folder carrying only Finder's bundle bit. Walks still go inside packages, so consumers
    /// that group or move pieces of a tree must ask (`DuplicateFinder`).
    public var isPackage: Bool {
        guard isDirectory, let kind, kind != "public.folder" else { return false }
        return UTType(kind)?.conforms(to: .package) == true
    }
}

extension Array where Element == FileNode {
    /// Recursively searches for all nodes matching the provided set of absolute path IDs.
    /// - Parameter paths: A set of absolute path IDs.
    /// - Returns: The matching `FileNode`s in pre-order.
    ///
    /// Stops once every distinct requested path has matched, since this runs per render over panes
    /// of ~40k nodes. Keyed on distinct paths, not `found.count`, so duplicate ids can't end it
    /// early. A trailing duplicate of a matched id may be omitted, which a real tree never has. A
    /// stale path absent from the tree means a full walk.
    public func findNodes(at paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        var found: [FileNode] = []
        found.reserveCapacity(paths.count)
        var unmatched = paths
        _ = collectNodes(matching: paths, unmatched: &unmatched, into: &found)
        return found
    }

    /// Appends matching nodes in pre-order and unwinds once `unmatched` is empty. Duplicates met
    /// before then are kept.
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
        // Sort by length so parents come first. By bytes: `utf8.count` is O(1), while `String.count`
        // walks graphemes on every comparison. An ancestor is a byte prefix, so it still sorts first.
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
