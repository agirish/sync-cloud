import Foundation

/// Represents a computed discrepancy between the Left and Right providers for a single file path
public struct FileDifference: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let leftItemPath: String
    public let rightItemPath: String
    public let type: DifferenceType
    public let action: SyncAction
    public let description: String
    public var isSyncing: Bool = false
    
    public init(id: UUID = UUID(), relativePath: String, leftItemPath: String, rightItemPath: String, type: DifferenceType, action: SyncAction, description: String, isSyncing: Bool = false) {
        self.id = id
        self.relativePath = relativePath
        self.leftItemPath = leftItemPath
        self.rightItemPath = rightItemPath
        self.type = type
        self.action = action
        self.description = description
        self.isSyncing = isSyncing
    }
    
    public enum DifferenceType: Equatable, Sendable {
        case missingOnRight
        case missingOnLeft
        case differentDates
    }
    
    public enum SyncAction: Equatable, Sendable {
        case copyToRight
        case copyToLeft
    }
}
