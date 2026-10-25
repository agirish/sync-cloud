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
        /// The file at the source path is no longer the one a preview matched — an automation
        /// apply refusing to move a stranger. Distinct from a failure: nothing went wrong with the
        /// filesystem, and the item is deliberately left where it is.
        case sourceChangedSincePreview
        /// The file at a To File card's path is no longer the one the scan found there (FR45) —
        /// replaced, edited or re-downloaded since. Left where it is; a rescan answers for it anew.
        case sourceChangedSinceScan
        /// A folder whose contents are not on this Mac, and whose cloud app did not hand them over
        /// in time (`DatalessFolderReads`). Not a permission problem, and worded so it does not
        /// send anyone to look at the folder's permissions.
        case folderNotAnswered(folderName: String)
        /// The destination is a folder the source sits inside — replacing it would throw away the
        /// folder the item came from, and everything else in it.
        case destinationContainsSource
        /// The destination is a package — a `.numbers`, `.pages` or `.app` — or inside one.
        case destinationIsADocument(name: String)
        /// The item is locked in Finder (Get Info ▸ Locked) — `uchg` or `uappnd` — so it cannot be
        /// renamed or put in the Trash, which a move must do to the original (FR31).
        case itemIsLocked(name: String)
        /// A pane transfer's row sits above the folder its source opens at, at a level the other
        /// source has no place for (`PathBoundary.transferTarget`).
        case itemAboveOpeningFolder(itemName: String)
        /// A move-by-copy landed its copy, could not put the original folder in the Trash, and its
        /// permanent removal stopped part-way (P2). Both are kept: the copy is the only whole one.
        case originalPartlyRemoved(name: String)

        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "The two paths are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            case .parentExistsAsFile(let parentName):
                return "A file named “\(parentName)” already exists on the destination. Sync the parent folder first (use Replace) to replace it with the package, then sync this item."
            case .sourceRootUnavailable:
                return "The source pane’s folder is no longer available. Rescan before copying or moving items."
            case .itemOutsideSourceRoot(let itemName):
                return "“\(itemName)” is not inside the source pane’s folder. Rescan and try again."
            case .destinationRootUnavailable:
                return "The destination folder is no longer available. Rescan before copying or moving items."
            case .sourceChangedSincePreview:
                return "This file changed since the preview, so it is no longer the one that rule matched. Preview again to see what it would do now."
            case .sourceChangedSinceScan:
                // Worded for both ways a folder reaches the move — the card's suggestion and one the
                // user picked with "Choose a folder…" — so it names what changed, the file, and not
                // who chose the folder.
                return "This file changed since the scan, so it is no longer the file that was being filed. It was left where it is; scan again to see where it goes now."
            case .folderNotAnswered(let folderName):
                return "“\(folderName)” couldn’t be read: its contents aren’t on this Mac, and the app that syncs it didn’t answer. Open that app and try again."
            case .destinationIsADocument(let name):
                return "“\(name)” is a document, not a folder, so nothing can be filed inside it. Choose another folder."
            case .destinationContainsSource:
                return "An item can’t replace the folder it’s inside — that would put the rest of the folder in the Trash. Choose Keep Both instead, or Merge for two folders."
            case .itemIsLocked(let name):
                return "“\(name)” is locked, so it can’t be moved or renamed. Unlock it in Finder (File ▸ Get Info) and try again."
            case .itemAboveOpeningFolder(let itemName):
                return "“\(itemName)” is above the folder its source opens at, and the other source has no folder at that level to put it in. It was left where it is."
            case .originalPartlyRemoved(let name):
                return "“\(name)” was copied, but its original couldn’t be put in the Trash and may have been only partly removed. The complete copy is at the destination; what is left of the original is still where it was."
            }
        }
    }
    
    /// - Parameter merging: true for a Merge, which moves the source's CHILDREN into the
    ///   destination and so may target the folder the source sits in — flattening `Photos/Photos`
    ///   is exactly that, and it is safe. Only a whole-item install over that folder is refused.
    nonisolated static func validateFileOperation(source: URL, destination: URL, merging: Bool = false) throws {
        try validateFileOperation(
            source: source,
            destination: destination,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: source),
            merging: merging
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    nonisolated static func validateFileOperation(source: URL, destination: URL, caseSensitiveVolume: Bool,
                                                  merging: Bool = false) throws {
        // Resolve symlinks so an aliased destination path cannot smuggle a directory into itself.
        let src = symlinkResolvedPath(for: source)
        let dst = symlinkResolvedPath(for: destination)

        // A case-only rename ("foo" -> "Foo") is a legitimate operation on a case-insensitive
        // volume and must not be rejected as identical. Comparing `src` and `dst` case-sensitively
        // is NOT enough to keep that promise, which is what this used to rely on: the two strings
        // being compared have been through `symlinkResolvedPath`, and `resolvingSymlinksInPath` is
        // realpath — it hands every component back the way the DIRECTORY spells it. Measured on
        // APFS: `/t/07. jul 2016.pdf` and `/t/07. Jul 2016.pdf` both resolve to the lowercase one,
        // so every case-only rename on the default macOS volume threw
        // `identicalSourceAndDestination` before it reached the mover.
        //
        // It read as covered because the only tests that exercise it drive a case-SENSITIVE test
        // double, where the destination does not exist, `symlinkResolvedPath` walks up past it, and
        // realpath never folds anything.
        //
        // The exemption is deliberately narrow — the same directory, and a last component that
        // differs ONLY by case (so a genuinely identical path, where nothing differs, still
        // throws). A case-variant PARENT is not exempted: `/a/dir/f` and `/a/DIR/f` are one file
        // and no rename at all.
        let isCaseOnlyRename = source.lastPathComponent != destination.lastPathComponent
            && isCaseOnlyRenaming(source: source, destination: destination,
                                  caseSensitiveVolume: caseSensitiveVolume)
        if src == dst, !isCaseOnlyRename {
            throw FileOperationError.identicalSourceAndDestination
        }

        // **The nesting check asks a different question from the identity check above, and needs a
        // different source path.** Identity asks "are these the same item?", where following the
        // link is right: an alias and its target ARE one item, and moving the alias onto it would
        // replace the real directory with a link to itself. Nesting asks "would this put a
        // container inside itself?", and **a symlink is not a container** — moving `/a/alias` to
        // `/b/dir/sub`, inside the very directory it points at, relocates one directory entry and
        // creates no cycle. With the leaf resolved the source read as `/b/dir`, the destination sat
        // under it, and an ordinary move was refused as `nestingViolation`.
        //
        // Only the LAST component is treated differently; `entryResolvedPath` still resolves the
        // parent, so every aliased-parent case this guard was written for is untouched. For a
        // source that is not a link the two paths are identical, because realpath hands the same
        // name back.
        let nestingSrc = entryResolvedPath(for: source)
        // Ensure trailing slash for prefix check to avoid /a matching /abc
        let srcWithSlash = nestingSrc.hasSuffix("/") ? nestingSrc : nestingSrc + "/"
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

        // **The mirror question: does the destination HOLD the source?** Paste `/T/Photos/Photos`
        // into `/T` and the target is `/T/Photos`, the source's own parent. A Replace then swapped
        // the inner folder in and sent the outer one to the Trash with every other item it held,
        // and ⌘Z could not move it back (FR30); Finder refuses the same drop. Keep Both picks a new
        // name, and a Merge (`merging`) moves only the children — flattening is what it is for.
        let dstWithSlash = dst.hasSuffix("/") ? dst : dst + "/"
        let holdsSource = caseSensitiveVolume
            ? nestingSrc.hasPrefix(dstWithSlash)
            : nestingSrc.range(of: dstWithSlash, options: [.anchored, .caseInsensitive]) != nil
        if holdsSource && !merging {
            throw FileOperationError.destinationContainsSource
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

    /// Symlink-free path for `url`'s PARENT, with the last component left exactly as spelled.
    ///
    /// **An operation acts on the directory entry, not on what it points at.** Moving or copying
    /// `/a/link` moves the link; `copyItem` duplicates the link rather than the tree behind it, and
    /// `moveItem` relocates the entry. Resolving the leaf therefore validates the wrong thing:
    /// ``symlinkResolvedPath(for:)`` hands back the TARGET, so `/a/link` → `/b/dir` is checked as
    /// though the user had asked to move `/b/dir` itself.
    ///
    /// What that costs is a refusal of a legal operation. `isNested` asks whether the destination
    /// sits under the source, and a link is not a container — dropping `/a/link` inside `/b/dir`,
    /// the very directory it points at, is ordinary and creates no cycle, but with the leaf
    /// resolved the source reads as `/b/dir` and the destination is inside it, so it throws
    /// `nestingViolation`. The `src == dst` comparison folds the same way: the link and its target
    /// compare equal and the move reads as `identicalSourceAndDestination`.
    ///
    /// The parent is still resolved, which is what the guard is actually for: an *aliased* parent
    /// can still smuggle a directory into itself, and that check is untouched. Only the last
    /// component is left alone — and for anything that is not a link, leaving it alone changes
    /// nothing, because realpath would have handed the same name back.
    ///
    /// Same principle as the delete path's `attributesOfItem` probe: the link is a thing in its own
    /// right, and asking about its target answers a different question.
    private nonisolated static func entryResolvedPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let leaf = standardized.lastPathComponent
        guard !leaf.isEmpty, leaf != "/" else { return symlinkResolvedPath(for: url) }
        let parentPath = symlinkResolvedPath(for: parent)
        // **Join without doubling the separator.** A source directly under the volume root has
        // `/` as its parent, and a bare `parent + "/" + leaf` spelled it `//Users` — which the
        // caller then turns into the prefix `//Users/`, and no resolved destination path ever
        // starts with that. So `isNested` came back false for exactly the operations it exists to
        // refuse: moving `/Users` into `/Users/anything` would have been allowed through, a
        // directory into itself. Only the root has a trailing slash to collide with, which is why
        // one `hasSuffix` covers it.
        return parentPath.hasSuffix("/") ? parentPath + leaf : parentPath + "/" + leaf
    }

    /// True when the volume containing `url` distinguishes names by case. Falls back to false
    /// (the macOS default is case-insensitive) when the volume cannot be queried, e.g. for a
    /// destination that does not exist yet - the stricter comparison is the safe default.
    public nonisolated static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// ``volumeSupportsCaseSensitiveNames(for:)`` for a destination that does not exist YET.
    ///
    /// `resourceValues` throws for a path with nothing on disk, so asking about a file about to be
    /// created always produced the fallback — never the volume's real answer. That is the exact
    /// shape a bulk sync asks about: every "missing on the other side" target is by definition
    /// absent, so a genuinely case-sensitive destination was still told to fold case, and two items
    /// differing only by case had one of them needlessly renamed to "name 2".
    ///
    /// Volume semantics do not change within a subtree, so walking up to the nearest EXISTING
    /// ancestor answers for the volume the path will land on. This mirrors the same walk the undo
    /// path already performs for vanished restore targets. When nothing up to "/" can answer, the
    /// result stays `false` (fold), which is the safe direction here: folding at worst uniquifies a
    /// name unnecessarily, while wrongly claiming case sensitivity lets two parallel writers target
    /// one file.
    public nonisolated static func volumeSupportsCaseSensitiveNamesForNewItem(at url: URL) -> Bool {
        caseSensitivityWalkingUp(from: url) { probe in
            (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
        }
    }

    /// The pure walk behind ``volumeSupportsCaseSensitiveNamesForNewItem(at:)``: asks `probe` about
    /// each ancestor in turn until one answers, and reports `false` if none does. Split out so the
    /// walk is testable without a case-sensitive volume to run on — on the ordinary case-INsensitive
    /// developer machine, "walked up and got the real answer" and "gave up and returned the
    /// fallback" are the same `false`, and a test could not tell the fix from the bug.
    nonisolated static func caseSensitivityWalkingUp(from url: URL, probe: (URL) -> Bool?) -> Bool {
        var current = url
        while true {
            if let answer = probe(current) { return answer }
            let up = current.deletingLastPathComponent()
            if up.path == current.path { return false }
            current = up
        }
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
            Logger.shared.info("Replaced \(destinationURL.path) — previous version recoverable at \(recovered.path)")
        }
        return recovered
    }

    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    ///
    /// With an `observer`, the staging copy can be abandoned part-way (RD24): it throws
    /// `CocoaError(.userCancelled)` before anything reaches the destination, and the `defer` below
    /// sweeps whatever the staging file held.
    @discardableResult
    public nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default, observer: CopyObserver? = nil) throws -> URL? {
        try safeCopyItem(
            at: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: sourceURL),
            observer: observer
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    @discardableResult
    nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver? = nil) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

        defer { removeStaging(tempURL, fileManager: fileManager) }

        let lock = try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            // Atomically swap the staged copy into place, preserving the old destination as a
            // sibling backup. The destination is never momentarily absent, so a crash or forced
            // quit mid-replace cannot strand the old file in Trash with nothing at the destination.
            // A throw here leaves the destination untouched (the primitive is atomic); the staged
            // temp is cleaned up by `defer`. `installReplacement`, not `replaceItem`: the result is
            // the source's copy with the source's permissions and dates (FR32), not the old file's.
            let backupURL = try fileManager.installReplacement(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
            restoreLock(lock, on: destinationURL, fileManager: fileManager)
            return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
        }

        // Brand-new destination (or a case-only rename whose "destination" is the source itself on
        // a case-insensitive volume): a single rename into place, no backup, no replacement window.
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        restoreLock(lock, on: destinationURL, fileManager: fileManager)
        return nil
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    /// With an `observer`, only a cross-volume move's staging copy is abandonable — a same-volume
    /// move is a rename, and a cancel that arrives after the copy has landed lets the move finish,
    /// because the source cleanup that follows is not something to stop half-way.
    @discardableResult
    public nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default, observer: CopyObserver? = nil) throws -> URL? {
        try safeMoveItem(
            at: sourceURL,
            to: destinationURL,
            fileManager: fileManager,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: sourceURL),
            observer: observer
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume, and
    /// `crossVolume` — when it is not given — from the two volumes on disk (FR33).
    @discardableResult
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver? = nil, crossVolume: Bool? = nil) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        // **Another volume is decided here, before `moveItem` is asked** (FR33). The staged path
        // below — a copy into `.tmp_` that watches Cancel, a rename into place, the original to the
        // Trash — used to run only when `moveItem` THREW, on the belief that a cross-volume move
        // throws EXDEV. Foundation's does not: measured, `moveItem` from the Data volume onto a
        // disk image succeeded, copying the item and unlinking the original itself. So every move
        // to an external disk or another volume skipped all three: Cancel could not stop it, and
        // the original was deleted outright rather than put in the Trash. The tests never saw it
        // because their doubles throw EXDEV on cue.
        let crossVolume = crossVolume ?? isCrossVolumeMove(from: sourceURL, to: destinationURL)

        // **A locked original is refused before anything is written** (FR31). A move has to rename
        // the original or put it in the Trash, and the kernel refuses both for an item locked in
        // Finder (`uchg`, or `uappnd`) — measured: `rename`, `moveItem`, `trashItem` and `removeItem`
        // all EPERM. Without this the failed rename took the copy fallback, which landed a copy and
        // then could not clear the original, so it reverted — or, with the copy locked too, left
        // both. The lock is the user's, and this app never lifts it from their item.
        if isLocked(sourceURL, fileManager: fileManager) {
            throw FileOperationError.itemIsLocked(name: sourceURL.lastPathComponent)
        }

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            return try replaceDestinationByMoving(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager, observer: observer, crossVolume: crossVolume)
        }

        // No existing destination (or a case-only rename whose "destination" is the source itself):
        // a plain single rename. Nothing is backed up, so there is no replacement window.
        do {
            if crossVolume { throw POSIXError(.EXDEV) }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for cross-volume moves (EXDEV) or other similar access issues. Stage into a
            // temp mathematically guaranteed to be on the destination's volume, then rename into
            // place — an atomic install that avoids corrupted half-files.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

            defer { removeStaging(tempURL, fileManager: fileManager) }

            // No lock to restore (P7): a locked original is refused above, and a locked entry
            // inside one by the staging itself, so a move's staged copy never carries one.
            try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer,
                      refusingLockedEntries: true)
            try fileManager.moveItem(at: tempURL, to: destinationURL)

            // Cleanup source: try trash first, fall back to direct remove if the volume has no Trash.
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                // **Spend the re-registration retry before destroying anything.** The transient
                // provider refusal measured on 2026-08-30 blocks this trash exactly as it blocks
                // a delete — and unlike a delete, the fallback below is unrecoverable, so under
                // that refusal a move would quietly become a permanent deletion of the original.
                if !FileSyncManager.retriedSourceCleanupTrash(
                    sourceURL, after: error, fileManager: fileManager,
                    context: "Cross-volume move") {
                    // Read before the removal: a folder's can stop part-way (P2).
                    let sourceIsFolder = entryKind(at: sourceURL, fileManager: fileManager) == .typeDirectory
                    do {
                        try fileManager.removeItem(at: sourceURL)
                        // The one branch of a move that removes something unrecoverably. The data
                        // survives at the destination, but the original is gone without a Trash stop,
                        // so the log must say so — the delete path's equivalent already does.
                        Logger.shared.warning("Cross-volume move: the original at \(sourceURL.path) could not be moved to the Trash and was permanently deleted — its content is at \(destinationURL.path)")
                    } catch let cleanupError {
                        // **A folder's removal can stop part-way, so its copy is never removed then**
                        // (P2). `removeItem` deletes what it can before it throws — a locked file
                        // inside is enough — and removing the copy after that deleted the only
                        // complete one. Both stay, and the error says so.
                        if sourceIsFolder {
                            Logger.shared.warning("Cross-volume move of \(sourceURL.path) failed at source cleanup, and the original may have been partly removed — the complete copy stays at \(destinationURL.path): \(cleanupError.localizedDescription)")
                            throw FileOperationError.originalPartlyRemoved(name: sourceURL.lastPathComponent)
                        }
                        // A file's removal is one unlink: it failed whole, the original is intact,
                        // and the item at the destination is this operation's own copy - removing it
                        // is a clean revert.
                        let reverted = (try? fileManager.removeItem(at: destinationURL)) != nil
                        Logger.shared.warning(reverted
                            ? "Cross-volume move of \(sourceURL.path) failed at source cleanup — the copy at \(destinationURL.path) was removed to revert it"
                            : "Cross-volume move of \(sourceURL.path) failed at source cleanup, and the copy at \(destinationURL.path) could not be removed — both copies remain")
                        throw cleanupError
                    }
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
        fileManager: FileManaging,
        observer: CopyObserver? = nil,
        crossVolume: Bool
    ) throws -> URL? {
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        // The staged temp is normally transient and swept on every exit. The ONE exception is
        // the double failure below (replace failed AND the restoring move-back failed with the
        // source already consumed): the temp then holds the only copy of the source's content
        // and must survive this scope — sweeping it would permanently destroy the source, not
        // even via the Trash.
        var tempHoldsOnlyCopyOfSource = false
        defer { if !tempHoldsOnlyCopyOfSource { removeStaging(tempURL, fileManager: fileManager) } }

        // Stage the source onto the destination's volume. Same-volume: a rename consumes the
        // source. Cross-volume — decided up front (FR33), because `moveItem` onto another volume
        // copies and unlinks by itself rather than throwing — or a rename that failed: copy, and
        // remember the original still needs cleanup.
        var sourceConsumed = true
        do {
            if crossVolume { throw POSIXError(.EXDEV) }
            try fileManager.moveItem(at: sourceURL, to: tempURL)
        } catch {
            // Unlocked, like the plain move's: no lock comes back to restore (P7).
            try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer,
                      refusingLockedEntries: true)
            sourceConsumed = false
        }

        let backupURL: URL?
        do {
            backupURL = try fileManager.installReplacement(
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
                        // still recoverable). A FAILED touch (busy temp — one of the very
                        // causes of this branch) forfeits that grace, so the message must not
                        // promise it.
                        let touched = (try? fileManager.setAttributes(
                            [.modificationDate: Date()], ofItemAtPath: tempURL.path)) != nil
                        detail = touched
                            ? "The original could not be put back at its path; its content is preserved in the hidden file “\(tempURL.lastPathComponent)” next to the destination."
                            : "The original could not be put back at its path; its content is currently in the hidden file “\(tempURL.lastPathComponent)” next to the destination, which the periodic cleanup may soon move to the Trash — recover it from either place."
                    } else {
                        // replaceItem may consume the staged item into the system's
                        // item-replacement directory before failing — then the temp is gone
                        // from its staging path through no act of ours. Say so honestly
                        // instead of pointing at a path that holds nothing.
                        detail = "The original could not be put back at its path, and the staged copy is no longer at its staging location — macOS may have moved it to a temporary item-replacement folder."
                    }
                    Logger.shared.error("Replace of \(destinationURL.path) failed and the source could not be restored to \(sourceURL.path). \(detail)")
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
                // Same retry, same reason, as the cross-volume move above: the fallback below is
                // the unrecoverable one, so the re-registration attempt is spent first.
                if !FileSyncManager.retriedSourceCleanupTrash(
                    sourceURL, after: error, fileManager: fileManager,
                    context: "Cross-volume replace") {
                    let sourceIsFolder = entryKind(at: sourceURL, fileManager: fileManager) == .typeDirectory
                    do {
                        try fileManager.removeItem(at: sourceURL)
                        // Same unrecoverable removal as the plain cross-volume move above, and the
                        // same obligation to say so.
                        Logger.shared.warning("Cross-volume replace: the original at \(sourceURL.path) could not be moved to the Trash and was permanently deleted — its content is at \(destinationURL.path)")
                    } catch let cleanupError {
                        // A folder may be partly gone (P2): reverting would put the old destination
                        // back over the only complete copy, and drop that copy with the fresh
                        // backup. The new content stays, the old destination goes to the Trash
                        // like any replaced item, and the error says what happened.
                        if sourceIsFolder {
                            let previous = finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
                            Logger.shared.warning("Cross-volume replace of \(destinationURL.path) failed at source cleanup, and the original at \(sourceURL.path) may have been partly removed — the complete copy stays at the destination\(previous.map { "; the item it replaced is at \($0.path)" } ?? ""): \(cleanupError.localizedDescription)")
                            throw FileOperationError.originalPartlyRemoved(name: sourceURL.lastPathComponent)
                        }
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
        guard let staleBackup = try? fileManager.installReplacement(
            at: destinationURL,
            withItemAt: backupURL,
            backupItemName: ".rollback_\(UUID().uuidString)"
        ) else {
            // The revert itself failed: the destination may hold the new content while the source
            // is still on disk. Log loudly — this is the one spot where a replace can leave the
            // two panes inconsistent without surfacing an error to the caller.
            Logger.shared.error("Could not revert a partial replace at \(destinationURL.path) from backup \(backupURL.path); the destination may hold new content while the original source is still present")
            return
        }
        try? fileManager.removeItem(at: staleBackup)
    }
    
    /// True when `source` and `destination` sit on different volumes, so a move between them is a
    /// copy and a delete rather than a rename (FR33). Asked of each entry's PARENT — a move
    /// relocates a directory entry, and a symbolic link lives where its parent is, not where it
    /// points — walking up to the nearest folder that exists, as the destination's may not yet.
    /// When either side cannot be asked it answers false: `moveItem` is then tried first, as it
    /// always was, and a rename that fails still takes the staged path.
    nonisolated static func isCrossVolumeMove(from source: URL, to destination: URL) -> Bool {
        guard let from = volumeIdentifier(near: source.deletingLastPathComponent()),
              let to = volumeIdentifier(near: destination.deletingLastPathComponent()) else { return false }
        return !from.isEqual(to)
    }

    private nonisolated static func volumeIdentifier(near url: URL) -> NSObjectProtocol? {
        var current = url.standardizedFileURL
        while true {
            if let id = (try? current.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier {
                return id
            }
            let up = current.deletingLastPathComponent()
            if up.path == current.path { return nil }
            current = up
        }
    }

    /// The Finder lock a staged copy was carrying, lifted so it can be installed — `.immutable`
    /// and/or `.appendOnly` set to `true`; empty when the source was not locked.
    typealias StagedLock = [FileAttributeKey: Any]

    /// The one staging copy every primitive above makes: observed when there is an observer,
    /// `copyItem` exactly as before when there is not.
    ///
    /// **A locked source's copy is unlocked in staging, and locked again once installed** (FR31).
    /// `copyItem` and `copyfile` both carry the source's `uchg`/`uappnd` onto the copy, and a locked
    /// `.tmp_` can be neither renamed into place nor replaced over the destination nor removed —
    /// measured: `moveItem`, `removeItem` and `trashItem` EPERM, `replaceItemAt` EACCES. So a locked
    /// file could never be copied, and every attempt left a hidden full-size copy that nothing could
    /// clear. Only the STAGED copy's own flags are touched — never the source's — and the lock goes
    /// back on the installed item (``restoreLock(_:on:fileManager:)``), so the copy is locked like
    /// its original.
    ///
    /// `refusingLockedEntries` is a move's (P2): its original must be removed once the copy lands,
    /// and a locked entry inside a folder cannot be — on a volume with no Trash, the removal stops
    /// part-way. So a locked entry anywhere in the tree refuses the move before anything is copied.
    @discardableResult
    private nonisolated static func stage(_ sourceURL: URL, to tempURL: URL, fileManager: FileManaging, observer: CopyObserver?,
                                          refusingLockedEntries: Bool = false) throws -> StagedLock {
        try requireContentsOnThisMac(sourceURL, fileManager: fileManager, observer: observer,
                                     refusingLockedEntries: refusingLockedEntries)
        if let observer {
            try fileManager.copyItem(at: sourceURL, to: tempURL, observer: observer)
        } else {
            try fileManager.copyItem(at: sourceURL, to: tempURL)
        }
        let lock = lockAttributes(of: tempURL, fileManager: fileManager)
        if !lock.isEmpty {
            try? fileManager.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: tempURL.path)
        }
        return lock
    }

    /// **A folder is copied only once every folder in it is on this Mac** (FR34) — asked of its
    /// cloud app through `DatalessFolderReads`, off the cooperative pool and for at most their
    /// deadline, and refused as `folderNotAnswered` at the first folder that does not answer.
    ///
    /// The copy's recursive walk (`copyfile`, or `copyItem`) lists every folder it reaches, and
    /// listing a dataless folder whose provider is not running blocks for good — measured on the
    /// OneDrive `.Trash` folders `DatalessFolderReads` describes. It has no deadline, and Cancel is
    /// only heard in the copy's callbacks, which never fire while a listing blocks; the copy runs on
    /// the serial operation queue, so every later copy, move and Trash in the app queued behind it.
    ///
    /// Walked the way `listing(of:)` walks: one recursive enumeration that is not let into a
    /// dataless folder — `hasDirectoryPath` is the enumerator's own word, so a file costs no `stat`
    /// and a folder one — with each dataless folder asked for first, which materializes it, and
    /// then walked in turn. A folder that answers is on disk for the copy that follows. A link is
    /// not followed (the copy copies the link); a file needs nothing. Cancel is heard per entry.
    nonisolated static func requireContentsOnThisMac(_ source: URL, fileManager: FileManaging, observer: CopyObserver?,
                                                     refusingLockedEntries: Bool = false) throws {
        guard entryKind(at: source, fileManager: fileManager) == .typeDirectory else { return }
        func walk(_ folder: URL) throws {
            if fileManager.isDataless(at: folder),
               fileManager.datalessFolderReads.readBlocking(folder.path, { fileManager.listingForARead(of: folder).outcome }) == nil {
                throw FileOperationError.folderNotAnswered(folderName: folder.lastPathComponent)
            }
            guard let entries = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [],
                                                       errorHandler: { _, _ in true }) else { return }
            for case let entry as URL in entries {
                if let observer, !observer.shouldContinue() {
                    throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: source.path])
                }
                if refusingLockedEntries, isLocked(entry, fileManager: fileManager) {
                    throw FileOperationError.itemIsLocked(name: entry.lastPathComponent)
                }
                guard entry.hasDirectoryPath, fileManager.isDataless(at: entry) else { continue }
                entries.skipDescendants()
                try walk(entry)
            }
        }
        try walk(source)
    }

    /// Puts a staged copy's lock back on the item it became. A failure is logged and not thrown:
    /// the copy has landed, and an unlocked copy of a locked file is not a reason to call it failed.
    private nonisolated static func restoreLock(_ lock: StagedLock, on url: URL, fileManager: FileManaging) {
        guard !lock.isEmpty else { return }
        do {
            try fileManager.setAttributes(lock, ofItemAtPath: url.path)
        } catch {
            Logger.shared.warning("Copied \(url.path), but could not lock it again like its original: \(error.localizedDescription)")
        }
    }

    /// The Finder lock on the item at `url` itself — not a link's target, as `attributesOfItem`
    /// reads the entry. Empty when it is not locked or cannot be read.
    private nonisolated static func lockAttributes(of url: URL, fileManager: FileManaging) -> StagedLock {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return [:] }
        var lock: StagedLock = [:]
        if (attributes[.immutable] as? Bool) == true { lock[.immutable] = true }
        if (attributes[.appendOnly] as? Bool) == true { lock[.appendOnly] = true }
        return lock
    }

    nonisolated static func isLocked(_ url: URL, fileManager: FileManaging) -> Bool {
        !lockAttributes(of: url, fileManager: fileManager).isEmpty
    }

    /// Removes a `.tmp_` staging item on every exit, locked entries and all (FR31). A folder's copy
    /// keeps the locks of the files inside it — they install locked, as their originals are — so a
    /// staged folder abandoned at Cancel or by a failed install could not be removed, and stayed
    /// beside the destination at full size. When the plain removal leaves anything behind, the
    /// locks INSIDE the staging item are lifted and it is removed again. Only an exact `.tmp_<UUID>`
    /// name is ever unlocked, and a symbolic link inside it is skipped, never followed: its target
    /// is somebody else's item.
    nonisolated static func removeStaging(_ url: URL, fileManager: FileManaging) {
        guard (try? fileManager.removeItem(at: url)) == nil,
              fileManager.fileExists(atPath: url.path),
              OrphanSweeper.isTempArtifactName(url.lastPathComponent) else { return }
        var entries = [url]
        if let walk = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil) {
            for case let entry as URL in walk { entries.append(entry) }
        }
        for entry in entries {
            guard let attributes = try? fileManager.attributesOfItem(atPath: entry.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  (attributes[.immutable] as? Bool) == true || (attributes[.appendOnly] as? Bool) == true
            else { continue }
            try? fileManager.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: entry.path)
        }
        try? fileManager.removeItem(at: url)
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
        fileManager: FileManaging = FileManager.default,
        observer: CopyObserver? = nil
    ) throws -> (trashed: URL?, from: URL, to: URL) {
        try ensureParentDirectoryExists(for: destinationURL, fileManager: fileManager)
        let trashed: URL?
        if isMove {
            trashed = try safeMoveItem(at: sourceURL, to: destinationURL, fileManager: fileManager, observer: observer)
        } else {
            trashed = try safeCopyItem(at: sourceURL, to: destinationURL, fileManager: fileManager, observer: observer)
        }
        return (trashed, sourceURL, destinationURL)
    }
    
    /// Only meaningful on case-insensitive volumes, where the case-variant destination IS the
    /// source. On a case-sensitive volume "foo" and "Foo" are distinct files, so no name change
    /// qualifies as case-only there.
    /// Internal rather than private since round 6: the rename pass's own never-overwrite guard sits
    /// ABOVE `safeMoveItem` and pre-empts it, so the two must ask this one question rather than each
    /// spell an answer. A second copy is how they came to disagree — see
    /// `applyRenamePlans(_:)`.
    nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL, caseSensitiveVolume: Bool) -> Bool {
        return !caseSensitiveVolume &&
               source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }
}
