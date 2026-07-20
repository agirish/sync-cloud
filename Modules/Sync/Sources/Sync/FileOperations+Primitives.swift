import Events
import Foundation

extension FileSyncManager {

    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError, Equatable {
        case identicalSourceAndDestination
        case nestingViolation
        /// Parent of destination exists as a file (e.g. cloud placeholder); sync the parent folder first.
        case parentExistsAsFile(parentName: String)
        /// The source pane's root path is empty — its provider vanished from settings while the
        /// pane still showed a stale tree. An empty root prefix-matches every node, so proceeding
        /// would resolve destinations against the process working directory.
        case sourceRootUnavailable
        /// The node's path is not inside the source pane's root (a stale tree after a pane swap
        /// or root edit). Grafting its absolute path under the destination would misdirect it.
        case itemOutsideSourceRoot(itemName: String)
        /// The destination root is empty or no longer on disk (provider unmounted or removed).
        /// Recreating it would land files in a dead local tree the provider never syncs.
        case destinationRootUnavailable

        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "The two paths are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            case .parentExistsAsFile(let parentName):
                return "A file named \"\(parentName)\" already exists on the destination. Sync the parent folder first (use Replace) to replace it with the package, then sync this item."
            case .sourceRootUnavailable:
                return "The source pane's folder is no longer available. Rescan before copying or moving items."
            case .itemOutsideSourceRoot(let itemName):
                return "\"\(itemName)\" is not inside the source pane's folder. Rescan and try again."
            case .destinationRootUnavailable:
                return "The destination folder is no longer available. Rescan before copying or moving items."
            }
        }
    }
    
    nonisolated static func validateFileOperation(source: URL, destination: URL) throws {
        try validateFileOperation(
            source: source,
            destination: destination,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: source)
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    nonisolated static func validateFileOperation(source: URL, destination: URL, caseSensitiveVolume: Bool) throws {
        // Resolve symlinks so an aliased destination path cannot smuggle a directory into itself.
        let src = symlinkResolvedPath(for: source)
        let dst = symlinkResolvedPath(for: destination)

        // Deliberately case-sensitive: a case-only rename ("foo" -> "Foo") is a legitimate
        // operation on case-insensitive volumes and must not be rejected as identical.
        if src == dst {
            throw FileOperationError.identicalSourceAndDestination
        }

        // Ensure trailing slash for prefix check to avoid /a matching /abc
        let srcWithSlash = src.hasSuffix("/") ? src : src + "/"
        let isNested: Bool
        if caseSensitiveVolume {
            isNested = dst.hasPrefix(srcWithSlash)
        } else {
            // APFS is case-insensitive by default: /a/Dir/child and /a/dir/child are the same
            // directory, so a case-variant path must not slip past the prefix check.
            isNested = dst.range(of: srcWithSlash, options: [.anchored, .caseInsensitive]) != nil
        }
        if isNested {
            throw FileOperationError.nestingViolation
        }
    }

    /// Symlink-free path for `url`. `resolvingSymlinksInPath()` alone returns the path
    /// unresolved whenever a trailing component does not exist (realpath fails), and a
    /// destination usually does not exist yet - so resolve the deepest existing ancestor and
    /// re-append the missing components.
    private nonisolated static func symlinkResolvedPath(for url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    /// True when the volume containing `url` distinguishes names by case. Falls back to false
    /// (the macOS default is case-insensitive) when the volume cannot be queried, e.g. for a
    /// destination that does not exist yet - the stricter comparison is the safe default.
    public nonisolated static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }
    
    
    /// Finds a free name near `url` by appending " 2", " 3", … A name counts as taken when it
    /// exists on disk OR is in `reserved` — the latter lets a bulk run that resolves every
    /// destination up front (before its parallel copy phase) avoid handing two items the same
    /// path when a keep-both suffix would otherwise collide with another item's real target.
    public nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManaging = FileManager.default, reserved: Set<String> = [], caseSensitiveVolume: Bool = true) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let extensionStr = url.pathExtension

        // On a case-insensitive destination, two reserved targets differing only by case name the
        // same file, so match the reserved set case-insensitively — `fileExists` already collapses
        // case on disk, but the in-memory reserved set would otherwise hand two case-variant items
        // the same path and let the second overwrite the first. (Default is exact, so a
        // case-sensitive volume keeps distinct case variants distinct.)
        let reservedForMatch = caseSensitiveVolume ? reserved : Set(reserved.map { $0.lowercased() })
        func isReserved(_ path: String) -> Bool {
            caseSensitiveVolume ? reserved.contains(path) : reservedForMatch.contains(path.lowercased())
        }

        var counter = 2
        var newURL = url

        while fileManager.fileExists(atPath: newURL.path) || isReserved(newURL.path) {
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

    /// True when `destinationURL` holds a distinct item that a copy/move must replace. A case-only
    /// rename ("foo" -> "Foo") on a case-insensitive volume reports its own source as the
    /// destination, so it is excluded: it is not a replacement, and backing it up would move the
    /// only copy of the data aside. On a case-sensitive volume there is no such aliasing —
    /// case-variant names are ordinary distinct items and the exclusion must not apply.
    private nonisolated static func destinationExistsForReplacement(
        source: URL,
        destination: URL,
        caseSensitiveVolume: Bool,
        fileManager: FileManaging
    ) -> Bool {
        !isCaseOnlyRenaming(source: source, destination: destination, caseSensitiveVolume: caseSensitiveVolume)
            && fileManager.fileExists(atPath: destination.path)
    }

    /// Finalizes the in-place `.rollback_<UUID>` backup that the atomic replace left beside the
    /// destination, returning a restorable URL for the overwritten item. Prefers the Trash so the
    /// backup shows up where users expect. When the volume has no Trash (network shares), KEEP the
    /// backup where it is: deleting it here would make Replace permanently destroy the old file the
    /// instant the operation succeeds. The dot-prefixed name hides it from the panes; undo restores
    /// it to its original location, and an unused backup is simply left behind once the undo stack
    /// drops — recoverable by hand beats silently destroyed. Returns nil when nothing was replaced.
    private nonisolated static func finalizeBackup(
        _ backupURL: URL?,
        replacing destinationURL: URL,
        fileManager: FileManaging
    ) -> URL? {
        guard let backupURL else { return nil }
        var trashedURL: NSURL? = nil
        let recovered: URL?
        if (try? fileManager.trashItem(at: backupURL, resultingItemURL: &trashedURL)) != nil {
            recovered = trashedURL as URL?
        } else {
            recovered = backupURL
        }
        if let recovered {
            // Recovery breadcrumb: the single line that lets a replaced file be found again after
            // an overwrite (or a bad sync). Logged at .info so it survives a normal-level trace.
            // Hopped to the MainActor logger, matching the other nonisolated logging in this file.
            Task { @MainActor in Logger.shared.info("Replaced \(destinationURL.path) — previous version recoverable at \(recovered.path)") }
        }
        return recovered
    }

    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    @discardableResult
    public nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try safeCopyItem(
            at: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: sourceURL)
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    @discardableResult
    nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

        defer { try? fileManager.removeItem(at: tempURL) }

        try fileManager.copyItem(at: sourceURL, to: tempURL)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            // Atomically swap the staged copy into place, preserving the old destination as a
            // sibling backup. The destination is never momentarily absent, so a crash or forced
            // quit mid-replace cannot strand the old file in Trash with nothing at the destination.
            // A throw here leaves the destination untouched (the primitive is atomic); the staged
            // temp is cleaned up by `defer`.
            let backupURL = try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
            return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
        }

        // Brand-new destination (or a case-only rename whose "destination" is the source itself on
        // a case-insensitive volume): a single rename into place, no backup, no replacement window.
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        return nil
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    @discardableResult
    public nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try safeMoveItem(
            at: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: sourceURL)
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    @discardableResult
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            return try replaceDestinationByMoving(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager)
        }

        // No existing destination (or a case-only rename whose "destination" is the source itself):
        // a plain single rename. Nothing is backed up, so there is no replacement window.
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for cross-volume moves (EXDEV) or other similar access issues. Stage into a
            // temp mathematically guaranteed to be on the destination's volume, then rename into
            // place — an atomic install that avoids corrupted half-files.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

            defer { try? fileManager.removeItem(at: tempURL) }

            try fileManager.copyItem(at: sourceURL, to: tempURL)
            try fileManager.moveItem(at: tempURL, to: destinationURL)

            // Cleanup source: try trash first, fall back to direct remove if the volume has no Trash.
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch let cleanupError {
                    // The move already landed, so the item at the destination is this operation's
                    // own copy - removing it is a clean revert when the source can't be cleaned up.
                    try? fileManager.removeItem(at: destinationURL)
                    throw cleanupError
                }
            }
        }
        return nil
    }

    /// Replaces an existing destination with `sourceURL`'s contents atomically. Stages the source
    /// onto the destination's volume (a same-volume rename consumes it; a cross-volume move copies
    /// it), then swaps it into place via `replaceItem`, preserving the old destination as a
    /// recoverable backup. Because the swap is atomic the destination is never momentarily absent —
    /// the crash window Finding 1 flagged. A failed swap leaves the destination untouched; if the
    /// same-volume staging had already consumed the source, it is restored so no data is lost.
    private nonisolated static func replaceDestinationByMoving(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManaging
    ) throws -> URL? {
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        // The staged temp is normally transient and swept on every exit. The ONE exception is
        // the double failure below (replace failed AND the restoring move-back failed with the
        // source already consumed): the temp then holds the only copy of the source's content
        // and must survive this scope — sweeping it would permanently destroy the source, not
        // even via the Trash.
        var tempHoldsOnlyCopyOfSource = false
        defer { if !tempHoldsOnlyCopyOfSource { try? fileManager.removeItem(at: tempURL) } }

        // Stage the source onto the destination's volume. Same-volume: a rename consumes the
        // source. Cross-volume (EXDEV): copy, and remember the original still needs cleanup.
        var sourceConsumed = true
        do {
            try fileManager.moveItem(at: sourceURL, to: tempURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: tempURL)
            sourceConsumed = false
        }

        let backupURL: URL?
        do {
            backupURL = try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
        } catch {
            // The atomic replace failed with the destination intact. But a same-volume rename has
            // already moved the source into the staged temp (which `defer` will delete), so restore
            // it — a failed replace must never destroy the source.
            // Named binding: the inner catch below shadows `error` with the move-back failure,
            // and both the rethrow and the enrichment must carry the REPLACE failure.
            let replaceError = error
            if sourceConsumed {
                do {
                    try fileManager.moveItem(at: tempURL, to: sourceURL)
                } catch {
                    // The move-back failed too (something re-took the source path — a cloud
                    // daemon re-materializing a placeholder does exactly this — or the temp is
                    // busy). The temp is now the only copy of the source's content: keep it,
                    // and say exactly where it is — in the ALERT the caller shows, not only the
                    // log, because a bare "Move Failed" reads as "nothing changed" while the
                    // source is in fact gone from its path. OrphanSweeper's later sweep only
                    // Trashes (recoverable); nothing may unlink it outright.
                    tempHoldsOnlyCopyOfSource = true
                    let detail: String
                    if fileManager.fileExists(atPath: tempURL.path) {
                        // Reset the sweeper's age clock: minimumAge reads the file's mtime, and
                        // the staging RENAME preserved the original's — a temp staged from any
                        // hour-old file was sweep-eligible on the very next refresh, making the
                        // "preserved at" pointer stale within minutes. Touching grants the full
                        // grace hour at the logged path (after which the sweep Trashes it,
                        // still recoverable).
                        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: tempURL.path)
                        detail = "The original could not be put back at its path; its content is preserved in the hidden file “\(tempURL.lastPathComponent)” next to the destination."
                    } else {
                        // replaceItem may consume the staged item into the system's
                        // item-replacement directory before failing — then the temp is gone
                        // from its staging path through no act of ours. Say so honestly
                        // instead of pointing at a path that holds nothing.
                        detail = "The original could not be put back at its path, and the staged copy is no longer at its staging location — macOS may have moved it to a temporary item-replacement folder."
                    }
                    Task { @MainActor in
                        Logger.shared.error("Replace of \(destinationURL.path) failed and the source could not be restored to \(sourceURL.path). \(detail)")
                    }
                    let ns = replaceError as NSError
                    throw NSError(domain: ns.domain, code: ns.code, userInfo: [
                        NSLocalizedDescriptionKey: "\(replaceError.localizedDescription) \(detail)",
                        NSUnderlyingErrorKey: replaceError,
                    ])
                }
            }
            throw replaceError
        }

        // Cross-volume: the source was copied, not consumed, so remove the original now that the
        // destination holds its data. Trash first; fall back to a permanent remove.
        if !sourceConsumed {
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch let cleanupError {
                    // Neither Trash nor remove worked, so this cross-volume move can't complete.
                    // Undo the replace and fail — matching the dest-absent cross-volume path, and
                    // avoiding a "moved" undo entry for a source still on disk.
                    if let backupURL {
                        revertReplace(destinationURL: destinationURL, from: backupURL, fileManager: fileManager)
                    }
                    throw cleanupError
                }
            }
        }

        return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
    }

    /// Atomically restores a just-replaced `destinationURL` to `backupURL`'s (pre-replace) content,
    /// then discards the redundant fresh backup the restore takes. Used to undo a replace whose
    /// cross-volume source-cleanup failed: the restore goes back through `replaceItem`, so the
    /// destination is never momentarily absent, and the fresh backup is a copy of that
    /// still-present source, so it can be dropped.
    private nonisolated static func revertReplace(
        destinationURL: URL,
        from backupURL: URL,
        fileManager: FileManaging
    ) {
        guard let staleBackup = try? fileManager.replaceItem(
            at: destinationURL,
            withItemAt: backupURL,
            backupItemName: ".rollback_\(UUID().uuidString)"
        ) else {
            // The revert itself failed: the destination may hold the new content while the source
            // is still on disk. Log loudly — this is the one spot where a replace can leave the
            // two panes inconsistent without surfacing an error to the caller.
            Task { @MainActor in Logger.shared.error("Could not revert a partial replace at \(destinationURL.path) from backup \(backupURL.path); the destination may hold new content while the original source is still present") }
            return
        }
        try? fileManager.removeItem(at: staleBackup)
    }
    
    /// Ensures the parent of `destinationURL` can be used as a directory (creates it or throws if it exists as a file).
    /// Call before copying into a path like `.../Package.pages-tef/Previews` so we don't fail with "file already exists".
    public nonisolated static func ensureParentDirectoryExists(
        for destinationURL: URL,
        fileManager: FileManaging
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw FileOperationError.parentExistsAsFile(parentName: parentURL.lastPathComponent)
            }
            return
        }
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    /// Performs only the file I/O for a single sync (create directory + copy or move).
    /// Used by bulk sync to run multiple operations in parallel without going through the serial queue per file.
    /// - Returns: On success, (nil, trashed, from, to). On failure, (error, nil, nil, nil).
    public nonisolated static func performFileSyncIO(
        from sourceURL: URL,
        to destinationURL: URL,
        isMove: Bool,
        fileManager: FileManaging = FileManager.default
    ) throws -> (trashed: URL?, from: URL, to: URL) {
        try ensureParentDirectoryExists(for: destinationURL, fileManager: fileManager)
        let trashed: URL?
        if isMove {
            trashed = try safeMoveItem(at: sourceURL, to: destinationURL, fileManager: fileManager)
        } else {
            trashed = try safeCopyItem(at: sourceURL, to: destinationURL, fileManager: fileManager)
        }
        return (trashed, sourceURL, destinationURL)
    }
    
    /// Only meaningful on case-insensitive volumes, where the case-variant destination IS the
    /// source. On a case-sensitive volume "foo" and "Foo" are distinct files, so no name change
    /// qualifies as case-only there.
    private nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL, caseSensitiveVolume: Bool) -> Bool {
        return !caseSensitiveVolume &&
               source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }
}
