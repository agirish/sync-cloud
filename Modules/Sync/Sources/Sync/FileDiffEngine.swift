import Foundation
import Events

/// A stateless engine responsible for computing synchronization differences between two directories.
/// Extracts heavy O(N) file system scanning and Date comparison logic out of the UI-bound SyncManager.
public struct FileDiffEngine {
    
    public struct FileInfo: Sendable {
        public let url: URL
        public let modificationDate: Date?
        public let fileSize: Int?
        public let isDirectory: Bool
    }
    
    /// Recursively scans a directory and caches the .contentModificationDateKey for high-performance O(1) diffing.
    public static func getFilesInDirectory(_ url: URL, fileManager: FileManaging = FileManager.default) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
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
                if sourceFile.isDirectory != destFile.isDirectory {
                     // Type mismatch (file vs folder)
                     diffs.append(FileDifference(
                        relativePath: relativePath,
                        sourceItemPath: sourceFile.url.path,
                        destinationItemPath: destFile.url.path,
                        type: .differentDates, // reusing for simplicity, UI will show names
                        action: .copyToDestination,
                        description: "Type mismatch (file vs folder)"
                    ))
                    continue
                }

                if sourceFile.isDirectory { continue } // Folders both exist, no "difference" in content but recursive scan will handle children

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
        
        return diffs.sorted { $0.relativePath < $1.relativePath }
    }
}
