import Foundation
import Events

/// A stateless engine responsible for computing synchronization differences between two directories.
/// Extracts heavy O(N) file system scanning and Date comparison logic out of the UI-bound SyncManager.
public struct FileDiffEngine {
    
    public struct FileInfo: Sendable {
        public let url: URL
        public let modificationDate: Date?
        public let fileSize: Int?
    }
    
    /// Recursively scans a directory and caches the .contentModificationDateKey for high-performance O(1) diffing.
    public static func getFilesInDirectory(_ url: URL) throws -> [String: FileInfo] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return [:]
        }
        
        var result: [String: FileInfo] = [:]
        let basePath = url.path
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
                if let isRegularFile = resourceValues.isRegularFile, isRegularFile {
                    var relativePath = fileURL.path
                    if relativePath.hasPrefix(basePath) {
                        relativePath = String(relativePath.dropFirst(basePath.count))
                    }
                    if relativePath.hasPrefix("/") {
                        relativePath.removeFirst()
                    }
                    
                    result[relativePath] = FileInfo(
                        url: fileURL, 
                        modificationDate: resourceValues.contentModificationDate,
                        fileSize: resourceValues.fileSize
                    )
                }
            } catch {
                let msg = "Error reading resource values for \(fileURL): \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
            }
        }
        
        return result
    }
    
    /// Computes the exact synchronization differences between a Source and Destination dictionary.
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
                if let sourceDate = sourceFile.modificationDate,
                   let destDate = destFile.modificationDate {
                    
                    let dateDiffers = abs(sourceDate.timeIntervalSince(destDate)) > 1
                    let sizeDiffers = (sourceFile.fileSize != destFile.fileSize) && (sourceFile.fileSize != nil)
                    
                    if dateDiffers || sizeDiffers { // 1 second tolerance or size mismatch
                        if sourceDate > destDate || (sizeDiffers && !dateDiffers) {
                            diffs.append(FileDifference(
                                relativePath: relativePath,
                                sourceItemPath: sourceFile.url.path,
                                destinationItemPath: destFile.url.path,
                                type: .differentDates,
                                action: .copyToDestination,
                                description: sizeDiffers && !dateDiffers ? "Sizes differ" : "\(source.displayName) file is newer"
                            ))
                        } else {
                            diffs.append(FileDifference(
                                relativePath: relativePath,
                                sourceItemPath: sourceFile.url.path,
                                destinationItemPath: destFile.url.path,
                                type: .differentDates,
                                action: .copyToSource,
                                description: "\(destination.displayName) file is newer"
                            ))
                        }
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
                    description: "Missing in \(destination.displayName)"
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
                    description: "Missing in \(source.displayName)"
                ))
            }
        }
        
        return diffs.sorted { $0.relativePath < $1.relativePath }
    }
}
