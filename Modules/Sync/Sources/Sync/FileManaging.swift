import Events
//
//  FileManaging.swift
//  SyncCloud
//

import Foundation

/// The `FileManager` primitives the Sync engine uses, so tests can run against an in-memory disk.
public protocol FileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey : Any]
    func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws
    /// Sets `path`'s modification date so it reads back as exactly `date`, as an "Exact match" scan
    /// compares it. `setAttributes` rounds to the microsecond, so the pair would still differ. Does
    /// not follow a symbolic link. The default (every test double) is `setAttributes`.
    func setModificationDate(_ date: Date, ofItemAtPath path: String) throws
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    /// `copyItem(at:to:)` that can be abandoned part-way (see `CopyObserver`). Throws
    /// `CocoaError(.userCancelled)` when `observer.shouldContinue` answers false, having removed
    /// what it wrote. The default (every test double) copies whole and checks only before starting.
    func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
    func removeItem(at URL: URL) throws
    /// Atomically installs `stagedURL` (already on the same volume) at `destinationURL`, keeping
    /// any prior item as a sibling named `backupItemName`. Returns the backup's URL, or `nil` when
    /// the destination did not exist. Atomic so a crash mid-replace can't leave the old file in the
    /// Trash and nothing at the destination.
    ///
    /// The result keeps the replaced item's permissions and creation date, as an in-place save wants
    /// (Edit must not strip a script's mode). A sync's Replace wants the opposite:
    /// ``installReplacement(at:withItemAt:backupItemName:)``.
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL?
    /// ``replaceItem(at:withItemAt:backupItemName:)`` whose result is the incoming item, metadata
    /// and all (permissions, creation date, tags), for a copy or move that replaces the destination.
    /// The default merge would keep the old file's mode and dates, so a script made executable at
    /// the source would stay non-executable after every sync. The default (every test double) is
    /// the plain `replaceItem`, so a double that intercepts replaces still sees this one.
    func installReplacement(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL?
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
    /// Whether `url` is a folder whose contents are not on this Mac yet (`SF_DATALESS`, set by a
    /// cloud provider). Listing one asks the provider, which may never answer if it isn't running;
    /// see `FileSyncManager.DatalessFolderReads`. One `stat`, never asks the provider, and follows a
    /// link as the listing would. The default (every test double) is `false`.
    func isDataless(at url: URL) -> Bool
    /// Where `listing(of:)` and `childCount(of:)` ask for a dataless folder's contents: off the
    /// cooperative pool, for at most a deadline, one read per folder. A test disk carries its own,
    /// with a short deadline. The default (every test double) is the app's shared one.
    var datalessFolderReads: FileSyncManager.DatalessFolderReads { get }
}

// Convenience overloads, and the defaults every test double inherits.
extension FileManaging {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }

    public func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws {
        guard observer.shouldContinue() else { throw CocoaError(.userCancelled, userInfo: [NSFilePathErrorKey: srcURL.path]) }
        try copyItem(at: srcURL, to: dstURL)
    }

    public func isDataless(at url: URL) -> Bool { false }

    public func setModificationDate(_ date: Date, ofItemAtPath path: String) throws {
        try setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    public func installReplacement(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
    }

    public var datalessFolderReads: FileSyncManager.DatalessFolderReads { .shared }
}

// The real disk.
extension FileManager: FileManaging {
    public func copyItem(at srcURL: URL, to dstURL: URL, observer: CopyObserver) throws {
        try observedCopyItem(at: srcURL, to: dstURL, observer: observer)
    }

    /// `stat`, not `lstat`: a walk lists a folder link's target, so the target's flag says whether
    /// the listing will wait. A failed `stat` answers `false`, and the listing then fails on its own.
    /// The `stat` answers at once even where the listing would hang.
    public func isDataless(at url: URL) -> Bool {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) } ?? -1
        }
        return status == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// `utimensat` to the nanosecond, leaving the access date alone. Foundation reads a date as
    /// `Double(tv_sec - 978307200) + Double(tv_nsec) / 1e9`, so splitting `date` the same way gives
    /// back the same `Date` on the next read. A date within weeks of 2001-01-01 holds more than
    /// nanosecond precision and can come back a hair off.
    public func setModificationDate(_ date: Date, ofItemAtPath path: String) throws {
        let interval = date.timeIntervalSinceReferenceDate
        var seconds = interval.rounded(.down)
        var nanoseconds = ((interval - seconds) * 1e9).rounded()
        if nanoseconds >= 1e9 { seconds += 1; nanoseconds -= 1e9 }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(seconds) + 978_307_200, tv_nsec: Int(nanoseconds))]
        guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
    }

    public func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName, options: [])
    }

    public func installReplacement(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName,
                        options: [.usingNewMetadataOnly])
    }

    private func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String,
                             options metadata: FileManager.ItemReplacementOptions) throws -> URL? {
        // A symbolic link is replaced as the entry it is: `replaceItemAt` refuses a link
        // (`NSCocoaErrorDomain 4`, "doesn't exist"). The link is renamed aside to the backup name
        // (never what it points at), the staged item takes its place, and a failure puts the link
        // back. The destination is briefly absent, but a link holds no data to lose.
        if (try? attributesOfItem(atPath: destinationURL.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
            try moveItem(at: destinationURL, to: backupURL)
            do {
                try moveItem(at: stagedURL, to: destinationURL)
            } catch {
                do {
                    try moveItem(at: backupURL, to: destinationURL)
                } catch let restoreError {
                    // Was silent: the link would sit under its backup name with nothing saying where.
                    Logger.shared.error("Replace: couldn't put the link \(destinationURL.path) back after a failed "
                                        + "replace (\(restoreError.localizedDescription)) — it is now at \(backupURL.path)")
                }
                throw error
            }
            return backupURL
        }
        // `replaceItemAt` needs an existing original; a new destination is a plain rename, with no
        // backup.
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
            options: metadata.union(.withoutDeletingBackupItem)
        )
        // The backup lands in the destination's directory under `backupItemName`.
        let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
        return fileExists(atPath: backupURL.path) ? backupURL : nil
    }
}
