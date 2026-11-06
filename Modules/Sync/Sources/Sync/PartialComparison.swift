import Foundation

/// A comparison that covered only part of a side, and so reports fewer differences than exist:
/// the Differences table has to say so.
///
/// A side's root is marked unexplored when it couldn't be listed (permission denied) or when the
/// walk stopped at `FileSyncManager.paneNodeBudget` entries. `FileDiffEngine.compare` then mints no
/// Missing row against that side, since it can't tell an absence from something it never read.
/// The table looks normal and its count reads as a total when it is only a floor, so the banner
/// this type words is the only on-screen sign.
///
/// Pure and `Sendable` so the wording can be asserted without a window, like
/// `SyncOperationAlerts.largeWalkMessage`.
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

    /// Built from the comparison maps, off the `""` key that means "this whole side is unknown".
    /// Deliberately not "any directory carries the mark": one locked folder deep in a tree is
    /// common, `compare` already suppresses just the rows under it, and a banner on every such scan
    /// would teach people to ignore it.
    public static func of(left: [String: FileDiffEngine.FileInfo],
                          right: [String: FileDiffEngine.FileInfo]) -> PartialComparison {
        PartialComparison(left: left[""]?.isUnexplored == true,
                          right: right[""]?.isUnexplored == true)
    }

    /// The warm-branch overload: the maps plus each cached tree's provenance. A budget-stopped
    /// pane walk had a readable root, so there is no `""` record; its truncation shows only as
    /// per-directory `isUnexplored` marks, which a locked folder also wears. The walk-stopped bit
    /// tells them apart.
    ///
    /// Both halves are needed: without the map check, a stopped walk whose unexplored folders have
    /// all since been grafted in would banner a complete comparison; without the bit, one locked
    /// folder would banner every scan. This changes the banner only; row suppression stays
    /// per-directory (see `getFilesInDirectory`).
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
    /// Names each side by its source, not "left" or "right", since the panes can be swapped
    /// (`swapPanes` mirrors this value with the providers for the same reason).
    ///
    /// Names both losses: nothing shows as missing on that side, and entries past a node-budget
    /// stop are in no map at all, so they produce no rows in either direction.
    ///
    /// Names no cause: the `""` record is the same for an unlistable root and a stopped walk, so
    /// "too large" would be false for a permission problem. "Not read in full" is true of both.
    public func message(leftName: String, rightName: String) -> String? {
        let names = [left ? leftName : nil, right ? rightName : nil].compactMap { $0 }
        guard !names.isEmpty else { return nil }
        let subject = names.count == 2 ? "\(names[0]) and \(names[1])" : names[0]
        let verb = names.count == 2 ? "were" : "was"
        let side = names.count == 2 ? "either side" : "that side"
        return "\(subject) \(verb) not read in full, so this list is incomplete: "
            + "nothing is reported as missing on \(side), and whatever went unread was not compared."
    }

    /// The headline above it: what is wrong with the number, since the number is what people act on.
    public var title: String { "This comparison is incomplete" }
}
