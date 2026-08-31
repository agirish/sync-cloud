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
                // prompt, and a decline with no record reads as a swallowed operation. At the
                // same level as the initiation line, or an Info-level trace shows an operation
                // start with no outcome — the exact swallowed read this exists to prevent.
                Logger.shared.info("\(isMove ? "Move" : "Copy") of \(prunedNodes.count) item(s) cancelled at the confirmation prompt")
                cancelPreCountedFileOperation()
                return []
            }
        }

        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "\(isMove ? "Moving" : "Copying") \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation(alreadyCounted: true) { [weak self, progress] () -> (errors: [Error], transferred: [(from: URL, to: URL, overwritten: URL?)], identityWalks: [Task<CopyIdentityReading, Never>], alreadyThere: Int) in
            guard self != nil else { return ([], [], [], 0) }
            // One stat, before any I/O: a missing destination root fails the whole operation
            // rather than being recreated by the per-item intermediate-directory pass below.
            guard !destinationRootPath.isEmpty, fm.fileExists(atPath: destinationRootPath) else {
                return ([FileOperationError.destinationRootUnavailable], [], [], 0)
            }
            // Publish progress only once this operation actually starts; setting it at enqueue
            // time would clobber the progress of an operation still running ahead in the queue.
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            // One identity walk per COPIED item (parallel to `targetItems`; unused and empty for
            // moves), started the moment that item's own copy lands. Started HERE, inside the
            // loop, because the loop blocks mid-batch on user prompts — `resolveCollision` and
            // `checkName` await the main actor per item — and on slow-volume I/O, so a walk that
            // starts only at registration time (after the whole batch) would record an edit the
            // user made inside an already-landed copy during that tail as the copy's BASELINE:
            // ⌘Z would then read `.unchanged` and trash the edit. Per-item, the edit postdates
            // the recording and reads as drift, which refuses. Registration below stays
            // synchronous and merely awaits these.
            var identityWalks: [Task<CopyIdentityReading, Never>] = []
            // Earlier copies' walk indices by aggressively folded destination path (precomposed
            // + lowercased), for the duplicate-destination restart below. Aggressive on purpose:
            // it only NOMINATES candidates — the volume-gated check at the hit decides.
            var copyWalkIndicesByFoldedDestination: [String: [Int]] = [:]
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
                    if !isMove {
                        // A batch can land one destination TWICE — two same-named sources
                        // through the replace prompt, under one spelling or two ("F.txt" then
                        // "f.txt" on a folding volume). The copy that just landed replaced the
                        // EARLIER item's output, so the earlier walk now describes an item this
                        // batch itself superseded — not user drift. Left stale, the undo would
                        // refuse the earlier registration (`.changed`) and strand its pre-batch
                        // backup: the handler's duplicate-registration guard is built on both
                        // registrations recording the FINAL state (pinned by
                        // `copyUndoDuplicateRegistrationOnTrashlessVolumeRemovesOnce`, which is
                        // what caught this). Restart the superseded walks so they do; the
                        // discarded walk's result is never read.
                        let foldedTarget = targetURL.path.precomposedStringWithCanonicalMapping.lowercased()
                        for i in copyWalkIndicesByFoldedDestination[foldedTarget] ?? [] {
                            let earlier = targetItems[i].to
                            // One on-disk name: exact after precomposing (APFS lookups are
                            // normalization-insensitive on every volume), or a case variant on
                            // a volume that folds case — the undo handler's own foldedKey gate.
                            //
                            // `…ForNewItem` rather than the plain probe, for its FAILURE
                            // behaviour rather than for a missing path (`targetURL` was just
                            // copied, so it is there): the plain probe answers `false` — folds —
                            // for any path it cannot query, and a false "folds" here restarts an
                            // unrelated earlier item's walk, moving its recording time to the end
                            // of THIS copy and reopening the batch-length window
                            // `startCopyIdentityWalk` exists to eliminate. The walking-up form
                            // asks the nearest ancestor that can answer, which is the same volume,
                            // and only falls back to `false` when nothing up to "/" answers at
                            // all. For a path that resolves first time the two are one probe each.
                            let sameOnDiskName = earlier.path.precomposedStringWithCanonicalMapping
                                == targetURL.path.precomposedStringWithCanonicalMapping
                                || !Self.volumeSupportsCaseSensitiveNamesForNewItem(at: targetURL)
                            if sameOnDiskName {
                                identityWalks[i] = Self.startCopyIdentityWalk(at: earlier, fileManager: fm)
                            }
                        }
                        // `identityWalks` runs parallel to `targetItems` for copies (each append
                        // below pairs the one above), so the new walk's index is the count now.
                        copyWalkIndicesByFoldedDestination[foldedTarget, default: []].append(identityWalks.count)
                        identityWalks.append(Self.startCopyIdentityWalk(at: targetURL, fileManager: fm))
                    }
                } catch {
                    taskErrors.append(error)
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems, identityWalks, alreadyThere)
        }

        let transferred = result.transferred
        if !transferred.isEmpty {
            if isMove {
                self.registerMoveUndo(items: transferred, actionName: "Move \(transferred.count) Items", fileManager: fm)
            } else {
                // Each item's identity walk was started the moment ITS copy landed, inside the
                // loop above; the registration here is synchronous and what is awaited is the
                // collection task wrapping those walks, so this operation does not return until
                // its undo is fully armed — the drift tests tamper the moment it does. The await
                // suspends the main actor rather than blocking it: the walks never run there.
                //
                // Deliberate: the await also holds `activeProgress` (cleared just below) through
                // this identity tail — the operation does not report complete until every undo
                // it registered is armed. `activeFileOperationsCount` already reads 0 during the
                // tail (the op decremented on return), so the quit guard would not hold the app
                // for it; that is harmless — the walks are read-only, and an unarmed undo dies
                // with the process anyway.
                let pending: [PendingCopyItemState] = zip(transferred, result.identityWalks).map {
                    (source: $0.0.from, destination: $0.0.to, overwritten: $0.0.overwritten, identity: $0.1)
                }
                await self.registerCopyUndo(pendingItems: pending, actionName: "Copy \(transferred.count) Items", fileManager: fm).value
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
    /// Whether a trash failure is macOS refusing this app permission, as opposed to the item
    /// being momentarily busy.
    ///
    /// **A subset of ``isTransientTrashFailure``, deliberately, and it does not change what that
    /// decides.** Both stay out of the permanent-delete escalation — offering to destroy a file
    /// outright because the app was denied the Trash would be answering a permission problem with
    /// an unrecoverable act. What this changes is only what the user is TOLD: a busy file is worth
    /// retrying, a denied one is not, and the two used to arrive as the same sentence.
    nonisolated static func isPermissionRefusal(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0...4 {
            if current.domain == NSPOSIXErrorDomain,
               [EACCES, EPERM].map(Int.init).contains(current.code) {
                return true
            }
            if current.domain == NSCocoaErrorDomain,
               current.code == NSFileWriteNoPermissionError {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            current = underlying
        }
        return false
    }

    /// What `trashAfterReregistering` did. Three cases, because two of them are not "it failed"
    /// and the caller has to tell them apart — one of them means the item is no longer at the path
    /// the user knows it by, which no "nothing was touched" message may be shown over.
    enum ReregisteredTrash {
        /// Reached the Trash. The URL is where it landed, when the platform reported one.
        case trashed(URL?)
        /// Nothing changed: the item is still at its original path, under its own name.
        case untouched
        /// Parked to re-register it, and could NOT be put back. Intact at this path — a hidden
        /// sibling of where it was — and nothing was deleted.
        case parkedAndNotRestored(URL)
    }

    /// Trashes an item that a permission refusal blocked, by first moving it inside its own
    /// directory and putting it straight back.
    ///
    /// **Measured 2026-08-30, and the second measurement is the important one.** At 18:11–19:26,
    /// twelve of twelve long-standing files under `~/Documents` — a tree iCloud syncs, so the Trash
    /// they belong in is `~/Library/Mobile Documents/.Trash` — refused BOTH ways to trash:
    /// `trashItem` from this process and `NSWorkspace.recycle` from the system service, each
    /// `NSCocoaErrorDomain 513`, while newly created files in the same folders trashed fine.
    /// Nothing about the items explained it: user-owned, mode `700`, no `chflags`, no deny ACL,
    /// writable parent, fully materialised rather than evicted placeholders, `access(2)` granting
    /// every permission the move needs — and a plain `rename(2)` of the very same item into that
    /// very same Trash directory succeeding. An ad-hoc-signed app bundle holding no privacy grants
    /// at all trashed files in the folder that refused them, so it was never TCC either.
    ///
    /// **Then at 20:30 the same probe found 24 of 24 trashable, across three subtrees, two of
    /// which had never been touched.** So this is a TRANSIENT state in the file-provider layer the
    /// two Trash APIs share — it clears on its own — and not, as the first version of this comment
    /// claimed, a permanent property of items registered long ago. What cleared it was not
    /// established; the app was quit and reinstalled at 19:32, which is a candidate and unverified.
    /// Age is what the refusal *correlated* with in one window, not what causes it.
    ///
    /// While it is in force, moving the item re-registers it and the ordinary `trashItem` then
    /// succeeds (5 of 5 on the reported tree). This parks it under a hidden sibling name and moves
    /// it right back, so the item ends where it began — same name, same inode, `rename(2)` leaves
    /// mtime alone — and the Trash it reaches is the real one, with real put-back metadata and the
    /// `(original, trashed)` pair ⌘Z already relies on. A hand-rolled move into `.Trash` would
    /// reach neither.
    ///
    /// **Last, because it is the only one of the three attempts that touches the item.**
    /// `trashItem` and the system service are both tried first and leave it alone.
    nonisolated static func trashAfterReregistering(
        _ url: URL, fileManager fm: FileManaging) -> ReregisteredTrash {
        // Deliberately NOT `.tmp_<UUID>`. That is `OrphanSweeper`'s reap pattern, and for the
        // width of this function the name belongs to one of the user's own documents — a sweep
        // that mistook it for build debris would trash a real file under a name nobody chose.
        // The cost of a private prefix is that nothing reaps it, which is why the one path that
        // can leave it behind reports itself rather than returning a bare failure.
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent(".synccloud-trash-retry-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: url, to: parked)
        } catch {
            // Not silent: without this line the log shows the first refusal and nothing about the
            // retry, so a reader cannot tell whether it ran. Same reason the refusal above is
            // logged with its codes rather than Foundation's sentence.
            Logger.shared.warning(
                "Delete: \(url.path) could not be moved inside its own folder to re-register it "
                + "for the Trash, so the refusal stands — \(Self.trashFailureDiagnosis(error))")
            return .untouched
        }
        do {
            try fm.moveItem(at: parked, to: url)
        } catch {
            // The one step that can leave the item under a name the user never chose. It is a
            // same-directory rename back to the name it held a moment ago, so a failure here is
            // close to impossible — and precisely because of that, it must be loud AND must reach
            // the user, who otherwise goes looking for a file that is sitting right there hidden.
            Logger.shared.error(
                "Delete: \(url.path) was parked as \(parked.lastPathComponent) to re-register it "
                + "with the Trash and could NOT be moved back — the file is intact under that "
                + "name in the same folder and NOTHING was deleted — "
                + "\(Self.trashFailureDiagnosis(error))")
            return .parkedAndNotRestored(parked)
        }
        var trashed: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            Logger.shared.warning(
                "Delete: \(url.path) was re-registered by a move in place and the Trash STILL "
                + "refused it — \(Self.trashFailureDiagnosis(error))")
            return .untouched
        }
        return .trashed(trashed as URL?)
    }

    /// The re-registration retry, wrapped for the move primitives' source cleanup.
    ///
    /// **Those two call sites fall back to `removeItem` — the one unrecoverable branch of a move.**
    /// The refusal above blocks them exactly as it blocks a delete, so under it a move would
    /// silently destroy the original instead of trashing it. Spending the retry there first is the
    /// difference between a recoverable move and an unrecoverable one.
    ///
    /// Returns `true` when the caller must NOT fall through to that fallback: either the source
    /// reached the Trash, or it is parked, in which case `removeItem` would be aimed at a path
    /// that no longer holds it. Only for a permission refusal — a busy item is better served by
    /// the retry the caller already gets, the same discipline `deleteItems` applies.
    nonisolated static func retriedSourceCleanupTrash(_ sourceURL: URL,
                                                      after refusal: Error,
                                                      fileManager fm: FileManaging,
                                                      context: String) -> Bool {
        guard isPermissionRefusal(refusal) else { return false }
        switch trashAfterReregistering(sourceURL, fileManager: fm) {
        case .trashed:
            Task { @MainActor in
                Logger.shared.info(
                    "\(context): the original at \(sourceURL.path) reached the Trash after being "
                    + "re-registered by a move in place")
            }
            return true
        case .parkedAndNotRestored(let parked):
            Task { @MainActor in
                Logger.shared.error(
                    "\(context): the original at \(sourceURL.path) could not be moved to the "
                    + "Trash, was parked as \(parked.lastPathComponent) to retry that, and could "
                    + "not be moved back — it is intact under that name and was NOT deleted")
            }
            return true
        case .untouched:
            return false
        }
    }

    /// The domain and code of an error and everything under it, for the log.
    ///
    /// **The codes, not the sentence.** "you don't have permission to access it" is the same
    /// string for a TCC denial, a deny-delete ACL and a read-only mount; `NSCocoaErrorDomain 513`
    /// wrapping `NSPOSIXErrorDomain 1` tells the next reader which. Bounded, like the walks above,
    /// so a cyclic chain cannot spin.
    nonisolated static func trashFailureDiagnosis(_ error: Error) -> String {
        var parts: [String] = []
        var current = error as NSError
        for _ in 0...4 {
            parts.append("\(current.domain) \(current.code)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return parts.joined(separator: " ← ") + ": \(error.localizedDescription)"
    }

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

    /// The one spelling in which a removal gate's answer is compared with the paths it was asked
    /// about — on BOTH sides of that exchange, and inside the gate bodies themselves.
    ///
    /// `URL(fileURLWithPath:).path` deliberately, because it is exactly the transform the removal
    /// itself applies on the way to `trashItem`/`removeItem`: whatever this folds together, the
    /// syscall folds together too. Measured: it strips a trailing slash (`"/a/Folder/"` →
    /// `"/a/Folder"`), expands `~`, and makes a relative path absolute against the process's
    /// working directory; it leaves `//` and `/./` alone, and so does the removal.
    ///
    /// It exists because the two sides did NOT always hold one spelling and matched by exact
    /// string equality anyway. `deleteItems` asks the gate about the caller's own path strings the
    /// first time and about `trashFailures.map { $0.path }` — already round-tripped through `URL` —
    /// the second, immediately before the unrecoverable branch. A mismatch there failed OPEN: the
    /// refusal missed the `contains` and the item was destroyed under a banner saying it had been
    /// kept. Nothing in the shipped scan-walk paths produces such a spelling today; that is what
    /// made it an unstated invariant rather than a guard, and this is the guard.
    nonisolated static func canonicalRemovalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).path
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
    /// - Parameter removalGate: A last-moment re-verification hook for callers whose delete rests
    ///   on a claim about the paths' CONTENT (the duplicates flows: "this copy is still the copy
    ///   the scan grouped"). Called with the paths about to be removed and returns the subset to
    ///   REFUSE — those are left on disk and counted in `DeleteOutcome.refusedByGate`. Invoked at
    ///   the two points where user-paced time can invalidate a verdict formed before this call:
    ///   once when the serialized operation actually STARTS (the op queue can hold this delete
    ///   behind a minutes-long operation), and again after a confirmed permanent delete, before
    ///   anything is destroyed unrecoverably (the confirmation dialog is open for as long as the
    ///   user leaves it). The gate is the caller's own verifier, so it also owns saying which
    ///   paths it refused and why; nil (every non-duplicates caller) changes nothing.
    ///
    ///   **Per-path detail is the gate's to give, and it is not obliged to.** Both shipped gates
    ///   log every path they refuse, but nothing here requires a caller-supplied one to, so
    ///   `deleteItems` logs the COUNT itself — otherwise a wholly refused batch leaves no record
    ///   at this level at all and the user's delete gesture reads, in the log, as ignored.
    ///
    ///   **Once per invocation, over the WHOLE list — not once per path immediately before its own
    ///   removal.** Stated because it is the difference between what this guarantees and what it
    ///   could be read as guaranteeing: a path late in a large batch is removed some way after the
    ///   verdict that cleared it, and for the duplicates gate that verdict costs a folder re-walk
    ///   (~0.7 s per 40k-node folder), so a big batch's first group can be seconds old by the time
    ///   its own `trashItem` runs.
    ///
    ///   That residual is ACCEPTED, and the line is drawn where it is for a reason: everything
    ///   between the gate call and the removals is machine-paced — one `fileExists` and one
    ///   `trashItem` per path, inside a single serialized operation, with no user interaction and
    ///   nothing else able to run on the queue. The two windows this hook exists for are
    ///   user-UNBOUNDED (a queued operation of arbitrary length, a modal sheet left open over
    ///   lunch), which is a different order of exposure, not a longer one of the same kind.
    ///   Re-verifying per path would close the machine-paced remainder at the cost of running each
    ///   group's whole verification once per removal path in it — and the verification is itself
    ///   the slow thing, so a batch would spend more elapsed time inside the gate than the ageing
    ///   it removes. `theRemovalGateRunsAtOperationStartAndRefusedPathsStay` pins this shape so a
    ///   change to it is a deliberate one.
    ///
    ///   The merge is the exception worth knowing: its folds are one group's redundant copies, so
    ///   its list is short and its per-fold verification is one walk of that copy.
    /// - Parameter restoreUndoHandback: Takes the restore-undo registration away from this method
    ///   and hands the caller the `(original, Trash backup)` pairs instead — the exact arguments
    ///   `registerRestoreItems` would have been given, already filtered to the items that really
    ///   reached the Trash. For ONE caller and one reason: a merge must reverse as a single ⌘Z,
    ///   which means its copy-undo and its restore-undo have to be registered inside one
    ///   `beginUndoGrouping`/`endUndoGrouping` pair — and that pair may not be held open across an
    ///   await (NSUndoManager grouping is manager-global, so anything else registering in the
    ///   window nests into the merge's step). The only way to have both is for this method to stop
    ///   registering mid-await and let the caller register both, synchronously, once it is done
    ///   awaiting. `nil` — every other caller — keeps registering here exactly as before.
    ///
    ///   The pairs are inert data: `registerRestoreItems` records no snapshot at registration
    ///   time, so deferring it changes nothing about what the undo will do. What the caller owes
    ///   in exchange is that it register them, in the same main-actor turn this returns in, or the
    ///   trash it just did has no undo at all.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default,
                            reportsNothingToDo: Bool = false,
                            removalGate: (@Sendable ([String]) async -> Set<String>)? = nil,
                            restoreUndoHandback: (([URL], [URL?]) -> Void)? = nil) async -> DeleteOutcome {
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): a delete landing mid-verify can remove a file as it's hashed.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before deleting items")
            return DeleteOutcome()
        }
        let confirmPermanentDelete = permanentDeleteConfirmer
        let recycle = trashViaWorkspace

        // Prune nested paths to avoid redundant operations on children if parent is trashed.
        //
        // A pruned path is not spared — it is destroyed WITH the ancestor that swallowed it — so
        // it must still be verified, and its ancestor must answer for it. Dropping it from the
        // gate's input silently removed it from the verification: the duplicates gate's
        // `guard !groupPaths.isEmpty else { continue }` skipped the whole group, and its
        // fail-closed `unattributed` block is computed from the already-pruned list, so it could
        // not see the omission either. `swallowed` keeps the (child, ancestor) pairs so both
        // halves can be repaired below. Not reachable from the shipped duplicate finder
        // (`coveredRoots` prevents nesting between the groups it emits), but
        // `applyRecommendedDuplicates` is `public` and takes caller-supplied groups — the same
        // reachability standard the two gate bodies' fail-closed blocks were written to.
        let sortedPaths = paths.sorted { $0.count < $1.count }
        var prunedPaths: [String] = []
        var acceptedPaths = Set<String>()
        var swallowed: [(path: String, ancestor: String)] = []
        for path in sortedPaths {
            if let ancestor = acceptedPaths.first(where: { path.isInsideDirectory(anyOf: [$0]) }) {
                swallowed.append((path: path, ancestor: ancestor))
            } else {
                prunedPaths.append(path)
                acceptedPaths.insert(path)
            }
        }
        // Keyed on the ancestor, so each gate call can add the children its own targets will take
        // down with them.
        let swallowedByAncestor = Dictionary(grouping: swallowed) {
            FileSyncManager.canonicalRemovalPath($0.ancestor)
        }.mapValues { $0.map(\.path) }

        let total = Int64(prunedPaths.count)
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Deleting \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation { [weak self, progress, prunedPaths, swallowedByAncestor] () -> (errors: [Error], items: [(original: URL, trashed: URL?)], declined: Int, refused: Int) in
            guard self != nil else { return ([], [], 0, 0) }
            // Publish progress only once this operation actually starts (see copyItems above).
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            var trashFailures: [URL] = []
            var refused = 0

            // The queue wait is over and the removals are about to run: let the caller's gate
            // re-verify its claim NOW, not when it formed it — a long operation queued ahead of
            // this one puts its whole duration between the caller's checks and this point.
            //
            // Matched on `canonicalRemovalPath`, not on the raw strings: the gate answers in
            // whatever spelling it holds, and an unmatched refusal here fails OPEN — the item is
            // removed under a banner saying it was kept. See that function for the measured
            // spellings that differ.
            // Asks the gate about `targets` AND about every nested path pruned in their favour,
            // then condemns any target whose swallowed child the gate refused: removing the
            // ancestor destroys the child, so a refusal that stopped only at the child would be a
            // refusal in name and a removal in fact.
            func gateRefusals(removing targets: [String]) async -> Set<String> {
                guard let removalGate else { return [] }
                var ask = targets
                var ownerOfChild: [String: String] = [:]
                for target in targets {
                    let targetKey = FileSyncManager.canonicalRemovalPath(target)
                    for child in swallowedByAncestor[targetKey] ?? [] {
                        ask.append(child)
                        ownerOfChild[FileSyncManager.canonicalRemovalPath(child)] = targetKey
                    }
                }
                var keys = Set(await removalGate(ask).map(FileSyncManager.canonicalRemovalPath))
                for (childKey, ownerKey) in ownerOfChild where keys.contains(childKey) {
                    guard keys.insert(ownerKey).inserted else { continue }
                    Logger.shared.warning("Delete: refusing \(ownerKey) at the last check because the removal gate refused \(childKey), which is nested inside it — trashing the ancestor would destroy the refused item anyway")
                }
                return keys
            }

            var gateRefusedKeys = Set<String>()
            if removalGate != nil {
                gateRefusedKeys = await gateRefusals(removing: prunedPaths)
                refused += prunedPaths.filter { gateRefusedKeys.contains(FileSyncManager.canonicalRemovalPath($0)) }.count
            }

            for (index, path) in prunedPaths.enumerated() {
                if progress?.isCancelled == true { break }

                await MainActor.run {
                    progress?.localizedAdditionalDescription = (path as NSString).lastPathComponent
                }
                if gateRefusedKeys.contains(FileSyncManager.canonicalRemovalPath(path)) {
                    // Refused by the gate — leave it on disk. Progress still advances below so
                    // the bar completes; the gate has already surfaced the refusal.
                    await MainActor.run {
                        progress?.completedUnitCount = Int64(index + 1)
                    }
                    continue
                }
                // **`fileExists` follows the link, and a dangling one is still a directory
                // entry.** Asked alone, it answers `false` for a symlink whose target has been
                // deleted or lives on an unmounted volume — so the item the user selected and
                // pressed Delete on was skipped here, with no error, no banner and no place in the
                // removed count. It stayed on disk and the operation reported success without it.
                //
                // `attributesOfItem` reports on the LINK, so it succeeds where the follow fails —
                // the same probe, for the same reason, as `setAsideUnreadable`, whose own comment
                // says it "keeps the dangling-symlink case refusing — the link is still a
                // directory entry". Asked second, so the ordinary path costs nothing extra.
                if fm.fileExists(atPath: path) || (try? fm.attributesOfItem(atPath: path)) != nil {
                    let url = URL(fileURLWithPath: path)
                    var trashedURL: NSURL? = nil
                    do {
                        try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                        trashedItems.append((original: url, trashed: trashedURL as? URL))
                    } catch {
                        // **The refusal gets a second, out-of-process attempt before it becomes a
                        // failure.** `trashItem` moves the item from THIS process, so it needs this
                        // process to be allowed to write wherever that item's Trash is — for a file
                        // kept in iCloud Drive, `~/Library/Mobile Documents/.Trash`. Measured on the
                        // reported file: the item and its attributes are fine, and Full Disk Access
                        // did not change the answer, so asking the system to perform the move is
                        // the remaining difference. Only on a PERMISSION refusal: a busy item is
                        // better served by the retry the caller already gets, and the Trash-less
                        // volume keeps its permanent-delete confirmation untouched below.
                        // Three attempts, in increasing order of how much they disturb the
                        // item, and a flag rather than a longer `else if` chain because the last
                        // one has three outcomes of its own — two of which are resolutions.
                        var resolved = false
                        if Self.isPermissionRefusal(error) {
                            if let moved = await recycle([url])[url] {
                                Logger.shared.info(
                                    "Delete: \(path) was refused in-process and moved to the Trash "
                                    + "by the system service instead")
                                trashedItems.append((original: url, trashed: moved))
                                resolved = true
                            } else {
                                switch Self.trashAfterReregistering(url, fileManager: fm) {
                                case .trashed(let destination):
                                    Logger.shared.info(
                                        "Delete: \(path) was refused in-process AND by the system "
                                        + "Trash service, and reached the Trash after being "
                                        + "re-registered by a move in place")
                                    trashedItems.append((original: url, trashed: destination))
                                    resolved = true
                                case .parkedAndNotRestored(let parkedURL):
                                    // Nothing was deleted, but the item is no longer at the path
                                    // the user knows it by — so the ordinary refusal below, which
                                    // says the file is untouched at that path, would be a lie.
                                    taskErrors.append(SyncError.trashParkedAndNotRestored(
                                        originalPath: path, parkedPath: parkedURL.path))
                                    resolved = true
                                case .untouched:
                                    break
                                }
                            }
                        }
                        if !resolved, Self.isTransientTrashFailure(error) {
                            // Busy / locked / permission-blocked right now — common for a cloud file
                            // a provider daemon is mid-write, or an evicted placeholder. Report it as
                            // a retryable failure rather than escalating to the permanent-delete
                            // prompt: a retry may well move it to the Trash recoverably. A genuinely
                            // Trash-less volume throws an unsupported/unknown error, which still falls
                            // through to `trashFailures` and the confirmation prompt below.
                            //
                            // **Logged with the path AND the underlying code**, which it was not.
                            // A refusal reached the user as Foundation's sentence and left nothing
                            // in the log he audits — so diagnosing one meant reproducing it. The
                            // chain is walked because Foundation wraps the POSIX cause.
                            Logger.shared.warning(
                                "Delete: the system refused to move \(path) to the Trash — "
                                + "\(Self.trashFailureDiagnosis(error))")
                            taskErrors.append(
                                Self.isPermissionRefusal(error)
                                    ? SyncError.trashNotPermitted(
                                        path: path, reason: error.localizedDescription)
                                    : error)
                        } else if !resolved {
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
                    confirmPermanentDelete(trashFailures.map { $0.path })
                }

                if confirmed {
                    // The dialog was user-paced: minutes can sit between the trash attempts above
                    // and this confirmation, and what follows is the UNRECOVERABLE branch. Re-run
                    // the caller's gate over exactly the paths about to be destroyed, and refuse
                    // the ones whose claim no longer holds — a stale verdict must never feed a
                    // permanent delete.
                    //
                    // The paths handed over here are URL round-tripped, which the caller's own
                    // spelling need not be — the mismatch this canonical match exists for, and the
                    // place it mattered most: an unmatched refusal let `removeItem` run.
                    var toRemove = trashFailures
                    if removalGate != nil {
                        let refusedNow = await gateRefusals(removing: toRemove.map { $0.path })
                        if !refusedNow.isEmpty {
                            refused += toRemove.filter { refusedNow.contains(FileSyncManager.canonicalRemovalPath($0.path)) }.count
                            toRemove.removeAll { refusedNow.contains(FileSyncManager.canonicalRemovalPath($0.path)) }
                        }
                    }
                    for url in toRemove {
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
            return (taskErrors, trashedItems, declined, refused)
        }
        
        let items = result.items
        let successfullyTrashed = items.compactMap { $0.trashed != nil ? $0 : nil }
        if !successfullyTrashed.isEmpty {
            let urls = successfullyTrashed.map { $0.original }
            let backups = successfullyTrashed.map { $0.trashed }
            if let restoreUndoHandback {
                restoreUndoHandback(urls, backups)
            } else {
                self.registerRestoreItems(urls: urls, trashedItems: backups, actionName: "Delete \(successfullyTrashed.count) Items", fileManager: fm)
            }
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
        // **One line at THIS level for anything the gate kept.** The two shipped gates log per
        // refused path themselves, but `removalGate` is a public caller-supplied closure with no
        // contract requiring that — and a WHOLLY refused batch otherwise produces no
        // `deleteItems`-level record at all: the per-path `continue` is silent by design, the
        // block above is skipped because `items` is empty, and the "already gone" branch below
        // deliberately excludes this case. A delete gesture that removed nothing, for a reason,
        // has to be visible in the log whatever the gate did or did not say. Covers the partial
        // case too, where the removals were logged but the refusals were not.
        if result.refused > 0 {
            Logger.shared.info("Delete: the caller's removal gate kept \(result.refused) of \(prunedPaths.count) selected item(s); \(items.count) removed")
        }
        // Surface any failure (e.g. a transiently-busy item), after the success banner so a mixed
        // batch reports both what worked and what didn't.
        if let firstError = result.errors.first {
            // A `SyncError` built above already carries its own title, path and remedy — flattening
            // it back through `.deleteFailed(reason:)` would throw all three away and re-present it
            // as the generic sentence it exists to replace.
            present(firstError as? SyncError ?? .deleteFailed(reason: firstError.localizedDescription))
        } else if items.isEmpty, result.declined > 0 {
            // Checked BEFORE the "already gone" branch: these items are the opposite of gone, and
            // that branch would otherwise claim they were.
            Logger.shared.info("Delete: kept \(result.declined) item(s) that could not be moved to the Trash — the permanent delete was declined")
            banner = .warning(result.declined == 1
                ? "Kept that item — it can't be moved to the Trash, and you chose not to delete it permanently"
                : "Kept those \(result.declined) items — they can't be moved to the Trash, and you chose not to delete them permanently")
        } else if reportsNothingToDo, items.isEmpty, result.refused == 0, !prunedPaths.isEmpty, progress?.isCancelled != true {
            // `result.refused == 0` because a batch the gate refused wholesale is the OPPOSITE of
            // "already gone" — the items are on disk, deliberately kept, and the gate has posted
            // its own explanation.
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
            //
            // A HANDBACK is the same situation for a different reason: the group that will top the
            // stack has not been registered yet (that is the caller's next synchronous step), so
            // `undoActionName` here still names the PREVIOUS action — arming the pairing would
            // attach these records to it. Unpair, and kill any pairing the caller's imminent group
            // would otherwise shadow.
            let handedBack = restoreUndoHandback != nil && !successfullyTrashed.isEmpty
            if handedBack || (!successfullyTrashed.isEmpty && successfullyTrashed.count != items.count) {
                invalidateRunUndoPairing()
            }
            recordSyncHistory(records, pairedWithUndo: !handedBack && successfullyTrashed.count == items.count)
        }

        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }
        return DeleteOutcome(trashed: successfullyTrashed.count,
                             permanentlyDeleted: items.count - successfullyTrashed.count,
                             declined: result.declined,
                             refusedByGate: result.refused)
    }
}
