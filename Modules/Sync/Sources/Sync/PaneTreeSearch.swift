import Foundation

/// Finding a name inside a pane's already-loaded tree — the whole of the matching, ordering and
/// reveal-target arithmetic, with no view and no filesystem anywhere in it.
///
/// **A find, not a filter.** Nothing here removes a row. The results say which rows matched, which
/// folders have matches beneath them, and where the current hit sits; the pane dims, emphasizes and
/// reveals from that, and its structure is untouched. A filter would rebuild the tree under the
/// user and destroy the one thing a tree communicates — where a hit *sits*.
///
/// **In-memory only.** Every input is a `PaneTree` the pane has already walked, so a search costs
/// one pass over nodes that are already in RAM. Nothing here stats, opens or enumerates anything;
/// a query must never be able to make the pane touch a cloud provider.
public enum PaneTreeSearch {

    // MARK: - Folding

    /// One name (or query) folded for comparison, with each folded character remembering which
    /// character of the ORIGINAL it came from.
    ///
    /// The parallel index is the whole reason this is not a one-line `folding(options:)` call. The
    /// match is found in the folded text and drawn on the original, and folding is not
    /// length-preserving — `.caseInsensitive` folding maps “ß” to “ss”, so a match found at folded
    /// offset 3 can sit at original offset 2. Folding character by character and recording the
    /// source index keeps the two alignable however many characters a fold produces.
    public struct FoldedName: Sendable {
        /// The folded characters, in order.
        public let characters: [Character]
        /// `sourceIndex[i]` is the offset, in the ORIGINAL name's characters, that produced
        /// `characters[i]`.
        public let sourceIndex: [Int]
    }

    /// Case folded and diacritics dropped, per grapheme — the normalization a name search has to use
    /// so that “cafe” finds “Café” and “CAFÉ” alike.
    ///
    /// **There is deliberately no `precomposedStringWithCanonicalMapping` here, and that is not an
    /// omission.** macOS really does hand back decomposed (NFD) names from some volumes and
    /// precomposed ones from others, so the requirement is real — but it is already met, because
    /// everything below compares Swift `Character`s, and Swift's `Character`/`String` equality,
    /// hashing and `Set` membership are all defined on canonical equivalence. Measured: the two
    /// spellings of “é” have different `unicodeScalars` and compare EQUAL as `Character`s, and both
    /// fold to “e”.
    ///
    /// `IgnoreRules` and `ProviderNameRules` do carry the explicit call, and they need it: both drop
    /// to `unicodeScalars`, which is exactly where canonical equivalence stops applying. Adding it
    /// here would have been a line that changes nothing — the version that had it survived deleting
    /// it with every test still green, which is how the redundancy was found.
    public static func fold(_ name: String) -> FoldedName {
        var characters: [Character] = []
        var sourceIndex: [Int] = []
        for (offset, character) in Array(name).enumerated() {
            let folded = String(character)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            for produced in folded {
                characters.append(produced)
                sourceIndex.append(offset)
            }
        }
        return FoldedName(characters: characters, sourceIndex: sourceIndex)
    }

    /// The query side of `fold`. It needs no source indices — nothing is ever drawn from it — so it
    /// is the plain folded text.
    public static func foldQuery(_ query: String) -> [Character] {
        fold(query.trimmingCharacters(in: .whitespaces)).characters
    }

    /// Where `query` matches inside `name`, as a range of the ORIGINAL name's character offsets, or
    /// `nil` when it does not. The first match only: the emphasis marks the run you searched for,
    /// and a name with two of them is not two hits.
    public static func match(name: String, foldedQuery query: [Character]) -> Range<Int>? {
        guard !query.isEmpty else { return nil }
        let folded = fold(name)
        let haystack = folded.characters
        guard haystack.count >= query.count else { return nil }
        for start in 0...(haystack.count - query.count) {
            var offset = 0
            while offset < query.count, haystack[start + offset] == query[offset] { offset += 1 }
            guard offset == query.count else { continue }
            // The folded run [start, start + count) spans original characters
            // sourceIndex[start] … sourceIndex[start + count - 1], inclusive — so the exclusive end
            // is one past the last. Taking `sourceIndex[start + count]` instead would be wrong at
            // the end of the name and, worse, would silently drop the last character of any match
            // whose final character folded into more than one.
            let first = folded.sourceIndex[start]
            let last = folded.sourceIndex[start + query.count - 1]
            return first..<(last + 1)
        }
        return nil
    }

    // MARK: - Searching a tree

    /// Every row of `tree` whose name contains `query`, in the order the pane lists them.
    ///
    /// Pre-order depth-first, which is exactly the order an expanded outline draws — so ↩ walks the
    /// hits down the pane rather than in some order of its own. Folders match on their own names
    /// like anything else; a folder that merely *contains* matches is reported by
    /// `containedMatchCounts` instead.
    ///
    /// No tree root is needed and none is taken: `tree.rows` ARE the root's children, so a hit's
    /// position relative to the root is the walk's own component stack. Absolute positions come from
    /// the nodes themselves (`PaneRow.node.id` is the absolute path), so nothing here has to join a
    /// root onto anything — which also means no copy of `PaneBrowsePath.normalized`'s trailing-slash
    /// rule can drift in here.
    public static func hits(in tree: PaneTree, query: String) -> [PaneSearchHit] {
        let folded = foldQuery(query)
        guard !folded.isEmpty else { return [] }
        var results: [PaneSearchHit] = []
        var components: [String] = []
        var ancestors: [String] = []

        func walk(_ rows: [PaneRow]) {
            for row in rows {
                if let range = match(name: row.info.name, foldedQuery: folded) {
                    results.append(PaneSearchHit(
                        path: row.node.id,
                        name: row.info.name,
                        isDirectory: row.info.isDirectory,
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

    /// Folder path → how many hits lie strictly BENEATH it.
    ///
    /// This is what lets a collapsed folder say “2 matches” instead of hiding the fact that the
    /// answer is inside it, and — because every ancestor of every hit is in here — it is also the
    /// rule that decides which rows must NOT dim: a folder on the way to an answer is part of the
    /// answer.
    ///
    /// Strictly beneath: a folder that matches on its own name is a hit, and counting itself here
    /// would make it claim a match inside it that may not exist.
    public static func containedMatchCounts(_ hits: [PaneSearchHit]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for hit in hits {
            for ancestor in hit.ancestorPaths {
                counts[ancestor, default: 0] += 1
            }
        }
        return counts
    }

    /// Every relative path in `tree` — the set a hit in this pane is checked against to decide
    /// whether the same item exists on both sides.
    ///
    /// Case is deliberately significant. The diff engine keys its pairs on exact relative paths and
    /// only folds case as a fallback on a case-insensitive volume, so a case-insensitive answer here
    /// would claim “both sides” for two items the Differences table reports separately.
    ///
    /// Normalization is deliberately NOT significant, and needs no code to make it so: these are
    /// Swift `String`s in a Swift `Set`, and both equality and hashing there are canonical-
    /// equivalence-based — so a folder arriving spelled NFD from one provider and NFC from another
    /// is one key, not two. See `fold` for the measurement, and for where the explicit precompose is
    /// genuinely load-bearing instead.
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
    /// Pure set membership over two already-walked trees — no disk access and no new scan, which is
    /// what makes this affordable on every keystroke. On a surface with no opposite pane (the
    /// single-source rail) the caller passes `nil` and no annotation is produced at all: “left only”
    /// is a statement about a comparison the rail is not making.
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
    /// **Per hit, on arrival — never all hits up front.** Expanding every ancestor of every hit
    /// would detonate a large tree for a query the user is still typing, and it would do it on the
    /// keystroke rather than on the decision to go and look. Walking to a hit opens only the folders
    /// on the way to it, and folders opened by an earlier hit stay open, exactly as they would if
    /// the user had clicked their way down.
    public static func expansion(_ expanded: Set<String>, revealing hit: PaneSearchHit) -> Set<String> {
        expanded.union(hit.ancestorPaths)
    }
}

/// Which side(s) of a comparison a hit exists on. Only ever produced where there IS a second tree —
/// see `PaneTreeSearch.sides(for:otherPaths:)`.
public enum PaneSearchSide: String, Sendable, Equatable {
    /// The same relative path exists in the opposite pane's tree.
    case bothSides
    /// It does not — which is usually the reason for searching at all, so this is the one that
    /// carries the risk tint.
    case thisSideOnly
}

/// One matched row: where it is, and which run of its name matched.
public struct PaneSearchHit: Equatable, Sendable, Identifiable {
    /// The node's absolute path, which is also its outline identity and its selection tag.
    public let path: String
    /// The name as stored, unfolded — the emphasis is drawn on this.
    public let name: String
    public let isDirectory: Bool
    /// Path relative to the pane's tree root. Used to ask the opposite pane whether it has this
    /// item, and (as components) to open the Columns stack down to it.
    public let relativePath: String
    /// The folder names from the tree root down to this hit's PARENT — i.e. `relativePath` minus the
    /// hit itself. This is a `PaneBrowsePath`'s components: the columns that must be open for the
    /// hit's own row to be listed in the deepest one.
    public let parentComponents: [String]
    /// Absolute paths of the folders containing this hit, outermost first. The tree presentation
    /// expands exactly these to reveal it.
    public let ancestorPaths: [String]
    /// The matched run, as a range of character offsets into `name`.
    public let match: Range<Int>

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, relativePath: String,
                parentComponents: [String], ancestorPaths: [String], match: Range<Int>) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.relativePath = relativePath
        self.parentComponents = parentComponents
        self.ancestorPaths = ancestorPaths
        self.match = match
    }

    /// The column stack that lists this hit's own row in its deepest column.
    ///
    /// The hit itself is never a component, even when it is a folder: opening a matched folder's own
    /// column would show its CONTENTS and leave the row that matched behind in the column to its
    /// left, where the selection highlight the reveal is about to set could not be seen.
    public var browsePath: PaneBrowsePath { PaneBrowsePath(components: parentComponents) }
}

/// One pane's search results, stamped so a SwiftUI comparison never walks them.
///
/// **Why the stamp.** This is handed to `FileTreeView`, whose `==` is the pane's re-render gate, and
/// the payload is three dictionaries plus an array that a broad query can fill with thousands of
/// entries. Comparing those by value on every render is the same mistake `PaneTree` exists to
/// prevent, one type over. So equality is `(side, generation, query)` and nothing else.
///
/// **Why that is exact rather than approximate.** `generation` is the host's own counter, bumped on
/// every recomputation — the same construction as `PaneTree.version`, and exact for the same reason:
/// two values carrying the same side and generation came from the same computation, so there is no
/// way to reach different contents without the counter having moved. `query` rides along because it
/// is what the pane draws its emphasis from and is cheap to compare; it cannot disagree with the
/// generation, and comparing it makes the common “the user typed a character” case obvious.
public struct PaneSearchResults: Equatable, Sendable {
    /// Which pane these are for. See `PaneTree.Side` — the two panes keep independent counters, so a
    /// bare generation is only meaningful alongside the side that minted it.
    public let side: PaneTree.Side
    /// The host's recomputation counter at the moment these were built.
    public let generation: Int
    /// The live query. Empty means the search is not running and every accessor below answers as if
    /// there were no results at all.
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
        self.query = query
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

    /// Whether a search is running at all. Every presentation decision is gated on this, so a
    /// collapsed field or an empty query leaves the pane rendering exactly as it always did.
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
    /// Stated positively, what stays bright is every row on the way to an answer. That is what makes
    /// the dimming readable as “not this branch” rather than as an arbitrary wash — and it is why
    /// the rule reads the contained count rather than a list of ancestors: the count is already
    /// keyed by path for the “N matches” pill, and one map cannot disagree with itself.
    public func isDimmed(path: String) -> Bool {
        isActive && matchByPath[path] == nil && (containedCounts[path] ?? 0) == 0
    }

    /// The hit at `index`, or `nil` when there is none (no results, or an index left over from a
    /// longer previous result set).
    public func hit(at index: Int) -> PaneSearchHit? {
        hits.indices.contains(index) ? hits[index] : nil
    }

    /// The “N of M” a field shows, or `nil` when there is nothing to count. `nil` for an inactive
    /// search; “No matches” when the query found none, which is a real answer and must not be
    /// silence.
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
/// Wrapping, in both directions, because a find bar that stops at the end makes the user work out
/// where they are in a list they cannot see; and clamped rather than trusted, because the index
/// outlives the results it was an index into — every keystroke rebuilds them, and a walk to hit 6
/// of 7 followed by one more typed character routinely leaves an index past the end.
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
    /// Deliberately not “keep where you were”. The hits are rebuilt from scratch on every keystroke
    /// and are a different list each time — index 4 of the old list names an unrelated file in the
    /// new one, so preserving it would walk the user somewhere they never asked to go. Typing
    /// restarts the walk; ↩ continues it.
    public static let restart = 0
}
