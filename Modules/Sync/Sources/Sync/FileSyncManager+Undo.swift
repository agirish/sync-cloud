import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    /// `CopyItemState` enriched with the copied item's identity as read when the undo was
    /// registered. The undo handler refuses to trash a destination whose identity no longer
    /// matches — the item was replaced or edited since the copy — and equally refuses when the
    /// identity cannot be read at all.
    ///
    /// This was a `destinationSize: Int?` guarded with `if let expected`, which is two defects in
    /// one line. `fileSizeSnapshot` answers nil for a DIRECTORY, deliberately, so `if let` skipped
    /// the guard entirely and undo of a copied folder had no drift check at all — copy a folder,
    /// let 200 files land in it, press ⌘Z, and on a Trash-less volume they were destroyed under a
    /// "removed 1 of 1" log line. And for files the comparison was size-only, so any same-length
    /// rewrite (2025→2026) compared equal and was trashed as though untouched.
    ///
    /// For a directory the identity recorded here is the DEEP one (`ItemIdentity.deepSnapshot`,
    /// `.directoryTree`): this undo trashes, so it must also notice an edit made deep inside the
    /// copy — which leaves the root's own date and child count identical and so slipped past the
    /// shallow `.directory` identity that used to be recorded here. See `registerCopyUndo(items:)`
    /// for the cost, and the move typealiases below for why THEY stay shallow.
    typealias CopyUndoItemState = (source: URL, destination: URL, overwritten: URL?, destinationIdentity: ItemIdentity)
    /// A copied item whose identity walk the CALL SITE already started — the moment the item's
    /// OWN copy landed, inside its batch loop — rather than when the whole batch finished.
    /// `identity` is that walk's task (`startCopyIdentityWalk`); it resolves to exactly what
    /// `CopyUndoItemState.destinationIdentity` records. This is what keeps the copy-to-recording
    /// window per ITEM: a batch blocks mid-run on user prompts (collision and name checks await
    /// the main actor per item) and on slow-volume I/O, so a post-batch walk would record an edit
    /// the user made during that tail as the copy's baseline — and a later ⌘Z would trash it as
    /// `.unchanged`. See `registerCopyUndo(pendingItems:)`.
    typealias PendingCopyItemState = (source: URL, destination: URL, overwritten: URL?, identity: Task<CopyIdentityReading, Never>)
    /// What one registration-time identity read yields: the identity itself, plus — when it came
    /// back `.indeterminate` — the descendant that made it so. The second half exists only to be
    /// REPORTED: it is what makes an eventual permanent ⌘Z refusal diagnosable. It rides along
    /// rather than being logged where it is read so that a batch can say it once instead of once
    /// per item; see `logIndeterminateRegistrations`.
    typealias CopyIdentityReading = (identity: ItemIdentity, unreadableDescendant: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)
    /// `MoveItemState` enriched with the identity the moved item had once the move completed, so
    /// the undo can verify that what sits at `to` now is still what it put there.
    ///
    /// The move-undo's only guard was that `from` is free. Nothing checked `to`. Drop a newer v2
    /// at the destination in Finder and press ⌘Z: v2 was moved away to the source path and the
    /// older version restored over it, reported as a full success. The doc comment claiming the
    /// move-undo carries a "still the same item?" guard described the occupancy check, which
    /// answers a different question.
    ///
    /// Enriched inside `registerMoveUndo` rather than added to `MoveItemState`, so the nine call
    /// sites that build a move state keep passing what they already build.
    ///
    /// **Nine, and `d650da77`'s commit message says eight.** Eight is the maintenance lines' count:
    /// `applyRenamePlans` lives in `FileSyncManager+FilingRename.swift`, which exists on `main`
    /// alone, and the figure travelled here with the cherry-pick. The code was written against
    /// `main` and is right; only the message is wrong, and a message cannot be corrected without
    /// rewriting history, so it is corrected here. Counted rather than remembered, and the nine are
    /// named so a future recount can be checked against them rather than re-derived: `+BulkSync`,
    /// `+FilingRename`, `FileSyncManager.swift`, `+NameNormalize`, `FileOperations.swift` ×2,
    /// `+Filing` ×2, `+Automations`. A grep for the count has to exclude this file's own
    /// declarations and doc mentions, which is exactly the mistake `d650da77` records correcting
    /// when it found `liveLocation` saying "ten".
    typealias MoveUndoItemState = (from: URL, to: URL, overwritten: URL?, movedIdentity: ItemIdentity)
    /// What a move-REDO needs to re-apply one item: where its undo put the item back, where the
    /// original move had sent it, and the identity read at `from` the instant the undo landed it
    /// there.
    ///
    /// The identity is the whole reason this is not a bare `(from:to:)` pair. A redo moves, so it
    /// destroys, and it was gating on nothing but `fileExists(from)` — an existence test standing
    /// in for an identity question, exactly as `liveLocation` was. Its undo re-snapshots the item
    /// at `to` for the NEXT undo already, so recording the source costs one more stat on a path
    /// that was taking one anyway.
    typealias MoveRedoParam = (from: URL, to: URL, sourceIdentity: ItemIdentity)
    /// A restore the delete-undo actually performed, plus the identity the restored item had the
    /// instant it landed — so the paired redo can refuse to trash something that is no longer it.
    ///
    /// The identity is the whole reason this is not a bare `URL`, exactly as `MoveRedoParam` is not
    /// a bare `(from:to:)` pair: a redo trashes, and a path is not an identity.
    typealias TrashRedoItemState = (url: URL, restoredIdentity: ItemIdentity)
    /// One deleted item awaiting a possible undo-restore: where it lived, and where the Trash
    /// holds its backup. Only items that actually reached the Trash are represented — a delete
    /// that fell through to a permanent remove has nothing to restore.
    typealias RestoreItemState = (original: URL, trashedBackup: URL)

    /// Error raised when an undo/restore would land on a location that a different item has taken
    /// since the original operation — reported instead of silently overwriting the occupant.
    nonisolated static var restoreTargetOccupiedError: Error {
        NSError(domain: "SyncCloud.Undo", code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "the original location is already occupied by another item"])
    }

    /// Surfaces a failed undo/redo restore instead of swallowing it. When an undo trashes or removes
    /// the current file and the restore of the original then fails — typically because the Trash
    /// backup was emptied or auto-purged between the operation and the undo — the destination is left
    /// EMPTY. The old best-effort `try?` gave the user no log line and no signal; this logs the
    /// affected paths at `.error` and raises a warning banner on the main actor so the loss is visible.
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
            target.banner = .warning("Undo couldn't restore the original of \"\(name)\" — it may have been removed from the Trash")
        }
    }

    /// Surfaces a failed redo re-apply instead of swallowing it. When a redo's copy/move/mkdir
    /// fails — typically because the source vanished between the undo and the redo — the old
    /// best-effort `try?` gave no log line and no banner, yet still registered the item in the
    /// next undo state, so a subsequent undo operated on a phantom item (up to a confusing
    /// permanent-delete prompt for a file not on disk). This logs the failure at `.error` and
    /// raises a warning banner; callers must also leave the failed item out of the next undo state.
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
            target.banner = .warning("Redo couldn't re-apply \"\(name)\" — its source may no longer exist")
        }
    }

    /// Surfaces a copy-undo permanent delete that failed after the user confirmed it. The copied
    /// item survives on disk, so its `overwritten` backup must stay where it is (restoring it
    /// would collide with the survivor), and the caller leaves the item OUT of the redo params —
    /// they are resolved after the removal loop from only the copies actually undone, so a later
    /// redo skips the survivor instead of re-copying over it.
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
            target.banner = .warning("Undo couldn't remove \"\(name)\" — it is still on disk")
        }
    }

    /// What a refused undo was about to do to the item, for `reportUndoRefusedChangedItem`. The
    /// two callers do genuinely different things to genuinely different items, and one sentence
    /// cannot be true of both.
    enum RefusedUndoIntent: Sendable {
        /// The copy-undo: it would have REMOVED the item, and that item is the one the copy — the
        /// operation this undo reverses — put there.
        case removeTheCopyItProduced
        /// The move-undo: it would have MOVED the item back to where it came from. Nothing is
        /// removed, and the undo did not produce the item; the original move did.
        case moveItBackToItsSource
    }

    /// Surfaces an undo that was REFUSED because the item it was about to remove or move is no
    /// longer the item the undo was registered for. Trashing or displacing it would destroy work
    /// the undo was never asked to reverse; the item is left in place, its `overwritten` backup
    /// stays in the Trash, and the caller keeps the item out of the redo params (a refused item
    /// must never be redone).
    ///
    /// `verdict` distinguishes the two refusals, which are not the same event to a person reading
    /// the log: `.changed` means the item demonstrably differs, `.indeterminate` means it could
    /// not be read and so nothing can be concluded. Both refuse — an unverifiable item is exactly
    /// the one not to destroy — but only the first is evidence that something was edited.
    ///
    /// `intent` exists because this doc comment said "remove **or move**" while the sentence it
    /// produced could only say *remove*: a refused MOVE-undo logged `REFUSED to remove "doc.txt" …
    /// it is no longer the item this undo produced`, and both halves were false — nothing was
    /// going to be removed (a move-undo moves it back), and the undo did not produce the item, the
    /// original operation did. Shipped because all four refusal tests asserted only the banner.
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
            bannerMessage = "Undo left \"\(name)\" in place — it changed since"
        case .indeterminate:
            logMessage = "Undo (\(actionName)): REFUSED to \(refusedAction) — its current state could not be read, so it cannot be confirmed as \(identity); leaving it in place"
            bannerMessage = "Undo left \"\(name)\" in place — it couldn't be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted so a future verdict has to be
            // decided here rather than quietly reported as a change.
            logMessage = "Undo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Undo left \"\(name)\" in place"
        }
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning(bannerMessage)
        }
    }

    /// Surfaces a move-undo refused because the identity recorded for the item is itself `.absent`
    /// — there was nothing at the destination when the undo was REGISTERED, so there is nothing
    /// this undo can be moving back.
    ///
    /// Separate from `reportUndoRefusedChangedItem` because neither of that reporter's two
    /// sentences is true here: nothing changed (both sides are absent, which is why `compare`
    /// answers `.unchanged`), and nothing failed to be read. Separate from the `vanished`
    /// breadcrumb too — "no longer on disk" claims the item was on disk and the user removed it,
    /// and a recorded `.absent` says the opposite.
    ///
    /// What it prevents is not a wrong sentence but a wrong ACT: `.unchanged` selected the move
    /// branch, whose first statement recreates the source's parent directory, so a doomed undo
    /// built a folder before failing — the very manufacture the branch's own comment says a
    /// refusal must never perform.
    nonisolated static func reportUndoRefusedUnrecordedItem(
        of destination: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): REFUSED to move \"\(name)\" back to its original location — nothing was recorded at \(destination.path) when this undo was registered, so there is no item to move back; leaving the disk exactly as it is"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo left \"\(name)\" in place — there was nothing to move back")
        }
    }

    /// Surfaces a REDO that was refused because the item it was about to move back to the
    /// destination is no longer the item its undo put at the source. The undo path has refused this
    /// for both of its own guards since `ItemIdentity` landed; the redo path had nothing, and
    /// gated only on the source PATH existing.
    ///
    /// Measured before this existed: move `/src/report.txt` → `/dst/report.txt`, ⌘Z, then create a
    /// DIFFERENT `/src/report.txt` and an unrelated `/dst/report.txt`, then ⌘⇧Z. The redo moved the
    /// file the user had just created, replaced the unrelated file at the destination, left nothing
    /// at the source, and reported nothing at all — no log line, no banner. A redo is as
    /// destructive as an undo and gets the same refusal.
    ///
    /// A source that is simply GONE is NOT this case: nothing is there to move, and
    /// `reportRedoFailure` already says exactly that. This is only for a source that is present and
    /// demonstrably not ours (`.changed`) or that cannot be read at all (`.indeterminate`).
    ///
    /// **"Gone" has to be re-established at the move, not remembered from the pass.** A source
    /// found absent up front and PRESENT again by the time its own move runs is not the gone case
    /// at all — it is this one, and reporting it as a missing source would credit the redo with
    /// having nothing to move while it moved a stranger.
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
            bannerMessage = "Redo left \"\(name)\" in place — it changed since"
        case .indeterminate:
            logMessage = "Redo (\(actionName)): REFUSED to re-apply \"\(name)\" from \(source.path) — its current state could not be read, so it cannot be confirmed as the item this redo moves; leaving it in place"
            bannerMessage = "Redo left \"\(name)\" in place — it couldn't be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted so a future verdict has to be
            // decided here rather than quietly reported as a change.
            logMessage = "Redo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Redo left \"\(name)\" in place"
        }
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning(bannerMessage)
        }
    }

    /// Surfaces a delete-REDO that was refused because the item at the restored path is no longer
    /// the item its undo put there.
    ///
    /// The sibling of ``reportRedoRefusedChangedItem(of:actionName:verdict:on:)`` for the other
    /// destructive redo, and it exists for the reason that one states: a redo is as destructive as
    /// an undo and gets the same refusal. The wording differs because the outcome does — this one
    /// would have put the stranger in the Trash rather than moved it somewhere.
    ///
    /// An ABSENT path never reaches here; it is skipped before the identity is read, because
    /// nothing being there is not a drift and there is nothing to leave in place.
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
            bannerMessage = "Redo left \"\(name)\" in place — it changed since"
        case .indeterminate:
            logMessage = "Redo (\(actionName)): REFUSED to trash \"\(name)\" at \(url.path) — its current state could not be read, so it cannot be confirmed as the item this redo deletes; leaving it in place"
            bannerMessage = "Redo left \"\(name)\" in place — it couldn't be checked"
        case .unchanged:
            // Not a refusal. Spelled out rather than defaulted for the same reason the move-redo
            // reporter spells it out: a future verdict has to be decided here.
            logMessage = "Redo (\(actionName)): refusal reported for \"\(name)\" with an unchanged verdict — this is a programming error"
            bannerMessage = "Redo left \"\(name)\" in place"
        }
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning(bannerMessage)
        }
    }

    /// Surfaces a TRANSIENT trash failure during an undo (the item is busy/locked or momentarily
    /// permission-blocked — see `isTransientTrashFailure`). Such failures must stay retryable:
    /// escalating them to the permanent-delete prompt could destroy a file that a retry would
    /// have moved to the Trash recoverably. The item stays on disk and out of the redo params.
    nonisolated static func reportUndoTransientTrashFailure(
        of destination: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): couldn't move \"\(name)\" at \(destination.path) to the Trash — transient failure, left in place for a retry instead of escalating to a permanent delete (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo couldn't remove \"\(name)\" — it looks busy; try again")
        }
    }

    /// The byte size of the regular FILE at `url`, or nil for directories, missing, or
    /// unstatable items.
    ///
    /// **No longer drives any guard.** It used to be the copy-undo's drift snapshot, and its nil
    /// — meaning "directory" *or* "missing" *or* "unstatable" alike, read through an `if let` —
    /// is why a copied FOLDER had no drift check at all and why a same-length rewrite compared
    /// equal. `ItemIdentity` replaced it at both undo sites; nothing in the app, the CLI or the
    /// undo path calls this any more.
    ///
    /// It stays because `ItemIdentityTests` measures it: two of that suite's expectations run this
    /// function against the very fixtures `ItemIdentity` now handles, so "nil for a directory" and
    /// "4 for an edited 4-byte file" are recorded facts about the thing that was replaced rather
    /// than a claim in a comment. (Same reasoning that keeps `scanNames` alive for
    /// `NameNormalizerTests`.) Delete it only together with those expectations.
    nonisolated static func fileSizeSnapshot(at url: URL, fileManager fm: FileManaging) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory { return nil }
        return (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
    }

    /// Every path a move in `batch` renamed away, keyed by its OLD path — `liveLocation`'s lookup
    /// table, built ONCE per batch by the caller rather than once per item.
    ///
    /// Separated out because folding it into `liveLocation` made `registerMoveUndo(items:)`
    /// quadratic on the MAIN ACTOR: it calls `liveLocation` per item and each call rebuilt the
    /// whole table from the whole batch. Measured (debug build, before the split): n=100 → 0.015 s,
    /// n=1000 → 1.70 s, n=3000 → **14.6 s**, n=6000 → 52.1 s of added main-thread time right after
    /// a bulk move — reachable from a multi-select move and from `normalizeNames`, both of which
    /// can hand over thousands of items.
    /// `theUndoRegistrationOfThreeThousandItemsStaysUnderThreeSeconds` is what keeps it from
    /// creeping back — and its name says what it can actually see: one point against a ceiling,
    /// which separates a three-orders-of-magnitude blow-up from the current cost and would not
    /// notice a merely 10× regression.
    nonisolated static func renameMap(for batch: [MoveItemState]) -> [String: String] {
        var renames: [String: String] = [:]
        for move in batch where move.from.path != move.to.path {
            renames[move.from.path] = move.to.path
        }
        return renames
    }

    /// Where `destination` — a path some item in a move batch was moved TO — actually sits once
    /// every OTHER move in that same batch has been applied. `renames` is that batch's
    /// `renameMap(for:)`.
    ///
    /// Only ANCESTOR components are rewritten, and only when another move's `from` is a strict
    /// ancestor of `destination`. A batch that renames ancestors first leaves no old name to
    /// match, so nothing is rewritten and the path is returned as-is — which is every single-item
    /// batch and every same-directory batch, i.e. all but one of the nine call sites.
    ///
    /// **A rewrite also has to be confirmed against the disk, because the ancestor condition alone
    /// is not proof.** The claim it used to rest on — "`destination` can still spell an ancestor's
    /// OLD name only if the item landed there before that ancestor was renamed" — is false for a
    /// batch that mixes NESTED provider roots, which `SettingsManager.existingSource` allows: with
    /// roots `/P` and `/P/Backup`, a multi-select move can move `/P/Backup/D` first and then let
    /// `ensureParentDirectoryExists` recreate `/P/Backup/D` under the item that lands second, so
    /// that item IS at its recorded `to` and rewriting the path walks it off into
    /// `/P/Backup/Backup/D/…`, snapshotting `.absent` and falsely refusing the undo.
    ///
    /// **The confirmation asks the DISK about the rewrite, not about the recorded path — because
    /// `fileExists` cannot tell OUR item from any item.** Written the other way round ("if
    /// something is still at `destination`, it did not go anywhere") this trusted a STRANGER: let a
    /// normalize pass turn `/root/P␣/a␣.txt` into `/root/P/a.txt`, then let the user recreate
    /// `/root/P␣` with an unrelated `a.txt` in it, and the recorded path is occupied again — by a
    /// file that has nothing to do with the batch. The snapshot was then taken OF the stranger, the
    /// undo's drift guard compared the stranger against itself, answered `.unchanged`, and moved
    /// it: measured on that fixture, ⌘Z renamed the user's unrelated file to `a␣.txt` — planting
    /// the very zero-width space the pass exists to remove — left the real item un-undone, and
    /// raised a banner naming a different item and blaming the Trash, which nothing went near.
    ///
    /// So the recorded path is trusted only when the REWRITTEN one is absent: nothing else can be
    /// there, so `destination` is the only candidate left. Ambiguity — both occupied — resolves to
    /// the rewrite, which makes the snapshot disagree with whatever sits at the recorded path and
    /// so makes the undo REFUSE. **That is the invariant this function is written to keep: a wrong
    /// answer here must cost a refusal, never a move of the wrong item.** The stats cost two calls,
    /// and only on the nested path where a rewrite was about to happen; every flat batch returns
    /// before reaching them.
    ///
    /// Resolution is recursive so a three-deep nest resolves fully (`/A-BAD/B-BAD/c.txt` →
    /// `/AOK/BOK/c.txt`), guarded by a `seen` set so a rename CYCLE stops rather than looping, and
    /// bounded by a depth cap so the `seen` guard's absence fails legibly instead of overflowing
    /// the stack. Giving up returns `destination`, which is the safe direction above.
    /// The leaf itself is never rewritten: an item is renamed once per batch, so its own name is
    /// final, and rewriting it would follow an unrelated item that happens to have taken the path —
    /// a renumbering cascade (`01 - x.pdf`→`02 - x.pdf` beside `02 - x.pdf`→`03 - x.pdf`) has one
    /// move's `to` equal to another's `from`, and would snapshot the wrong file.
    ///
    /// **`applyRenamePlans` is not a second exposure, and `4b21f9ed`'s message was wrong to say so.**
    /// It claimed the nested-rename fix "also fixes `applyRenamePlans`, which has the identical
    /// exposure"; that pass renames only FILES — `liveFiles` skips directories and passes
    /// `.skipsSubdirectoryDescendants` — and every `dst` is `dir.appendingPathComponent(…)` in the
    /// plan's own folder, so no move's `from` can be an ancestor of another move's `to` and this
    /// function is a strict no-op for every batch it produces. Both backports had already dropped
    /// the claim, but the reason they gave implies `main` has one, so it is corrected here rather
    /// than left to be rediscovered. What `applyRenamePlans` genuinely is, is the closest real
    /// producer of the LEAF collision above, so a leaf-rewriting `liveLocation` would find its
    /// first victim there.
    ///
    /// **But not for the reason this used to give, and the difference matters.** It said the
    /// cascades "stay safe only because the label travels with the number" (`01. Mar`→`02. Mar`
    /// beside `02. Apr`→`03. Apr`, never onto each other) — which contradicts the leaf rule three
    /// paragraphs up, whose whole justification is a cascade where one move's `to` IS another's
    /// `from`. Both cannot be true of the same producer, and the fixture the leaf rule is built on
    /// is the version the convention declares impossible. The convention is a property of today's
    /// planner.
    ///
    /// **The replacement reason was wrong too, and in the more dangerous direction: it declared the
    /// collision unproducible.** It credited the never-overwrite fallback at
    /// `FileSyncManager+FilingRename.swift:251-258` — a `dst` already occupied by a DIFFERENT item
    /// is diverted through `generateUniqueURL` — and concluded that "no applied step can land on a
    /// path another step is still sourcing from, whatever the planner names things". That fallback
    /// tests `fileExists` at APPLY time, per step, in `plan.steps` order, so it blocks the
    /// collision only for a step whose target is still occupied. For an EARLIER one the path has
    /// already been vacated and no diversion happens: a descending renumber `03→04`, `02→03`,
    /// `01→02` moves `03` away first, so `02→03` finds `03` free, takes it, and produces a move
    /// whose `to` is exactly another move's `from`. `applyRenamePlans` is therefore a real producer
    /// of the leaf collision, which is what the paragraph above already assumes and what the leaf
    /// rule is here to survive — and that is the whole answer. Nothing needs to make `to == from`
    /// impossible; not rewriting the leaf is what makes it harmless.
    ///
    /// The habit worth keeping from both wrong versions: a guard whose stated reason is not its
    /// operative reason is one planner change away from being silently wrong. Stating a guarantee
    /// the code does not have is worse still, because it invites the guard's removal.
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

    /// How many frames `resolveRenamedDirectory` may take before it abandons the resolution.
    ///
    /// One frame per path component plus one per rename hop. `PATH_MAX` is 1024 BYTES, so a real
    /// path cannot carry more than ~512 components even at two bytes each, and every path this app
    /// has ever seen is under fifty; a rename CHAIN long enough to add hundreds more would have to
    /// be a renumbering cascade of that many DIRECTORIES in one batch. 512 is therefore far outside
    /// anything producible, and deliberately small enough that hitting it cannot itself overflow a
    /// stack: these frames are a few hundred bytes each, so the whole cap fits inside the 512 KB a
    /// non-main thread gets — which matters because the tests that exercise it do not run on the
    /// main actor, and a cap that crashed on the way to reporting itself would be no cap at all.
    private nonisolated static let maxRenameResolutionDepth = 512

    /// `liveLocation`'s worker: the path `path` reads as after `renames` are applied to it and to
    /// every one of its ancestors, or nil if the resolution ran past `maxRenameResolutionDepth`.
    /// `seen` bounds a cycle (A→B, B→A) to one lap.
    ///
    /// **`seen` is unreachable from production, and stays anyway.** The only caller of
    /// `liveLocation` is `registerMoveUndo(items:)`, and every batch reaching it was applied
    /// sequentially against a real filesystem through `safeMoveItem`: for A→B and B→A both to be
    /// recorded, whichever ran second would have had to move onto a path the first one had just
    /// filled, which `safeMoveItem`'s collision handling turns into a replace (one item, not a
    /// cycle) rather than a second rename. So no input can reach the guard today. What it costs is
    /// three lines; what its absence costs is not a wrong answer but an unbounded recursion — a
    /// stack-overflow crash of the whole app, from a batch nobody could inspect afterwards. That
    /// is the wrong side to be cheap on, so it stays, and `liveLocationStopsAtOneLapOfACycle`
    /// pins the exact path it produces rather than accepting "either lap".
    ///
    /// **The depth cap is what makes that guard's absence legible.** Deleting `seen` used to be
    /// invisible to the suite in the worst possible way: the recursion never returned, the test
    /// host died with `exited with unexpected signal code 10`, and the run ended with no
    /// `Test run with N tests` line at all — so the regression reported as broken infrastructure
    /// and took every other verdict in the run with it. With the cap, the same deletion runs out of
    /// frames, answers nil, and `liveLocation` returns the recorded path, which its own tests then
    /// disprove as an ordinary red assertion. The cap is a BACKSTOP, not a replacement: `seen` is
    /// what gives a cycle its correct one-lap answer, and nil is only ever a refusal.
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

    /// Outcome of putting an undo's displaced `.overwritten` backup back at the destination.
    enum UndoRestoreOutcome { case restored, failed, nothingToRestore }

    /// Restores the backup a copy-undo displaced (`overwritten`) onto `destination`, surfacing any
    /// failure via `reportUndoRestoreFailure`. Shared by `registerCopyUndo`'s two removal paths —
    /// the Trash path and the confirmed permanent-delete fallback — so the restore-and-report logic
    /// lives in one place.
    nonisolated static func restoreOverwrittenBackup(
        _ overwritten: URL?,
        to destination: URL,
        actionName: String,
        fileManager fm: FileManaging,
        on target: FileSyncManager
    ) async -> UndoRestoreOutcome {
        guard let overwritten else { return .nothingToRestore }
        do {
            try fm.moveItem(at: overwritten, to: destination)
            return .restored
        } catch {
            await reportUndoRestoreFailure(of: destination, from: overwritten, actionName: actionName, error: error, on: target)
            return .failed
        }
    }

    /// Any change to the undo stack invalidates a still-showing *undoable* completion banner: its
    /// Undo button pops the current top step, so once a different operation is registered (or an
    /// undo/redo re-registers its reverse), the button would reverse the WRONG operation. Clearing
    /// the banner here removes the affordance the moment it goes stale. The op that WANTS a banner
    /// registers its undo first and posts the banner after, so its own banner survives; non-undoable
    /// (warning/error) banners are left alone — an error must not vanish because an unrelated op ran.
    private func invalidateUndoableBanner() {
        if banner?.isUndoable == true { banner = nil }
    }

    /// Convenience for call sites whose copied items are fully known at registration time: wraps
    /// them in an `AsyncValueResolver` that a detached identity walk resolves, so the
    /// resolver-based form below stays the single implementation. The resolver forms remain for
    /// the undo/redo chain, where the next state genuinely resolves later (inside the queued
    /// file operation).
    ///
    /// Snapshots each copied item's identity for the undo handler, which refuses to trash a
    /// destination that is no longer the item this copy produced — and it takes the DEEP
    /// snapshot, because this undo DESTROYS. `deepSnapshot` digests every descendant, so an edit
    /// made two levels down inside the copy — which leaves the root's own date and child count
    /// identical, the exact case the shallow identity's doc admitted it "answers `.unchanged`
    /// for" — changes the identity and the ⌘Z refuses instead of trashing the only instance of
    /// the edit. The move registrations below stay SHALLOW on purpose; each says why at its own
    /// snapshot.
    ///
    /// **The walk runs OFF the main actor, and the ordering that keeps that safe is spelled out
    /// here because every caller leans on it.** The undo is registered with the undo manager
    /// synchronously, before this returns — unchanged from when the walk was inline — and only
    /// the IDENTITY arrives later, resolved by the detached task this returns. So a ⌘Z landing
    /// before the walk finishes pops THIS undo, never the operation before it, and its handler
    /// suspends in `stateResolver.get()` until the identity exists — a not-yet-resolved
    /// registration can neither no-op nor compare against a half-recorded state. Inline, the
    /// walk was the one main-actor stall in the whole chain: `FileSyncManager` is `@MainActor`,
    /// so copying a big folder froze the UI for the length of its walk — measured 2026-08-21, a
    /// 40,200-node tree (200 dirs × 200 files) costs ~1.8 s of recursive listing+stat on this
    /// machine even cache-warm — and SMB or cold iCloud metadata turns that into minutes.
    ///
    /// **The returned task completes when the identity is recorded.** The copy/sync call sites
    /// await it as the last step of the operation, which is what keeps "the operation returned"
    /// implying "its undo is fully armed" — the property the drift tests (tamper the moment the
    /// copy returns, then ⌘Z) are written against. A caller that discards it loses only that
    /// determinism, never the guard.
    ///
    /// Residual, stated — and this convenience is for SINGLE-item call sites only (`syncFile`),
    /// where the copy-to-recording gap really is milliseconds: the identity is read moments
    /// after the copy rather than in the same main-actor turn, so an edit landing inside that
    /// gap is recorded as part of the copy and a later ⌘Z will trash it. Out-of-process writers
    /// always had that window. A BATCH must not funnel through here: this walk starts only when
    /// the whole batch is done, and a batch blocks mid-run on user prompts and slow-volume I/O
    /// — user-unbounded time during which an edit inside an already-landed copy would become
    /// that copy's baseline. Batch loops start each item's walk as its own copy lands
    /// (`startCopyIdentityWalk`) and register through `registerCopyUndo(pendingItems:)`.
    ///
    /// Cost: one stat-only recursive walk per copied folder (no bytes are read), at the moment
    /// the copy just finished and the tree's metadata is warm. The duplicates path already
    /// accepts the same trade for the same reason — `folderDriftedInPlace`: "one recursive walk
    /// per folder copy, at the moment of a destructive click — the alternative is trashing the
    /// last copy of 1,200 photos to save it."
    @discardableResult
    func registerCopyUndo(items: [CopyItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) -> Task<Void, Never> {
        let resolver = AsyncValueResolver<[CopyUndoItemState]>()
        // Registered before the walk is even spawned: no suspension can separate the caller
        // from the registration, which is the first half of the ordering guarantee above.
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
                                 overwritten: item.overwritten, destinationIdentity: read.identity))
            }
            FileSyncManager.logIndeterminateRegistrations(unreadable, of: items.count, actionName: actionName)
            await resolver.resolve(enriched)
        }
    }

    /// Batch registration over identity walks the call site already started, one per item, the
    /// moment that item's own copy landed (`PendingCopyItemState`). The registration contract is
    /// identical to `registerCopyUndo(items:)` — the undo is registered synchronously before the
    /// first suspension, the handler suspends in the resolver until every identity exists, and
    /// the returned task completes when the state is recorded (callers await it as the
    /// operation's last step). Only WHEN each identity is read differs, and that is the point:
    /// per item at copy-land time, not per batch at loop-end time.
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
                                 destinationIdentity: read.identity))
            }
            FileSyncManager.logIndeterminateRegistrations(unreadable, of: pendingItems.count, actionName: actionName)
            await resolver.resolve(enriched)
        }
    }

    /// Starts the detached identity walk for ONE landed copy. Batch call sites call this the
    /// moment each item's own copy returns — inside the transfer/bulk loops — so the
    /// copy-to-recording window stays milliseconds even when the rest of the batch then blocks
    /// on a user prompt or hours of I/O; an edit the user makes during that tail reads as drift
    /// (⌘Z refuses) instead of being recorded as the copy's baseline. The task feeds
    /// `registerCopyUndo(pendingItems:)`.
    ///
    /// **Deliberately UNBOUNDED, against the `processInParallel(concurrency: min(4, …))` this
    /// codebase uses everywhere else it fans out — measured, not assumed.** A 5,000-file bulk sync
    /// spawns 5,000 of these, each doing blocking `stat` work on the cooperative pool alongside the
    /// copy workers, and since `tree-3` a folder walk digests `.git`, `.build` and `node_modules`
    /// too. Measured on this machine (10 cores, APFS, warm):
    ///
    /// | shape                                   | unbounded | serial |
    /// |-----------------------------------------|-----------|--------|
    /// | 5,000 file walks (one stat each)        |  0.095 s  | 0.22 s |
    /// | 4 folder walks, 10k nodes               |  0.24 s   | 0.60 s |
    /// | 16 folder walks, 40k nodes              |  1.53 s   | 5.01 s |
    ///
    /// Two facts decide it. First, **"5,000 spawned" is not 5,000 running**: `Task.detached` puts
    /// them on the cooperative pool, which is capped at the core count — the 5,000-file run's
    /// measured PEAK concurrency was 10, exactly `activeProcessorCount`. The fan-out is already
    /// bounded, by the runtime, at the width of the machine. A `min(4, …)` cap would only make it
    /// narrower than the hardware, and every measurement above says narrower is slower.
    ///
    /// Second, and the reason a cap would be a correctness regression rather than a tuning
    /// choice: a capped walk STARTS LATE. Item 5,000 of a batch would not begin its walk until
    /// 4,996 others had finished — which is the end of the batch, i.e. exactly the
    /// copy-to-recording window the per-item start exists to eliminate. An edit made in that
    /// window becomes the copy's recorded baseline and ⌘Z trashes it.
    ///
    /// What the walks DO cost is `copyItems`' tail, where `activeProgress` is still published at
    /// 100% while the registration awaits them: measured over a 4-folder, 10,000-file batch, the
    /// whole call took 1.36–1.66 s with the walks and 0.98–1.17 s with them stubbed out — ~0.45 s
    /// of tail, which is the walks' own standalone cost rather than contention with the copies.
    /// If that tail ever needs shortening the lever is the walk's own work, not its width.
    nonisolated static func startCopyIdentityWalk(at destination: URL, fileManager fm: FileManaging) -> Task<CopyIdentityReading, Never> {
        Task.detached(priority: .userInitiated) {
            recordedCopyIdentity(at: destination, fileManager: fm)
        }
    }

    /// The identity every copy-undo registration records for one landed copy: the DEEP snapshot,
    /// plus the one warning that makes an eventual refusal diagnosable. A registration-time
    /// `.indeterminate` is a PERMANENT refusal for that item — the handler will decline the ⌘Z
    /// however often it is pressed — and the user used to first learn of it hours later from a
    /// banner that cannot say why, with the refusal itself as the log's only line. The cause is
    /// knowable NOW (the walk can name the descendant it could not read), so it is logged now.
    nonisolated static func recordedCopyIdentity(at destination: URL, fileManager fm: FileManaging) -> CopyIdentityReading {
        ItemIdentity.deepSnapshotDetailingFailure(at: destination, fileManager: fm)
    }

    /// The ONE line a batch leaves behind when some of its registration-time identity reads came
    /// back `.indeterminate`. Emits nothing when none did.
    ///
    /// **One line, not one per item, and the cap is the reason.** `Logger.shared.entries` holds
    /// the last 1000 entries, so a batch registered over an unreadable tree — a permissions
    /// problem, an unmounted network volume, a provider that stopped answering — used to emit a
    /// warning per item and push the surrounding context, including whatever explains the cause,
    /// out of the buffer. Same shape and the same reason as `SyncHistoryStore.appendBatch`'s
    /// dropped-record report: count them, name the first, say what it costs.
    ///
    /// A single-item batch reads exactly as it did before this was a batch report, because for
    /// N == 1 there is nothing to summarize.
    nonisolated static func logIndeterminateRegistrations(
        _ unreadable: [(destination: URL, child: URL?)], of total: Int, actionName: String
    ) {
        guard let first = unreadable.first else { return }
        let child = first.child.map { " — couldn't read \"\($0.path)\"" } ?? ""
        let subject = unreadable.count == 1
            ? "the identity of \"\(first.destination.lastPathComponent)\" at \(first.destination.path) couldn't be read when its undo was registered\(child); a later ⌘Z of this copy will refuse"
            : "\(unreadable.count) of \(total) items' identities couldn't be read when their undo was registered — first \"\(first.destination.lastPathComponent)\" at \(first.destination.path)\(child); a later ⌘Z of those copies will refuse"
        Logger.shared.warning("Copy undo (\(actionName)): \(subject) rather than remove what it can't verify")
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    func registerMoveUndo(items: [MoveItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        // Snapshots each moved item's identity HERE, at registration time — the move has already
        // happened, so the item this undo is responsible for is on disk — so the handler can
        // refuse to move back something that is no longer it.
        //
        // The SHALLOW snapshot, deliberately, where `registerCopyUndo` takes the deep one. The
        // two undos do different things to the item: the copy-undo TRASHES it, so a deep edit it
        // fails to notice is an edit destroyed; the move-undo MOVES it back, and an edit it fails
        // to notice travels with the folder — nothing is lost. A deep identity here would turn
        // that non-loss into a false refusal: edit any file inside a folder you moved and ⌘Z
        // would decline to move the folder back, "protecting" content that was never in danger.
        // The shallow check still catches what a move-back can genuinely clobber into being wrong
        // — the destination replaced wholesale, or reshaped at depth 1.
        //
        // Read at `liveLocation` rather than at `to` itself, because for a NESTED
        // batch `to` is not where the item is by the time registration runs. `normalizeNames`
        // applies renames deepest-first (a child renames inside its still-named parent, then the
        // parent is renamed around it) and registers shallowest-first, so the child's recorded
        // `to` — /root/Photos-BAD/aOK.txt — names a path that no longer exists once the parent
        // became /root/PhotosOK. Snapshotting there recorded `.absent`, and at undo time, with the
        // parent already restored, `.absent` vs the real file compared `.changed`: the child's
        // rename was refused and never reversed, a half-undone pass reported as drift that never
        // happened. `to` itself stays the recorded value — at undo time the parent IS restored
        // first, so `to` is again the right path to move back from.
        // Built ONCE for the whole batch: this loop is the reason `renameMap(for:)` is separate
        // from `liveLocation` — rebuilding it per item made a 3,000-item move cost 14.6 s of
        // main-actor time (see `renameMap(for:)`).
        let renames = FileSyncManager.renameMap(for: items)
        let enriched: [MoveUndoItemState] = items.map { item in
            (from: item.from, to: item.to, overwritten: item.overwritten,
             movedIdentity: ItemIdentity.snapshot(
                at: FileSyncManager.liveLocation(of: item.to, throughRenames: renames, fileManager: fm),
                fileManager: fm))
        }
        let resolver = AsyncValueResolver<[MoveUndoItemState]>()
        Task { await resolver.resolve(enriched) }
        registerMoveUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    /// `trashedItems[i]` is the Trash location of `urls[i]` (nil when it wasn't trashed —
    /// such items have no backup to restore, so they're dropped from the undo state here).
    func registerRestoreItems(urls: [URL], trashedItems: [URL?], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let items: [RestoreItemState] = zip(urls, trashedItems).compactMap { original, trashed in
            trashed.map { (original: original, trashedBackup: $0) }
        }
        let resolver = AsyncValueResolver<[RestoreItemState]>()
        Task { await resolver.resolve(items) }
        registerRestoreItems(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyUndoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        let confirmPermanentDelete = permanentDeleteConfirmer
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[(source: URL, destination: URL)]>()
            target.registerCopyRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)

            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let items = await stateResolver.get()

                        // Undoing a copy deletes the copied item. On volumes without Trash that
                        // deletion is permanent, so it needs the same user confirmation as
                        // deleteItems — never a silent removeItem fallback.
                        // Redo params are resolved from ONLY the copies actually undone (destination
                        // removed), not eagerly from every item — a copy whose undo was refused (trash
                        // failed AND the user declined the permanent delete) still exists on disk, so
                        // redoing it would re-copy over the survivor. `redoParamResolver` MUST be
                        // resolved on every exit (including the declined-confirmation early return) or
                        // a later redo would await it forever.
                        var trashFailures: [CopyUndoItemState] = []
                        var removed = 0
                        var restored = 0
                        var restoreFailures = 0
                        var leftInPlace = 0
                        var vanished = 0
                        var undoneCopies: [(source: URL, destination: URL)] = []
                        // Destinations THIS run already put into their pre-batch state. A batch
                        // can register one path twice (the second copy replaced the first): after
                        // item 1's trash, item 2 finds its destination "gone" — but not
                        // externally-gone, and restoring ITS backup would resurrect the
                        // intermediate copy item 1 just removed.
                        // Exact strings PLUS a folded form: a batch can register one on-disk
                        // file under two spellings ("F.txt" then "f.txt" via the replace
                        // prompt), and the second must be recognized as already handled or its
                        // backup restore resurrects content this run just removed. Folding is
                        // gated on the destination VOLUME's case semantics (per parent — on a
                        // case-sensitive volume two variants are two real files and only the
                        // exact match may skip); Unicode always precomposes (APFS/HFS+ lookups
                        // are normalization-insensitive on every volume).
                        var handledDestinations = Set<String>()
                        var handledFoldedDestinations = Set<String>()
                        var duplicateRegistrations = 0
                        // The fold decision is per destination PARENT, resolved once and CACHED:
                        // keys must be stable across the run (a parent vanishing mid-undo must
                        // not change set membership), and the answer must come from a real
                        // volume — resourceValues throws for a vanished path, and a fixed
                        // fallback inverts the guard's rule exactly when the vanished branch
                        // needs it (fail→fold skipped a REAL second file's restore on a
                        // case-sensitive volume). Walking up to the nearest existing ancestor
                        // answers for the volume the path lives on; volume semantics don't
                        // change within a subtree. Total failure ("/" unanswerable) stays
                        // exact-only: never skip a possibly-real file.
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
                        func markHandled(_ url: URL) {
                            handledDestinations.insert(url.path)
                            handledFoldedDestinations.insert(foldedKey(url))
                        }
                        func alreadyHandled(_ url: URL) -> Bool {
                            handledDestinations.contains(url.path)
                                || handledFoldedDestinations.contains(foldedKey(url))
                        }
                        for item in items {
                            if alreadyHandled(item.destination) {
                                duplicateRegistrations += 1
                                logger.debug("Undo (\(actionName)): \(item.destination.lastPathComponent) already handled by an earlier item of this run — skipping its duplicate registration")
                                continue
                            }
                            // A copy the user already deleted themselves: nothing to trash. For
                            // directories this used to fall through to trashItem (their nil size
                            // snapshot skips the drift guard below), whose no-such-file error is
                            // not transient — escalating to a permanent-delete prompt naming an
                            // item that isn't on disk; for files, the drift guard refused with a
                            // "changed" banner. Either way the overwritten backup stayed
                            // stranded. The undo's goal at this path is already met: restore the
                            // backup, keep the item in the redo params (a redo re-copies it),
                            // and log the breadcrumb. (registerCreateFolderUndo guards its
                            // missing-folder case the same way.)
                            if !fm.fileExists(atPath: item.destination.path) {
                                vanished += 1
                                markHandled(item.destination)
                                logger.info("Undo (\(actionName)): \(item.destination.lastPathComponent) is no longer on disk — nothing to remove")
                                undoneCopies.append((source: item.source, destination: item.destination))
                                switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                                case .restored: restored += 1
                                case .failed: restoreFailures += 1
                                case .nothingToRestore: break
                                }
                                continue
                            }
                            // "Still the same item?" drift guard: if the destination is no longer
                            // the item this copy produced, refuse to trash it and keep it out of
                            // the redo params. For a folder the recorded identity is DEEP
                            // (`.directoryTree`), and `drift` re-walks at that same depth here —
                            // so an edit buried levels down inside the copy refuses too, not just
                            // a change to the root's own date or immediate children.
                            //
                            // Switched rather than `if let`-ed, which is the fix: the verdict has
                            // three values and the old shape could only express two, so the third
                            // — "could not tell" — silently took the destroy path.
                            //
                            // Read ONCE and switch on the binding: re-reading inside the branch
                            // would let the reported verdict disagree with the one that chose it.
                            let verdict = item.destinationIdentity.drift(at: item.destination, fileManager: fm)
                            switch verdict {
                            case .unchanged:
                                break
                            case .changed, .indeterminate:
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedChangedItem(of: item.destination, actionName: actionName, verdict: verdict, intent: .removeTheCopyItProduced, on: target)
                                continue
                            }
                            do {
                                try fm.trashItem(at: item.destination, resultingItemURL: nil)
                            } catch {
                                // A transiently busy/locked item stays retryable — never escalate
                                // it to the permanent-delete prompt (same distinction deleteItems
                                // applies): a retry may well trash it recoverably.
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
                            undoneCopies.append((source: item.source, destination: item.destination))

                            switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                            case .restored: restored += 1
                            case .failed: restoreFailures += 1
                            case .nothingToRestore: break
                            }
                        }

                        // Items whose destination an earlier (successful) attempt already put
                        // into its pre-batch state are settled — the prompt must not ask the
                        // user to confirm permanently deleting a file the loop would then skip.
                        let confirmableFailures = trashFailures.filter { !alreadyHandled($0.destination) }
                        if !confirmableFailures.isEmpty {
                            // The prompt lists each on-disk file ONCE: a duplicate-registered
                            // path (both attempts failed trash) must not read as two files.
                            var promptedFolded = Set<String>()
                            let promptPaths = confirmableFailures.compactMap { item -> String? in
                                promptedFolded.insert(foldedKey(item.destination)).inserted
                                    ? item.destination.path : nil
                            }
                            let confirmed = await MainActor.run {
                                confirmPermanentDelete(promptPaths)
                            }
                            guard confirmed else {
                                await redoParamResolver.resolve(undoneCopies)
                                return
                            }
                            for item in confirmableFailures {
                                // Same duplicate guard as the main loop — on a Trash-less
                                // volume BOTH registrations of one path land here, and without
                                // this check item B's removeItem permanently unlinked the
                                // pre-batch original item A had just restored.
                                if alreadyHandled(item.destination) {
                                    duplicateRegistrations += 1
                                    logger.debug("Undo (\(actionName)): \(item.destination.lastPathComponent) already handled — skipping its duplicate permanent-delete")
                                    continue
                                }
                                do {
                                    try fm.removeItem(at: item.destination)
                                } catch {
                                    // The copy survives on disk, so its backup must not be
                                    // restored over it — report and leave everything in place.
                                    await FileSyncManager.reportUndoRemoveFailure(of: item.destination, actionName: actionName, error: error, on: target)
                                    continue
                                }
                                removed += 1
                                markHandled(item.destination)
                                undoneCopies.append((source: item.source, destination: item.destination))
                                switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                                case .restored: restored += 1
                                case .failed: restoreFailures += 1
                                case .nothingToRestore: break
                                }
                            }
                        }

                        await redoParamResolver.resolve(undoneCopies)
                        logger.info("Undo (\(actionName)): removed \(removed) of \(items.count) copied item(s), \(vanished) already gone, \(duplicateRegistrations) duplicate registration(s) skipped, restored \(restored) overwritten original(s), \(restoreFailures) restore failure(s), \(leftInPlace) left in place (changed or busy)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerCopyRedo(paramResolver: AsyncValueResolver<[(source: URL, destination: URL)]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
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
                        // Collected across the loop and reported once, for the reason
                        // `logIndeterminateRegistrations` states: N lines over an unreadable tree
                        // push the context that explains it out of the 1000-entry buffer.
                        var unreadable: [(destination: URL, child: URL?)] = []

                        // **No source-identity guard here, deliberately, and it is not the same gap
                        // the MOVE redo had.** A move-redo that reads a changed source relocates
                        // it: the stranger leaves the source path and lands on the destination, and
                        // that is destruction, so it refuses. A copy-redo reads the source and
                        // leaves it exactly where it is. What it can overwrite is the DESTINATION,
                        // and `safeCopyItem` puts that through the same collision resolver the
                        // original copy went through — the user is asked, the displaced item comes
                        // back as `trashed`, and the next undo restores it. There is also no
                        // recorded identity to compare against: a copy never touches its source, so
                        // nothing in this chain has ever snapshotted one. Re-copying a source the
                        // user has since edited re-applies the copy to the file that is there now,
                        // which is what "redo the copy" means.
                        for param in params {
                            try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                let trashed = try FileSyncManager.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                                // Re-snapshot the item this redo just produced — the next undo
                                // must guard against drift from THIS copy, not the first. DEEP,
                                // like `registerCopyUndo(items:)`: this identity feeds the same
                                // trash guard, and recording it shallow here would quietly hand
                                // the redo→undo leg back the deep-edit blindness the first leg
                                // just closed — pinned by `aDeepEditAfterARedoRefusesTheSecondUndo`
                                // (this line mutated to `snapshot` passed the whole suite before
                                // that test: every copy-redo fixture was a file, for which the
                                // two snapshots are definitionally identical). Taken inline,
                                // right after the item's own copy, so the window is per item.
                                let read = FileSyncManager.recordedCopyIdentity(at: param.destination, fileManager: fm)
                                if read.identity == .indeterminate {
                                    unreadable.append((param.destination, read.unreadableDescendant))
                                }
                                nextState.append((source: param.source, destination: param.destination, overwritten: trashed,
                                                  destinationIdentity: read.identity))
                            } catch {
                                // A failed re-copy must stay out of the next undo state: undoing
                                // a phantom copy would prompt to permanently delete a file that
                                // is not on disk.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.destination, actionName: actionName, error: error, on: target)
                            }
                        }

                        FileSyncManager.logIndeterminateRegistrations(unreadable, of: params.count, actionName: actionName)
                        await nextUndoStateResolver.resolve(nextState)
                        logger.info("Redo (\(actionName)): copied \(nextState.count) of \(params.count) item(s), \(redoFailures) redo failure(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    /// **`items` arrives in whatever order its call site built it, and the whole chain preserves
    /// that order**: the handler reverses them front to back, `registerMoveRedo` re-applies them
    /// back to front, and the state it hands the next undo is reversed again.
    ///
    /// **Exactly ONE of the nine call sites depends on that, and it is the only one that sorts.**
    /// `normalizeNames` applies deepest-first and then deliberately re-sorts the batch
    /// shallowest-first before registering, so a ⌘Z restores a renamed parent folder before the
    /// children renamed inside it and a ⌘⇧Z renames the children before the folder around them.
    /// The reversal in `registerMoveRedo` is written for that call site, and the comment there
    /// saying it "restores the original apply order" is true of that call site only.
    ///
    /// The other eight hand over APPLY order — four pass a single item, where order is not a
    /// question at all, and four (`FileOperations.swift`'s multi-select move,
    /// `FileSyncManager+Filing.swift`'s batch filing, `FileSyncManager+Automations.swift`'s
    /// automation run, and `applyRenamePlans`' renumbering) append in the order they moved things.
    /// For those the replay runs the batch backwards. Filing and automation move FILES into
    /// destination folders and `applyRenamePlans` renames files inside one folder, so in all three
    /// no move's `from` can be an ancestor of another's `to` and any order reverses.
    ///
    /// **The multi-select move is the one that has to be checked rather than assumed, and it does
    /// NOT satisfy that.** `liveLocation`'s own doc, four hundred lines above, constructs the
    /// counter-example: with nested provider roots `/P` and `/P/Backup`, a single multi-select move
    /// batch has `/P/Backup/D` → `/P/Backup/moved-D` beside `/P/D/file.txt` →
    /// `/P/Backup/D/file.txt`, where the first move's `from` IS a strict ancestor of the second's
    /// `to`. This comment used to claim every other batch holds "items whose paths cannot reach
    /// each other", which contradicted that; it says what is true instead. Nothing reaches the bad
    /// replay today: undoing such a batch refuses the ancestor (its source is occupied by the
    /// recreated directory), so the ancestor never enters the redo params and the reversal has
    /// nothing to get wrong. If a second call site ever needs an order, SORT it as `normalizeNames`
    /// does rather than leaning on the reversal.
    ///
    /// **`applyRenamePlans`' cascades are safe, and neither reason this has given for it was the
    /// real one.** The first credited the naming convention — the label travels with the number, so
    /// `01. Mar`→`02. Mar` sits beside `02. Apr`→`03. Apr` and no destination is another's source.
    /// That is true of today's planner and is not a guarantee. The second replaced it with the
    /// never-overwrite fallback at `FileSyncManager+FilingRename.swift:251-258`, which diverts `dst`
    /// through `generateUniqueURL` when the target is occupied by a different item, and concluded
    /// that even a planner renumbering onto a live sibling "could not produce a move whose `to` is
    /// another move's `from`". It can: that fallback stats at APPLY time in step order, so it
    /// diverts only a step whose target is still occupied, and a descending renumber `03→04`,
    /// `02→03`, `01→02` vacates `03` before `02→03` looks at it. The chain is produced.
    ///
    /// What actually holds is one step further on, and it is a property of the UNDO rather than of
    /// the planner: undoing that batch first moves `04`→`03`, and `03` is occupied — by the very
    /// item the `02→03` step put there — so the occupancy check refuses it with
    /// `restoreTargetOccupiedError`, and a refused item is never added to `movedBackPairs`. `03`→`02`
    /// refuses for the same reason one link along. The chain links therefore never reach the redo
    /// params, and the reversal below has nothing to get wrong — the same mechanism that already
    /// covers the multi-select case in the paragraph above, which is why this now names it once
    /// instead of inventing a second one. Note what that means in the other direction: it holds
    /// because the cascade cannot be undone, not because it cannot be built.
    func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveUndoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[MoveRedoParam]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                        let items = await stateResolver.get()

                        // Resolve the redo params AFTER the reversal loop, from ONLY the items that
                        // actually moved back — mirroring how the redo path excludes failed re-applies
                        // from its next-undo state. A refused item (its source is now occupied by a
                        // DIFFERENT file) must never be in redoParams: redoing it would run the move
                        // anyway and drop that unrelated occupant over the real file at the destination.
                        var movedBack = 0
                        var restoreFailures = 0
                        // A drift refusal is not a failure — the undo CHOSE not to move the item,
                        // and nothing it attempted went wrong. Counting it as a restore failure
                        // reported "moved 0 of 1 item(s) back to source, 1 restore failure(s)" for
                        // a run in which nothing failed, which reads as breakage in the log and
                        // hides the genuine `safeMoveItem` throws among it. The copy path already
                        // separates the two with its own `leftInPlace`; this is its twin.
                        var leftInPlace = 0
                        var movedBackPairs: [(from: URL, to: URL)] = []
                        // Items the user removed themselves between the move and the ⌘Z. Counted
                        // apart from `leftInPlace` because they are not a refusal: this undo did
                        // not decline to act, there was nothing left to act on.
                        var vanished = 0
                        // Items whose RECORDED identity is `.absent` — nothing was at the
                        // destination when this undo was registered. A third category again: not a
                        // drift refusal (nothing was ever there to drift), and not `vanished`
                        // (which says the user removed it, and would be a false accusation here).
                        var nothingRecorded = 0
                        for item in items {
                            var movedBackOK = false
                            // **A recorded `.absent` must not authorise a move.** It is not an
                            // identity, it is the absence of one, and the drift guard below cannot
                            // say so: `compare(.absent, .absent)` answers `.unchanged` — correct,
                            // and useless, because "nothing changed" here means "there was nothing,
                            // and there still is nothing". That verdict reached the `else` branch,
                            // whose FIRST statement is `createDirectory(item.from's parent)`, so an
                            // undo that could only ever throw still manufactured a folder — for a
                            // normalize batch, the zero-width-space name the pass had just removed.
                            // Measured on an empty root with a batch recorded against a
                            // never-created destination: `[]` before ⌘Z, `["P␣"]` after.
                            //
                            // **FIRST, ahead of the `vanished` branch, because the two overlap.**
                            // That branch fires when the destination's parent exists and the
                            // destination does not — which is exactly the ordinary normalize shape,
                            // a child renamed inside a folder that is still there. It claimed such
                            // an item first and reported "no longer on disk", a sentence that says
                            // the USER removed it while a recorded `.absent` says it was never
                            // recorded as being there at all — and it only logs, so the banner that
                            // tells them the undo refused was lost with it. (The comment here used
                            // to assert the two could not overlap, on the grounds that `.absent`
                            // implies a missing parent. It does not: the measured fixture had the
                            // root as the parent, and the test that pinned this deliberately
                            // emptied the root, which is what kept the overlap invisible.)
                            //
                            // Checked before the drift stat rather than after: with the recorded
                            // side absent there is nothing a stat could add, and the refusal is the
                            // same whatever is at `item.to` now.
                            if item.movedIdentity == .absent {
                                nothingRecorded += 1
                                await FileSyncManager.reportUndoRefusedUnrecordedItem(
                                    of: item.to, actionName: actionName, on: target)
                                continue
                            }
                            // The moved item is GONE. Not drift — nothing is there to be a
                            // stranger — and both siblings already say so: the copy-undo has its
                            // own "already deleted themselves" branch, and the move-REDO skips its
                            // absent sources for the same reason. Only this loop fell through to
                            // the drift comparison, where `.absent` differs from the recorded
                            // identity and reported the deleted item as CHANGED.
                            //
                            // The sentence was false, and it cost something real: the ORIGINAL
                            // this move displaced stayed stranded in the Trash. Restoring it is
                            // the one part of the reversal still available, and it is safe
                            // precisely here — the destination is empty, so nothing is clobbered.
                            // Deliberately NOT added to `movedBackPairs`: nothing moved back, and
                            // a redo has nothing to re-apply.
                            //
                            // **The parent has to exist for this to mean what it says**, and that
                            // condition is the whole difference between the two ways a path can
                            // come back missing. A NESTED batch whose shallow item was refused
                            // leaves the deeper item's recorded `to` spelling an ancestor that was
                            // never restored: the file is still on disk under the ancestor's other
                            // name, so "no longer on disk" would be false, and moving the backup
                            // there would manufacture the very folder the refusal declined to
                            // recreate. Without this clause the nested-refusal test reported
                            // `a.txt is no longer on disk` about a file sitting in `Photos/`.
                            // A missing parent falls through to the drift guard, which refuses —
                            // which is what it did before this branch existed.
                            let parentExists = fm.fileExists(atPath: item.to.deletingLastPathComponent().path)
                            if parentExists, !fm.fileExists(atPath: item.to.path) {
                                vanished += 1
                                logger.info("Undo (\(actionName)): \(item.to.lastPathComponent) is no longer on disk — nothing to move back")
                                if let trashed = item.overwritten {
                                    do {
                                        try fm.moveItem(at: trashed, to: item.to)
                                    } catch {
                                        restoreFailures += 1
                                        await FileSyncManager.reportUndoRestoreFailure(of: item.to, from: trashed, actionName: actionName, error: error, on: target)
                                    }
                                }
                                continue
                            }
                            // A case-only rename ("foo"→"Foo") is NOT a clobber: on a case-insensitive
                            // volume item.from resolves to the very item.to being moved back, so
                            // `fileExists(item.from)` is true even though nothing else took the spot.
                            // Exclude that case (mirrors renameItem's isCaseOnly guard) and let
                            // safeMoveItem perform the case-only rename; otherwise, if a DIFFERENT item
                            // now occupies the original location, refuse rather than silently
                            // replace-and-Trash it (a displacement Redo couldn't track).
                            // Only treat item.from as "the moved item itself" on a case-INsensitive
                            // volume, where the two case-variant paths are one file. On a
                            // case-sensitive volume they're distinct, so a genuine occupant at
                            // item.from must still trip the guard (matches renameItem's isCaseOnly,
                            // which is likewise volume-gated).
                            let sameItemAsMoved = !FileSyncManager.volumeSupportsCaseSensitiveNames(for: item.from)
                                && item.from.path.caseInsensitiveCompare(item.to.path) == .orderedSame
                            // "Still the same item?" — the guard the doc comment claimed and the
                            // code did not have. The occupancy check below asks whether the SOURCE
                            // is free; this asks whether the thing at the DESTINATION is still the
                            // item this undo moved there. Without it, a newer version dropped at
                            // the destination is moved away to the source path and the older one
                            // restored over it, reported as a clean success.
                            //
                            // Checked before the occupancy branch so a drifted destination refuses
                            // for the accurate reason rather than falling through to whichever
                            // branch the source's state happens to select.
                            let moveVerdict = item.movedIdentity.drift(at: item.to, fileManager: fm)
                            if moveVerdict != .unchanged {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedChangedItem(of: item.to, actionName: actionName, verdict: moveVerdict, intent: .moveItBackToItsSource, on: target)
                            } else if !sameItemAsMoved && fm.fileExists(atPath: item.from.path) {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.from, from: item.to, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                            } else {
                                do {
                                    // Recreating the source's parent belongs HERE, in the branch
                                    // that is actually about to move something, not at the top of
                                    // the loop. A refused item must leave the disk exactly as it
                                    // found it, and running this first did not: for a NESTED batch
                                    // whose shallow item was refused, the deeper item's `from`
                                    // spells the old ancestor name, so the refusal that followed
                                    // still left behind a brand-new empty folder carrying the very
                                    // name the pass had just removed.
                                    try? fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                                    _ = try FileSyncManager.safeMoveItem(at: item.to, to: item.from, fileManager: fm)
                                    movedBack += 1
                                    movedBackOK = true
                                    // Only a move-back that actually happened is redoable.
                                    movedBackPairs.append((from: item.from, to: item.to))
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
                                do {
                                    try fm.moveItem(at: trashed, to: item.to)
                                } catch {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRestoreFailure(of: item.to, from: trashed, actionName: actionName, error: error, on: target)
                                }
                            }
                        }
                        // The identity each restored item has NOW, read in one pass once the whole
                        // reversal has settled — this is what lets the redo refuse to move a
                        // stranger, and the pass has to come after the loop rather than inside it.
                        // A batch can nest (`normalizeNames` restores a parent and then the
                        // children inside it), and moving a child rewrites its PARENT's
                        // modification date; a directory identity taken the moment that directory
                        // landed would already disagree with itself two items later. The state the
                        // loop leaves behind is the state the redo will find, so that is the one to
                        // record.
                        //
                        // SHALLOW, deliberately, for the same reason as `registerMoveUndo(items:)`:
                        // a redo MOVES rather than destroys, so a deep edit it misses travels with
                        // the folder, while a deep identity here would falsely refuse the redo of
                        // any folder edited inside since the undo — and the redo's own deepest-first
                        // replay moves children out of the very directories it is about to compare,
                        // which a recursive digest would read as drift this loop itself caused.
                        let reversedParams: [MoveRedoParam] = movedBackPairs.map { pair in
                            (from: pair.from, to: pair.to,
                             sourceIdentity: ItemIdentity.snapshot(at: pair.from, fileManager: fm))
                        }
                        await redoParamResolver.resolve(reversedParams)
                        logger.info("Undo (\(actionName)): moved \(movedBack) of \(items.count) item(s) back to source, \(restoreFailures) restore failure(s), \(leftInPlace) left in place (changed or unverifiable)"
                                    + (vanished > 0 ? ", \(vanished) no longer on disk" : "")
                                    // Appended rather than folded into `leftInPlace`, whose
                                    // parenthetical would stop being true of every item it counts.
                                    + (nothingRecorded > 0 ? ", \(nothingRecorded) with nothing recorded to move back" : ""))
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

                        // "Still the same item?" for the REDO, which had no such guard at all: it
                        // gated on `fileExists(param.from)` and then moved whatever was there.
                        // Measured — move `/src/report.txt` → `/dst/report.txt`, ⌘Z, create a
                        // DIFFERENT `/src/report.txt` and an unrelated `/dst/report.txt`, ⌘⇧Z — the
                        // redo relocated the file the user had just made, replaced the unrelated
                        // one at the destination, and said nothing: no log line, no banner. The
                        // undo path refuses exactly this via `reportUndoRefusedChangedItem`.
                        //
                        // **WHERE the check happens is decided per item, by the SOURCE's own type,
                        // and both answers are load-bearing.**
                        //
                        // Checking every source up front and then moving every source leaves the
                        // whole pass-to-move interval unguarded: for item *k* of *N* that is
                        // (N−k stats) plus (k−1 real filesystem moves), which on the 3,000-item
                        // batches `renameMap(for:)` is written for is seconds. Anything that lands
                        // at a source inside that window is moved unchecked — the same
                        // "`fileExists` answering an identity question" defect this pass was added
                        // to fix, one step later in the same function. Measured on a two-item batch
                        // with a stranger written at the first item's source while the second was
                        // moving: it was relocated, and nothing was logged or bannered.
                        //
                        // But checking a DIRECTORY source in its turn is wrong, and not marginally:
                        // the replay runs deepest-first, so moving a child rewrites its PARENT's
                        // modification date, and the parent would then be measured against a date
                        // this very loop had just changed. Verified — it refuses
                        // `redoOfANestedNormalizePassReAppliesBothRenames` with `Redo left
                        // "Photos␣" in place — it changed since`, which is a correct redo declined.
                        //
                        // That perturbation is only possible for a directory: a sibling move cannot
                        // touch a `.file` or a `.symlink`'s identity, so nothing this loop does can
                        // make a non-directory source disagree with itself. So a directory keeps the
                        // up-front comparison, everything else is compared immediately before its
                        // own move, and each keeps the property the other cannot.
                        //
                        // The residual is stated rather than hidden: a directory source SWAPPED for
                        // another between the pass and its move is still moved. Closing that means
                        // telling this replay's own perturbation apart from a foreign one, which an
                        // identity alone cannot do — and it is the state every source was in before
                        // this split, not a new exposure.
                        var replayable: [(param: MoveRedoParam, recheckAtItsMove: Bool)] = []
                        for param in params.reversed() {
                            // Only a recorded DIRECTORY has the up-front pass to gain, and only a
                            // present one: an absent directory has nothing to compare yet.
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

                        // `replayable` is already REVERSED, because re-applying is not the same
                        // order as reversing.
                        //
                        // The undo appends its params in the order it processed `items`, and
                        // `normalizeNames` hands that in deliberately: apply deepest-first, undo
                        // shallowest-first, so the parent is restored around the children before
                        // they move back inside it. Re-applying in the undo's own order runs the
                        // parent rename FIRST, and every deeper item's recorded `from` then spells
                        // an ancestor that has just stopped existing. Measured on a normalize pass
                        // over `<root>/Photos␣/a␣.txt`: ⌘⇧Z produced `Photos`, `Photos/a␣.txt` and
                        // a brand-new EMPTY `Photos␣` — the risky name the pass exists to remove —
                        // and the stray directory then occupied the child's source, so the next
                        // ⌘Z hit `restoreTargetOccupiedError` and reversed nothing at all. No data
                        // was lost, but the tree was one nobody asked for and the undo stack was
                        // dead. Reversing restores the order in which `normalizeNames` applied the
                        // moves, which is the order that made them possible in the first place.
                        //
                        // It also makes the inline snapshot below read a LIVE path for free: each
                        // item is snapshotted the instant it lands, before the shallower moves
                        // rename its ancestors, so `param.to` is where the item actually is. This
                        // is why the redo does NOT need `liveLocation` — and must not use it, as
                        // that would resolve to a path only the LATER moves make real.
                        for (param, recheckAtItsMove) in replayable {
                            if recheckAtItsMove {
                                let liveSource = ItemIdentity.snapshot(at: param.from, fileManager: fm)
                                // Still nothing there: that IS the gone case, and the re-apply
                                // below reports it precisely as "its source may no longer exist".
                                // Re-established here rather than remembered from the pass, which
                                // is the second half of this fix — an `.absent` verdict taken up
                                // front meant the recorded identity was never consulted at ANY
                                // point, and the `fileExists` re-test below then moved whatever had
                                // appeared. Measured: the user deleted a source after the undo and
                                // wrote an unrelated file at the same path while a sibling was
                                // moving; the redo relocated the new file and reported nothing.
                                //
                                // A recorded `.absent` cannot authorise anything through here
                                // either: absent-vs-absent skips the compare and falls to the
                                // failure report, and absent-vs-present compares `.changed`.
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
                            // Only manufacture the destination's parent for a move that can
                            // actually happen. Unconditionally, this created the ancestor a
                            // sibling move had just renamed away — the empty `Photos␣` above —
                            // and then reported the failure anyway. If the source is not there,
                            // nothing is going to land, so nothing should be built for it.
                            if fm.fileExists(atPath: param.from.path) {
                                try? fm.createDirectory(at: param.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                            }
                            do {
                                let trashed = try FileSyncManager.safeMoveItem(at: param.from, to: param.to, fileManager: fm)
                                // Snapshot HERE, where the state is produced — the resolver is
                                // consumed at undo time, and a snapshot taken there would be
                                // compared against itself. Shallow, like every move-chain
                                // identity: it feeds the next MOVE-undo's guard, which moves
                                // rather than destroys (see `registerMoveUndo(items:)`).
                                nextState.append((from: param.from, to: param.to, overwritten: trashed,
                                                  movedIdentity: ItemIdentity.snapshot(at: param.to, fileManager: fm)))
                            } catch {
                                // A failed re-move must stay out of the next undo state: undoing
                                // a phantom move would "restore" from a destination that was
                                // never populated.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.to, actionName: actionName, error: error, on: target)
                            }
                        }

                        // Handed back in UNDO order — the reverse of the order just re-applied —
                        // which is the invariant every array in this chain keeps: a move state is
                        // always stored in the order its undo must process it. Resolved in the
                        // replay's own order, the next ⌘Z would restore a parent before the
                        // children inside it had left, which is the same defect one step further
                        // along.
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
            Logger.shared.info("User triggered Undo: New Folder")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            target.registerCreateFolderRedo(url: url, fileManager: fm)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) {
                // This undo can follow a FAILED folder redo (its registration cannot be taken
                // back once the redo's createDirectory throws), so it only removes what it owns:
                // an existing directory at `url`. A missing folder — or a non-folder item that
                // has since taken the path — must not be trashed or prompt for deletion.
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    logger.info("Undo (New Folder): no folder to remove at \(url.path)")
                    return
                }
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    // A transiently busy/locked folder stays retryable — same distinction as
                    // deleteItems and the copy-undo: escalating a momentary EBUSY/EACCES to the
                    // permanent-delete prompt could permanently destroy a folder (and whatever
                    // the user has put in it since) that a retry would have trashed recoverably.
                    if FileSyncManager.isTransientTrashFailure(error) {
                        await FileSyncManager.reportUndoTransientTrashFailure(of: url, actionName: "New Folder", error: error, on: target)
                        return
                    }
                    // The folder was created empty, but the user may have filled it since —
                    // permanent removal gets the same confirmation as everywhere else.
                    let confirmed = await MainActor.run { confirmPermanentDelete([url.path]) }
                    if confirmed {
                        // Report the outcome either way. `try?` swallowed both: a failure left the
                        // folder on disk after the user had confirmed its deletion, with nothing
                        // in the log and no banner — the undo simply appeared to have worked. The
                        // copy-undo's twin of this branch has always reported through
                        // reportUndoRemoveFailure; this one just never did.
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
    
    /// Registers the REDO of a delete: the handler re-trashes what its paired undo actually
    /// restored — `itemsResolver` is resolved by that undo AFTER its restore loop, from only the
    /// successful restores, so a REFUSED restore (a different item occupied the original path)
    /// can never put the unrelated occupant on the redo's trash list. Its only caller is the
    /// delete-undo handler in `registerRestoreItems`, so the audit label is always "Redo".
    ///
    /// **And each item is re-identified at the moment it is trashed, not merely stat-ed for
    /// existence.** Being on this list means "the undo put our item back here", which stops being
    /// true the moment anything replaces it. The move-redo path has refused exactly this shape
    /// since `ItemIdentity` landed (`reportRedoRefusedChangedItem`, whose doc says a redo is as
    /// destructive as an undo and gets the same refusal); this one gated on the PATH existing and
    /// would trash a stranger. Measured: delete `/a/report.txt`, ⌘Z, replace `/a/report.txt` with a
    /// different file, ⌘⇧Z — the replacement went to the Trash, with no log line and no banner.
    ///
    /// A path that is simply GONE stays a silent skip: nothing is there to trash, the redo has
    /// nothing to do about it, and the count line already says how many of how many were trashed.
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
                        for item in items {
                            let url = item.url
                            guard fmLocal.fileExists(atPath: url.path) else { continue }
                            // Re-read HERE, immediately before the trash, rather than trusting the
                            // existence check: the gap between "something is at this path" and
                            // "our item is at this path" is the whole defect.
                            let verdict = item.restoredIdentity.drift(at: url, fileManager: fmLocal)
                            guard verdict == .unchanged else {
                                refused += 1
                                await FileSyncManager.reportRedoRefusedTrashOfChangedItem(
                                    at: url, actionName: actionName, verdict: verdict, on: target)
                                continue
                            }
                            var t: NSURL?
                            if (try? fmLocal.trashItem(at: url, resultingItemURL: &t)) != nil, let trashed = t as? URL {
                                trashedItems.append((original: url, trashedBackup: trashed))
                            }
                        }
                        await nextResolver.resolve(trashedItems)
                        logger.info("Redo (\(actionName)): trashed \(trashedItems.count) of \(items.count) item(s)"
                                    + (refused > 0 ? ", refused \(refused) that changed since the undo" : ""))
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Registers the UNDO of a delete: the handler restores each item from its Trash location.
    /// The redo it registers re-trashes ONLY what this undo actually restored — the redo URL list
    /// is resolved AFTER the restore loop (mirroring `registerMoveUndo`, "a refused item must
    /// never be in redoParams"): a restore refused because a DIFFERENT item took the original
    /// path leaves that occupant in place, and a redo that blindly re-trashed the full original
    /// URL list would trash it.
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
                        if fm.fileExists(atPath: item.original.path) {
                            // A different item now occupies the deleted item's location. Restoring
                            // from Trash here would silently replace-and-Trash it (untracked by
                            // Redo). Refuse and report; the item stays in the Trash, recoverable —
                            // and stays OUT of redoURLs, so a redo can't trash the occupant either.
                            restoreFailures += 1
                            await FileSyncManager.reportUndoRestoreFailure(of: item.original, from: item.trashedBackup, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                        } else {
                            do {
                                _ = try FileSyncManager.safeMoveItem(at: item.trashedBackup, to: item.original, fileManager: fm)
                                restored += 1
                                // Only a restore that actually happened is redoable — and it is
                                // identified as it lands, so the redo can tell our item from
                                // whatever may be at that path by the time it runs. Read AFTER the
                                // move, so it describes the restored item rather than the backup.
                                //
                                // Shallow: `snapshot` not `deepSnapshot`, so for a directory this
                                // is `.directory(modified:childCount:)` — it notices a direct
                                // child appearing or going, and does NOT notice an edit further
                                // down. That asymmetry is the intended one. The deep walk exists
                                // for the copy-undo, where a refusal is what protects the ONLY
                                // instance of an edit; here the item goes to the Trash, which the
                                // user can retrieve it from, so paying a recursive walk per
                                // restored folder to catch a deep edit would buy very little.
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

/// A generic async resolver used to chain dynamically generated state values (like Trash URLs) 
/// from background file executions into sequential, synchronously registered Undo/Redo blocks.
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
