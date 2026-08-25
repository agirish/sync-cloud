import Foundation

/// **A comparison that covered only part of a side**, and therefore reports fewer differences than
/// exist — the fact the Differences table has to say out loud.
///
/// Two causes, one consequence. A side's root is marked unexplored when it could not be listed at
/// all (permission denied), and — since the walk was bounded in v4.4 — when the walk stopped at
/// `FileSyncManager.paneNodeBudget` entries. `FileDiffEngine.compare` reads that mark as "this
/// side's view is unknown" and mints **no Missing row against it**, which is the only honest
/// treatment: it cannot tell an absence from something it never read.
///
/// **The consequence is invisible in the result.** Every "missing on left" row disappears when the
/// left is partial, and what remains is a normal-looking table with a normal-looking count. Nothing
/// on screen said so — the only signal was a `warning` in `~/sync-cloud.log`, which is not where
/// anyone is looking when they press Copy. A number that is quietly a floor reads as a total, and
/// this app's whole job is telling someone what differs.
///
/// The wording lives here, pure and `Sendable`, so it can be asserted without a window — the same
/// reason `SyncOperationAlerts.largeWalkMessage` was split out of its alert.
public struct PartialComparison: Equatable, Sendable {
    /// Whether the left side's root came back unread — wholly, not one folder inside it.
    public let left: Bool
    public let right: Bool

    public static let complete = PartialComparison(left: false, right: false)

    public init(left: Bool, right: Bool) {
        self.left = left
        self.right = right
    }

    public var isComplete: Bool { !left && !right }

    /// **Built from the comparison maps**, off the one key that means "this whole side is unknown".
    ///
    /// Deliberately NOT "does any directory carry the mark": an ordinary unreadable folder deep in
    /// a tree is common, and `compare` already suppresses exactly the rows under it and nothing
    /// else. That is precise, and a banner over every scan of a disk with one locked folder in it
    /// is the kind of warning people learn to stop reading. Only the whole-side case loses rows the
    /// user has no other way to find out about.
    public static func of(left: [String: FileDiffEngine.FileInfo],
                          right: [String: FileDiffEngine.FileInfo]) -> PartialComparison {
        PartialComparison(left: left[""]?.isUnexplored == true,
                          right: right[""]?.isUnexplored == true)
    }

    /// What the banner reads, or nil when the comparison was complete.
    ///
    /// Names the side by its **source**, not by "left" and "right": the panes can be swapped, and
    /// the sentence has to survive being read a minute later.
    public func message(leftName: String, rightName: String) -> String? {
        let names = [left ? leftName : nil, right ? rightName : nil].compactMap { $0 }
        guard !names.isEmpty else { return nil }
        let subject = names.count == 2 ? "\(names[0]) and \(names[1])" : names[0]
        let verb = names.count == 2 ? "were" : "was"
        return "\(subject) \(verb) too large to read in full, so anything present only on "
            + (names.count == 2 ? "one of them" : "the other side")
            + " is not listed here."
    }

    /// The headline above it. One sentence, and it says what is wrong with the NUMBER, because the
    /// number is what someone acts on.
    public var title: String { "This comparison is incomplete" }
}
