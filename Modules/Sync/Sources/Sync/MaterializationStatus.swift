import Foundation

/// Detects and materializes "dataless" cloud files — File Provider placeholders whose content lives
/// on the provider, not on disk (iCloud Drive, Dropbox, Google Drive, OneDrive, Box under
/// `~/Library/CloudStorage`). The signal is the BSD `SF_DATALESS` file flag, read with `lstat`: a
/// metadata-only call that does NOT fetch the file (opening or reading it would). Kept pure and
/// nonisolated so the flag math is unit-tested and the lstat can run off the main thread.
public enum MaterializationStatus {
    /// `SF_DATALESS` from `<sys/stat.h>` — set when a file's content isn't present locally. Defined
    /// here because the constant isn't surfaced in the Swift `Darwin` overlay.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// Whether a stat's `st_flags` marks the file dataless (cloud-only).
    public static func isDataless(flags: UInt32) -> Bool {
        flags & datalessFlag != 0
    }

    /// One file's `st_flags`, or nil when the path cannot be statted. The seam a test substitutes,
    /// and deliberately the syscall itself: only a File Provider sets `SF_DATALESS` (`chflags`
    /// refuses it to non-root), so this is the one part that can't be staged, and everything built
    /// on it still runs as in production.
    public typealias StatFlags = @Sendable (String) -> UInt32?

    /// The real `lstat`: metadata only, so it never fetches the file's content.
    public static let realStatFlags: StatFlags = { path in
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_flags
    }

    /// True when the file at `path` is a cloud-only placeholder, false for anything without the flag
    /// (ordinary local files, directories), and nil when the path cannot be statted at all.
    ///
    /// Three-way because "not dataless" and "not there" are opposite facts: a download poll would
    /// read a bare `false` for a deleted file as "landed" and memoize local content for a path with
    /// no file. Used by the two callers that write into the process-wide badge memo (the download
    /// poll and the memo's own stat); everything else takes the two-way form below. One `lstat`.
    public static func isCloudOnlyIfKnown(atPath path: String,
                                          statFlags: StatFlags = realStatFlags) -> Bool? {
        guard let flags = statFlags(path) else { return nil }
        return isDataless(flags: flags)
    }

    /// True when the file at `path` is a cloud-only placeholder. False on any stat error and for
    /// anything without the flag (ordinary local files, directories).
    ///
    /// For callers where "cannot stat" and "not a placeholder" lead to the same next step: proceed,
    /// and let what comes next fail on its own. `FileContentVerifier.hashOutcome` (and the duplicate
    /// hasher through it) skips a placeholder rather than fetch it; `FileTreeView`'s row menu
    /// decides whether to show Download; `ColumnPreviewProbe.read` pairs it with an existence check,
    /// so an unstattable path reads as `.missing`.
    ///
    /// Where a non-answer must not be recorded as a fact, ask `isCloudOnlyIfKnown`:
    /// `CloudDownloadPoll.run` asks whether content has arrived, and `CloudOnlyBadgeCache` declines
    /// to memoize a failed stat.
    public static func isCloudOnly(atPath path: String,
                                   statFlags: StatFlags = realStatFlags) -> Bool {
        isCloudOnlyIfKnown(atPath: path, statFlags: statFlags) ?? false
    }

    /// The file a door should ask about: `path` itself, or the file a symbolic link finally points
    /// to. The predicates above ask about the link itself (`lstat` doesn't follow the last
    /// component), and a link is always local, so a door about to read a link to a cloud-only file
    /// would fetch it unasked. Such doors ask here first; a row's badge does not.
    ///
    /// Only a path ending in a link is resolved: `lstat` already follows folder links higher up, and
    /// other paths stay as spelled so callers' comparisons (`/var` vs `/private/var`) hold. A
    /// dangling link answers itself, so the read fails honestly. One `lstat`, plus resolution for a
    /// link.
    public static func linkTarget(of path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Asks the system to fetch a dataless file's content and returns at once. Works beyond iCloud
    /// (a Google Drive placeholder downloads too; Dropbox and OneDrive are untested). When it
    /// throws, callers fall back to revealing the item in Finder.
    ///
    /// **Read the result with a fresh URL**: `URL` caches resource values, so polling
    /// `ubiquitousItemDownloadingStatus` on the same instance keeps saying "not downloaded". A link
    /// is downloaded as its target (``linkTarget(of:)``).
    public static func download(atPath path: String) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: linkTarget(of: path)))
    }

    // MARK: - A folder's Download All

    /// Whether `path` is inside a cloud provider's folder (`~/Library/CloudStorage/<provider>`, an
    /// iCloud container, or an iCloud-synced `~/Desktop` / `~/Documents`), where a folder is offered
    /// Download All. Path arithmetic plus at most one `getxattr`, since a row's menu asks on every
    /// render; whether the folder holds anything cloud-only would take a walk.
    public static func isInCloudLocation(_ path: String, home: String = NSHomeDirectory(),
                                         domainOf: KeepDownloaded.DomainOf = KeepDownloaded.realDomainOf) -> Bool {
        KeepDownloaded.descendant(path, of: home + "/Library/CloudStorage") != nil
            || KeepDownloaded.iCloudRoot(containing: path, home: home, domainOf: domainOf) != nil
    }

    /// What one Download All asked for.
    public struct FolderDownload: Equatable, Sendable {
        /// Cloud-only files whose download was requested.
        public let requested: [String]
        /// Cloud-only files the provider refused to download.
        public let refused: [String]
        /// Folders the walk could not read, so nothing under them was asked for.
        public let unreadable: Int

        public init(requested: [String], refused: [String], unreadable: Int) {
            self.requested = requested
            self.refused = refused
            self.unreadable = unreadable
        }
    }

    /// Requests every cloud-only file at any depth below the folder at `path`. A walk, because
    /// `startDownloadingUbiquitousItem` on a cloud-only folder downloads nothing in it.
    ///
    /// **Blocks its thread; call it off the cooperative pool.** The walk is
    /// `FileManaging.listing(of:)`, so each cloud-only folder is read through `DatalessFolderReads`
    /// within its deadline; one that never answers is counted in `unreadable`, never a hung walk.
    /// Listing a cloud-only folder brings its contents on disk, so every level is reached. Links
    /// are never followed, so nothing outside the folder is fetched.
    public static func downloadContents(
        ofFolder path: String,
        using disk: FileManaging = FileManager.default,
        statFlags: StatFlags = realStatFlags,
        download: (String) throws -> Void = { try MaterializationStatus.download(atPath: $0) }
    ) -> FolderDownload {
        let listing = disk.listing(of: URL(fileURLWithPath: path, isDirectory: true), options: [])
        var requested: [String] = []
        var refused: [String] = []
        for url in listing.urls where !url.hasDirectoryPath && isCloudOnly(atPath: url.path, statFlags: statFlags) {
            do {
                try download(url.path)
                requested.append(url.path)
            } catch {
                refused.append(url.path)
            }
        }
        let unreadable = listing.outcome == .unreadable ? 1 : listing.unreadableDescendants.count
        return FolderDownload(requested: requested, refused: refused, unreadable: unreadable)
    }

    /// Download All over a selection: each cloud-only file in `files`, then every cloud-only file
    /// below each of `folders` — ``downloadContents(ofFolder:using:statFlags:download:)`` per
    /// folder, so it blocks its thread the same way.
    ///
    /// Each file is asked for once however the selection overlaps (a file beside its own folder, a
    /// folder beside one inside it). A file is checked as its link target, which is what
    /// ``download(atPath:)`` fetches.
    public static func downloadAll(
        files: [String], folders: [String],
        using disk: FileManaging = FileManager.default,
        statFlags: StatFlags = realStatFlags,
        download: (String) throws -> Void = { try MaterializationStatus.download(atPath: $0) }
    ) -> FolderDownload {
        var asked: Set<String> = []
        var requested: [String] = []
        var refused: [String] = []
        var unreadable = 0
        func ask(_ path: String) {
            guard asked.insert(path).inserted else { return }
            do {
                try download(path)
                requested.append(path)
            } catch {
                refused.append(path)
            }
        }
        for file in files where isCloudOnly(atPath: linkTarget(of: file), statFlags: statFlags) {
            ask(file)
        }
        for folder in folders {
            let below = downloadContents(ofFolder: folder, using: disk, statFlags: statFlags,
                                         download: { _ in })
            // The walk only finds them here; asking goes through `ask`, so overlap is dropped.
            below.requested.forEach(ask)
            unreadable += below.unreadable
        }
        return FolderDownload(requested: requested, refused: refused, unreadable: unreadable)
    }
}
