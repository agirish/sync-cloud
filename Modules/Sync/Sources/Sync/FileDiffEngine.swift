import Foundation
import Events

/// A stateless engine responsible for computing synchronization differences between two directories.
/// Extracts heavy O(N) file system scanning and Date comparison logic out of the UI-bound SyncManager.
public struct FileDiffEngine {
    
    /// Lightweight metadata structure for individual files used during differential comparison.
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
        source: FileInfo,
        sourceProvider: CloudProvider,
        destination: FileInfo,
        destinationProvider: CloudProvider
    ) -> (action: FileDifference.SyncAction, description: String) {
        let sourceDate = source.modificationDate ?? Date.distantPast
        let destinationDate = destination.modificationDate ?? Date.distantPast

        if abs(sourceDate.timeIntervalSince(destinationDate)) > 1 {
            if sourceDate > destinationDate {
                return (.copyToDestination, "\(sourceProvider.displayName) item is newer (type mismatch)")
            }
            return (.copyToSource, "\(destinationProvider.displayName) item is newer (type mismatch)")
        }

        if source.isDirectory {
            return (.copyToDestination, "Type mismatch; defaulting to the folder from \(sourceProvider.displayName)")
        }

        return (.copyToSource, "Type mismatch; defaulting to the folder from \(destinationProvider.displayName)")
    }
    
    /// Recursively scans a directory and aggregates `FileInfo` objects in a dictionary keyed by relative path.
    /// Uses high-performance resource value fetching in standard production, and fallback attributes for mocks.
    /// - Parameters:
    ///   - url: The root directory URL to scan.
    ///   - showHidden: Whether to include files starting with '.' (e.g. .DS_Store).
    ///   - fileManager: The file manager to use for scanning (supports injected mocks).
    /// - Returns: A map of relative paths to `FileInfo` metadata.
    public static func getFilesInDirectory(_ url: URL, showHidden: Bool = false, fileManager: FileManaging = FileManager.default) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: options) else {
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
    
    /// Computes the exact synchronization differences between Source and Destination file sets.
    /// Resolves discrepancies by comparing modification dates and file sizes.
    /// - Parameters:
    ///   - source: The source cloud provider model.
    ///   - sourceURL: The absolute URL to the source root.
    ///   - destination: The destination cloud provider model.
    ///   - destinationURL: The absolute URL to the destination root.
    ///   - sourceFilesInfo: Pre-scanned metadata for the source pane.
    ///   - destinationFilesInfo: Pre-scanned metadata for the destination pane.
    /// - Returns: A sorted list of `FileDifference` objects ready for UI display and synchronization.
    public static func computeDifferences(
        source: CloudProvider,
        sourceURL: URL,
        destination: CloudProvider,
        destinationURL: URL,
        sourceFilesInfo: [String: FileInfo],
        destinationFilesInfo: [String: FileInfo]
    ) -> [FileDifference] {
        var diffs: [FileDifference] = []
        
        // 1. Files in source but not in destination (or compare if exists)
        for (relativePath, sourceFile) in sourceFilesInfo {
            if let destFile = destinationFilesInfo[relativePath] {
                // exists in both, compare dates and sizes in RAM
                if sourceFile.isDirectory != destFile.isDirectory {
                    let resolution = resolveTypeMismatch(
                        source: sourceFile,
                        sourceProvider: source,
                        destination: destFile,
                        destinationProvider: destination
                    )
                    diffs.append(FileDifference(
                        relativePath: relativePath,
                        sourceItemPath: sourceFile.url.path,
                        destinationItemPath: destFile.url.path,
                        type: .differentDates,
                        action: resolution.action,
                        description: resolution.description
                    ))
                    continue
                }

                if sourceFile.isDirectory { continue } // Folders both exist, no "difference" in content but recursive scan will handle children
                
                let sourceDate = sourceFile.modificationDate
                let destDate = destFile.modificationDate
                
                let dateDiffers: Bool
                if let sD = sourceDate, let dD = destDate {
                    dateDiffers = abs(sD.timeIntervalSince(dD)) > 1
                } else {
                    dateDiffers = false // Can't reliably compare dates, fallback to size
                }
                
                let sizeDiffers = (sourceFile.fileSize != destFile.fileSize) && (sourceFile.fileSize != nil || destFile.fileSize != nil)
                
                if dateDiffers || sizeDiffers { // 1 second tolerance or size mismatch
                    let sourceIsNewer = (sourceDate ?? Date.distantPast) > (destDate ?? Date.distantPast)
                    
                    if sourceIsNewer || (sizeDiffers && !dateDiffers && sourceDate == nil && destDate == nil) {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            sourceItemPath: sourceFile.url.path,
                            destinationItemPath: destFile.url.path,
                            type: .differentDates,
                            action: .copyToDestination,
                            description: sizeDiffers && !dateDiffers ? "Sizes differ" : "\(source.displayName) file is newer"
                        ))
                    } else if !sourceIsNewer && dateDiffers {
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            sourceItemPath: sourceFile.url.path,
                            destinationItemPath: destFile.url.path,
                            type: .differentDates,
                            action: .copyToSource,
                            description: "\(destination.displayName) file is newer"
                        ))
                    } else {
                        // Fallback if dates are identical/missing but sizes differ: default to source as truth
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            sourceItemPath: sourceFile.url.path,
                            destinationItemPath: destFile.url.path,
                            type: .differentDates,
                            action: .copyToDestination,
                            description: "Sizes differ"
                        ))
                    }
                }
            } else {
                // missing in destination
                let destExpectedPath = destinationURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    sourceItemPath: sourceFile.url.path,
                    destinationItemPath: destExpectedPath,
                    type: .missingInDestination,
                    action: .copyToDestination,
                    description: sourceFile.isDirectory ? "Folder missing in \(destination.displayName)" : "Missing in \(destination.displayName)"
                ))
            }
        }
        
        // 2. Files in destination but not in source
        for (relativePath, destFile) in destinationFilesInfo {
            if sourceFilesInfo[relativePath] == nil {
                let sourceExpectedPath = sourceURL.appendingPathComponent(relativePath).path
                diffs.append(FileDifference(
                    relativePath: relativePath,
                    sourceItemPath: sourceExpectedPath,
                    destinationItemPath: destFile.url.path,
                    type: .missingInSource,
                    action: .copyToSource,
                    description: destFile.isDirectory ? "Folder missing in \(source.displayName)" : "Missing in \(source.displayName)"
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
