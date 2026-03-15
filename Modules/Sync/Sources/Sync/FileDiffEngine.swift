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
    
    /// Recursively scans a directory and aggregates `FileInfo` objects in a dictionary keyed by relative path.
    /// Uses high-performance resource value fetching in standard production, and fallback attributes for mocks.
    /// - Parameters:
    ///   - url: The root directory URL to scan.
    ///   - fileManager: The file manager to use for scanning (supports injected mocks).
    /// - Returns: A map of relative paths to `FileInfo` metadata.
    public static func getFilesInDirectory(_ url: URL, fileManager: FileManaging = FileManager.default) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return [:]
        }
        
        var result: [String: FileInfo] = [:]
        let basePath = url.path
        
        for case let fileURL as URL in enumerator {
            do {
                var isReg = true
                var modDate: Date? = nil
                var size: Int? = nil
                var isDir = false
                
                if let _ = fileManager as? FileManager {
                    let resourceValues = try fileURL.resourceValues(forKeys: Set(keys + [.isDirectoryKey]))
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
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
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
    /// - Returns: Sorted array of `FileDifference` for UI and sync actions.
    public static func computeDifferences(
        left: CloudProvider,
        leftURL: URL,
        right: CloudProvider,
        rightURL: URL,
        leftFilesInfo: [String: FileInfo],
        rightFilesInfo: [String: FileInfo]
    ) -> [FileDifference] {
        var diffs: [FileDifference] = []
        
        // 1. Files on left but not on right (or compare if exists)
        for (relativePath, leftFile) in leftFilesInfo {
            if let rightFile = rightFilesInfo[relativePath] {
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
                        description: resolution.description,
                        leftFileSize: leftFile.fileSize,
                        rightFileSize: rightFile.fileSize
                    ))
                    continue
                }

                if leftFile.isDirectory { continue } // Folders both exist, no "difference" in content but recursive scan will handle children
                
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
                            description: sizeDiffers && !dateDiffers ? "Sizes differ" : "\(left.displayName) file is newer",
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
                            description: "\(right.displayName) file is newer",
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
                            description: "Sizes differ",
                            leftFileSize: leftFile.fileSize,
                            rightFileSize: rightFile.fileSize
                        ))
                    }
                }
            } else {
                // missing on right
                let rightExpectedPath = rightURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    leftItemPath: leftFile.url.path,
                    rightItemPath: rightExpectedPath,
                    type: .missingOnRight,
                    action: .copyToRight,
                    description: leftFile.isDirectory ? "Folder missing on right (\(right.displayName))" : "Missing on right (\(right.displayName))"
                ))
            }
        }
        
        // 2. Files on right but not on left
        for (relativePath, rightFile) in rightFilesInfo {
            if leftFilesInfo[relativePath] == nil {
                let leftExpectedPath = leftURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    leftItemPath: leftExpectedPath,
                    rightItemPath: rightFile.url.path,
                    type: .missingOnLeft,
                    action: .copyToLeft,
                    description: rightFile.isDirectory ? "Folder missing on left (\(left.displayName))" : "Missing on left (\(left.displayName))"
                ))
            }
        }
        
        let result = diffs.sorted { $0.relativePath < $1.relativePath }
        Task { @MainActor in 
            Logger.shared.debug("Computed differences: \(result.count) items requiring action.")
        }
        return result
    }
}
