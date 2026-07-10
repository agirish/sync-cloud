import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)

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

    func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
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

                        let redoParams = items.map { (source: $0.source, destination: $0.destination) }
                        await redoParamResolver.resolve(redoParams)

                        // Undoing a copy deletes the copied item. On volumes without Trash that
                        // deletion is permanent, so it needs the same user confirmation as
                        // deleteItems — never a silent removeItem fallback.
                        var trashFailures: [CopyItemState] = []
                        var restored = 0
                        var restoreFailures = 0
                        for item in items {
                            do {
                                try fm.trashItem(at: item.destination, resultingItemURL: nil)
                            } catch {
                                trashFailures.append(item)
                                continue
                            }

                            if let trashed = item.overwritten {
                                do {
                                    try fm.moveItem(at: trashed, to: item.destination)
                                    restored += 1
                                } catch {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRestoreFailure(of: item.destination, from: trashed, actionName: actionName, error: error, on: target)
                                }
                            }
                        }

                        if !trashFailures.isEmpty {
                            let confirmed = await MainActor.run {
                                confirmPermanentDelete(trashFailures.map { $0.destination.lastPathComponent })
                            }
                            guard confirmed else { return }
                            for item in trashFailures {
                                try? fm.removeItem(at: item.destination)
                                if let trashed = item.overwritten {
                                    do {
                                        try fm.moveItem(at: trashed, to: item.destination)
                                        restored += 1
                                    } catch {
                                        restoreFailures += 1
                                        await FileSyncManager.reportUndoRestoreFailure(of: item.destination, from: trashed, actionName: actionName, error: error, on: target)
                                    }
                                }
                            }
                        }

                        logger.info("Undo (\(actionName)): removed \(items.count) copied item(s), restored \(restored) overwritten original(s), \(restoreFailures) restore failure(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerCopyRedo(paramResolver: AsyncValueResolver<[(source: URL, destination: URL)]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let nextUndoStateResolver = AsyncValueResolver<[CopyItemState]>()
            target.registerCopyUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [CopyItemState] = []
                        
                        for param in params {
                            try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            let trashed = try? FileSyncManager.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                            nextState.append((source: param.source, destination: param.destination, overwritten: trashed))
                        }
                        
                        await nextUndoStateResolver.resolve(nextState)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            let redoParamResolver = AsyncValueResolver<[(from: URL, to: URL)]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let items = await stateResolver.get()
                        let redoParams = items.map { (from: $0.from, to: $0.to) }
                        await redoParamResolver.resolve(redoParams)
                        
                        var movedBack = 0
                        var restoreFailures = 0
                        for item in items {
                            try? fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                            do {
                                _ = try FileSyncManager.safeMoveItem(at: item.to, to: item.from, fileManager: fm)
                                movedBack += 1
                            } catch {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: item.from, from: item.to, actionName: actionName, error: error, on: target)
                            }

                            if let trashed = item.overwritten {
                                do {
                                    try fm.moveItem(at: trashed, to: item.to)
                                } catch {
                                    restoreFailures += 1
                                    await FileSyncManager.reportUndoRestoreFailure(of: item.to, from: trashed, actionName: actionName, error: error, on: target)
                                }
                            }
                        }
                        logger.info("Undo (\(actionName)): moved \(movedBack) of \(items.count) item(s) back to source, \(restoreFailures) restore failure(s)")
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    func registerMoveRedo(paramResolver: AsyncValueResolver<[(from: URL, to: URL)]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
            let nextUndoStateResolver = AsyncValueResolver<[MoveItemState]>()
            target.registerMoveUndo(stateResolver: nextUndoStateResolver, actionName: actionName, fileManager: fm)
            
            target.preCountFileOperation()
            Task {
                await target.enqueueFileOperation(alreadyCounted: true) {
                        let params = await paramResolver.get()
                        var nextState: [MoveItemState] = []
                        
                        for param in params {
                            try? fm.createDirectory(at: param.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                            let trashed = try? FileSyncManager.safeMoveItem(at: param.from, to: param.to, fileManager: fm)
                            nextState.append((from: param.from, to: param.to, overwritten: trashed))
                        }
                        
                        await nextUndoStateResolver.resolve(nextState)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    func registerCreateFolderUndo(url: URL, fileManager fm: FileManaging = FileManager.default) {
        let confirmPermanentDelete = permanentDeleteConfirmer
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: New Folder")
            target.registerCreateFolderRedo(url: url, fileManager: fm)
            target.preCountFileOperation()
            Task { await target.enqueueFileOperation(alreadyCounted: true) {
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
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: New Folder")
            target.registerCreateFolderUndo(url: url, fileManager: fm)
            target.preCountFileOperation()
            Task { await target.enqueueFileOperation(alreadyCounted: true) { try? fm.createDirectory(at: url, withIntermediateDirectories: true) } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    func registerTrashItems(urls: [URL], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
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
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    func registerRestoreItems(urls: [URL], trashResolver: AsyncValueResolver<[URL?]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: \(actionName)")
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
                            do {
                                _ = try FileSyncManager.safeMoveItem(at: trashedURL, to: targetURL, fileManager: fm)
                                restored += 1
                            } catch {
                                restoreFailures += 1
                                await FileSyncManager.reportUndoRestoreFailure(of: targetURL, from: trashedURL, actionName: actionName, error: error, on: target)
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
