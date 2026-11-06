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
    /// Each side's modification date as the scan read it, nil where that side has no item (or
    /// the provider reported none). Kept so an answer can say how much newer a side is.
    public let leftModified: Date?
    public let rightModified: Date?
    /// For a folder missing on one side: how many items it contains, all of which sync with the
    /// folder itself (folder copies are recursive, so they are not listed as separate differences).
    public let enclosedItemCount: Int?
    /// Whether the item on the left is a folder, as the scan found it; `false` where the left has
    /// no item. Ask this, not `enclosedItemCount`: that count is nil for an empty folder and for a
    /// `.nameConflict` folder pair, and can't say which side of a folder-versus-file row is which.
    public let leftIsDirectory: Bool
    /// Whether the item on the right is a folder; see `leftIsDirectory`.
    public let rightIsDirectory: Bool
    /// Why no run may take this row's suggested `action` on the user's behalf, or nil when one may.
    ///
    /// Every row carries an `action`, but for these rows it is a guess, and a bulk run that took it
    /// would overwrite whichever side lost. A held row stays listed with its note in `description`,
    /// is left out of every bulk run (`FileSyncManager.syncAll`, the CLI's `sync`) and reported as
    /// left out. A row the user copies on its own goes ahead (the right-click menu, via
    /// `redirected(to:)`), except `.sourceIsSymbolicLink`, which `syncFile` refuses. The CLI leaves
    /// held rows to the app. Not a `DifferenceType`, so filters, badges and sorts still read the row
    /// by its type.
    public let heldBack: HeldBack?

    /// The reasons a row's suggested direction cannot be taken unattended; see `heldBack`.
    public enum HeldBack: Equatable, Sendable {
        /// Two files whose sizes differ while their dates match within the tolerance, or where a
        /// side has no date: nothing says which is newer. A `.nameConflict` pair of two files is
        /// held for the same reason.
        case sizesDifferWithoutANewerSide
        /// A folder against a file. A folder's own date is not when its contents last changed (a
        /// package edited inside keeps an old date), so the dates don't say which side is newer.
        case folderVersusFile
        /// The side the row copies from is a symbolic link. The comparison reads a link as its
        /// target, but the copy writes the link itself (`ObservedCopy` uses
        /// `COPYFILE_NOFOLLOW_SRC`): a "Folder missing" row would become one link to the original,
        /// the next scan would call it in sync, and edits in "the copy" would change the original.
        case sourceIsSymbolicLink
        /// A folder missing on one side holds a symbolic link that points out of it; `path` is the
        /// first such link by relative path. The recursive copy writes it as a link, with the
        /// problem `sourceIsSymbolicLink` describes. A relative link that stays inside (a
        /// framework's `Versions/Current -> A`) is fine; an absolute or dangling one counts as out
        /// (`FileDiffEngine.linkLeads`). A single deliberate copy goes ahead: the rest copies right.
        case enclosesSymbolicLink(path: String)
    }

    /// True when both sides report the same file size (and both are non-nil). Use for optional checksum verification.
    public var sizesMatch: Bool {
        guard let l = leftFileSize, let r = rightFileSize else { return false }
        return l == r
    }
    
    public init(id: UUID = UUID(), relativePath: String, leftItemPath: String, rightItemPath: String, type: DifferenceType, action: SyncAction, description: String, isSyncing: Bool = false, leftFileSize: Int? = nil, leftModified: Date? = nil, rightFileSize: Int? = nil, rightModified: Date? = nil, enclosedItemCount: Int? = nil, leftIsDirectory: Bool = false, rightIsDirectory: Bool = false, heldBack: HeldBack? = nil) {
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
        self.leftModified = leftModified
        self.rightModified = rightModified
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
        /// Item exists on both sides under names that differ only invisibly (leading or trailing
        /// whitespace, trailing dots, NFC/NFD form), usually because one provider normalizes
        /// names. Copied as "missing" it would mint a look-alike duplicate the stricter provider
        /// can't upload, so it is one conflict whose paths point at both real items, and a sync
        /// meets the existing counterpart as a normal collision.
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

    /// This difference as seen after the panes trade sides: paths, sizes, type, action and the
    /// description's side wording flip. The `id` stays, so table selection and checksum results
    /// survive a pane swap.
    public func mirrored() -> FileDifference {
        FileDifference(
            id: id,
            relativePath: relativePath,
            leftItemPath: rightItemPath,
            rightItemPath: leftItemPath,
            type: type.mirrored,
            action: action.mirrored,
            // A .nameConflict description is side-neutral and quotes both names exactly, so the
            // side-phrase rewrite must not touch it: a name containing "on right" would change.
            description: type == .nameConflict ? description : Self.mirroredDescription(description),
            isSyncing: isSyncing,
            leftFileSize: rightFileSize,
            leftModified: rightModified,
            rightFileSize: leftFileSize,
            rightModified: leftModified,
            enclosedItemCount: enclosedItemCount,
            leftIsDirectory: rightIsDirectory,
            rightIsDirectory: leftIsDirectory,
            // Side-neutral: a swap moves the source side and the action together, so a link is
            // still the side copied from and an undecided pair is still undecided.
            heldBack: heldBack
        )
    }

    /// This row with the user's chosen direction in place of the engine's, as the row's Copy to …
    /// item hands it to `syncFile`. Paths, type, note, hold and `id` are unchanged, so it resolves
    /// this row. Not `mirrored()`, which trades the panes.
    public func redirected(to direction: SyncAction) -> FileDifference {
        FileDifference(
            id: id, relativePath: relativePath, leftItemPath: leftItemPath, rightItemPath: rightItemPath,
            type: type, action: direction, description: description, isSyncing: isSyncing,
            leftFileSize: leftFileSize, leftModified: leftModified, rightFileSize: rightFileSize, rightModified: rightModified,
            enclosedItemCount: enclosedItemCount,
            leftIsDirectory: leftIsDirectory, rightIsDirectory: rightIsDirectory, heldBack: heldBack)
    }

    /// Absolute path of the item on the side `action` copies from (left for `.copyToRight`, right
    /// for `.copyToLeft`).
    var sourceItemPath: String {
        action == .copyToRight ? leftItemPath : rightItemPath
    }

    /// Source and destination URLs for resolving this difference in its `action` direction.
    var transferURLs: (from: URL, to: URL) {
        action == .copyToRight
            ? (URL(fileURLWithPath: leftItemPath), URL(fileURLWithPath: rightItemPath))
            : (URL(fileURLWithPath: rightItemPath), URL(fileURLWithPath: leftItemPath))
    }

    /// The two compared folders this transfer runs between, in `action` direction: each item path
    /// minus `relativePath`. These are the panes' folders, not the item's possibly deep parent.
    /// Falls back to the immediate parents if a path doesn't end in `relativePath`.
    var transferContainers: (from: String, to: String) {
        let urls = transferURLs
        func container(of path: String) -> String {
            guard path.hasSuffix("/" + relativePath) else {
                return (path as NSString).deletingLastPathComponent
            }
            let stripped = String(path.dropLast(relativePath.count + 1))
            // A pane rooted at "/" strips to "", which would leave From/To lines blank.
            return stripped.isEmpty ? "/" : stripped
        }
        return (container(of: urls.from.path), container(of: urls.to.path))
    }

    /// Flips the side wording in a description ("Missing on right (iCloud)" → "Missing on left
    /// (iCloud)"). Provider names travel with their files, and no `FileDiffEngine` description
    /// names both sides, so one one-way replacement is exact.
    ///
    /// Only outside “…”: a quoted span is an exact path, and a link named `notes on right` must
    /// neither be renamed nor pick the direction.
    static func mirroredDescription(_ description: String) -> String {
        // Alternating runs: even indices outside quotes, odd ones inside (each with its quotes).
        var runs: [String] = []
        var current = ""
        for character in description {
            if character == "“", runs.count % 2 == 0 {
                runs.append(current); current = String(character)
            } else if character == "”", runs.count % 2 == 1 {
                current.append(character); runs.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        runs.append(current)
        let outside = runs.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined()
        let (from, to): (String, String)
        if outside.contains("on right") { (from, to) = ("on right", "on left") }
        else if outside.contains("on left") { (from, to) = ("on left", "on right") }
        else { return description }
        return runs.enumerated().map { index, run in
            index % 2 == 0 ? run.replacingOccurrences(of: from, with: to) : run
        }.joined()
    }
}
