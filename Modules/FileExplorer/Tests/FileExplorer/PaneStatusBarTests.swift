import Testing
import SwiftUI
import AppKit
import Foundation
import Design
import Sync
@testable import FileExplorer

/// Browse's status bar (roadmap RD6): what each segment says, the order they shed in, and the
/// census that feeds the cloud-only one.
@MainActor
@Suite struct PaneStatusBarTests {

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private func size<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: AnyView(view)).fittingSize
    }

    /// A full set of facts, so a rung that drops a segment can be seen to drop it.
    private func facts(itemCount: Int = 1_284,
                       selection: PaneStatusFacts.Selection? = .init(itemCount: 3,
                                                                     fileBytes: 42_600_000,
                                                                     cloudOnlyCount: 1),
                       cloudOnlyCount: Int? = 212,
                       ageSeconds: TimeInterval? = 240) -> PaneStatusFacts {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return PaneStatusFacts(itemCount: itemCount,
                               selection: selection,
                               cloudOnlyCount: cloudOnlyCount,
                               readAt: ageSeconds.map { now.addingTimeInterval(-$0) },
                               now: now)
    }

    private func file(_ path: String, size: Int? = 100) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 fileSize: size)
    }

    private func folder(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children)
    }

    // MARK: The words

    /// The three shapes of the count, including the one that is not a number. A pane with nothing
    /// in it says so; "0 items" reads as a measurement that came back empty-handed.
    @Test func theItemCountReadsAsAStateAtZeroAndAsANumberAbove() {
        #expect(facts(itemCount: 0).itemsCaption == "Empty")
        #expect(facts(itemCount: 1).itemsCaption == "1 item")
        #expect(facts(itemCount: 2).itemsCaption == "2 items")
        // Grouped: a bare `1284` in 10pt type is a smear.
        #expect(facts(itemCount: 1_284).itemsCaption.hasPrefix("1,284 items"))
    }

    /// The selection segment carries the size and the cloud clause, and **drops each one when it
    /// would be furniture** — a `0 in the cloud` on every ordinary selection is a fact about
    /// nothing, and a `Zero KB` under a folder-only selection is a number this bar is not allowed
    /// to know (folder byte sizes are not in the tree).
    @Test func theSelectionSegmentDropsTheClausesThatWouldSayNothing() {
        let both = PaneStatusFacts.Selection(itemCount: 3, fileBytes: 42_600_000, cloudOnlyCount: 1)
        let caption = PaneStatusFacts.selectionCaption(both)
        #expect(caption.hasPrefix("3 selected · "))
        #expect(caption.hasSuffix(", 1 in the cloud"))

        let noCloud = PaneStatusFacts.Selection(itemCount: 3, fileBytes: 42_600_000, cloudOnlyCount: 0)
        #expect(!PaneStatusFacts.selectionCaption(noCloud).contains("in the cloud"))

        let foldersOnly = PaneStatusFacts.Selection(itemCount: 2, fileBytes: 0, cloudOnlyCount: 0)
        #expect(PaneStatusFacts.selectionCaption(foldersOnly) == "2 selected",
                "a folder-only selection grew a size it has no way to know")
    }

    /// **A dash, never a zero, while the census walks.** The roadmap's brief rules out "a number
    /// that is about to change" by name, and `0 in the cloud only` over a tree that has not been
    /// statted yet is exactly that — and it is the one wrong answer that reads as a real one.
    @Test func theCloudOnlySegmentReadsADashUntilTheCensusLands() {
        #expect(facts(cloudOnlyCount: nil).cloudOnlyCaption == "— in the cloud only")
        #expect(facts(cloudOnlyCount: 0).cloudOnlyCaption == "0 in the cloud only")
        #expect(facts(cloudOnlyCount: 212).cloudOnlyCaption == "212 in the cloud only")
    }

    /// The freshness is `ScanFreshness`'s sentence, not a fifth spelling of one — and it is absent
    /// rather than "never" when nothing has been loaded, because a pane with no tree has nothing
    /// under the bar for the word to be about.
    @Test func theFreshnessSegmentIsScanFreshnessAndVanishesBeforeTheFirstLoad() {
        #expect(facts(ageSeconds: 240).freshness?.text == "Scanned 4m ago")
        #expect(facts(ageSeconds: 240).freshness?.isStale == false)
        #expect(facts(ageSeconds: ScanFreshness.staleAfter + 60).freshness?.isStale == true)
        #expect(facts(ageSeconds: nil).freshness == nil)
        #expect(!facts(ageSeconds: nil).segments(.full).contains { $0.contains("Scanned") },
                "the full rung drew a freshness segment for a pane that has loaded nothing")
    }

    // MARK: The ladder

    /// **The order they shed in, stated as segments.** Each rung is the one above it with its
    /// rightmost segment gone, and the item count survives every step — which is the roadmap's
    /// brief ("the item count is what stays longest") turned into something that fails.
    @Test func theRungsShedFromTheRightAndKeepTheItemCount() {
        let f = facts()
        #expect(f.segments(.full).count == 4)
        for rung in PaneStatusFacts.Rung.allCases {
            #expect(f.segments(rung).first == f.itemsCaption,
                    "the \(rung) rung leads with \(String(describing: f.segments(rung).first))")
        }
        let counts = PaneStatusFacts.Rung.allCases.map { f.segments($0).count }
        #expect(counts == [4, 3, 2, 1], "the rungs carry \(counts) segments")
        // Each rung is a strict prefix of the one before it: nothing is re-ordered on the way down.
        for (wider, narrower) in zip(PaneStatusFacts.Rung.allCases, PaneStatusFacts.Rung.allCases.dropFirst()) {
            #expect(Array(f.segments(wider).prefix(f.segments(narrower).count)) == f.segments(narrower),
                    "\(narrower) is not a prefix of \(wider) — a segment moved rather than shedding")
        }
    }

    /// **Every rung is actually offered to `ViewThatFits`.** The candidates are spelled out (a
    /// `ForEach` there is one child, and the ladder would collapse to a single candidate), so a
    /// rung added to the enum and forgotten in the view is unreachable at every width — silently,
    /// with the strip simply truncating.
    @Test func theLadderOffersEveryRungInSheddingOrder() throws {
        let source = try Self.barSource()
        let offered = PaneStatusFacts.Rung.allCases.map { "strip(.\($0))" }
        var cursor = source.startIndex
        for call in offered {
            let found = try #require(source.range(of: call, range: cursor..<source.endIndex),
                                     "\(call) is never offered to ViewThatFits")
            cursor = found.upperBound
        }
    }

    /// **The rungs have to be strictly narrower in order, or `ViewThatFits` never reaches them** —
    /// it takes the first candidate that fits, so a "narrower" rung measuring wider than its
    /// predecessor is dead code no width can select. Same failure, and same check, as
    /// `EditorLayoutTests.eachStatusRungIsNarrowerThanTheOneBeforeIt`.
    @Test func eachRungIsNarrowerThanTheOneBeforeIt() {
        for scale in scales {
            let widths = PaneStatusFacts.Rung.allCases.map {
                size(PaneStatusBar(facts: facts(), forcedRung: $0).environment(\.appFontScale, scale)).width
            }
            #expect(widths == widths.sorted(by: >),
                    "at scale \(scale) the rungs measure \(widths), which is not strictly narrowing")
        }
    }

    /// The positive control for the measurement above: without it, the widths would agree over a
    /// strip that drew no numbers at all.
    @Test func theBarReallyDrawsItsNumbers() {
        let small = size(PaneStatusBar(facts: facts(itemCount: 1, cloudOnlyCount: 0), forcedRung: .full)).width
        let large = size(PaneStatusBar(facts: facts(itemCount: 1_284_000, cloudOnlyCount: 212_000), forcedRung: .full)).width
        #expect(large > small + 20, "the full rung measured \(small) with tiny numbers and \(large) with large ones")
    }

    /// **VoiceOver is never shed.** Shedding is a width bargain and VoiceOver has no width, so a
    /// narrow pane must not make the cloud-only count unspeakable — and the staleness has to be in
    /// words somewhere, because the visible segment reads identically fresh or stale.
    @Test func theSpokenLabelCarriesEveryFactWhateverRungIsDrawn() {
        let stale = facts(ageSeconds: ScanFreshness.staleAfter + 60)
        let label = stale.accessibilityLabel
        #expect(label.contains("1,284 items"))
        #expect(label.contains("3 selected"))
        #expect(label.contains("212 in the cloud only"))
        #expect(label.contains("may be out of date"),
                "staleness reaches the eye through colour and the ear through nothing at all")
    }

    // MARK: The selection's own numbers

    /// Folders are in the count and out of the bytes, for the reason `DetailsSelectionSummary`
    /// gives: a folder's byte size is not in the tree, and walking for it is what this bar exists
    /// not to do.
    @Test func theSelectionCountsFoldersAndSizesOnlyFiles() {
        let nodes = [file("/a/one.pdf", size: 100), file("/a/two.pdf", size: 250),
                     folder("/a/sub", [file("/a/sub/deep.pdf", size: 9_999)])]
        let selection = PaneStatusFacts.Selection.make(nodes: nodes) { _ in nil }
        #expect(selection?.itemCount == 3)
        #expect(selection?.fileBytes == 350, "a folder contributed bytes, or its children did")
    }

    /// **An unstatted row is not a cloud row.** The badge memo answers nil for a path nobody has
    /// looked at, and folding that into "yes" would put a number in the bar that no syscall backs.
    @Test func onlyKnownCloudOnlyPathsCountTowardTheSelectionsCloudClause() {
        let nodes = [file("/a/here.pdf"), file("/a/cloud.pdf"), file("/a/unknown.pdf")]
        let known: [String: Bool] = ["/a/here.pdf": false, "/a/cloud.pdf": true]
        let selection = PaneStatusFacts.Selection.make(nodes: nodes) { known[$0] }
        #expect(selection?.cloudOnlyCount == 1)
        #expect(PaneStatusFacts.Selection.make(nodes: []) { _ in nil } == nil,
                "an empty selection produced a segment saying nothing is selected")
    }

    // MARK: The census

    /// `SF_DATALESS`, spelled here because `MaterializationStatus.datalessFlag` is internal to
    /// `Sync` and this suite is in another module. It is checked against the module's own predicate
    /// in every test that uses it (`isDataless` is public), so the two cannot drift.
    private let datalessFlag: UInt32 = 0x4000_0000

    /// The local flag constant really is the one `Sync` recognises — without this the census tests
    /// below would pass over a stat stub returning a number that means nothing.
    @Test func theTestsDatalessFlagIsTheOneSyncRecognises() {
        #expect(MaterializationStatus.isDataless(flags: datalessFlag))
        #expect(!MaterializationStatus.isDataless(flags: 0))
    }

    /// It counts files, walks into folders, and **stats no directory** — `SF_DATALESS` is a
    /// content flag and a folder is never a placeholder for content.
    @Test func theCensusCountsDatelessFilesAcrossTheWholeTree() async {
        let tree = [folder("/a", [file("/a/one.pdf"), file("/a/two.pdf"),
                                  folder("/a/sub", [file("/a/sub/three.pdf")])]),
                    file("/b.pdf")]
        let cloud: Set<String> = ["/a/two.pdf", "/a/sub/three.pdf"]
        // The stat seam is `@Sendable` (it runs off the main actor), so the recorder has to be
        // too — a captured `var` cannot be written from inside it.
        let statted = StattedPaths()
        let flag = datalessFlag
        let count = await CloudOnlyCensus.count(in: tree) { path in
            statted.record(path)
            return cloud.contains(path) ? flag : 0
        }
        let seen = statted.all
        #expect(count == 2)
        #expect(!seen.contains("/a") && !seen.contains("/a/sub"),
                "the census statted a directory — \(seen)")
        #expect(seen.count == 4, "the census missed a file — it statted \(seen)")
    }

    /// A path that cannot be statted at all is **not** counted: "no answer" is not "in the cloud".
    /// The distinction is `MaterializationStatus.isCloudOnlyIfKnown`'s, and this is the one caller
    /// that would silently turn a deleted file into a cloud file.
    @Test func anUnstattablePathIsNotCountedAsCloudOnly() async {
        let count = await CloudOnlyCensus.count(in: [file("/gone.pdf")]) { _ in nil }
        #expect(count == 0)
    }

    /// **Cancelled comes back nil, not zero.** A superseded census must leave the bar reading `—`
    /// until the census for the tree now on screen finishes; publishing its partial total as an
    /// answer is the "number about something else" the restart exists to avoid.
    @Test func aCancelledCensusAnswersNilRatherThanItsPartialTotal() async {
        let many = (0..<(CloudOnlyCensus.batchSize * 3)).map { file("/a/\($0).pdf") }
        let flag = datalessFlag
        let task = Task { await CloudOnlyCensus.count(in: many) { _ in flag } }
        task.cancel()
        #expect(await task.value == nil)
    }

    /// A `Sendable` box for what the stub was asked about, so the stat seam can stay `@Sendable`.
    private final class StattedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func record(_ path: String) { lock.withLock { _ = paths.insert(path) } }
        var all: Set<String> { lock.withLock { paths } }
    }

    private static func barSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FileExplorer
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let source = try String(contentsOf: packageRoot
            .appendingPathComponent("Sources/FileExplorer/PaneStatusBar.swift"), encoding: .utf8)
        try #require(!source.isEmpty)
        return source
    }
}
