import Foundation

/// Options for resolving file naming collisions during transfers.
public enum CollisionResolution: Sendable {
    case replace
    case keepBoth
    case skip
}

/// Everything a collision prompt needs to say WHAT collided and WHERE — the bare file name
/// alone can't tell the user which copy of "Resume.docx" is being written over which.
/// Grown as a struct (not more closure parameters) so the resolver seams stop churning
/// every test stub each time the prompt learns a new fact.
public struct FileCollision: Sendable {
    /// Name of the colliding item (last path component of `destinationPath`).
    public let fileName: String
    /// Absolute path of the item being copied or moved.
    public let sourcePath: String
    /// Absolute path of the existing destination item that would be replaced.
    public let destinationPath: String
    /// True for a move, false for a copy (selects the prompt's verb).
    public let isMove: Bool
    /// Whether the colliding DESTINATION item is a folder, so the prompt can warn that
    /// replacing a folder replaces its entire contents.
    public let isDirectory: Bool

    public init(sourcePath: String, destinationPath: String, isMove: Bool, isDirectory: Bool) {
        self.fileName = (destinationPath as NSString).lastPathComponent
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.isMove = isMove
        self.isDirectory = isDirectory
    }
}

/// What a copy/move confirmation prompt describes before any I/O starts: the verb, how many
/// items, and the two folders involved. Built by the engine at each transfer entry point
/// (`transferItems`, `syncFile`, `syncAll`) and handed to the `transferConfirmer` seam.
public struct TransferSummary: Sendable {
    /// True for a move, false for a copy.
    public let isMove: Bool
    /// Number of items the operation will process (after nested-selection pruning).
    public let itemCount: Int
    /// Name of the first item, so a single-item prompt can name it.
    public let firstItemName: String
    /// Absolute path of the folder the items come from (the first item's parent for
    /// mixed-folder selections — representative, not exhaustive).
    public let sourceDirectory: String
    /// Absolute path of the folder the items land in.
    public let destinationDirectory: String

    public init(isMove: Bool, itemCount: Int, firstItemName: String, sourceDirectory: String, destinationDirectory: String) {
        self.isMove = isMove
        self.itemCount = itemCount
        self.firstItemName = firstItemName
        self.sourceDirectory = sourceDirectory
        self.destinationDirectory = destinationDirectory
    }
}
