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
    /// Absolute path of the item being copied or moved.
    public let sourcePath: String
    /// Absolute path of the existing destination item that would be replaced.
    public let destinationPath: String
    /// True for a move, false for a copy (selects the prompt's verb).
    public let isMove: Bool
    /// Whether the colliding DESTINATION item is a folder, so the prompt can warn that
    /// replacing a folder replaces its entire contents.
    public let isDirectory: Bool

    /// Name of the colliding item. Computed, not stored, so no future initializer or
    /// decoding path can ever set it inconsistently with `destinationPath` — the alert
    /// title must always name the same file the Replacing: line shows.
    public var fileName: String {
        (destinationPath as NSString).lastPathComponent
    }

    public init(sourcePath: String, destinationPath: String, isMove: Bool, isDirectory: Bool) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.isMove = isMove
        self.isDirectory = isDirectory
    }
}

/// Everything the invalid-destination-name prompt needs to say: which name the destination
/// provider forbids, why, and the sanitized name the operation can use instead. Built by
/// `FileSyncManager.checkDestinationName` before any I/O and handed to the
/// `invalidNameResolver` seam.
public struct NameViolationPrompt: Sendable {
    /// The offending path component, verbatim (may be an ancestor folder, not just the leaf).
    public let itemName: String
    /// A nearby name the provider accepts (see `ProviderNameRules.sanitized(name:for:)`).
    public let sanitizedName: String
    /// Display name of the destination provider whose rules reject the name.
    public let providerName: String
    /// Human-readable reason, e.g. "Dropbox doesn't allow names ending with a space."
    public let reason: String
    /// Absolute path the operation was about to write.
    public let destinationPath: String
    /// True for a move, false for a copy (selects the prompt's verb).
    public let isMove: Bool

    public init(itemName: String, sanitizedName: String, providerName: String, reason: String, destinationPath: String, isMove: Bool) {
        self.itemName = itemName
        self.sanitizedName = sanitizedName
        self.providerName = providerName
        self.reason = reason
        self.destinationPath = destinationPath
        self.isMove = isMove
    }
}

/// The user's answer to a `NameViolationPrompt`.
public enum InvalidNameResolution: Sendable {
    /// Write under the sanitized name instead (an existing item there then goes through the
    /// normal collision flow).
    case useSanitizedName
    /// Write the invalid name anyway (the provider will keep the item local-only).
    case keepOriginalName
    /// Don't write this item at all.
    case skip
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
