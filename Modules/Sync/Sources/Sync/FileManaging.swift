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
    func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    /// `copyItem(at:to:)` that can be abandoned part-way — see `CopyObserver`. Throws
    /// `CocoaError(.userCancelled)` when `observer.shouldContinue` answers false, having removed
    /// what it wrote. The default (every test double) copies whole and checks only before starting.
    func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws
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
    /// Whether `url` is a folder whose contents are not on this Mac yet — `SF_DATALESS`, set by a
    /// cloud provider on a folder it has not enumerated to disk. Listing one asks the provider, and
    /// a provider that is not running never answers; see `FileSyncManager.DatalessFolderReads`.
    /// Answering it costs one `stat` and never asks the provider. Follows a symbolic link, as the
    /// listing that would follow does. The default (every test double) is `false`.
    func isDataless(at url: URL) -> Bool
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

    public func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws {
        guard observer.shouldContinue() else { throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: srcURL.path]) }
        try copyItem(at: srcURL, to: dstURL)
    }

    public func isDataless(at url: URL) -> Bool { false }
}

// Ensure the real macOS FileManager strictly conforms to this interface.
extension FileManager: FileManaging {
    public func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws {
        try observedCopyItem(at: srcURL, to: dstURL, observer: observer)
    }

    /// `stat`, not `lstat`: a walk lists a folder link's target, so the target's flag is the one
    /// that says whether the listing will wait. A `stat` that fails answers `false` — the listing
    /// then fails on its own, as it did before this existed. Measured on the two hung `.Trash`
    /// folders: the `stat` answers at once while the listing never does.
    public func isDataless(at url: URL) -> Bool {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        return status == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

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
