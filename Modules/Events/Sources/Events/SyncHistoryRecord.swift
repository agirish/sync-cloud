import Foundation

/// The kind of file mutation a `SyncHistoryRecord` captures. Kept deliberately coarse — a
/// history reader thinks in "copy / move / delete", not in the app's internal sync directions
/// (that nuance lives in `SyncHistoryRecord.direction`). `Codable` so the store can persist it
/// as JSON-lines and re-load it; `Sendable` so records can be built off the main actor.
///
/// **Adding a case is safe for the file on disk.** The store is append-only and loads line by
/// line, dropping a line it cannot decode (`SyncHistoryStore.loadRecords`), so an older build
/// reading a history with a newer case skips those lines and keeps the rest — it never rewrites
/// them away.
public enum SyncAction: String, Codable, Sendable, CaseIterable {
    case copy
    case move
    case delete
    /// "Copy to match dates" on a pair Verify All proved byte-identical (FR41): the destination
    /// file took the source's modification date, and no byte was copied.
    case matchDates

    /// A short human label for the UI ("Copy" / "Move" / "Move to Trash" / "Match Dates").
    ///
    /// **A `.delete` is a move to the Trash, so it says so** (FD2), as the row menu, the banner and
    /// Edit ▸ Undo already do. The one delete that is not — an item removed outright on a disk with
    /// no Trash — is told apart per record: `SyncHistoryRecord.actionLabel`. The raw value stays
    /// `delete`: it is what the history file and its CSV/JSON exports carry.
    public var label: String {
        switch self {
        case .copy: return "Copy"
        case .move: return "Move"
        case .delete: return "Move to Trash"
        case .matchDates: return "Match Dates"
        }
    }

    /// SF Symbol used to badge the action in the Sync History list.
    public var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .delete: return "trash"
        case .matchDates: return "calendar"
        }
    }
}

/// One durable, structured entry in the Sync History: a single file/folder that a copy, move,
/// or delete touched. Unlike a `LogEntry` (a free-text, in-memory audit line that forgets on
/// quit), a record is machine-readable and persisted, so history survives relaunch and can be
/// filtered, exported (CSV/JSON), and — via the run it belongs to — reversed.
///
/// A record never carries authority to change anything; it is the *evidence* an operation ran.
/// `backupPath` (the Trash location of a deleted item, or the displaced original of an
/// overwrite) is recorded only so the history is self-explanatory — the actual reversal reuses
/// the app's existing `UndoManager` stack, not this field.
public struct SyncHistoryRecord: Codable, Sendable, Identifiable {
    /// Unique identity of this record.
    public let id: UUID
    /// The run (one user gesture — a single sync, a bulk sync, a multi-item transfer/delete)
    /// this record belongs to. Every record produced by one gesture shares a `runId`, which is
    /// how "the last run" is scoped for filtering and reversal.
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
    /// SHA-256 hex of the content, if known. Deliberately nil at write time (hashing inline
    /// would slow bulk runs); a later Verify can populate the field. Present in the schema so
    /// the "with checksum" contract holds even when the value is filled in after the fact.
    public let checksum: String?
    /// The Trash location of a deleted item, or the displaced original of an overwrite — kept
    /// so a reader can see what was set aside. The reversal path does not consult this.
    public let backupPath: String?
    /// The sync direction in the two-pane model ("→ Right" / "← Left"), when meaningful; nil
    /// for a delete or a transfer to an arbitrary folder.
    public let direction: String?

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
        direction: String? = nil
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
    }

    /// **A delete that did not reach the Trash** — removed outright on a disk with no Trash, after
    /// the permanent-delete question was answered yes. `deleteItems` records the Trash location of
    /// every item it trashed in `backupPath` and leaves it nil for exactly these, so the record
    /// itself tells the two apart.
    public var isPermanentDelete: Bool { action == .delete && backupPath == nil }

    /// The row's label: `action.label`, except "Delete" for a permanent delete (FD2) — "Move to
    /// Trash" there would promise a way back that is not there.
    public var actionLabel: String { isPermanentDelete ? "Delete" : action.label }
}
