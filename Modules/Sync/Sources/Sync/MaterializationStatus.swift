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

    /// One file's `st_flags`, or nil when the path cannot be statted.
    ///
    /// **This is the seam a test substitutes, and it is deliberately the syscall itself** — the one
    /// thing about a dataless file that cannot be staged. `SF_DATALESS` is an `SF_` flag, which
    /// `chflags` refuses to anyone but root and which only a File Provider ever sets, so a test that
    /// wants to say "this file's content lives on the provider" has no other way to say it. Stubbing
    /// here leaves the whole decision — the flag math, the fold to a Bool, and every predicate built
    /// on it — running as production runs it, rather than replacing the answer wholesale.
    public typealias StatFlags = @Sendable (String) -> UInt32?

    /// The real `lstat`: metadata only, so it never fetches the file's content.
    public static let realStatFlags: StatFlags = { path in
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_flags
    }

    /// True when the file at `path` is a cloud-only placeholder, false for anything without the flag
    /// (ordinary local files, directories) — and **nil when the path cannot be statted at all**.
    ///
    /// The three-way answer exists because "not dataless" and "not there" are opposite facts that
    /// `lstat` reports through the same failure. A download poll asking "has the content landed
    /// yet?" reads a bare `false` as YES: a file deleted mid-download counted as materialized, and
    /// the memo gained an entry asserting local content for a path with no file behind it. Nil says
    /// "no answer", which is the truth, and lets a caller decline to record anything.
    ///
    /// Used by the two callers that WRITE what they learn into the process-wide badge memo — the
    /// download poll and the memo's own stat. Everything else takes the two-way form below.
    ///
    /// One `lstat` — cheap enough to call lazily per visible row.
    public static func isCloudOnlyIfKnown(atPath path: String,
                                          statFlags: StatFlags = realStatFlags) -> Bool? {
        guard let flags = statFlags(path) else { return nil }
        return isDataless(flags: flags)
    }

    /// True when the file at `path` is a cloud-only placeholder. False on any stat error and for
    /// anything without the flag (ordinary local files, directories).
    ///
    /// The two-way form, kept for every caller where **"cannot stat" and "not a placeholder" lead
    /// to the same next step** — don't skip the read, don't offer the download, don't badge it:
    /// proceed, and let whatever comes next fail on its own. That is the property its callers
    /// share, and it is not "deciding whether to read a file": two of the four are not reads at all.
    ///
    /// - `FileContentVerifier.hashOutcome` — a read decision proper: a placeholder is skipped
    ///   rather than force-fetched. Reached only after a successful `fileExists`, so nil here would
    ///   mean a path that vanished in between — and hashing it fails at the open regardless.
    /// - `FileSyncManager+Duplicates.hashFilesCounting` — the duplicate hasher, which routes
    ///   through that same call and inherits the same answer.
    /// - `FileTreeView`'s row context menu — whether to SHOW the Download item, not whether to
    ///   read. A path that cannot be statted is not one to offer a download for, which is what
    ///   `false` produces.
    /// - `ColumnPreviewProbe.read` — CLASSIFICATION, not a read: `ColumnPreviewSource.classify`
    ///   pairs it with an existence check, so an unstattable path lands on `.missing` ("this file
    ///   is no longer here"), which is the honest answer for it.
    ///
    /// The distinction is needed only where a non-answer must not be written down as a fact, and
    /// both such callers ask `isCloudOnlyIfKnown` directly. `CloudDownloadPoll.run` is the sharp
    /// case — it asks "has it ARRIVED yet?", for which the two are opposites. `CloudOnlyBadgeCache`
    /// is the quiet one: it hands its caller the same `false` this would, and differs only in
    /// declining to MEMOIZE it, so the next realization of that row asks the filesystem again
    /// instead of being served what one stat failed to find out.
    public static func isCloudOnly(atPath path: String,
                                   statFlags: StatFlags = realStatFlags) -> Bool {
        isCloudOnlyIfKnown(atPath: path, statFlags: statFlags) ?? false
    }

    /// The file a door should ask about: `path` itself, or — when `path` is a symbolic link — the
    /// file the link finally points to (TE206).
    ///
    /// **Every predicate above asks about the LINK when handed one**, because `lstat` does not
    /// follow the last component of a path, and a link is always local and always tiny. So a link
    /// to a cloud-only PDF read as downloaded, and the door then opened it — which made the
    /// provider fetch the whole file, unasked. That is right for a row's badge, which describes the
    /// row; it is wrong for any door that is about to read what the link points to. Those ask here
    /// first.
    ///
    /// **Only a path that ends in a link is resolved.** A folder link higher up the path is already
    /// followed by the `lstat` itself, and leaving every other path exactly as spelled keeps a
    /// caller's own comparisons (`/var` against `/private/var`) as they were. A link that dangles
    /// answers the link again (measured: Foundation stops at the last component it can resolve),
    /// so the door goes on to fail its read — which is the truth about it.
    ///
    /// One `lstat` for an ordinary file; a link pays the resolution too.
    public static func linkTarget(of path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Asks the system to fetch a dataless file's content, returning at once while it fetches in the
    /// background. `startDownloadingUbiquitousItem` is not iCloud-only: measured 2026-10-25 on a real
    /// Google Drive placeholder, it did not throw and the content was on disk within a second.
    /// Dropbox and OneDrive have not been measured. When it does throw, callers fall back to
    /// revealing the item in Finder.
    ///
    /// **Read the result with a fresh URL.** `URL` caches resource values, so polling
    /// `ubiquitousItemDownloadingStatus` on the same instance kept saying "not downloaded" after the
    /// content had landed; `lstat`'s `SF_DATALESS` flag and a new URL both told the truth.
    ///
    /// A link is downloaded as the file it points to (``linkTarget(of:)``): that is the file every
    /// door that offers Download said was not downloaded.
    public static func download(atPath path: String) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: linkTarget(of: path)))
    }

    // MARK: - A folder's Download All

    /// Whether `path` is inside a cloud provider's folder — `~/Library/CloudStorage/<provider>`,
    /// an iCloud container, or an iCloud-synced `~/Desktop` / `~/Documents` — which is where a folder
    /// is offered Download All. Path arithmetic plus at most one `getxattr`: a row's menu asks it on
    /// every render, and whether the folder holds anything cloud-only would take a walk to know.
    public static func isInCloudLocation(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        KeepDownloaded.descendant(path, of: home + "/Library/CloudStorage") != nil
            || KeepDownloaded.iCloudRoot(containing: path, home: home) != nil
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

    /// Requests every cloud-only file at any depth below the folder at `path`.
    ///
    /// **A walk, because the folder itself cannot be asked.** Measured 2026-10-27 on a cloud-only
    /// iCloud folder: `startDownloadingUbiquitousItem` on the folder returned without throwing and
    /// downloaded nothing in it, ten seconds on.
    ///
    /// **Blocks its thread — call it off the cooperative pool.** The walk is
    /// `FileManaging.listing(of:)`, so a cloud-only folder inside is asked for through
    /// `DatalessFolderReads` — at most their deadline per folder, and a provider that never answers
    /// leaves that folder unexplored and counted in `unreadable`, never a hung walk. Listing a
    /// cloud-only folder is what brings its contents on disk, so every level is reached.
    ///
    /// A link is never followed: the listing does not descend into a linked folder, and a link's
    /// `lstat` never reads cloud-only, so nothing outside the folder is fetched.
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
}
