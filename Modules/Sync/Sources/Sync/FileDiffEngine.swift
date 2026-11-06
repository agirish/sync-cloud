import Foundation
import Events

/// Stateless engine that computes sync differences between two directory trees (left and right
/// panes): the disk walk and the date/size comparison. `FileSyncManager` runs it off the main actor.
public struct FileDiffEngine {

    /// Per-file metadata used when comparing the two sides (path, date, size, isDirectory).
    public struct FileInfo: Sendable {
        /// The absolute URL of the file.
        public let url: URL
        /// The modification date on the disk.
        public let modificationDate: Date?
        /// The size of the file in bytes.
        public let fileSize: Int?
        /// True if the item is a directory.
        public let isDirectory: Bool
        /// True for a directory whose contents could not be listed (permission denied, I/O
        /// error): what's inside is unknown, not empty. The diff must not mint "Missing" rows for
        /// the other side's contents, or accepting one would copy into a folder nobody can read.
        /// Mirrors `FileNode.isUnexplored` so the warm (tree) and cold (disk walk) scans agree.
        public let isUnexplored: Bool
        /// True when `url` is itself a symbolic link. The fields above describe its target, which
        /// is what the comparison compares, but a copy writes the link, so a row copying from it is
        /// held back (`FileDifference.HeldBack`). Mirrors `FileNode.isSymbolicLink`; a folder the
        /// walk substitutes for a link (iCloud Drive's `Desktop`, `Documents`) is not one.
        public let isSymbolicLink: Bool

        public init(url: URL, modificationDate: Date?, fileSize: Int?, isDirectory: Bool,
                    isUnexplored: Bool = false, isSymbolicLink: Bool = false) {
            self.url = url
            self.modificationDate = modificationDate
            self.fileSize = fileSize
            self.isDirectory = isDirectory
            self.isUnexplored = isUnexplored
            self.isSymbolicLink = isSymbolicLink
        }
    }

    /// The suggested direction and note for a folder on one side against a file on the other.
    ///
    /// The dates can't say which side is newer: a folder's date moves only when an entry directly
    /// inside is added, removed or renamed, so a package edited yesterday can look older than a
    /// file. So the row is held out of bulk runs (`FileDifference.HeldBack.folderVersusFile`) and
    /// its note leaves the choice to the user. The suggested direction (later date, folder on a tie)
    /// only aims a single deliberate copy, which trashes the other side's item and so is recoverable.
    /// The note names providers, not sides, so a pane swap needs no rewrite of it.
    private static func resolveTypeMismatch(
        left: FileInfo,
        leftProvider: CloudProvider,
        right: FileInfo,
        rightProvider: CloudProvider,
        dateToleranceSeconds: TimeInterval
    ) -> (action: FileDifference.SyncAction, description: String) {
        let leftDate = left.modificationDate ?? Date.distantPast
        let rightDate = right.modificationDate ?? Date.distantPast
        let action: FileDifference.SyncAction
        if abs(leftDate.timeIntervalSince(rightDate)) > dateToleranceSeconds {
            action = leftDate > rightDate ? .copyToRight : .copyToLeft
        } else {
            action = left.isDirectory ? .copyToRight : .copyToLeft
        }
        let (folderIn, fileIn) = left.isDirectory
            ? (leftProvider.displayName, rightProvider.displayName)
            : (rightProvider.displayName, leftProvider.displayName)
        return (action, "Folder in \(folderIn), file in \(fileIn) — a folder’s date is not when its contents changed; choose which to keep")
    }

    /// The note on a both-files row whose sizes differ with no newer side: what the dates say, and
    /// that the choice is the user's. Providers, not sides, as in `resolveTypeMismatch`.
    private static func sizesDifferWithoutANewerSide(
        leftDate: Date?, rightDate: Date?,
        left: CloudProvider, right: CloudProvider,
        dateToleranceSeconds: TimeInterval
    ) -> String {
        let choose = " — choose which to keep"
        switch (leftDate, rightDate) {
        case (.some, .some):
            guard dateToleranceSeconds > 0 else { return "Sizes differ but the dates are the same" + choose }
            let seconds = dateToleranceSeconds == dateToleranceSeconds.rounded()
                ? String(Int(dateToleranceSeconds)) : String(dateToleranceSeconds)
            return "Sizes differ but the dates match within the \(seconds) s tolerance" + choose
        case (nil, nil):
            return "Sizes differ and neither file has a date" + choose
        case (nil, .some):
            return "Sizes differ and the \(left.displayName) file has no date" + choose
        case (.some, nil):
            return "Sizes differ and the \(right.displayName) file has no date" + choose
        }
    }

    /// `held` for a row that copies from `source`: a link there outranks every other reason, since
    /// even a single deliberate copy can't get it right.
    private static func held(_ reason: FileDifference.HeldBack?, source: FileInfo) -> FileDifference.HeldBack? {
        source.isSymbolicLink ? .sourceIsSymbolicLink : reason
    }

    /// `description` with the link note added when the row copies from a link (see
    /// `FileDifference.HeldBack.sourceIsSymbolicLink`). Side-neutral, so a pane swap leaves it.
    private static func noted(_ description: String, source: FileInfo) -> String {
        source.isSymbolicLink
            ? description + " — it is a link, so a copy would be a link too, not what it points to"
            : description
    }
    
    /// Builds the same relative-path→`FileInfo` map `getFilesInDirectory` produces by walking the
    /// disk, but from an already-built deep `FileNode` tree, so the scan can skip the re-walk when
    /// both panes' trees are current.
    ///
    /// A key is the path of names from the base down to the node, never the node's id with the
    /// base stripped off, matching the disk walk's key. Ids stop continuing their parent's in two
    /// cases: the walk lists a folder linked in from outside as its target
    /// (`FileSyncManager.buildTree`; iCloud Drive's `Desktop` and `Documents`), and
    /// `contentsOfDirectory(at:)` returns symlink-resolved URLs below a folder reached through a
    /// link. Stripped ids would then key off real paths, the warm scan would disagree with the cold
    /// one, and at Home a row could copy the other side's folder through the link onto `~/Documents`.
    ///
    /// A node marked `FileNode.isCoveredElsewhere` is keyed like any other: the disk walk lists it
    /// in both places too. Each name is the last component of the node's id, not `name`, which is
    /// left bridged on purpose (`FileSyncManager.nativePath`) and would pay the bridge per node.
    /// `basePath` only recognizes the base itself, which `buildTree` returns alone when it could not
    /// be listed.
    public static func filesInfo(fromTree nodes: [FileNode], basePath: String) -> [String: FileInfo] {
        var result: [String: FileInfo] = [:]

        func add(_ node: FileNode, key: String) {
            result[key] = FileInfo(
                // `isDirectory:` keeps this initializer from asking the file system what `node`
                // already says: one lookup per node, ~40k per pane. Consumers read `.path`, which
                // is the same either way, even for a link to a directory.
                url: URL(fileURLWithPath: node.id, isDirectory: node.isDirectory),
                modificationDate: node.modificationDate,
                fileSize: node.fileSize,
                isDirectory: node.isDirectory,
                // The walk's "couldn't look inside" marker: `computeDifferences` must not read the
                // absent children as missing.
                isUnexplored: node.isDirectory && node.isUnexplored == true,
                // So a warm scan holds back the same link rows a cold one does. A substituted
                // folder's node is real and says false.
                isSymbolicLink: node.isSymbolicLink == true
            )
            guard let children = node.children, !children.isEmpty else { return }
            // Once per directory, not per child.
            let prefix = key + "/"
            for child in children {
                var childKey = prefix
                childKey.append(contentsOf: TreeShape.leaf(of: child.id))
                add(child, key: childKey)
            }
        }

        for node in nodes {
            guard node.id == basePath else {
                add(node, key: String(TreeShape.leaf(of: node.id)))
                continue
            }
            // `buildTree` returns the root alone, unexplored, when its listing failed, so this
            // side's whole view is unknown. Recorded under the root key "", which
            // `computeDifferences` reads to suppress whole-side Missing rows, as on the cold branch.
            if node.isDirectory, node.isUnexplored == true {
                result[""] = FileInfo(
                    url: URL(fileURLWithPath: node.id, isDirectory: true),
                    modificationDate: node.modificationDate,
                    fileSize: node.fileSize,
                    isDirectory: true,
                    isUnexplored: true
                )
            }
            for child in node.children ?? [] {
                add(child, key: String(TreeShape.leaf(of: child.id)))
            }
        }
        return result
    }

    /// Recursively scans a directory into a map of `FileInfo` keyed by relative path. Uses resource
    /// values on the real disk and attributes for test doubles.
    ///
    /// `maxEntries` bounds the scan's cold path: when both sides aren't already in
    /// `prefetchedTrees` (capped by `FileSyncManager.paneNodeBudget`), the comparison walks here,
    /// and an unbounded walk of a large Home folder can run for minutes.
    ///
    /// Truncation is recorded as the root being unexplored, under the `""` key an unlistable root
    /// also uses, so `computeDifferences` mints no Missing row against this side and a partial scan
    /// can't offer to copy what the walk didn't reach. Rows both sides saw, and Missing rows against
    /// the other side, are unaffected. The warm branch suppresses per directory instead; this flat
    /// walk stops in enumeration order, so what it missed is scattered and only whole-side is
    /// honest. A cold scan of a truncated pair thus shows no Missing rows where a warm one shows
    /// some; both banner as partial (`PartialComparison.of`).
    ///
    /// - Parameters:
    ///   - url: The root directory URL to scan.
    ///   - fileManager: The file manager to use for scanning (supports injected mocks).
    ///   - maxEntries: Stop after recording this many entries, marking the root unexplored. `nil`
    ///     is unbounded, as every caller outside the comparison scan is.
    /// - Returns: A map of relative paths to `FileInfo` metadata.
    public static func getFilesInDirectory(_ url: URL, fileManager: FileManaging = FileManager.default,
                                           maxEntries: Int? = nil) throws -> [String: FileInfo] {
        try getFilesInDirectory(url, fileManager: fileManager, maxEntries: maxEntries, datalessReads: .shared)
    }

    /// - Parameter datalessReads: where a folder whose contents are not on this Mac is read (see
    ///   `FileSyncManager.DatalessFolderReads`). The comparison passes its manager's; everything else
    ///   takes the app's shared one through the overload above.
    static func getFilesInDirectory(_ url: URL, fileManager: FileManaging = FileManager.default,
                                    maxEntries: Int? = nil,
                                    datalessReads: FileSyncManager.DatalessFolderReads) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let keySet = Set(keys)

        var result: [String: FileInfo] = [:]
        // Unreadable entries are logged once after the walk: a denied or placeholder-heavy subtree
        // can fail for tens of thousands of entries, and per-entry logging costs a main-actor task
        // and a disk write each.
        var unreadableCount = 0
        var unreadableSamples: [String] = []
        let maxIndividuallyLogged = 3
        // Relative keys of directories the enumerator could not descend into. Their entries are
        // re-marked `isUnexplored` after the walk, so their contents read as unknown, not empty,
        // and the other side's files don't show as Missing rows.
        var unreadableDirKeys = Set<String>()
        /// Set when `maxEntries` stopped the walk; see the note on this function.
        var truncated = false

        /// Stable identity of the directory a URL refers to through symlinks, for the descent's
        /// cycle guard (the tree walk's `directoryIdentity`). The raw-path fallback fires only for
        /// test doubles, which have no links, and for stat failures.
        func canonicalIdentity(_ dirURL: URL) -> String {
            // Resolve the link first: `canonicalPathKey` doesn't resolve a leaf symlink, and an
            // unresolved leaf looks distinct from its target, defeating the cycle guard.
            let resolved = dirURL.resolvingSymlinksInPath()
            if fileManager is FileManager,
               let canonical = try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                return canonical
            }
            return resolved.standardizedFileURL.path
        }

        // Symlinked-directory targets on the current branch, by canonical identity: the root plus
        // every link descended on the way here. Per branch, not global, like the tree walk's
        // `branchVisited`: two sibling links to one directory must each expand, or the cold scan
        // would report the second one's contents missing. It still breaks A→B→A cycles.
        let symlinkDepthCap = 64   // mirrors TreeBuilder.hardDepthCap, bounding pathological symlink fan-out

        func walk(_ rootURL: URL, prefix: String, branchVisited: Set<String>) throws {
            // A folder whose contents are not on this Mac is read through `DatalessFolderReads`,
            // off the cooperative pool with a deadline. An answer means it is on disk now; none
            // means unknown, recorded as an unreadable folder so nothing under it reads as missing
            // (the root, `prefix` "", marks the whole side). Otherwise this costs one `stat`.
            if fileManager.isDataless(at: rootURL),
               datalessReads.readBlocking(rootURL.path, { fileManager.listingForARead(of: rootURL).outcome }) == nil {
                unreadableDirKeys.insert(prefix)
                return
            }
            var basePath = rootURL.path
            if fileManager is FileManager {
                // The real enumerator yields canonical URLs (/private/var/...), so a root given via
                // a link (/var/...) would miss the prefix trim below and keys would come back
                // near-absolute. Not `resolvingSymlinksInPath`, which strips /private. Test doubles
                // echo their URLs back, so they keep the raw base.
                if let canonicalPath = try? rootURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                    basePath = canonicalPath
                }
            }
            // After the canonicalisation above, so it describes the base actually used.
            let baseGraphemeCount = basePath.count

            // Fires when the enumerator can't descend into a directory or read an entry. Without
            // it the subtree is skipped silently, so record the failure and remember the directory
            // to re-mark it unexplored. Returning true keeps walking: one locked folder must not
            // abort the scan.
            let recordUnreadable: (URL, Error) -> Bool = { failedURL, error in
                // A link to a directory is not unreadable. The enumerator fails on it with
                // ENOTDIR, but the descent below walks its target. Recorded, it would be re-marked
                // unexplored and hide every Missing row beneath it (iCloud Drive's `Desktop` and
                // `Documents` are such links).
                if fileManager is FileManager,
                   (try? failedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                   (try? failedURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    return true
                }
                unreadableCount += 1
                if unreadableSamples.count < maxIndividuallyLogged {
                    unreadableSamples.append("Error enumerating \(failedURL): \(error)")
                }
                var rel = failedURL.path
                if rel.hasPrefix(basePath) { rel = String(rel.dropFirst(basePath.count)) }
                // By scalar, as the entry keys below are, so a re-mark finds its entry.
                if rel.unicodeScalars.first == "/" { rel.unicodeScalars.removeFirst() }
                // An empty `rel` means the failed directory is this walk's root: the scan root
                // (key "") or a linked directory on a manual descent (key `prefix`). Dropped, the
                // whole side would read as empty and everything on the other side as Missing.
                unreadableDirKeys.insert(rel.isEmpty ? prefix : (prefix.isEmpty ? rel : prefix + "/" + rel))
                return true
            }
            guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: recordUnreadable) else {
                return
            }

            for case let fileURL as URL in enumerator {
                // A superseded scan's results are discarded, so stop instead of holding the
                // scanning slot for a walk nobody will read.
                try Task.checkCancellation()
                // Checked before the entry is statted, since the stat is the cost. The one stop for
                // nested walks too: whichever level runs out, each enclosing level hits this test
                // on its next entry. The `!truncated` guard on the link descent below is redundant.
                if let maxEntries, result.count >= maxEntries {
                    truncated = true
                    return
                }
                do {
                    var isReg = true
                    var modDate: Date? = nil
                    var size: Int? = nil
                    var isDir = false
                    var isSymlinkedDir = false
                    var isLink = false

                    if let _ = fileManager as? FileManager {
                        let resourceValues = try fileURL.resourceValues(forKeys: keySet)
                        if resourceValues.isSymbolicLink == true {
                            isLink = true
                            // As the tree walk does (`buildNode`): a link compares by its target's
                            // type, size and date, and a broken link is dropped.
                            guard let target = try? fileURL.resolvingSymlinksInPath().resourceValues(forKeys: keySet) else {
                                continue
                            }
                            isReg = target.isRegularFile ?? false
                            isDir = target.isDirectory ?? false
                            modDate = target.contentModificationDate
                            size = target.fileSize
                            isSymlinkedDir = isDir
                        } else {
                            isReg = resourceValues.isRegularFile ?? true
                            modDate = resourceValues.contentModificationDate
                            size = resourceValues.fileSize
                            isDir = resourceValues.isDirectory ?? false
                        }
                    } else {
                        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
                        let fileType = attrs[FileAttributeKey.type] as? FileAttributeType
                        isReg = (fileType == FileAttributeType.typeRegular)
                        isDir = (fileType == FileAttributeType.typeDirectory)
                        modDate = attrs[FileAttributeKey.modificationDate] as? Date
                        if let s = attrs[FileAttributeKey.size] as? NSNumber {
                            size = s.intValue
                        } else if let s = attrs[FileAttributeKey.size] as? Int {
                            size = s
                        }
                    }

                    if isReg || isDir {
                        var relativePath = fileURL.path
                        if relativePath.hasPrefix(basePath) {
                            // Hoisted: `basePath.count` walks graphemes.
                            relativePath = String(relativePath.dropFirst(baseGraphemeCount))
                        }
                        // The slash goes by scalar: a name opening with a combining mark joins the
                        // `/` into one Character, so `hasPrefix("/")` would miss it and the key would
                        // keep its slash where the warm branch's has none.
                        if relativePath.unicodeScalars.first == "/" {
                            relativePath.unicodeScalars.removeFirst()
                        }

                        if relativePath.isEmpty { continue }
                        let keyPath = prefix.isEmpty ? relativePath : prefix + "/" + relativePath

                        result[keyPath] = FileInfo(
                            url: fileURL,
                            modificationDate: modDate,
                            fileSize: size,
                            isDirectory: isDir,
                            isSymbolicLink: isLink
                        )

                        // The enumerator must not enter a dataless folder: it lists it on its next
                        // call, and a provider that isn't running never answers, so the whole scan
                        // would wait. `walk` takes it instead, asking through the dataless reads.
                        if isDir, !isSymlinkedDir, fileManager.isDataless(at: fileURL) {
                            enumerator.skipDescendants()
                            try walk(fileURL, prefix: keyPath, branchVisited: branchVisited)
                        }

                        // The enumerator never enters a linked directory but the tree walk does,
                        // so descend by hand (cycle-guarded, via the target). Otherwise the cold scan
                        // reports the contents missing and a bulk accept re-copies over the target.
                        if isSymlinkedDir {
                            let targetID = canonicalIdentity(fileURL)
                            let depth = keyPath.split(separator: "/").count
                            // `branchVisited` holds only the root and manually descended targets,
                            // not the real directories between, so a link to an ancestor
                            // (a/b/link -> a) would expand an extra level. Refuse a target that is
                            // the link's own directory or above it, as `buildTree` does.
                            let hostID = canonicalIdentity(fileURL.deletingLastPathComponent())
                            let pointsIntoAncestor = hostID == targetID || hostID.hasPrefix(targetID + "/")
                            if !branchVisited.contains(targetID) && !pointsIntoAncestor && depth < symlinkDepthCap
                                && !truncated {
                                try walk(fileURL.resolvingSymlinksInPath(), prefix: keyPath,
                                         branchVisited: branchVisited.union([targetID]))
                            }
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unreadableCount += 1
                    if unreadableSamples.count < maxIndividuallyLogged {
                        unreadableSamples.append("Scan: could not read \(fileURL.path) (\(error.localizedDescription)) — omitted from the comparison")
                    }
                }
            }
        }

        // A root that is a link to a folder is walked where it leads. The enumerator lists nothing
        // at a link (ENOTDIR), and `recordUnreadable` forgives links, so the side would read as
        // empty and everything on the other side as missing.
        var walkRoot = url
        if fileManager is FileManager,
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            let target = url.resolvingSymlinksInPath()
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walkRoot = target
            }
        }
        try walk(walkRoot, prefix: "", branchVisited: [canonicalIdentity(walkRoot)])

        // Re-mark the directories whose descent failed: their entry was added while listing the
        // (readable) parent, but what's inside is unknown, not absent.
        for key in unreadableDirKeys {
            if let info = result[key], info.isDirectory, !info.isUnexplored {
                result[key] = FileInfo(url: info.url, modificationDate: info.modificationDate,
                                       fileSize: info.fileSize, isDirectory: true, isUnexplored: true,
                                       isSymbolicLink: info.isSymbolicLink)
            }
        }
        // An unreadable root has no parent listing to mint its entry, so it gets a synthetic one
        // under the root key "". `computeDifferences` reads it to suppress the whole side's
        // Missing rows.
        if unreadableDirKeys.contains(""), result[""] == nil {
            result[""] = FileInfo(url: url, modificationDate: nil, fileSize: nil,
                                  isDirectory: true, isUnexplored: true)
        }
        // A stopped walk makes the same claim as an unlistable root, so it mints the same record,
        // unless an unreadable root already did.
        if truncated, result[""] == nil {
            // Counted before the synthetic root record is added, or the log would say `limit + 1`.
            let counted = result.count
            result[""] = FileInfo(url: url, modificationDate: nil, fileSize: nil,
                                  isDirectory: true, isUnexplored: true)
            let limit = maxEntries ?? 0
            let root = url.path
            Logger.shared.warning("Scan: stopped reading “\(root)” after \(counted) entries (limit \(limit)) — the comparison covers what was read and reports nothing on this side as missing")
        }

        if unreadableCount > 0 {
            let count = unreadableCount
            let samples = unreadableSamples
            let root = url.path
            // A per-entry read failure omits that item from the comparison (an unreadable
            // directory is marked unexplored instead). Environmental, not the app's fault, so a
            // warning, as the tree builder's "could not list …" is (FileSyncManager+Scanning).
            if count <= maxIndividuallyLogged {
                for message in samples { Logger.shared.warning(message) }
            } else {
                Logger.shared.warning("Scan: \(count) entries unreadable under \(root); first: \(samples.joined(separator: " | "))")
            }
        }

        return result
    }
    
    /// Computes all sync differences between the left and right file sets (missing items, date/size mismatches).
    /// - Parameters:
    ///   - left: Cloud provider for the left pane (used for display names in descriptions).
    ///   - leftURL: Root directory URL for the left pane.
    ///   - right: Cloud provider for the right pane.
    ///   - rightURL: Root directory URL for the right pane.
    ///   - leftFilesInfo: Pre-scanned file metadata for the left pane (relative path → `FileInfo`).
    ///   - rightFilesInfo: Pre-scanned file metadata for the right pane.
    ///   - caseInsensitive: True when both pane volumes are case-insensitive (the macOS default).
    ///     Paths differing only by case then compare as one pair, not two "missing" rows whose sync
    ///     would overwrite one side. Keep it false if either volume is case-sensitive: that side
    ///     can hold both variants, and collapsing them would hide a real file.
    ///   - dateToleranceSeconds: Modification dates within this many seconds compare as equal,
    ///     since providers round or rewrite dates on upload. 0 means exact.
    /// - Returns: Sorted array of `FileDifference` for UI and sync actions.
    public static func computeDifferences(
        left: CloudProvider,
        leftURL: URL,
        right: CloudProvider,
        rightURL: URL,
        leftFilesInfo: [String: FileInfo],
        rightFilesInfo: [String: FileInfo],
        caseInsensitive: Bool = false,
        dateToleranceSeconds: TimeInterval = 1
    ) -> [FileDifference] {
        var diffs: [FileDifference] = []
        // An unexplored root record (key "", from either branch) means the scan root couldn't be
        // listed: that side's whole view is unknown, so no Missing row may be minted against it.
        // Popped either way so the root key never takes part in the passes.
        var leftFilesInfo = leftFilesInfo
        var rightFilesInfo = rightFilesInfo
        let leftRootUnreadable = leftFilesInfo.removeValue(forKey: "")?.isUnexplored == true
        let rightRootUnreadable = rightFilesInfo.removeValue(forKey: "")?.isUnexplored == true
        // Directories whose contents couldn't be listed on one side (`FileInfo.isUnexplored`).
        // An item under one on the other side is not missing here, so rows under these are
        // suppressed in both passes, rather than offering to copy into an unreadable folder.
        let unexploredLeftDirs = Set(leftFilesInfo.compactMap { key, info in
            info.isDirectory && info.isUnexplored ? key : nil
        })
        let unexploredRightDirs = Set(rightFilesInfo.compactMap { key, info in
            info.isDirectory && info.isUnexplored ? key : nil
        })
        // Folders that exist on one side only, per direction. Their descendants collapse into the
        // folder's row, since a folder copy is recursive.
        var missingOnRightDirs = Set<String>()
        var missingOnLeftDirs = Set<String>()
        // Entries present on one side only, per direction. Their rows wait for the collapse
        // (step 3): a pass can meet a folder after its contents.
        var missingOnRight: [(key: String, info: FileInfo)] = []
        var missingOnLeft: [(key: String, info: FileInfo)] = []
        // Folders that pair with a file on the other side. Their descendants collapse into the
        // mismatch row, since either resolution handles the whole subtree. Keyed by the dir side's
        // path, mapping to the row's `relativePath` (the left key); the two can differ by case or
        // invisibly when the pair matched as a variant.
        var typeMismatchDirs: [String: String] = [:]

        // Lowercased right key → actual right key, for the case-insensitive fallback. Full paths,
        // so children of case-variant folders ("Docs/a.txt", "docs/a.txt") pair too.
        var caseFoldedRightKeys: [String: String] = [:]
        if caseInsensitive {
            caseFoldedRightKeys.reserveCapacity(rightFilesInfo.count)
            for key in rightFilesInfo.keys {
                caseFoldedRightKeys[key.lowercased()] = key
            }
        }
        // Right keys consumed by a case-variant match in pass 1; pass 2 must not report them missing.
        var caseVariantMatchedRightKeys = Set<String>()

        // Right keys by near-name form (`ProviderNameRules.nearNameKey`), to pair names that
        // differ only invisibly. A form claimed by several keys on either side is ambiguous, and
        // matching it would depend on dictionary order, so those fall back to plain missing rows.
        var nearNameRightKeys: [String: String] = [:]
        var ambiguousNearNameRightKeys = Set<String>()
        nearNameRightKeys.reserveCapacity(rightFilesInfo.count)
        for key in rightFilesInfo.keys {
            let nearKey = ProviderNameRules.nearNameKey(forRelativePath: key, foldCase: caseInsensitive)
            if let existing = nearNameRightKeys[nearKey], existing != key {
                ambiguousNearNameRightKeys.insert(nearKey)
            } else {
                nearNameRightKeys[nearKey] = key
            }
        }
        var ambiguousNearNameLeftKeys = Set<String>()
        var seenNearNameLeftKeys: [String: String] = [:]
        seenNearNameLeftKeys.reserveCapacity(leftFilesInfo.count)
        for key in leftFilesInfo.keys {
            let nearKey = ProviderNameRules.nearNameKey(forRelativePath: key, foldCase: caseInsensitive)
            if let existing = seenNearNameLeftKeys[nearKey], existing != key {
                ambiguousNearNameLeftKeys.insert(nearKey)
            } else {
                seenNearNameLeftKeys[nearKey] = key
            }
        }
        // Right keys consumed by a near-name match in pass 1; pass 2 must not report them missing.
        var nearNameMatchedRightKeys = Set<String>()
        // Directory pairs whose names differ invisibly, left spelling → right spelling, to re-aim
        // one-sided descendants at the destination's real folder. The source's spelling would mint
        // the look-alike folder the name-conflict row exists to prevent.
        var nearNameDirPairs: [String: String] = [:]

        // The right key a left folder pairs with in pass 1 (exactly, as a case variant, or by
        // near-name), or nil. Pass 1's guards that only an ambiguous form can trip are left out,
        // since ambiguity is refused here. Memoized: every key below a folder asks again.
        var folderCounterparts: [String: String?] = [:]
        func counterpart(ofLeftFolder folder: String) -> String? {
            if let known = folderCounterparts[folder] { return known }
            var answer: String?
            if leftFilesInfo[folder] == nil {
                answer = nil
            } else if rightFilesInfo[folder] != nil {
                answer = folder
            } else if caseInsensitive, let variant = caseFoldedRightKeys[folder.lowercased()],
                      leftFilesInfo[variant] == nil {
                answer = variant
            } else {
                let nearKey = ProviderNameRules.nearNameKey(forRelativePath: folder, foldCase: caseInsensitive)
                if !ambiguousNearNameLeftKeys.contains(nearKey),
                   !ambiguousNearNameRightKeys.contains(nearKey) {
                    answer = nearNameRightKeys[nearKey]
                }
            }
            folderCounterparts.updateValue(answer, forKey: folder)
            return answer
        }
        // A key pairs by near-name only where every folder above it pairs with the one at the
        // same depth above the candidate. With left `A` and `A ` against a right `A`, `A ` pairs
        // with nothing, so `A /f.txt` must not pair with `A/f.txt`: it would put a both-sides row
        // inside a missing folder, and sync `f.txt` twice. Refused, it collapses into its folder.
        func foldersPair(above leftKey: String, and rightKey: String) -> Bool {
            for (leftFolder, rightFolder) in zip(FoldersAbove(leftKey), FoldersAbove(rightKey)) {
                if counterpart(ofLeftFolder: String(leftFolder)) != String(rightFolder) { return false }
            }
            return true
        }

        // Unexplored-ancestor suppression under the same folding pairing uses, so left
        // "Docs/x.txt" sees an unreadable right "docs" or "Docs␣" as its counterpart rather than
        // minting Missing rows into it. Applies only when no exact spelling on the other side owns
        // that level. `nearNameKey` folds case exactly when the comparison does.
        func suppressionKey(_ path: String) -> String {
            ProviderNameRules.nearNameKey(forRelativePath: path, foldCase: caseInsensitive)
        }
        let unexploredLeftDirKeys = Set(unexploredLeftDirs.map(suppressionKey))
        let unexploredRightDirKeys = Set(unexploredRightDirs.map(suppressionKey))
        // Readable dirs under the same fold: a readable owner of a level, exact or variant, means
        // the row targets it. Readable wins ties: over-reporting into a readable folder beats
        // hiding a real difference.
        func readableDirKeys(_ side: [String: FileInfo]) -> Set<String> {
            Set(side.compactMap { key, info in
                info.isDirectory && !info.isUnexplored ? suppressionKey(key) : nil
            })
        }
        let readableLeftDirKeys = readableDirKeys(leftFilesInfo)
        let readableRightDirKeys = readableDirKeys(rightFilesInfo)
        func hasUnexploredFoldedAncestor(
            of relativePath: String, keys: Set<String>, otherSide: [String: FileInfo], readableKeys: Set<String>
        ) -> Bool {
            guard !keys.isEmpty else { return false }
            for folder in FoldersAbove(relativePath) {
                let prefix = String(folder)
                if otherSide[prefix] != nil { continue }             // exact entry owns this level
                let key = suppressionKey(prefix)
                if readableKeys.contains(key) { continue }           // a readable variant owns it
                if keys.contains(key) { return true }
            }
            return false
        }

        // 1. Files on left but not on right (or compare if exists)
        for (relativePath, leftFile) in leftFilesInfo {
            // Exact-case match first; on case-insensitive volumes fall back to a case-variant match.
            var rightKey = relativePath
            var namesDifferOnlyByCase = false
            if rightFilesInfo[rightKey] == nil,
               caseInsensitive,
               let variant = caseFoldedRightKeys[relativePath.lowercased()],
               leftFilesInfo[variant] == nil { // if the variant also exists on the left, that exact pair owns it
                rightKey = variant
                // Only a leaf-name case difference belongs to this row; identical children of
                // case-variant folders must produce no rows.
                namesDifferOnlyByCase = TreeShape.leaf(of: relativePath) != TreeShape.leaf(of: variant)
                caseVariantMatchedRightKeys.insert(variant)
            }
            // Near-name fallback for names that differ only invisibly. As for case variants: the
            // exact pair owns its keys, ambiguous forms never match, a right key is consumed once,
            // and the folders above must pair (`foldersPair`).
            var nearNameMatched = false
            if rightFilesInfo[rightKey] == nil {
                let nearKey = ProviderNameRules.nearNameKey(forRelativePath: relativePath, foldCase: caseInsensitive)
                if !ambiguousNearNameLeftKeys.contains(nearKey),
                   !ambiguousNearNameRightKeys.contains(nearKey),
                   let candidate = nearNameRightKeys[nearKey],
                   leftFilesInfo[candidate] == nil,
                   !caseVariantMatchedRightKeys.contains(candidate),
                   !nearNameMatchedRightKeys.contains(candidate),
                   foldersPair(above: relativePath, and: candidate) {
                    rightKey = candidate
                    nearNameMatched = true
                    nearNameMatchedRightKeys.insert(candidate)
                }
            }
            if let rightFile = rightFilesInfo[rightKey] {
                if nearNameMatched {
                    let leftLeaf = String(TreeShape.leaf(of: relativePath))
                    let rightLeaf = String(TreeShape.leaf(of: rightKey))
                    // The conflict row belongs to the level whose name differs. Under an
                    // invisibly renamed folder this pair is ordinary content, compared below. A
                    // leaf differing only by case is a case variant, not an invisible rename.
                    let leafInvisiblyRenamed = leftLeaf != rightLeaf
                        && !(caseInsensitive && leftLeaf.lowercased() == rightLeaf.lowercased())
                    if leafInvisiblyRenamed {
                        if leftFile.isDirectory && rightFile.isDirectory {
                            nearNameDirPairs[relativePath] = rightKey
                        } else if leftFile.isDirectory != rightFile.isDirectory {
                            // A file against a folder: either direction replaces the whole subtree,
                            // so the folder's contents collapse into this row. As separate rows they
                            // would mint the look-alike folder beside the file.
                            typeMismatchDirs[leftFile.isDirectory ? relativePath : rightKey] = relativePath
                        }
                        // Both item paths are real, so a sync either way meets the existing
                        // counterpart as a normal collision. The newer side wins; ties go left→right.
                        let leftDate = leftFile.modificationDate ?? Date.distantPast
                        let rightDate = rightFile.modificationDate ?? Date.distantPast
                        let action: FileDifference.SyncAction =
                            rightDate.timeIntervalSince(leftDate) > dateToleranceSeconds ? .copyToLeft : .copyToRight
                        let source = action == .copyToRight ? leftFile : rightFile
                        // Different sizes with no clearly newer side is a question here too: the
                        // tie default is a guess. Held like the plain both-files row, same note; a
                        // side with no date is no newer side.
                        let bothDated = leftFile.modificationDate != nil && rightFile.modificationDate != nil
                        let noNewerSide = !bothDated
                            || abs(leftDate.timeIntervalSince(rightDate)) <= dateToleranceSeconds
                        let sizesUnclear = !leftFile.isDirectory && !rightFile.isDirectory
                            && leftFile.fileSize != rightFile.fileSize && noNewerSide
                        var conflictNote = ProviderNameRules.nameConflictDescription(
                            leftName: leftLeaf, leftProvider: left.displayName,
                            rightName: rightLeaf, rightProvider: right.displayName
                        )
                        if sizesUnclear {
                            let sizesNote = sizesDifferWithoutANewerSide(
                                leftDate: leftFile.modificationDate, rightDate: rightFile.modificationDate,
                                left: left, right: right, dateToleranceSeconds: dateToleranceSeconds)
                            conflictNote += "; " + sizesNote.prefix(1).lowercased() + sizesNote.dropFirst()
                        }
                        let heldReason: FileDifference.HeldBack? = leftFile.isDirectory != rightFile.isDirectory
                            ? .folderVersusFile
                            : sizesUnclear ? .sizesDifferWithoutANewerSide : nil
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .nameConflict,
                            action: action,
                            description: noted(conflictNote, source: source),
                            leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                            rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                            leftIsDirectory: leftFile.isDirectory,
                            rightIsDirectory: rightFile.isDirectory,
                            // A folder's own date says nothing about its contents, so held like the
                            // plain type-mismatch row below.
                            heldBack: held(heldReason, source: source)
                        ))
                        continue
                    }
                }
                let caseNote = namesDifferOnlyByCase ? " (names differ only by case)" : ""
                // exists in both, compare dates and sizes in RAM
                if leftFile.isDirectory != rightFile.isDirectory {
                    // Descendants live under the dir side's own key, so record that key.
                    typeMismatchDirs[leftFile.isDirectory ? relativePath : rightKey] = relativePath
                    let resolution = resolveTypeMismatch(
                        left: leftFile,
                        leftProvider: left,
                        right: rightFile,
                        rightProvider: right,
                        dateToleranceSeconds: dateToleranceSeconds
                    )
                    let source = resolution.action == .copyToRight ? leftFile : rightFile
                    diffs.append(FileDifference(
                        relativePath: relativePath,
                        leftItemPath: leftFile.url.path,
                        rightItemPath: rightFile.url.path,
                        type: .differentDates,
                        action: resolution.action,
                        description: noted(resolution.description + caseNote, source: source),
                        leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                        rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                        leftIsDirectory: leftFile.isDirectory,
                        rightIsDirectory: rightFile.isDirectory,
                        heldBack: held(.folderVersusFile, source: source)
                    ))
                    continue
                }

                // Both are folders (maybe case variants): no row; their children compare below.
                if leftFile.isDirectory { continue }
                
                let leftDate = leftFile.modificationDate
                let rightDate = rightFile.modificationDate
                
                let dateDiffers: Bool
                if let lD = leftDate, let rD = rightDate {
                    dateDiffers = abs(lD.timeIntervalSince(rD)) > dateToleranceSeconds
                } else {
                    dateDiffers = false // Can't reliably compare dates, fallback to size
                }

                let sizeDiffers = (leftFile.fileSize != rightFile.fileSize) && (leftFile.fileSize != nil || rightFile.fileSize != nil)

                if dateDiffers || sizeDiffers { // date tolerance exceeded or size mismatch
                    let leftIsNewer = (leftDate ?? Date.distantPast) > (rightDate ?? Date.distantPast)

                    if sizeDiffers && !dateDiffers {
                        // Different sizes and no newer side is a question, not a direction: the
                        // dates match within the tolerance, or a side has none. The suggestion
                        // (left → right) only aims a single deliberate copy; the note says it is a
                        // guess, and the row is held out of bulk runs (`FileDifference.HeldBack`).
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToRight,
                            description: noted(sizesDifferWithoutANewerSide(
                                leftDate: leftDate, rightDate: rightDate, left: left, right: right,
                                dateToleranceSeconds: dateToleranceSeconds) + caseNote,
                                source: leftFile),
                            leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                            rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                            heldBack: held(.sizesDifferWithoutANewerSide, source: leftFile)
                        ))
                    } else if leftIsNewer {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToRight,
                            description: noted("\(left.displayName) file is newer" + caseNote, source: leftFile),
                            leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                            rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                            heldBack: held(nil, source: leftFile)
                        ))
                    } else {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToLeft,
                            description: noted("\(right.displayName) file is newer" + caseNote, source: rightFile),
                            leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                            rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                            heldBack: held(nil, source: rightFile)
                        ))
                    }
                } else if namesDifferOnlyByCase {
                    // Same dates and sizes, names differ by case: one row (checksum-verifiable)
                    // rather than two "missing" rows.
                    diffs.append(FileDifference(
                        relativePath: relativePath,
                        leftItemPath: leftFile.url.path,
                        rightItemPath: rightFile.url.path,
                        type: .differentDates,
                        action: .copyToRight,
                        description: noted("Names differ only by case", source: leftFile),
                        leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                        rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                        heldBack: held(nil, source: leftFile)
                    ))
                }
            } else {
                // Absent from the right map, but if the right root or an ancestor couldn't be
                // listed, that is unknown, not missing.
                if rightRootUnreadable { continue }
                if topMostAncestor(of: relativePath, in: unexploredRightDirs) != nil { continue }
                if hasUnexploredFoldedAncestor(of: relativePath, keys: unexploredRightDirKeys,
                                               otherSide: rightFilesInfo,
                                               readableKeys: readableRightDirKeys) { continue }
                // missing on right
                if leftFile.isDirectory { missingOnRightDirs.insert(relativePath) }
                missingOnRight.append((relativePath, leftFile))
            }
        }
        
        // 2. Files on right but not on left
        for (relativePath, rightFile) in rightFilesInfo {
            if leftFilesInfo[relativePath] == nil
                && !caseVariantMatchedRightKeys.contains(relativePath)
                && !nearNameMatchedRightKeys.contains(relativePath) {
                // Mirror of pass 1: with the left root or an ancestor unlistable, absence is
                // unknown, not missing.
                if leftRootUnreadable { continue }
                if topMostAncestor(of: relativePath, in: unexploredLeftDirs) != nil { continue }
                if hasUnexploredFoldedAncestor(of: relativePath, keys: unexploredLeftDirKeys,
                                               otherSide: leftFilesInfo,
                                               readableKeys: readableLeftDirKeys) { continue }
                if rightFile.isDirectory { missingOnLeftDirs.insert(relativePath) }
                missingOnLeft.append((relativePath, rightFile))
            }
        }
        
        // 3. The one-sided rows, for what the collapse keeps.
        //
        // A missing folder and a type-mismatch folder each handle their whole subtree in one
        // action, so their descendants get no rows: separate rows would double-copy in a bulk sync,
        // race the parent's replace, and leave stale rows behind. The folder row gets
        // `enclosedItemCount` instead. Decided on the keys before any row is built, since a Home
        // scan can have ~200,000 one-sided entries and keep a few dozen rows.
        //
        // A type-mismatch dir's descendants exist only on its directory side, so one shared set
        // serves both directions. Both-sides items can't sit under a collapsible folder: every
        // folder above them pairs (for a near-name pair, because pass 1 checks `foldersPair`).
        let typeMismatchDirPaths = Set(typeMismatchDirs.keys)
        let collapsibleOnRight = missingOnRightDirs.union(typeMismatchDirPaths)
        let collapsibleOnLeft = missingOnLeftDirs.union(typeMismatchDirPaths)
        // Top-most collapsible ancestor folder's row path → number of items collapsed into it.
        var enclosedCounts: [String: Int] = [:]
        // The same row path → the links among those items, which its recursive copy would write
        // as links. Read off the entries in hand; only these are resolved, once rows are built.
        var enclosedLinks: [String: [(key: String, url: URL)]] = [:]
        /// Whether `key` is carried by a folder's row, counting it there if so. A type-mismatch row
        /// is keyed by the left path, which can differ from the dir-side key, so map back to it.
        func isCollapsed(_ key: String, _ file: FileInfo, into dirs: Set<String>) -> Bool {
            guard let ancestor = topMostAncestor(of: key, in: dirs) else { return false }
            let row = typeMismatchDirs[ancestor] ?? ancestor
            enclosedCounts[row, default: 0] += 1
            if file.isSymbolicLink { enclosedLinks[row, default: []].append((key, file.url)) }
            return true
        }
        // Re-aim one-sided items under a name-conflicted folder pair at the destination's real
        // spelling; the source's spelling would create the look-alike folder `.nameConflict`
        // exists to prevent.
        let rightToLeftDirPairs = nearNameDirPairs.isEmpty ? [:] : Dictionary(
            nearNameDirPairs.map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        // `isDirectory:` from the entry, or the URL probes the file system per row; it only
        // decides a trailing slash, which `.path` drops. Composition stays URL composition: it
        // decomposes precomposed names, and concatenation would not (`OneSidedRowPathTests`).
        for (relativePath, leftFile) in missingOnRight {
            if isCollapsed(relativePath, leftFile, into: collapsibleOnRight) { continue }
            let destination = remappedPath(relativePath, via: nearNameDirPairs) ?? relativePath
            diffs.append(FileDifference(
                relativePath: relativePath,
                leftItemPath: leftFile.url.path,
                rightItemPath: rightURL.appendingPathComponent(destination, isDirectory: leftFile.isDirectory).path,
                type: .missingOnRight,
                action: .copyToRight,
                description: noted(leftFile.isDirectory ? "Folder missing on right (\(right.displayName))" : "Missing on right (\(right.displayName))",
                                   source: leftFile),
                // The item exists on the left; carry its size for the Differences list (nil, "—",
                // for a folder).
                leftFileSize: leftFile.fileSize, leftModified: leftFile.modificationDate,
                leftIsDirectory: leftFile.isDirectory,
                // A link's contents are counted like a real folder's; it is the copy that can't
                // reproduce them.
                heldBack: held(nil, source: leftFile)
            ))
        }
        for (relativePath, rightFile) in missingOnLeft {
            if isCollapsed(relativePath, rightFile, into: collapsibleOnLeft) { continue }
            // Missing-on-left entries carry RIGHT-side relative paths; re-aim right → left.
            let destination = remappedPath(relativePath, via: rightToLeftDirPairs) ?? relativePath
            diffs.append(FileDifference(
                relativePath: relativePath,
                leftItemPath: leftURL.appendingPathComponent(destination, isDirectory: rightFile.isDirectory).path,
                rightItemPath: rightFile.url.path,
                type: .missingOnLeft,
                action: .copyToLeft,
                description: noted(rightFile.isDirectory ? "Folder missing on left (\(left.displayName))" : "Missing on left (\(left.displayName))",
                                   source: rightFile),
                // The item exists on the right; carry its size so the Differences list can show it.
                rightFileSize: rightFile.fileSize, rightModified: rightFile.modificationDate,
                rightIsDirectory: rightFile.isDirectory,
                heldBack: held(nil, source: rightFile)
            ))
        }
        // The counts are complete only now: a folder's key can come before its contents'.
        if !enclosedCounts.isEmpty {
            diffs = diffs.map { diff in
                guard let count = enclosedCounts[diff.relativePath] else { return diff }
                // A link inside a missing folder that points out of it holds the folder's row: the
                // recursive copy writes it as a link, which would lead back out of the copy. One
                // that stays inside (`Versions/Current -> A`) is fine. Missing-folder rows only: a
                // folder-versus-file row is held already.
                var heldBack = diff.heldBack
                var description = diff.description
                if heldBack == nil, diff.type == .missingOnRight || diff.type == .missingOnLeft,
                   let enclosed = enclosedLinks[diff.relativePath] {
                    let folder = diff.type == .missingOnRight ? diff.leftItemPath : diff.rightItemPath
                    let links = enclosed.filter { linkLeads(out: $0.url, of: folder) }.map(\.key).sorted()
                    if let first = links.first {
                        heldBack = .enclosesSymbolicLink(path: first)
                        description += links.count == 1
                            ? " — “\(first)” inside it is a link, so a copy would carry the link, not what it points to"
                            : " — “\(first)” and \(links.count - 1) more inside it are links, so a copy would carry the links, not what they point to"
                    }
                }
                return FileDifference(
                    id: diff.id,
                    relativePath: diff.relativePath,
                    leftItemPath: diff.leftItemPath,
                    rightItemPath: diff.rightItemPath,
                    type: diff.type,
                    action: diff.action,
                    description: description,
                    isSyncing: diff.isSyncing,
                    leftFileSize: diff.leftFileSize,
                    leftModified: diff.leftModified,
                    rightFileSize: diff.rightFileSize,
                    rightModified: diff.rightModified,
                    enclosedItemCount: count,
                    leftIsDirectory: diff.leftIsDirectory,
                    rightIsDirectory: diff.rightIsDirectory,
                    heldBack: heldBack
                )
            }
        }

        let result = diffs.sorted { $0.relativePath < $1.relativePath }
        Logger.shared.debug("Computed differences: \(result.count) item(s) requiring action")
        return result
    }

    /// Whether the link at `link`, copied as a link inside `folder`, would point outside the copy
    /// (`FileDifference.HeldBack.enclosesSymbolicLink`).
    ///
    /// - An absolute target is always out: the copy keeps the path, so it leads to the original.
    /// - A relative target is followed by `realpath(3)` (so `..` and chained links count), and is in
    ///   only when it lands at or under `folder`, compared byte for byte.
    /// - A target that can't be followed (dangling, a loop, unreadable) is out.
    static func linkLeads(out link: URL, of folder: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              !target.hasPrefix("/"),
              let resolved = realPath(link.path), let root = realPath(folder) else { return true }
        return !(resolved.utf8.elementsEqual(root.utf8) || resolved.utf8.starts(with: (root + "/").utf8))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` rewritten from one side's folder spelling into the other's: the deepest folder above
    /// it that `dirPairs` names is replaced with its counterpart. Deepest, since each nested pair is
    /// keyed by its full path and so already carries every ancestor's spelling. nil when none
    /// applies. The rest is carried over from the `/` by scalar, or a name ending in a Prepend
    /// character would take the `/` with it (see `FoldersAbove`).
    private static func remappedPath(_ path: String, via dirPairs: [String: String]) -> String? {
        guard !dirPairs.isEmpty else { return nil }
        var deepest: (folder: Substring, replacement: String)?
        for folder in FoldersAbove(path) {
            if let replacement = dirPairs[String(folder)] { deepest = (folder, replacement) }
        }
        guard let deepest else { return nil }
        var remapped = deepest.replacement
        remapped.unicodeScalars.append(contentsOf: path.unicodeScalars[deepest.folder.endIndex...])
        return remapped
    }

    /// Shortest strict prefix of `path` (at a "/" component boundary) that is in `dirs`, or nil.
    /// The shortest match is the top-most missing folder, so nested missing folders and their
    /// contents all collapse into the single entry the user actually sees.
    private static func topMostAncestor(of path: String, in dirs: Set<String>) -> String? {
        guard !dirs.isEmpty else { return nil }
        for folder in FoldersAbove(path) {
            let prefix = String(folder)
            if dirs.contains(prefix) { return prefix }
        }
        return nil
    }

    /// The folders above a relative path, outermost first: each prefix that ends just before a
    /// `/`, as a slice of the path whose `endIndex` is that `/`.
    ///
    /// **The `/` is found by scalar, never by Character.** A name opening with a combining mark or
    /// ending with a Prepend character (U+0600…) joins the `/` into one Character, and a Character
    /// search would fuse the two names. Both scans cut keys by scalar, so the folder above would go
    /// unseen by the collapse, the unreadable-folder suppression and the remap.
    private struct FoldersAbove: Sequence, IteratorProtocol {
        private let path: String
        private var cursor: String.Index

        init(_ path: String) {
            self.path = path
            cursor = path.utf8.startIndex
        }

        mutating func next() -> Substring? {
            guard let slash = path.utf8[cursor...].firstIndex(of: UInt8(ascii: "/")) else { return nil }
            cursor = path.utf8.index(after: slash)
            return Substring(path.unicodeScalars[..<slash])
        }
    }
}
