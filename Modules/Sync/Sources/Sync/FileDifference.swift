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
    /// Whether the item on the LEFT is a folder, as the scan found it — `false` where the left has
    /// no item at all (a row missing on the left).
    ///
    /// **The folder fact, per side, and not `enclosedItemCount`.** That count is recorded only for
    /// a folder whose contents were collapsed into its row, so it is `nil` for an EMPTY folder
    /// missing on one side, for a pair of folders whose names differ only invisibly
    /// (`.nameConflict`), and for a folder-versus-file mismatch whose folder is empty; and where it
    /// is set it cannot say WHICH side is the folder — a folder-versus-file row has a real file on
    /// the other side. The engine knows both answers when it builds the row, so it records them.
    public let leftIsDirectory: Bool
    /// Whether the item on the RIGHT is a folder — see `leftIsDirectory`.
    public let rightIsDirectory: Bool
    /// Why no run may take this row's suggested `action` on the user's behalf, or nil when one may.
    ///
    /// **Every row carries a direction, and for some of them the direction is a guess.** The
    /// engine has to fill `action` in, and for most rows it has a reason — one side is missing, or
    /// one date is clearly later. For the rows below it has none it can stand behind, and a bulk
    /// run ("Copy N to →", `synccloud sync`) used to take the guess along with everything else:
    /// the user approved a count, and a guess inside it overwrote whichever side lost.
    ///
    /// A held row stays on the list with its note in `description`, is left out of every bulk run
    /// (`FileSyncManager.syncAll`, the CLI's `sync`), and is reported there as left out. A single
    /// row the user picks and copies on its own is their choice and goes ahead — except
    /// `.sourceIsSymbolicLink`, which no copy does right (`syncFile` refuses it).
    ///
    /// Not a `DifferenceType`: a held row is still a missing, differing or name-conflict row, and
    /// every filter, badge and sort keyed on that type should keep reading it as one.
    public let heldBack: HeldBack?

    /// The reasons a row's suggested direction cannot be taken unattended — see `heldBack`.
    public enum HeldBack: Equatable, Sendable {
        /// (FR39) Two files whose sizes differ while their dates match within the tolerance, or
        /// where a side has no date at all: nothing says which is newer, and the old default
        /// ("left as truth") overwrote the right on every bulk run — at the 5 s and 60 s
        /// tolerances, for any pair edited within that window of each other.
        case sizesDifferWithoutANewerSide
        /// (FR40) A folder against a file. A folder's own date is not when its contents last
        /// changed — a package edited yesterday inside can carry a 2024 folder date — so the two
        /// dates do not say which side is newer.
        case folderVersusFile
        /// (FR8) The side the row copies FROM is a symbolic link. The comparison reads a link as
        /// what it points to, but the copy writes the link itself (`ObservedCopy` stages with
        /// `COPYFILE_NOFOLLOW_SRC`): a "Folder missing" row of 300 items "copied" in an instant
        /// into one small link at the original, the next scan read both sides through it as in
        /// sync, and edits in "the copy" changed the originals.
        case sourceIsSymbolicLink
        /// (FR8) A folder missing on one side holds a symbolic link somewhere inside that points
        /// OUT of it — `path`, the first such link by relative path. The folder is one row (its
        /// contents collapse into it) and its copy is recursive, so the link inside is written as a
        /// link, for the reason `sourceIsSymbolicLink` gives. A link whose relative target stays
        /// inside the folder (a framework's `Versions/Current -> A`) is right copied as a link and
        /// holds nothing; an absolute or dangling one is out (`FileDiffEngine.linkLeads`). Unlike
        /// `sourceIsSymbolicLink`, a single deliberate copy goes ahead: everything else in the
        /// folder copies right.
        case enclosesSymbolicLink(path: String)
    }

    /// True when both sides report the same file size (and both are non-nil). Use for optional checksum verification.
    public var sizesMatch: Bool {
        guard let l = leftFileSize, let r = rightFileSize else { return false }
        return l == r
    }
    
    public init(id: UUID = UUID(), relativePath: String, leftItemPath: String, rightItemPath: String, type: DifferenceType, action: SyncAction, description: String, isSyncing: Bool = false, leftFileSize: Int? = nil, rightFileSize: Int? = nil, enclosedItemCount: Int? = nil, leftIsDirectory: Bool = false, rightIsDirectory: Bool = false, heldBack: HeldBack? = nil) {
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
        self.leftIsDirectory = leftIsDirectory
        self.rightIsDirectory = rightIsDirectory
        self.heldBack = heldBack
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
            enclosedItemCount: enclosedItemCount,
            leftIsDirectory: rightIsDirectory,
            rightIsDirectory: leftIsDirectory,
            // Side-neutral: a swap moves the source side and the action together, so a link is
            // still the side copied from and an undecided pair is still undecided.
            heldBack: heldBack
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
