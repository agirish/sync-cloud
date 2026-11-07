import Foundation
import Sync

/// Per-pane lookup from a tree node's absolute path to its diff status, built once per
/// differences change so `FileRowView` badges rows by dictionary lookup, not by scanning the list.
///
/// Each relative path is joined onto the pane's root (`rootPath`) to key by absolute path, the
/// form of tree node IDs, and re-aligned to the side's real casing via `sideAlignedPath`, since
/// lookups are exact-string. Ancestors of every diff (strictly below the root) are indexed too,
/// so folders can show a contained-differences count.
public struct DiffStatusIndex: Equatable, Sendable {
    /// Absolute path of a differing item → its difference type.
    private let statusByPath: [String: FileDifference.DifferenceType]
    /// Absolute path of a directory → number of differences anywhere beneath it.
    private let containedDiffCounts: [String: Int]
    /// Case/NFC-folded directory path → count, for panes on case-insensitive volumes: a missing
    /// row's expected path carries the source side's ancestor casing, so the destination's real
    /// folder ("docs" receiving a copy credited under "Docs") matches no exact key. Empty when
    /// `foldsCase` is false, where "Docs" and "docs" are distinct folders.
    private let foldedContainedDiffCounts: [String: Int]

    /// Index with no differences: every lookup returns nil/zero.
    public static let empty = DiffStatusIndex(differences: [], rootPath: "")

    /// - Parameters:
    ///   - differences: Current diff results for the focused comparison.
    ///   - rootPath: Absolute path of this pane's comparison root (the folder whose
    ///     children the pane's tree shows). Trailing slashes are tolerated.
    ///   - foldsCase: True when this pane's volume is case-insensitive; enables the folded
    ///     contained counts.
    public init(differences: [FileDifference], rootPath: String, foldsCase: Bool = false) {
        let root = Self.normalizedRoot(rootPath)
        guard !rootPath.isEmpty, !differences.isEmpty else {
            statusByPath = [:]
            containedDiffCounts = [:]
            foldedContainedDiffCounts = [:]
            return
        }

        var status: [String: FileDifference.DifferenceType] = [:]
        status.reserveCapacity(differences.count)
        var counts: [String: Int] = [:]

        for difference in differences {
            let relative = Self.normalizedRelative(difference.relativePath)
            guard !relative.isEmpty else { continue }
            // A name conflict's two sides spell the name differently and relativePath carries only
            // the left spelling, so index each side's real path; whichever lies under this pane's
            // root badges its node.
            let keys: [String]
            if difference.type == .nameConflict {
                keys = [difference.leftItemPath, difference.rightItemPath]
                    .filter { $0.hasPrefix(root + "/") }
            } else {
                keys = [Self.sideAlignedPath(
                    // Composed through `PathBoundary`, so a difference under a folder the root
                    // links in (iCloud Drive's `Documents`) keys the node the walk made. The
                    // filesystem root normalizes to an empty `root`, which `join` reads as no root,
                    // so it is joined by hand.
                    joined: root.isEmpty ? root + "/" + relative : PathBoundary.join(root: root, relative: relative),
                    left: difference.leftItemPath,
                    right: difference.rightItemPath
                )]
            }
            // A pane can show both sides of a conflict (same provider in both panes), and the two
            // are siblings sharing every ancestor, so credit each ancestor once per difference or
            // the pair counts twice.
            var ancestorsToCredit = Set<String>()
            for absolute in keys {
                status[absolute] = difference.type

                // Collect every ancestor directory strictly between the root and the item.
                var directory = absolute
                while let slash = directory.lastIndex(of: "/") {
                    directory = String(directory[..<slash])
                    guard directory.count > root.count else { break }
                    ancestorsToCredit.insert(directory)
                }
            }
            for directory in ancestorsToCredit {
                counts[directory, default: 0] += 1
            }
        }

        statusByPath = status
        containedDiffCounts = counts
        if foldsCase {
            var folded: [String: Int] = [:]
            folded.reserveCapacity(counts.count)
            for (path, count) in counts {
                folded[Self.foldedKey(path), default: 0] += count
            }
            foldedContainedDiffCounts = folded
        } else {
            foldedContainedDiffCounts = [:]
        }
    }

    /// Difference type for the node itself, or nil when the node is in sync.
    public func status(forNodeId id: String) -> FileDifference.DifferenceType? {
        statusByPath[id]
    }

    /// Number of differences anywhere beneath this directory node (0 for files and folders with
    /// none). On a folding pane the folded map answers alone, not as a fallback: one real folder's
    /// differences can be keyed under two casings (pairs via sideAlignedPath, missing rows under
    /// the source's), and an exact lookup would count only one casing's share.
    public func containedDiffCount(forNodeId id: String) -> Int {
        if !foldedContainedDiffCounts.isEmpty {
            return foldedContainedDiffCounts[Self.foldedKey(id)] ?? 0
        }
        return containedDiffCounts[id] ?? 0
    }

    /// Case + Unicode fold for the folded map (APFS/HFS+ lookups are normalization-insensitive;
    /// case folds only on the volumes this map is built for).
    private static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The absolute key to index a difference under. `relativePath` carries left-side casing, but
    /// on a case-insensitive volume the right pane's node ids carry right-side casing, so an exact
    /// lookup on the join would miss. When the join matches a side path only case-insensitively,
    /// that side's real path wins; the exact check first keeps the left index identical to the join.
    static func sideAlignedPath(joined: String, left: String, right: String) -> String {
        if left == joined || right == joined { return joined }
        if left.caseInsensitiveCompare(joined) == .orderedSame { return left }
        if right.caseInsensitiveCompare(joined) == .orderedSame { return right }
        return joined
    }

    /// Root with trailing slashes stripped, so joining with "/" never doubles a
    /// separator (a root of "/" becomes "" and joins back to "/<relative>").
    private static func normalizedRoot(_ path: String) -> String {
        var root = path
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// Relative path with surrounding slashes stripped. The diff engine emits none, but the join
    /// must not produce empty components if one sneaks in.
    private static func normalizedRelative(_ path: String) -> String {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        return relative
    }
}
