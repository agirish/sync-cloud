import Foundation
import Sync

/// Per-pane lookup from a tree node's absolute path to its diff status, built once per
/// differences change so `FileRowView` can badge rows with dictionary lookups instead of
/// scanning the differences list per row.
///
/// `FileDifference.relativePath` is relative to the focused comparison root, while tree
/// node IDs are absolute paths; the index joins each relative path onto the pane's root
/// (`rootPath`) to key by absolute path, re-aligned to the side's real casing via
/// `sideAlignedPath` (lookups are exact-string). Ancestor directories of every diff
/// (strictly below the root) are also indexed so folders can show a contained-differences
/// count.
public struct DiffStatusIndex: Equatable, Sendable {
    /// Absolute path of a differing item → its difference type.
    private let statusByPath: [String: FileDifference.DifferenceType]
    /// Absolute path of a directory → number of differences anywhere beneath it.
    private let containedDiffCounts: [String: Int]
    /// Case/NFC-folded directory path → count, the fallback for panes on case-insensitive
    /// volumes: a MISSING row's expected path carries the SOURCE side's ancestor casing all
    /// the way down, so the destination pane's real folder ("docs" receiving a copy credited
    /// under "Docs") matched no exact key and showed no badge. Empty when `foldsCase` is
    /// false — on a case-sensitive volume "Docs" and "docs" are distinct real folders and a
    /// folded hit would badge the wrong one.
    private let foldedContainedDiffCounts: [String: Int]

    /// Index with no differences: every lookup returns nil/zero.
    public static let empty = DiffStatusIndex(differences: [], rootPath: "")

    /// - Parameters:
    ///   - differences: Current diff results for the focused comparison.
    ///   - rootPath: Absolute path of this pane's comparison root (the folder whose
    ///     children the pane's tree shows). Trailing slashes are tolerated.
    ///   - foldsCase: Pass true when this pane's volume is case-insensitive; enables the
    ///     folded contained-count fallback described above.
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
            // A name conflict's two sides spell the name differently (relativePath carries
            // only the LEFT spelling), so index each side's REAL path — whichever lies under
            // this pane's root badges its own node; the other side's key matches nothing here.
            let keys: [String]
            if difference.type == .nameConflict {
                keys = [difference.leftItemPath, difference.rightItemPath]
                    .filter { $0.hasPrefix(root + "/") }
            } else {
                keys = [Self.sideAlignedPath(
                    joined: root + "/" + relative,
                    left: difference.leftItemPath,
                    right: difference.rightItemPath
                )]
            }
            // A pane can show both sides of a conflict (same provider in both panes): each key
            // badges its own node. But the two sides of a name conflict are siblings in the same
            // folder, so they share every ancestor — credit each ancestor only ONCE per
            // difference, or the shared folders would count this single pair twice.
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

    /// Number of differences anywhere beneath this directory node (0 for files
    /// and for directories with no differing descendants). Exact key first; on a
    /// case-insensitive pane a miss falls back to the folded key, so the destination
    /// folder of a case-variant ancestor chain still shows its badge.
    public func containedDiffCount(forNodeId id: String) -> Int {
        if let exact = containedDiffCounts[id] { return exact }
        guard !foldedContainedDiffCounts.isEmpty else { return 0 }
        return foldedContainedDiffCounts[Self.foldedKey(id)] ?? 0
    }

    /// Case + Unicode fold for the fallback map (APFS/HFS+ lookups are
    /// normalization-insensitive; case folds only on the volumes this map is built for).
    private static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The absolute key to index a difference under. `relativePath` always carries
    /// LEFT-side casing, but on a case-insensitive volume a pair can differ in case
    /// between the sides — then the right pane's node ids carry right-side casing and an
    /// exact lookup on the join would miss. When the join isn't literally one of the
    /// difference's side paths but matches one case-insensitively, that side's real path
    /// (root included, so a right pane under a left-cased join can't be misattributed)
    /// wins; the exact-match check first keeps the left index byte-identical to the join.
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

    /// Relative path with surrounding slashes stripped (the diff engine emits none,
    /// but the join above must not produce empty components if one sneaks in).
    private static func normalizedRelative(_ path: String) -> String {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        return relative
    }
}
