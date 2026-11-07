import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    /// `CopyItemState` plus what the undo checks before it destroys anything. The undo trashes the
    /// copy only while `destinationIdentity` still matches, and refuses when it can't be read. For
    /// a folder that identity is deep (`.directoryTree`), so an edit anywhere inside counts.
    /// `overwrittenIdentity` pins the Trash backup of the item the copy replaced, so the undo
    /// restores that item and not a stranger that took its name (`.absent` if nothing was
    /// replaced). `copiedLock` marks a Finder lock the copy took from its source: the only lock the
    /// undo may lift.
    typealias CopyUndoItemState = (source: URL, destination: URL, overwritten: URL?, destinationIdentity: ItemIdentity,
                                   overwrittenIdentity: ItemIdentity, copiedLock: Bool)
    /// A copied item whose identity walk started the moment its own copy landed
    /// (`startCopyIdentityWalk`); it resolves to `CopyUndoItemState.destinationIdentity`. Per item,
    /// not per batch: a batch can stall on prompts or slow I/O, and a walk after it would record the
    /// user's edits as the baseline, so ⌘Z would trash them as `.unchanged`.
    typealias PendingCopyItemState = (source: URL, destination: URL, overwritten: URL?, identity: Task<CopyIdentityReading, Never>)
    /// One registration-time identity read: the identity, plus the descendant that made it
    /// `.indeterminate`, if one did. That descendant is only reported, so a later ⌘Z refusal can be
    /// diagnosed; it rides along so a batch logs once (`logIndeterminateRegistrations`).
    typealias CopyIdentityReading = (identity: ItemIdentity, unreadableDescendant: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)
    /// `MoveItemState` plus the moved item's identity once the move completed, so the undo moves
    /// back only what it put at `to`, never a newer file dropped there since. Added inside
    /// `registerMoveUndo` so the call sites that build a `MoveItemState` stay unchanged.
    /// `overwrittenIdentity` pins the Trash backup, as for the copy. `emptiedByMerge` marks a source
    /// folder a merge emptied and trashed, whose redo follows the merge's rule (`MoveRedoParam`).
    /// `redirectedIntoTrash` marks an item a later move in its batch replaced into the Trash, so it
    /// is held to the Trash rule wherever it is recorded there.
    typealias MoveUndoItemState = (from: URL, to: URL, overwritten: URL?, movedIdentity: ItemIdentity,
                                   overwrittenIdentity: ItemIdentity, emptiedByMerge: Bool,
                                   redirectedIntoTrash: Bool)
    /// What a move-redo needs to re-apply one item: where its undo put the item back, where the
    /// original move sent it, and `sourceIdentity`, read at `from` as the undo landed it. A redo
    /// moves and so can destroy; a path is not an identity, so it moves only that item.
    /// `destinationIdentity` is what the undo left at `to` (the original it restored, or `.absent`),
    /// so the redo can tell it from something that arrived since. `emptiedByMerge`: trash the
    /// folder again only if nothing but a `.DS_Store` is left, or a refused child would go with it.
    /// `redirectedIntoTrash`: the redo puts it back in the Trash, and the next undo reads it there by
    /// file number, deep, as the first did.
    typealias MoveRedoParam = (from: URL, to: URL, sourceIdentity: ItemIdentity, destinationIdentity: ItemIdentity,
                               emptiedByMerge: Bool, redirectedIntoTrash: Bool)
    /// What a copy-redo needs to re-apply one item: the copy's source and destination, and what the
    /// undo left at the destination (the original it restored, or `.absent`).
    typealias CopyRedoParam = (source: URL, destination: URL, destinationIdentity: ItemIdentity)
    /// A restore the delete-undo performed, plus the restored item's identity as it landed, so the
    /// paired redo refuses to trash anything else at that path.
    typealias TrashRedoItemState = (url: URL, restoredIdentity: ItemIdentity)
    /// One deleted item awaiting a possible undo-restore: where it lived and where the Trash holds
    /// it. Only items that reached the Trash are represented; a permanent remove has nothing to
    /// restore. `backupIdentity` lets the restore tell this item from one that took its name in the
    /// Trash since (`trashBackupVerdict`).
    typealias RestoreItemState = (original: URL, trashedBackup: URL, backupIdentity: ItemIdentity)

    /// Error raised when an undo/restore would land on a location that a different item has taken
    /// since the original operation — reported instead of silently overwriting the occupant.
    nonisolated static var restoreTargetOccupiedError: Error {
        NSError(domain: "SyncCloud.Undo", code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "the original location is already occupied by another item"])
    }

    /// Reports a failed undo/redo restore. When the undo has already removed the current file and
    /// the original can't be restored (often because the Trash backup was emptied), the destination
    /// is left empty, so this logs the paths at `.error` and raises a warning banner.
    nonisolated static func reportUndoRestoreFailure(
        of destination: URL,
        from backup: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        // Build the message off the main actor (it reads the non-Sendable `error`), then hop once to
        // log and raise the banner — `Logger.shared` and `banner` are both main-actor isolated.
        let logMessage = "Undo/Redo (\(actionName)): FAILED to restore \"\(name)\" at \(destination.path) from backup \(backup.path) — destination may now be empty (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo couldn’t restore the original of “\(name)” — it may have been removed from the Trash", log: .loggedAtSite)
        }
    }

    /// Reports an undo or redo move that put the item back whole at `restored` but, moving across
    /// volumes, couldn't fully remove what was left at `leftover` (`originalPartlyRemoved`). Not a
    /// failed restore. The item is left out of the next step, whose move would meet the remains.
    nonisolated static func reportMovedWithLeftoverRemains(
        restored: URL,
        leftover: URL,
        isRedo: Bool,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = restored.lastPathComponent
        let step = isRedo ? "Redo" : "Undo"
        let logMessage = "\(step) (\(actionName)): moved \"\(name)\" to \(restored.path) whole, but what it moved from at \(leftover.path) could not be fully removed — part of it is still there"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("\(step) moved “\(name)” \(isRedo ? "again" : "back"), but the copy where it was couldn’t be fully removed", log: .loggedAtSite)
        }
    }

    /// Reports a failed redo (a copy, move or mkdir, usually because the source vanished) with an
    /// `.error` log line and a warning banner. Callers must leave the item out of the next undo
    /// state, or that undo acts on an item that isn't on disk.
    nonisolated static func reportRedoFailure(
        of destination: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        // Build the message off the main actor (it reads the non-Sendable `error`), then hop once to
        // log and raise the banner — `Logger.shared` and `banner` are both main-actor isolated.
        let logMessage = "Undo/Redo (\(actionName)): FAILED to redo \"\(name)\" at \(destination.path) — item left out of the next undo state (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Redo couldn’t re-apply “\(name)” — its source may no longer exist", log: .loggedAtSite)
        }
    }

    /// Reports a copy-undo permanent delete that failed after the user confirmed it. The copy is
    /// still on disk, so its `overwritten` backup stays put (restoring it would collide), and the
    /// caller leaves the item out of the redo params so a redo doesn't copy over it.
    nonisolated static func reportUndoRemoveFailure(
        of destination: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): FAILED to permanently delete \"\(name)\" at \(destination.path) — the item remains on disk (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo couldn’t remove “\(name)” — it is still on disk", log: .loggedAtSite)
        }
    }

    /// What a refused undo was about to do, for `reportUndoRefusedChangedItem`: the two callers do
    /// different things, and one sentence can't describe both.
    enum RefusedUndoIntent: Sendable {
        /// The copy-undo: it would have removed the item the copy put there.
        case removeTheCopyItProduced
        /// The move-undo: it would have moved the item back where it came from. Nothing is removed.
        case moveItBackToItsSource
    }

    /// Reports an undo refused because the item it would remove or move is no longer the one it
    /// was registered for: touching it would destroy work the undo wasn't asked to reverse. The
    /// item stays, its `overwritten` backup stays in the Trash, and the caller keeps it out of the
    /// redo params. `verdict` says which refusal: `.changed` (it differs) or `.indeterminate` (it
    /// couldn't be read). `intent` picks the sentence for what was refused.
    nonisolated static func reportUndoRefusedChangedItem(
        of destination: URL,
        actionName: String,
        verdict: DriftVerdict,
        intent: RefusedUndoIntent,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let refusedAction: String
        let identity: String
        switch intent {
        case .removeTheCopyItProduced:
            refusedAction = "remove \"\(name)\" at \(destination.path)"
            identity = "the item this undo produced"
        case .moveItBackToItsSource:
            refusedAction = "move \"\(name)\" at \(destination.path) back to its original location"
            identity = "the item that was moved here"
        }
        let logMessage: String
        let bannerMessage: String
        switch verdict {
        case .changed:
            logMessage = "Undo (\(actionName)): REFUSED to \(refusedAction) — it changed since the operation, so it is no longer \(identity); leaving it in place"
            bannerMessage = "Undo left “\(name)” in place — it changed since"
        case .indeterminate:
            logMessage = "Undo (\(actionName)): REFUSED to \(refusedAction) — its current state could not be read, so it cannot be confirmed as \(identity); leaving it in place"
            bannerMessage = "Undo left “\(name)” in place — it couldn’t be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted so a future verdict has to be
            // decided here rather than quietly reported as a change.
            logMessage = "Undo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Undo left “\(name)” in place"
        }
        await MainActor.run {
            if logMessage.hasSuffix("this is a programming error") { Logger.shared.error(logMessage) } else { Logger.shared.warning(logMessage) }
            target.banner = .warning(bannerMessage, log: .loggedAtSite)
        }
    }

    /// Reports a move-undo refused because the identity recorded for the item is `.absent`:
    /// nothing was at the destination when the undo was registered, so there is nothing to move
    /// back. Its own case because `compare` answers `.unchanged` for two absents. Treated as a move,
    /// that would recreate the source's parent folder before failing.
    nonisolated static func reportUndoRefusedUnrecordedItem(
        of destination: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): REFUSED to move \"\(name)\" back to its original location — nothing was recorded at \(destination.path) when this undo was registered, so there is no item to move back; leaving the disk exactly as it is"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("Undo left “\(name)” in place — there was nothing to move back", log: .loggedAtSite)
        }
    }

    /// Reports a redo refused because the item at the source is no longer the one its undo put
    /// there: a redo is as destructive as an undo and gets the same refusal. Only for a source that
    /// is present and `.changed` or `.indeterminate`; a missing source is `reportRedoFailure`.
    /// Decide "missing" at the move itself, not from an earlier pass, since a file can appear there
    /// in between.
    nonisolated static func reportRedoRefusedChangedItem(
        of source: URL,
        actionName: String,
        verdict: DriftVerdict,
        on target: FileSyncManager
    ) async {
        let name = source.lastPathComponent
        let logMessage: String
        let bannerMessage: String
        switch verdict {
        case .changed:
            logMessage = "Redo (\(actionName)): REFUSED to re-apply \"\(name)\" from \(source.path) — it changed since the undo put it back, so it is no longer the item this redo moves; leaving it in place"
            bannerMessage = "Redo left “\(name)” in place — it changed since"
        case .indeterminate:
            logMessage = "Redo (\(actionName)): REFUSED to re-apply \"\(name)\" from \(source.path) — its current state could not be read, so it cannot be confirmed as the item this redo moves; leaving it in place"
            bannerMessage = "Redo left “\(name)” in place — it couldn’t be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted so a future verdict has to be
            // decided here rather than quietly reported as a change.
            logMessage = "Redo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Redo left “\(name)” in place"
        }
        await MainActor.run {
            if logMessage.hasSuffix("this is a programming error") { Logger.shared.error(logMessage) } else { Logger.shared.warning(logMessage) }
            target.banner = .warning(bannerMessage, log: .loggedAtSite)
        }
    }

    /// Whether a redo may replace what is at its destination: only nothing (`.unchanged`) or the
    /// item the undo left there. Anything else, such as a file another app saved since, answers
    /// `.changed` (or `.indeterminate` if unreadable), and the redo refuses rather than trash it.
    /// Deep for a folder, as recorded by `redoOccupantIdentity`, so a `.DS_Store` Finder writes on
    /// opening it doesn't count as a change.
    nonisolated static func redoDestinationVerdict(recorded: ItemIdentity, at destination: URL,
                                                   fileManager fm: FileManaging) -> DriftVerdict {
        let current = ItemIdentity.snapshot(at: destination, fileManager: fm)
        if current == .absent { return .unchanged }
        return recorded.drift(at: destination, fileManager: fm)
    }

    /// What an undo left at a redo's destination, as ``redoDestinationVerdict(recorded:at:fileManager:)``
    /// reads it back: deep with OS noise ignored, or the folder's file number when a descendant
    /// can't be read, so one unreadable file doesn't refuse the redo forever.
    nonisolated static func redoOccupantIdentity(at destination: URL, fileManager fm: FileManaging) -> ItemIdentity {
        ItemIdentity.deepSnapshotOrFileNumber(at: destination, fileManager: fm)
    }

    /// Surfaces a redo refused by ``redoDestinationVerdict(recorded:at:fileManager:)``: the item at
    /// the destination is not the one the undo left there, and replacing it would put work nobody
    /// asked to touch in the Trash. Both items stay where they are.
    nonisolated static func reportRedoRefusedOccupiedDestination(
        of destination: URL,
        actionName: String,
        verdict: DriftVerdict,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage: String
        let bannerMessage: String
        switch verdict {
        case .indeterminate:
            logMessage = "Redo (\(actionName)): REFUSED to re-apply \"\(name)\" — the item at \(destination.path) could not be read, so it cannot be confirmed as the one the undo left there; leaving both in place"
            bannerMessage = "Redo left “\(name)” alone — what is at its destination couldn’t be checked"
        case .changed, .unchanged:
            logMessage = "Redo (\(actionName)): REFUSED to re-apply \"\(name)\" — a different item is at \(destination.path) now, not the one the undo left there, and the redo would replace it; leaving both in place"
            bannerMessage = "Redo left “\(name)” alone — a different item is at its destination now"
        }
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning(bannerMessage, log: .loggedAtSite)
        }
    }

    /// Reports a merge-emptied source folder that the redo left in place because it is no longer
    /// empty: it holds something the redo didn't move, which trashing the folder would take with it.
    nonisolated static func reportRedoLeftMergeSourceFolder(
        _ folder: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = folder.lastPathComponent
        let logMessage = "Redo (\(actionName)): left \"\(name)\" at \(folder.path) in place rather than move it to the Trash — the merge trashed it only once it was empty, and it still holds items this redo did not move"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("Redo left “\(name)” in place — it still holds items the redo didn’t move", log: .loggedAtSite)
        }
    }

    /// Reports a delete-redo refused because the item at the restored path is no longer the one its
    /// undo put there. The trash counterpart of
    /// ``reportRedoRefusedChangedItem(of:actionName:verdict:on:)``. An absent path is skipped
    /// before this: nothing there is not a drift.
    nonisolated static func reportRedoRefusedTrashOfChangedItem(
        at url: URL,
        actionName: String,
        verdict: DriftVerdict,
        on target: FileSyncManager
    ) async {
        let name = url.lastPathComponent
        let logMessage: String
        let bannerMessage: String
        switch verdict {
        case .changed:
            logMessage = "Redo (\(actionName)): REFUSED to trash \"\(name)\" at \(url.path) — it changed since the undo restored it, so it is no longer the item this redo deletes; leaving it in place"
            bannerMessage = "Redo left “\(name)” in place — it changed since"
        case .indeterminate:
            logMessage = "Redo (\(actionName)): REFUSED to trash \"\(name)\" at \(url.path) — its current state could not be read, so it cannot be confirmed as the item this redo deletes; leaving it in place"
            bannerMessage = "Redo left “\(name)” in place — it couldn’t be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted for the same reason the move-redo
            // reporter spells it out: a future verdict has to be decided here.
            logMessage = "Redo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Redo left “\(name)” in place"
        }
        await MainActor.run {
            if logMessage.hasSuffix("this is a programming error") { Logger.shared.error(logMessage) } else { Logger.shared.warning(logMessage) }
            target.banner = .warning(bannerMessage, log: .loggedAtSite)
        }
    }

    /// Reports a copy-undo refused because the copy is locked in Finder by a lock it didn't carry
    /// from its source. The user put it there, and the undo lifts only a lock the copy carried.
    nonisolated static func reportUndoRefusedLockedItem(
        of destination: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): REFUSED to remove \"\(name)\" at \(destination.path) — it is locked, and the lock was not one the copy carried from its original, so this undo does not lift it; leaving it in place"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("Undo left “\(name)” in place — it’s locked. Unlock it in Get Info, then undo again", log: .loggedAtSite)
        }
    }

    /// Whether the copy at `destination` carries its `source`'s Finder lock, the only lock a
    /// copy-undo may lift. Both must be locked: a locked copy of an unlocked source was locked by
    /// someone else.
    nonisolated static func copyCarriesItsSourcesLock(_ source: URL, _ destination: URL,
                                                      fileManager fm: FileManaging) -> Bool {
        isLocked(destination, fileManager: fm) && isLocked(source, fileManager: fm)
    }

    /// Lifts the lock a copy carried from its source, so the copy-undo can remove it, and returns
    /// what it lifted so a failed removal can put it back. Empty, touching nothing, when there is no
    /// such lock.
    nonisolated static func liftCopiedLock(_ item: CopyUndoItemState,
                                           fileManager fm: FileManaging) -> [FileAttributeKey: Any] {
        guard item.copiedLock,
              let attributes = try? fm.attributesOfItem(atPath: item.destination.path) else { return [:] }
        var lock: [FileAttributeKey: Any] = [:]
        if (attributes[.immutable] as? Bool) == true { lock[.immutable] = true }
        if (attributes[.appendOnly] as? Bool) == true { lock[.appendOnly] = true }
        guard !lock.isEmpty,
              (try? fm.setAttributes([.immutable: false, .appendOnly: false],
                                     ofItemAtPath: item.destination.path)) != nil else { return [:] }
        return lock
    }

    /// Puts back the lock `liftCopiedLock` lifted, on a copy whose removal then failed. Logged, not
    /// thrown: the removal failure is the event being reported.
    nonisolated static func relock(_ url: URL, _ lock: [FileAttributeKey: Any], fileManager fm: FileManaging) {
        guard !lock.isEmpty else { return }
        if (try? fm.setAttributes(lock, ofItemAtPath: url.path)) == nil {
            Logger.shared.warning("Undo: could not lock \(url.path) again after failing to remove it")
        }
    }

    /// Reports a transient trash failure during an undo (busy, locked or briefly blocked; see
    /// `isTransientTrashFailure`). It must stay retryable: escalating to the permanent-delete prompt
    /// could destroy a file a retry would have trashed recoverably. The item stays on disk and out
    /// of the redo params.
    nonisolated static func reportUndoTransientTrashFailure(
        of destination: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): couldn't move \"\(name)\" at \(destination.path) to the Trash — transient failure, left in place for a retry instead of escalating to a permanent delete (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("Undo couldn’t remove “\(name)” — it looks busy; try again", log: .loggedAtSite)
        }
    }

    /// The byte size of the regular file at `url`, or nil for a folder or an unreadable or missing
    /// item. Drives no guard; it isn't an identity, since nil conflates three cases and size misses
    /// a same-length rewrite. Kept only for `ItemIdentityTests`; delete it with those expectations.
    nonisolated static func fileSizeSnapshot(at url: URL, fileManager fm: FileManaging) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory { return nil }
        return (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
    }

    /// Every path a move in `batch` renamed away, keyed by its old path: `liveLocation`'s lookup
    /// table. Build it once per batch, not per item: rebuilt per item, registering an undo is
    /// quadratic on the main actor, and a bulk move can hand over thousands of items.
    /// `theUndoRegistrationOfThreeThousandItemsStaysUnderThreeSeconds` guards the blow-up.
    nonisolated static func renameMap(for batch: [MoveItemState]) -> [String: String] {
        var renames: [String: String] = [:]
        for move in batch where move.from.path != move.to.path {
            renames[move.from.path] = move.to.path
        }
        return renames
    }

    /// Where `destination`, a path some item in a move batch was moved to, actually sits once every
    /// other move in the batch is applied. `renames` is the batch's `renameMap(for:)`.
    ///
    /// Only ancestor components are rewritten, when another move's `from` is a strict ancestor; most
    /// batches return the path as-is. The leaf is never rewritten: an item's own name is final, and
    /// in a renumbering cascade (`02→03` beside `01→02`, which `applyRenamePlans` produces) one
    /// move's `to` is another's `from`, so following it would snapshot the wrong file.
    ///
    /// A rewrite is confirmed against the disk. With nested provider roots the item can really be at
    /// its recorded path, and a stranger can take the recorded path too, which `fileExists` can't
    /// tell apart. So the recorded path wins only when the rewritten one is empty; otherwise the
    /// rewrite wins. **A wrong answer here must cost a refusal, never a move of the wrong item.**
    nonisolated static func liveLocation(
        of destination: URL, throughRenames renames: [String: String], fileManager fm: FileManaging
    ) -> URL {
        guard !renames.isEmpty else { return destination }
        let parent = destination.deletingLastPathComponent()
        var seen = Set<String>()
        guard let livingParent = resolveRenamedDirectory(parent.path, renames: renames, seen: &seen)
        else { return destination }
        guard livingParent != parent.path else { return destination }
        let rewritten = URL(fileURLWithPath: livingParent)
            .appendingPathComponent(destination.lastPathComponent)
        // Recorded path occupied AND rewritten path free: nothing else can hold the item, so the
        // occupant is it. Every other combination — including both occupied, where the occupant of
        // the recorded path may be a stranger — takes the rewrite, i.e. takes a refusal.
        guard fm.fileExists(atPath: destination.path),
              !fm.fileExists(atPath: rewritten.path) else { return rewritten }
        return destination
    }

    /// One-shot convenience over `renameMap(for:)` + `liveLocation(of:throughRenames:fileManager:)`.
    /// Never call this in a loop over the batch — that is the quadratic shape `renameMap(for:)`
    /// exists to keep out of `registerMoveUndo(items:)`.
    nonisolated static func liveLocation(
        of destination: URL, afterBatch batch: [MoveItemState], fileManager fm: FileManaging
    ) -> URL {
        liveLocation(of: destination, throughRenames: renameMap(for: batch), fileManager: fm)
    }

    /// How many frames `resolveRenamedDirectory` may take before it gives up: one per path
    /// component plus one per rename hop. `PATH_MAX` allows ~512 components, so no real batch reaches
    /// it, and 512 small frames still fit the 512 KB stack of a non-main thread, where the tests
    /// run.
    private nonisolated static let maxRenameResolutionDepth = 512

    /// `liveLocation`'s worker: `path` with `renames` applied to it and all its ancestors, or nil
    /// past `maxRenameResolutionDepth`. `seen` stops a rename cycle (A→B, B→A) after one lap. No
    /// production batch can form a cycle, but without `seen` one would overflow the stack and crash
    /// the app. The depth cap is the backstop: if `seen` is lost, the tests fail with a wrong answer
    /// instead of a dead test host.
    private nonisolated static func resolveRenamedDirectory(
        _ path: String, renames: [String: String], seen: inout Set<String>, depth: Int = 0
    ) -> String? {
        guard depth < maxRenameResolutionDepth else { return nil }
        if let renamed = renames[path] {
            guard seen.insert(path).inserted else { return path }
            return resolveRenamedDirectory(renamed, renames: renames, seen: &seen, depth: depth + 1)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        guard parent.path != path else { return path }   // reached the volume root
        guard let livingParent = resolveRenamedDirectory(parent.path, renames: renames, seen: &seen,
                                                         depth: depth + 1) else { return nil }
        guard livingParent != parent.path else { return path }
        return URL(fileURLWithPath: livingParent).appendingPathComponent(url.lastPathComponent).path
    }

    /// Whether any entry sits at `url`: a file, a folder, or a symbolic link, even a dangling one.
    /// For the undo's "the user already removed it" decisions. Not `fileExists`, which follows links,
    /// so a moved relative link (usually dangling) would read as gone. `fileExists` is only the
    /// fallback for an entry that can't be statted.
    nonisolated static func entryExists(at url: URL, fileManager fm: FileManaging) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil || fm.fileExists(atPath: url.path)
    }

    /// The identity a later restore holds a backup's location to, read as the undo registers.
    /// `.absent` when there is no backup. Deep for a folder, skipping `.DS_Store` and other OS noise,
    /// so a folder browsed in the Trash still matches and one with other contents doesn't. If a
    /// descendant can't be read, the folder's file number stands in, which survives the move into the
    /// Trash. A stat-only walk, but read off the main actor for a whole batch. An always-empty merge
    /// source uses `mergeEmptiedFolderIdentity`.
    nonisolated static func backupIdentity(_ backup: URL?, fileManager fm: FileManaging) -> ItemIdentity {
        backup.map { ItemIdentity.deepSnapshotOrFileNumber(at: $0, fileManager: fm) } ?? .absent
    }

    /// The identity of a source folder a merge emptied and trashed: `backupIdentity`'s deep rule plus
    /// the folder's file number. The folder is empty, so its contents can't tell it from another empty
    /// folder of that name in the Trash; the file number can. Also used for an item a batch replaced
    /// into the Trash. If its contents can't be read, the file number alone stands in, rather than
    /// `.indeterminate` refusing it forever.
    nonisolated static func mergeEmptiedFolderIdentity(_ folder: URL, fileManager fm: FileManaging) -> ItemIdentity {
        let identity = ItemIdentity.deepSnapshotWithFileNumber(at: folder, fileManager: fm)
        guard identity == .indeterminate,
              let fileNumber = ItemIdentity.directoryFileNumber(at: folder, fileManager: fm) else { return identity }
        return .directoryFileNumber(fileNumber)
    }

    /// Whether the item at a Trash backup's location is still the one this operation put there.
    /// Once the Trash is emptied, macOS gives the freed name to the next file trashed under it, so a
    /// path is not an identity. Re-read at the depth it was recorded (`drift`). A restore goes
    /// ahead when nothing usable was recorded (`.absent`, `.indeterminate`) or nothing is there now
    /// (the move then fails and reports it). Otherwise a different item is `.changed` and an
    /// unreadable one `.indeterminate`; both refuse. **Call it before the undo's irreversible
    /// step**, so a refusal leaves everything in place.
    nonisolated static func trashBackupVerdict(recorded: ItemIdentity, at backup: URL,
                                               fileManager fm: FileManaging) -> DriftVerdict {
        guard recorded != .absent, recorded != .indeterminate else { return .unchanged }
        guard FileSyncManager.entryExists(at: backup, fileManager: fm) else { return .unchanged }
        return recorded.drift(at: backup, fileManager: fm)
    }

    /// Reports a restore refused by ``trashBackupVerdict(recorded:at:fileManager:)``: the item in the
    /// Trash isn't the one this operation put there, so it stays and nothing moves to `destination`.
    nonisolated static func reportUndoRefusedTrashStranger(
        at backup: URL,
        restoring destination: URL,
        actionName: String,
        verdict: DriftVerdict,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let unreadable = verdict == .indeterminate
        let why = unreadable
            ? "it could not be read, so it cannot be confirmed as the item this operation put there"
            : "it is not the item this operation put there — the Trash may have been emptied and another item of that name put in it since"
        let logMessage = "Undo/Redo (\(actionName)): REFUSED to restore \"\(name)\" to \(destination.path) from \(backup.path) — \(why); leaving it in the Trash"
        let bannerMessage = unreadable
            ? "Undo didn’t restore “\(name)” — the item in the Trash under that name couldn’t be read"
            : "Undo didn’t restore “\(name)” — the item in the Trash under that name isn’t the one SyncCloud put there"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning(bannerMessage, log: .loggedAtSite)
        }
    }

    /// Reports a copy- or move-undo refused before its irreversible step because the backup it
    /// would restore can't be read now. Nothing changes, so a later ⌘Z can still put both back once
    /// the backup is readable.
    nonisolated static func reportUndoRefusedUnreadableBackup(
        at backup: URL,
        leaving destination: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): REFUSED to undo \"\(name)\" at \(destination.path) — the original it would restore from \(backup.path) could not be read, so it cannot be confirmed as the item this operation put in the Trash; leaving both as they are"
        await MainActor.run {
            Logger.shared.warning(logMessage)
            target.banner = .warning("Undo left “\(name)” in place — the original in the Trash couldn’t be read", log: .loggedAtSite)
        }
    }

    /// Outcome of putting an undo's displaced `.overwritten` backup back at the destination.
    enum UndoRestoreOutcome { case restored, failed, nothingToRestore }

    /// Restores the backup a copy-undo displaced (`overwritten`) onto `destination`, reporting any
    /// failure. Shared by `registerCopyUndo`'s Trash path and its permanent-delete fallback.
    /// `verdict` is `trashBackupVerdict`'s answer, read by the caller before it removed the copy; a
    /// stranger at the backup's location is refused and counted as a failure.
    nonisolated static func restoreOverwrittenBackup(
        _ overwritten: URL?,
        verdict: DriftVerdict,
        to destination: URL,
        actionName: String,
        fileManager fm: FileManaging,
        on target: FileSyncManager
    ) async -> UndoRestoreOutcome {
        guard let overwritten else { return .nothingToRestore }
        guard verdict == .unchanged else {
            await reportUndoRefusedTrashStranger(at: overwritten, restoring: destination,
                                                 actionName: actionName, verdict: verdict, on: target)
            return .failed
        }
        do {
            try fm.moveItem(at: overwritten, to: destination)
            return .restored
        } catch {
            await reportUndoRestoreFailure(of: destination, from: overwritten, actionName: actionName, error: error, on: target)
            return .failed
        }
    }

    /// Clears a still-showing undoable banner whenever the undo stack changes: its Undo button pops
    /// the top step, which is now a different operation. An operation that wants a banner registers
    /// its undo first and posts the banner after, so its own survives. Warnings and errors stay.
    func invalidateUndoableBanner() {
        if banner?.isUndoable == true { banner = nil }
        // An Ask Claude card's Undo is the same kind of affordance (`undoPlan`).
        planUndoToken = nil
    }

    /// Registers a copy-undo for items fully known now, wrapping them in a resolver that a detached
    /// identity walk fills. Each copy gets a deep identity, because this undo destroys: an edit
    /// anywhere inside the copy makes ⌘Z refuse rather than trash it. (Move-undos stay shallow; each
    /// says why.)
    ///
    /// **Ordering:** the undo is registered synchronously before this returns; only the identity
    /// arrives later. A ⌘Z before the walk finishes pops this undo and waits in the resolver, so it
    /// never compares against a half-recorded state. The walk runs off the main actor because a big
    /// folder (or SMB, or cold iCloud) can take seconds to minutes. Callers await the returned task
    /// last, so "the operation returned" means "its undo is armed".
    ///
    /// **Single-item call sites only** (`syncFile`). The walk starts after the copy, so an edit in
    /// that gap becomes the baseline. In a batch that gap can last as long as a user prompt, so
    /// batches start each walk as its copy lands (`startCopyIdentityWalk`) and register through
    /// `registerCopyUndo(pendingItems:)`.
    @discardableResult
    func registerCopyUndo(items: [CopyItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) -> Task<Void, Never> {
        let resolver = AsyncValueResolver<[CopyUndoItemState]>()
        // Registered before the walk is spawned, so no suspension separates caller and registration.
        registerCopyUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
        return Task.detached(priority: .userInitiated) {
            var enriched: [CopyUndoItemState] = []
            enriched.reserveCapacity(items.count)
            var unreadable: [(destination: URL, child: URL?)] = []
            for item in items {
                let read = FileSyncManager.recordedCopyIdentity(at: item.destination, fileManager: fm)
                if read.identity == .indeterminate {
                    unreadable.append((item.destination, read.unreadableDescendant))
                }
                enriched.append((source: item.source, destination: item.destination,
                                 overwritten: item.overwritten, destinationIdentity: read.identity,
                                 overwrittenIdentity: FileSyncManager.backupIdentity(item.overwritten, fileManager: fm),
                                 copiedLock: FileSyncManager.copyCarriesItsSourcesLock(item.source, item.destination, fileManager: fm)))
            }
            FileSyncManager.logIndeterminateRegistrations(unreadable, of: items.count, actionName: actionName)
            await resolver.resolve(enriched)
        }
    }

    /// Batch registration over identity walks the call site started as each copy landed
    /// (`PendingCopyItemState`). Same contract as `registerCopyUndo(items:)`; only when each identity
    /// is read differs: per item as it lands, not after the batch.
    @discardableResult
    func registerCopyUndo(pendingItems: [PendingCopyItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) -> Task<Void, Never> {
        let resolver = AsyncValueResolver<[CopyUndoItemState]>()
        registerCopyUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
        return Task.detached(priority: .userInitiated) {
            var enriched: [CopyUndoItemState] = []
            enriched.reserveCapacity(pendingItems.count)
            var unreadable: [(destination: URL, child: URL?)] = []
            for item in pendingItems {
                let read = await item.identity.value
                if read.identity == .indeterminate {
                    unreadable.append((item.destination, read.unreadableDescendant))
                }
                enriched.append((source: item.source, destination: item.destination,
                                 overwritten: item.overwritten,
                                 destinationIdentity: read.identity,
                                 overwrittenIdentity: FileSyncManager.backupIdentity(item.overwritten, fileManager: fm),
                                 copiedLock: FileSyncManager.copyCarriesItsSourcesLock(item.source, item.destination, fileManager: fm)))
            }
            FileSyncManager.logIndeterminateRegistrations(unreadable, of: pendingItems.count, actionName: actionName)
            await resolver.resolve(enriched)
        }
    }

    /// Starts the detached identity walk for one landed copy, called as each copy returns inside a
    /// batch loop, so a later edit reads as drift (⌘Z refuses) instead of becoming the baseline.
    /// Feeds `registerCopyUndo(pendingItems:)`.
    ///
    /// **Deliberately unbounded**, unlike the `min(4, …)` fan-outs elsewhere. The cooperative pool
    /// already caps concurrency at the core count, and measured unbounded walks beat serial ones.
    /// A cap would also make walks start late, reopening the window in which an edit becomes the
    /// baseline and ⌘Z trashes it. To shorten `copyItems`' tail, make each walk cheaper, not fewer.
    nonisolated static func startCopyIdentityWalk(at destination: URL, fileManager fm: FileManaging) -> Task<CopyIdentityReading, Never> {
        Task.detached(priority: .userInitiated) {
            recordedCopyIdentity(at: destination, fileManager: fm)
        }
    }

    /// The identity a copy-undo records for one landed copy: the deep snapshot, plus the unreadable
    /// descendant if there is one. An `.indeterminate` read now means that ⌘Z will always refuse,
    /// so the cause is logged at registration, while it can still be named.
    nonisolated static func recordedCopyIdentity(at destination: URL, fileManager fm: FileManaging) -> CopyIdentityReading {
        ItemIdentity.deepSnapshotDetailingFailure(at: destination, fileManager: fm)
    }

    /// The one line a batch logs when some registration-time identity reads came back
    /// `.indeterminate`; nothing when none did. One line, not one per item: the log keeps only the
    /// last 1000 entries, and a warning per item would push out the context that explains the cause.
    /// It counts them, names the first, and says what it costs.
    /// Which registration is reporting — its undo removes a copy, or moves an item back.
    enum IndeterminateRegistration: Sendable { case copy, move }

    nonisolated static func logIndeterminateRegistrations(
        _ unreadable: [(destination: URL, child: URL?)], of total: Int, actionName: String,
        operation: IndeterminateRegistration = .copy
    ) {
        guard let first = unreadable.first else { return }
        let child = first.child.map { " — couldn't read \"\($0.path)\"" } ?? ""
        let (one, many, label, act) = operation == .copy
            ? ("copy", "copies", "Copy undo", "remove")
            : ("move", "moves", "Move undo", "move back")
        let subject = unreadable.count == 1
            ? "the identity of \"\(first.destination.lastPathComponent)\" at \(first.destination.path) couldn't be read when its undo was registered\(child); a later ⌘Z of this \(one) will refuse"
            : "\(unreadable.count) of \(total) items' identities couldn't be read when their undo was registered — first \"\(first.destination.lastPathComponent)\" at \(first.destination.path)\(child); a later ⌘Z of those \(many) will refuse"
        Logger.shared.warning("\(label) (\(actionName)): \(subject) rather than \(act) what it can't verify")
    }

    /// Registers a move-undo; same contract as `registerCopyUndo(items:actionName:fileManager:)`.
    /// `mergeEmptiedFolders` and `redirectedIntoTrash` name items by their Trash location (`to`); see
    /// `MoveRedoParam`. `landedIdentities` holds, by `to`, identities read as each item landed: in a
    /// pane transfer a later item can write into an earlier one, so the earlier one is held to what it
    /// was then. Items not named are read here.
    @discardableResult
    func registerMoveUndo(items: [MoveItemState], mergeEmptiedFolders: Set<URL> = [],
                          redirectedIntoTrash: Set<URL> = [], landedIdentities: [URL: ItemIdentity] = [:],
                          actionName: String,
                          fileManager fm: FileManaging = FileManager.default) -> Task<Void, Never> {
        // Snapshot each moved item now, so the handler refuses to move back something that is no
        // longer it. Shallow on purpose: a move-undo moves the item, so an edit inside travels with
        // it and nothing is lost, and a deep identity would refuse for no reason. Shallow still
        // catches a destination replaced wholesale or reshaped one level down.
        //
        // Read at `liveLocation`, not `to`: in a nested batch the parent may already be renamed, so
        // `to` no longer exists. `to` stays recorded, since the undo restores the parent first.
        // The rename map is built once per batch (see `renameMap(for:)`).
        let renames = FileSyncManager.renameMap(for: items)
        let enriched: [MoveUndoItemState] = items.map { item in
            (from: item.from, to: item.to, overwritten: item.overwritten,
             movedIdentity: landedIdentities[item.to] ?? ItemIdentity.snapshot(
                at: FileSyncManager.liveLocation(of: item.to, throughRenames: renames, fileManager: fm),
                fileManager: fm),
             overwrittenIdentity: ItemIdentity.absent,
             emptiedByMerge: mergeEmptiedFolders.contains(item.to),
             redirectedIntoTrash: redirectedIntoTrash.contains(item.to))
        }
        let resolver = AsyncValueResolver<[MoveUndoItemState]>()
        registerMoveUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
        // Backup identities cost a walk per replaced folder, so they're read off the main actor;
        // the handler waits on the resolver. Items now in the Trash (a merge-emptied source folder,
        // or an item a later move replaced into the Trash) are re-read deep and by file number
        // (`mergeEmptiedFolderIdentity`), so Finder's `.DS_Store` doesn't count as a change and
        // another folder with the same contents doesn't match.
        return Task.detached(priority: .userInitiated) {
            let withBackups: [MoveUndoItemState] = enriched.map { item in
                (from: item.from, to: item.to, overwritten: item.overwritten,
                 movedIdentity: item.emptiedByMerge || item.redirectedIntoTrash
                    ? FileSyncManager.mergeEmptiedFolderIdentity(item.to, fileManager: fm) : item.movedIdentity,
                 overwrittenIdentity: FileSyncManager.backupIdentity(item.overwritten, fileManager: fm),
                 emptiedByMerge: item.emptiedByMerge, redirectedIntoTrash: item.redirectedIntoTrash)
            }
            // Logged now, once per batch: an unreadable identity is a ⌘Z that will refuse.
            let unreadable = withBackups.filter { $0.movedIdentity == .indeterminate }.map { (destination: $0.to, child: URL?.none) }
            FileSyncManager.logIndeterminateRegistrations(unreadable, of: withBackups.count, actionName: actionName,
                                                          operation: .move)
            await resolver.resolve(withBackups)
        }
    }

    /// Registers a delete-undo; same contract as `registerCopyUndo(items:actionName:fileManager:)`.
    /// `trashedItems[i]` is where `urls[i]` went in the Trash, or nil if it wasn't trashed (then
    /// there is nothing to restore and it's dropped). Backup identities are read off the main actor.
    @discardableResult
    func registerRestoreItems(urls: [URL], trashedItems: [URL?], actionName: String, fileManager fm: FileManaging = FileManager.default) -> Task<Void, Never> {
        let pairs: [(original: URL, trashed: URL)] = zip(urls, trashedItems).compactMap { original, trashed in
            trashed.map { (original: original, trashed: $0) }
        }
        let resolver = AsyncValueResolver<[RestoreItemState]>()
        registerRestoreItems(stateResolver: resolver, actionName: actionName, fileManager: fm)
        return Task.detached(priority: .userInitiated) {
            let items: [RestoreItemState] = pairs.map {
                (original: $0.original, trashedBackup: $0.trashed,
                 backupIdentity: FileSyncManager.backupIdentity($0.trashed, fileManager: fm))
            }
            await resolver.resolve(items)
        }
    }

    func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyUndoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        let confirmPermanentDelete = permanentDeleteConfirmer
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[CopyRedoParam]>()
            target.registerCopyRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let items = await stateResolver.get()

                        // Undoing a copy deletes it. Without a Trash that is permanent, so it needs
                        // the same confirmation as deleteItems, never a silent removeItem.
                        // Redo params come only from copies actually removed: a refused one still
                        // exists, and redoing it would copy over it. Resolve `redoParamResolver` on
                        // every exit, or a later redo awaits it forever.
                        var trashFailures: [CopyUndoItemState] = []
                        var removed = 0
                        var restored = 0
                        var restoreFailures = 0
                        var leftInPlace = 0
                        var vanished = 0
                        var undoneCopies: [(source: URL, destination: URL)] = []
                        /// Each undone copy with what this undo left at its destination, read after
                        /// every restore, since that is what the redo will find.
                        func redoParams() -> [CopyRedoParam] {
                            undoneCopies.map { copy in
                                (source: copy.source, destination: copy.destination,
                                 destinationIdentity: FileSyncManager.redoOccupantIdentity(at: copy.destination, fileManager: fm))
                            }
                        }
                        // Destinations this run already returned to their pre-batch state. A batch
                        // can register one path twice (a second copy replaced the first), and
                        // restoring the second's backup would resurrect the copy just removed. Kept
                        // exact and folded, since one file can be registered under two spellings
                        // ("F.txt", "f.txt"). Case folds only on a case-insensitive volume, where the
                        // two are one file; Unicode always precomposes, as APFS/HFS+ lookups do.
                        var handledDestinations = Set<String>()
                        var handledFoldedDestinations = Set<String>()
                        var duplicateRegistrations = 0
                        // Whether to fold, per destination parent, cached so keys stay stable if a
                        // parent vanishes mid-undo. Asked of the nearest existing ancestor, since a
                        // vanished path can't answer and a fixed fallback would be wrong on some
                        // volume. If nothing answers, don't fold: never skip a file that may be real.
                        var foldsByParent: [String: Bool] = [:]
                        func volumeFoldsCase(underParent parent: URL) -> Bool {
                            if let cached = foldsByParent[parent.path] { return cached }
                            var probe = parent
                            var folds = false
                            while true {
                                if let sensitive = try? probe.resourceValues(
                                    forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames {
                                    folds = !sensitive
                                    break
                                }
                                let up = probe.deletingLastPathComponent()
                                if up.path == probe.path { break }
                                probe = up
                            }
                            foldsByParent[parent.path] = folds
                            return folds
                        }
                        func foldedKey(_ url: URL) -> String {
                            let precomposed = url.path.precomposedStringWithCanonicalMapping
                            return volumeFoldsCase(underParent: url.deletingLastPathComponent())
                                ? precomposed.lowercased() : precomposed
                        }
                        // The redo re-copies what the batch ended with at each name, source and
                        // spelling both. A name copied twice is undone once and the later
                        // registration skipped, so take the last one (`items` is in order).
                        let finalCopyByDestination = Dictionary(
                            items.map { (foldedKey($0.destination), (source: $0.source, destination: $0.destination)) },
                            uniquingKeysWith: { _, later in later })
                        func undone(_ item: CopyUndoItemState) -> (source: URL, destination: URL) {
                            finalCopyByDestination[foldedKey(item.destination)] ?? (source: item.source, destination: item.destination)
                        }
                        func markHandled(_ url: URL) {
                            handledDestinations.insert(url.path)
                            handledFoldedDestinations.insert(foldedKey(url))
                        }
                        func alreadyHandled(_ url: URL) -> Bool {
                            handledDestinations.contains(url.path)
                                || handledFoldedDestinations.contains(foldedKey(url))
                        }
                        // The backup's verdict; `.unchanged` when there is none.
                        func backupVerdict(_ item: CopyUndoItemState) -> DriftVerdict {
                            item.overwritten.map {
                                FileSyncManager.trashBackupVerdict(recorded: item.overwrittenIdentity, at: $0, fileManager: fm)
                            } ?? .unchanged
                        }
                        for item in items {
                            if alreadyHandled(item.destination) {
                                duplicateRegistrations += 1
                                logger.debug("Undo (\(actionName)): \(item.destination.lastPathComponent) already handled by an earlier item of this run — skipping its duplicate registration")
                                continue
                            }
                            // The user already deleted the copy, so the undo's goal here is met:
                            // restore the backup and keep the item in the redo params. Checked
                            // without following links, since a dangling copied link is still the copy.
                            if !FileSyncManager.entryExists(at: item.destination, fileManager: fm) {
                                vanished += 1
                                markHandled(item.destination)
                                logger.info("Undo (\(actionName)): \(item.destination.lastPathComponent) is no longer on disk — nothing to remove")
                                undoneCopies.append(undone(item))
                                switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, verdict: backupVerdict(item), to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                                case .restored: restored += 1
                                case .failed: restoreFailures += 1
                                case .nothingToRestore: break
                                }
                                continue
                            }
                            // If the destination is no longer the item this copy produced (re-read
                            // deep for a folder), refuse to trash it and keep it out of the redo
                            // params. Switch on all three verdicts, so "couldn't tell" never takes
                            // the destroy path. Read once, so the report matches the decision.
                            let verdict = item.destinationIdentity.drift(at: item.destination, fileManager: fm)
                            switch verdict {
                            case .unchanged:
                                break
                            case .changed, .indeterminate:
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedChangedItem(of: item.destination, actionName: actionName, verdict: verdict, intent: .removeTheCopyItProduced, on: target)
                                continue
                            }
                            // A locked copy can't be trashed. A lock it carried from its source is
                            // lifted, since the check above confirmed it is our copy; any other lock
                            // is the user's, and the undo refuses and says so.
                            if FileSyncManager.isLocked(item.destination, fileManager: fm), !item.copiedLock {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedLockedItem(of: item.destination, actionName: actionName, on: target)
                                continue
                            }
                            // Check the backup before the copy goes. An unreadable one refuses the
                            // whole item, or the destination would end up empty with the original
                            // still in the Trash. A stranger doesn't hold the copy back (the original
                            // is gone either way); the restore below refuses it.
                            let itemBackupVerdict = backupVerdict(item)
                            if let overwritten = item.overwritten, itemBackupVerdict == .indeterminate {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedUnreadableBackup(
                                    at: overwritten, leaving: item.destination, actionName: actionName, on: target)
                                continue
                            }
                            let liftedLock = FileSyncManager.liftCopiedLock(item, fileManager: fm)
                            do {
                                try fm.trashItem(at: item.destination, resultingItemURL: nil)
                            } catch {
                                // Left as it was found: the lock goes back on a copy that stays.
                                FileSyncManager.relock(item.destination, liftedLock, fileManager: fm)
                                // A transient failure stays retryable, never a permanent-delete
                                // prompt (as in deleteItems): a retry may trash it recoverably.
                                if FileSyncManager.isTransientTrashFailure(error) {
                                    leftInPlace += 1
                                    await FileSyncManager.reportUndoTransientTrashFailure(of: item.destination, actionName: actionName, error: error, on: target)
                                } else {
                                    trashFailures.append(item)
                                }
                                continue
                            }
                            removed += 1
                            markHandled(item.destination)
                            undoneCopies.append(undone(item))

                            switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, verdict: itemBackupVerdict, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                            case .restored: restored += 1
                            case .failed: restoreFailures += 1
                            case .nothingToRestore: break
                            }
                        }

                        // Skip items an earlier attempt already settled, so the prompt doesn't ask
                        // to delete a file the loop would then skip.
                        let confirmableFailures = trashFailures.filter { !alreadyHandled($0.destination) }
                        if !confirmableFailures.isEmpty {
                            // List each on-disk file once, even if registered twice.
                            var promptedFolded = Set<String>()
                            let promptPaths = confirmableFailures.compactMap { item -> String? in
                                promptedFolded.insert(foldedKey(item.destination)).inserted
                                    ? item.destination.path : nil
                            }
                            let confirmed = await MainActor.run {
                                confirmPermanentDelete(promptPaths)
                            }
                            guard confirmed else {
                                await redoParamResolver.resolve(redoParams())
                                return
                            }
                            for item in confirmableFailures {
                                // The main loop's duplicate guard. Without a Trash both
                                // registrations of a path land here, and the second removeItem would
                                // permanently delete the original the first just restored.
                                if alreadyHandled(item.destination) {
                                    duplicateRegistrations += 1
                                    logger.debug("Undo (\(actionName)): \(item.destination.lastPathComponent) already handled — skipping its duplicate permanent-delete")
                                    continue
                                }
                                // Re-read the backup before deleting, since the prompt may have been up
                                // a while; the copied lock is lifted as on the Trash path.
                                let itemBackupVerdict = backupVerdict(item)
                                if let overwritten = item.overwritten, itemBackupVerdict == .indeterminate {
                                    leftInPlace += 1
                                    await FileSyncManager.reportUndoRefusedUnreadableBackup(
                                        at: overwritten, leaving: item.destination, actionName: actionName, on: target)
                                    continue
                                }
                                let liftedLock = FileSyncManager.liftCopiedLock(item, fileManager: fm)
                                do {
                                    try fm.removeItem(at: item.destination)
                                } catch {
                                    FileSyncManager.relock(item.destination, liftedLock, fileManager: fm)
                                    // The copy survives, so its backup must not be restored over it.
                                    await FileSyncManager.reportUndoRemoveFailure(of: item.destination, actionName: actionName, error: error, on: target)
                                    continue
                                }
                                removed += 1
                                markHandled(item.destination)
                                undoneCopies.append(undone(item))
                                switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, verdict: itemBackupVerdict, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                                case .restored: restored += 1
                                case .failed: restoreFailures += 1
                                case .nothingToRestore: break
                                }
                            }
                        }

                        await redoParamResolver.resolve(redoParams())
                        logger.info("Undo (\(actionName)): removed \(removed) of \(items.count) copied item(s), \(vanished) already gone, \(duplicateRegistrations) duplicate registration(s) skipped, restored \(restored) overwritten original(s), \(restoreFailures) restore failure(s), \(leftInPlace) left in place (changed or busy)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerCopyRedo(paramResolver: AsyncValueResolver<[CopyRedoParam]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextUndoStateResolver = AsyncValueResolver<[CopyUndoItemState]>()
            target.registerCopyUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let params = await paramResolver.get()
                        var nextState: [CopyUndoItemState] = []
                        var redoFailures = 0
                        var leftInPlace = 0
                        // Reported once after the loop (see `logIndeterminateRegistrations`).
                        var unreadable: [(destination: URL, child: URL?)] = []

                        // No source-identity guard, on purpose: a copy-redo only reads its source,
                        // so re-copying an edited source is what "redo the copy" means. What it can
                        // destroy is the destination, which `safeCopyItem` replaces without asking,
                        // so the destination is guarded below: only what the undo left there may
                        // be replaced.
                        for param in params {
                            // Before the parent is made, so a refusal leaves the disk as it was.
                            let atDestination = FileSyncManager.redoDestinationVerdict(
                                recorded: param.destinationIdentity, at: param.destination, fileManager: fm)
                            guard atDestination == .unchanged else {
                                leftInPlace += 1
                                await FileSyncManager.reportRedoRefusedOccupiedDestination(
                                    of: param.destination, actionName: actionName, verdict: atDestination, on: target)
                                continue
                            }
                            try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                let trashed = try FileSyncManager.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                                // Re-snapshot this redo's copy for the next undo, deep as in
                                // `registerCopyUndo(items:)` since that undo trashes, and inline so the
                                // window is per item. `aDeepEditAfterARedoRefusesTheSecondUndo` fails if
                                // this goes shallow.
                                let read = FileSyncManager.recordedCopyIdentity(at: param.destination, fileManager: fm)
                                if read.identity == .indeterminate {
                                    unreadable.append((param.destination, read.unreadableDescendant))
                                }
                                nextState.append((source: param.source, destination: param.destination, overwritten: trashed,
                                                  destinationIdentity: read.identity,
                                                  overwrittenIdentity: FileSyncManager.backupIdentity(trashed, fileManager: fm),
                                                  copiedLock: FileSyncManager.copyCarriesItsSourcesLock(param.source, param.destination, fileManager: fm)))
                            } catch {
                                // Keep a failed re-copy out of the next undo state, or its undo would
                                // prompt to delete a file that isn't on disk.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.destination, actionName: actionName, error: error, on: target)
                            }
                        }

                        FileSyncManager.logIndeterminateRegistrations(unreadable, of: params.count, actionName: actionName)
                        await nextUndoStateResolver.resolve(nextState)
                        logger.info("Redo (\(actionName)): copied \(nextState.count) of \(params.count) item(s), \(redoFailures) redo failure(s), \(leftInPlace) left in place (a different item at the destination)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    /// Registers the handler for a move-undo. `items` keeps its call-site order through the chain:
    /// the undo walks it front to back and `registerMoveRedo` replays it back to front. Call sites
    /// that need an order arrange it themselves: `normalizeNames` registers shallowest-first, so ⌘Z
    /// restores a parent before its children, and the multi-select move registers last item first,
    /// since a later item can write into an earlier one. A renumbering cascade (`03→04`, `02→03`)
    /// chains, but its undo refuses each link as occupied, so no link reaches the redo params.
    func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveUndoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            guard !target.undoReplayBlockedByLanding(actionName) else { return }
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[MoveRedoParam]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                    // An original parked by this undo's cleanup is the item it moved back from, so
                    // the alert words it as an undo.
                    await ParkedSourceLeftovers.$undoing.withValue(true) {
                        let items = await stateResolver.get()

                        // Redo params come only from items that actually moved back. A refused item
                        // must never be redone: the redo would move an unrelated occupant over the
                        // real file at the destination.
                        var movedBack = 0
                        var restoreFailures = 0
                        // Refusals, counted apart from failures: the undo chose not to act, and
                        // nothing went wrong. Mirrors the copy path's `leftInPlace`.
                        var leftInPlace = 0
                        var movedBackPairs: [(from: URL, to: URL, emptiedByMerge: Bool, redirectedIntoTrash: Bool)] = []
                        // Items the user removed between the move and the ⌘Z: nothing to act on, so
                        // not a refusal.
                        var vanished = 0
                        // Items recorded as `.absent`: nothing was at the destination at
                        // registration. Neither a drift refusal nor `vanished`.
                        var nothingRecorded = 0
                        for item in items {
                            var movedBackOK = false
                            // **A recorded `.absent` must not authorise a move.** The drift guard
                            // answers `.unchanged` for two absents, and the move branch would then
                            // create the source's parent folder before failing. Checked first, ahead
                            // of `vanished`, which overlaps it whenever the parent exists and would
                            // only log, losing the refusal banner.
                            if item.movedIdentity == .absent {
                                nothingRecorded += 1
                                await FileSyncManager.reportUndoRefusedUnrecordedItem(
                                    of: item.to, actionName: actionName, on: target)
                                continue
                            }
                            // The moved item is gone: not drift, just nothing to move back. Still
                            // restore the original this move displaced, which is safe because the
                            // destination is empty. Not added to `movedBackPairs`: there is nothing to
                            // redo.
                            //
                            // Only when the parent exists. In a nested batch whose parent's undo was
                            // refused, `to` spells a parent that was never restored: the file is still
                            // on disk under the other name, and restoring the backup there would create
                            // that folder. A missing parent falls through to the drift guard, which
                            // refuses. Checked without following links: a moved relative link usually
                            // dangles, and is still the item.
                            let parentExists = fm.fileExists(atPath: item.to.deletingLastPathComponent().path)
                            if parentExists, !FileSyncManager.entryExists(at: item.to, fileManager: fm) {
                                vanished += 1
                                logger.info("Undo (\(actionName)): \(item.to.lastPathComponent) is no longer on disk — nothing to move back")
                                if let trashed = item.overwritten {
                                    // Only the item this move put in the Trash.
                                    let backupVerdict = FileSyncManager.trashBackupVerdict(
                                        recorded: item.overwrittenIdentity, at: trashed, fileManager: fm)
                                    if backupVerdict != .unchanged {
                                        restoreFailures += 1
                                        await FileSyncManager.reportUndoRefusedTrashStranger(
                                            at: trashed, restoring: item.to, actionName: actionName,
                                            verdict: backupVerdict, on: target)
                                        continue
                                    }
                                    do {
                                        try fm.moveItem(at: trashed, to: item.to)
                                    } catch {
                                        restoreFailures += 1
                                        await FileSyncManager.reportUndoRestoreFailure(of: item.to, from: trashed, actionName: actionName, error: error, on: target)
                                    }
                                }
                                continue
                            }
                            // Undoing a case-only rename ("foo"→"Foo") isn't a clobber. On a
                            // case-insensitive volume `item.from` is the very item being moved back, so
                            // let safeMoveItem do the rename (as renameItem's isCaseOnly does). On a
                            // case-sensitive volume they're two files, and an occupant must still
                            // refuse. Asked through the walking-up probe because `item.from` is usually
                            // absent, and the plain probe's fallback (insensitive) is the unsafe answer
                            // here.
                            let sameItemAsMoved = !FileSyncManager.volumeSupportsCaseSensitiveNamesForNewItem(at: item.from)
                                && item.from.path.caseInsensitiveCompare(item.to.path) == .orderedSame
                            // Is the item at the destination still the one this move put there? If
                            // not (a newer version dropped there, say), moving it back would swap the
                            // newer version out for the old. Checked before the source-occupancy
                            // check, so the refusal gives the accurate reason.
                            let moveVerdict = item.movedIdentity.drift(at: item.to, fileManager: fm)
                            // Check the backup before the item moves back, as the copy-undo does: an
                            // unreadable one refuses the whole item, so the original is never left
                            // stranded.
                            let backupVerdict = item.overwritten.map {
                                FileSyncManager.trashBackupVerdict(recorded: item.overwrittenIdentity, at: $0, fileManager: fm)
                            } ?? .unchanged
                            if moveVerdict != .unchanged {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedChangedItem(of: item.to, actionName: actionName, verdict: moveVerdict, intent: .moveItBackToItsSource, on: target)
                            } else if !sameItemAsMoved && FileSyncManager.entryExists(at: item.from, fileManager: fm) {
                                // `entryExists`, not `fileExists`: a dangling link is an occupant.
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.from, from: item.to, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                            } else if let trashed = item.overwritten, backupVerdict == .indeterminate {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedUnreadableBackup(
                                    at: trashed, leaving: item.to, actionName: actionName, on: target)
                            } else {
                                do {
                                    // Recreate the source's parent only here, once a move is
                                    // certain: a refused item must leave the disk as it found it.
                                    try? fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                                    _ = try FileSyncManager.safeMoveItem(at: item.to, to: item.from, fileManager: fm)
                                    movedBack += 1
                                    movedBackOK = true
                                    // Only a move-back that actually happened is redoable.
                                    movedBackPairs.append((from: item.from, to: item.to, emptiedByMerge: item.emptiedByMerge,
                                                           redirectedIntoTrash: item.redirectedIntoTrash))
                                } catch FileOperationError.originalPartlyRemoved {
                                    // Back whole at `from`, with remains at `to`. Not redoable, and
                                    // the original stays in the Trash rather than land on the remains.
                                    movedBack += 1
                                    await FileSyncManager.reportMovedWithLeftoverRemains(
                                        restored: item.from, leftover: item.to, isRedo: false,
                                        actionName: actionName, on: target)
                                } catch {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRestoreFailure(of: item.from, from: item.to, actionName: actionName, error: error, on: target)
                                }
                            }

                            // Restore the original move's overwritten backup to item.to ONLY if the
                            // item actually left it (move-back succeeded). If we refused, or the
                            // move-back failed, item.to still holds the item and this would just
                            // collide and mis-report a second failure.
                            if movedBackOK, let trashed = item.overwritten {
                                // Only the item this move put in the Trash: a stranger with its name
                                // stays, and the destination stays empty.
                                if backupVerdict != .unchanged {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRefusedTrashStranger(
                                        at: trashed, restoring: item.to, actionName: actionName,
                                        verdict: backupVerdict, on: target)
                                } else {
                                    do {
                                        try fm.moveItem(at: trashed, to: item.to)
                                    } catch {
                                        restoreFailures += 1
                                        await FileSyncManager.reportUndoRestoreFailure(of: item.to, from: trashed, actionName: actionName, error: error, on: target)
                                    }
                                }
                            }
                        }
                        // Read each restored item's identity after the whole loop, since that is what
                        // the redo will find: in a nested batch, moving a child changes its parent's
                        // date. The source is shallow, as in `registerMoveUndo(items:)`, because a redo
                        // moves rather than destroys. The destination is deep, because the redo would
                        // trash what's there (`redoDestinationVerdict`).
                        let reversedParams: [MoveRedoParam] = movedBackPairs.map { pair in
                            (from: pair.from, to: pair.to,
                             sourceIdentity: ItemIdentity.snapshot(at: pair.from, fileManager: fm),
                             destinationIdentity: FileSyncManager.redoOccupantIdentity(at: pair.to, fileManager: fm),
                             emptiedByMerge: pair.emptiedByMerge, redirectedIntoTrash: pair.redirectedIntoTrash)
                        }
                        await redoParamResolver.resolve(reversedParams)
                        logger.info("Undo (\(actionName)): moved \(movedBack) of \(items.count) item(s) back to source, \(restoreFailures) restore failure(s), \(leftInPlace) left in place (changed or unverifiable)"
                                    + (vanished > 0 ? ", \(vanished) no longer on disk" : "")
                                    // Separate from `leftInPlace`, whose parenthetical wouldn't fit it.
                                    + (nothingRecorded > 0 ? ", \(nothingRecorded) with nothing recorded to move back" : ""))
                    }
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    func registerMoveRedo(paramResolver: AsyncValueResolver<[MoveRedoParam]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextUndoStateResolver = AsyncValueResolver<[MoveUndoItemState]>()
            target.registerMoveUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let params = await paramResolver.get()
                        var nextState: [MoveUndoItemState] = []
                        var redoFailures = 0
                        var leftInPlace = 0

                        // The redo moves only the item its undo put at the source, never a stranger
                        // found there. When to check depends on the source's type. Files and links are
                        // checked right before their own move, so nothing that appears mid-batch slips
                        // through. Folders are checked up front: the replay runs deepest-first, so
                        // moving a child changes its parent's date, and a parent checked at its turn
                        // would refuse a correct redo. Remaining gap: a folder swapped for another
                        // between the check and its move is still moved.
                        var replayable: [(param: MoveRedoParam, recheckAtItsMove: Bool)] = []
                        for param in params.reversed() {
                            // Only a recorded folder that is present now is checked up front.
                            guard case .directory = param.sourceIdentity else {
                                replayable.append((param: param, recheckAtItsMove: true))
                                continue
                            }
                            let currentSource = ItemIdentity.snapshot(at: param.from, fileManager: fm)
                            guard currentSource != .absent else {
                                replayable.append((param: param, recheckAtItsMove: true))
                                continue
                            }
                            let verdict = ItemIdentity.compare(recorded: param.sourceIdentity,
                                                               current: currentSource)
                            guard verdict == .unchanged else {
                                leftInPlace += 1
                                await FileSyncManager.reportRedoRefusedChangedItem(
                                    of: param.from, actionName: actionName, verdict: verdict, on: target)
                                continue
                            }
                            replayable.append((param: param, recheckAtItsMove: false))
                        }

                        // `replayable` is reversed: re-applying runs in the original apply order
                        // (deepest-first for `normalizeNames`), not the undo's order. In the undo's
                        // order the parent is renamed first, and every child's `from` then names a
                        // folder that no longer exists. Each item is also snapshotted as it lands,
                        // before shallower moves rename its ancestors, so `param.to` is live and
                        // `liveLocation` must not be used here.
                        for (param, recheckAtItsMove) in replayable {
                            if recheckAtItsMove {
                                let liveSource = ItemIdentity.snapshot(at: param.from, fileManager: fm)
                                // Nothing there now is the missing-source case, which the move below
                                // reports. Decided here, at the move, not from the up-front pass, so
                                // a file that appeared since is compared rather than moved. A
                                // recorded `.absent` authorises nothing: against a present item it
                                // compares `.changed`.
                                if liveSource != .absent {
                                    let verdict = ItemIdentity.compare(recorded: param.sourceIdentity,
                                                                       current: liveSource)
                                    guard verdict == .unchanged else {
                                        leftInPlace += 1
                                        await FileSyncManager.reportRedoRefusedChangedItem(
                                            of: param.from, actionName: actionName, verdict: verdict, on: target)
                                        continue
                                    }
                                }
                            }
                            // A merge-emptied source folder goes back to the Trash only if, as when
                            // the merge trashed it, nothing but a `.DS_Store` is left. A child whose
                            // redo was refused would otherwise go with it. A missing folder falls to
                            // the move's own report.
                            if param.emptiedByMerge, FileSyncManager.entryExists(at: param.from, fileManager: fm),
                               !FileSyncManager.mergeLeftNothing(in: param.from, fileManager: fm) {
                                leftInPlace += 1
                                await FileSyncManager.reportRedoLeftMergeSourceFolder(
                                    param.from, actionName: actionName, on: target)
                                continue
                            }
                            // The destination must still hold what the undo left there:
                            // `safeMoveItem` trashes whatever it finds. Checked after the source, so
                            // a refusal names the right one.
                            let atDestination = FileSyncManager.redoDestinationVerdict(
                                recorded: param.destinationIdentity, at: param.to, fileManager: fm)
                            guard atDestination == .unchanged else {
                                leftInPlace += 1
                                await FileSyncManager.reportRedoRefusedOccupiedDestination(
                                    of: param.to, actionName: actionName, verdict: atDestination, on: target)
                                continue
                            }
                            // Create the destination's parent only if there is a source to move
                            // (including a dangling link), or it could recreate a folder a sibling
                            // move just renamed away.
                            if FileSyncManager.entryExists(at: param.from, fileManager: fm) {
                                try? fm.createDirectory(at: param.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                            }
                            do {
                                let trashed = try FileSyncManager.safeMoveItem(at: param.from, to: param.to, fileManager: fm)
                                // Snapshot here, where the state is produced; at undo time it would
                                // be compared against itself. Shallow, like every move identity,
                                // except an item this redo put back in the Trash, which is read deep
                                // and by file number (`mergeEmptiedFolderIdentity`).
                                nextState.append((from: param.from, to: param.to, overwritten: trashed,
                                                  movedIdentity: param.emptiedByMerge || param.redirectedIntoTrash
                                                    ? FileSyncManager.mergeEmptiedFolderIdentity(param.to, fileManager: fm)
                                                    : ItemIdentity.snapshot(at: param.to, fileManager: fm),
                                                  overwrittenIdentity: FileSyncManager.backupIdentity(trashed, fileManager: fm),
                                                  emptiedByMerge: param.emptiedByMerge,
                                                  redirectedIntoTrash: param.redirectedIntoTrash))
                            } catch FileOperationError.originalPartlyRemoved {
                                // Whole at `to`, with remains at `from`. Left out of the next undo,
                                // whose move back would meet them.
                                await FileSyncManager.reportMovedWithLeftoverRemains(
                                    restored: param.to, leftover: param.from, isRedo: true,
                                    actionName: actionName, on: target)
                            } catch {
                                // Keep a failed re-move out of the next undo state, or its undo would
                                // restore from an empty destination.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.to, actionName: actionName, error: error, on: target)
                            }
                        }

                        // Handed back in undo order, the reverse of the replay: every move state in
                        // this chain is stored in the order its undo processes it.
                        await nextUndoStateResolver.resolve(Array(nextState.reversed()))
                        logger.info("Redo (\(actionName)): moved \(nextState.count) of \(params.count) item(s), \(redoFailures) redo failure(s), \(leftInPlace) left in place (changed or unverifiable)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerCreateFolderUndo(url: URL, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        let confirmPermanentDelete = permanentDeleteConfirmer
        undoManager?.registerUndo(withTarget: self) { target in
            guard !target.undoReplayBlockedByLanding("New Folder") else { return }
            Logger.shared.info("User triggered Undo: New Folder")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            target.registerCreateFolderRedo(url: url, fileManager: fm)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) {
                // This undo can follow a failed folder redo, so it removes only an existing folder
                // at `url`. A missing folder, or another item now at the path, is left alone.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    logger.info("Undo (New Folder): no folder to remove at \(url.path)")
                    return
                }
                // **Only an empty folder is this undo's to remove.** Anything an action moved in was
                // registered later, so its undo already ran; what remains got there another way (the
                // user, or a refused move-back). OS noise holds nothing, but a subfolder counts as
                // content even if empty. Uses Restructure's count, which bounds a cloud-only folder's
                // listing, so a stopped cloud app can't hang the file queue. Nil (not fully read)
                // means not empty.
                var held = FileSyncManager.visibleFileCount(atPath: url.path, fm: fm)
                if held == 0 {
                    // No file beneath, so anything listed beyond OS noise is a subfolder. An
                    // incomplete listing is unknown.
                    let top = fm.listing(of: url)
                    held = top.isComplete
                        ? top.urls.count { !ItemIdentity.deepIdentityIgnoredNames.contains($0.lastPathComponent) }
                        : nil
                }
                guard held == 0 else {
                    let name = url.lastPathComponent
                    // Tell the user "couldn't be read" apart from "isn't empty".
                    let unread = held == nil
                    await MainActor.run {
                        logger.warning(unread
                            ? "Undo (New Folder): left \(url.path) in place — it could not be fully read, so it cannot be confirmed empty"
                            : "Undo (New Folder): left \(url.path) in place — it holds files or folders the undo did not put there")
                        target.banner = .warning(unread
                            ? "Undo left “\(name)” in place — its contents couldn’t be read"
                            : "Undo left “\(name)” in place — it isn’t empty", log: .loggedAtSite)
                    }
                    return
                }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    // A transient failure stays retryable, as in deleteItems and the copy-undo: a
                    // permanent-delete prompt could destroy a folder a retry would trash recoverably.
                    if FileSyncManager.isTransientTrashFailure(error) {
                        await FileSyncManager.reportUndoTransientTrashFailure(of: url, actionName: "New Folder", error: error, on: target)
                        return
                    }
                    // The folder was created empty, but the user may have filled it since —
                    // permanent removal gets the same confirmation as everywhere else.
                    let confirmed = await MainActor.run { confirmPermanentDelete([url.path]) }
                    if confirmed {
                        // Report the outcome either way: a failure after the user confirmed would
                        // otherwise look like success.
                        do {
                            try fm.removeItem(at: url)
                            _ = await MainActor.run {
                                Logger.shared.info("Undo (New Folder): permanently deleted \"\(url.lastPathComponent)\" at \(url.path) — it could not be moved to the Trash")
                            }
                        } catch {
                            await FileSyncManager.reportUndoRemoveFailure(
                                of: url, actionName: "New Folder", error: error, on: target)
                        }
                    } else {
                        _ = await MainActor.run {
                            Logger.shared.info("Undo (New Folder): \"\(url.lastPathComponent)\" could not be moved to the Trash and the user declined to delete it permanently — it is still on disk")
                        }
                    }
                }
            } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    func registerCreateFolderRedo(url: URL, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: New Folder")
            target.registerCreateFolderUndo(url: url, fileManager: fm)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } catch {
                    // The paired undo registered above skips when no directory exists at `url`,
                    // so a failed re-create stays a reported no-op instead of poisoning it.
                    await FileSyncManager.reportRedoFailure(of: url, actionName: "New Folder", error: error, on: target)
                }
            } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    /// Registers the redo of a delete, which re-trashes only what its undo actually restored
    /// (`itemsResolver` is filled after the restore loop), so an occupant that refused a restore is
    /// never trashed. Called only from `registerRestoreItems`. Each item is re-identified just before
    /// it is trashed, and a replacement at the path is refused. A path that is gone is skipped
    /// silently; the count line covers it.
    func registerTrashItems(itemsResolver: AsyncValueResolver<[TrashRedoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextResolver = AsyncValueResolver<[RestoreItemState]>()
            target.registerRestoreItems(stateResolver: nextResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let fmLocal = fm
                        let items = await itemsResolver.get()
                        var trashedItems: [RestoreItemState] = []
                        var refused = 0
                        var notTrashed = 0
                        for item in items {
                            let url = item.url
                            // `entryExists`: a dangling link the undo restored is still there.
                            guard FileSyncManager.entryExists(at: url, fileManager: fmLocal) else { continue }
                            // Re-identified right before the trash: "something is here" isn't "our
                            // item is here".
                            let verdict = item.restoredIdentity.drift(at: url, fileManager: fmLocal)
                            guard verdict == .unchanged else {
                                refused += 1
                                await FileSyncManager.reportRedoRefusedTrashOfChangedItem(
                                    at: url, actionName: actionName, verdict: verdict, on: target)
                                continue
                            }
                            var t: NSURL?
                            do {
                                try fmLocal.trashItem(at: url, resultingItemURL: &t)
                                if let trashed = t as? URL {
                                    trashedItems.append((original: url, trashedBackup: trashed,
                                                         backupIdentity: FileSyncManager.backupIdentity(trashed, fileManager: fmLocal)))
                                }
                            } catch {
                                // Was silent: the summary said "trashed 3 of 4" with no path or reason.
                                notTrashed += 1
                                logger.error("Redo (\(actionName)): FAILED to move \(url.path) to the Trash — "
                                             + "\(FileSyncManager.trashFailureDiagnosis(error))")
                            }
                        }
                        await nextResolver.resolve(trashedItems)
                        logger.info("Redo (\(actionName)): trashed \(trashedItems.count) of \(items.count) item(s)"
                                    + (refused > 0 ? ", refused \(refused) that changed since the undo" : "")
                                    + (notTrashed > 0 ? ", \(notTrashed) couldn't be trashed" : ""))
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Registers the undo of a delete, which restores each item from the Trash. The redo list is
    /// resolved after the restore loop, from successful restores only, so a redo never trashes an
    /// occupant that refused a restore.
    func registerRestoreItems(stateResolver: AsyncValueResolver<[RestoreItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoItemResolver = AsyncValueResolver<[FileSyncManager.TrashRedoItemState]>()
            target.registerTrashItems(itemsResolver: redoItemResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                    let items = await stateResolver.get()
                    var restored = 0
                    var restoreFailures = 0
                    var restoredItems: [FileSyncManager.TrashRedoItemState] = []
                    for item in items {
                        try? fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                        // Read once, so the refusal reports the verdict that chose it.
                        let backupVerdict = FileSyncManager.trashBackupVerdict(
                            recorded: item.backupIdentity, at: item.trashedBackup, fileManager: fm)
                        if FileSyncManager.entryExists(at: item.original, fileManager: fm) {
                            // Something else, even a dangling link, now holds the original location.
                            // Refuse rather than trash it: the item stays in the Trash and out of the
                            // redo list.
                            restoreFailures += 1
                            await FileSyncManager.reportUndoRestoreFailure(of: item.original, from: item.trashedBackup, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                        } else if backupVerdict != .unchanged {
                            // The item in the Trash isn't the one this delete put there. It stays
                            // there, and out of the redo list.
                            restoreFailures += 1
                            await FileSyncManager.reportUndoRefusedTrashStranger(
                                at: item.trashedBackup, restoring: item.original, actionName: actionName,
                                verdict: backupVerdict, on: target)
                        } else {
                            do {
                                _ = try FileSyncManager.safeMoveItem(at: item.trashedBackup, to: item.original, fileManager: fm)
                                restored += 1
                                // Only a real restore is redoable. It is identified after the move, so
                                // the redo can tell it from whatever is at the path later. Shallow on
                                // purpose: the redo only trashes, which is recoverable, so a deep walk
                                // per folder would buy little. Shallow still catches another folder at
                                // the path or a changed direct child, and ignores `.DS_Store`.
                                restoredItems.append((url: item.original,
                                                      restoredIdentity: ItemIdentity.snapshot(at: item.original, fileManager: fm)))
                            } catch {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.original, from: item.trashedBackup, actionName: actionName, error: error, on: target)
                            }
                        }
                    }
                    await redoItemResolver.resolve(restoredItems)
                    logger.info("Undo (\(actionName)): restored \(restored) of \(items.count) deleted item(s) from Trash, \(restoreFailures) restore failure(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
}

/// Hands state produced by a background file operation (Trash URLs, say) to an undo/redo block
/// that was registered synchronously before it existed.
actor AsyncValueResolver<T: Sendable> {
    private var result: T?
    private var continuations: [CheckedContinuation<T, Never>] = []
    
    func resolve(_ value: T) {
        if result != nil { return }
        result = value
        for cont in continuations { cont.resume(returning: value) }
        continuations.removeAll()
    }

    func get() async -> T {
        if let value = result { return value }
        return await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }
}
