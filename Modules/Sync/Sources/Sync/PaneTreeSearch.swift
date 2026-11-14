import Foundation

/// Finding a name inside a pane's already-loaded tree: the matching, ordering and reveal-target
/// arithmetic, with no view and no filesystem.
///
/// A find, not a filter: nothing removes a row. The results say which rows matched, which folders
/// have matches beneath them, and where the current hit is; the pane dims, emphasizes and reveals
/// from that. A filter would rebuild the tree and lose where a hit sits.
///
/// In-memory only: every input is a `PaneTree` already walked, so a search is one pass over nodes
/// in RAM. Nothing here stats, opens or enumerates; a query must never make the pane touch a cloud
/// provider.
public enum PaneTreeSearch {

    // MARK: - Matching

    /// The comparison a name search uses: case folded, diacritics dropped, and (being Swift
    /// strings) normalization-insensitive.
    ///
    /// Deliberately no `precomposedStringWithCanonicalMapping`: volumes hand back both NFD and NFC
    /// names, but Swift string comparison already uses canonical equivalence. `IgnoreRules` and
    /// `ProviderNameRules` need the explicit call because they compare `unicodeScalars`, where
    /// canonical equivalence no longer applies.
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query, trimmed. Empty means "not searching" and every caller treats it as such.
    public static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Where `query` matches inside `name`, as a range of the name's character offsets, or `nil`.
    /// The first match only: a name with two of them is not two hits.
    ///
    /// `range(of:options:...)` matches in one ICU call per name and returns a range into the
    /// original string, so folds that change length (`strasse` finds `Straße`) need no offset
    /// mapping. It runs on the main actor per debounced keystroke over trees of ~40,000 nodes,
    /// which a per-grapheme fold is too slow for.
    public static func match(name: String, query: String) -> Range<Int>? {
        guard !query.isEmpty,
              let found = name.range(of: query, options: matchOptions, range: nil, locale: nil)
        else { return nil }
        return name.distance(from: name.startIndex, to: found.lowerBound)
            ..< name.distance(from: name.startIndex, to: found.upperBound)
    }

    // MARK: - Searching a tree

    /// Every row of `tree` whose name contains `query`, in the order the pane lists them.
    ///
    /// Pre-order depth-first, the order an expanded outline draws, so ↩ walks the hits down the
    /// pane. Folders match on their own names; a folder that only contains matches is reported by
    /// `containedMatchCounts`.
    ///
    /// No root is taken: `tree.rows` are the root's children, so the walk's component stack is the
    /// relative path, and `PaneRow.node.id` is already absolute. Nothing joins a root, so no copy of
    /// `PaneBrowsePath.normalized`'s trailing-slash rule is needed.
    public static func hits(in tree: PaneTree, query: String) -> [PaneSearchHit] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return [] }
        var results: [PaneSearchHit] = []
        var components: [String] = []
        var ancestors: [String] = []

        func walk(_ rows: [PaneRow]) {
            for row in rows {
                if let range = match(name: row.info.name, query: needle) {
                    results.append(PaneSearchHit(
                        path: row.node.id,
                        name: row.info.name,
                        relativePath: (components + [row.info.name]).joined(separator: "/"),
                        parentComponents: components,
                        ancestorPaths: ancestors,
                        match: range))
                }
                guard let children = row.children, !children.isEmpty else { continue }
                components.append(row.info.name)
                ancestors.append(row.node.id)
                walk(children)
                components.removeLast()
                ancestors.removeLast()
            }
        }

        walk(tree.rows)
        return results
    }

    /// Folder path → how many hits lie strictly beneath it.
    ///
    /// Lets a collapsed folder say “2 matches”, and, holding every ancestor of every hit, decides
    /// which rows must not dim: a folder on the way to an answer is part of it. Strictly beneath,
    /// so a folder matching on its own name doesn't claim a match inside it.
    public static func containedMatchCounts(_ hits: [PaneSearchHit]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for hit in hits {
            for ancestor in hit.ancestorPaths {
                counts[ancestor, default: 0] += 1
            }
        }
        return counts
    }

    /// Every relative path in `tree`: the set a hit in the other pane is checked against to decide
    /// whether the same item exists on both sides.
    ///
    /// Case is significant: the diff engine pairs on exact relative paths and folds case only as a
    /// fallback, so a case-insensitive answer would claim “both sides” for two items the
    /// Differences table lists separately.
    ///
    /// Normalization is not, with no code needed: Swift `Set` equality and hashing use canonical
    /// equivalence, so NFD and NFC spellings are one key. See `matchOptions` for where an explicit
    /// precompose is needed instead.
    public static func relativePaths(in tree: PaneTree) -> Set<String> {
        var paths: Set<String> = []
        var components: [String] = []

        func walk(_ rows: [PaneRow]) {
            for row in rows {
                components.append(row.info.name)
                paths.insert(components.joined(separator: "/"))
                if let children = row.children, !children.isEmpty {
                    walk(children)
                }
                components.removeLast()
            }
        }

        walk(tree.rows)
        return paths
    }

    /// Which side(s) each hit is on, given the other pane's relative paths.
    ///
    /// Pure set membership over two already-walked trees, so it is cheap on every keystroke. With
    /// no opposite pane (the single-source rail) the caller passes `nil` and nothing is annotated:
    /// “this side only” means nothing without a comparison.
    public static func sides(for hits: [PaneSearchHit],
                             otherPaths: Set<String>?) -> [String: PaneSearchSide] {
        guard let otherPaths else { return [:] }
        var sides: [String: PaneSearchSide] = [:]
        for hit in hits {
            sides[hit.path] = otherPaths.contains(hit.relativePath) ? .bothSides : .thisSideOnly
        }
        return sides
    }

    // MARK: - Revealing a hit

    /// The expansion set after revealing `hit`: what was already open, plus exactly this hit's own
    /// ancestors.
    ///
    /// Per hit, on arrival, never all hits up front: expanding every hit's ancestors would blow
    /// open a large tree while the user is still typing. Folders opened by an earlier hit stay
    /// open, as if the user had clicked down to it.
    public static func expansion(_ expanded: Set<String>, revealing hit: PaneSearchHit) -> Set<String> {
        expanded.union(hit.ancestorPaths)
    }
}

/// Which side(s) of a comparison a hit exists on. Only produced where there is a second tree
/// (`PaneTreeSearch.sides(for:otherPaths:)`).
public enum PaneSearchSide: String, Sendable, Equatable {
    /// The same relative path exists in the opposite pane's tree.
    case bothSides
    /// It doesn't. Usually the reason for searching, so this one carries the risk tint.
    case thisSideOnly
}

/// One matched row: where it is, and which run of its name matched.
public struct PaneSearchHit: Equatable, Sendable, Identifiable {
    /// The node's absolute path, which is also its outline identity and its selection tag.
    public let path: String
    /// The name as stored, unfolded: the emphasis is drawn on this.
    public let name: String
    /// Path relative to the pane's tree root. Used to ask the opposite pane whether it has this
    /// item, and (as components) to open the Columns stack down to it.
    public let relativePath: String
    /// The folder names from the tree root down to this hit's parent (`relativePath` minus the
    /// hit): a `PaneBrowsePath`'s components, the columns that must be open for the hit's row to be
    /// listed in the deepest one.
    public let parentComponents: [String]
    /// Absolute paths of the folders containing this hit, outermost first. The tree presentation
    /// expands exactly these to reveal it.
    public let ancestorPaths: [String]
    /// The matched run, as a range of character offsets into `name`.
    public let match: Range<Int>

    public var id: String { path }

    public init(path: String, name: String, relativePath: String,
                parentComponents: [String], ancestorPaths: [String], match: Range<Int>) {
        self.path = path
        self.name = name
        self.relativePath = relativePath
        self.parentComponents = parentComponents
        self.ancestorPaths = ancestorPaths
        self.match = match
    }

    /// The column stack that lists this hit's own row in its deepest column.
    ///
    /// The hit itself is never a component, even as a folder: opening its own column would show
    /// its contents and leave the matched row, and its selection highlight, out of view.
    public var browsePath: PaneBrowsePath { PaneBrowsePath(components: parentComponents) }
}

/// One pane's search results, stamped so a SwiftUI comparison never walks them.
///
/// `FileTreeView`'s `==` gates the pane's re-render, and a broad query fills these maps with
/// thousands of entries, so equality is `(side, generation, query)` only, as with `PaneTree`.
///
/// That is exact: `generation` is the host's counter, bumped on every recomputation, so the same
/// side and generation means the same computation. `query` rides along because it is cheap and is
/// what the emphasis is drawn from.
public struct PaneSearchResults: Equatable, Sendable {
    /// Which pane these are for. The two panes keep independent counters, so a generation means
    /// something only with the side that minted it.
    public let side: PaneTree.Side
    /// The host's recomputation counter at the moment these were built.
    public let generation: Int
    /// The live query, trimmed. Empty means no search is running, and every accessor below
    /// answers as if there were no results.
    public let query: String
    /// The hits, in the order the pane lists them.
    public let hits: [PaneSearchHit]

    private let matchByPath: [String: Range<Int>]
    private let containedCounts: [String: Int]
    private let sideByPath: [String: PaneSearchSide]

    /// Builds the results for one pane. `otherPaths` is the opposite pane's relative paths (see
    /// `PaneTreeSearch.relativePaths(in:)`), or `nil` on a surface with no opposite pane.
    public init(side: PaneTree.Side, generation: Int, query: String,
                tree: PaneTree, otherPaths: Set<String>?) {
        let hits = PaneTreeSearch.hits(in: tree, query: query)
        self.side = side
        self.generation = generation
        // The trimmed query, not the raw text: `hits` trims before matching, so a single space
        // must not count as `isActive` (dimming every row and saying "No matches"). One value then
        // answers whether it runs, what matched, and what the counter says.
        self.query = PaneTreeSearch.normalizedQuery(query)
        self.hits = hits
        self.matchByPath = Dictionary(hits.map { ($0.path, $0.match) }, uniquingKeysWith: { first, _ in first })
        self.containedCounts = PaneTreeSearch.containedMatchCounts(hits)
        self.sideByPath = PaneTreeSearch.sides(for: hits, otherPaths: otherPaths)
    }

    /// The resting value: no query, no hits, nothing drawn.
    public static func empty(side: PaneTree.Side) -> PaneSearchResults {
        PaneSearchResults(side: side, generation: 0, query: "",
                          tree: PaneTree(side: side, version: 0, nodes: [], rows: []),
                          otherPaths: nil)
    }

    /// Whether a search is running. Every presentation decision is gated on this, so a collapsed
    /// field or empty query leaves the pane rendering as normal.
    public var isActive: Bool { !query.isEmpty }

    /// The matched run of this row's name, or `nil` when it is not a hit.
    public func match(forPath path: String) -> Range<Int>? { matchByPath[path] }

    /// How many hits lie beneath this folder (0 for files and for folders with none).
    public func containedMatchCount(forPath path: String) -> Int { containedCounts[path] ?? 0 }

    /// Which side(s) this hit is on, or `nil` when it is not a hit or there is no opposite pane.
    public func side(forPath path: String) -> PaneSearchSide? { sideByPath[path] }

    /// Whether this row should dim: a search is running, this row did not match, and there is
    /// nothing matching underneath it either.
    ///
    /// Every row on the way to an answer stays bright, so dimming reads as “not this branch”. Reads
    /// the contained count, already keyed by path for the “N matches” pill, so the pill and the
    /// dimming come from one map.
    public func isDimmed(path: String) -> Bool {
        isActive && matchByPath[path] == nil && (containedCounts[path] ?? 0) == 0
    }

    /// The hit at `index`, or `nil` when there is none (no results, or an index left over from a
    /// longer previous result set).
    public func hit(at index: Int) -> PaneSearchHit? {
        hits.indices.contains(index) ? hits[index] : nil
    }

    /// Where the walk should stand once these results replace `previous`, which was standing at
    /// `index`.
    ///
    /// Two events land here and want opposite things. Typing builds a different list, where index
    /// 4 names an unrelated file, so the walk restarts. A republish (every scan, copy and
    /// hidden-files toggle, in either pane) keeps the query, and restarting would yank the user to
    /// the first hit and scroll them away from the row they were reading.
    ///
    /// So with the same query, follow the path, since the index means nothing across result sets.
    /// Falls back to the top when the query changed or the file is no longer a hit.
    public func walkIndex(after previous: PaneSearchResults, standingAt index: Int) -> Int {
        guard previous.query == query, let path = previous.hit(at: index)?.path,
              let moved = hits.firstIndex(where: { $0.path == path })
        else { return PaneSearchWalk.restart }
        return moved
    }

    /// The “N of M” a field shows; `nil` for an inactive search. “No matches” when the query found
    /// none: a real answer, not silence.
    public func summary(at index: Int) -> String? {
        guard isActive else { return nil }
        guard !hits.isEmpty else { return "No matches" }
        return "\(min(index, hits.count - 1) + 1) of \(hits.count)"
    }

    /// Deliberately ignores the hits and the three maps: see the note on the type.
    public static func == (lhs: PaneSearchResults, rhs: PaneSearchResults) -> Bool {
        lhs.side == rhs.side && lhs.generation == rhs.generation && lhs.query == rhs.query
    }
}

/// Where ↩ and ⇧↩ leave the current-hit index.
///
/// Wraps in both directions, so the user never has to work out where they are in a list they
/// can't see. Clamped rather than trusted: the index outlives its results, and one more typed
/// character can leave it past the end.
public enum PaneSearchWalk {
    /// The index after ↩ (`reverse: false`) or ⇧↩ (`reverse: true`) over `count` hits.
    /// Answers 0 when there is nothing to walk.
    public static func advance(_ index: Int, count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        return reverse ? (current + count - 1) % count : (current + 1) % count
    }

    /// The index a freshly recomputed result set starts at: the top of the list.
    ///
    /// Not “keep where you were”: each keystroke builds a different list, where the old index
    /// names an unrelated file. Typing restarts the walk; ↩ continues it.
    public static let restart = 0
}
