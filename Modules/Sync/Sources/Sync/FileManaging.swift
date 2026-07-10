//
//  FileManaging.swift
//  SyncCloud
//

import Foundation

/// A protocol declaring the `FileManager` primitives required by the Sync engine,
/// enabling fully decoupled RAM-based Unit Testing without mutating the physical disk.
public protocol FileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any]
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
    func removeItem(at URL: URL) throws
    /// Atomically installs `stagedURL` (which must already be on the same volume as
    /// `destinationURL`) at `destinationURL`, preserving any prior item there as a sibling named
    /// `backupItemName`. Returns the backup's URL, or `nil` when the destination did not exist.
    ///
    /// The atomicity is the whole point: unlike trash-then-rename, the destination path is never
    /// momentarily absent, so a crash or forced quit mid-replace cannot strand the old file in
    /// Trash with nothing at the destination.
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL?
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
}

// Swift Protocols don't allow default implementations directly in the requirement, 
// so we provide an extension to fulfill the exact `FileManager` call-stubs.
extension FileManaging {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }
    
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: nil)
    }
}

// Ensure the real macOS FileManager strictly conforms to this interface.
extension FileManager: FileManaging {
    public func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        // `replaceItemAt` is defined only when the original exists; a brand-new destination is a
        // plain rename — no backup, and no replacement window to close.
        guard fileExists(atPath: destinationURL.path) else {
            try moveItem(at: stagedURL, to: destinationURL)
            return nil
        }
        // `.withoutDeletingBackupItem` keeps the prior destination as a sibling backup so an
        // overwrite stays recoverable; the caller decides whether to Trash or keep it.
        _ = try replaceItemAt(
            destinationURL,
            withItemAt: stagedURL,
            backupItemName: backupItemName,
            options: [.withoutDeletingBackupItem]
        )
        // The backup lands in the destination's directory under `backupItemName`.
        let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
        return fileExists(atPath: backupURL.path) ? backupURL : nil
    }
}
