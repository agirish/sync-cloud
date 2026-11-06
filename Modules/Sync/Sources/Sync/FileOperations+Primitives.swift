import Events
import Foundation

extension FileSyncManager {

    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError, Equatable {
        case identicalSourceAndDestination
        case nestingViolation
        /// Parent of destination exists as a file (e.g. cloud placeholder); sync the parent folder first.
        case parentExistsAsFile(parentName: String)
        /// The source pane's root path is empty: its provider vanished from settings while the pane
        /// still showed a stale tree. An empty root prefix-matches every node, so destinations
        /// would resolve against the process working directory.
        case sourceRootUnavailable
        /// The node's path is not inside the source pane's root (a stale tree after a pane swap
        /// or root edit). Grafting its absolute path under the destination would misdirect it.
        case itemOutsideSourceRoot(itemName: String)
        /// The destination root is empty or no longer on disk (provider unmounted or removed).
        /// Recreating it would land files in a dead local tree the provider never syncs.
        case destinationRootUnavailable
        /// The file at the source path is no longer the one a preview matched, so an automation
        /// apply won't move it. Not a failure: nothing is wrong with the disk, and the item is
        /// deliberately left where it is.
        case sourceChangedSincePreview
        /// The file at a To File card's path is no longer the one the scan found (replaced, edited
        /// or re-downloaded since). Left where it is; a rescan answers for it anew.
        case sourceChangedSinceScan
        /// A folder whose contents aren't on this Mac, and whose cloud app didn't hand them over in
        /// time (`DatalessFolderReads`). Worded so it doesn't send anyone to check permissions.
        case folderNotAnswered(folderName: String)
        /// The destination is a folder the source sits inside: replacing it would throw away the
        /// folder the item came from, and everything else in it.
        case destinationContainsSource
        /// The destination is a package (a `.numbers`, `.pages` or `.app`) or inside one.
        case destinationIsADocument(name: String)
        /// The item is locked in Finder (`uchg` or `uappnd`), so it can't be renamed or put in the
        /// Trash, which a move must do to the original.
        case itemIsLocked(name: String)
        /// A pane transfer's row sits above the folder its source opens at, at a level the other
        /// source has no place for (`PathBoundary.transferTarget`).
        case itemAboveOpeningFolder(itemName: String)
        /// The folder a pane opens at, carried onto the folder the other pane opens at, was answered
        /// with something other than Merge, or the target can't be merged with.
        case landingFolderMergesOnly(name: String)
        /// A move-by-copy landed its copy, couldn't put the original folder in the Trash, and its
        /// permanent removal stopped part-way. Both are kept: the copy is the only whole one.
        /// `replacedItemKeptAt` says where a Replace put the item it replaced; nil if none.
        case originalPartlyRemoved(name: String, replacedItemKeptAt: ReplacedItemPlace? = nil)

        /// Where a Replace kept the item it replaced.
        enum ReplacedItemPlace: Equatable, Sendable {
            case trash
            /// A volume with no Trash: the hidden backup beside the destination, by its name.
            /// Nothing sweeps it: `OrphanSweeper` takes only staging names, never `.rollback_`.
            case hiddenBesideDestination(name: String)
        }

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
                // Worded for both the card's suggestion and a folder from "Choose a folder…", so it
                // names what changed (the file), not who chose the folder.
                return "This file changed since the scan, so it is no longer the file that was being filed. It was left where it is; scan again to see where it goes now."
            case .folderNotAnswered(let folderName):
                return "“\(folderName)” couldn’t be read: its contents aren’t on this Mac, and the app that syncs it didn’t answer. Open that app and try again."
            case .destinationIsADocument(let name):
                return "“\(name)” is a document, not a folder, so nothing can be filed inside it. Choose another folder."
            case .destinationContainsSource:
                return "An item can’t replace the folder it’s inside — that would put the rest of the folder in the Trash. Choose Keep Both instead, or Merge for two folders."
            case .itemIsLocked(let name):
                return "“\(name)” is locked, so it can’t be moved or renamed. Unlock it in Finder (File ▸ Get Info) and try again."
            case .landingFolderMergesOnly(let name):
                return "“\(name)” is the folder this side opens at, so it can only be merged into the folder the other side opens at — replacing that, or keeping both, would put it over or beside everything that side shows. It was left where it is."
            case .itemAboveOpeningFolder(let itemName):
                return "“\(itemName)” is above the folder its source opens at, and the other source has no folder at that level to put it in. It was left where it is."
            case .originalPartlyRemoved(let name, let replaced):
                let text = "“\(name)” was copied, but its original couldn’t be put in the Trash and may have been only partly removed. The complete copy is at the destination; what is left of the original is still where it was."
                switch replaced {
                case nil: return text
                case .trash: return text + " The item it replaced is in the Trash."
                case .hiddenBesideDestination(let backup):
                    return text + " The item it replaced is kept beside it as the hidden “\(backup)”, which nothing removes."
                }
            }
        }
    }
    
    /// - Parameter merging: true for a Merge, which moves the source's children into the
    ///   destination and so may target the folder the source sits in (flattening `Photos/Photos`).
    ///   Only a whole-item install over that folder is refused.
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

        // A case-only rename ("foo" -> "Foo") is legitimate on a case-insensitive volume and must
        // not be rejected as identical. Comparing `src` and `dst` case-sensitively isn't enough:
        // `resolvingSymlinksInPath` is realpath, which spells each component the way the directory
        // does, so both names resolve to the existing one. Hence the explicit exemption, kept
        // narrow: same directory, last component differing only by case. A case-variant parent
        // (`/a/dir/f` vs `/a/DIR/f`) is one file and no rename.
        let isCaseOnlyRename = source.lastPathComponent != destination.lastPathComponent
            && isCaseOnlyRenaming(source: source, destination: destination,
                                  caseSensitiveVolume: caseSensitiveVolume)
        if src == dst, !isCaseOnlyRename {
            throw FileOperationError.identicalSourceAndDestination
        }

        // Nesting needs a different source path from the identity check. Identity follows the
        // link: an alias and its target are one item, and moving one onto the other would replace
        // the directory with a link to itself. Nesting asks "would a container go inside itself?",
        // and a symlink is not a container: moving `/a/alias` into the directory it points at
        // creates no cycle. So only the leaf is left unresolved (`entryResolvedPath`); an aliased
        // parent is still caught. For a non-link the two paths are the same.
        let nestingSrc = entryResolvedPath(for: source)
        // Trailing slash, so /a doesn't prefix-match /abc.
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

        // The mirror question: does the destination hold the source? Pasting `/T/Photos/Photos`
        // into `/T` targets `/T/Photos`, the source's own parent; a Replace would trash the outer
        // folder with everything else in it, beyond ⌘Z's reach. Finder refuses the same drop. Keep
        // Both picks a new name, and a Merge (`merging`) moves only the children.
        //
        // The destination entry is checked, not where it leads: replacing a link to the source's
        // ancestor removes only the link. Its parent is still resolved, as for the nesting check.
        let holding = entryResolvedPath(for: destination)
        let dstWithSlash = holding.hasSuffix("/") ? holding : holding + "/"
        let holdsSource = caseSensitiveVolume
            ? nestingSrc.hasPrefix(dstWithSlash)
            : nestingSrc.range(of: dstWithSlash, options: [.anchored, .caseInsensitive]) != nil
        if holdsSource && !merging {
            throw FileOperationError.destinationContainsSource
        }
    }

    /// Symlink-free path for `url`. `resolvingSymlinksInPath()` leaves the path unresolved when a
    /// trailing component doesn't exist, as a destination usually doesn't, so this resolves the
    /// deepest existing ancestor and re-appends the missing components.
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

    /// Symlink-free path for `url`'s parent, with the last component left exactly as spelled.
    ///
    /// An operation acts on the directory entry, not what it points at: `copyItem` and `moveItem`
    /// on `/a/link` copy or move the link. ``symlinkResolvedPath(for:)`` would hand back the
    /// target, so dropping a link inside the folder it points at would be refused as a
    /// `nestingViolation`. The parent is still resolved, so an aliased parent can't smuggle a
    /// directory into itself. For a non-link, leaving the leaf alone changes nothing.
    private nonisolated static func entryResolvedPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let leaf = standardized.lastPathComponent
        guard !leaf.isEmpty, leaf != "/" else { return symlinkResolvedPath(for: url) }
        let parentPath = symlinkResolvedPath(for: parent)
        // Join without doubling the separator. Under the root, `parent + "/" + leaf` would be
        // `//Users`, a prefix no resolved destination starts with, so `isNested` would let
        // `/Users` move into `/Users/anything`. Only `/` ends in a slash, so one `hasSuffix` does.
        return parentPath.hasSuffix("/") ? parentPath + leaf : parentPath + "/" + leaf
    }

    /// True when the volume containing `url` distinguishes names by case. False (the macOS
    /// default) when it can't be queried, as for a destination that doesn't exist yet; folding
    /// case is the safe default.
    public nonisolated static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// ``volumeSupportsCaseSensitiveNames(for:)`` for a destination that doesn't exist yet, such
    /// as every "missing on the other side" target of a bulk sync. `resourceValues` throws for a
    /// missing path, so this walks up to the nearest existing ancestor, which is on the same
    /// volume. If nothing up to "/" answers it returns `false` (fold): folding at worst renames
    /// needlessly, while wrongly claiming case sensitivity lets two parallel writers hit one file.
    public nonisolated static func volumeSupportsCaseSensitiveNamesForNewItem(at url: URL) -> Bool {
        caseSensitivityWalkingUp(from: url) { probe in
            (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
        }
    }

    /// The pure walk behind ``volumeSupportsCaseSensitiveNamesForNewItem(at:)``: asks `probe` about
    /// each ancestor until one answers, or reports `false`. Split out so it can be tested without a
    /// case-sensitive volume, where a real answer and the fallback would both be `false`.
    nonisolated static func caseSensitivityWalkingUp(from url: URL, probe: (URL) -> Bool?) -> Bool {
        var current = url
        while true {
            if let answer = probe(current) { return answer }
            let up = current.deletingLastPathComponent()
            if up.path == current.path { return false }
            current = up
        }
    }
    
    
    /// Finds a free name near `url` by appending " 2", " 3", … A name is taken when it exists on
    /// disk or is in `reserved`, which lets a bulk run that resolves every destination before its
    /// parallel copies avoid giving two items the same path.
    public nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManaging = FileManager.default, reserved: Set<String> = [], caseSensitiveVolume: Bool = true) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let extensionStr = url.pathExtension

        // On a case-insensitive destination, match the reserved set case-insensitively, as
        // `fileExists` already does on disk, or two case-variant items get one path and the second
        // overwrites the first. The default is exact, for case-sensitive volumes.
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

    /// True when `destinationURL` holds a distinct item that a copy or move must replace. A
    /// case-only rename on a case-insensitive volume finds its own source there, so it is excluded:
    /// backing it up would move the only copy aside. On a case-sensitive volume case variants are
    /// distinct items, so the exclusion doesn't apply.
    private nonisolated static func destinationExistsForReplacement(
        source: URL,
        destination: URL,
        caseSensitiveVolume: Bool,
        fileManager: FileManaging
    ) -> Bool {
        !isCaseOnlyRenaming(source: source, destination: destination, caseSensitiveVolume: caseSensitiveVolume)
            && fileManager.fileExists(atPath: destination.path)
    }

    /// Finalizes the `.rollback_<UUID>` backup the atomic replace left beside the destination and
    /// returns a restorable URL for the overwritten item, or nil when nothing was replaced. Prefers
    /// the Trash. **With no Trash (network shares), the backup stays where it is**: deleting it
    /// would make Replace destroy the old file outright. The dot name hides it from the panes; undo
    /// restores it, and an unused one is left behind, recoverable by hand.
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
            // The one line that lets a replaced file be found again. At .info so a normal trace
            // keeps it.
            Logger.shared.info("Replaced \(destinationURL.path) — previous version recoverable at \(recovered.path)")
        }
        return recovered
    }

    /// The name `url`'s item has on disk, byte for byte, or nil when nothing is there.
    ///
    /// Not `lastPathComponent`: APFS keeps a name in the Unicode form it was created in (NFC `é`,
    /// as iPhone apps and the keyboard make, or NFD `e` plus a combining accent) and finds it by
    /// either. Foundation's create, move and copy write the name decomposed, whatever form they
    /// are given; only the system calls write it as given. `getattrlist` reports it as stored.
    nonisolated static func nameOnDisk(of url: URL) -> String? {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                               commonattr: attrgroup_t(ATTR_CMN_NAME), volattr: 0, dirattr: 0,
                               fileattr: 0, forkattr: 0)
        // Length word, the reference, and the longest name: 255 UTF-16 units, 3 UTF-8 bytes each.
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<attrreference_t>.size + 768)
        let status = buffer.withUnsafeMutableBytes { raw in
            url.withUnsafeFileSystemRepresentation { path in
                path.map { getattrlist($0, &request, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) } ?? -1
            }
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> String? in
            let reference = raw.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let end = start + Int(reference.attr_length) - 1  // the length counts the NUL
            guard end > start, end <= raw.count else { return nil }
            return String(decoding: raw[start..<end], as: UTF8.self)
        }
    }

    /// Puts `itemURL` at `destinationURL` with the name `originalURL`'s item has on disk, when the
    /// destination's name is the same name in another Unicode form, as for every copy and move.
    /// Any other name lands as `moveItem` writes it.
    ///
    /// A copy keeps its original's name bytes, as Finder's does. Through `moveItem` an NFC
    /// "Café.pdf" would land as NFD, and Dropbox and iCloud upload the bytes they find. APFS's
    /// 255-unit limit also counts the form written, so a long name that fits NFC can overflow NFD
    /// (a Korean syllable is one unit NFC, up to three NFD). A typed name lands as Foundation
    /// writes it, as in Finder.
    ///
    /// Uses `rename(2)` with `RENAME_EXCL`, which writes the name as given and refuses an occupied
    /// destination. Any failure falls through to `moveItem`, so other volumes, races and error
    /// messages behave as before. Only for a `FileManager`: other `FileManaging` types keep their
    /// own `moveItem`, though a `FileManager` subclass overriding it is bypassed for such a name.
    nonisolated static func land(_ itemURL: URL, at destinationURL: URL, keepingNameOf originalURL: URL,
                                 fileManager: FileManaging) throws {
        if fileManager is FileManager,
           let name = nameOnDisk(of: originalURL),
           name == destinationURL.lastPathComponent,
           !name.utf8.elementsEqual(destinationURL.lastPathComponent.utf8) {
            let landing = (destinationURL.deletingLastPathComponent().path as NSString).appendingPathComponent(name)
            let renamed = itemURL.withUnsafeFileSystemRepresentation { from in
                from.map { renamex_np($0, landing, UInt32(RENAME_EXCL)) } ?? -1
            }
            if renamed == 0 { return }
        }
        try fileManager.moveItem(at: itemURL, to: destinationURL)
    }

    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    ///
    /// With an `observer`, the staging copy can be abandoned part-way: it throws
    /// `CocoaError(.userCancelled)` before anything reaches the destination, and the staging file
    /// is swept.
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

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume. Every copy
    /// comes through here (renames and filing call it directly), so this is where the file is
    /// noted for the cloud app status to watch its upload.
    @discardableResult
    nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver? = nil) throws -> URL? {
        let restorable = try copyItemCore(at: sourceURL, to: destinationURL, fileManager: fileManager,
                                          caseSensitiveVolume: caseSensitiveVolume, observer: observer)
        ChangedFileLedger.shared.note(destinationURL.path)
        return restorable
    }

    private nonisolated static func copyItemCore(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver?) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

        defer { removeStaging(tempURL, fileManager: fileManager) }

        let lock = try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            // Swap the staged copy in atomically, keeping the old destination as a sibling backup.
            // The destination is never absent, so a crash mid-replace can't leave nothing there; a
            // throw leaves it untouched. `installReplacement`, not `replaceItem`: the result keeps
            // the source's permissions and dates, not the old file's.
            let backupURL = try fileManager.installReplacement(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
            restoreLock(lock, on: destinationURL, fileManager: fileManager)
            return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
        }

        // A new destination (or a case-only rename onto the source itself): one rename into
        // place, no backup, no replacement window.
        try land(tempURL, at: destinationURL, keepingNameOf: sourceURL, fileManager: fileManager)
        restoreLock(lock, on: destinationURL, fileManager: fileManager)
        return nil
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    /// With an `observer`, only a cross-volume move's staging copy can be abandoned: a same-volume
    /// move is a rename, and once the copy has landed the move finishes, since the source cleanup
    /// must not stop half-way.
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
    /// `crossVolume`, when not given, from the two volumes on disk. Every move and rename comes
    /// through here and is noted as the copy core notes.
    @discardableResult
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver? = nil, crossVolume: Bool? = nil) throws -> URL? {
        let restorable = try moveItemCore(at: sourceURL, to: destinationURL, fileManager: fileManager,
                                          caseSensitiveVolume: caseSensitiveVolume, observer: observer,
                                          crossVolume: crossVolume)
        ChangedFileLedger.shared.note(destinationURL.path)
        return restorable
    }

    private nonisolated static func moveItemCore(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging, caseSensitiveVolume: Bool, observer: CopyObserver?, crossVolume: Bool?) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume)

        // Another volume is decided here, before `moveItem` is asked. Foundation's `moveItem`
        // across volumes doesn't throw EXDEV: it copies and unlinks the original itself, so Cancel
        // couldn't stop it and the original would skip the Trash. A cross-volume move takes the
        // staged path below instead (a copy into `.tmp_` that watches Cancel, a rename into place,
        // the original to the Trash).
        //
        // Only a real disk is asked: a test double's paths would be judged by what the real disk
        // holds there. A double is one volume unless its caller says otherwise.
        let crossVolume = crossVolume
            ?? (fileManager is FileManager && isCrossVolumeMove(from: sourceURL, to: destinationURL))

        // A locked original is refused before anything is written. A move must rename or trash
        // the original, and the kernel refuses both (EPERM) for an item locked in Finder (`uchg` or
        // `uappnd`); the copy fallback would land a copy it then can't clean up. The lock is the
        // user's, and this app never lifts it from their item.
        if isLocked(sourceURL, fileManager: fileManager) {
            throw FileOperationError.itemIsLocked(name: sourceURL.lastPathComponent)
        }

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, caseSensitiveVolume: caseSensitiveVolume, fileManager: fileManager) {
            return try replaceDestinationByMoving(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager, observer: observer, crossVolume: crossVolume)
        }

        // No existing destination (or a case-only rename onto the source itself): one plain
        // rename, nothing backed up.
        do {
            if crossVolume { throw POSIXError(.EXDEV) }
            try land(sourceURL, at: destinationURL, keepingNameOf: sourceURL, fileManager: fileManager)
        } catch {
            // Cross-volume (EXDEV) or a failed rename: stage into a temp beside the destination, so
            // on its volume, then rename into place, so no half-written file ever lands.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

            defer { removeStaging(tempURL, fileManager: fileManager) }

            // No lock to restore: a locked original is refused above. Entries inside keep their own
            // locks, as copied.
            try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer)
            try land(tempURL, at: destinationURL, keepingNameOf: sourceURL, fileManager: fileManager)

            // Clean up the source: Trash first, a direct remove if the volume has no Trash.
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                // **Spend the re-registration retry before destroying anything.** A transient
                // provider refusal blocks this trash as it blocks a delete, and the fallback below
                // is unrecoverable: the move would become a permanent deletion of the original.
                if !FileSyncManager.retriedSourceCleanupTrash(
                    sourceURL, after: error, fileManager: fileManager,
                    context: "Cross-volume move") {
                    // Read before the removal: a folder's can stop part-way.
                    let sourceIsFolder = entryKind(at: sourceURL, fileManager: fileManager) == .typeDirectory
                    do {
                        try fileManager.removeItem(at: sourceURL)
                        // The one branch of a move that removes something unrecoverably: the data
                        // is at the destination, but the original skipped the Trash, so log it.
                        Logger.shared.warning("Cross-volume move: the original at \(sourceURL.path) could not be moved to the Trash and was permanently deleted — its content is at \(destinationURL.path)")
                    } catch let cleanupError {
                        // **A folder's removal can stop part-way, so its copy is never removed
                        // then.** `removeItem` deletes what it can before throwing (a locked file
                        // inside is enough), so the copy is the only whole one. Both stay.
                        if sourceIsFolder {
                            Logger.shared.warning("Cross-volume move of \(sourceURL.path) failed at source cleanup, and the original may have been partly removed — the complete copy stays at \(destinationURL.path): \(cleanupError.localizedDescription)")
                            throw FileOperationError.originalPartlyRemoved(name: sourceURL.lastPathComponent)
                        }
                        // A file's removal is one unlink: it failed whole, the original is intact,
                        // and removing this operation's own copy is a clean revert.
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

    /// Replaces an existing destination with `sourceURL`'s contents atomically. Stages the source on
    /// the destination's volume (a same-volume rename consumes it; a cross-volume move copies it),
    /// then swaps it in with `installReplacement`, keeping the old destination as a recoverable
    /// backup. The destination is never absent, so a crash can't leave nothing there. A failed swap
    /// leaves the destination untouched, and a source already consumed by staging is put back.
    private nonisolated static func replaceDestinationByMoving(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManaging,
        observer: CopyObserver? = nil,
        crossVolume: Bool
    ) throws -> URL? {
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        // The staged temp is swept on every exit except one: when the replace and the move-back
        // both fail after the source was consumed, the temp holds the only copy of the source and
        // must survive. Sweeping it would destroy the source outright, bypassing the Trash.
        var tempHoldsOnlyCopyOfSource = false
        defer { if !tempHoldsOnlyCopyOfSource { removeStaging(tempURL, fileManager: fileManager) } }

        // Stage the source on the destination's volume. Same volume: a rename consumes it. Cross
        // volume (decided up front, since `moveItem` there copies and unlinks rather than throwing)
        // or a failed rename: copy, and remember the original still needs cleaning up.
        var sourceConsumed = true
        do {
            if crossVolume { throw POSIXError(.EXDEV) }
            try fileManager.moveItem(at: sourceURL, to: tempURL)
        } catch {
            // Unlocked, like the plain move's: no lock to restore.
            try stage(sourceURL, to: tempURL, fileManager: fileManager, observer: observer)
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
            // The replace failed with the destination intact, but a same-volume rename already put
            // the source in the temp, which `defer` deletes, so move it back: a failed replace must
            // never destroy the source. Named so the inner catch can't shadow the replace error.
            let replaceError = error
            if sourceConsumed {
                do {
                    try fileManager.moveItem(at: tempURL, to: sourceURL)
                } catch {
                    // The move-back failed too (a cloud daemon re-took the source path, or the temp
                    // is busy). The temp is now the only copy of the source: keep it, and say where
                    // it is in the alert, not only the log, since a bare "Move Failed" reads as
                    // "nothing changed". OrphanSweeper only Trashes it; nothing may unlink it.
                    tempHoldsOnlyCopyOfSource = true
                    let detail: String
                    if fileManager.fileExists(atPath: tempURL.path) {
                        // Reset the sweeper's age clock: `minimumAge` reads the mtime, which the
                        // staging rename kept from the original, so an old file's temp would be
                        // swept at once. Touching grants the full grace hour at the logged path. A
                        // failed touch (a busy temp) forfeits it, so the message mustn't promise it.
                        let touched = (try? fileManager.setAttributes(
                            [.modificationDate: Date()], ofItemAtPath: tempURL.path)) != nil
                        detail = touched
                            ? "The original could not be put back at its path; its content is preserved in the hidden file “\(tempURL.lastPathComponent)” next to the destination."
                            : "The original could not be put back at its path; its content is currently in the hidden file “\(tempURL.lastPathComponent)” next to the destination, which the periodic cleanup may soon move to the Trash — recover it from either place."
                    } else {
                        // replaceItem may move the staged item into the system's item-replacement
                        // directory before failing. Say so rather than point at an empty path.
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

        // Cross-volume: the source was copied, not consumed, so remove the original now the
        // destination holds its data. Trash first, then a permanent remove.
        if !sourceConsumed {
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                // The same retry as the cross-volume move above, spent before the unrecoverable
                // fallback.
                if !FileSyncManager.retriedSourceCleanupTrash(
                    sourceURL, after: error, fileManager: fileManager,
                    context: "Cross-volume replace") {
                    let sourceIsFolder = entryKind(at: sourceURL, fileManager: fileManager) == .typeDirectory
                    do {
                        try fileManager.removeItem(at: sourceURL)
                        // Unrecoverable, as in the plain cross-volume move, so it is logged too.
                        Logger.shared.warning("Cross-volume replace: the original at \(sourceURL.path) could not be moved to the Trash and was permanently deleted — its content is at \(destinationURL.path)")
                    } catch let cleanupError {
                        // A folder may be partly gone: reverting would put the old destination back
                        // over the only complete copy. The new content stays, the old destination
                        // goes to the Trash like any replaced item, and the error says so.
                        if sourceIsFolder {
                            let previous = finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
                            Logger.shared.warning("Cross-volume replace of \(destinationURL.path) failed at source cleanup, and the original at \(sourceURL.path) may have been partly removed — the complete copy stays at the destination\(previous.map { "; the item it replaced is at \($0.path)" } ?? ""): \(cleanupError.localizedDescription)")
                            // The alert says where the replaced item went: the Trash, or with no
                            // Trash, the hidden backup `finalizeBackup` left in place.
                            let kept: FileOperationError.ReplacedItemPlace? = previous.map {
                                $0 == backupURL ? .hiddenBesideDestination(name: $0.lastPathComponent) : .trash
                            }
                            throw FileOperationError.originalPartlyRemoved(name: sourceURL.lastPathComponent,
                                                                           replacedItemKeptAt: kept)
                        }
                        // Neither Trash nor remove worked, so the move can't complete. Revert the
                        // replace and fail, as the plain cross-volume path does, so no "moved" undo
                        // entry exists for a source still on disk.
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

    /// Atomically restores a just-replaced `destinationURL` to `backupURL`'s pre-replace content,
    /// then drops the fresh backup the restore makes, a copy of the source still on disk. For a
    /// replace whose cross-volume source cleanup failed; `installReplacement` keeps the
    /// destination present throughout.
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
            // The revert failed: the destination may hold the new content while the source is still
            // on disk. Log loudly; this is the one place a replace can leave the panes inconsistent
            // without an error reaching the caller.
            Logger.shared.error("Could not revert a partial replace at \(destinationURL.path) from backup \(backupURL.path); the destination may hold new content while the original source is still present")
            return
        }
        try? fileManager.removeItem(at: staleBackup)
    }
    
    /// True when `source` and `destination` sit on different volumes, so a move is a copy and a
    /// delete rather than a rename. Asked of each entry's parent (a link lives where its parent
    /// is, not where it points), walking up to the nearest existing folder. False when either side
    /// can't be asked: `moveItem` is tried first, and a failed rename still takes the staged path.
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

    /// The Finder lock a staged copy carried, lifted so it can be installed: `.immutable` and/or
    /// `.appendOnly` set to `true`; empty when the source wasn't locked.
    typealias StagedLock = [FileAttributeKey: Any]

    /// The one staging copy every primitive above makes: observed when there is an observer,
    /// plain `copyItem` when there isn't.
    ///
    /// A locked source's copy is unlocked in staging and locked again once installed. The copy
    /// carries the source's `uchg`/`uappnd`, and a locked `.tmp_` can't be renamed, replaced over
    /// the destination or removed, leaving a hidden full-size copy behind. Only the staged copy's
    /// flags are touched, never the source's; ``restoreLock(_:on:fileManager:)`` re-locks the
    /// installed item.
    @discardableResult
    private nonisolated static func stage(_ sourceURL: URL, to tempURL: URL, fileManager: FileManaging, observer: CopyObserver?) throws -> StagedLock {
        try requireContentsOnThisMac(sourceURL, fileManager: fileManager, observer: observer)
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

    /// A folder is copied only once every folder in it is on this Mac. Each dataless folder is
    /// asked of its cloud app through `DatalessFolderReads` (off the cooperative pool, within its
    /// deadline), and the first that doesn't answer is refused as `folderNotAnswered`.
    ///
    /// The copy's own walk lists every folder, and listing a dataless folder whose provider isn't
    /// running blocks forever, with no deadline and no Cancel. The copy runs on the serial
    /// operation queue, so every later copy, move and Trash in the app would queue behind it.
    ///
    /// Walked as `listing(of:)` walks: one enumeration kept out of dataless folders
    /// (`hasDirectoryPath` costs a file no `stat`), each dataless folder materialized by asking
    /// and then walked in turn. Links aren't followed (the copy copies the link). Cancel is heard
    /// per entry.
    nonisolated static func requireContentsOnThisMac(_ source: URL, fileManager: FileManaging, observer: CopyObserver?) throws {
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
                guard entry.hasDirectoryPath, fileManager.isDataless(at: entry) else { continue }
                entries.skipDescendants()
                try walk(entry)
            }
        }
        try walk(source)
    }

    /// Puts a staged copy's lock back on the item it became. A failure is logged, not thrown: the
    /// copy has landed, and being unlocked doesn't make it a failed copy.
    private nonisolated static func restoreLock(_ lock: StagedLock, on url: URL, fileManager: FileManaging) {
        guard !lock.isEmpty else { return }
        do {
            try fileManager.setAttributes(lock, ofItemAtPath: url.path)
        } catch {
            Logger.shared.warning("Copied \(url.path), but could not lock it again like its original: \(error.localizedDescription)")
        }
    }

    /// The Finder lock on the item at `url` itself, not a link's target (`attributesOfItem` reads
    /// the entry). Empty when it isn't locked or can't be read.
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

    /// Removes a `.tmp_` staging item on every exit, locked entries and all. A staged folder keeps
    /// the locks of the files inside it, so if the plain removal leaves anything, those locks are
    /// lifted and it is removed again. Only an exact `.tmp_<UUID>` name is ever unlocked, and a
    /// symbolic link inside is skipped, never followed: its target is somebody else's item.
    ///
    /// A staging item that still won't go is logged with its path, as left in place: it is a
    /// hidden full-size copy, and `OrphanSweeper` only Trashes, so with no Trash nothing takes it.
    nonisolated static func removeStaging(_ url: URL, fileManager: FileManaging) {
        guard (try? fileManager.removeItem(at: url)) == nil,
              fileManager.fileExists(atPath: url.path) else { return }
        guard OrphanSweeper.isTempArtifactName(url.lastPathComponent) else {
            Logger.shared.warning("Could not remove the staging item at \(url.path); it was left in place")
            return
        }
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
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Logger.shared.warning("Could not remove the staging item at \(url.path), even with its locks lifted — it is left in place: \(error.localizedDescription)")
        }
    }

    /// Ensures the parent of `destinationURL` is a usable directory: creates it, or throws if it
    /// exists as a file. Call before copying into a path like `.../Package.pages-tef/Previews`.
    ///
    /// With `sourceURL`, each folder made takes its counterpart's on-disk name bytes when the names
    /// match, so a rebuilt folder keeps its original's name as a copied file does
    /// (``land(_:at:keepingNameOf:fileManager:)``).
    public nonisolated static func ensureParentDirectoryExists(
        for destinationURL: URL,
        fileManager: FileManaging,
        mirroring sourceURL: URL? = nil
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw FileOperationError.parentExistsAsFile(parentName: parentURL.lastPathComponent)
            }
            return
        }
        if let sourceURL, fileManager is FileManager,
           createFolders(parentURL, keepingNamesAbove: sourceURL, fileManager: fileManager) {
            return
        }
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    /// Makes `folderURL`'s missing folders top-down with `mkdir(2)`, each named as the folder at the
    /// same depth above `sourceURL` is on disk when the names match. False, leaving the rest to
    /// `createDirectory` and its familiar errors, when no name would differ or any `mkdir` fails.
    private nonisolated static func createFolders(_ folderURL: URL, keepingNamesAbove sourceURL: URL,
                                                  fileManager: FileManaging) -> Bool {
        var missing: [(name: String, keptName: String?)] = []
        var folder = folderURL
        var counterpart = sourceURL.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: folder.path) {
            let name = folder.lastPathComponent
            let onDisk = nameOnDisk(of: counterpart)
            missing.append((name, onDisk.flatMap { $0 == name && !$0.utf8.elementsEqual(name.utf8) ? $0 : nil }))
            let up = folder.deletingLastPathComponent()
            if up.path == folder.path { return false }
            folder = up
            counterpart = counterpart.deletingLastPathComponent()
        }
        guard missing.contains(where: { $0.keptName != nil }) else { return false }
        var path = folder.path
        for step in missing.reversed() {
            path = (path as NSString).appendingPathComponent(step.keptName ?? step.name)
            guard mkdir(path, 0o777) == 0 else { return false }
        }
        return true
    }

    /// Performs only the file I/O for a single sync (create the parent folder, then copy or move).
    /// Bulk sync uses it to run operations in parallel without the serial queue per file.
    /// - Returns: The restorable URL of any replaced item, and the source and destination.
    ///   Throws on failure.
    public nonisolated static func performFileSyncIO(
        from sourceURL: URL,
        to destinationURL: URL,
        isMove: Bool,
        fileManager: FileManaging = FileManager.default,
        observer: CopyObserver? = nil
    ) throws -> (trashed: URL?, from: URL, to: URL) {
        try ensureParentDirectoryExists(for: destinationURL, fileManager: fileManager, mirroring: sourceURL)
        let trashed: URL?
        if isMove {
            trashed = try safeMoveItem(at: sourceURL, to: destinationURL, fileManager: fileManager, observer: observer)
        } else {
            trashed = try safeCopyItem(at: sourceURL, to: destinationURL, fileManager: fileManager, observer: observer)
        }
        return (trashed, sourceURL, destinationURL)
    }
    
    /// Only meaningful on case-insensitive volumes, where the case-variant destination is the
    /// source. On a case-sensitive volume "foo" and "Foo" are distinct files, so nothing is
    /// case-only there. Internal because the rename pass's never-overwrite guard
    /// (`applyRenamePlans(_:)`) runs before `safeMoveItem`, and both must ask this one question.
    nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL, caseSensitiveVolume: Bool) -> Bool {
        return !caseSensitiveVolume &&
               source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }
}
