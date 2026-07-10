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
    }

    private static func resolveTypeMismatch(
        left: FileInfo,
        leftProvider: CloudProvider,
        right: FileInfo,
        rightProvider: CloudProvider
    ) -> (action: FileDifference.SyncAction, description: String) {
        let leftDate = left.modificationDate ?? Date.distantPast
        let rightDate = right.modificationDate ?? Date.distantPast

        if abs(leftDate.timeIntervalSince(rightDate)) > 1 {
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
                    isDirectory: node.isDirectory
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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return [:]
        }
        
        var result: [String: FileInfo] = [:]
        var basePath = url.path
        if fileManager is FileManager {
            // The real enumerator yields canonical, symlink-resolved URLs (/private/var/...), so a
            // root given via a symlinked path (/var/..., a linked user folder) would never match the
            // prefix trim below and every key would come back near-absolute. Canonicalize the base
            // to match. resolvingSymlinksInPath can't be used here: it deliberately strips /private.
            // Mock file managers echo back the URLs they were given, so they keep the raw base.
            if let canonicalPath = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
                basePath = canonicalPath
            }
        }
        
        for case let fileURL as URL in enumerator {
            do {
                var isReg = true
                var modDate: Date? = nil
                var size: Int? = nil
                var isDir = false
                
                if let _ = fileManager as? FileManager {
                    let resourceValues = try fileURL.resourceValues(forKeys: keySet)
                    isReg = resourceValues.isRegularFile ?? true
                    modDate = resourceValues.contentModificationDate
                    size = resourceValues.fileSize
                    isDir = resourceValues.isDirectory ?? false
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

                    result[relativePath] = FileInfo(
                        url: fileURL, 
                        modificationDate: modDate,
                        fileSize: size,
                        isDirectory: isDir
                    )
                }
            } catch {
                let msg = "Error reading resource values for \(fileURL): \(error)"
                Task { @MainActor in Logger.shared.error(msg) }
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
    /// - Returns: Sorted array of `FileDifference` for UI and sync actions.
    public static func computeDifferences(
        left: CloudProvider,
        leftURL: URL,
        right: CloudProvider,
        rightURL: URL,
        leftFilesInfo: [String: FileInfo],
        rightFilesInfo: [String: FileInfo],
        caseInsensitive: Bool = false
    ) -> [FileDifference] {
        var diffs: [FileDifference] = []
        // Folders that exist on one side only, per direction. Their descendants are collapsed
        // into the folder's own entry below (a folder copy is recursive, so the descendants
        // carry no independent action).
        var missingOnRightDirs = Set<String>()
        var missingOnLeftDirs = Set<String>()

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
            if let rightFile = rightFilesInfo[rightKey] {
                let caseNote = namesDifferOnlyByCase ? " (names differ only by case)" : ""
                // exists in both, compare dates and sizes in RAM
                if leftFile.isDirectory != rightFile.isDirectory {
                    let resolution = resolveTypeMismatch(
                        left: leftFile,
                        leftProvider: left,
                        right: rightFile,
                        rightProvider: right
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
                    dateDiffers = abs(lD.timeIntervalSince(rD)) > 1
                } else {
                    dateDiffers = false // Can't reliably compare dates, fallback to size
                }
                
                let sizeDiffers = (leftFile.fileSize != rightFile.fileSize) && (leftFile.fileSize != nil || rightFile.fileSize != nil)
                
                if dateDiffers || sizeDiffers { // 1 second tolerance or size mismatch
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
            if leftFilesInfo[relativePath] == nil && !caseVariantMatchedRightKeys.contains(relativePath) {
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
        
        let result = collapseMissingFolderContents(
            diffs,
            missingOnRightDirs: missingOnRightDirs,
            missingOnLeftDirs: missingOnLeftDirs
        ).sorted { $0.relativePath < $1.relativePath }
        Task { @MainActor in
            Logger.shared.debug("Computed differences: \(result.count) items requiring action.")
        }
        return result
    }

    /// Drops differences that live inside a folder already reported missing on the same side:
    /// copying that folder is recursive, so its contents sync with the folder entry itself.
    /// Listing them separately double-copies during bulk sync and leaves stale rows (with
    /// spurious overwrite prompts) after the folder row is synced. The surviving folder entry
    /// gets `enclosedItemCount` so the UI can still say how much it carries.
    private static func collapseMissingFolderContents(
        _ diffs: [FileDifference],
        missingOnRightDirs: Set<String>,
        missingOnLeftDirs: Set<String>
    ) -> [FileDifference] {
        guard !missingOnRightDirs.isEmpty || !missingOnLeftDirs.isEmpty else { return diffs }

        // Top-most missing ancestor folder → number of items collapsed into it.
        var enclosedCounts: [String: Int] = [:]
        var kept: [FileDifference] = []
        kept.reserveCapacity(diffs.count)

        for diff in diffs {
            let dirs: Set<String>
            switch diff.type {
            case .missingOnRight: dirs = missingOnRightDirs
            case .missingOnLeft: dirs = missingOnLeftDirs
            case .differentDates:
                // Items present on both sides can't sit under a folder that's missing on either.
                kept.append(diff)
                continue
            }
            if let ancestor = topMostAncestor(of: diff.relativePath, in: dirs) {
                enclosedCounts[ancestor, default: 0] += 1
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
