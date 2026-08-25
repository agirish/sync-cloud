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

    /// The warm-branch overload: the maps **plus each cached tree's provenance**, because a
    /// budget-stopped pane walk is partial coverage the maps alone cannot show. The root was
    /// readable, so no `""` record exists — the truncation lives in per-directory `isUnexplored`
    /// marks that an ordinary locked folder also wears, which is exactly the noise the plain
    /// overload declines to banner on. The provenance bit is what separates them.
    ///
    /// The conjunction is load-bearing in both directions. Without the map check, a stopped walk
    /// whose every unexplored directory has since been grafted in (columns opened them) would
    /// banner a comparison that really did cover everything. Without the bit, a tree with one
    /// locked folder would banner on every scan — the warning people learn to stop reading.
    /// This changes the BANNER only: row suppression stays per-directory on the warm branch,
    /// the deliberate asymmetry `getFilesInDirectory`'s note records.
    public static func of(left: [String: FileDiffEngine.FileInfo],
                          right: [String: FileDiffEngine.FileInfo],
                          leftWalkStopped: Bool,
                          rightWalkStopped: Bool) -> PartialComparison {
        func unexploredSurvives(_ info: [String: FileDiffEngine.FileInfo]) -> Bool {
            info.values.contains { $0.isDirectory && $0.isUnexplored }
        }
        let maps = of(left: left, right: right)
        return PartialComparison(
            left: maps.left || (leftWalkStopped && unexploredSurvives(left)),
            right: maps.right || (rightWalkStopped && unexploredSurvives(right)))
    }

    /// What the banner reads, or nil when the comparison was complete.
    ///
    /// Names the side by its **source**, not by "left" and "right": the panes can be swapped, and
    /// the sentence has to survive being read a minute later. (`swapPanes` mirrors this value with
    /// the providers for the same reason.)
    ///
    /// **Both losses are named, because there are two.** The obvious one is the suppression:
    /// `compare` mints no Missing row against a side whose view is unknown, so nothing shows as
    /// missing there. The other is quieter — a walk stopped by the node budget did not record the
    /// entries past it at all, so those files are in no map, produce no rows in EITHER direction,
    /// and are not compared. An earlier wording named only the first ("anything present only on the
    /// other side is not listed"), which reads as a precise, bounded caveat about one direction and
    /// is a promise the result cannot keep.
    ///
    /// **It names no CAUSE, because this type cannot tell them apart.** `of(left:right:)` reads one
    /// boolean per side off the `""` record, and `FileDiffEngine.compare` mints that same record for
    /// both a root it could not list and a walk it had to stop — deliberately, so the suppression
    /// rule has one input. So the earlier "too large to read in full" was right for the budget case
    /// and false for the permission-denied one, which is the case where the reader most needs to
    /// know it is a permission problem and not a size problem. "Not read in full" is true of both.
    /// Naming the cause needs the cause carried through the record; it is not free, and a wrong
    /// cause is worse than none.
    public func message(leftName: String, rightName: String) -> String? {
        let names = [left ? leftName : nil, right ? rightName : nil].compactMap { $0 }
        guard !names.isEmpty else { return nil }
        let subject = names.count == 2 ? "\(names[0]) and \(names[1])" : names[0]
        let verb = names.count == 2 ? "were" : "was"
        let side = names.count == 2 ? "either side" : "that side"
        return "\(subject) \(verb) not read in full, so this list is incomplete: "
            + "nothing is reported as missing on \(side), and whatever went unread was not compared."
    }

    /// The headline above it. One sentence, and it says what is wrong with the NUMBER, because the
    /// number is what someone acts on.
    public var title: String { "This comparison is incomplete" }
}
