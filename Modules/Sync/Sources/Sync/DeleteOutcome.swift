//
//  DeleteOutcome.swift
//  SyncCloud
//

import Foundation

/// What a `deleteItems` run actually did, split by whether it can be taken back.
///
/// **Callers must not promise "press ⌘Z to undo" unless `isUndoable`.** On a volume with no Trash
/// (exFAT, most SMB shares) the files are gone for good, and ⌘Z would instead reverse whatever was
/// below on the undo stack, such as an unrelated filing batch. `declined` items are still on disk,
/// so a report must not call them removed or already gone.
public struct DeleteOutcome: Sendable, Equatable {
    /// Items moved to the Trash. Recoverable, and covered by the registered restore-undo.
    public let trashed: Int
    /// Items the Trash took without saying where (`trashItem` left its result nil). Recoverable from
    /// the Trash by hand, but no undo covers them, since the restore needs the location.
    public let trashedWithoutLocation: Int
    /// Items removed permanently because the volume has no Trash and the user confirmed.
    /// Unrecoverable, and covered by no undo.
    public let permanentlyDeleted: Int
    /// Items left on disk: they could not be trashed and the user declined the permanent delete.
    public let declined: Int
    /// Items left on disk because the caller's `removalGate` refused them at the last moment, having
    /// changed since the caller checked them. The queue and the permanent-delete dialog can put
    /// user-paced time between that check and the removal, so an earlier verdict must not be acted
    /// on. The gate reports which paths and why; this count keeps them apart from failures.
    public let refusedByGate: Int
    /// A Stop ended the run with items not yet visited, left on disk because the user asked. False
    /// for a Stop during or after the last item, when nothing was left to stop.
    public let stoppedShort: Bool

    public init(trashed: Int = 0, trashedWithoutLocation: Int = 0, permanentlyDeleted: Int = 0,
                declined: Int = 0, refusedByGate: Int = 0, stoppedShort: Bool = false) {
        self.trashed = trashed
        self.trashedWithoutLocation = trashedWithoutLocation
        self.permanentlyDeleted = permanentlyDeleted
        self.declined = declined
        self.refusedByGate = refusedByGate
        self.stoppedShort = stoppedShort
    }

    /// Items that actually left their place, by any route.
    public var removed: Int { trashed + trashedWithoutLocation + permanentlyDeleted }

    /// Whether ⌘Z can fully reverse this run. False for a mixed batch too: the restore-undo brings
    /// back only items whose Trash location is known, and would silently leave the rest.
    public var isUndoable: Bool { trashedWithoutLocation == 0 && permanentlyDeleted == 0 && trashed > 0 }
}
