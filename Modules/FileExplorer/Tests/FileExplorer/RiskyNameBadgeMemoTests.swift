import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Holds the row badge to the cost model `RiskyNameBadgeCache` was designed against: a pane asks
/// about a name on every visible row of every render pass, and the rules run **once per distinct
/// name, ever**.
///
/// This suite measures the tree pane (`FileTreeView`); `RiskyNameBadgeColumnsMemoTests` measures the
/// columns pane against the same fixture. Both are real call sites of `riskyNameReason`, and the
/// claim is meant to hold for whichever one is on screen.
///
/// **Why a count and not a stopwatch.** The obvious net was the existing
/// `RiskyNameBadgeCostBenchmark` turned into a load-scaled timing bar, like
/// `ColumnClickCostBenchmark`. It would not work. The badge's whole measured cost is +0.03–0.24 ms
/// against a ~9 ms pane re-render — smaller than the spread *within* one arm, on a Mac that is also
/// the CI runner and routinely sits at load 5–8 (three identical runs during the original
/// measurement gave medians of 8.66, 10.50 and 9.16 ms; runs while writing these tests saw load
/// above 24). Deleting the memo outright — the single regression most worth catching — swaps a
/// ~1.5 µs dictionary hit for a ~7 µs live check on ~60 rows: a few hundred microseconds, an order
/// of magnitude under the noise. A bar loose enough not to flake could not see it, and a net that
/// catches nothing while looking like protection is worse than no net.
///
/// Counting evaluations measures the same quantity the design was argued from — the table in the
/// cache's doc comment is a per-miss rate — and it is exact, needs no calibration, and gives the
/// same verdict on a busy machine as an idle one. So these cases are deliberately NOT
/// `.machinePinned`: there is nothing here for a machine to be wrong about.
///
/// **Counted by name, not by tally.** `RiskyNameBadgeCache.onEvaluateForTesting` reports the name
/// evaluated, and every case counts only names from its own fixture. That is not fastidiousness — a
/// plain process-wide counter was tried and flaked, because `DifferencesView` asks the same memo and
/// the suites that mount one run alongside these. See the seam's own note.
///
/// **What it catches.** Remove the memo, defeat it, key it on anything that varies per row or per
/// pass, or add an eager pass over the published tree, and these counts move by more than an order
/// of magnitude — measured, by mutation, for the first and the last of those.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgeMemoTests {

    final class Box: ObservableObject {
        @Published var selection: Set<String> = []
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let otherTree: PaneTree
        let delegate: FileActionDelegate
        let downloads: NotificationCenter

        var body: some View {
            FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: BadgeMemoFixture.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: .empty,
                downloadChannel: downloads)
        }
    }

    /// The pane is mounted on a `NotificationCenter` of this suite's own.
    ///
    /// It wants nothing from `.cloudDownloadRequested`, but a mounted `FileTreeView` subscribes
    /// whether the test asks or not, so on `.default` it would accept any parallel suite's `.left`
    /// post — and accepting one republishes `downloads.requests`, which rebuilds this pane's body.
    ///
    /// **Measured, not assumed, because the obvious worry is wrong.** Posting one foreign `.left`
    /// request onto this pane during `aMountedPaneEvaluatesEachDistinctNameExactlyOnce` cost it a
    /// whole extra render — `riskyNameReason` asks went 861 → 984 — and moved the evaluation count
    /// by exactly nothing, 15 → 15. The memo absorbs it, and none of the three cases mounting
    /// through here counts renders: they compare evaluations against the distinct names the pane
    /// asked about, against zero for later passes, and against a collapsed subtree that stays
    /// unrealized. All three are invariant under a render nobody here triggered, so this channel is
    /// not propping up any verdict.
    ///
    /// It is here because the rule is the rule (see `docs/flaky-tests.md` mechanism 9) and because
    /// the render is not free: 123 wasted asks and a full pass through the pane's body, inside a
    /// `.serialized` suite, at a moment another suite chose. A count-based test earns its exactness
    /// by having nothing else able to touch what it counts — including the parts that would have
    /// been absorbed this time.
    private func mount(_ box: Box, delegate: FileActionDelegate) -> NSWindow {
        BadgeMemoMount.window(Harness(box: box,
                                      tree: BadgeMemoFixture.tree(side: .left),
                                      otherTree: BadgeMemoFixture.tree(side: .right),
                                      delegate: delegate,
                                      downloads: NotificationCenter()))
    }

    private func renderPass(_ window: NSWindow, _ box: Box, selecting index: Int) {
        BadgeMemoMount.renderPass(window) { box.selection = [BadgeMemoFixture.fileID(index)] }
    }

    // MARK: - The memo, on its own

    /// The floor case, with no view in it: asking the same name repeatedly runs the rules once.
    /// Fails first, and most legibly, if the memo lookup is ever removed.
    @Test func askingOneNameRepeatedlyRunsTheRulesOnce() {
        RiskyNameBadgeCache.resetForTesting()
        BadgeEvaluationLog.record { log in
            for _ in 0..<500 {
                _ = RiskyNameBadgeCache.reason(name: "\(BadgeMemoFixture.token)Statement 2026 ",
                                               isDirectory: false, provider: .oneDrive)
            }
            #expect(log.count == 1, "500 asks about one name ran the rules \(log.count) times, not once")
        }
    }

    /// The count follows DISTINCT names, not calls: twelve names asked five hundred times each
    /// still cost twelve.
    @Test func theCountFollowsDistinctNamesNotCalls() {
        RiskyNameBadgeCache.resetForTesting()
        BadgeEvaluationLog.record { log in
            for _ in 0..<500 {
                for name in BadgeMemoFixture.visibleFileNames {
                    _ = RiskyNameBadgeCache.reason(name: name, isDirectory: false, provider: .oneDrive)
                }
            }
            #expect(log.count == BadgeMemoFixture.visibleFileNames.count,
                    "\(BadgeMemoFixture.visibleFileNames.count) distinct names, asked 500 times each, ran the rules \(log.count) times")
        }
    }

    // MARK: - The memo, under a mounted tree pane

    /// **The main assertion.** Mount a pane, render it several times over, and require the rules to
    /// have run exactly once per distinct name the pane asked about — no more (the memo is doing
    /// its job) and no fewer (nothing else is answering).
    ///
    /// Stated against the pane's own traffic rather than a hand-written number, so it survives a
    /// change in row height or window size: whatever the pane happens to realize, the evaluations
    /// must equal the distinct names in it.
    @Test func aMountedPaneEvaluatesEachDistinctNameExactlyOnce() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            for pass in 0..<6 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.eachDistinctNameEvaluatedOnce(asked: delegate.asked, log: log,
                                                             pane: "tree")
            window.close()
        }
    }

    /// Re-rendering the pane must be free. The first pass pays for the names it sees; every pass
    /// after it adds nothing at all.
    ///
    /// This is the claim a wall-clock bar could never state: zero is exact, and a few hundred
    /// microseconds of extra live checking is not.
    @Test func furtherRenderPassesEvaluateNothingNew() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            renderPass(window, box, selecting: 0)
            let afterFirst = log.count
            let asksAfterFirst = delegate.asked.count
            for pass in 1..<6 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.laterPassesAreFree(afterFirst: afterFirst, asksAfterFirst: asksAfterFirst,
                                                   asked: delegate.asked, log: log, pane: "tree")
            window.close()
        }
    }

    /// **The eager-pass guard.** The fixture's three collapsed folders hold 600 names that no
    /// visible row shows. A lazy pane never touches them; a walk of the published tree — the
    /// up-front index the cache's doc comment weighs and rejects at ~140 ms per publish — touches
    /// all of them, on the main actor, on the path that decides how long opening a folder takes.
    @Test func theCollapsedSubtreeIsNeverEvaluated() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            for pass in 0..<3 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.theUnopenedSubtreeIsUntouched(asked: delegate.asked, log: log,
                                                              pane: "tree")
            window.close()
        }
    }
}

/// The same three claims, against the columns pane.
///
/// `PaneColumnsView` is the badge's second render call site (`PaneColumnsView.columnRow`), and it is
/// the same shape as the tree pane's: `riskyNameReason` per row, per render pass, evaluated eagerly
/// while building the row. Nothing about the tree pane's verdict carries over on its own — the two
/// realize rows differently, and the columns pane resolves each column's rows through
/// `PaneChildrenIndex` rather than from `PaneRow.children` — so the claims are re-measured here
/// rather than assumed.
///
/// With an empty `browsePath` this renders exactly one column, the root's. A folder's children get a
/// column only when it is drilled into, so the fixture's 600 hidden names are as far out of reach
/// here as they are behind a collapsed `OutlineGroup` row.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgeColumnsMemoTests {

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    /// Observes the box, so a selection write actually re-renders the pane — `PaneColumnsView` takes
    /// bindings, and a bare `Binding(get:set:)` over the box would update the box and nothing else.
    /// `ColumnTapSelectionWiringTests` documents the same trap.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let delegate: FileActionDelegate

        var body: some View {
            PaneColumnsView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index,
                treeRoot: BadgeMemoFixture.root,
                browsePath: $box.browsePath,
                onNavigate: { box.browsePath = $0 },
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: delegate,
                diffIndex: .empty,
                otherPaneName: "Right",
                isSingleSource: false,
                density: .compact,
                isActivePane: true,
                placement: nil,
                onBarEdgeFlip: nil,
                onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
        }
    }

    private func mount(_ box: Box, delegate: FileActionDelegate) -> NSWindow {
        // The preview column is switched off in this mount's own `ScratchDefaults` suite rather than
        // left to whatever the process picked up. It is not what is being measured, it would open on
        // every file selection below, and `UserDefaults.standard` is never touched — so nothing is
        // inherited from another suite and nothing leaks to one.
        let store = ScratchDefaults("RiskyNameBadgeColumnsMemoTests")
        store.set(false, forKey: PaneViewMode.previewColumnDefaultsKey)

        let tree = BadgeMemoFixture.tree(side: .left)
        let index = PaneChildrenIndex(tree: tree, treeRoot: BadgeMemoFixture.root)
        return BadgeMemoMount.window(
            Harness(box: box, tree: tree, index: index, delegate: delegate)
                .defaultAppStorage(store))
    }

    private func renderPass(_ window: NSWindow, _ box: Box, selecting index: Int) {
        BadgeMemoMount.renderPass(window) { box.selection = [BadgeMemoFixture.fileID(index)] }
    }

    @Test func aMountedColumnEvaluatesEachDistinctNameExactlyOnce() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            for pass in 0..<6 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.eachDistinctNameEvaluatedOnce(asked: delegate.asked, log: log,
                                                             pane: "columns")
            window.close()
        }
    }

    @Test func furtherRenderPassesEvaluateNothingNew() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            renderPass(window, box, selecting: 0)
            let afterFirst = log.count
            let asksAfterFirst = delegate.asked.count
            for pass in 1..<6 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.laterPassesAreFree(afterFirst: afterFirst, asksAfterFirst: asksAfterFirst,
                                                   asked: delegate.asked, log: log, pane: "columns")
            window.close()
        }
    }

    /// The columns pane's version of the eager-pass guard: an unopened folder's column does not
    /// exist, so none of the 600 names behind one may be evaluated.
    @Test func theUnopenedColumnsAreNeverEvaluated() {
        RiskyNameBadgeCache.resetForTesting()
        let box = Box()
        let delegate = BadgeRecordingDelegate(provider: .oneDrive)
        BadgeEvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            BadgeMemoMount.settle(window)
            for pass in 0..<3 { renderPass(window, box, selecting: pass) }

            BadgeMemoAssertions.theUnopenedSubtreeIsUntouched(asked: delegate.asked, log: log,
                                                              pane: "columns")
            window.close()
        }
    }
}

/// The three claims themselves, written once so the two panes are held to the same bar and a
/// strengthening of one cannot silently skip the other.
///
/// Each takes the pane's name so a failure says which presentation broke.
@MainActor
enum BadgeMemoAssertions {

    /// Every distinct name the pane asked about was evaluated exactly once, and the pane really did
    /// generate repeat traffic worth memoizing.
    static func eachDistinctNameEvaluatedOnce(asked: [String], log: BadgeEvaluationLog,
                                              pane: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let distinct = Set(asked)

        // Anti-vacuity, and the reason the equality below means anything: the pane really did ask
        // repeatedly, so a memo that answered nothing would not sail through. A `>` on the traffic
        // rather than an equality on the row count, because how many rows a pane realizes is a
        // layout detail this fixture has no business pinning.
        #expect(asked.count > distinct.count * 2,
                "\(pane): asked \(asked.count) times about \(distinct.count) names — too little repeat traffic for this to prove anything",
                sourceLocation: sourceLocation)
        #expect(distinct.count >= 8,
                "\(pane): only \(distinct.count) distinct names reached the badge; the fixture's rows are not rendering",
                sourceLocation: sourceLocation)

        // The equality below is against the pane's OWN traffic, so on its own it cannot see traffic
        // that should not exist: an eager walk that asks the delegate about the whole tree inflates
        // both sides equally and the equality still holds. (Measured — that mutation passed this
        // case until this assertion was added.) So bound the traffic first: only names the pane
        // actually shows may be asked about at all.
        let strays = distinct.subtracting(BadgeMemoFixture.visibleDistinctNames).sorted()
        // Counted before asserting: expanding the collection itself would bury the message under
        // 600 names.
        let strayCount = strays.count
        #expect(strayCount == 0,
                """
                \(pane): \(strayCount) name(s) the pane never showed reached the badge, e.g. \
                “\(strays.first ?? "")” — something is walking past the visible rows.
                """,
                sourceLocation: sourceLocation)

        #expect(log.count == distinct.count,
                """
                \(pane): \(asked.count) asks about \(distinct.count) distinct names ran the rules \
                \(log.count) times — it must be once per distinct name. Above that, the memo has \
                been removed, defeated, or keyed on something that varies per row or per pass; \
                below it, something other than the memo is answering.
                """,
                sourceLocation: sourceLocation)
    }

    /// Render passes after the first cost nothing, while still generating asks.
    static func laterPassesAreFree(afterFirst: Int, asksAfterFirst: Int, asked: [String],
                                   log: BadgeEvaluationLog, pane: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(afterFirst > 0,
                "\(pane): the first pass evaluated nothing — the badge is not on the render path at all",
                sourceLocation: sourceLocation)
        #expect(asked.count > asksAfterFirst,
                "\(pane): the later passes asked nothing; they did not re-render, so this proves nothing",
                sourceLocation: sourceLocation)
        #expect(log.count == afterFirst,
                """
                \(pane): five further render passes ran the rules \(log.count - afterFirst) more \
                times; a re-render must cost zero evaluations.
                """,
                sourceLocation: sourceLocation)
    }

    /// Nothing behind an unopened folder was asked about, or evaluated by any other route.
    static func theUnopenedSubtreeIsUntouched(asked: [String], log: BadgeEvaluationLog, pane: String,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
        let hidden = asked.filter { $0.hasPrefix(BadgeMemoFixture.hiddenPrefix) }
        // Bound to a count before asserting, for the same reason as above.
        let hiddenAsks = hidden.count
        #expect(hiddenAsks == 0,
                "\(pane): \(hiddenAsks) asks came from inside an unopened folder, e.g. “\(hidden.first ?? "")”",
                sourceLocation: sourceLocation)

        // And the same regression taking a route that bypasses the delegate lands here.
        let strays = log.strays
        let strayCount = strays.count
        #expect(strayCount == 0,
                """
                \(pane): ran the rules for \(strayCount) name(s) the pane never showed, e.g. \
                “\(strays.first ?? "")” — the 600 names behind the unopened folders are being \
                evaluated up front.
                """,
                sourceLocation: sourceLocation)
    }
}
