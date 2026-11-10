import Events
import Foundation

extension FileSyncManager {
    // MARK: - File Operations

    /// Copies the given nodes from one pane to the other (left → right or right → left). Resolves collisions via `collisionResolver`.
    /// - Returns: The nodes that were successfully copied (may be fewer if user skips or errors occur).
    @discardableResult
    public func copyItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default,
                          receipt: SyncRunReceipt? = nil) async -> [FileNode] {
        let placed = panePlacements(of: nodes, fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot)
        return await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot,
                                          leftOpenAt: paneOpenAt(true), rightOpenAt: paneOpenAt(false),
                                          placedByThePane: placed),
            mergeOnly: Self.paneLandingFolderRow(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot,
                                                 leftOpenAt: paneOpenAt(true), rightOpenAt: paneOpenAt(false),
                                                 placedByThePane: placed),
            direction: fromLeft ? "→ Right" : "← Left",
            fileManager: fm,
            receipt: receipt
        )
    }

    /// Moves the given nodes to the opposite pane (removes from source). Collisions handled via `collisionResolver`.
    /// - Returns: The nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default,
                          receipt: SyncRunReceipt? = nil) async -> [FileNode] {
        let placed = panePlacements(of: nodes, fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot)
        return await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot,
                                          leftOpenAt: paneOpenAt(true), rightOpenAt: paneOpenAt(false),
                                          placedByThePane: placed),
            mergeOnly: Self.paneLandingFolderRow(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot,
                                                 leftOpenAt: paneOpenAt(true), rightOpenAt: paneOpenAt(false),
                                                 placedByThePane: placed),
            direction: fromLeft ? "→ Right" : "← Left",
            fileManager: fm,
            receipt: receipt
        )
    }

    /// Where the source pane places each node below its root, for nodes whose id isn't spelled
    /// under it (below a folder symlink, or under a root spelled through a link). By id alone these
    /// rows would be refused as outside the pane; `paneRelativePath` reads the tree's shape, as
    /// "Compare only this folder" does.
    private func panePlacements(of nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String) -> [String: String] {
        let root = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        guard !root.isEmpty else { return [:] }
        // One walk of the tree for the whole selection, not one per row.
        let unspelled = nodes.filter { PathBoundary.relativize($0.id, under: root, links: linkedFolders) == nil }
        return paneRelativePaths(of: unspelled, isLeft: fromLeft, root: root)
    }

    /// Copies multiple files to a specific absolute destination directory path.
    /// - Returns: Nodes that were successfully copied.
    @discardableResult
    public func copyItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default,
                          receipt: SyncRunReceipt? = nil) async -> [FileNode] {
        // Expand once and use it for both the root-existence guard and the per-item targets, so a
        // "~/…" caller's targets match the path the guard stats.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
            fileManager: fm,
            receipt: receipt
        )
    }

    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default,
                          receipt: SyncRunReceipt? = nil) async -> [FileNode] {
        // Same single expansion as copyItems(toPath:); a misdirected move would also remove the
        // sources.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
            fileManager: fm,
            receipt: receipt
        )
    }

    /// A folder's immediate children, hidden ones included, in name order (the order a merge asks
    /// its questions in), spelled under the path the transfer was given. Anything short of a
    /// complete listing throws, or a partly read merge would report itself done. A folder whose
    /// cloud app didn't answer throws as that, not as a permission problem.
    nonisolated static func mergeChildren(of folder: URL, fileManager fm: FileManaging) throws -> [URL] {
        let listing = fm.listing(of: folder)
        guard listing.isComplete else {
            if listing.isUnanswered {
                throw FileOperationError.folderNotAnswered(folderName: folder.lastPathComponent)
            }
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
        }
        return listing.urls
            .map { folder.appendingPathComponent($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Whether a move's merge has left nothing in `folder` but a `.DS_Store`: the rule for trashing
    /// the emptied source folder, held to by the merge and its redo. A folder that can't be fully
    /// listed is not empty.
    nonisolated static func mergeLeftNothing(in folder: URL, fileManager fm: FileManaging) -> Bool {
        let left = (try? mergeChildren(of: folder, fileManager: fm)) ?? [folder]
        return left.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    /// A move batch's undo list: `transferred` in order, with each source folder a merge emptied
    /// and trashed placed just ahead of that merge's first child.
    ///
    /// The move-undo works front to back, so the folder is back before its children move into it,
    /// rather than recreated empty by the undo's `createDirectory`. A merge records its folder after
    /// its children (and after a nested merge's folder at the same index), so among folders at one
    /// index the last recorded, the outermost, comes first.
    ///
    /// The batch's items are undone last first. `nodeStarts[k]` is where item `k`'s transfers
    /// begin, and each folder carries its item. A later item can write into an earlier one (move
    /// `A/f` and `B/f` into `D`, merging the second), so undoing front to back would send `D/f`
    /// home with `B/f`'s children inside, and their undo would find nothing.
    nonisolated static func undoItems(_ transferred: [MoveItemState], nodeStarts: [Int],
                                      restoringFirst folders: [(node: Int, before: Int, item: MoveItemState)]) -> [MoveItemState] {
        var items: [MoveItemState] = []
        items.reserveCapacity(transferred.count + folders.count)
        for node in nodeStarts.indices.reversed() {
            let lower = nodeStarts[node]
            let upper = node + 1 < nodeStarts.count ? nodeStarts[node + 1] : transferred.count
            let own = folders.filter { $0.node == node }.map { (before: $0.before - lower, item: $0.item) }
            items += undoItems(Array(transferred[lower..<upper]), restoringFirst: own)
        }
        return items
    }

    /// One item's part of ``undoItems(_:nodeStarts:restoringFirst:)``: its transfers, with each
    /// folder its merge emptied ahead of that merge's first child (`before`, relative to them).
    nonisolated static func undoItems(_ transferred: [MoveItemState],
                                      restoringFirst folders: [(before: Int, item: MoveItemState)]) -> [MoveItemState] {
        guard !folders.isEmpty else { return transferred }
        var ahead: [Int: [MoveItemState]] = [:]
        for folder in folders.reversed() { ahead[folder.before, default: []].append(folder.item) }
        var items: [MoveItemState] = []
        items.reserveCapacity(transferred.count + folders.count)
        for index in 0...transferred.count {
            items += ahead[index] ?? []
            if index < transferred.count { items.append(transferred[index]) }
        }
        return items
    }

    /// The entry's own type, without following a symlink (`attributesOfItem` doesn't), or nil when
    /// nothing is there. A dangling link counts as there, unlike with `fileExists`.
    nonisolated static func entryKind(at url: URL, fileManager fm: FileManaging) -> FileAttributeType? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.type] as? FileAttributeType) ?? (attributes[.type] as? String).map(FileAttributeType.init(rawValue:))
    }

    /// Whether a merge may walk into `url`: a real folder, not a symlink to one and not a package.
    /// A `.pages`, `.app` or `.photoslibrary` is a file to its user; merging two child by child
    /// builds a bundle neither app wrote, so a package collides as a whole, as in Finder.
    nonisolated static func isMergeableFolder(_ url: URL, fileManager fm: FileManaging) -> Bool {
        guard entryKind(at: url, fileManager: fm) == .typeDirectory else { return false }
        return (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
    }

    /// Counts what Replace and Merge would each do to `destination`, for the collision alert.
    /// Bounded, because it runs before the alert opens: past `entryLimit` entries or `timeLimit`
    /// seconds it answers nil and the alert goes without numbers, since a partial count would be
    /// invented.
    ///
    /// Paths are compared the way the destination volume compares names: folded for case and
    /// normalization unless the volume is case-sensitive.
    nonisolated static func folderMergePreview(
        source: URL, destination: URL, fileManager fm: FileManaging,
        entryLimit: Int = 5_000, timeLimit: TimeInterval = 1.0
    ) -> FolderMergePreview? {
        let deadline = Date().addingTimeInterval(timeLimit)
        let caseSensitive = volumeSupportsCaseSensitiveNames(for: destination)
        func key(_ relative: String) -> String {
            let composed = relative.precomposedStringWithCanonicalMapping
            return caseSensitive ? composed : composed.lowercased()
        }
        var visited = 0
        /// relative key → whether the entry is a real folder. Nil when the walk ran out of budget.
        func walk(_ root: URL) -> [String: Bool]? {
            var entries: [String: Bool] = [:]
            var pending: [(url: URL, relative: String)] = [(root, "")]
            while let (folder, relative) = pending.popLast() {
                // A dataless folder isn't asked for here: waiting on its cloud app would far
                // outlast this preview's budget, before the alert can open. The merge asks, if
                // chosen. An unreadable folder gives up too, since skipping it would invent a count.
                if fm.isDataless(at: folder) { return nil }
                guard let children = try? mergeChildren(of: folder, fileManager: fm) else { return nil }
                for child in children {
                    visited += 1
                    if visited > entryLimit || Date() > deadline { return nil }
                    let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                    // A package is counted as one item, like the merge itself treats it.
                    let isFolder = isMergeableFolder(child, fileManager: fm)
                    entries[key(childRelative)] = isFolder
                    if isFolder { pending.append((child, childRelative)) }
                }
            }
            return entries
        }
        guard let destinationEntries = walk(destination), let sourceEntries = walk(source) else { return nil }
        var destinationOnly = 0
        var colliding = 0
        for (path, isFolder) in destinationEntries where (path as NSString).lastPathComponent.lowercased() != ".ds_store" {
            if let sourceIsFolder = sourceEntries[path] {
                if !(isFolder && sourceIsFolder) { colliding += 1 }
            } else if !isFolder {
                destinationOnly += 1
            }
        }
        return FolderMergePreview(destinationOnlyCount: destinationOnly, collidingCount: colliding)
    }

    /// Derives the cross-pane destination for a node: its path relative to the source pane root,
    /// re-rooted under the opposite pane's root. Throws rather than guess when the node isn't inside
    /// the source root, including an empty root (a provider dropped from settings) and prefix
    /// aliasing ("/data/foo" must not claim "/data/foobar/x"); grafting the absolute path under the
    /// destination would misdirect the copy.
    ///
    /// Goes through `PathBoundary`, as linked navigation does: relative to the source root
    /// link-aware (rows under iCloud's `Documents` carry the real `~/Documents/…` path), moved from
    /// the source's landing folder to the destination's (`transferTarget`), and joined link-aware.
    /// So a Dropbox `Documents/Tax.pdf` lands in Google Drive's `My Drive/Documents`, as the pane
    /// shows, not at the account root. At and above the landing folder a row keeps its name a level
    /// up, never the other pane's root.
    ///
    /// `placedByThePane` answers for a node whose id isn't spelled under the root (below a folder
    /// symlink, or under a root spelled through a link) with where the pane places it.
    nonisolated static func paneTargetURL(fromLeft: Bool, leftRoot: String, rightRoot: String,
                                          leftOpenAt: String = "", rightOpenAt: String = "",
                                          placedByThePane: [String: String] = [:],
                                          links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
        -> @Sendable (FileNode) throws -> URL {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let fromOpenAt = fromLeft ? leftOpenAt : rightOpenAt
        let toOpenAt = fromLeft ? rightOpenAt : leftOpenAt
        return { node in
            guard !fromRoot.isEmpty else { throw FileOperationError.sourceRootUnavailable }
            guard !toRoot.isEmpty else { throw FileOperationError.destinationRootUnavailable }
            guard let relativePath = PathBoundary.relativize(node.id, under: fromRoot, links: links)
                    ?? placedByThePane[node.id] else {
                throw FileOperationError.itemOutsideSourceRoot(itemName: node.name)
            }
            guard let anchored = PathBoundary.transferTarget(relativePath, from: fromOpenAt, to: toOpenAt) else {
                throw FileOperationError.itemAboveOpeningFolder(itemName: node.name)
            }
            return URL(fileURLWithPath: PathBoundary.join(root: toRoot, relative: anchored, links: links))
        }
    }

    /// Whether a pane transfer's row is the folder its source opens at: `transferTarget` maps it
    /// onto the other source's landing folder, which may be that pane's root, so the transfer
    /// offers only Merge. A source that opens at its root has no such row.
    nonisolated static func paneLandingFolderRow(fromLeft: Bool, leftRoot: String, rightRoot: String,
                                                 leftOpenAt: String = "", rightOpenAt: String = "",
                                                 placedByThePane: [String: String] = [:],
                                                 links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
        -> @Sendable (FileNode) -> Bool {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let fromOpenAt = fromLeft ? leftOpenAt : rightOpenAt
        return { node in
            guard !fromRoot.isEmpty, !fromOpenAt.isEmpty,
                  let relative = PathBoundary.relativize(node.id, under: fromRoot, links: links)
                    ?? placedByThePane[node.id] else { return false }
            return PathBoundary.lexicalRelativize(relative, under: fromOpenAt) == ""
        }
    }

    /// Shared implementation behind the four copy/move entry points. They differ only in how the
    /// destination is derived (`targetURL`), the primitive (`isMove` picks safeMoveItem or
    /// safeCopyItem, the undo registrar and the log wording), and the same-URL policy: a copy onto
    /// itself keeps both under a new name, a move onto itself is skipped.
    ///
    /// `destinationRoot` (the pane root or drop folder) must already exist: recreating a vanished
    /// provider root would land files in a dead local tree nothing syncs, and a move would also
    /// remove the originals. Missing folders under a live root are still created per item by
    /// `ensureParentDirectoryExists`.
    /// - Returns: The nodes that were successfully transferred, in processing order.
    private func transferItems(
        nodes: [FileNode],
        isMove: Bool,
        destinationDescription: String,
        destinationRoot: String,
        targetURL deriveTargetURL: @escaping @Sendable (FileNode) throws -> URL,
        mergeOnly isLandingFolderRow: @escaping @Sendable (FileNode) -> Bool = { _ in false },
        direction: String? = nil,
        fileManager fm: FileManaging,
        receipt: SyncRunReceipt? = nil
    ) async -> [FileNode] {
        let resolveCollision = collisionResolver
        // A merge's children are a batch of their own (several collisions, one gesture), so they
        // use the bulk resolver and its "apply to all", scoped to that merge.
        let resolveMergeChildCollision = bulkCollisionResolver
        // The name check runs on the main actor (its resolver shows UI); the loop below hops here
        // per item. Weak: with the manager gone the operation is a no-op, so "clean" is safe.
        let checkName: @MainActor (URL) -> DestinationNameDecision = { [weak self] url in
            self?.checkDestinationName(for: url, isMove: isMove) ?? .clean
        }
        // Verify All's exclusion, as in syncFile: a transfer mid-verify could overwrite a file
        // as it's hashed.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before copying or moving items", log: .info)
            return []
        }
        if isMove, let refusal = oneWaySyncRefusal?(nodes.map(\.id)) {
            banner = .refusal(refusal, log: .warn)
            return []
        }
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        // Drop a trailing slash for the existence stat; an empty root stays empty
        // (URL(fileURLWithPath: "") would resolve against the process CWD).
        let destinationRootPath = destinationRoot.isEmpty
            ? ""
            : URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath).path

        // Count the operation before the confirmation prompt: its modal spins the run loop, and
        // Verify All and the scan-time auto-verify read `activeFileOperationsCount`, so they could
        // start hashing files this transfer will overwrite. Completion of
        // `enqueueFileOperation(alreadyCounted: true)` decrements; a decline reverts it here. Only
        // the count: `fileOperationsEpoch` moves at enqueue, since a bump can't be taken back.
        preCountFileOperation()

        // Confirm before any I/O is queued, so a mis-click can be cancelled for free. A decline
        // is not an error: a log line, nothing transferred. An empty destination root skips the
        // prompt (confirming `Copy "x" to ""?` helps nobody); the enqueue guard reports it as
        // destinationRootUnavailable. The existence stat stays on the operation queue.
        if let first = prunedNodes.first, !destinationRootPath.isEmpty {
            // Name the folder the first item lands in, not the destination root, which for an item
            // in a subfolder is levels too shallow. Like `sourceDirectory`, it speaks for the first
            // item only. A derivation that throws falls back to the root; the enqueue reports it.
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
                // Callers log "User initiating move…" before the prompt, so a decline needs its
                // own line at the same level, or the trace shows a start with no outcome.
                Logger.shared.info("\(isMove ? "Move" : "Copy") of \(prunedNodes.count) item(s) cancelled at the confirmation prompt")
                cancelPreCountedFileOperation()
                return []
            }
        }
        // From here the operation runs, so its finish line carries the time it took.
        let elapsed = Elapsed()

        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            // Sentence case, as Finder titles its progress; the undo name stays Title Case.
            progress.localizedDescription = "\(isMove ? "Moving" : "Copying") \(CountedNoun.phrase(Int(total), "item"))"
            progress.isCancellable = true
            progress.runLockReason = Progress.runLockReason(waitingFor: isMove ? "the move" : "the copy")
        }

        let result = await enqueueFileOperation(alreadyCounted: true) { [weak self, progress] () -> (errors: [Error], transferred: [(from: URL, to: URL, overwritten: URL?)], identityWalks: [Task<CopyIdentityReading, Never>], alreadyThere: Int, mergedNodeIDs: Set<String>, trashedMergeSources: [(node: Int, before: Int, item: MoveItemState)], nodeStarts: [Int], redirectedIntoTrash: [URL: URL], landedIdentities: [URL: ItemIdentity]) in
            guard self != nil else { return ([], [], [], 0, [], [], [], [:], [:]) }
            // One stat before any I/O: a missing destination root fails the whole operation rather
            // than being recreated by the per-item folder creation below.
            guard !destinationRootPath.isEmpty, fm.fileExists(atPath: destinationRootPath) else {
                return ([FileOperationError.destinationRootUnavailable], [], [], 0, [], [], [], [:], [:])
            }
            // Publish progress only once this operation starts, or it would clobber the progress
            // of one still running ahead in the queue.
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            // One identity walk per copied item (parallel to `targetItems`; empty for moves),
            // started the moment that copy lands. The loop can block on prompts (`resolveCollision`
            // and `checkName` await the main actor) and slow I/O, so a walk after the batch would
            // record the user's edits in a landed copy as its baseline, and ⌘Z would trash them as
            // `.unchanged`. Registration below just awaits these.
            var identityWalks: [Task<CopyIdentityReading, Never>] = []
            // Earlier copies' walk indices by aggressively folded destination (precomposed and
            // lowercased), for the duplicate-destination restart below. It only nominates
            // candidates; the volume-gated check at the hit decides.
            var copyWalkIndicesByFoldedDestination: [String: [Int]] = [:]
            // The same index for moves, over `targetItems` itself (see `recordLanded`).
            var moveIndicesByFoldedDestination: [String: [Int]] = [:]
            // Items skipped because the move's target was its source. Counted here because the
            // name check can rewrite the target, so only the loop knows what decided the skip.
            var alreadyThere = 0
            // Nodes answered with Merge that landed at least one child. A merge's transfers are its
            // children's, so they can't be matched back to the node by source path afterwards.
            var mergedNodeIDs: Set<String> = []
            // Source folders a move's merge emptied and trashed, each with the index in
            // `targetItems` where its children begin, so the undo puts the folder back before they
            // move into it. Kept apart from `targetItems`: they aren't transfers, and nothing that
            // counts or records transfers may see them.
            var trashedMergeSources: [(node: Int, before: Int, item: MoveItemState)] = []
            // Where each selected item's transfers begin in `targetItems`, and which item the loop
            // is on, so the undo can take the batch back last item first.
            var nodeStarts: [Int] = []
            var currentNode = 0
            // Each moved item's identity the moment it landed, keyed by where it landed. A later
            // item can write into it (a merge into the folder an earlier item became), and that
            // item's undo, run first, takes it back out before this one is compared.
            var landedIdentities: [URL: ItemIdentity] = [:]
            // Move records redirected into the Trash: where each is now → where it landed first.
            // Its undo reads it as any Trash backup, and Sync History names the destination the
            // user moved it to, not the Trash.
            var redirectedIntoTrash: [URL: URL] = [:]
            // Children a merge skipped (by an answer, or a `.DS_Store` the destination keeps), so
            // its log line can say what it did not do as well as what it did.
            var mergeSkipped = 0
            // Set when Cancel abandons a copy mid-item, inside a merge or not: ends the batch.
            var abandonedAtCancel = false

            /// Records one item that has landed at `targetURL`: the transfer, and for a copy the
            /// identity walk its undo will compare against.
            func recordLanded(from sourceURL: URL, to targetURL: URL, overwritten trashed: URL?) {
                var overwritten = trashed
                if isMove {
                    // A move that replaced an item this batch moved there. Moving `/A/f.txt`
                    // and `/B/f.txt` into `/D` with Replace leaves A's file at `trashed` and B's at
                    // `/D/f.txt`. If both records said `/D/f.txt`, ⌘Z would swap their contents.
                    // So the earlier record names where its file really is, and this one inherits
                    // what `/D` held before the batch, which its undo must put back. Same
                    // on-disk-name test as the copy branch below.
                    let folded = targetURL.path.precomposedStringWithCanonicalMapping.lowercased()
                    var stillThere: [Int] = []
                    for i in moveIndicesByFoldedDestination[folded] ?? [] {
                        let earlier = targetItems[i].to
                        let sameOnDiskName = earlier.path.precomposedStringWithCanonicalMapping
                            == targetURL.path.precomposedStringWithCanonicalMapping
                            || !Self.volumeSupportsCaseSensitiveNamesForNewItem(at: targetURL)
                        // Only a replace that kept the old item somewhere can be followed.
                        guard sameOnDiskName, let trashed else { stillThere.append(i); continue }
                        overwritten = targetItems[i].overwritten
                        redirectedIntoTrash[trashed] = targetItems[i].to
                        targetItems[i] = (from: targetItems[i].from, to: trashed, overwritten: nil)
                    }
                    // A redirected record no longer lives at this name, so it leaves the index.
                    moveIndicesByFoldedDestination[folded] = stillThere + [targetItems.count]
                }
                targetItems.append((from: sourceURL, to: targetURL, overwritten: overwritten))
                if isMove { landedIdentities[targetURL] = ItemIdentity.snapshot(at: targetURL, fileManager: fm) }
                if !isMove {
                    // A batch can land one destination twice (two same-named sources through
                    // Replace, as "F.txt" then "f.txt" on a folding volume). The earlier walk then
                    // describes an item the batch itself superseded; left stale, the undo would
                    // refuse that registration as `.changed` and strand its pre-batch backup. The
                    // duplicate-registration guard needs both to record the final state
                    // (`copyUndoDuplicateRegistrationOnTrashlessVolumeRemovesOnce`), so restart
                    // the superseded walks; the discarded results are never read.
                    let foldedTarget = targetURL.path.precomposedStringWithCanonicalMapping.lowercased()
                    for i in copyWalkIndicesByFoldedDestination[foldedTarget] ?? [] {
                        let earlier = targetItems[i].to
                        // One on-disk name: exact after precomposing (APFS lookups ignore
                        // normalization), or a case variant on a volume that folds case, the undo
                        // handler's own foldedKey gate. `…ForNewItem` for its failure behaviour: the
                        // plain probe answers "folds" for any path it can't query, which would
                        // restart an unrelated item's walk and move its recording to the end of
                        // this copy. The walking-up form asks the nearest ancestor that answers.
                        let sameOnDiskName = earlier.path.precomposedStringWithCanonicalMapping
                            == targetURL.path.precomposedStringWithCanonicalMapping
                            || !Self.volumeSupportsCaseSensitiveNamesForNewItem(at: targetURL)
                        if sameOnDiskName {
                            identityWalks[i] = Self.startCopyIdentityWalk(at: earlier, fileManager: fm)
                        }
                    }
                    // `identityWalks` runs parallel to `targetItems` for copies, so the new walk's
                    // index is the count now.
                    copyWalkIndicesByFoldedDestination[foldedTarget, default: []].append(identityWalks.count)
                    identityWalks.append(Self.startCopyIdentityWalk(at: targetURL, fileManager: fm))
                }
            }

            /// Copies or moves one item into a free or Replace-sanctioned `targetURL`. False when
            /// Cancel abandoned it inside its staging copy — nothing reached the destination, and it
            /// is neither a transfer nor a failure. Other failures are collected, not thrown.
            func land(_ sourceURL: URL, at targetURL: URL, itemName: String) async -> Bool {
                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try Self.ensureParentDirectoryExists(for: targetURL, fileManager: fm, mirroring: sourceURL)
                    // The item's copy watches Cancel too, so a very large item stops part-way. An
                    // abandoned copy throws `userCancelled` from its `.tmp_` staging and ends the
                    // batch without an alert, as a cancel between items does.
                    let observer = progress.map { Self.transferCopyObserver(progress: $0, itemName: itemName, sourceURL: sourceURL, fileManager: fm) }
                    let trashed = isMove
                        ? try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm, observer: observer)
                        : try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm, observer: observer)
                    recordLanded(from: sourceURL, to: targetURL, overwritten: trashed)
                } catch where CopyObserver.isCancellation(error) && progress?.isCancelled == true {
                    // Only a cancel of this operation's Progress ends the batch. A `userCancelled`
                    // from elsewhere (a provider refusing a read) is an ordinary failure;
                    // swallowing it would silently drop every item after it.
                    let abandonedTarget = targetURL.path
                    _ = await MainActor.run {
                        Logger.shared.info("\(isMove ? "Move" : "Copy") of \"\(itemName)\" abandoned mid-copy at Cancel — nothing reached \(abandonedTarget)")
                    }
                    abandonedAtCancel = true
                    return false
                } catch {
                    taskErrors.append(error)
                }
                return true
            }

            /// Merges `source` into the existing folder `destination`, child by child. What is
            /// missing lands whole; a folder in both is merged in turn, silently, as Finder does;
            /// any other child in both is a collision of its own, through the bulk resolver, so the
            /// Settings policy still applies and "apply to all" covers only this merge. A child
            /// folder's collision never seeds or reads that answer. `.DS_Store` in both stays.
            ///
            /// For a move, the source folder goes to the Trash once only a `.DS_Store` is left in
            /// it; anything skipped keeps it where it was.
            func merge(_ source: URL, into destination: URL, applyToAll: inout CollisionResolution?) async {
                let firstChildIndex = targetItems.count
                let children: [URL]
                do {
                    children = try Self.mergeChildren(of: source, fileManager: fm)
                } catch {
                    taskErrors.append(error)
                    return
                }
                for child in children {
                    if progress?.isCancelled == true || abandonedAtCancel { return }
                    let name = child.lastPathComponent
                    let target = destination.appendingPathComponent(name)
                    await MainActor.run {
                        progress?.localizedAdditionalDescription = (destination.lastPathComponent as NSString).appendingPathComponent(name)
                    }
                    guard let targetKind = Self.entryKind(at: target, fileManager: fm) else {
                        guard await land(child, at: target, itemName: name) else { return }
                        continue
                    }
                    if targetKind == .typeDirectory, Self.isMergeableFolder(child, fileManager: fm),
                       Self.isMergeableFolder(target, fileManager: fm) {
                        var nested = applyToAll
                        await merge(child, into: target, applyToAll: &nested)
                        applyToAll = nested
                        continue
                    }
                    if name == ".DS_Store" { mergeSkipped += 1; continue }
                    let targetIsDirectory = targetKind == .typeDirectory
                    let resolution: CollisionResolution
                    if let cached = applyToAll, !targetIsDirectory {
                        resolution = cached
                    } else {
                        let collision = FileCollision(sourcePath: child.path, destinationPath: target.path,
                                                      isMove: isMove, isDirectory: targetIsDirectory)
                        let answer = await MainActor.run { resolveMergeChildCollision(collision) }
                        if answer.applyToAll && !targetIsDirectory { applyToAll = answer.resolution }
                        resolution = answer.resolution
                    }
                    switch resolution {
                    case .skip, .merge:
                        mergeSkipped += 1
                        continue
                    case .replace:
                        guard await land(child, at: target, itemName: name) else { return }
                    case .keepBoth:
                        guard await land(child, at: Self.generateUniqueURL(for: target, fileManager: fm), itemName: name) else { return }
                    }
                }
                if isMove, !abandonedAtCancel, progress?.isCancelled != true {
                    if Self.mergeLeftNothing(in: source, fileManager: fm) {
                        let emptied = source.path
                        do {
                            var trashedURL: NSURL?
                            try fm.trashItem(at: source, resultingItemURL: &trashedURL)
                            // Recorded, so ⌘Z puts this folder back with its tags, icon and
                            // dates, rather than `createDirectory` making a new empty one. As a
                            // move to its Trash location it goes through the move-undo's guards: the
                            // recorded identity refuses another folder that took its name in the
                            // Trash, and an emptied Trash falls back to a new folder.
                            if let trashedURL = trashedURL as URL? {
                                trashedMergeSources.append((node: currentNode, before: firstChildIndex,
                                                            item: (from: source, to: trashedURL, overwritten: nil)))
                            }
                            _ = await MainActor.run { Logger.shared.info("Merge moved everything out of \(emptied) — the emptied folder went to the Trash") }
                        } catch {
                            // A volume with no Trash: the folder stays, empty. Never a permanent
                            // delete; it may still hold a `.DS_Store`, and keeping it costs nothing.
                            let reason = error.localizedDescription
                            _ = await MainActor.run { Logger.shared.warning("Merge moved everything out of \(emptied), but the emptied folder could not go to the Trash and was left in place: \(reason)") }
                        }
                    }
                }
            }

            items: for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }
                currentNode = nodeStarts.count
                nodeStarts.append(targetItems.count)

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
                        // A skipped item counts as completed, so a trailing skip can't strand the
                        // bar below 100%.
                        alreadyThere += 1
                        _ = await MainActor.run {
                            Logger.shared.debug("Skipping move of \"\(node.name)\": source and destination are the same location.")
                            progress?.completedUnitCount = Int64(index + 1)
                        }
                        continue
                    }
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else {
                    // Stat with isDirectory so the prompt can warn that replacing a folder replaces
                    // its whole contents, as Finder does.
                    var targetIsDir: ObjCBool = false
                    if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir) {
                        // Merge needs two real folders: `fileExists` follows a symlink, and merging
                        // through one would write into the tree it points at. A package is a
                        // document (`isMergeableFolder`).
                        let offersMerge = targetIsDir.boolValue
                            && Self.isMergeableFolder(targetURL, fileManager: fm)
                            && Self.isMergeableFolder(sourceURL, fileManager: fm)
                        // The folder this side opens at, onto the folder the other side opens at:
                        // Merge only. Where it can't merge, it is refused without asking.
                        let mergeOnly = isLandingFolderRow(node)
                        if mergeOnly && !offersMerge {
                            taskErrors.append(FileOperationError.landingFolderMergesOnly(name: node.name))
                            await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                            continue
                        }
                        let collision = FileCollision(
                            sourcePath: sourceURL.path,
                            destinationPath: targetURL.path,
                            isMove: isMove,
                            isDirectory: targetIsDir.boolValue,
                            offersMerge: offersMerge,
                            mergePreview: offersMerge ? Self.folderMergePreview(source: sourceURL, destination: targetURL, fileManager: fm) : nil,
                            mergeOnly: mergeOnly
                        )
                        var resolution = await MainActor.run { resolveCollision(collision) }
                        if mergeOnly, resolution == .replace || resolution == .keepBoth {
                            taskErrors.append(FileOperationError.landingFolderMergesOnly(name: node.name))
                            resolution = .skip
                        }
                        switch resolution {
                        case .replace: break
                        case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                        case .merge where offersMerge:
                            do {
                                // The nesting guard a Replace gets from `land`: merging a folder into
                                // its own descendant would walk what it writes.
                                try Self.validateFileOperation(source: sourceURL, destination: targetURL, merging: true)
                                let landedBefore = targetItems.count
                                let failedBefore = taskErrors.count
                                mergeSkipped = 0
                                var applyToAll: CollisionResolution?
                                await merge(sourceURL, into: targetURL, applyToAll: &applyToAll)
                                if targetItems.count > landedBefore { mergedNodeIDs.insert(node.id) }
                                let summary = "\(targetItems.count - landedBefore) item(s) \(isMove ? "moved" : "copied"), \(mergeSkipped) skipped, \(taskErrors.count - failedBefore) failed"
                                let stopped = abandonedAtCancel || progress?.isCancelled == true
                                _ = await MainActor.run {
                                    Logger.shared.info("Merged \"\(node.name)\" into \(targetURL.path)\(stopped ? " (stopped at Cancel)" : ""): \(summary)")
                                }
                            } catch {
                                taskErrors.append(error)
                            }
                            if abandonedAtCancel { break items }
                            await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                            continue
                        case .skip, .merge:
                            // Counted as completed, like the skip above. A `.merge` that wasn't
                            // offered is a stray answer, read as skip.
                            await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                            continue
                        }
                    }
                }

                guard await land(sourceURL, at: targetURL, itemName: node.name) else { break items }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems, identityWalks, alreadyThere, mergedNodeIDs, trashedMergeSources, nodeStarts, redirectedIntoTrash, landedIdentities)
        }

        let transferred = result.transferred
        /// Sync History: one record per transferred item, sharing this batch's run id. Size comes
        /// from a cheap stat of the landed file; checksum is nil, as in the bulk path.
        ///
        /// **Call it in the registration's own turn, before the copy's await:** the pairing reads
        /// the name on top of the undo stack, which after the await may be a rename or a ⌘Z.
        func recordTransferHistory() {
            let runId = UUID()
            let recordAction: SyncAction = isMove ? .move : .copy
            let records = transferred.map { item in
                let size = ((try? fm.attributesOfItem(atPath: item.to.path))?[.size] as? NSNumber)?.intValue
                return SyncHistoryRecord(
                    runId: runId,
                    action: recordAction,
                    sourcePath: item.from.path,
                    // Where the user moved it, for a record redirected into the Trash, so Undo Last
                    // Run doesn't list it as moved to `.Trash`.
                    destPath: (result.redirectedIntoTrash[item.to] ?? item.to).path,
                    sizeBytes: size,
                    checksum: nil,
                    backupPath: item.overwritten?.path,
                    direction: direction
                )
            }
            // Recorded first, then handed back: `receipt?.runId = recordSyncHistory(…)` would skip
            // the recording whenever there is no receipt, optional chaining and all.
            let recordedRun = recordSyncHistory(records)
            receipt?.runId = recordedRun
        }
        // What landed stays visible through a type filter until the pane moves.
        for item in transferred { noteOwnWrite(atPath: item.to.path) }
        // A merge that moved nothing out may still have trashed its emptied source (an empty
        // folder, or one holding only a `.DS_Store`), and ⌘Z must reverse that alone.
        if !transferred.isEmpty || (isMove && !result.trashedMergeSources.isEmpty) {
            progress?.markFinishing(isMove ? "the move" : "the copy")
            if isMove {
                // Awaited, as for the copy below: the Trash items' identities are read off the main
                // actor after registration, and returning first would let a stranger put at a
                // Trash path in that gap be recorded, and later restored, as the source folder.
                //
                // Counts the items the user moved, not every folder trashed: a nested merge's
                // emptied folder sits inside its parent's, which is the one item.
                let trashedSources = result.trashedMergeSources.map { $0.item.from.path }
                let moved = transferred.isEmpty
                    ? trashedSources.filter { path in !trashedSources.contains { path.hasPrefix($0 + "/") } }.count
                    : transferred.count
                let armed = self.registerMoveUndo(items: Self.undoItems(transferred, nodeStarts: result.nodeStarts,
                                                                        restoringFirst: result.trashedMergeSources),
                                                  mergeEmptiedFolders: Set(result.trashedMergeSources.map(\.item.to)),
                                                  redirectedIntoTrash: Set(result.redirectedIntoTrash.keys),
                                                  landedIdentities: result.landedIdentities,
                                                  actionName: "Move \(CountedNoun.phrase(moved, "Item"))", fileManager: fm)
                // A group with no history records must not leave an earlier run's pairing live: an
                // earlier "Move 1 Item" run would pass the name gate, and Undo Last Run would
                // describe that run while reversing this merge.
                if !transferred.isEmpty { recordTransferHistory() } else { invalidateRunUndoPairing() }
                await armed.value
            } else {
                // Each walk started as its copy landed; registration is synchronous, and awaiting
                // the task wrapping the walks means this returns only once its undo is armed (the
                // drift tests tamper the moment it does). The await suspends the main actor, not
                // blocks it. It also holds `activeProgress` until then. `activeFileOperationsCount`
                // already reads 0, so quit won't wait for it; harmless, as the walks only read.
                let pending: [PendingCopyItemState] = zip(transferred, result.identityWalks).map {
                    (source: $0.0.from, destination: $0.0.to, overwritten: $0.0.overwritten, identity: $0.1)
                }
                let armed = self.registerCopyUndo(pendingItems: pending, actionName: "Copy \(CountedNoun.phrase(transferred.count, "Item"))", fileManager: fm)
                recordTransferHistory()
                await armed.value
            }
        }

        // Clear only if still ours: a queued operation may have started and published its own.
        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }

        // Keyed lookup rather than a scan per item; first wins should an id repeat in the selection.
        let nodesByID = Dictionary(prunedNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var transferredNodes = transferred.compactMap { nodesByID[$0.from.path] }
        // A merged folder's transfers are its children's, so none matches the node's own path; it
        // counts as transferred when anything in it landed. The list is rebuilt in processing order
        // only then, so a batch with no merge is unaffected.
        if !result.mergedNodeIDs.isEmpty {
            let landedIDs = Set(transferredNodes.map(\.id)).union(result.mergedNodeIDs)
            var seen = Set<String>()
            transferredNodes = prunedNodes.filter { landedIDs.contains($0.id) && seen.insert($0.id).inserted }
        }

        if let firstError = result.errors.first {
            let reason = firstError.localizedDescription
            // The errors carry no item, so the alert can't name one, but it still speaks for the
            // whole run: the count in the message, the other reasons in the log.
            let items = result.errors.count == 1 ? "the selected items" : "\(result.errors.count) items"
            // `present` logs the first error; log the rest here so every failure is recorded once.
            for error in result.errors.dropFirst() {
                Logger.shared.error("\(isMove ? "Move" : "Copy") Failed: \(error.localizedDescription)")
            }
            let failure: SyncError = isMove
                ? .moveFailed(items: items, reason: reason)
                : .copyFailed(items: items, reason: reason)
            // **Don't replace the leftover alert this operation just raised.** "Original left
            // behind" is presented as the operation ends, before this, and `present` replaces; the
            // failure would hide the news of a hidden full-size duplicate. So it mentions it.
            if let leftover = currentError, leftover.isParkedOriginalLeftover {
                present(failure.mentioning(leftover))
            } else {
                present(failure)
            }
        } else if !nodes.isEmpty {
            let verb = isMove ? "Moved" : "Copied"
            // .info, not .debug: a copy or move changes data and belongs in the normal audit trail.
            if transferredNodes.count == prunedNodes.count {
                Logger.shared.info("\(verb) \(transferredNodes.count) item(s) \(destinationDescription) (\(elapsed.text))")
            } else {
                Logger.shared.info("\(verb) \(transferredNodes.count) of \(prunedNodes.count) item(s) \(destinationDescription) (\(elapsed.text))")
            }
            // Every item was skipped for already being at its target (both panes on one provider
            // at the same path, say). Say so, or it looks like a dropped click. Only for this
            // cause: a collision Skip or a Cancel was the user's own choice a moment ago.
            if transferred.isEmpty, result.alreadyThere == prunedNodes.count, let first = prunedNodes.first {
                // The parent's name, or its full path when that is "/" or "", so the sentence
                // doesn't dangle for an item at a root-mounted provider.
                let parent = (first.id as NSString).deletingLastPathComponent
                let leaf = (parent as NSString).lastPathComponent
                let folder = (leaf.isEmpty || leaf == "/") ? parent : leaf
                banner = .warning(prunedNodes.count == 1
                    ? "“\(first.name)” is already in \(folder)"
                    : "All \(prunedNodes.count) items are already in \(folder)", log: .warn)
            }
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
        // Verify All's exclusion, as every write has: a rename mid-verify moves a file out from
        // under its hash.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before renaming", log: .info)
            return
        }
        if let refusal = oneWaySyncRefusal?([path]) {
            banner = .refusal(refusal, log: .warn)
            return
        }
        if let reason = Self.validateItemName(newName) {
            // Not retryable: the same name would be rejected again.
            present(SyncError(title: "Rename Failed", message: reason, path: path))
            return
        }
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)

        // A case-only rename skips the collision check only where the stat would hit the source
        // itself (case-insensitive volumes). On a case-sensitive volume the variant is a distinct
        // item and collides like any other.
        let isCaseOnly = !caseSensitiveVolume && url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
            // Not retryable: it would collide again. Reveal points at the item in the way.
            present(SyncError(
                title: "Rename Failed",
                message: "An item named “\(newName)” already exists.",
                path: newURL.path
            ))
            return
        }
        
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?, collision: Bool) in
            // Re-check the collision when the operation runs: a copy queued ahead could create
            // `newName` meanwhile, and safeMoveItem would silently replace it. A rename onto an
            // occupied name must fail, not overwrite.
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
                message: "An item named “\(newName)” already exists.",
                path: newURL.path
            ))
        } else if let err = result.error {
            present(.renameFailed(reason: err.localizedDescription, path: url.path))
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            noteOwnWrite(atPath: newURL.path)
            self.registerMoveUndo(items: [(from: url, to: newURL, overwritten: result.trashed)], actionName: "Rename Item", fileManager: fm)
            // In History as the move it is, in the registration's own turn.
            recordSyncHistory([SyncHistoryRecord(runId: UUID(), action: .move, sourcePath: url.path, destPath: newURL.path,
                                                 backupPath: result.trashed?.path)])
        }
    }
    
    /// Creates a new empty directory on disk.
    public func createFolder(named name: String, in path: String, fileManager fm: FileManaging = FileManager.default) async {
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before making a folder", log: .info)
            return
        }
        if let reason = Self.validateItemName(name) {
            present(SyncError(title: "Couldn’t Create Folder", message: reason, path: path))
            return
        }
        // As in transferItems, an empty parent path (a provider gone from settings) stays empty:
        // URL(fileURLWithPath: "") would resolve against the process CWD.
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
                // One stat before any I/O, as in transferItems: a vanished parent (provider
                // unmounted) fails cleanly rather than with a raw file-system error.
                guard fm.fileExists(atPath: parentPath) else {
                    throw FileOperationError.destinationRootUnavailable
                }
                if fm.fileExists(atPath: createdURL.path) {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey : "An item named “\(name)” already exists."])
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
            noteOwnWrite(atPath: createdURL.path)
            self.registerCreateFolderUndo(url: createdURL, fileManager: fm)
            // In History, in the registration's own turn.
            recordSyncHistory([SyncHistoryRecord(runId: UUID(), action: .newFolder, sourcePath: createdURL.path)])
        }
    }

    /// Whether a trash failure is macOS refusing this app permission, as opposed to the item
    /// being momentarily busy.
    ///
    /// A subset of ``isTransientTrashFailure``, and it doesn't change what that decides: both stay
    /// out of the permanent-delete escalation, since a denied Trash is no reason to destroy a file.
    /// It changes only what the user is told: a busy file is worth retrying, a denied one is not.
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

    /// Whether a provider is moving this item's bytes right now.
    ///
    /// iCloud's own signals, all that is available without a file-provider entitlement (the two
    /// keys `FilingSurvey` reads). A Dropbox or Drive item mid-sync answers false and isn't
    /// covered; a false answer just leaves that item's handling unchanged.
    nonisolated static func midCloudTransfer(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                             .ubiquitousItemIsUploadingKey,
                                                             .ubiquitousItemIsDownloadingKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemIsUploading == true
            || values.ubiquitousItemIsDownloading == true
    }

    /// Where the system Trash service put `url`, read out of the dictionary it answers with, not
    /// by looking up the URL we passed.
    ///
    /// `NSWorkspace.recycle` hands back its own spelling of its keys (standardised, a `/private`
    /// prefix, a trailing slash on a folder), and `URL` compares on the absolute string. A missed
    /// lookup would read as "the service refused too", and the caller would end up offering to
    /// permanently delete a file already safe in the Trash.
    ///
    /// Two readings, sound for any number of items: the exact key, and a key naming the same file
    /// once both sides are standardised and symlink-resolved. A wider third reading, sound only for
    /// a single item, is in ``recycledSingle(_:using:)``.
    nonisolated static func recycled(_ url: URL, in moved: [URL: URL]) -> URL? {
        if let exact = moved[url] { return exact }
        let wanted = url.standardizedFileURL.resolvingSymlinksInPath().path
        return moved.first {
            $0.key.standardizedFileURL.resolvingSymlinksInPath().path == wanted
        }?.value
    }

    /// Asks the system Trash service about one item and reads its answer.
    ///
    /// The request and the read are one call, which is what makes the last reading sound:
    /// asked about exactly one item, a one-entry answer is that item, whatever spelling its key
    /// has. Over a dictionary alone that would be false for a multi-item request. The wide reading
    /// logs, since it can't be proven from the key.
    nonisolated static func recycledSingle(
        _ url: URL, using recycle: @Sendable ([URL]) async -> [URL: URL]) async -> URL? {
        let moved = await recycle([url])
        if let named = recycled(url, in: moved) { return named }
        guard moved.count == 1, let (key, destination) = moved.first else { return nil }
        Logger.shared.info(
            "Delete: the system Trash service reported moving \(url.path) under a different key "
            + "(\(key.path)) — read as this item, which is the only one it was asked about")
        return destination
    }

    /// What `trashAfterReregistering` did. Three cases, because two aren't "it failed" and the
    /// caller must tell them apart: one means the item is no longer at the path the user knows,
    /// so no "nothing was touched" message may be shown over it.
    enum ReregisteredTrash {
        /// Reached the Trash. The URL is where it landed, when the platform reported one.
        case trashed(URL?)
        /// Nothing changed: the item is still at its original path, under its own name.
        case untouched
        /// Parked to re-register it, and couldn't be put back. Intact at this path, a hidden
        /// sibling of where it was; nothing was deleted.
        case parkedAndNotRestored(URL)
    }

    /// The originals a move's source cleanup parked and couldn't put back, collected for the file
    /// operation that ran the move.
    ///
    /// A task-local, not a return value: the strand happens after the item landed, so the move is
    /// a success that can't throw, and its return value is already the replaced item's backup.
    /// `enqueueFileOperation` binds one around every operation and, if anything was recorded,
    /// presents ``SyncError/movedButOriginalParked(originalPath:parkedPath:additional:)``, so a
    /// hidden `.synccloud-trash-retry-<UUID>` duplicate never sits silently behind a Moved banner.
    ///
    /// Reaches the operation's own task and its child tasks (bulk sync's task group), not a
    /// `Task.detached` started inside it; a strand there is only logged.
    final class ParkedSourceLeftovers: @unchecked Sendable {
        @TaskLocal static var current: ParkedSourceLeftovers?
        /// Set by a move-undo around its own body: what its cleanup parks is the item it moved
        /// back from, and the alert must not say a move "reached its destination".
        @TaskLocal static var undoing = false
        private let lock = NSLock()
        private var entries: [(original: URL, parked: URL, undoing: Bool)] = []

        func record(original: URL, parked: URL) {
            let undoing = Self.undoing
            lock.lock(); defer { lock.unlock() }
            entries.append((original, parked, undoing))
        }

        var recorded: [(original: URL, parked: URL, undoing: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    /// Trashes an item that a permission refusal blocked, by first moving it inside its own
    /// directory and putting it straight back.
    ///
    /// The file-provider layer both Trash APIs share can enter a transient state in which existing
    /// files under an iCloud-synced tree refuse both `trashItem` and `NSWorkspace.recycle`
    /// (`NSCocoaErrorDomain 513`), though nothing about the item explains it and new files trash
    /// fine. It clears on its own. While it lasts, moving the item re-registers it, and the
    /// ordinary `trashItem` then succeeds.
    ///
    /// This parks the item under a hidden sibling name and moves it straight back, so it ends where
    /// it began (same name, same inode; `rename(2)` keeps mtime), and it reaches the real Trash with
    /// real put-back metadata and the `(original, trashed)` pair ⌘Z relies on. A hand-rolled move
    /// into `.Trash` would give neither. Tried last, as the only attempt that touches the item.
    ///
    /// Whether to attempt it is the caller's question (``FileSyncManager/isMidCloudTransfer``).
    /// The delete path declines it for an item mid-transfer; the move path must not, because there
    /// `.untouched` means `removeItem`.
    nonisolated static func trashAfterReregistering(
        _ url: URL, fileManager fm: FileManaging) -> ReregisteredTrash {
        // **Not `.tmp_<UUID>`**, `OrphanSweeper`'s reap pattern: here the name belongs to a user's
        // document, and a sweep would trash it under a name nobody chose. Nothing reaps this
        // prefix, so the one path that can leave it behind reports itself.
        let parked = url.deletingLastPathComponent()
            .appendingPathComponent(".synccloud-trash-retry-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: url, to: parked)
        } catch {
            // Logged, so the log shows the retry ran, with codes rather than Foundation's sentence.
            Logger.shared.warning(
                "Delete: \(url.path) could not be moved inside its own folder to re-register it "
                + "for the Trash, so the refusal stands — \(Self.trashFailureDiagnosis(error))")
            return .untouched
        }
        do {
            try fm.moveItem(at: parked, to: url)
        } catch {
            // The one step that can leave the item under a name the user never chose. Nearly
            // impossible (a same-folder rename back), so it must be loud and reach the user, who
            // would otherwise hunt for a file sitting there hidden.
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
    /// Both call sites fall back to `removeItem`, a move's one unrecoverable branch. The
    /// refusal above blocks them as it blocks a delete, so without the retry a move would destroy
    /// the original instead of trashing it.
    ///
    /// Returns `true` when the caller must not fall back: the source reached the Trash, or it is
    /// parked and `removeItem` would hit an empty path. Only for a permission refusal; a busy item
    /// gets the caller's own retry, as in `deleteItems`.
    nonisolated static func retriedSourceCleanupTrash(_ sourceURL: URL,
                                                      after refusal: Error,
                                                      fileManager fm: FileManaging,
                                                      context: String) -> Bool {
        guard isPermissionRefusal(refusal) else { return false }
        // **The delete path's mid-transfer refusal must not reach here.** There, declining to park
        // leaves a retryable refusal. Here it returns `false` and sends the caller to
        // `removeItem`, destroying the very item that refusal protects. `isMidCloudTransfer`
        // lives on the manager and is read by `deleteItems`, so nothing static picks it up.
        switch trashAfterReregistering(sourceURL, fileManager: fm) {
        case .trashed:
            Logger.shared.info(
                "\(context): the original at \(sourceURL.path) reached the Trash after being "
                + "re-registered by a move in place")
            return true
        case .parkedAndNotRestored(let parked):
            Logger.shared.error(
                "\(context): the original at \(sourceURL.path) could not be moved to the "
                + "Trash, was parked as \(parked.lastPathComponent) to retry that, and could "
                + "not be moved back — it is intact under that name and was NOT deleted")
            // Told to the user too: the move landed and returns a success, and the operation that
            // ran it reports the leftover when it ends.
            ParkedSourceLeftovers.current?.record(original: sourceURL, parked: parked)
            return true
        case .untouched:
            return false
        }
    }

    /// The domain and code of an error and everything under it, for the log.
    ///
    /// The codes, not the sentence: "you don't have permission" is the same for a TCC denial, a
    /// deny-delete ACL and a read-only mount, and the codes tell them apart. Bounded, so a cyclic
    /// chain can't spin.
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

    /// Whether a `trashItem` failure is transient (busy, locked or briefly permission-blocked)
    /// rather than a volume with no Trash. Only the latter may be offered a permanent delete; a
    /// transient failure must stay retryable, or a file a retry would have trashed could be
    /// destroyed. Unknown errors count as not transient, so a Trash-less volume still escalates.
    nonisolated static func isTransientTrashFailure(_ error: Error) -> Bool {
        // Walk the underlying-error chain: FileManager wraps the POSIX cause in a Cocoa error, so
        // a busy item can arrive as a generic code with EBUSY beneath, and reading only the top
        // would escalate it to the permanent-delete prompt. Bounded so a cycle can't spin.
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
    /// about, on both sides and inside the gate bodies.
    ///
    /// `URL(fileURLWithPath:).path`, because it is the transform the removal itself applies on the
    /// way to `trashItem`/`removeItem`: it strips a trailing slash, expands `~` and makes a
    /// relative path absolute, and leaves `//` and `/./` alone, as the removal does.
    ///
    /// **A spelling mismatch fails open:** `deleteItems` asks the gate about the caller's strings
    /// first and about URL-round-tripped paths just before the unrecoverable branch, and a refusal
    /// that missed the match would let the item be destroyed under a banner saying it was kept.
    nonisolated static func canonicalRemovalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).path
    }

    /// Moves the given paths to the Trash, falling back to a confirmed permanent delete only on
    /// Trash-less volumes. Returns the number of items removed (0 when everything failed or a
    /// permanent delete was declined, short of the batch after a cancel), so callers never report
    /// a false success. Nested paths pruned in favour of an ancestor count once, via it.
    @discardableResult
    /// - Parameter reportsNothingToDo: Whether to raise a banner when none of the paths were still
    ///   on disk. True for the user's own delete, where silence looks like an ignored click. False
    ///   for internal callers (duplicates, the review's trash), which post their own message.
    /// - Parameter removalGate: A last-moment re-check for callers whose delete rests on a claim
    ///   about the paths' content (the duplicates flows: "this is still the copy the scan
    ///   grouped"). Given the paths about to go, it returns those to refuse, which stay on disk and
    ///   count in `DeleteOutcome.refusedByGate`. Called where user-paced time can stale a verdict:
    ///   when the queued operation starts, and after a confirmed permanent delete, before anything
    ///   is destroyed. The gate says which paths it refused and why; `deleteItems` logs the count.
    ///   Nil changes nothing.
    ///
    ///   Called once over the whole list, not per path before its removal. Between the gate and the
    ///   removals is machine-paced time (a stat and a trash per path, no user interaction); the
    ///   hook exists for the user-unbounded windows. Re-checking per path would cost more than the
    ///   ageing it removes. `theRemovalGateRunsAtOperationStartAndRefusedPathsStay` pins this.
    /// - Parameter restoreUndoHandback: Hands the caller the `(original, Trash backup)` pairs
    ///   (filtered to items that reached the Trash) instead of registering the restore-undo here.
    ///   For the merge, which must reverse as one ⌘Z: its copy-undo and restore-undo must share
    ///   one undo group, and a group can't stay open across an await (grouping is manager-global).
    ///   **The caller must register them in the same main-actor turn this returns in**, or the
    ///   trash has no undo. `registerRestoreItems` records no snapshot, so deferring is safe.
    /// - Parameter resumingProgress: The caller's own run, put back on `activeProgress` when this
    ///   delete takes its progress down, for a run that contains the delete (the merge).
    ///   `activeProgress` is the write lock, the capsule and the ⌘Z gate at once. Named, not
    ///   remembered: restoring whatever was replaced could revive a finished run's lock forever.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default,
                            reportsNothingToDo: Bool = false,
                            removalGate: (@Sendable ([String]) async -> Set<String>)? = nil,
                            restoreUndoHandback: (([URL], [URL?]) -> Void)? = nil,
                            resumingProgress: Progress? = nil) async -> DeleteOutcome {
        // Verify All's exclusion, as in syncFile: a delete mid-verify could remove a file as it's
        // hashed.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before deleting items", log: .info)
            return DeleteOutcome()
        }
        if let refusal = oneWaySyncRefusal?(paths) {
            banner = .refusal(refusal, log: .warn)
            return DeleteOutcome()
        }
        let confirmPermanentDelete = permanentDeleteConfirmer
        let recycle = trashViaWorkspace
        let midTransfer = isMidCloudTransfer
        let elapsed = Elapsed()

        // Prune nested paths: a trashed parent takes its children with it.
        //
        // A pruned path isn't spared but destroyed with its ancestor, so it must still go to the
        // gate, and a refusal of it must refuse the ancestor. `swallowed` keeps the (child,
        // ancestor) pairs for that. The shipped duplicate finder never nests groups, but
        // `applyRecommendedDuplicates` is `public` and takes caller-supplied groups.
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
            // Accurate: a no-Trash volume asks first, in its own alert, before deleting outright.
            progress.localizedDescription = "Moving \(CountedNoun.phrase(Int(total), "item")) to the Trash"
            progress.isCancellable = true
            progress.runLockReason = Progress.runLockReason(waitingFor: "the move to the Trash")
        }

        let result = await enqueueFileOperation { [weak self, progress, prunedPaths, swallowedByAncestor] () -> (errors: [Error], items: [(original: URL, trashed: URL?, reachedTrash: Bool)], declined: Int, refused: Int, stoppedShort: Bool) in
            guard self != nil else { return ([], [], 0, 0, false) }
            // Publish progress only once this operation starts (see transferItems above).
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?, reachedTrash: Bool)] = []
            var trashFailures: [URL] = []
            var refused = 0
            // Set only when a Stop leaves items unvisited; a Stop during or after the last item
            // stopped nothing.
            var stoppedShort = false

            // The queue wait is over: let the caller's gate re-verify its claim now, since a long
            // operation queued ahead put its whole duration between the caller's check and here.
            // Matched on `canonicalRemovalPath`, as an unmatched refusal fails open.
            //
            // Asks about `targets` and every nested path pruned in their favour, then refuses any
            // target whose swallowed child was refused: removing the ancestor destroys the child.
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
                if progress?.isCancelled == true { stoppedShort = true; break }

                await MainActor.run {
                    progress?.localizedAdditionalDescription = (path as NSString).lastPathComponent
                }
                if gateRefusedKeys.contains(FileSyncManager.canonicalRemovalPath(path)) {
                    // Refused by the gate: leave it on disk. Progress still advances so the bar
                    // completes; the gate has reported the refusal.
                    await MainActor.run {
                        progress?.completedUnitCount = Int64(index + 1)
                    }
                    continue
                }
                // `fileExists` follows the link, and a dangling one is still an entry. Alone it
                // would skip a dangling symlink the user chose to delete, silently.
                // `attributesOfItem` reports on the link itself, as in `setAsideUnreadable`. Asked
                // second, so the ordinary path costs nothing extra.
                if fm.fileExists(atPath: path) || (try? fm.attributesOfItem(atPath: path)) != nil {
                    let url = URL(fileURLWithPath: path)
                    var trashedURL: NSURL? = nil
                    do {
                        try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                        trashedItems.append((original: url, trashed: trashedURL as? URL, reachedTrash: true))
                    } catch {
                        // A permission refusal gets an out-of-process attempt before it fails.
                        // `trashItem` needs this process to write to the item's Trash (for iCloud
                        // Drive, `~/Library/Mobile Documents/.Trash`); the system service may be
                        // allowed where it isn't. Only for a permission refusal: a busy item gets
                        // the caller's retry, and a Trash-less volume keeps its permanent-delete
                        // confirmation below. Attempts go in increasing order of disturbance; a
                        // flag, because the last has three outcomes, two of them resolutions.
                        var resolved = false
                        if Self.isPermissionRefusal(error) {
                            if let moved = await Self.recycledSingle(url, using: recycle) {
                                Logger.shared.info(
                                    "Delete: \(path) was refused in-process and moved to the Trash "
                                    + "by the system service instead")
                                trashedItems.append((original: url, trashed: moved, reachedTrash: true))
                                resolved = true
                            } else if midTransfer(url) {
                                // No third attempt while the provider is moving this item's
                                // bytes. A mid-write item throws the same
                                // `NSFileWriteNoPermissionError`, so only its transfer state tells
                                // them apart. Renaming it mid-sync invites the provider to record a
                                // delete-and-create; here, unlike the move path, not trying costs
                                // only a retryable refusal with the file left where it is.
                                Logger.shared.warning(
                                    "Delete: \(path) was refused the Trash while its provider is "
                                    + "still transferring it, so it was left where it is rather "
                                    + "than moved in place to re-register it — retry once the "
                                    + "transfer finishes")
                            } else {
                                switch Self.trashAfterReregistering(url, fileManager: fm) {
                                case .trashed(let destination):
                                    Logger.shared.info(
                                        "Delete: \(path) was refused in-process AND by the system "
                                        + "Trash service, and reached the Trash after being "
                                        + "re-registered by a move in place")
                                    trashedItems.append((original: url, trashed: destination, reachedTrash: true))
                                    resolved = true
                                case .parkedAndNotRestored(let parkedURL):
                                    // Nothing was deleted, but the item is no longer at its path,
                                    // so the ordinary "untouched" refusal below would be false.
                                    taskErrors.append(SyncError.trashParkedAndNotRestored(
                                        originalPath: path, parkedPath: parkedURL.path))
                                    resolved = true
                                case .untouched:
                                    break
                                }
                            }
                        }
                        if !resolved, Self.isTransientTrashFailure(error) {
                            // Busy, locked or permission-blocked right now (a cloud file
                            // mid-write, an evicted placeholder): a retryable failure, never the
                            // permanent-delete prompt, since a retry may trash it recoverably. A
                            // Trash-less volume throws an unknown error and still reaches
                            // `trashFailures` below. Logged with the path and underlying codes.
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
                    // The dialog is user-paced, and what follows is unrecoverable. Re-run the
                    // caller's gate over exactly the paths about to be destroyed: **a stale verdict
                    // must never feed a permanent delete.** These paths are URL round-tripped, so
                    // the canonical match matters most here.
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
                            trashedItems.append((original: url, trashed: nil, reachedTrash: false))
                        } catch {
                            taskErrors.append(error)
                        }
                    }
                } else {
                    // Counted, so the run isn't reported as having nothing to do or as "already
                    // gone": these items are on disk, untouched, by the user's choice.
                    declined = trashFailures.count
                }
            }
            return (taskErrors, trashedItems, declined, refused, stoppedShort)
        }
        
        let items = result.items
        let successfullyTrashed = items.compactMap { $0.trashed != nil ? $0 : nil }
        if !successfullyTrashed.isEmpty {
            let urls = successfullyTrashed.map { $0.original }
            let backups = successfullyTrashed.map { $0.trashed }
            if let restoreUndoHandback {
                restoreUndoHandback(urls, backups)
            } else {
                self.registerRestoreItems(urls: urls, trashedItems: backups, actionName: Self.trashUndoActionName(count: successfullyTrashed.count), fileManager: fm)
            }
        }
        
        // The run Sync History records below, named now so the success banner can report it.
        let deleteRunId = UUID()
        // The success banner for whatever was removed, independent of any failure below, so one
        // busy item doesn't hide the banner and its ⌘Z for the items that did trash.
        if !items.isEmpty {
            // Tell recoverable from permanent: a permanent delete (Trash-less volume, confirmed)
            // can't be undone and gets a named warning line.
            //
            // Decided by whether the item reached the Trash, not whether a location came back.
            // The Trash can take an item without reporting where (`.trashed(nil)`); it is
            // recoverable by hand, though ⌘Z can't restore it, so it isn't "permanently deleted".
            let permanentlyDeleted = items.filter { !$0.reachedTrash }
            let trashedWithoutLocation = items.filter { $0.reachedTrash && $0.trashed == nil }
            if !trashedWithoutLocation.isEmpty {
                let names = trashedWithoutLocation.map { $0.original.lastPathComponent }.joined(separator: ", ")
                Logger.shared.warning("Moved \(trashedWithoutLocation.count) item(s) to Trash, but the system reported no Trash location, so Undo cannot restore them (recover them from the Trash): \(names)")
            }
            if permanentlyDeleted.isEmpty {
                Logger.shared.info("Moved \(items.count) item(s) to Trash (\(elapsed.text))")
            } else {
                // Every name kept, the only record of what was destroyed; split into lines of at most
                // 200 so a large delete stays readable.
                for line in LogNames.lines("Permanently deleted \(permanentlyDeleted.count) item(s) that could not be moved to Trash (unrecoverable)",
                                           permanentlyDeleted.map { $0.original.lastPathComponent }) {
                    Logger.shared.warning(line)
                }
                let trashedCount = items.count - permanentlyDeleted.count
                if trashedCount > 0 {
                    Logger.shared.info("Moved \(trashedCount) other item(s) to Trash (\(elapsed.text))")
                }
            }
            let name = items.first?.original.lastPathComponent ?? "item"
            // Undoable only when every removed item went to the Trash: the restore brings back only
            // the trashed ones, and an Undo must not silently leave permanent deletions in place.
            let deleted = Self.removalBannerText(count: items.count, firstName: name,
                                                 anyPermanent: !permanentlyDeleted.isEmpty)
            // Name the items the user declined to destroy, or they'd think those went too.
            let kept = result.declined == 0 ? "" :
                " — kept \(result.declined.formatted()) that can’t be moved to the Trash"
            // Not with a handback: the caller registers the undo after this returns, so an Undo
            // offered now would pin to whatever step tops the stack before it.
            self.banner = .success(deleted + kept,
                                   undoable: restoreUndoHandback == nil && successfullyTrashed.count == items.count)
                .reporting(run: deleteRunId)
        }
        // One line here for anything the gate kept. A caller-supplied gate needn't log, and a
        // wholly refused batch would otherwise leave no record at all, so a delete that removed
        // nothing, for a reason, is always in the log. Covers partial refusals too.
        if result.refused > 0 {
            Logger.shared.info("Delete: the caller's removal gate kept \(result.refused) of \(prunedPaths.count) selected item(s); \(items.count) removed")
        }
        // Any failure (a busy item, say), after the success banner, so a mixed batch reports both.
        if let firstError = result.errors.first {
            // A `SyncError` already carries its title, path and remedy; `.deleteFailed(reason:)`
            // would flatten them into the generic sentence.
            present(firstError as? SyncError ?? .deleteFailed(reason: firstError.localizedDescription))
        } else if items.isEmpty, result.declined > 0 {
            // Before the "already gone" branch: these items are the opposite of gone.
            Logger.shared.info("Delete: kept \(result.declined) item(s) that could not be moved to the Trash — the permanent delete was declined")
            banner = .warning(result.declined == 1
                ? "Kept that item — it can’t be moved to the Trash, and you chose not to delete it permanently"
                : "Kept those \(result.declined) items — they can’t be moved to the Trash, and you chose not to delete them permanently", log: .warn)
        } else if reportsNothingToDo, items.isEmpty, result.refused == 0, !prunedPaths.isEmpty, progress?.isCancelled != true {
            // Everything selected had already left the disk since the tree was walked. Say so, or
            // the delete looks ignored. Not when the gate refused (`result.refused == 0`): those
            // items are on disk, kept on purpose.
            Logger.shared.info("Delete: none of the \(prunedPaths.count) selected item(s) were still on disk")
            // `.warning`: nothing failed, but nothing happened either.
            banner = .warning(prunedPaths.count == 1
                ? "That item was already gone"
                : "Those \(prunedPaths.count) items were already gone", log: .warn)
        }

        // Sync History: one `.delete` record per removed item, sharing this run id. Size comes
        // from the Trash backup (nil for a permanent delete). Built synchronously, so this returns
        // at the same point relative to `activeFileOperationsCount`.
        if !items.isEmpty {
            let runId = deleteRunId
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
                    direction: nil,
                    reachedTrash: item.reachedTrash
                )
            }
            // Pair with the undo stack only when every removed item reached the Trash at a known
            // location, so the restore-undo covers exactly these records. Otherwise pairing would
            // attach them to whatever action tops the stack.
            //
            // A mixed batch registered a partial group named by its trashed count, which can match
            // an earlier armed delete's name, so any surviving pairing is stale and is killed.
            // All-permanent registers nothing, and the previous pairing stays valid. A handback is
            // the same: the caller's group isn't registered yet, so unpair and kill any pairing it
            // would shadow.
            let handedBack = restoreUndoHandback != nil && !successfullyTrashed.isEmpty
            if handedBack || (!successfullyTrashed.isEmpty && successfullyTrashed.count != items.count) {
                invalidateRunUndoPairing()
            }
            recordSyncHistory(records, pairedWithUndo: !handedBack && successfullyTrashed.count == items.count)
        }

        if let progress, self.activeProgress === progress {
            // A Stop that left items unremoved was meant for the caller's run (the capsule showed
            // only the trash's progress), so the run handed back is cancelled and ends as a stop
            // (`lastFinishedRun.cancelled`). A Stop too late to stop anything isn't passed on.
            if result.stoppedShort { resumingProgress?.cancel() }
            self.activeProgress = resumingProgress
        } else if let resumingProgress, self.activeProgress !== resumingProgress {
            // Unreachable from the window (writes are refused while a run holds the lock), but a
            // direct caller could queue a run that publishes first. Its lock stands, and the
            // caller's tail runs under it. Logged, not fixed.
            Logger.shared.warning("Delete: could not hand the run lock back to “\(resumingProgress.runTitle ?? "the run")” — “\(self.activeProgress?.runTitle ?? "nothing")” holds it")
        }
        let reachedTrash = items.filter(\.reachedTrash).count
        return DeleteOutcome(trashed: successfullyTrashed.count,
                             trashedWithoutLocation: reachedTrash - successfullyTrashed.count,
                             permanentlyDeleted: items.count - reachedTrash,
                             declined: result.declined,
                             refusedByGate: result.refused,
                             stoppedShort: result.stoppedShort)
    }
}

extension FileSyncManager {
    /// The undo action name for a batch moved to the Trash, as Edit ▸ Undo shows it: "Move to
    /// Trash", "Move 3 Items to Trash". The row menu's own words, so a recoverable move isn't
    /// called a delete.
    nonisolated static func trashUndoActionName(count: Int) -> String {
        count == 1 ? "Move to Trash" : "Move \(CountedNoun.phrase(count, "Item")) to Trash"
    }

    /// The banner after a delete gesture: “Moved “a.txt” to the Trash” or “Moved 3 items to the
    /// Trash”. "Deleted" only when something was permanently deleted (a confirmed delete on a
    /// Trash-less volume), since "moved to the Trash" would promise a way back that isn't there.
    nonisolated static func removalBannerText(count: Int, firstName: String, anyPermanent: Bool) -> String {
        if anyPermanent {
            return count == 1 ? "Deleted “\(firstName)”" : "Deleted \(count.formatted()) items"
        }
        return count == 1 ? "Moved “\(firstName)” to the Trash" : "Moved \(count.formatted()) items to the Trash"
    }
}
