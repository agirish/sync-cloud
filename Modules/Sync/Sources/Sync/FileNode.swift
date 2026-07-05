import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// An in-memory representation of a file or directory mapped from a local or cloud path.
/// Includes metadata used for UI display, sorting, and differential scanning.
public struct FileNode: Identifiable, Hashable, Codable {
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
    
    /// Initializes a new FileNode with optional metadata.
    public init(
        id: String, 
        name: String, 
        isDirectory: Bool, 
        children: [FileNode]? = nil, 
        modificationDate: Date? = nil, 
        fileSize: Int? = nil, 
        tags: [String]? = nil, 
        kind: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.tags = tags
        self.kind = kind
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
    /// - Returns: An array of matching `FileNode` objects.
    public func findNodes(at paths: Set<String>) -> [FileNode] {
        var found: [FileNode] = []
        for node in self {
            if paths.contains(node.id) {
                found.append(node)
            }
            if let children = node.children {
                found.append(contentsOf: children.findNodes(at: paths))
            }
        }
        return found
    }
    
    /// Prunes nested nodes from a selection array, keeping only the highest-level parent nodes.
    /// This prevents duplicate operations (e.g., trying to move a child after its parent was already moved).
    public func pruneNestedNodes() -> [FileNode] {
        // Sort paths by length so parents come first
        let sortedNodes = self.sorted { $0.id.count < $1.id.count }
        var pruned: [FileNode] = []
        
        for node in sortedNodes {
            // Check if this node is a child of any already accepted parent
            let isChildOfAcceptedParent = pruned.contains { parent in
                node.id.hasPrefix(parent.id + "/")
            }
            if !isChildOfAcceptedParent {
                pruned.append(node)
            }
        }
        return pruned
    }
}
