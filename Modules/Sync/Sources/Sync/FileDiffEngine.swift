import Foundation
import Events

/// Stateless engine that computes sync differences between two directory trees (left and right panes).
/// Handles O(N) filesystem scanning and date/size comparison; used by `FileSyncManager` on a background thread.
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
        /// True for a directory whose contents could NOT be listed (permission denied, I/O
        /// error) — this side's view of what's inside is UNKNOWN, not empty. The diff must not
        /// mint "Missing" rows for the other side's contents of such a directory: accepting one
        /// would copy files into a folder nobody can read (or worse, "restore" content that was
        /// never gone). Mirrors `FileNode.isUnexplored` so the warm (tree) and cold (disk walk)
        /// scan branches agree.
        public let isUnexplored: Bool

        public init(url: URL, modificationDate: Date?, fileSize: Int?, isDirectory: Bool,
                    isUnexplored: Bool = false) {
            self.url = url
            self.modificationDate = modificationDate
            self.fileSize = fileSize
            self.isDirectory = isDirectory
            self.isUnexplored = isUnexplored
        }
    }

    private static func resolveTypeMismatch(
        left: FileInfo,
        leftProvider: CloudProvider,
        right: FileInfo,
        rightProvider: CloudProvider,
        dateToleranceSeconds: TimeInterval
    ) -> (action: FileDifference.SyncAction, description: String) {
        let leftDate = left.modificationDate ?? Date.distantPast
        let rightDate = right.modificationDate ?? Date.distantPast

        if abs(leftDate.timeIntervalSince(rightDate)) > dateToleranceSeconds {
            if leftDate > rightDate {
                return (.copyToRight, "\(leftProvider.displayName) item is newer (type mismatch)")
            }
            return (.copyToLeft, "\(rightProvider.displayName) item is newer (type mismatch)")
        }

        if left.isDirectory {
            return (.copyToRight, "Type mismatch; defaulting to the folder from \(leftProvider.displayName)")
        }

        return (.copyToLeft, "Type mismatch; defaulting to the folder from \(rightProvider.displayName)")
    }
    
    /// Builds the same relative-path→`FileInfo` map `getFilesInDirectory` produces by walking
    /// the disk, but from an already-built deep `FileNode` tree — used to skip the scan's
    /// re-walk when both panes' trees are current (they carry the same metadata the walk
    /// would fetch). Key normalization mirrors `getFilesInDirectory`: strip `basePath`, strip
    /// the leading slash, skip the base itself.
    public static func filesInfo(fromTree nodes: [FileNode], basePath: String) -> [String: FileInfo] {
        var result: [String: FileInfo] = [:]
        func add(_ node: FileNode) {
            var relativePath = node.id
            if relativePath.hasPrefix(basePath) {
                relativePath = String(relativePath.dropFirst(basePath.count))
            }
            if relativePath.hasPrefix("/") {
                relativePath.removeFirst()
            }
            if !relativePath.isEmpty {
                result[relativePath] = FileInfo(
                    url: URL(fileURLWithPath: node.id),
                    modificationDate: node.modificationDate,
                    fileSize: node.fileSize,
                    isDirectory: node.isDirectory,
                    // Carry the walk's "couldn't look inside" marker (permission denied, cycle
                    // cap): computeDifferences must not read the absent children as "missing".
                    isUnexplored: node.isDirectory && node.isUnexplored == true
                )
            }
            for child in node.children ?? [] {
                add(child)
            }
        }
        for node in nodes {
            add(node)
        }
        return result
    }

    /// Recursively scans a directory and aggregates `FileInfo` objects in a dictionary keyed by relative path.
    /// Uses high-performance resource value fetching in standard production, and fallback attributes for mocks.
    /// - Parameters:
    ///   - url: The root directory URL to scan.
    ///   - fileManager: The file manager to use for scanning (supports injected mocks).
    /// - Returns: A map of relative paths to `FileInfo` metadata.
    public static func getFilesInDirectory(_ url: URL, fileManager: FileManaging = FileManager.default) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let keySet = Set(keys)

        var result: [String: FileInfo] = [:]
        // Unreadable entries are aggregated and logged once after the walk: a permission-denied
        // or placeholder-heavy subtree can fail for tens of thousands of entries, and logging
        // per-entry spawned that many MainActor tasks and disk writes mid-scan.
        var unreadableCount = 0
        var unreadableSamples: [String] = []
        let maxIndividuallyLogged = 3
        // Relative keys of directories the enumerator could not descend into (permission
        // denied): their entries are re-marked `isUnexplored` after the walk, so the diff knows
        // this side's view of their contents is UNKNOWN — not empty. Without this the cold
        // (disk-walk) branch silently skipped the subtree and the other side's files showed up
        // as phantom actionable "Missing" rows.
        var unreadableDirKeys = Set<String>()

        /// Stable identity of the directory a URL ultimately refers to (through symlinks), for
        /// the symlink-descent cycle guard below — the disk-walk counterpart of the tree walk's
        /// `directoryIdentity`. Mock file managers contain no symlinks, so the raw-path fallback
        /// only ever fires for them (and for real-FS stat failures, where refusing to descend is
        /// the safe answer).
        func canonicalIdentity(_ dirURL: URL) -> String {
            // Resolve the link itself first — canonicalPathKey canonicalizes the path (case,
            // /private) but does NOT resolve a leaf symlink, and an unresolved leaf makes every
            // link look distinct from its target, defeating the cycle guard.
            let resolved = dirURL.resolvingSymlinksInPath()
            if fileManager is FileManager,
               let canonical = try? resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                return canonical
            }
            return resolved.standardizedFileURL.path
        }

        // Symlinked-directory targets on the current branch (by canonical identity): the scan root
        // plus every symlinked directory descended into on the path to here. PER-BRANCH (an
        // immutable snapshot extended per descent, like the warm-cache tree walk's `branchVisited`)
        // rather than global: two SIBLING symlinks to the same directory must each expand — a
        // global set would descend the target only once, so a cold-cache (disk) scan would report
        // the second link's contents missing while a warm-cache (tree) scan reports them present.
        // The branch snapshot still breaks A→B→A cycles and self-links.
        let symlinkDepthCap = 64   // mirrors TreeBuilder.hardDepthCap, bounding pathological symlink fan-out

        func walk(_ rootURL: URL, prefix: String, branchVisited: Set<String>) throws {
            var basePath = rootURL.path
            if fileManager is FileManager {
                // The real enumerator yields canonical, symlink-resolved URLs (/private/var/...), so a
                // root given via a symlinked path (/var/..., a linked user folder) would never match the
                // prefix trim below and every key would come back near-absolute. Canonicalize the base
                // to match. resolvingSymlinksInPath can't be used here: it deliberately strips /private.
                // Mock file managers echo back the URLs they were given, so they keep the raw base.
                if let canonicalPath = try? rootURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                    basePath = canonicalPath
                }
            }

            // The error handler fires when the enumerator cannot descend into a directory
            // (permission denied) or read an entry. A nil handler silently SKIPPED the subtree —
            // the cold branch's counterpart of the tree walk's unexplored marking — so record the
            // failure into the same aggregation the per-entry catch feeds, and remember the
            // directory so its map entry is re-marked unexplored after the walk. Returning true
            // keeps the rest of the walk going: one locked folder must not abort the whole scan.
            let recordUnreadable: (URL, Error) -> Bool = { failedURL, error in
                unreadableCount += 1
                if unreadableSamples.count < maxIndividuallyLogged {
                    unreadableSamples.append("Error enumerating \(failedURL): \(error)")
                }
                var rel = failedURL.path
                if rel.hasPrefix(basePath) { rel = String(rel.dropFirst(basePath.count)) }
                if rel.hasPrefix("/") { rel.removeFirst() }
                if !rel.isEmpty {
                    unreadableDirKeys.insert(prefix.isEmpty ? rel : prefix + "/" + rel)
                }
                return true
            }
            guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: recordUnreadable) else {
                return
            }

            for case let fileURL as URL in enumerator {
                // A superseded scan's results are discarded wholesale (generation-gated publish);
                // abort mid-walk instead of holding the scanning slot for a walk nobody will read.
                try Task.checkCancellation()
                do {
                    var isReg = true
                    var modDate: Date? = nil
                    var size: Int? = nil
                    var isDir = false
                    var isSymlinkedDir = false

                    if let _ = fileManager as? FileManager {
                        let resourceValues = try fileURL.resourceValues(forKeys: keySet)
                        if resourceValues.isSymbolicLink == true {
                            // Align with the tree path (buildNode): symlinked entries participate
                            // with the TARGET's type/size/date — the link's own stat is meaningless
                            // for diffing — and broken links are dropped.
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
                            relativePath = String(relativePath.dropFirst(basePath.count))
                        }
                        if relativePath.hasPrefix("/") {
                            relativePath.removeFirst()
                        }

                        if relativePath.isEmpty { continue }
                        let keyPath = prefix.isEmpty ? relativePath : prefix + "/" + relativePath

                        result[keyPath] = FileInfo(
                            url: fileURL,
                            modificationDate: modDate,
                            fileSize: size,
                            isDirectory: isDir
                        )

                        // The URL enumerator never walks INTO a symlinked directory, but the tree
                        // walk always has — leaving the two scan branches disagreeing: a cold-cache
                        // (disk) scan reported a linked folder's contents as missing on this side
                        // while a warm-cache (tree) scan reported them present, phantom rows whose
                        // bulk-accept would re-copy data over the link's real target. Descend
                        // manually (cycle-guarded, via the resolved target) so both branches see
                        // the same files.
                        if isSymlinkedDir {
                            let targetID = canonicalIdentity(fileURL)
                            let depth = keyPath.split(separator: "/").count
                            // The flat enumerator descends the whole real subtree in one call, so
                            // `branchVisited` only ever holds the root plus targets we manually
                            // descended — never the real intermediate directories walked through.
                            // A link pointing at one of those ancestors (a/b/link -> a) would thus
                            // over-expand a full extra level before the target-repeat guard below
                            // finally catches it. `buildTree` caps such a link immediately because
                            // its `visited` set carries every ancestor. Match that: refuse to
                            // descend a link whose target is an ancestor of (or the same as) the
                            // directory the link lives in.
                            let hostID = canonicalIdentity(fileURL.deletingLastPathComponent())
                            let pointsIntoAncestor = hostID == targetID || hostID.hasPrefix(targetID + "/")
                            if !branchVisited.contains(targetID) && !pointsIntoAncestor && depth < symlinkDepthCap {
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
                        unreadableSamples.append("Error reading resource values for \(fileURL): \(error)")
                    }
                }
            }
        }

        try walk(url, prefix: "", branchVisited: [canonicalIdentity(url)])

        // Re-mark the directories whose descent failed: their entry was added while listing the
        // (readable) parent, but what's inside is unknown, not absent.
        for key in unreadableDirKeys {
            if let info = result[key], info.isDirectory, !info.isUnexplored {
                result[key] = FileInfo(url: info.url, modificationDate: info.modificationDate,
                                       fileSize: info.fileSize, isDirectory: true, isUnexplored: true)
            }
        }

        if unreadableCount > 0 {
            let count = unreadableCount
            let samples = unreadableSamples
            let root = url.path
            Task { @MainActor in
                if count <= maxIndividuallyLogged {
                    for message in samples { Logger.shared.error(message) }
                } else {
                    Logger.shared.error("Scan: \(count) entries unreadable under \(root); first: \(samples.joined(separator: " | "))")
                }
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
    ///   - caseInsensitive: Pass true when BOTH pane volumes are case-insensitive (the macOS
    ///     default). Paths that differ only by case then compare as a single pair instead of
    ///     two phantom "missing" rows — syncing those would silently overwrite one side's
    ///     content. With mixed sensitivity (either volume case-sensitive) keep this false:
    ///     the case-sensitive side really can hold both variants, so collapsing them would
    ///     hide a real file.
    ///   - dateToleranceSeconds: Modification dates within this many seconds compare as equal.
    ///     Cloud providers round or rewrite dates on upload (FAT-style 2s granularity, Drive's
    ///     whole-second rewrites), so the user can widen this to hide those false differences.
    ///     0 means exact comparison.
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
        // Directories whose contents could not be LISTED on one side (permission denied — see
        // `FileInfo.isUnexplored`). An item that exists under such a directory on the OTHER side
        // is not "missing" here: this side's view is unknown, and an actionable Missing row would
        // offer to copy into (or "restore" from) a folder nobody could read. Rows under these
        // ancestors are suppressed in both passes below.
        let unexploredLeftDirs = Set(leftFilesInfo.compactMap { key, info in
            info.isDirectory && info.isUnexplored ? key : nil
        })
        let unexploredRightDirs = Set(rightFilesInfo.compactMap { key, info in
            info.isDirectory && info.isUnexplored ? key : nil
        })
        // Folders that exist on one side only, per direction. Their descendants are collapsed
        // into the folder's own entry below (a folder copy is recursive, so the descendants
        // carry no independent action).
        var missingOnRightDirs = Set<String>()
        var missingOnLeftDirs = Set<String>()
        // Folders that pair with a FILE on the other side (type mismatch). Their descendants —
        // which exist only on the directory side — collapse into the mismatch row the same way,
        // since either resolution handles the whole subtree in one action (dir wins: recursive
        // copy; file wins: the subtree is replaced wholesale). Keyed by the dir side's relative
        // path, mapping to the row's relativePath (the LEFT key) — the two can differ in case
        // when the pair matched via case-variant keys and the directory is on the right.
        var typeMismatchDirs: [String: String] = [:]

        // Lowercased right key → actual right key, for the case-insensitive fallback match.
        // Keying by the full relative path also matches children of folders whose names
        // differ only by case ("Docs/a.txt" vs "docs/a.txt"), so they compare against each
        // other instead of double-reporting.
        var caseFoldedRightKeys: [String: String] = [:]
        if caseInsensitive {
            caseFoldedRightKeys.reserveCapacity(rightFilesInfo.count)
            for key in rightFilesInfo.keys {
                caseFoldedRightKeys[key.lowercased()] = key
            }
        }
        // Right keys consumed by a case-variant match in pass 1; pass 2 must not report them missing.
        var caseVariantMatchedRightKeys = Set<String>()

        // Right keys indexed by near-name form (see ProviderNameRules.nearNameKey): the
        // fallback that pairs entries whose names differ only invisibly (trailing/leading
        // whitespace, trailing dots, Unicode NFC/NFD) across the two sides. A form claimed
        // by several keys on either side is ambiguous — matching it would be arbitrary (and
        // dictionary-order nondeterministic), so those keys deterministically fall back to
        // plain missing rows instead.
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
        // Directory pairs whose names differ invisibly, left spelling → right spelling. Used
        // after the passes to re-aim one-side-only descendants at the destination's REAL
        // folder: the naive expected path carries the source side's spelling, and copying to
        // it would mint the very doppelganger folder the name-conflict row exists to prevent.
        var nearNameDirPairs: [String: String] = [:]

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
                // Only a leaf-name case difference belongs to this row. When just an ancestor
                // folder's name differs by case, the difference is the folder's, not every
                // descendant's — identical children under such folders must produce no rows.
                namesDifferOnlyByCase = relativePath.split(separator: "/").last != variant.split(separator: "/").last
                caseVariantMatchedRightKeys.insert(variant)
            }
            // Near-name fallback: pair entries whose names differ only invisibly. Guards
            // mirror the case-variant match — the exact pair owns its keys, ambiguous forms
            // never match, and a right key is consumed at most once.
            var nearNameMatched = false
            if rightFilesInfo[rightKey] == nil {
                let nearKey = ProviderNameRules.nearNameKey(forRelativePath: relativePath, foldCase: caseInsensitive)
                if !ambiguousNearNameLeftKeys.contains(nearKey),
                   !ambiguousNearNameRightKeys.contains(nearKey),
                   let candidate = nearNameRightKeys[nearKey],
                   leftFilesInfo[candidate] == nil,
                   !caseVariantMatchedRightKeys.contains(candidate),
                   !nearNameMatchedRightKeys.contains(candidate) {
                    rightKey = candidate
                    nearNameMatched = true
                    nearNameMatchedRightKeys.insert(candidate)
                }
            }
            if let rightFile = rightFilesInfo[rightKey] {
                if nearNameMatched {
                    let leftLeaf = String(relativePath.split(separator: "/").last ?? Substring(relativePath))
                    let rightLeaf = String(rightKey.split(separator: "/").last ?? Substring(rightKey))
                    // The conflict row belongs to the level whose name actually differs.
                    // When only an ancestor folder's name differs invisibly, this pair is
                    // the folder's ordinary content — compare it normally below (identical
                    // children produce no rows). A leaf differing only by case is the
                    // case-variant story, not an invisible rename.
                    let leafInvisiblyRenamed = leftLeaf != rightLeaf
                        && !(caseInsensitive && leftLeaf.lowercased() == rightLeaf.lowercased())
                    if leafInvisiblyRenamed {
                        if leftFile.isDirectory && rightFile.isDirectory {
                            nearNameDirPairs[relativePath] = rightKey
                        }
                        // Both item paths are REAL: a sync in either direction writes onto
                        // the existing counterpart (a normal collision), never a doppelganger.
                        // Newer side wins the suggested direction; ties default left→right.
                        let leftDate = leftFile.modificationDate ?? Date.distantPast
                        let rightDate = rightFile.modificationDate ?? Date.distantPast
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .nameConflict,
                            action: rightDate.timeIntervalSince(leftDate) > dateToleranceSeconds ? .copyToLeft : .copyToRight,
                            description: ProviderNameRules.nameConflictDescription(
                                leftName: leftLeaf, leftProvider: left.displayName,
                                rightName: rightLeaf, rightProvider: right.displayName
                            ),
                            leftFileSize: leftFile.fileSize,
                            rightFileSize: rightFile.fileSize
                        ))
                        continue
                    }
                }
                let caseNote = namesDifferOnlyByCase ? " (names differ only by case)" : ""
                // exists in both, compare dates and sizes in RAM
                if leftFile.isDirectory != rightFile.isDirectory {
                    // Descendants live under the dir side's own key, so record that key
                    // (left key when the dir is on the left, right key otherwise).
                    typeMismatchDirs[leftFile.isDirectory ? relativePath : rightKey] = relativePath
                    let resolution = resolveTypeMismatch(
                        left: leftFile,
                        leftProvider: left,
                        right: rightFile,
                        rightProvider: right,
                        dateToleranceSeconds: dateToleranceSeconds
                    )
                    diffs.append(FileDifference(
                        relativePath: relativePath,
                        leftItemPath: leftFile.url.path,
                        rightItemPath: rightFile.url.path,
                        type: .differentDates,
                        action: resolution.action,
                        description: resolution.description + caseNote,
                        leftFileSize: leftFile.fileSize,
                        rightFileSize: rightFile.fileSize
                    ))
                    continue
                }

                // Folders both exist (possibly under case-variant names), no "difference" in
                // content but the children compare against each other below.
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
                    
                    if leftIsNewer || (sizeDiffers && !dateDiffers && leftDate == nil && rightDate == nil) {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToRight,
                            description: (sizeDiffers && !dateDiffers ? "Sizes differ" : "\(left.displayName) file is newer") + caseNote,
                            leftFileSize: leftFile.fileSize,
                            rightFileSize: rightFile.fileSize
                        ))
                    } else if !leftIsNewer && dateDiffers {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToLeft,
                            description: "\(right.displayName) file is newer" + caseNote,
                            leftFileSize: leftFile.fileSize,
                            rightFileSize: rightFile.fileSize
                        ))
                    } else {
                        // Fallback if dates are identical/missing but sizes differ: default to left as truth
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            leftItemPath: leftFile.url.path,
                            rightItemPath: rightFile.url.path,
                            type: .differentDates,
                            action: .copyToRight,
                            description: "Sizes differ" + caseNote,
                            leftFileSize: leftFile.fileSize,
                            rightFileSize: rightFile.fileSize
                        ))
                    }
                } else if namesDifferOnlyByCase {
                    // Same dates and sizes, but the on-disk names differ by case. Surface it
                    // as a single comparable row (verifiable by checksum like any same-size
                    // pair) rather than the two phantom "missing" rows exact matching gives.
                    diffs.append(FileDifference(
                        relativePath: relativePath,
                        leftItemPath: leftFile.url.path,
                        rightItemPath: rightFile.url.path,
                        type: .differentDates,
                        action: .copyToRight,
                        description: "Names differ only by case",
                        leftFileSize: leftFile.fileSize,
                        rightFileSize: rightFile.fileSize
                    ))
                }
            } else {
                // Present on the left, absent from the right map — but if it sits under a
                // directory the RIGHT side couldn't list, "absent" is unknowable, not missing.
                if topMostAncestor(of: relativePath, in: unexploredRightDirs) != nil { continue }
                // missing on right
                if leftFile.isDirectory { missingOnRightDirs.insert(relativePath) }
                let rightExpectedPath = rightURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    leftItemPath: leftFile.url.path,
                    rightItemPath: rightExpectedPath,
                    type: .missingOnRight,
                    action: .copyToRight,
                    description: leftFile.isDirectory ? "Folder missing on right (\(right.displayName))" : "Missing on right (\(right.displayName))",
                    // The item exists on the left; carry its size so the Differences list can show it.
                    // Directories report a nil fileSize, so folders stay sizeless (shown as "—").
                    leftFileSize: leftFile.fileSize
                ))
            }
        }
        
        // 2. Files on right but not on left
        for (relativePath, rightFile) in rightFilesInfo {
            if leftFilesInfo[relativePath] == nil
                && !caseVariantMatchedRightKeys.contains(relativePath)
                && !nearNameMatchedRightKeys.contains(relativePath) {
                // Mirror of pass 1: under a directory the LEFT side couldn't list, absence on
                // the left is unknowable — no phantom Missing row.
                if topMostAncestor(of: relativePath, in: unexploredLeftDirs) != nil { continue }
                if rightFile.isDirectory { missingOnLeftDirs.insert(relativePath) }
                let leftExpectedPath = leftURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    leftItemPath: leftExpectedPath,
                    rightItemPath: rightFile.url.path,
                    type: .missingOnLeft,
                    action: .copyToLeft,
                    description: rightFile.isDirectory ? "Folder missing on left (\(left.displayName))" : "Missing on left (\(left.displayName))",
                    // The item exists on the right; carry its size so the Differences list can show it.
                    rightFileSize: rightFile.fileSize
                ))
            }
        }
        
        // Re-aim one-side-only items that live under a name-conflicted folder pair at the
        // destination side's REAL folder spelling. Their expected paths were derived from
        // the source side's relative path, and copying to that spelling would create the
        // exact identical-looking, provider-unsyncable duplicate folder the `.nameConflict`
        // classification exists to prevent.
        if !nearNameDirPairs.isEmpty {
            let rightToLeftDirPairs = Dictionary(
                nearNameDirPairs.map { ($0.value, $0.key) },
                uniquingKeysWith: { first, _ in first }
            )
            diffs = diffs.map { diff in
                let remappedExpectedPath: (left: String, right: String)?
                switch diff.type {
                case .missingOnRight:
                    guard let remapped = remappedPath(diff.relativePath, via: nearNameDirPairs) else { return diff }
                    remappedExpectedPath = (diff.leftItemPath, rightURL.appendingPathComponent(remapped).path)
                case .missingOnLeft:
                    // missingOnLeft rows carry RIGHT-side relative paths; remap right → left.
                    guard let remapped = remappedPath(diff.relativePath, via: rightToLeftDirPairs) else { return diff }
                    remappedExpectedPath = (leftURL.appendingPathComponent(remapped).path, diff.rightItemPath)
                case .differentDates, .nameConflict:
                    return diff
                }
                guard let paths = remappedExpectedPath else { return diff }
                return FileDifference(
                    id: diff.id,
                    relativePath: diff.relativePath,
                    leftItemPath: paths.left,
                    rightItemPath: paths.right,
                    type: diff.type,
                    action: diff.action,
                    description: diff.description,
                    isSyncing: diff.isSyncing,
                    leftFileSize: diff.leftFileSize,
                    rightFileSize: diff.rightFileSize,
                    enclosedItemCount: diff.enclosedItemCount
                )
            }
        }

        let result = collapseMissingFolderContents(
            diffs,
            missingOnRightDirs: missingOnRightDirs,
            missingOnLeftDirs: missingOnLeftDirs,
            typeMismatchDirs: typeMismatchDirs
        ).sorted { $0.relativePath < $1.relativePath }
        Task { @MainActor in
            Logger.shared.debug("Computed differences: \(result.count) items requiring action.")
        }
        return result
    }

    /// Drops differences that live inside a folder whose own row already resolves them:
    /// a folder missing on the same side (copying it is recursive), or a type-mismatch
    /// folder (either resolution — recursive dir copy or wholesale replacement by the
    /// file — handles the whole subtree in one action). Listing contents separately
    /// double-copies during bulk sync, races the parent's replace op under parallel
    /// sync, and leaves stale rows (with spurious overwrite prompts) after the folder
    /// row is synced. The surviving folder entry gets `enclosedItemCount` so the UI can
    /// still say how much it carries.
    private static func collapseMissingFolderContents(
        _ diffs: [FileDifference],
        missingOnRightDirs: Set<String>,
        missingOnLeftDirs: Set<String>,
        typeMismatchDirs: [String: String]
    ) -> [FileDifference] {
        guard !missingOnRightDirs.isEmpty || !missingOnLeftDirs.isEmpty || !typeMismatchDirs.isEmpty else { return diffs }

        // A type-mismatch dir's descendants exist only on its directory side: the other side
        // holds a file there, which has no children. So under a left-side dir they surface
        // solely as .missingOnRight rows, and under a right-side dir solely as .missingOnLeft
        // rows — one shared set safely serves both directions, since the direction that can't
        // occur simply never produces a row to match.
        let typeMismatchDirPaths = Set(typeMismatchDirs.keys)
        let collapsibleOnRight = missingOnRightDirs.union(typeMismatchDirPaths)
        let collapsibleOnLeft = missingOnLeftDirs.union(typeMismatchDirPaths)

        // Top-most collapsible ancestor folder's row path → number of items collapsed into it.
        var enclosedCounts: [String: Int] = [:]
        var kept: [FileDifference] = []
        kept.reserveCapacity(diffs.count)

        for diff in diffs {
            let dirs: Set<String>
            switch diff.type {
            case .missingOnRight: dirs = collapsibleOnRight
            case .missingOnLeft: dirs = collapsibleOnLeft
            case .differentDates, .nameConflict:
                // Items present on both sides (including type-mismatch and name-conflict
                // rows themselves) can't sit under a missing or type-mismatch folder: every
                // ancestor of a both-sides path exists as a directory on both sides.
                kept.append(diff)
                continue
            }
            if let ancestor = topMostAncestor(of: diff.relativePath, in: dirs) {
                // A type-mismatch dir's row is keyed by the LEFT path, which can differ in
                // case from the dir-side key the descendants carry; map back to the row.
                enclosedCounts[typeMismatchDirs[ancestor] ?? ancestor, default: 0] += 1
            } else {
                kept.append(diff)
            }
        }

        guard !enclosedCounts.isEmpty else { return kept }
        return kept.map { diff in
            guard let count = enclosedCounts[diff.relativePath] else { return diff }
            return FileDifference(
                id: diff.id,
                relativePath: diff.relativePath,
                leftItemPath: diff.leftItemPath,
                rightItemPath: diff.rightItemPath,
                type: diff.type,
                action: diff.action,
                description: diff.description,
                isSyncing: diff.isSyncing,
                leftFileSize: diff.leftFileSize,
                rightFileSize: diff.rightFileSize,
                enclosedItemCount: count
            )
        }
    }

    /// `path` rewritten from one side's folder spelling into the other's: the LONGEST
    /// `dirPairs` key that prefixes it at a component boundary is replaced with its
    /// counterpart spelling. Longest wins because nested name-conflicted folders each get
    /// their own pair entry keyed by the full source-side path, so the deepest entry already
    /// carries every ancestor's destination spelling. nil when no conflicted ancestor applies.
    private static func remappedPath(_ path: String, via dirPairs: [String: String]) -> String? {
        var best: (prefix: String, replacement: String)?
        for (sourceDir, destinationDir) in dirPairs {
            if path.hasPrefix(sourceDir + "/"), sourceDir.count > (best?.prefix.count ?? -1) {
                best = (sourceDir, destinationDir)
            }
        }
        guard let best else { return nil }
        return best.replacement + path.dropFirst(best.prefix.count)
    }

    /// Shortest strict prefix of `path` (at a "/" component boundary) that is in `dirs`, or nil.
    /// The shortest match is the top-most missing folder, so nested missing folders and their
    /// contents all collapse into the single entry the user actually sees.
    private static func topMostAncestor(of path: String, in dirs: Set<String>) -> String? {
        guard !dirs.isEmpty else { return nil }
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            let prefix = String(path[..<slash])
            if dirs.contains(prefix) { return prefix }
            index = path.index(after: slash)
        }
        return nil
    }
}
