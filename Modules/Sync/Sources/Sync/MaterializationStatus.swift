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
    /// "no answer", which is the truth, and lets that caller decline to record anything.
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
    /// The two-way form, kept for every caller that is deciding whether to READ a file — the badge
    /// memo, `FileContentVerifier`, the duplicate hasher, the row menu's Download item. For all of
    /// them "cannot stat" and "not a placeholder" lead to the same next step: proceed, and let the
    /// open fail if the file is gone. Only the download poll needs the distinction, and it asks
    /// `isCloudOnlyIfKnown` directly.
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
