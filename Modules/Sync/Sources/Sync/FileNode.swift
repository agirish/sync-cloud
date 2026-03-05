import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// An in-memory representation of a file or directory mapped from a local or cloud path
public struct FileNode: Identifiable, Hashable, Codable {
    public let id: String // Absolute path
    public let name: String
    public let isDirectory: Bool
    public var children: [FileNode]?
    public var modificationDate: Date?
    public var fileSize: Int?
    public var tags: [String]?
    public var kind: String?
    
    public init(id: String, name: String, isDirectory: Bool, children: [FileNode]? = nil, modificationDate: Date? = nil, fileSize: Int? = nil, tags: [String]? = nil, kind: String? = nil) {
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
    /// Recursively searches for a node with the specified absolute path.
    /// - Parameter path: The absolute path ID to search for.
    /// - Returns: The found `FileNode` or nil if not found.
    func findNode(at path: String?) -> FileNode? {
        guard let path = path else { return nil }
        for node in self {
            if node.id == path { return node }
            if let children = node.children, let found = children.findNode(at: path) {
                return found
            }
        }
        return nil
    }
    
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
}
