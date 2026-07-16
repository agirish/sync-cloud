import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)

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
    /// item survives on disk, so no state is changed: its `overwritten` backup must stay where it
    /// is (restoring it would collide with the survivor), and the already-resolved redo params
    /// remain valid — a later redo simply replaces the surviving item.
    nonisolated static func reportUndoRemoveFailure(
        of destination: URL,
        actionName: String,
        error: Error,
        on target: FileSyncManager
    ) async {
        let name = destination.lastPathComponent
        let logMessage = "Undo (\(actionName)): FAILED to permanently delete \"\(name)\" at \(destination.path) — the copied item remains on disk (\(error.localizedDescription))"
        await MainActor.run {
            Logger.shared.error(logMessage)
            target.banner = .warning("Undo couldn't remove \"\(name)\" — it is still on disk")
        }
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
    func registerCopyUndo(items: [CopyItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let resolver = AsyncValueResolver<[CopyItemState]>()
        Task { await resolver.resolve(items) }
        registerCopyUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    func registerMoveUndo(items: [MoveItemState], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let resolver = AsyncValueResolver<[MoveItemState]>()
        Task { await resolver.resolve(items) }
        registerMoveUndo(stateResolver: resolver, actionName: actionName, fileManager: fm)
    }

    /// Pre-resolved convenience; see `registerCopyUndo(items:actionName:fileManager:)`.
    /// `trashedItems[i]` is the Trash location of `urls[i]` (nil when it wasn't trashed).
    func registerRestoreItems(urls: [URL], trashedItems: [URL?], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        let resolver = AsyncValueResolver<[URL?]>()
        Task { await resolver.resolve(trashedItems) }
        registerRestoreItems(urls: urls, trashResolver: resolver, actionName: actionName, fileManager: fm)
    }

    func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
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
                        var trashFailures: [CopyItemState] = []
                        var removed = 0
                        var restored = 0
                        var restoreFailures = 0
                        var undoneCopies: [(source: URL, destination: URL)] = []
                        for item in items {
                            do {
                                try fm.trashItem(at: item.destination, resultingItemURL: nil)
                            } catch {
                                trashFailures.append(item)
                                continue
                            }
                            removed += 1
                            undoneCopies.append((source: item.source, destination: item.destination))

                            switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                            case .restored: restored += 1
                            case .failed: restoreFailures += 1
                            case .nothingToRestore: break
                            }
                        }

                        if !trashFailures.isEmpty {
                            let confirmed = await MainActor.run {
                                confirmPermanentDelete(trashFailures.map { $0.destination.lastPathComponent })
                            }
                            guard confirmed else {
                                await redoParamResolver.resolve(undoneCopies)
                                return
                            }
                            for item in trashFailures {
                                do {
                                    try fm.removeItem(at: item.destination)
                                } catch {
                                    // The copy survives on disk, so its backup must not be
                                    // restored over it — report and leave everything in place.
                                    await FileSyncManager.reportUndoRemoveFailure(of: item.destination, actionName: actionName, error: error, on: target)
                                    continue
                                }
                                removed += 1
                                undoneCopies.append((source: item.source, destination: item.destination))
                                switch await FileSyncManager.restoreOverwrittenBackup(item.overwritten, to: item.destination, actionName: actionName, fileManager: fm, on: target) {
                                case .restored: restored += 1
                                case .failed: restoreFailures += 1
                                case .nothingToRestore: break
                                }
                            }
                        }

                        await redoParamResolver.resolve(undoneCopies)
                        logger.info("Undo (\(actionName)): removed \(removed) of \(items.count) copied item(s), restored \(restored) overwritten original(s), \(restoreFailures) restore failure(s)")
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
            let nextUndoStateResolver = AsyncValueResolver<[CopyItemState]>()
            target.registerCopyUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)

            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [CopyItemState] = []
                        var redoFailures = 0

                        for param in params {
                            try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                let trashed = try FileSyncManager.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                                nextState.append((source: param.source, destination: param.destination, overwritten: trashed))
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
                    // The folder was created empty, but the user may have filled it since —
                    // permanent removal gets the same confirmation as everywhere else.
                    let confirmed = await MainActor.run { confirmPermanentDelete([url.lastPathComponent]) }
                    if confirmed {
                        try? fm.removeItem(at: url)
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
    
    /// Registers the REDO of a delete: the handler re-trashes `urls`. Its only caller is the
    /// delete-undo handler in `registerRestoreItems`, so the audit label is always "Redo".
    func registerTrashItems(urls: [URL], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let nextResolver = AsyncValueResolver<[URL?]>()
            target.registerRestoreItems(urls: urls, trashResolver: nextResolver, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let fmLocal = fm
                        var trashedItems: [URL?] = []
                        for url in urls {
                            var t: NSURL?
                            if fmLocal.fileExists(atPath: url.path), (try? fmLocal.trashItem(at: url, resultingItemURL: &t)) != nil, let trashed = t as? URL {
                                trashedItems.append(trashed)
                            } else {
                                trashedItems.append(nil)
                            }
                        }
                        await nextResolver.resolve(trashedItems)
                        logger.info("Redo (\(actionName)): trashed \(trashedItems.compactMap { $0 }.count) of \(urls.count) item(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Registers the UNDO of a delete: the handler restores each item from its Trash location.
    func registerRestoreItems(urls: [URL], trashResolver: AsyncValueResolver<[URL?]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            target.registerTrashItems(urls: urls, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                    let trashedItems = await trashResolver.get()
                    var restored = 0
                    var restoreFailures = 0
                    for (idx, targetURL) in urls.enumerated() {
                        if let trashedURL = trashedItems[idx] {
                            try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if fm.fileExists(atPath: targetURL.path) {
                                // A different item now occupies the deleted item's location. Restoring
                                // from Trash here would silently replace-and-Trash it (untracked by
                                // Redo). Refuse and report; the item stays in the Trash, recoverable.
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: targetURL, from: trashedURL, actionName: actionName, error: FileSyncManager.restoreTargetOccupiedError, on: target)
                            } else {
                                do {
                                    _ = try FileSyncManager.safeMoveItem(at: trashedURL, to: targetURL, fileManager: fm)
                                    restored += 1
                                } catch {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRestoreFailure(of: targetURL, from: trashedURL, actionName: actionName, error: error, on: target)
                                }
                            }
                        }
                    }
                    logger.info("Undo (\(actionName)): restored \(restored) of \(urls.count) deleted item(s) from Trash, \(restoreFailures) restore failure(s)")
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
