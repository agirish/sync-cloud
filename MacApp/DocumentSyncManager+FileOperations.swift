import Foundation
import AppKit

extension DocumentSyncManager {
    
    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError {
        case identicalSourceAndDestination
        case nestingViolation
        
        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "Source and destination are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            }
        }
    }
    
    private nonisolated static func validateFileOperation(source: URL, destination: URL) throws {
        let src = source.standardizedFileURL.path
        let dst = destination.standardizedFileURL.path
        
        if src == dst {
            throw FileOperationError.identicalSourceAndDestination
        }
        
        if dst.hasPrefix(src + "/") {
            throw FileOperationError.nestingViolation
        }
    }
    
    // MARK: - Collision Resolution
    
    enum CollisionResolution {
        case replace
        case keepBoth
        case skip
    }
    
    @MainActor
    private static func promptForCollision(fileName: String, isMove: Bool) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(fileName)\" already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you're \(isMove ? "moving" : "copying")?"
        
        // Buttons added right to left.
        alert.addButton(withTitle: "Keep Both") // First added (Rightmost, Return key default)
        alert.addButton(withTitle: "Skip")      // Second added (Middle)
        alert.addButton(withTitle: "Replace")   // Third added (Leftmost)
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .skip
        case .alertThirdButtonReturn:
            return .replace
        default:
            return .skip
        }
    }
    
    private nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let extensionStr = url.pathExtension
        
        var counter = 2
        var newURL = url
        
        while fileManager.fileExists(atPath: newURL.path) {
            let newFilename = "\(filename) \(counter)"
            if extensionStr.isEmpty {
                newURL = directory.appendingPathComponent(newFilename)
            } else {
                newURL = directory.appendingPathComponent(newFilename).appendingPathExtension(extensionStr)
            }
            counter += 1
        }
        
        return newURL
    }
    
    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        var trashedOriginal: URL? = nil
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        
        if !isCaseOnlyRenaming(source: sourceURL, destination: destinationURL) && fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            trashedOriginal = trashedURL as URL?
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
        return trashedOriginal
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        var trashedOriginal: URL? = nil
        if !isCaseOnlyRenaming(source: sourceURL, destination: destinationURL) && fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            trashedOriginal = trashedURL as URL?
        }
        
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for Cross-Volume moves (EXDEV) or other similar access issues
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try? fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
        }
        
        return trashedOriginal
    }
    
    
    private nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL) -> Bool {
        return source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }

    // MARK: - File Operations
    
    /// Copies multiple files or folders between the Source and Destination panes.
    func copyItems(nodes: [FileNode], fromSource: Bool, sourceRoot: String, destinationRoot: String) async {
        let fromRoot = ((fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        
        let result = await enqueueFileOperation { () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let relativePath = node.id.replacingOccurrences(of: fromRoot, with: "")
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: targetPath)
                
                if sourceURL == targetURL {
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: targetURL.lastPathComponent, isMove: false) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetItems)
        }
        
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Copied \(nodes.count) items between panes")
        }
    }
    
    /// Copies multiple files to a specific absolute destination directory path.
    func copyItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: targetURL.lastPathComponent, isMove: false) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetItems)
        }
        
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Copied \(nodes.count) items to \(destinationPath)")
        }
    }
    
    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    func moveItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], moved: [(from: URL, to: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    continue
                } else if fm.fileExists(atPath: targetURL.path) {
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: targetURL.lastPathComponent, isMove: true) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((from: sourceURL, to: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetItems)
        }
        
        let moved = result.moved
        if !moved.isEmpty {
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve(moved) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Move \(moved.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error moving items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Moved \(nodes.count) items to \(destinationPath)")
        }
    }
    
    /// Renames a specific file or folder on disk.
    func renameItem(at path: String, to newName: String) async {
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        
        let isCaseOnly = url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && FileManager.default.fileExists(atPath: newURL.path) {
            let msg = "Error renaming item: An item named \"\(newName)\" already exists."
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
            return
        }
        
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?) in
            let fm = FileManager.default
            do {
                let trashed = try Self.safeMoveItem(at: url, to: newURL, fileManager: fm)
                return (nil, trashed)
            } catch {
                return (error, nil)
            }
        }
        
        if let err = result.error {
            let msg = "Error renaming item: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve([(from: url, to: newURL, overwritten: result.trashed)]) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Rename Item")
        }
    }
    
    /// Creates a new empty directory on disk.
    func createFolder(named name: String, in path: String) async {
        let createdURL = URL(fileURLWithPath: path).appendingPathComponent(name)
        
        let error = await enqueueFileOperation { () -> Error? in
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: createdURL.path) {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey : "An item named \"\(name)\" already exists."])
                }
                try fm.createDirectory(at: createdURL, withIntermediateDirectories: false)
                return nil
            } catch {
                return error
            }
        }
        
        if let err = error {
            let msg = "Error creating folder: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL)
        }
    }

    /// Permanently deletes files or directories from disk.
    func deleteItems(at paths: [String]) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], items: [(original: URL, trashed: URL?)]) in
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            let fm = FileManager.default
            
            for path in paths {
                do {
                    if fm.fileExists(atPath: path) {
                        let url = URL(fileURLWithPath: path)
                        var trashedURL: NSURL? = nil
                        do {
                            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                            trashedItems.append((original: url, trashed: trashedURL as? URL))
                        } catch {
                            // If trashing fails (e.g. network drive), fallback to immediate deletion if user confirms
                            let confirmed = await MainActor.run { NativeAlerts.confirmPermanentDelete(fileName: url.lastPathComponent) }
                            if confirmed {
                                do {
                                    try fm.removeItem(at: url)
                                    trashedItems.append((original: url, trashed: nil)) // Mark permanently deleted (no undo)
                                } catch let rmErr {
                                    trashedItems.append((original: url, trashed: nil))
                                    taskErrors.append(rmErr)
                                }
                            } else {
                                trashedItems.append((original: url, trashed: nil))
                                taskErrors.append(error)
                            }
                        }
                    }
                }
            }
            return (taskErrors, trashedItems)
        }
        
        let items = result.items
        let successfullyTrashed = items.compactMap { $0.trashed != nil ? $0 : nil }
        if !successfullyTrashed.isEmpty {
            let urls = successfullyTrashed.map { $0.original }
            let initialResolver = AsyncValueResolver<[URL?]>()
            Task { await initialResolver.resolve(successfullyTrashed.map { $0.trashed }) }
            
            self.registerRestoreItems(urls: urls, trashResolver: initialResolver, actionName: "Delete \(successfullyTrashed.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error deleting items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !paths.isEmpty {
            Logger.shared.info("Deleted \(paths.count) items")
        }
    }
    
    // MARK: - Undo/Redo Native Registration Stack
    
    typealias CopyItemState = (source: URL, destination: URL, overwritten: URL?)
    typealias MoveItemState = (from: URL, to: URL, overwritten: URL?)
    
    private func registerCopyUndo(stateResolver: AsyncValueResolver<[CopyItemState]>, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let redoParamResolver = AsyncValueResolver<[(source: URL, destination: URL)]>()
            target.registerCopyRedo(paramResolver: redoParamResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let items = await stateResolver.get()
                    
                    let redoParams = items.map { (source: $0.source, destination: $0.destination) }
                    await redoParamResolver.resolve(redoParams)
                    
                    for item in items {
                        try? FileManager.default.trashItem(at: item.destination, resultingItemURL: nil)
                        
                        if let trashed = item.overwritten {
                            try? FileManager.default.moveItem(at: trashed, to: item.destination)
                        }
                    }
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerCopyRedo(paramResolver: AsyncValueResolver<[(source: URL, destination: URL)]>, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let nextUndoStateResolver = AsyncValueResolver<[CopyItemState]>()
            target.registerCopyUndo(stateResolver: nextUndoStateResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let params = await paramResolver.get()
                    var nextState: [CopyItemState] = []
                    
                    let fm = FileManager.default
                    for param in params {
                        try? fm.createDirectory(at: param.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let trashed = try? Self.safeCopyItem(at: param.source, to: param.destination, fileManager: fm)
                        nextState.append((source: param.source, destination: param.destination, overwritten: trashed))
                    }
                    
                    await nextUndoStateResolver.resolve(nextState)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerMoveUndo(stateResolver: AsyncValueResolver<[MoveItemState]>, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let redoParamResolver = AsyncValueResolver<[(from: URL, to: URL)]>()
            target.registerMoveRedo(paramResolver: redoParamResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let items = await stateResolver.get()
                    let redoParams = items.map { (from: $0.from, to: $0.to) }
                    await redoParamResolver.resolve(redoParams)
                    
                    for item in items {
                        try? Self.safeMoveItem(at: item.to, to: item.from)
                        
                        if let trashed = item.overwritten {
                            try? FileManager.default.moveItem(at: trashed, to: item.to)
                        }
                    }
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    private func registerMoveRedo(paramResolver: AsyncValueResolver<[(from: URL, to: URL)]>, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let nextUndoStateResolver = AsyncValueResolver<[MoveItemState]>()
            target.registerMoveUndo(stateResolver: nextUndoStateResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let params = await paramResolver.get()
                    var nextState: [MoveItemState] = []
                    
                    for param in params {
                        try? FileManager.default.createDirectory(at: param.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let trashed = try? Self.safeMoveItem(at: param.from, to: param.to)
                        nextState.append((from: param.from, to: param.to, overwritten: trashed))
                    }
                    
                    await nextUndoStateResolver.resolve(nextState)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerCreateFolderUndo(url: URL) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCreateFolderRedo(url: url)
            Task { await target.enqueueFileOperation { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    private func registerCreateFolderRedo(url: URL) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCreateFolderUndo(url: url)
            Task { await target.enqueueFileOperation { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } }
        }
        undoManager?.setActionName("New Folder")
    }
    
    private func registerTrashItems(urls: [URL], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let nextResolver = AsyncValueResolver<[URL?]>()
            target.registerRestoreItems(urls: urls, trashResolver: nextResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let fm = FileManager.default
                    var trashedItems: [URL?] = []
                    for url in urls {
                        var t: NSURL?
                        if fm.fileExists(atPath: url.path), (try? fm.trashItem(at: url, resultingItemURL: &t)) != nil, let trashed = t as? URL {
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

    private func registerRestoreItems(urls: [URL], trashResolver: AsyncValueResolver<[URL?]>, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerTrashItems(urls: urls, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let trashedItems = await trashResolver.get()
                    for (idx, targetURL) in urls.enumerated() {
                        if let trashedURL = trashedItems[idx] {
                            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? Self.safeMoveItem(at: trashedURL, to: targetURL)
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
actor AsyncValueResolver<T> {
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
