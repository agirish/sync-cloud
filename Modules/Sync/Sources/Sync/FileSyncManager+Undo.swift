import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    /// `CopyItemState` enriched with the copied item's byte size as stat'ed when the undo was
    /// registered (nil for directories, or when the size couldn't be read). The undo handler
    /// refuses to trash a destination whose current size no longer matches — the item is no
    /// longer the copy the undo was registered for (replaced or edited since), mirroring the
    /// "still the same item?" drift guards the move- and delete-undos already carry.
    typealias CopyUndoItemState = (source: URL, destination: URL, overwritten: URL?, destinationSize: Int?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)
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

    /// Surfaces a copy-undo that was REFUSED because the item at the copy destination is no
    /// longer the copy the undo was registered for — its byte size drifted, so it was replaced
    /// or edited since. Trashing it would destroy work the undo was never asked to reverse; the
    /// item is left in place, its `overwritten` backup stays in the Trash, and the caller keeps
    /// the item out of the redo params (a refused item must never be redone).
    nonisolated static func reportUndoRefusedChangedItem(
        of destination: URL,
        actionName: String,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): REFUSED to remove \"\(name)\" at \(destination.path) — the item's size changed since the copy, so it is no longer the copied item; leaving it in place"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo left \"\(name)\" in place — it changed since the copy")
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
    /// unstatable items. Directories deliberately return nil so the copy-undo drift guard
    /// applies size comparison to files only — a folder's stat size isn't its content size
    /// (the same reasoning as the duplicate keeper gate's folder carve-out).
    nonisolated static func fileSizeSnapshot(at url: URL, fileManager fm: FileManaging) -> Int? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        if (attrs[.type] as? FileAttributeType) == .typeDirectory { return nil }
        return (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
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
             destinationSize: FileSyncManager.fileSizeSnapshot(at: item.destination, fileManager: fm))
        }
        let resolver = AsyncValueResolver<[CopyUndoItemState]>()
        Task { await resolver.resolve(enriched) }
        registerCopyUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    func registerMoveUndo(items: [MoveItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let resolver = AsyncValueResolver<[MoveItemState]>()
        Task { await resolver.resolve(items) }
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
                            // "Still the same item?" drift guard (mirrors the move-undo's occupied
                            // check and the delete-undo's occupant refusal): if the destination's
                            // byte size no longer matches the registration-time snapshot, the item
                            // was replaced or edited since the copy — refuse to trash it, and keep
                            // it out of the redo params.
                            if let expected = item.destinationSize,
                               FileSyncManager.fileSizeSnapshot(at: item.destination, fileManager: fm) != expected {
                                leftInPlace += 1
                                await FileSyncManager.reportUndoRefusedChangedItem(of: item.destination, actionName: actionName, on: target)
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
                                                  destinationSize: FileSyncManager.fileSizeSnapshot(at: param.destination, fileManager: fm)))
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
    
    func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
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
                        var reversedParams: [(from: URL, to: URL)] = []
                        for item in items {
                            try? fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
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
                            if !sameItemAsMoved && fm.fileExists(atPath: item.from.path) {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.from, from: item.to, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                            } else {
                                do {
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
                        logger.info("Undo (\(actionName)): moved \(movedBack) of \(items.count) item(s) back to source, \(restoreFailures) restore failure(s)")
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
            let nextUndoStateResolver = AsyncValueResolver<[MoveItemState]>()
            target.registerMoveUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [MoveItemState] = []
                        var redoFailures = 0

                        for param in params {
                            try? fm.createDirectory(at: param.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                let trashed = try FileSyncManager.safeMoveItem(at: param.from, to: param.to, fileManager: fm)
                                nextState.append((from: param.from, to: param.to, overwritten: trashed))
                            } catch {
                                // A failed re-move must stay out of the next undo state: undoing
                                // a phantom move would "restore" from a destination that was
                                // never populated.
                                redoFailures += 1
                                await FileSyncManager.reportRedoFailure(of: param.to, actionName: actionName, error: error, on: target)
                            }
                        }

                        await nextUndoStateResolver.resolve(nextState)
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
