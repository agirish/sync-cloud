import Events
import Foundation
import AppKit

extension FileSyncManager {
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)
    
    func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyItemState]>, actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let redoParamResolver = AsyncValueResolver<[(source: URL, destination: URL)]>()
            target.registerCopyRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            Task {
                await target.enqueueFileOperation {
                        let items = await stateResolver.get()
                        
                        let redoParams = items.map { (source: $0.source, destination: $0.destination) }
                        await redoParamResolver.resolve(redoParams)
                        
                        for item in items {
                            do {
                                try fm.trashItem(at: item.destination, resultingItemURL: nil)
                            } catch {
                                try? fm.removeItem(at: item.destination)
                            }
                            
                            if let trashed = item.overwritten {
                                try? fm.moveItem(at: trashed, to: item.destination)
                            }
                        }
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
            
            Task {
                await target.enqueueFileOperation {
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
            let redoParamResolver = AsyncValueResolver<[(from: URL, to: URL)]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName, fileManager: fm)
            
            Task {
                await target.enqueueFileOperation {
                        let items = await stateResolver.get()
                        let redoParams = items.map { (from: $0.from, to: $0.to) }
                        await redoParamResolver.resolve(redoParams)
                        
                        for item in items {
                            try? fm.createDirectory(at: item.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                            _ = try? FileSyncManager.safeMoveItem(at: item.to, to: item.from, fileManager: fm)
                            
                            if let trashed = item.overwritten {
                                try? fm.moveItem(at: trashed, to: item.to)
                            }
                        }
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
            
            Task {
                await target.enqueueFileOperation {
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
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: New Folder")
            target.registerCreateFolderRedo(url: url, fileManager: fm)
            Task { await target.enqueueFileOperation { 
                do {
                    try fm.trashItem(at: url, resultingItemURL: nil) 
                } catch {
                    try? fm.removeItem(at: url)
                }
            } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    func registerCreateFolderRedo(url: URL, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Redo: New Folder")
            target.registerCreateFolderUndo(url: url, fileManager: fm)
            Task { await target.enqueueFileOperation { try? fm.createDirectory(at: url, withIntermediateDirectories: true) } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    func registerTrashItems(urls: [URL], actionName: String, fileManager fm: FileManaging = FileManager.default) {
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered Undo: \(actionName)")
            let nextResolver = AsyncValueResolver<[URL?]>()
            target.registerRestoreItems(urls: urls, trashResolver: nextResolver, actionName: actionName, fileManager: fm)
            
            Task {
                await target.enqueueFileOperation {
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
            target.registerTrashItems(urls: urls, actionName: actionName, fileManager: fm)
            
            Task {
                await target.enqueueFileOperation {
                    let trashedItems = await trashResolver.get()
                    for (idx, targetURL) in urls.enumerated() {
                        if let trashedURL = trashedItems[idx] {
                            try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            _ = try? FileSyncManager.safeMoveItem(at: trashedURL, to: targetURL, fileManager: fm)
                        }
                    }
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
    
    /// Fails the resolver with a provided value (e.g. empty array or nil) to unblock waiting tasks.
    func fail(with fallback: T) {
        resolve(fallback)
    }
    
    func get() async -> T {
        if let value = result { return value }
        return await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }
}
