import Foundation

/// What the last completed Compare scan found, and which comparison it found it in.
///
/// Compare was the only workspace that opened cold. Duplicates and Organize re-run their scan on
/// open when it cannot cost money, and Storage restores its report — Compare showed *"Nothing
/// scanned yet"* on the default workspace of every launch, however many times it had been scanned.
///
/// **A summary, deliberately not the rows.** Restoring differences would break the rule the lens
/// caches are built on — cache inputs, never restore results — because every action Compare offers
/// against a row writes files, and offering "Copy 412 to →" against a three-day-old world is
/// exactly the destructive apply that rule exists to prevent. A count and a date make no such
/// offer: they say what the last scan found, and the only button is Scan.
public struct LastScanSummary: Codable, Equatable, Sendable {
    public let date: Date
    public let differenceCount: Int
    /// The comparison this describes. Provider **ids** rather than display names, which the user
    /// can rename in Settings ▸ Providers, and absolute scanned paths rather than relative ones,
    /// because the same relative path under two different roots is two different comparisons.
    public let leftProviderID: String
    public let leftPath: String
    public let rightProviderID: String
    public let rightPath: String

    public init(date: Date, differenceCount: Int,
                leftProviderID: String, leftPath: String,
                rightProviderID: String, rightPath: String) {
        self.date = date
        self.differenceCount = differenceCount
        self.leftProviderID = leftProviderID
        self.leftPath = leftPath
        self.rightProviderID = rightProviderID
        self.rightPath = rightPath
    }

    /// Whether this summary describes the comparison the panes are pointed at **now**.
    ///
    /// The gate that keeps the empty state honest. Without it, navigating either pane somewhere
    /// else would leave the card reporting a count for a comparison nobody is looking at — a
    /// number about the wrong folders is worse than no number, because it reads as current.
    ///
    /// Not symmetric: a summary of A↔B does not describe B↔A. The counts would coincide, but the
    /// swap is a different reading of the same pair (what is missing on the *left* is the opposite
    /// question), and Compare's own actions are directional.
    public func describes(leftProviderID: String, leftPath: String,
                          rightProviderID: String, rightPath: String) -> Bool {
        self.leftProviderID == leftProviderID
            && self.rightProviderID == rightProviderID
            && Self.normalized(self.leftPath) == Self.normalized(leftPath)
            && Self.normalized(self.rightPath) == Self.normalized(rightPath)
    }

    /// Trailing separators removed, so the two sides can be produced by different expressions
    /// without a cosmetic difference reading as a different folder.
    ///
    /// A provider path is whatever the user typed into Settings ▸ Providers, trailing slash and
    /// all, and it reaches the scan and the pane through code that normalizes differently — the
    /// scan's `URL(fileURLWithPath:).path` drops a trailing slash and `PaneLogic.fullPath`'s
    /// `appendingPathComponent` does not. Without this, a root stored as `~/Docs/` would compare
    /// unequal to itself and the summary would silently never show.
    ///
    /// Deliberately string-only: no `standardizingPath`, no `URL` round-trip. Both of those touch
    /// the file system to resolve symlinks, and this runs while a view body is being evaluated.
    ///
    /// `trimmed != "/"` rather than a length check: `String.count` walks the whole string, so a
    /// `count > 1` guard inside the loop costs O(n) per iteration to answer a question `"/"` answers
    /// in O(1). It reads the same and keeps the root from being trimmed to "".
    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/"), trimmed != "/" { trimmed.removeLast() }
        return trimmed
    }
}
