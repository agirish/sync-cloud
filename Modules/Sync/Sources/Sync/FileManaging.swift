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
    /// Sets `path`'s modification date so that it reads back as exactly `date` — the write a date
    /// match needs, where a scan at the "Exact match" tolerance compares the two dates exactly.
    /// `setAttributes` rounds to the microsecond, so a date set through it reads back up to 6e-7 s
    /// off and the pair still differs. Does not follow a symbolic link. The default (every test
    /// double) is `setAttributes`, which stores the `Date` as given.
    func setModificationDate(_ date: Date, ofItemAtPath path: String) throws
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
    ///
    /// **The result keeps the REPLACED item's permissions and creation date** (macOS's default
    /// merge), which is what an in-place save wants: Edit saving a script must not strip the mode
    /// the user gave it. A sync's Replace wants the opposite — ``installReplacement(at:withItemAt:backupItemName:)``.
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL?
    /// ``replaceItem(at:withItemAt:backupItemName:)`` whose result is the INCOMING item, metadata
    /// and all — its permissions, creation date and tags — for a copy or move that replaces what was
    /// at the destination (FR32).
    ///
    /// Measured with `replaceItemAt`'s default merge: a 0755 script replacing a 0600 one landed as
    /// 0600, with the old file's 2001 creation date, while its Finder tags came from the new one —
    /// so a script made executable at the source stayed non-executable after every sync, and a
    /// compare had no way to see why. `.usingNewMetadataOnly` lands it as 0755 with the source's
    /// own dates. The default (every test double) is the plain `replaceItem`, so a double that
    /// intercepts replaces still sees this one.
    func installReplacement(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL?
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator?
    /// Whether `url` is a folder whose contents are not on this Mac yet — `SF_DATALESS`, set by a
    /// cloud provider on a folder it has not enumerated to disk. Listing one asks the provider, and
    /// a provider that is not running never answers; see `FileSyncManager.DatalessFolderReads`.
    /// Answering it costs one `stat` and never asks the provider. Follows a symbolic link, as the
    /// listing that would follow does. The default (every test double) is `false`.
    func isDataless(at url: URL) -> Bool
    /// Where `listing(of:)` and `childCount(of:)` ask for a dataless folder's contents — off the
    /// cooperative pool, for at most a deadline, one read per folder. The app's shared one; a test
    /// disk carries its own, with a short deadline. The default (every test double) is the shared one.
    var datalessFolderReads: FileSyncManager.DatalessFolderReads { get }
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

    public func setModificationDate(_ date: Date, ofItemAtPath path: String) throws {
        try setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    public func installReplacement(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
        try replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
    }

    public var datalessFolderReads: FileSyncManager.DatalessFolderReads { .shared }
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

    /// `utimensat` to the nanosecond, the access date left alone. Foundation reads a date as
    /// `Double(tv_sec - 978307200) + Double(tv_nsec) / 1e9` since the reference date, so splitting
    /// `date` the same way and rounding to the nanosecond gives back the very `Date` on the next
    /// read — measured on every one of 20,000 random dates past 2001-02 (a date within weeks of
    /// 2001-01-01 carries more precision than a nanosecond and can come back a hair off).
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
            options: metadata.union(.withoutDeletingBackupItem)
        )
        // The backup lands in the destination's directory under `backupItemName`.
        let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(backupItemName)
        return fileExists(atPath: backupURL.path) ? backupURL : nil
    }
}
