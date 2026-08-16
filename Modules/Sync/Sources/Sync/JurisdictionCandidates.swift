import Foundation

/// One proposed jurisdiction value, and the evidence for it — enough for a dialog to say
/// *"we found US, IN and HPE under Finance, Legal and School; which of these are places?"*
public struct JurisdictionCandidate: Sendable, Equatable, Identifiable {
    public var id: String { value }
    /// The folder name as it appears in the tree, verbatim — `US`, not `us`. The profile's
    /// `axes.jurisdiction` values are written the way the folders spell them.
    public let value: String
    /// The distinct parent folders it appears under, relative to the surveyed root and sorted.
    /// `""` is the root itself. This is the *evidence*, and it is what the dialog shows: a value
    /// under `Finance`, `Legal` and `School` reads as a place; one under `Work/Payslips` alone
    /// reads as an employer.
    public let parents: [String]
    /// How many folders would take this value if it were confirmed — the folder named `value` and
    /// everything beneath it, **counted once per folder**. A path that names the value at two depths
    /// (`Taxes/US/Consulate/US`) is still one folder; counting per occurrence inflated the number the
    /// dialog reports and could reorder the list. This is the blast radius, and it is what the list
    /// is ordered by.
    public let folderCount: Int

    public init(value: String, parents: [String], folderCount: Int) {
        self.value = value
        self.parents = parents
        self.folderCount = folderCount
    }
}

/// Proposes jurisdiction axis values from folder names — **and does not decide them.**
///
/// **This heuristic is wrong often enough that wiring it straight through would be actively
/// harmful, and the numbers are measured, not estimated.** Run over the reference tree
/// (`~/Documents`, 3,013 surveyed folders, the profile the offline builder produced):
///
/// | Vocabulary | Folders whose jurisdiction matches the hand-built profile |
/// |---|---|
/// | this heuristic's proposals, used as-is | 2,508 / 3,013 — **83.2%** |
/// | the same code handed the confirmed values | 3,013 / 3,013 — **100%** |
///
/// The gap is not noise, it is three inventions. The rule proposes `US` and `IN`, which are real,
/// **and `HPE`, `IT` and `PRD`, which are an employer, a department and a product stage.** A file
/// routed by a `jurisdiction: HPE` axis is being reasoned about with a fact that does not exist.
/// That is why the shape of this API is *propose*, and why the confirmation step is not optional
/// polish: handed the right values the axis is perfect, so **the entire error is in the guessing.**
///
/// **And it misses.** `Singapore` is a real jurisdiction on that tree — 10 folders — and this rule
/// cannot propose it twice over: it is nine characters, and it appears under only two distinct
/// parents (`Immigration/Visa`, `Travel/Trips`), below the ``minimumDistinctParents`` bar. **A
/// dialog built on this must therefore let the user ADD a value as well as tick one**, or the tree's
/// third jurisdiction can never be recorded at all.
///
/// The rule is deliberately permissive — short all-caps names under several parents — because a
/// human filters the output. It is tuned to offer `HPE` rather than to be right about it; a
/// tighter rule that dropped the false positives would drop `IN` with them.
///
/// Pure: no disk, no `FileManager`, no clock. It reads the tree it is handed and nothing else.
public enum JurisdictionCandidates {

    /// A candidate component is this many characters. `US`, `IN`, `UK`, `AE` — country codes are
    /// two or three, and a fourth character starts admitting ordinary words.
    ///
    /// **The upper bound is measured, not tidiness.** The reference tree's only all-caps name of
    /// four or more characters that clears ``minimumDistinctParents`` is **`TODO`, under 16 of
    /// them** — more parents than `US` has. Without the cap the strongest jurisdiction this
    /// proposes is the inbox marker the whole filing path exists to refuse.
    public static let componentLength = 2...3

    /// How many distinct parents a value must appear under to be proposed at all. An axis value
    /// *splits* several branches — `Finance/US`, `Legal/US`, `School/US`; a name under one parent
    /// is a folder, not an axis. This is also the bar `Singapore` fails on the reference tree.
    public static let minimumDistinctParents = 3

    /// Candidate jurisdiction values found in `tree`, strongest first.
    ///
    /// - Parameters:
    ///   - tree: the surveyed nodes. Either the root's children or a single root node; the root
    ///     is identified by `root` and contributes no value of its own.
    ///   - root: the absolute path the tree was walked from. Paths are reported relative to it.
    /// - Returns: candidates ordered by ``JurisdictionCandidate/folderCount`` descending, then by
    ///   value, so the dialog shows the one that would change the most folders first and the order
    ///   does not wobble between runs.
    public static func propose(tree: [FileNode], root: String) -> [JurisdictionCandidate] {
        var folders: [String] = []
        let rootPath = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        for node in tree {
            // A node whose id IS the root is the root itself: it contributes its children, not its
            // own name. Anything else is taken as a child of the root, which is what a walk hands
            // over. Composing paths from `name` down rather than slicing every id keeps this
            // independent of how the ids were spelled.
            collect(node, prefix: node.id == rootPath ? nil : "", into: &folders)
        }

        var parentsByValue: [String: Set<String>] = [:]
        for path in folders {
            let cut = path.lastIndex(of: "/")
            let name = cut.map { String(path[path.index(after: $0)...]) } ?? path
            guard isCandidateName(name) else { continue }
            let parent = cut.map { String(path[path.startIndex..<$0]) } ?? ""
            // **A value nested under itself is one branch, not several.** The parents set is the
            // evidence that this value *splits* the tree — `Finance/US`, `Legal/US`, `School/US` —
            // and `minimumDistinctParents` is the bar it has to clear. Counting every occurrence let
            // a single branch clear that bar on its own: `A/US/B/US/C/US` contributes three
            // different parent strings (`A`, `A/US/B`, `A/US/B/US/C`) and proposes a value that
            // splits nothing, which is exactly what the rule's own doc says a parent count is for.
            // The blast radius had the same defect one field over and was fixed; this is the half
            // that was missed.
            guard !parent.split(separator: "/").contains(where: { $0 == name }) else { continue }
            parentsByValue[name, default: []].insert(parent)
        }
        let proposed = parentsByValue.filter { $0.value.count >= minimumDistinctParents }
        guard !proposed.isEmpty else { return [] }

        // The blast radius: every folder that has the value anywhere in its path takes it, which
        // is the same rule a confirmed axis is applied by. The folder named `US` counts itself.
        //
        // **Once per folder, which is what `Set` is for.** Counting per matching *component* meant a
        // path that repeats the value at two depths — `Taxes/US/Consulate/US` — added 2 for one
        // folder, and every descendant repeated the inflation. The count is what the dialog sorts
        // and displays as "how many folders would take this value", so a doubled one is both a wrong
        // number and possibly a wrong order.
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

    /// Whether a folder name is short and all-caps enough to be offered.
    ///
    /// Letters only, so `529` (a real folder under `Finance/US`) and `PG&E` are not offered as
    /// places, and case-sensitive, so `Us` — an ordinary word — is not either.
    static func isCandidateName(_ name: String) -> Bool {
        guard componentLength.contains(name.count) else { return false }
        return name.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Appends every surveyed directory's path, relative to the root, in pre-order. `prefix` is the
    /// parent's relative path, or nil for a node standing in for the root itself.
    ///
    /// **The filter is ``FolderSurveyBuilder/isSurveyedFolder(_:)``, not `isDirectory`, because this
    /// counts on the survey's behalf.** Every number here is a promise about what confirming a value
    /// would do — the parents are the evidence, and `folderCount` is the blast radius the dialog
    /// orders by. Counting on a rule of its own made those promises about a different tree than the
    /// one the survey walks: `isDirectory` is true of a symlink to a directory (it describes the
    /// link's target), so a symlinked `US` could push a value over ``minimumDistinctParents`` on
    /// parents the survey skips, and a link to an in-tree subtree counted that subtree twice;
    /// dot-directories and unexplored subtrees counted the same way, and none of them ever receive
    /// an axis.
    private static func collect(_ node: FileNode, prefix: String?, into folders: inout [String]) {
        guard let prefix else {
            // The node standing in for the root: it contributes its children, never its own name,
            // and is not judged by the survey's filter — it is the tree, not a folder within it.
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
