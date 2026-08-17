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
    typealias CopyUndoItemState = (source: URL, destination: URL, overwritten: URL?, destinationIdentity: ItemIdentity)
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
    /// Enriched inside `registerMoveUndo` rather than added to `MoveItemState`, so the eight call
    /// sites that build a move state keep passing what they already build.
    typealias MoveUndoItemState = (from: URL, to: URL, overwritten: URL?, movedIdentity: ItemIdentity)
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
    /// can hand over thousands of items. `theUndoRegistrationOfALargeBatchStaysLinear` is what
    /// keeps it from creeping back.
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
    /// batch and every same-directory batch, i.e. all but one of the ten call sites.
    ///
    /// **A rewrite also has to be confirmed against the disk, because the ancestor condition alone
    /// is not proof.** The claim it used to rest on — "`destination` can still spell an ancestor's
    /// OLD name only if the item landed there before that ancestor was renamed" — is false for a
    /// batch that mixes NESTED provider roots, which `SettingsManager.existingSource` allows: with
    /// roots `/P` and `/P/Backup`, a multi-select move can move `/P/Backup/D` first and then let
    /// `ensureParentDirectoryExists` recreate `/P/Backup/D` under the item that lands second, so
    /// that item IS at its recorded `to` and rewriting the path walks it off into
    /// `/P/Backup/Backup/D/…`. The consequence was only ever a bad READ — `item.to` still drives
    /// the actual move, so the blast radius is an `.absent` snapshot and a falsely refused undo,
    /// never a wrong destination — but a false refusal is exactly what this function exists to
    /// stop. So: if the item is still AT `destination`, it did not go anywhere, and the recorded
    /// path is the answer. The stat costs one call, and only on the nested path where a rewrite
    /// was about to happen; every flat batch returns before reaching it.
    ///
    /// Resolution is recursive so a three-deep nest resolves fully (`/A-BAD/B-BAD/c.txt` →
    /// `/AOK/BOK/c.txt`), and guarded by a `seen` set so a rename CYCLE stops rather than looping.
    /// The leaf itself is never rewritten: an item is renamed once per batch, so its own name is
    /// final, and rewriting it would follow an unrelated item that happens to have taken the path —
    /// a renumbering cascade (`01 - x.pdf`→`02 - x.pdf` beside `02 - x.pdf`→`03 - x.pdf`) has one
    /// move's `to` equal to another's `from`, and would snapshot the wrong file.
    nonisolated static func liveLocation(
        of destination: URL, throughRenames renames: [String: String], fileManager fm: FileManaging
    ) -> URL {
        guard !renames.isEmpty else { return destination }
        let parent = destination.deletingLastPathComponent()
        var seen = Set<String>()
        let livingParent = resolveRenamedDirectory(parent.path, renames: renames, seen: &seen)
        guard livingParent != parent.path else { return destination }
        guard !fm.fileExists(atPath: destination.path) else { return destination }
        return URL(fileURLWithPath: livingParent).appendingPathComponent(destination.lastPathComponent)
    }

    /// One-shot convenience over `renameMap(for:)` + `liveLocation(of:throughRenames:fileManager:)`.
    /// Never call this in a loop over the batch — that is the quadratic shape `renameMap(for:)`
    /// exists to keep out of `registerMoveUndo(items:)`.
    nonisolated static func liveLocation(
        of destination: URL, afterBatch batch: [MoveItemState], fileManager fm: FileManaging
    ) -> URL {
        liveLocation(of: destination, throughRenames: renameMap(for: batch), fileManager: fm)
    }

    /// `liveLocation`'s worker: the path `path` reads as after `renames` are applied to it and to
    /// every one of its ancestors. `seen` bounds a cycle (A→B, B→A) to one lap.
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
    private nonisolated static func resolveRenamedDirectory(
        _ path: String, renames: [String: String], seen: inout Set<String>
    ) -> String {
        if let renamed = renames[path] {
            guard seen.insert(path).inserted else { return path }
            return resolveRenamedDirectory(renamed, renames: renames, seen: &seen)
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        guard parent.path != path else { return path }   // reached the volume root
        let livingParent = resolveRenamedDirectory(parent.path, renames: renames, seen: &seen)
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

    /// Convenience for call sites whose undo state is fully known at registration time: wraps
    /// the items in a pre-resolved `AsyncValueResolver` so the resolver-based form below stays
    /// the single implementation. The resolver forms remain for the undo/redo chain, where the
    /// next state genuinely resolves later (inside the queued file operation).
    /// Snapshots each copied item's byte size HERE, at registration time (a cheap synchronous
    /// metadata stat, same trade as deleteItems' history records), so the undo handler can
    /// refuse to trash a destination that is no longer the item this copy produced.
    func registerCopyUndo(items: [CopyItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let enriched: [CopyUndoItemState] = items.map { item in
            (source: item.source, destination: item.destination, overwritten: item.overwritten,
             destinationIdentity: ItemIdentity.snapshot(at: item.destination, fileManager: fm))
        }
        let resolver = AsyncValueResolver<[CopyUndoItemState]>()
        Task { await resolver.resolve(enriched) }
        registerCopyUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    func registerMoveUndo(items: [MoveItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        // Snapshots each moved item's identity HERE, at registration time — the move has already
        // happened, so the item this undo is responsible for is on disk — so the handler can
        // refuse to move back something that is no longer it.
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

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
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
                            // the redo params.
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
                            let promptNames = confirmableFailures.compactMap { item -> String? in
                                promptedFolded.insert(foldedKey(item.destination)).inserted
                                    ? item.destination.lastPathComponent : nil
                            }
                            let confirmed = await MainActor.run {
                                confirmPermanentDelete(promptNames)
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

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [CopyUndoItemState] = []
                        var redoFailures = 0

                        for param in params {
                            try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                let trashed = try FileSyncManager.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                                // Re-snapshot the size of the item this redo just produced — the
                                // next undo must guard against drift from THIS copy, not the first.
                                nextState.append((source: param.source, destination: param.destination, overwritten: trashed,
                                                  destinationIdentity: ItemIdentity.snapshot(at: param.destination, fileManager: fm)))
                            } catch {
                                // A failed re-copy must stay out of the next undo state: undoing
                                // a phantom copy would prompt to permanently delete a file that
                                // is not on disk.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.destination, actionName: actionName, error: error, on: target)
                            }
                        }

                        await nextUndoStateResolver.resolve(nextState)
                        logger.info("Redo (\(actionName)): copied \(nextState.count) of \(params.count) item(s), \(redoFailures) redo failure(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    /// **`items` is in UNDO order**, and the whole undo/redo chain keeps it that way: the handler
    /// reverses them front to back, `registerMoveRedo` re-applies them back to front, and the
    /// state it hands the next undo is reversed again. `normalizeNames` is where that matters —
    /// it applies deepest-first and passes the batch shallowest-first, so a ⌘Z restores a renamed
    /// parent folder before the children renamed inside it, and a ⌘⇧Z renames the children before
    /// the folder around them. Every other call site passes one item, or items in no relation to
    /// each other, and is indifferent.
    func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveUndoItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[(from: URL, to: URL)]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
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
                        var reversedParams: [(from: URL, to: URL)] = []
                        for item in items {
                            var movedBackOK = false
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
                                    reversedParams.append((from: item.from, to: item.to))
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
                        await redoParamResolver.resolve(reversedParams)
                        logger.info("Undo (\(actionName)): moved \(movedBack) of \(items.count) item(s) back to source, \(restoreFailures) restore failure(s), \(leftInPlace) left in place (changed or unverifiable)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    func registerMoveRedo(paramResolver: AsyncValueResolver<[(from: URL, to: URL)]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextUndoStateResolver = AsyncValueResolver<[MoveUndoItemState]>()
            target.registerMoveUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [MoveUndoItemState] = []
                        var redoFailures = 0

                        // REVERSED, because re-applying is not the same order as reversing.
                        //
                        // The undo appends `reversedParams` in the order it processed `items`, and
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
                        // dead. Reversing restores the original apply order, which is the order
                        // that made the moves possible in the first place.
                        //
                        // It also makes the inline snapshot below read a LIVE path for free: each
                        // item is snapshotted the instant it lands, before the shallower moves
                        // rename its ancestors, so `param.to` is where the item actually is. This
                        // is why the redo does NOT need `liveLocation` — and must not use it, as
                        // that would resolve to a path only the LATER moves make real.
                        for param in params.reversed() {
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
                                // compared against itself.
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
                        logger.info("Redo (\(actionName)): moved \(nextState.count) of \(params.count) item(s), \(redoFailures) redo failure(s)")
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
            target.preCountFileOperation()
            Task { await target.enqueueFileOperation(alreadyCounted: true) {
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
                    let confirmed = await MainActor.run { confirmPermanentDelete([url.lastPathComponent]) }
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
            target.preCountFileOperation()
            Task { await target.enqueueFileOperation(alreadyCounted: true) {
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
    
    /// Registers the REDO of a delete: the handler re-trashes the URLs its paired undo actually
    /// restored — `urlsResolver` is resolved by that undo AFTER its restore loop, from only the
    /// successful restores, so a REFUSED restore (a different item occupied the original path)
    /// can never put the unrelated occupant on the redo's trash list. Its only caller is the
    /// delete-undo handler in `registerRestoreItems`, so the audit label is always "Redo".
    func registerTrashItems(urlsResolver: AsyncValueResolver<[URL]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextResolver = AsyncValueResolver<[RestoreItemState]>()
            target.registerRestoreItems(stateResolver: nextResolver, actionName: actionName, fileManager: fm)

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let fmLocal = fm
                        let urls = await urlsResolver.get()
                        var trashedItems: [RestoreItemState] = []
                        for url in urls {
                            var t: NSURL?
                            if fmLocal.fileExists(atPath: url.path), (try? fmLocal.trashItem(at: url, resultingItemURL: &t)) != nil, let trashed = t as? URL {
                                trashedItems.append((original: url, trashedBackup: trashed))
                            }
                        }
                        await nextResolver.resolve(trashedItems)
                        logger.info("Redo (\(actionName)): trashed \(trashedItems.count) of \(urls.count) item(s)")
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
            let redoURLResolver = AsyncValueResolver<[URL]>()
            target.registerTrashItems(urlsResolver: redoURLResolver, actionName: actionName, fileManager: fm)

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                    let items = await stateResolver.get()
                    var restored = 0
                    var restoreFailures = 0
                    var restoredURLs: [URL] = []
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
                                // Only a restore that actually happened is redoable.
                                restoredURLs.append(item.original)
                            } catch {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.original, from: item.trashedBackup, actionName: actionName, error: error, on: target)
                            }
                        }
                    }
                    await redoURLResolver.resolve(restoredURLs)
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
