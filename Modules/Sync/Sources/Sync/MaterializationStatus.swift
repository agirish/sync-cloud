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
    public static func isCloudOnlyIfKnown(atPath path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return isDataless(flags: info.st_flags)
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
    public static func isCloudOnly(atPath path: String) -> Bool {
        isCloudOnlyIfKnown(atPath: path) ?? false
    }

    /// Asks the system to fetch a dataless file's content. Uses the iCloud download API — the one
    /// public, side-effect-free way to materialize on demand — which returns immediately and fetches
    /// in the background. For other File Provider providers there is no public consumer API, so this
    /// throws and the caller should fall back to revealing the item in Finder.
    public static func download(atPath path: String) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
    }
}
