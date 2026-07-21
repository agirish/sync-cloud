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
    /// File size on the left side (bytes). Used to show "Verify with checksum" when same as right.
    public let leftFileSize: Int?
    /// File size on the right side (bytes).
    public let rightFileSize: Int?
    /// For a folder missing on one side: how many items it contains, all of which sync with the
    /// folder itself (folder copies are recursive, so they are not listed as separate differences).
    public let enclosedItemCount: Int?
    
    /// True when both sides report the same file size (and both are non-nil). Use for optional checksum verification.
    public var sizesMatch: Bool {
        guard let l = leftFileSize, let r = rightFileSize else { return false }
        return l == r
    }
    
    public init(id: UUID = UUID(), relativePath: String, leftItemPath: String, rightItemPath: String, type: DifferenceType, action: SyncAction, description: String, isSyncing: Bool = false, leftFileSize: Int? = nil, rightFileSize: Int? = nil, enclosedItemCount: Int? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.leftItemPath = leftItemPath
        self.rightItemPath = rightItemPath
        self.type = type
        self.action = action
        self.description = description
        self.isSyncing = isSyncing
        self.leftFileSize = leftFileSize
        self.rightFileSize = rightFileSize
        self.enclosedItemCount = enclosedItemCount
    }
    
    /// Describes how the two panes differ for this path.
    public enum DifferenceType: Equatable, Sendable {
        /// Item exists on the left pane but is missing on the right.
        case missingOnRight
        /// Item exists on the right pane but is missing on the left.
        case missingOnLeft
        /// Item exists on both sides but has different modification dates or sizes.
        case differentDates
        /// Item exists on both sides under names that differ only invisibly (trailing or
        /// leading whitespace, trailing dots, or Unicode NFC/NFD form) — typically because
        /// one provider's server normalizes names the other stores verbatim. Copying such a
        /// pair as "missing" would mint an identical-looking duplicate the stricter provider
        /// can never upload, so the pair is surfaced as a single conflict instead; its item
        /// paths point at both REAL items, so a sync targets the existing counterpart (a
        /// normal collision) rather than a doppelganger.
        case nameConflict

        /// The same discrepancy as seen after the panes trade sides.
        public var mirrored: DifferenceType {
            switch self {
            case .missingOnRight: return .missingOnLeft
            case .missingOnLeft: return .missingOnRight
            case .differentDates: return .differentDates
            case .nameConflict: return .nameConflict
            }
        }
    }

    /// Recommended direction to sync this item.
    public enum SyncAction: Equatable, Sendable {
        /// Copy from the left pane to the right pane.
        case copyToRight
        /// Copy from the right pane to the left pane.
        case copyToLeft

        /// The same sync direction as seen after the panes trade sides.
        public var mirrored: SyncAction {
            switch self {
            case .copyToRight: return .copyToLeft
            case .copyToLeft: return .copyToRight
            }
        }
    }

    /// This difference as seen after the panes trade sides: paths, sizes, type, action, and
    /// the description's side-relative wording all flip. The `id` is preserved — the item on
    /// disk is the same, so row identity (table selection) and checksum-verification results
    /// (content equality is symmetric) both survive a pane swap.
    public func mirrored() -> FileDifference {
        FileDifference(
            id: id,
            relativePath: relativePath,
            leftItemPath: rightItemPath,
            rightItemPath: leftItemPath,
            type: type.mirrored,
            action: action.mirrored,
            // A .nameConflict description is side-neutral by construction — it quotes both
            // leaf names PRECISELY (showing exact spellings is its purpose) and provider
            // names travel with their files through a swap. The side-phrase rewrite must not
            // touch it: a quoted file name containing "on right" would be rewritten into a
            // name that doesn't exist, on the one row type built to show exact names.
            description: type == .nameConflict ? description : Self.mirroredDescription(description),
            isSyncing: isSyncing,
            leftFileSize: rightFileSize,
            rightFileSize: leftFileSize,
            enclosedItemCount: enclosedItemCount
        )
    }

    /// Absolute path of the item on the side this difference's `action` copies FROM
    /// (left for `.copyToRight`, right for `.copyToLeft`). Single source of truth for the
    /// side selection duplicated across sync error reporting and URL derivation.
    var sourceItemPath: String {
        action == .copyToRight ? leftItemPath : rightItemPath
    }

    /// Source and destination URLs for resolving this difference in its `action` direction.
    var transferURLs: (from: URL, to: URL) {
        action == .copyToRight
            ? (URL(fileURLWithPath: leftItemPath), URL(fileURLWithPath: rightItemPath))
            : (URL(fileURLWithPath: rightItemPath), URL(fileURLWithPath: leftItemPath))
    }

    /// The two compared folders this difference's transfer runs between, in `action` direction:
    /// each item path minus the shared root-relative suffix. This names the panes' focused
    /// folders (what the user is looking at), where the item's immediate parent could be an
    /// arbitrarily deep subfolder of them. Falls back to the immediate parents if an item path
    /// doesn't end in `relativePath` (never true for engine-built differences).
    var transferContainers: (from: String, to: String) {
        let urls = transferURLs
        func container(of path: String) -> String {
            guard path.hasSuffix("/" + relativePath) else {
                return (path as NSString).deletingLastPathComponent
            }
            let stripped = String(path.dropLast(relativePath.count + 1))
            // A pane rooted at the filesystem root strips to "": "/a.txt" minus "/a.txt".
            // Blank From/To lines (and `to ""` in the prompt title) would be worse than "/".
            return stripped.isEmpty ? "/" : stripped
        }
        return (container(of: urls.from.path), container(of: urls.to.path))
    }

    /// Flips the side-relative wording in a description ("Missing on right (iCloud)" →
    /// "Missing on left (iCloud)"). Provider display names travel with their files in a swap,
    /// so they stay correct untouched; only "on left"/"on right" phrases are side-relative,
    /// and no description generated by `FileDiffEngine` ever mentions both sides, so a single
    /// one-way replacement is exact.
    static func mirroredDescription(_ description: String) -> String {
        if description.contains("on right") {
            return description.replacingOccurrences(of: "on right", with: "on left")
        }
        if description.contains("on left") {
            return description.replacingOccurrences(of: "on left", with: "on right")
        }
        return description
    }
}
