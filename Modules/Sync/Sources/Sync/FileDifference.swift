import Foundation

/// A single file or folder that differs between the two comparison panes (left and right).
/// Used by the diff engine and UI to list discrepancies and drive sync actions (copy to left/right).
public struct FileDifference: Identifiable, Equatable, Sendable {
    /// Unique identifier for this difference (e.g. for tracking sync state in the UI).
    public let id: UUID
    /// Path relative to the pane root (same for both sides).
    public let relativePath: String
    /// Absolute filesystem path of the item on the left pane.
    public let leftItemPath: String
    /// Absolute filesystem path of the item on the right pane.
    public let rightItemPath: String
    /// Kind of discrepancy (missing on one side, or different dates/sizes).
    public let type: DifferenceType
    /// Recommended sync action to resolve the difference.
    public let action: SyncAction
    /// Human-readable description for the UI (e.g. "Missing on right (iCloud)").
    public let description: String
    /// Whether a sync for this item is currently in progress.
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
    
    /// Describes how the two panes differ for this path.
    public enum DifferenceType: Equatable, Sendable {
        /// Item exists on the left pane but is missing on the right.
        case missingOnRight
        /// Item exists on the right pane but is missing on the left.
        case missingOnLeft
        /// Item exists on both sides but has different modification dates or sizes.
        case differentDates
    }

    /// Recommended direction to sync this item.
    public enum SyncAction: Equatable, Sendable {
        /// Copy from the left pane to the right pane.
        case copyToRight
        /// Copy from the right pane to the left pane.
        case copyToLeft
    }
}
