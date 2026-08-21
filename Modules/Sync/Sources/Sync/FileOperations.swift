import Events
import Foundation

extension FileSyncManager {
    // MARK: - File Operations

    /// Copies the given nodes from one pane to the other (left → right or right → left). Resolves collisions via `collisionResolver`.
    /// - Returns: The nodes that were successfully copied (may be fewer if user skips or errors occur).
    @discardableResult
    public func copyItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot),
            direction: fromLeft ? "→ Right" : "← Left",
            fileManager: fm
        )
    }

    /// Moves the given nodes to the opposite pane (removes from source). Collisions handled via `collisionResolver`.
    /// - Returns: The nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot),
            direction: fromLeft ? "→ Right" : "← Left",
            fileManager: fm
        )
    }

    /// Copies multiple files to a specific absolute destination directory path.
    /// - Returns: Nodes that were successfully copied.
    @discardableResult
    public func copyItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        // Expand once, and use the expanded value for both the root-existence guard and the
        // per-item targets (mirroring paneTargetURL): the guard stats the expanded path, so a
        // "~/…" caller must not derive its targets from the raw string.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        // Same single expansion as copyItems(toPath:) — a move also removes the sources, so a
        // misdirected target would be worse than a stray copy.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Derives the cross-pane destination for a node: its path relative to the source pane root,
    /// re-rooted under the opposite pane's root. Throws instead of guessing when the node is not
    /// actually inside the source root — including the empty-root case (a provider dropped from
    /// settings mid-session) and prefix aliasing ("/data/foo" must not claim "/data/foobar/x").
    /// The old fallback kept the node's near-absolute path and grafted it under the destination
    /// root, which is how pane swaps produced misdirected `<newRoot>/Users/…/<oldRoot>/…` copies.
    private nonisolated static func paneTargetURL(fromLeft: Bool, leftRoot: String, rightRoot: String) -> @Sendable (FileNode) throws -> URL {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        return { node in
            guard !fromRoot.isEmpty else { throw FileOperationError.sourceRootUnavailable }
            guard !toRoot.isEmpty else { throw FileOperationError.destinationRootUnavailable }
            let fromRootWithSlash = fromRoot.hasSuffix("/") ? fromRoot : fromRoot + "/"
            let relativePath: String
            if node.id == fromRoot {
                relativePath = ""
            } else if node.id.hasPrefix(fromRootWithSlash) {
                relativePath = String(node.id.dropFirst(fromRootWithSlash.count))
            } else {
                throw FileOperationError.itemOutsideSourceRoot(itemName: node.name)
            }
            return URL(fileURLWithPath: (toRoot as NSString).appendingPathComponent(relativePath))
        }
    }

    /// Shared implementation behind the four copy/move entry points. The variants differ only in
    /// how the destination URL is derived (`targetURL`), the primitive (`isMove` selects
    /// safeMoveItem/safeCopyItem, the Move/Copy undo registrar, and the log wording), and the
    /// same-URL policy: a copy onto itself keeps both under a uniquified name, a move onto
    /// itself is skipped.
    ///
    /// `destinationRoot` is the pane root or drop directory the transfer targets. It must
    /// already exist on disk: silently recreating a vanished provider root (e.g.
    /// `~/Library/CloudStorage/…` after the cloud app unmounted) would land files in a dead
    /// local tree the provider never syncs — and a move would also remove the originals.
    /// Missing intermediate folders UNDER a live root are still created per item by
    /// `ensureParentDirectoryExists`; only the root itself is never auto-created.
    /// - Returns: The nodes that were successfully transferred, in processing order.
    private func transferItems(
        nodes: [FileNode],
        isMove: Bool,
        destinationDescription: String,
        destinationRoot: String,
        targetURL deriveTargetURL: @escaping @Sendable (FileNode) throws -> URL,
        direction: String? = nil,
        fileManager fm: FileManaging
    ) async -> [FileNode] {
        let resolveCollision = collisionResolver
        // The pre-write name check runs on the MainActor (its resolver presents UI); the
        // detached loop below hops into this closure per item. Weak: if the manager is gone
        // the operation is already a no-op via its own guard, so "clean" is a safe answer.
        let checkName: @MainActor (URL) -> DestinationNameDecision = { [weak self] url in
            self?.checkDestinationName(for: url, isMove: isMove) ?? .clean
        }
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): a transfer starting mid-verify can overwrite a file as it's hashed.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before copying or moving items")
            return []
        }
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        // Standardize away a trailing slash for the existence stat; an empty root must stay
        // empty (URL(fileURLWithPath: "") would resolve against the process CWD).
        let destinationRootPath = destinationRoot.isEmpty
            ? ""
            : URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath).path

        // Count the pending operation BEFORE the confirmation prompt, not at enqueue time:
        // the prompt's modal spins the run loop, and the exclusion guards that protect
        // checksum validity (Verify All, and the scan-time auto-verify pass — which is not
        // click-gated, so the modal doesn't block it) read `activeFileOperationsCount`. An
        // unlatched prompt would let them start hashing the very files this transfer is
        // about to overwrite — the same window syncAll/syncFile close with their own latches.
        // `enqueueFileOperation(alreadyCounted: true)`'s completion decrements; a decline
        // reverts the count here. The COUNT only: `fileOperationsEpoch` moves at enqueue time,
        // because a declined prompt runs no I/O and a monotonic bump can't be taken back.
        preCountFileOperation()

        // Confirm before any I/O is queued: this is the seam that lets a mis-clicked
        // Copy/Move be cancelled while it still costs nothing. Cancelling is not an error —
        // no alert, just a debug breadcrumb and nothing transferred. An EMPTY destination
        // root (provider dropped from settings mid-session) skips the prompt — asking the
        // user to confirm `Copy "x" to ""?` and then failing anyway helps nobody; the
        // enqueue guard below turns it into the destinationRootUnavailable error directly.
        // (The on-disk existence stat deliberately stays on the operation queue.)
        if let first = prunedNodes.first, !destinationRootPath.isEmpty {
            // Name the folder the item actually LANDS in, not the destination root. The
            // cross-pane derivation re-roots each item's relative path under the far root and
            // `ensureParentDirectoryExists` builds the intermediate folders, so for anything
            // inside a subfolder the root is two or more levels shallow — the prompt read
            // `To: ~/Dropbox` for a file bound for `~/Dropbox/Reports/2025`. The drop and paste
            // routes derive `<dir>/<name>`, whose parent IS the root, so they are unaffected.
            //
            // Representative of the FIRST item, exactly like `sourceDirectory` beside it: a
            // mixed-folder selection genuinely lands in several folders and no single line can
            // say so. A derivation that throws (item outside the source root) falls back to the
            // root — the enqueue below turns that same condition into a proper error, and the
            // prompt must not be what reports it.
            let firstTargetDirectory = (try? deriveTargetURL(first))
                .map { $0.deletingLastPathComponent().path } ?? destinationRootPath
            let confirmed = transferConfirmer(TransferSummary(
                isMove: isMove,
                itemCount: prunedNodes.count,
                firstItemName: first.name,
                sourceDirectory: URL(fileURLWithPath: first.id).deletingLastPathComponent().path,
                destinationDirectory: firstTargetDirectory
            ))
            guard confirmed else {
                // The breadcrumb matters: callers log "User initiating move…" before this
                // prompt, and a decline with no record reads as a swallowed operation.
                Logger.shared.debug("\(isMove ? "Move" : "Copy") of \(prunedNodes.count) item(s) cancelled at the confirmation prompt")
                cancelPreCountedFileOperation()
                return []
            }
        }

        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "\(isMove ? "Moving" : "Copying") \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation(alreadyCounted: true) { [weak self, progress] () -> (errors: [Error], transferred: [(from: URL, to: URL, overwritten: URL?)], alreadyThere: Int) in
            guard self != nil else { return ([], [], 0) }
            // One stat, before any I/O: a missing destination root fails the whole operation
            // rather than being recreated by the per-item intermediate-directory pass below.
            guard !destinationRootPath.isEmpty, fm.fileExists(atPath: destinationRootPath) else {
                return ([FileOperationError.destinationRootUnavailable], [], 0)
            }
            // Publish progress only once this operation actually starts; setting it at enqueue
            // time would clobber the progress of an operation still running ahead in the queue.
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            // Items skipped because the move's target WAS its source. Counted rather than
            // re-derived afterwards: the loop's target can be rewritten by the provider-name
            // check, so only the loop knows which comparison actually decided the skip.
            var alreadyThere = 0

            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }

                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL: URL
                do {
                    targetURL = try deriveTargetURL(node)
                } catch {
                    taskErrors.append(error)
                    await MainActor.run {
                        progress?.completedUnitCount = Int64(index + 1)
                    }
                    continue
                }

                // Provider name check before the collision stat, so a sanitized target that
                // collides with an existing item still gets its overwrite prompt below.
                switch await MainActor.run(body: { checkName(targetURL) }) {
                case .skip:
                    // Same accounting as a collision skip: the item still counts as completed.
                    await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                    continue
                case .sanitized(let sanitizedURL):
                    targetURL = sanitizedURL
                case .clean, .keepOriginal:
                    break
                }

                if sourceURL == targetURL {
                    if isMove {
                        // A skipped item still counts as completed (like syncAll's skip
                        // accounting): a trailing skip must not strand the bar below 100%.
                        alreadyThere += 1
                        _ = await MainActor.run {
                            Logger.shared.debug("Skipping move of \"\(node.name)\": source and destination are the same location.")
                            progress?.completedUnitCount = Int64(index + 1)
                        }
                        continue
                    }
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else {
                    // Stat with isDirectory so the collision prompt can warn that replacing a
                    // folder replaces its whole contents (Finder-style), not just a same-named file.
                    var targetIsDir: ObjCBool = false
                    if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir) {
                        let collision = FileCollision(
                            sourcePath: sourceURL.path,
                            destinationPath: targetURL.path,
                            isMove: isMove,
                            isDirectory: targetIsDir.boolValue
                        )
                        let resolution = await MainActor.run { resolveCollision(collision) }
                        switch resolution {
                        case .replace: break
                        case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                        case .skip:
                            // Same accounting as the move-onto-itself skip above.
                            await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                            continue
                        }
                    }
                }

                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try Self.ensureParentDirectoryExists(for: targetURL, fileManager: fm)
                    let trashed = isMove
                        ? try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
                        : try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((from: sourceURL, to: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems, alreadyThere)
        }

        let transferred = result.transferred
        if !transferred.isEmpty {
            if isMove {
                self.registerMoveUndo(items: transferred, actionName: "Move \(transferred.count) Items", fileManager: fm)
            } else {
                // The registration is synchronous; what is awaited is the detached identity walk
                // it returns (see `registerCopyUndo(items:)`), so this operation does not return
                // until its undo is fully armed — the drift tests tamper the moment it does. The
                // await suspends the main actor rather than blocking it: the walk itself never
                // runs there.
                await self.registerCopyUndo(items: transferred.map { (source: $0.from, destination: $0.to, overwritten: $0.overwritten) }, actionName: "Copy \(transferred.count) Items", fileManager: fm).value
            }
        }

        // Clear only if still ours: a queued operation may have started and published its own.
        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }

        // Keyed lookup instead of a linear scan per transferred item; first-wins matches what
        // `first(where:)` returned should an id ever repeat in the selection.
        let nodesByID = Dictionary(prunedNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transferredNodes = transferred.compactMap { nodesByID[$0.from.path] }

        if let firstError = result.errors.first {
            let reason = firstError.localizedDescription
            // The errors here carry no item pairing, so the alert can't name the first item the
            // way the bulk-sync aggregate does — but the wording still reflects the whole run
            // (count in the message, remaining reasons logged) instead of pretending the first
            // error was the only one.
            let items = result.errors.count == 1 ? "the selected items" : "\(result.errors.count) items"
            // `present` below logs the first error (its logDescription); log only the rest here so
            // the persistent record covers every failure without double-logging the first one.
            for error in result.errors.dropFirst() {
                Logger.shared.error("\(isMove ? "Move" : "Copy") Failed: \(error.localizedDescription)")
            }
            present(isMove
                ? .moveFailed(items: items, reason: reason)
                : .copyFailed(items: items, reason: reason))
        } else if !nodes.isEmpty {
            let verb = isMove ? "Moved" : "Copied"
            // .info, not .debug: a copy/move is a data mutation that belongs in a normal-level
            // audit trail, not just a diagnostic one.
            if transferredNodes.count == prunedNodes.count {
                Logger.shared.info("\(verb) \(transferredNodes.count) item(s) \(destinationDescription)")
            } else {
                Logger.shared.info("\(verb) \(transferredNodes.count) of \(prunedNodes.count) item(s) \(destinationDescription)")
            }
            // Nothing moved, nothing failed, and every item was skipped for already sitting at
            // its target. The operation genuinely did nothing and said so NOWHERE — no banner,
            // no alert, one debug line — so confirming the prompt and watching the window not
            // change was indistinguishable from a dropped click. That is the exact shape of the
            // report that started this: both panes on one provider at the same relative path, so
            // every derived target equalled its source.
            //
            // Deliberately scoped to this one cause. A collision Skip or a cancelled progress bar
            // also transfers nothing, but both are choices the user made a moment ago and neither
            // needs restating.
            if transferred.isEmpty, result.alreadyThere == prunedNodes.count, let first = prunedNodes.first {
                // The parent's own name, falling back to its full path: `lastPathComponent` of
                // "/" is "/", and of "" is "" — either would leave the sentence dangling for an
                // item sitting directly on a root-mounted provider.
                let parent = (first.id as NSString).deletingLastPathComponent
                let leaf = (parent as NSString).lastPathComponent
                let folder = (leaf.isEmpty || leaf == "/") ? parent : leaf
                banner = .warning(prunedNodes.count == 1
                    ? "“\(first.name)” is already in \(folder)"
                    : "All \(prunedNodes.count) items are already in \(folder)")
            }
        }

        // Durable Sync History (X2): one record per transferred item, all sharing this batch's
        // run id. The result tuples don't carry size, so best-effort stat the landed file — a
        // local metadata read of a file that was just written, so it's cheap. Built SYNCHRONOUSLY
        // (no await): an awaited suspension here, after the op already decremented
        // `activeFileOperationsCount`, would let a caller waiting on completion observe "done"
        // before this method returns. Checksum is left nil at op time (see the bulk path's note).
        if !transferred.isEmpty {
            let runId = UUID()
            let recordAction: SyncAction = isMove ? .move : .copy
            let records = transferred.map { item in
                let size = ((try? fm.attributesOfItem(atPath: item.to.path))?[.size] as? NSNumber)?.intValue
                return SyncHistoryRecord(
                    runId: runId,
                    action: recordAction,
                    sourcePath: item.from.path,
                    destPath: item.to.path,
                    sizeBytes: size,
                    checksum: nil,
                    backupPath: item.overwritten?.path,
                    direction: direction
                )
            }
            recordSyncHistory(records)
        }

        return transferredNodes
    }
    
    /// Renames a specific file or folder on disk.
    public func renameItem(at path: String, to newName: String, fileManager fm: FileManaging = FileManager.default) async {
        await renameItem(
            at: path,
            to: newName,
            fileManager: fm,
            caseSensitiveVolume: Self.volumeSupportsCaseSensitiveNames(for: URL(fileURLWithPath: path))
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the item's volume.
    func renameItem(at path: String, to newName: String, fileManager fm: FileManaging, caseSensitiveVolume: Bool) async {
        if let reason = Self.validateItemName(newName) {
            // Deterministic — the same name would be rejected again, so not retryable.
            present(SyncError(title: "Rename Failed", message: reason, path: path))
            return
        }
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)

        // A case-only rename skips the collision check only where the destination stat would
        // hit the source itself (case-insensitive volumes). On a case-sensitive volume the
        // case variant is a distinct item and must trigger the collision alert like any other.
        let isCaseOnly = !caseSensitiveVolume && url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
            // Deterministic collision — renaming to the same existing name would just fail again,
            // so it is not retryable. Reveal points at the item that is in the way.
            present(SyncError(
                title: "Rename Failed",
                message: "An item named \"\(newName)\" already exists.",
                path: newURL.path
            ))
            return
        }
        
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?, collision: Bool) in
            // Re-check the collision at EXECUTION time, not just at enqueue. The check above runs on
            // the MainActor before this op joins the serial queue; a queued copy/sync ahead of it
            // could create `newName` in the interval, and safeMoveItem would then silently
            // replace-with-backup. A rename onto a now-occupied name must fail, not overwrite.
            if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
                return (nil, nil, true)
            }
            do {
                let trashed = try Self.safeMoveItem(at: url, to: newURL, fileManager: fm, caseSensitiveVolume: caseSensitiveVolume)
                return (nil, trashed, false)
            } catch {
                return (error, nil, false)
            }
        }

        if result.collision {
            present(SyncError(
                title: "Rename Failed",
                message: "An item named \"\(newName)\" already exists.",
                path: newURL.path
            ))
        } else if let err = result.error {
            present(.renameFailed(reason: err.localizedDescription, path: url.path))
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            self.registerMoveUndo(items: [(from: url, to: newURL, overwritten: result.trashed)], actionName: "Rename Item", fileManager: fm)
        }
    }
    
    /// Creates a new empty directory on disk.
    public func createFolder(named name: String, in path: String, fileManager fm: FileManaging = FileManager.default) async {
        if let reason = Self.validateItemName(name) {
            present(SyncError(title: "Couldn't Create Folder", message: reason, path: path))
            return
        }
        // Same guard as transferItems: an empty parent path (a provider that vanished from
        // settings while its stale tree was showing) must stay empty — URL(fileURLWithPath: "")
        // would resolve against the process CWD and create the folder there.
        let parentPath = path.isEmpty
            ? ""
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path
        guard !parentPath.isEmpty else {
            present(.createFolderFailed(reason: FileOperationError.destinationRootUnavailable.localizedDescription, path: path))
            return
        }
        let createdURL = URL(fileURLWithPath: parentPath).appendingPathComponent(name)

        let error = await enqueueFileOperation { () -> Error? in
            do {
                // One stat, before any I/O (matching transferItems): a parent that no longer
                // exists on disk (provider unmounted or removed) fails the operation rather
                // than surfacing a raw file-system error.
                guard fm.fileExists(atPath: parentPath) else {
                    throw FileOperationError.destinationRootUnavailable
                }
                if fm.fileExists(atPath: createdURL.path) {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey : "An item named \"\(name)\" already exists."])
                }
                try fm.createDirectory(at: createdURL, withIntermediateDirectories: false)
                return nil
            } catch let createError {
                return createError
            }
        }
        
        if let err = error {
            present(.createFolderFailed(reason: err.localizedDescription, path: path))
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL, fileManager: fm)
        }
    }

    /// Permanently deletes files or directories from disk.
    /// Whether a `trashItem` failure is transient (the item is busy/locked or momentarily
    /// permission-blocked) rather than the volume genuinely lacking a Trash. Only the latter should
    /// be offered an unrecoverable permanent delete; a transient failure must stay retryable, since
    /// silently upgrading it to a permanent delete could destroy a file a retry would have trashed.
    /// Unknown/unsupported errors are treated as non-transient so a real Trash-less volume still
    /// escalates (the pre-existing behavior).
    nonisolated static func isTransientTrashFailure(_ error: Error) -> Bool {
        // Walk the NSUnderlyingError chain, not just the outermost error: FileManager routinely
        // reports a Cocoa-domain error that WRAPS the POSIX cause, so a merely-busy item could
        // arrive here as a generic Cocoa code with EBUSY underneath. Reading only the top level
        // classified that as non-transient and escalated it to the permanent-delete prompt — the
        // exact upgrade this function exists to prevent. Bounded so a cyclic chain can't spin.
        var current = error as NSError
        for _ in 0...4 {
            if current.domain == NSPOSIXErrorDomain,
               [EBUSY, EAGAIN, EACCES, EPERM].map(Int.init).contains(current.code) {
                return true
            }
            if current.domain == NSCocoaErrorDomain,
               current.code == NSFileWriteNoPermissionError || current.code == NSFileLockingError {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }

    /// Moves the given paths to the Trash (falling back to a confirmed permanent delete only on
    /// Trash-less volumes). Returns the number of items actually removed — 0 when everything
    /// failed or a permanent delete was declined, and short of the batch after a mid-batch
    /// cancel — so callers can tell partial success from full and never report a false success.
    /// Nested paths pruned in favor of an ancestor count as removed via that ancestor (once).
    @discardableResult
    /// - Parameter reportsNothingToDo: Whether to raise a banner when NONE of the paths were still
    ///   on disk. True for the user's direct delete gesture, where silence is indistinguishable
    ///   from the click being ignored. False for the internal callers (duplicate resolve/merge,
    ///   the review's trash), which interpret a zero return themselves and post their own,
    ///   better-scoped message — a low-level "already gone" would talk over them.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default,
                            reportsNothingToDo: Bool = false) async -> DeleteOutcome {
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): a delete landing mid-verify can remove a file as it's hashed.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before deleting items")
            return DeleteOutcome()
        }
        let confirmPermanentDelete = permanentDeleteConfirmer

        // Prune nested paths to avoid redundant operations on children if parent is trashed
        let sortedPaths = paths.sorted { $0.count < $1.count }
        var prunedPaths: [String] = []
        var acceptedPaths = Set<String>()
        for path in sortedPaths {
            if !path.isInsideDirectory(anyOf: acceptedPaths) {
                prunedPaths.append(path)
                acceptedPaths.insert(path)
            }
        }

        let total = Int64(prunedPaths.count)
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Deleting \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation { [weak self, progress, prunedPaths] () -> (errors: [Error], items: [(original: URL, trashed: URL?)], declined: Int) in
            guard self != nil else { return ([], [], 0) }
            // Publish progress only once this operation actually starts (see copyItems above).
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            var trashFailures: [URL] = []

            for (index, path) in prunedPaths.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = (path as NSString).lastPathComponent
                }
                if fm.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    var trashedURL: NSURL? = nil
                    do {
                        try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                        trashedItems.append((original: url, trashed: trashedURL as? URL))
                    } catch {
                        if Self.isTransientTrashFailure(error) {
                            // Busy / locked / permission-blocked right now — common for a cloud file
                            // a provider daemon is mid-write, or an evicted placeholder. Report it as
                            // a retryable failure rather than escalating to the permanent-delete
                            // prompt: a retry may well move it to the Trash recoverably. A genuinely
                            // Trash-less volume throws an unsupported/unknown error, which still falls
                            // through to `trashFailures` and the confirmation prompt below.
                            taskErrors.append(error)
                        } else {
                            trashFailures.append(url)
                        }
                    }
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            
            var declined = 0
            if !trashFailures.isEmpty {
                let confirmed = await MainActor.run {
                    confirmPermanentDelete(trashFailures.map { $0.lastPathComponent })
                }
                
                if confirmed {
                    for url in trashFailures {
                        do {
                            try fm.removeItem(at: url)
                            trashedItems.append((original: url, trashed: nil))
                        } catch {
                            taskErrors.append(error)
                        }
                    }
                } else {
                    // Declining appended to NEITHER list, so the run ended indistinguishable from
                    // one with nothing to do — silently, or under the "already gone" banner below
                    // when other selected paths had genuinely vanished. Both are false: these
                    // items are on disk and untouched, by the user's own choice.
                    declined = trashFailures.count
                }
            }
            return (taskErrors, trashedItems, declined)
        }
        
        let items = result.items
        let successfullyTrashed = items.compactMap { $0.trashed != nil ? $0 : nil }
        if !successfullyTrashed.isEmpty {
            let urls = successfullyTrashed.map { $0.original }
            self.registerRestoreItems(urls: urls, trashedItems: successfullyTrashed.map { $0.trashed }, actionName: "Delete \(successfullyTrashed.count) Items", fileManager: fm)
        }
        
        // Show the success banner for whatever was removed, INDEPENDENTLY of any failure below: a
        // transiently-busy item in a larger batch must not hide the "Deleted N — ⌘Z" banner for the
        // items that did trash (they're already registered for undo above).
        if !items.isEmpty {
            // Distinguish recoverable (Trash) from irreversible (permanent) deletes: a permanent
            // delete happens only on Trash-less volumes after the user confirmed, and cannot be
            // undone — it deserves a named, warning-level record, not a lumped debug line.
            let permanentlyDeleted = items.filter { $0.trashed == nil }
            if permanentlyDeleted.isEmpty {
                Logger.shared.info("Moved \(items.count) item(s) to Trash")
            } else {
                let names = permanentlyDeleted.map { $0.original.lastPathComponent }.joined(separator: ", ")
                Logger.shared.warning("Permanently deleted \(permanentlyDeleted.count) item(s) that could not be moved to Trash (unrecoverable): \(names)")
                let trashedCount = items.count - permanentlyDeleted.count
                if trashedCount > 0 {
                    Logger.shared.info("Moved \(trashedCount) other item(s) to Trash")
                }
            }
            let name = items.first?.original.lastPathComponent ?? "item"
            // Undoable only when EVERY removed item went to the Trash — the restore undo can bring
            // back only the trashed subset, so a mixed batch (some permanently deleted on a
            // Trash-less volume) must not offer an Undo that would silently leave the permanent
            // deletions in place.
            let deleted = items.count == 1 ? "Deleted \"\(name)\"" : "Deleted \(items.count) items"
            // A batch can both remove some items and keep others the user declined to destroy.
            // Reporting only the removals would leave them believing the kept ones went too.
            let kept = result.declined == 0 ? "" :
                " — kept \(result.declined) that can't be moved to the Trash"
            self.banner = .success(deleted + kept, undoable: successfullyTrashed.count == items.count)
        }
        // Surface any failure (e.g. a transiently-busy item), after the success banner so a mixed
        // batch reports both what worked and what didn't.
        if let firstError = result.errors.first {
            present(.deleteFailed(reason: firstError.localizedDescription))
        } else if items.isEmpty, result.declined > 0 {
            // Checked BEFORE the "already gone" branch: these items are the opposite of gone, and
            // that branch would otherwise claim they were.
            Logger.shared.info("Delete: kept \(result.declined) item(s) that could not be moved to the Trash — the permanent delete was declined")
            banner = .warning(result.declined == 1
                ? "Kept that item — it can't be moved to the Trash, and you chose not to delete it permanently"
                : "Kept those \(result.declined) items — they can't be moved to the Trash, and you chose not to delete them permanently")
        } else if reportsNothingToDo, items.isEmpty, !prunedPaths.isEmpty, progress?.isCancelled != true {
            // Everything selected had already left the disk (deleted in Finder, or by a sync,
            // since the tree was walked), so the per-item `fileExists` pre-check skipped it all.
            // Both the banner and the error above are gated on non-empty results, so the user's
            // delete gesture produced no feedback whatsoever — indistinguishable from the app
            // ignoring the click. The rows disappear on the next refresh either way; this just
            // says why.
            Logger.shared.info("Delete: none of the \(prunedPaths.count) selected item(s) were still on disk")
            // `.warning` is this type's "completed only partially / items were skipped" rung —
            // nothing failed here, but nothing happened either.
            banner = .warning(prunedPaths.count == 1
                ? "That item was already gone"
                : "Those \(prunedPaths.count) items were already gone")
        }

        // Durable Sync History (X2): one `.delete` record per removed item, sharing this run id.
        // Size is best-effort from the Trash backup (the original is gone); a permanent delete
        // has no backup, so its size stays nil. Built SYNCHRONOUSLY (no await) so this method's
        // return timing — after `activeFileOperationsCount` was decremented — is unchanged; a
        // stat of the local Trash backup is a cheap metadata read.
        if !items.isEmpty {
            let runId = UUID()
            let records = items.map { item in
                let size = item.trashed.flatMap {
                    ((try? fm.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber)?.intValue
                }
                return SyncHistoryRecord(
                    runId: runId,
                    action: .delete,
                    sourcePath: item.original.path,
                    destPath: nil,
                    sizeBytes: size,
                    checksum: nil,
                    backupPath: item.trashed?.path,
                    direction: nil
                )
            }
            // Pair with the undo stack only when EVERY removed item reached the Trash — that's
            // when the restore-undo registered above covers exactly these records. A permanent
            // delete registers nothing for its items (mirrors the banner's undoable flag), so
            // pairing would attach these records to whatever action sits on top of the stack.
            //
            // A MIXED batch (some trashed, some permanent) did register a partial group above,
            // named by its TRASHED count — which can collide with an earlier armed delete's
            // name ("Delete 1 Items" after "Delete 1 Items"). That group now tops the stack,
            // so any surviving pairing is stale and must die: the name gate cannot tell the
            // two groups apart. All-permanent registers nothing, so the previous pairing's
            // group is still the top and stays valid.
            if !successfullyTrashed.isEmpty && successfullyTrashed.count != items.count {
                invalidateRunUndoPairing()
            }
            recordSyncHistory(records, pairedWithUndo: successfullyTrashed.count == items.count)
        }

        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }
        return DeleteOutcome(trashed: successfullyTrashed.count,
                             permanentlyDeleted: items.count - successfullyTrashed.count,
                             declined: result.declined)
    }
}
