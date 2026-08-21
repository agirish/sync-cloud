//
//  DeleteOutcome.swift
//  SyncCloud
//

import Foundation

/// What a `deleteItems` run actually did, split by whether it can be taken back.
///
/// This was a bare `Int` — the number of items removed — which folded together the two outcomes a
/// caller most needs to tell apart. `deleteItems` itself knows the difference and gets it right: it
/// registers a restore-undo only for items that reached the Trash, and flags its own banner
/// `undoable: false` otherwise. But it could not hand that fact back, so the duplicates callers
/// replaced its banner with an unconditional **"press ⌘Z to undo"**.
///
/// On a volume with no Trash — exFAT, most SMB shares — that promise is printed after files were
/// destroyed permanently. ⌘Z then reverses whatever was previously on top of the undo stack: the
/// preceding "Filed 40 files" batch, say, moving forty unrelated files back.
///
/// `declined` covers the third outcome, which had no representation at all: items that could not be
/// trashed and that the user then chose NOT to delete permanently. They are still on disk, and
/// counting them as neither removed nor failed is what let the run report "That item was already
/// gone" about a file sitting untouched where it always was.
public struct DeleteOutcome: Sendable, Equatable {
    /// Items moved to the Trash. Recoverable, and covered by the registered restore-undo.
    public let trashed: Int
    /// Items removed permanently because the volume has no Trash and the user confirmed.
    /// Unrecoverable, and covered by no undo.
    public let permanentlyDeleted: Int
    /// Items left on disk: they could not be trashed and the user declined the permanent delete.
    public let declined: Int
    /// Items left on disk because the caller's `removalGate` refused them at the last moment:
    /// re-verification found they were no longer what the caller checked before calling — the
    /// serialized queue and the permanent-delete dialog can both put user-paced time between a
    /// caller's verify and the removal, and a verdict from before that window must not be acted
    /// on after it. The gate itself surfaces WHICH paths were refused and why; this count lets
    /// the caller's accounting distinguish "refused at the last check" from "failed".
    public let refusedByGate: Int

    public init(trashed: Int = 0, permanentlyDeleted: Int = 0, declined: Int = 0,
                refusedByGate: Int = 0) {
        self.trashed = trashed
        self.permanentlyDeleted = permanentlyDeleted
        self.declined = declined
        self.refusedByGate = refusedByGate
    }

    /// Items that actually left the disk, by either route — what the old `Int` return meant.
    public var removed: Int { trashed + permanentlyDeleted }

    /// Whether ⌘Z can genuinely reverse this run. False for a mixed batch as well as an
    /// all-permanent one: the restore-undo can only bring back the trashed subset, so offering an
    /// Undo would silently leave the permanent deletions in place.
    public var isUndoable: Bool { permanentlyDeleted == 0 && trashed > 0 }
}
