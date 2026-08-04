import Testing
import Foundation
@testable import Sync

/// The pane search's matching, ordering, annotation and reveal arithmetic.
///
/// Everything the pane draws while searching is decided here, so this is where it can be pinned
/// without mounting anything: which rows matched, which run of each name, which folders must stay
/// bright, which side a hit is on, and where ↩ leaves you.
@Suite struct PaneTreeSearchTests {

    // MARK: - Fixture
    //
    // Documents/Finance/{Tax Return 2025.pdf, tax-notes.md, Receipts 2025.numbers}
    // Documents/IRS/{taxes.csv}
    // Movies/{Holiday.mov}
    //
    // Shaped after the mockup so the counts below are the ones on the drawing.

    static let root = "/root"

    static func file(_ path: String) -> FileNode {
        FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    static func folder(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent,
                 isDirectory: true, children: children)
    }

    static func tree(side: PaneTree.Side = .left, version: Int = 1) -> PaneTree {
        PaneTree(side: side, version: version, nodes: [
            folder("Documents", [
                folder("Documents/Finance", [
                    file("Documents/Finance/Tax Return 2025.pdf"),
                    file("Documents/Finance/tax-notes.md"),
                    file("Documents/Finance/Receipts 2025.numbers"),
                ]),
                folder("Documents/IRS", [
                    file("Documents/IRS/taxes.csv"),
                ]),
            ]),
            folder("Movies", [
                file("Movies/Holiday.mov"),
            ]),
        ])
    }

    private func hits(_ query: String) -> [PaneSearchHit] {
        PaneTreeSearch.hits(in: Self.tree(), query: query)
    }

    // MARK: - Matching

    @Test("A substring of a name matches, whatever its case")
    func matchingIsCaseInsensitive() {
        let found = hits("tax").map(\.name)
        #expect(found == ["Tax Return 2025.pdf", "tax-notes.md", "taxes.csv"])
    }

    /// The reason the fold exists rather than a plain `lowercased()`: a name typed without its
    /// accent has to find the file that carries one, in both directions.
    @Test("Diacritics fold, both ways")
    func matchingIsDiacriticInsensitive() {
        let tree = PaneTree(side: .left, version: 1, nodes: [Self.file("Café Menu.pdf")])
        #expect(PaneTreeSearch.hits(in: tree, query: "cafe").count == 1)
        #expect(PaneTreeSearch.hits(in: tree, query: "CAFÉ").count == 1)
    }

    /// The same name spelled decomposed (as some volumes hand it back) must be found by a query
    /// typed precomposed.
    ///
    /// **This pins a property, not a line.** There is no explicit precompose in the fold to delete —
    /// the version that had one survived its removal with this test green, because Swift compares
    /// `Character`s on canonical equivalence and the two spellings simply are one character. What
    /// this catches is the change that WOULD break it: a matcher rewritten to compare
    /// `unicodeScalars`, which is where canonical equivalence stops applying. The scalar assertion
    /// below is the fixture's own proof that the two spellings are genuinely different input.
    @Test("A decomposed name is found by a precomposed query")
    func matchingIsNormalizationInsensitive() {
        let decomposed = "Cafe\u{0301} Menu.pdf"
        #expect(Array(decomposed.unicodeScalars) != Array("Café Menu.pdf".unicodeScalars))
        let tree = PaneTree(side: .left, version: 1, nodes: [Self.file(decomposed)])
        #expect(PaneTreeSearch.hits(in: tree, query: "Café").count == 1)
    }

    @Test("An empty or whitespace-only query finds nothing at all")
    func anEmptyQueryIsNotASearch() {
        #expect(hits("").isEmpty)
        #expect(hits("   ").isEmpty)
    }

    @Test("A query that matches nothing finds nothing — and does not crash on a long one")
    func aQueryLongerThanEveryNameFindsNothing() {
        #expect(hits("zzz").isEmpty)
        #expect(hits(String(repeating: "x", count: 400)).isEmpty)
    }

    // MARK: - The matched run

    /// The emphasis is drawn on the ORIGINAL name, so the range has to be in the original's
    /// character offsets. `tax-notes.md` matches at 0; `Tax Return 2025.pdf` at 0; `taxes.csv` at 0.
    @Test("The matched run is reported in the original name's character offsets")
    func theMatchRangeIndexesTheOriginalName() throws {
        let hit = try #require(hits("notes").first)
        #expect(hit.name == "tax-notes.md")
        #expect(hit.match == 4..<9)
        #expect(String(Array(hit.name)[hit.match]) == "notes")
    }

    /// The alignment case the parallel index exists for: “ß” folds to “ss”, so a match found at
    /// folded offset 3 sits at original offset 2. A naive `folding()` + offset would highlight the
    /// wrong characters here — and would run past the end for a match at the tail.
    @Test("A fold that changes length still highlights the right characters")
    func theMatchRangeSurvivesALengthChangingFold() throws {
        let tree = PaneTree(side: .left, version: 1, nodes: [Self.file("Straße.txt")])
        let hit = try #require(PaneTreeSearch.hits(in: tree, query: "strasse").first)
        #expect(String(Array(hit.name)[hit.match]) == "Straße")
    }

    /// A match whose LAST character folds into two must still include that character. Taking the
    /// source index one past the run's end (rather than the last character's own index, plus one)
    /// is the off-by-one that drops it.
    @Test("A match ending on a multi-character fold keeps its last character")
    func theMatchRangeIncludesAFinalExpandedCharacter() throws {
        let tree = PaneTree(side: .left, version: 1, nodes: [Self.file("Maß")])
        let hit = try #require(PaneTreeSearch.hits(in: tree, query: "mass").first)
        #expect(String(Array(hit.name)[hit.match]) == "Maß")
    }

    @Test("Only the first run of a name is emphasized — a name is one hit, not two")
    func onlyTheFirstRunMatches() throws {
        let tree = PaneTree(side: .left, version: 1, nodes: [Self.file("tax-tax.pdf")])
        let found = PaneTreeSearch.hits(in: tree, query: "tax")
        #expect(found.count == 1)
        #expect(found[0].match == 0..<3)
    }

    // MARK: - Order and position

    /// ↩ has to walk DOWN the pane, so the hits must arrive in the order the outline draws them:
    /// depth-first, pre-order. Finance's two hits precede IRS's, which precedes nothing in Movies.
    @Test("Hits arrive in the order the pane lists them")
    func hitsArriveInOutlineOrder() {
        #expect(hits("tax").map(\.relativePath) == [
            "Documents/Finance/Tax Return 2025.pdf",
            "Documents/Finance/tax-notes.md",
            "Documents/IRS/taxes.csv",
        ])
    }

    @Test("A hit knows its ancestors, outermost first — that is what the tree expands")
    func aHitCarriesItsAncestors() throws {
        let hit = try #require(hits("notes").first)
        #expect(hit.ancestorPaths == ["/root/Documents", "/root/Documents/Finance"])
    }

    /// The Columns reveal writes exactly this. The hit itself is never a component — opening a
    /// matched FOLDER's own column would list its contents and leave the matched row behind in the
    /// column to the left, where the selection the reveal sets could not be seen.
    @Test("A hit's browse path opens the columns down to its parent, never into itself")
    func aHitsBrowsePathStopsAtItsParent() throws {
        let file = try #require(hits("notes").first)
        #expect(file.browsePath.components == ["Documents", "Finance"])

        let folder = try #require(PaneTreeSearch.hits(in: Self.tree(), query: "Finance").first)
        #expect(folder.isDirectory)
        #expect(folder.browsePath.components == ["Documents"])
    }

    @Test("A top-level hit has no ancestors and an empty browse path")
    func aTopLevelHitRevealsNothing() throws {
        let hit = try #require(PaneTreeSearch.hits(in: Self.tree(), query: "Movies").first)
        #expect(hit.ancestorPaths.isEmpty)
        #expect(hit.browsePath.isEmpty)
    }

    // MARK: - Contained counts

    @Test("A folder reports the hits beneath it, at every level")
    func containedCountsAccumulateUpTheTree() {
        let counts = PaneTreeSearch.containedMatchCounts(hits("tax"))
        #expect(counts["/root/Documents"] == 3)
        #expect(counts["/root/Documents/Finance"] == 2)
        #expect(counts["/root/Documents/IRS"] == 1)
        #expect(counts["/root/Movies"] == nil)
    }

    /// A folder that matches on its own name is a hit; counting itself as containing one would make
    /// it claim a match inside it that need not exist.
    @Test("A matching folder does not count itself")
    func aMatchingFolderDoesNotCountItself() {
        let counts = PaneTreeSearch.containedMatchCounts(hits("Movies"))
        #expect(counts["/root/Movies"] == nil)
    }

    // MARK: - Sides

    @Test("A hit whose relative path exists in the other tree reads as both sides")
    func sidesAreDecidedByTheOtherTreesPaths() {
        let other: Set<String> = ["Documents", "Documents/Finance",
                                  "Documents/Finance/Tax Return 2025.pdf"]
        let sides = PaneTreeSearch.sides(for: hits("tax"), otherPaths: other)
        #expect(sides["/root/Documents/Finance/Tax Return 2025.pdf"] == .bothSides)
        #expect(sides["/root/Documents/Finance/tax-notes.md"] == .thisSideOnly)
        #expect(sides["/root/Documents/IRS/taxes.csv"] == .thisSideOnly)
    }

    /// The rail has no opposite pane, so “left only” is a statement about a comparison it is not
    /// making — it must produce no annotation at all rather than a wrong one.
    @Test("With no opposite pane there is no side annotation")
    func aSingleSourceSurfaceAnnotatesNothing() {
        #expect(PaneTreeSearch.sides(for: hits("tax"), otherPaths: nil).isEmpty)
    }

    /// The other tree's paths are relative and keyed at every level, and a spelling difference
    /// between two providers is one key rather than two — see `matchingIsNormalizationInsensitive`
    /// for why that needs no code, and what would break it.
    @Test("The other tree's paths are relative, per level, and agree across spellings")
    func relativePathsAreKeyedPerLevel() {
        let decomposed = PaneTree(side: .right, version: 1, nodes: [
            Self.folder("Cafe\u{0301}", [Self.file("Cafe\u{0301}/menu.pdf")])
        ])
        let paths = PaneTreeSearch.relativePaths(in: decomposed)
        #expect(paths == ["Café", "Café/menu.pdf"])
    }

    /// Case is deliberately significant: the diff engine pairs on exact relative paths, so a
    /// case-insensitive answer here would claim “both sides” for two items the Differences table
    /// reports separately.
    @Test("A case difference is not the same path")
    func sidesAreCaseSensitive() {
        let other: Set<String> = ["documents/finance/tax-notes.md"]
        let sides = PaneTreeSearch.sides(for: hits("notes"), otherPaths: other)
        #expect(sides["/root/Documents/Finance/tax-notes.md"] == .thisSideOnly)
    }

    // MARK: - Reveal

    @Test("Revealing a hit opens exactly its own ancestors, and keeps what was already open")
    func expansionAddsOnlyTheHitsAncestors() throws {
        let hit = try #require(hits("taxes").first)
        let after = PaneTreeSearch.expansion(["/root/Movies"], revealing: hit)
        #expect(after == ["/root/Movies", "/root/Documents", "/root/Documents/IRS"])
    }

    /// The half that matters for a large tree: walking to one hit must not open the folders that
    /// hold the others.
    @Test("Revealing one hit does not open another hit's folder")
    func expansionIsPerHitNotPerQuery() throws {
        let all = hits("tax")
        let irs = try #require(all.last)
        let after = PaneTreeSearch.expansion([], revealing: irs)
        #expect(!after.contains("/root/Documents/Finance"))
    }

    // MARK: - Walking

    @Test("↩ walks forward and wraps; ⇧↩ walks back and wraps")
    func walkingWrapsInBothDirections() {
        #expect(PaneSearchWalk.advance(0, count: 3, reverse: false) == 1)
        #expect(PaneSearchWalk.advance(2, count: 3, reverse: false) == 0)
        #expect(PaneSearchWalk.advance(0, count: 3, reverse: true) == 2)
        #expect(PaneSearchWalk.advance(2, count: 3, reverse: true) == 1)
    }

    /// The index outlives the results it indexes — every keystroke rebuilds them — so a stale index
    /// past the end must land somewhere real rather than crashing or sticking.
    @Test("An index left over from a longer result set is clamped, not trusted")
    func walkingClampsAStaleIndex() {
        #expect(PaneSearchWalk.advance(9, count: 3, reverse: false) == 0)
        #expect(PaneSearchWalk.advance(9, count: 3, reverse: true) == 1)
        #expect(PaneSearchWalk.advance(-4, count: 3, reverse: false) == 1)
    }

    @Test("Walking an empty result set stays at zero rather than dividing by it")
    func walkingNothingIsHarmless() {
        #expect(PaneSearchWalk.advance(0, count: 0, reverse: false) == 0)
        #expect(PaneSearchWalk.advance(5, count: 0, reverse: true) == 0)
    }
}

/// `PaneSearchResults` — the stamped value the pane renders from, and the accessors that decide
/// what each row draws.
@Suite struct PaneSearchResultsTests {

    private func results(_ query: String, generation: Int = 1,
                         otherPaths: Set<String>? = nil) -> PaneSearchResults {
        PaneSearchResults(side: .left, generation: generation, query: query,
                          tree: PaneTreeSearchTests.tree(), otherPaths: otherPaths)
    }

    @Test("An empty query is not an active search, and draws nothing")
    func anEmptyQueryIsInactive() {
        let idle = results("")
        #expect(!idle.isActive)
        #expect(idle.hits.isEmpty)
        #expect(!idle.isDimmed(path: "/root/Movies"))
        #expect(idle.summary(at: 0) == nil)
    }

    /// …and neither is whitespace. Matching trims, so a lone space found nothing — but the results
    /// judged themselves ACTIVE from the raw text, which dimmed every row off a path to an answer
    /// and put "No matches" in the field for a keystroke that asked nothing.
    @Test("A whitespace-only query is not a search either")
    func aWhitespaceQueryIsInactive() {
        let spaces = results("   ")
        #expect(!spaces.isActive)
        #expect(!spaces.isDimmed(path: "/root/Movies"))
        #expect(spaces.summary(at: 0) == nil)
    }

    /// The same effective query typed with stray spaces is the same search, so the pane must not
    /// re-render for it — `==` reads the stored (normalized) query.
    @Test("Padding a query does not make it a different one")
    func paddingDoesNotChangeTheQuery() {
        #expect(results("tax") == results(" tax "))
    }

    /// The dim rule, stated as the pane draws it: matches stay bright, so do the folders on the way
    /// to them, and everything else recedes.
    @Test("Only rows off every path to an answer dim")
    func dimmingSparesMatchesAndTheirAncestors() {
        let found = results("tax")
        #expect(!found.isDimmed(path: "/root/Documents/Finance/tax-notes.md"))
        #expect(!found.isDimmed(path: "/root/Documents"))
        #expect(!found.isDimmed(path: "/root/Documents/Finance"))
        #expect(!found.isDimmed(path: "/root/Documents/IRS"))
        #expect(found.isDimmed(path: "/root/Documents/Finance/Receipts 2025.numbers"))
        #expect(found.isDimmed(path: "/root/Movies"))
    }

    @Test("The counter reads N of M, and says so when there is nothing")
    func theSummaryCountsTheWalk() {
        #expect(results("tax").summary(at: 0) == "1 of 3")
        #expect(results("tax").summary(at: 2) == "3 of 3")
        #expect(results("zzz").summary(at: 0) == "No matches")
    }

    /// A stale index must not make the counter lie or trap — it reads as the last hit, which is
    /// where a clamped walk would put you.
    @Test("A stale index is clamped in the counter too")
    func theSummaryClampsAStaleIndex() {
        #expect(results("tax").summary(at: 99) == "3 of 3")
        #expect(results("tax").hit(at: 99) == nil)
    }

    @Test("The side annotation reaches the row that asked for it")
    func sidesAreReadableByPath() {
        let annotated = results("tax", otherPaths: ["Documents/Finance/Tax Return 2025.pdf"])
        #expect(annotated.side(forPath: "/root/Documents/Finance/Tax Return 2025.pdf") == .bothSides)
        #expect(annotated.side(forPath: "/root/Documents/Finance/tax-notes.md") == .thisSideOnly)
        #expect(annotated.side(forPath: "/root/Movies") == nil)
    }

    // MARK: - Where the walk lands after a recomputation

    /// A republish must not move the user. The pane republishes on every scan, copy and
    /// hidden-files toggle — and the OTHER pane's republish counts too — so restarting the walk
    /// there yanks them to the first hit and, because the reveal fires on the index, scrolls them
    /// away from the row they were reading.
    @Test("A republish keeps the walk on the file it was standing on")
    func aRepublishFollowsThePath() {
        let before = results("tax", generation: 1)
        let after = results("tax", generation: 2)
        #expect(after.walkIndex(after: before, standingAt: 2) == 2)
    }

    /// …and it follows the FILE, not the number.
    ///
    /// **The fixture has to make the two rules disagree, or it proves nothing.** The first version
    /// of this test used a shrunken tree where the old index was simply out of range, so
    /// "follow the index" fell back to the top — which was also the expected answer, and the test
    /// passed against a mutation that ignored the path entirely. Here the reordered tree still has
    /// three hits, so index 2 is perfectly valid and names a DIFFERENT file: following the number
    /// answers 2, following the path answers 0.
    @Test("It follows the path, not the index")
    func theWalkFollowsTheFileNotTheNumber() throws {
        let before = results("tax", generation: 1)
        let standing = try #require(before.hit(at: 2))
        #expect(standing.name == "taxes.csv")

        // The same three files, with IRS listed before Finance — so `taxes.csv` is now hit 0 while
        // hit 2 is `tax-notes.md`.
        let reordered = PaneSearchResults(
            side: .left, generation: 3, query: "tax",
            tree: PaneTree(side: .left, version: 2, nodes: [
                PaneTreeSearchTests.folder("Documents", [
                    PaneTreeSearchTests.folder("Documents/IRS", [
                        PaneTreeSearchTests.file("Documents/IRS/taxes.csv"),
                    ]),
                    PaneTreeSearchTests.folder("Documents/Finance", [
                        PaneTreeSearchTests.file("Documents/Finance/Tax Return 2025.pdf"),
                        PaneTreeSearchTests.file("Documents/Finance/tax-notes.md"),
                    ]),
                ]),
            ]), otherPaths: nil)
        #expect(reordered.hits.count == 3, "index 2 must still be valid, or the rules cannot disagree")
        #expect(reordered.hit(at: 0)?.path == standing.path)
        #expect(reordered.hit(at: 2)?.path != standing.path)
        #expect(reordered.walkIndex(after: before, standingAt: 2) == 0)
    }

    /// Typing is the opposite case: a different query is a different list, where the old index names
    /// an unrelated file.
    @Test("A changed query restarts the walk")
    func aChangedQueryRestartsTheWalk() {
        let before = results("tax", generation: 1)
        let after = results("notes", generation: 2)
        #expect(after.walkIndex(after: before, standingAt: 2) == PaneSearchWalk.restart)
    }

    /// The file they were standing on stopped matching — deleted, renamed, filtered out. The top is
    /// the only honest answer.
    @Test("A hit that is gone restarts the walk")
    func aVanishedHitRestartsTheWalk() {
        let before = results("tax", generation: 1)
        let empty = PaneSearchResults(side: .left, generation: 2, query: "tax",
                                      tree: PaneTree(side: .left, version: 2, nodes: []),
                                      otherPaths: nil)
        #expect(empty.walkIndex(after: before, standingAt: 2) == PaneSearchWalk.restart)
    }

    /// A stale index into the previous results resolves to no path at all, which must not trap.
    @Test("A stale standing index is survivable")
    func aStaleStandingIndexRestartsTheWalk() {
        let before = results("tax", generation: 1)
        let after = results("tax", generation: 2)
        #expect(after.walkIndex(after: before, standingAt: 99) == PaneSearchWalk.restart)
    }

    // MARK: - The stamp

    /// The whole point of the type: the payload is three maps and an array a broad query can fill
    /// with thousands of entries, and `FileTreeView.==` compares this on every render.
    @Test("Two results from the same computation compare equal without walking the hits")
    func equalityIsTheStamp() {
        #expect(results("tax") == results("tax"))
    }

    @Test("A recomputation is noticed")
    func aNewGenerationIsNoticed() {
        #expect(results("tax", generation: 1) != results("tax", generation: 2))
    }

    @Test("A changed query is noticed")
    func aNewQueryIsNoticed() {
        #expect(results("tax") != results("taxes"))
    }

    @Test("The other pane's results are never mistaken for this one's")
    func theSideIsNoticed() {
        let left = PaneSearchResults(side: .left, generation: 1, query: "tax",
                                     tree: PaneTreeSearchTests.tree(), otherPaths: nil)
        let right = PaneSearchResults(side: .right, generation: 1, query: "tax",
                                      tree: PaneTreeSearchTests.tree(side: .right), otherPaths: nil)
        #expect(left != right)
    }

    @Test("The resting value is inactive and empty on both sides")
    func theEmptyValueIsInert() {
        #expect(!PaneSearchResults.empty(side: .left).isActive)
        #expect(PaneSearchResults.empty(side: .right).hits.isEmpty)
    }
}
