import Foundation

/// The kind of file mutation a `SyncHistoryRecord` captures. Deliberately coarse: a reader thinks
/// in copy, move and delete, and the sync direction lives in `SyncHistoryRecord.direction`.
///
/// Adding a case is safe for the file on disk: the store is append-only and skips a line it can't
/// decode (`SyncHistoryStore.loadRecords`), so an older build keeps the rest and never rewrites
/// the newer lines away.
public enum SyncAction: String, Codable, Sendable, CaseIterable {
    case copy
    case move
    case delete
    /// "Copy to match dates" on a pair Verify All proved byte-identical: the destination took the
    /// source's modification date, and no byte was copied.
    case matchDates
    /// A folder made, by New Folder or by a card of changes in Ask Claude. `sourcePath` is the
    /// folder.
    case newFolder

    /// A short label for the UI ("Copy", "Move", "Move to Trash", "Match Dates", "New Folder").
    ///
    /// A `.delete` is a move to the Trash, so it says so, as the row menu, banner and Edit ▸ Undo
    /// do. A permanent delete on a disk with no Trash is told apart per record
    /// (`SyncHistoryRecord.actionLabel`). The raw value stays `delete`, as the file and exports carry.
    public var label: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .delete: return "Move to Trash"
        case .matchDates: return "Match Dates"
        case .newFolder: return "New Folder"
        }
    }

    /// SF Symbol used to badge the action in the Sync History list.
    public var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        case .matchDates: return "calendar"
        case .newFolder: return "folder.badge.plus"
        }
    }
}

/// One durable entry in the Sync History: a single file or folder an operation touched. Unlike a
/// free-text `LogEntry`, a record is structured and persisted, so it can be filtered, exported and
/// grouped by run.
///
/// A record is evidence an operation ran, never authority to change anything: reversal uses the
/// app's `UndoManager` stack, not `backupPath`.
public struct SyncHistoryRecord: Codable, Sendable, Identifiable {
    /// Unique identity of this record.
    public let id: UUID
    /// The run (one user gesture, such as a sync or a multi-item transfer) this record belongs to.
    /// Every record from one gesture shares it, which is how "the last run" is scoped.
    public let runId: UUID
    /// When the operation completed.
    public let timestamp: Date
    /// What happened to the item.
    public let action: SyncAction
    /// Absolute path the item came from (the source of a copy/move, the original of a delete).
    public let sourcePath: String
    /// Absolute path the item landed at (nil for a delete).
    public let destPath: String?
    /// Size in bytes, best-effort. Nil when it wasn't cheaply available at record time.
    public let sizeBytes: Int?
    /// SHA-256 hex of the content, if known. Nil at write time, since hashing inline would slow
    /// bulk runs; in the schema so a later Verify can fill it in.
    public let checksum: String?
    /// The Trash location of a deleted item, or the displaced original of an overwrite — kept
    /// so a reader can see what was set aside. The reversal path does not consult this.
    public let backupPath: String?
    /// The sync direction in the two-pane model ("→ Right" / "← Left"), when meaningful; nil
    /// for a delete or a transfer to an arbitrary folder.
    public let direction: String?
    /// Whether a `.delete` reached the Trash, recorded by `deleteItems`. Its own field because the
    /// Trash can take an item and report no location, so `backupPath` can't say it. Nil for other
    /// actions and in older records, which fall back to `backupPath` (`isPermanentDelete`).
    /// Optional, so files decode both ways; the JSON export carries it, the CSV does not.
    public let reachedTrash: Bool?
    /// For a `.matchDates` record, the modification date the destination had before, so the
    /// history says what was replaced. Nil for other actions and in older lines, which still load
    /// because the synthesized decoder reads an absent key as nil.
    public let previousModificationDate: Date?

    public init(
        id: UUID = UUID(),
        runId: UUID,
        timestamp: Date = Date(),
        action: SyncAction,
        sourcePath: String,
        destPath: String? = nil,
        sizeBytes: Int? = nil,
        checksum: String? = nil,
        backupPath: String? = nil,
        direction: String? = nil,
        reachedTrash: Bool? = nil,
        previousModificationDate: Date? = nil
    ) {
        self.id = id
        self.runId = runId
        self.timestamp = timestamp
        self.action = action
        self.sourcePath = sourcePath
        self.destPath = destPath
        self.sizeBytes = sizeBytes
        self.checksum = checksum
        self.backupPath = backupPath
        self.direction = direction
        self.reachedTrash = reachedTrash
        self.previousModificationDate = previousModificationDate
    }

    /// A delete that didn't reach the Trash: removed outright, after the permanent-delete question
    /// was answered yes. Read from `reachedTrash`; an older record falls back to
    /// `backupPath == nil`, which also counts an item trashed with no reported location.
    public var isPermanentDelete: Bool {
        action == .delete && !(reachedTrash ?? (backupPath != nil))
    }

    /// The row's label: `action.label`, except "Delete" for a permanent delete, where "Move to
    /// Trash" would promise a way back that isn't there.
    public var actionLabel: String { isPermanentDelete ? "Delete" : action.label }
}
