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
    var tags: [String]?
    var kind: String?
}

extension FileNode: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

extension Array where Element == FileNode {
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
