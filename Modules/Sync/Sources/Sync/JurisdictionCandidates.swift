import Foundation

/// One proposed jurisdiction value, and the evidence for it — enough for a dialog to say
/// *"we found US, IN and EMP under Finance, Legal and School; which of these are places?"*
public struct JurisdictionCandidate: Sendable, Equatable, Identifiable {
    public var id: String { value }
    /// The folder name as it appears in the tree, verbatim — `US`, not `us`. The profile's
    /// `axes.jurisdiction` values are written the way the folders spell them.
    public let value: String
    /// The distinct parent folders it appears under, relative to the surveyed root and sorted
    /// (`""` is the root). This is the evidence the dialog shows: a value under `Finance`, `Legal`
    /// and `School` reads as a place; one under `Work/Payslips` alone reads as an employer.
    public let parents: [String]
    /// How many folders would take this value if confirmed: the folder named `value` and everything
    /// beneath it, counted once per folder even when a path names the value twice
    /// (`Taxes/US/Consulate/US`). The blast radius, and what the list is ordered by.
    public let folderCount: Int

    public init(value: String, parents: [String], folderCount: Int) {
        self.value = value
        self.parents = parents
        self.folderCount = folderCount
    }
}

/// Proposes jurisdiction axis values from folder names, and does not decide them: a person must
/// confirm them. On the reference tree its raw proposals match the hand-built profile for 83% of
/// folders, against 100% when handed the confirmed values, because it also proposes `EMP`, `IT` and
/// `PRD` (an employer, a department, a product stage) beside the real `US` and `IN`.
///
/// It also misses: `Singapore` is too long and sits under too few parents. **A dialog built on this
/// must let the user add a value as well as tick one.**
///
/// Deliberately permissive, because a human filters the output; a tighter rule that dropped the
/// false positives would drop `IN` with them. Pure: no disk, no `FileManager`, no clock.
public enum JurisdictionCandidates {

    /// A candidate component is this many characters: country codes are two or three, and a fourth
    /// starts admitting ordinary words. On the reference tree the only longer all-caps name that
    /// clears ``minimumDistinctParents`` is `TODO`, the inbox marker filing exists to refuse.
    public static let componentLength = 2...3

    /// How many distinct parents a value must appear under to be proposed at all. An axis value
    /// splits several branches (`Finance/US`, `Legal/US`, `School/US`); a name under one parent is
    /// a folder, not an axis.
    public static let minimumDistinctParents = 3

    /// How many distinct parents a value needs before setup pre-ticks it. Higher than
    /// ``minimumDistinctParents`` because a proposal costs one glance and a wrong tick costs a wrong
    /// profile the user approved. `JurisdictionConfidenceGroundTruthTests` checks it against the
    /// reference tree: at five exactly `US` and `IN` pre-tick, and six would drop `IN`. Raise it
    /// only if that test names a value the profile doesn't carry.
    public static let confidentDistinctParents = 5

    /// Whether setup should offer this candidate already ticked. Needs both the parent count (it
    /// behaves like an axis) and the region check (it is a country, not an employer or department
    /// such as `IT`). The region check is alpha-2 only, so three-letter codes like `USA` are
    /// proposed but never pre-ticked; the user ticks them by hand.
    public static func isConfident(_ candidate: JurisdictionCandidate) -> Bool {
        guard candidate.parents.count >= confidentDistinctParents else { return false }
        return Locale.Region.isoRegions.contains(Locale.Region(candidate.value))
    }

    /// Candidate jurisdiction values found in `tree`, strongest first.
    ///
    /// - Parameters:
    ///   - tree: the surveyed nodes. Either the root's children or a single root node; the root
    ///     is identified by `root` and contributes no value of its own.
    ///   - root: the absolute path the tree was walked from. Paths are reported relative to it.
    ///
    /// The root node is recognised by an exact `node.id == root` match (trailing slash aside), so a
    /// `root` spelled with a tilde against absolute ids treats the root as a child and every parent
    /// gains a level. ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)``
    /// always takes the root's children instead, so the two agree only on matching spellings. A
    /// future caller should hand both the same shape.
    /// - Returns: candidates by ``JurisdictionCandidate/folderCount`` descending, then by value, so
    ///   the biggest change comes first and the order is stable between runs.
    public static func propose(tree: [FileNode], root: String) -> [JurisdictionCandidate] {
        var folders: [String] = []
        let rootPath = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        for node in tree {
            // The root node contributes its children, not its own name; anything else is a child of
            // the root. Paths are built from `name`, so they don't depend on how ids are spelled.
            collect(node, prefix: node.id == rootPath ? nil : "", into: &folders)
        }

        var parentsByValue: [String: Set<String>] = [:]
        for path in folders {
            let cut = path.lastIndex(of: "/")
            let name = cut.map { String(path[path.index(after: $0)...]) } ?? path
            guard isCandidateName(name) else { continue }
            let parent = cut.map { String(path[path.startIndex..<$0]) } ?? ""
            // A value nested under itself is one branch, not several: without this,
            // `A/US/B/US/C/US` alone would give `US` three parents and clear the bar while
            // splitting nothing.
            guard !parent.split(separator: "/").contains(where: { $0 == name }) else { continue }
            parentsByValue[name, default: []].insert(parent)
        }
        let proposed = parentsByValue.filter { $0.value.count >= minimumDistinctParents }
        guard !proposed.isEmpty else { return [] }

        // The blast radius: every folder with the value anywhere in its path takes it, the same rule
        // a confirmed axis applies; the folder named `US` counts itself. The `Set` counts a folder
        // once even when its path repeats the value (`Taxes/US/Consulate/US`).
        var affected: [String: Int] = [:]
        for path in folders {
            for component in Set(path.split(separator: "/")) where proposed[String(component)] != nil {
                affected[String(component), default: 0] += 1
            }
        }

        return proposed.map { value, parents in
            JurisdictionCandidate(value: value, parents: parents.sorted(),
                                  folderCount: affected[value] ?? 0)
        }
        .sorted { ($0.folderCount, $1.value) > ($1.folderCount, $0.value) }
    }

    /// Whether a folder name is short and all-caps enough to be offered. Letters only, so `529` and
    /// `PG&E` are not offered, and case-sensitive, so the word `Us` is not either.
    static func isCandidateName(_ name: String) -> Bool {
        guard componentLength.contains(name.count) else { return false }
        return name.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Appends every surveyed directory's path, relative to the root, in pre-order. `prefix` is the
    /// parent's relative path, or nil for a node standing in for the root itself.
    ///
    /// Filters by ``FolderSurveyBuilder/isSurveyedFolder(_:)``, not `isDirectory`, so the counts
    /// describe the tree the survey walks. `isDirectory` is true of a symlink to a folder, which
    /// would add parents the survey skips and count a linked subtree twice; dot-folders and
    /// unexplored subtrees never receive an axis either.
    private static func collect(_ node: FileNode, prefix: String?, into folders: inout [String]) {
        guard let prefix else {
            // The root contributes its children, never its own name, and skips the survey's filter:
            // it is the tree, not a folder within it.
            guard node.isDirectory else { return }
            for child in node.children ?? [] { collect(child, prefix: "", into: &folders) }
            return
        }
        guard FolderSurveyBuilder.isSurveyedFolder(node) else { return }
        let here = prefix.isEmpty ? node.name : prefix + "/" + node.name
        folders.append(here)
        for child in node.children ?? [] { collect(child, prefix: here, into: &folders) }
    }
}
