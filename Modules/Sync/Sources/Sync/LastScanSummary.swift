import Foundation

/// What the last completed Compare scan found, and in which comparison, so Compare doesn't open
/// cold on every launch.
///
/// A summary, never the rows: the lens caches keep inputs, never results. Every Compare row action
/// writes files, and offering "Copy 412 to →" against a days-old scan would be a destructive apply
/// on stale data. A count and a date offer nothing but Scan.
public struct LastScanSummary: Codable, Equatable, Sendable {
    public let date: Date
    public let differenceCount: Int
    /// The comparison this describes. Provider ids, since display names can be renamed in
    /// Settings ▸ Sources, and absolute paths, since one relative path under two roots is two
    /// different comparisons.
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

    /// Whether this summary describes the comparison the panes show now. Without it, moving either
    /// pane would leave a count for folders nobody is looking at, which reads as current. Not
    /// symmetric: A↔B doesn't describe B↔A, because Compare's actions are directional.
    public func describes(leftProviderID: String, leftPath: String,
                          rightProviderID: String, rightPath: String) -> Bool {
        self.leftProviderID == leftProviderID
            && self.rightProviderID == rightProviderID
            && Self.normalized(self.leftPath) == Self.normalized(leftPath)
            && Self.normalized(self.rightPath) == Self.normalized(rightPath)
    }

    /// Trailing separators removed, so a root stored as `~/Docs/` still matches itself: the scan's
    /// `URL(fileURLWithPath:).path` drops the slash and `PaneLogic.fullPath` keeps it.
    ///
    /// String-only, because `standardizingPath` or a `URL` round-trip touches the disk and this runs
    /// in a view body. `!= "/"` keeps the root from trimming to "" without an O(n) `count` per pass.
    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/"), trimmed != "/" { trimmed.removeLast() }
        return trimmed
    }
}
