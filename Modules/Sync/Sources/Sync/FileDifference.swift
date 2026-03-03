import Foundation

/// Represents a computed discrepancy between the Source and Destination providers for a single file paths
public struct FileDifference: Identifiable, Equatable {
    public let id: UUID
    public let relativePath: String
    public let sourceItemPath: String
    public let destinationItemPath: String
    public let type: DifferenceType
    public let action: SyncAction
    public let description: String
    public var isSyncing: Bool = false
    
    public init(id: UUID = UUID(), relativePath: String, sourceItemPath: String, destinationItemPath: String, type: DifferenceType, action: SyncAction, description: String, isSyncing: Bool = false) {
        self.id = id
        self.relativePath = relativePath
        self.sourceItemPath = sourceItemPath
        self.destinationItemPath = destinationItemPath
        self.type = type
        self.action = action
        self.description = description
        self.isSyncing = isSyncing
    }
    
    public enum DifferenceType: Equatable {
        case missingInDestination
        case missingInSource
        case differentDates
    }
    
    public enum SyncAction: Equatable {
        case copyToDestination
        case copyToSource
    }
}
