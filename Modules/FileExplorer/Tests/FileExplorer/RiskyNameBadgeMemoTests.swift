import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Holds the row badge to `RiskyNameBadgeCache`'s cost model: a pane asks about a name on every
/// visible row of every render pass, and the rules run once per distinct name, ever.
///
/// This suite measures the tree pane (`FileTreeView`); `RiskyNameBadgeColumnsMemoTests` measures
/// the columns pane against the same fixture. Both are real call sites of `riskyNameReason`.
///
/// A count, not a stopwatch. The badge costs +0.03–0.24 ms against a ~9 ms re-render, smaller than
/// the spread within one arm on a loaded Mac; deleting the memo swaps a ~1.5 µs dictionary hit for
/// a ~7 µs live check on ~60 rows, an order of magnitude under the noise. A timing bar loose
/// enough not to flake couldn't see it. Counting evaluations is exact, needs no calibration and
/// reads the same on a busy machine, so these cases are not `.machinePinned`.
///
/// Counted by name, not by tally: `RiskyNameBadgeCache.onEvaluateForTesting` reports the name, and
/// each case counts only its own fixture's names, because `DifferencesView` asks the same memo
/// from suites running alongside. See the seam's own note.
///
/// Removing the memo, defeating it, keying it on anything that varies per row or per pass, or
/// adding an eager pass over the published tree moves these counts by more than an order of
/// magnitude.
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

    /// The pane is mounted on a `NotificationCenter` of this suite's own. A mounted `FileTreeView`
    /// subscribes to `.cloudDownloadRequested` regardless, so on `.default` any parallel suite's
    /// `.left` post would republish `downloads.requests` and rebuild this pane's body.
    ///
    /// The memo absorbs such a render, and no case here counts renders, so no verdict depends on
    /// this. It is here because the rule is the rule (see "A mounted view is a live subscriber, in
    /// every suite at once" in `docs/flaky-tests.md`), and because a count-based test earns its
    /// exactness by letting nothing else touch what it counts.
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

    /// The count follows distinct names, not calls: twelve names asked five hundred times each
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

    /// Mount a pane and render it six times. The rules run exactly once per distinct name the pane
    /// asked about (no more: the memo works; no fewer: nothing else answers), every pass after the
    /// first adds nothing, and the 600 names behind the collapsed folders are never touched: a walk
    /// of the published tree (~140 ms per publish, on the main actor) would touch them all.
    @Test func aMountedPaneEvaluatesEachVisibleNameOnceEver() {
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

            BadgeMemoAssertions.eachDistinctNameEvaluatedOnce(asked: delegate.asked, log: log, pane: "tree")
            BadgeMemoAssertions.laterPassesAreFree(afterFirst: afterFirst, asksAfterFirst: asksAfterFirst,
                                                   asked: delegate.asked, log: log, pane: "tree")
            BadgeMemoAssertions.theUnopenedSubtreeIsUntouched(asked: delegate.asked, log: log, pane: "tree")
            window.close()
        }
    }
}

/// The same claims, against the columns pane.
///
/// `PaneColumnsView` is the badge's second render call site (`PaneColumnsView.columnRow`), with the
/// same shape: `riskyNameReason` per row, per pass, evaluated while building the row. The two panes
/// realize rows differently (this one resolves each column's rows through `PaneChildrenIndex`, not
/// `PaneRow.children`), so the claims are re-measured here rather than assumed.
///
/// With an empty `browsePath` this renders one column, the root's; a folder's children get a
/// column only when it is drilled into, so the fixture's 600 hidden names are out of reach.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgeColumnsMemoTests {

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    /// Observes the box, so a selection write re-renders the pane: `PaneColumnsView` takes bindings,
    /// and a bare `Binding(get:set:)` over the box would update the box and nothing else.
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
        // Its own `ScratchDefaults` suite for everything the pane reads from defaults (the column
        // widths, the glass hue): `UserDefaults.standard` is never touched, so nothing is inherited
        // from another suite and nothing leaks to one.
        let store = ScratchDefaults("RiskyNameBadgeColumnsMemoTests")

        let tree = BadgeMemoFixture.tree(side: .left)
        let index = PaneChildrenIndex(tree: tree, treeRoot: BadgeMemoFixture.root)
        return BadgeMemoMount.window(
            Harness(box: box, tree: tree, index: index, delegate: delegate)
                .defaultAppStorage(store))
    }

    private func renderPass(_ window: NSWindow, _ box: Box, selecting index: Int) {
        BadgeMemoMount.renderPass(window) { box.selection = [BadgeMemoFixture.fileID(index)] }
    }

    /// The same six-pass run against the columns pane: an unopened folder's column doesn't exist,
    /// so none of the 600 names behind one may be evaluated.
    @Test func aMountedColumnEvaluatesEachVisibleNameOnceEver() {
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

            BadgeMemoAssertions.eachDistinctNameEvaluatedOnce(asked: delegate.asked, log: log, pane: "columns")
            BadgeMemoAssertions.laterPassesAreFree(afterFirst: afterFirst, asksAfterFirst: asksAfterFirst,
                                                   asked: delegate.asked, log: log, pane: "columns")
            BadgeMemoAssertions.theUnopenedSubtreeIsUntouched(asked: delegate.asked, log: log, pane: "columns")
            window.close()
        }
    }
}

/// The three claims, written once so both panes meet the same bar and strengthening one can't
/// skip the other. Each takes the pane's name so a failure says which presentation broke.
@MainActor
enum BadgeMemoAssertions {

    /// Every distinct name the pane asked about was evaluated exactly once, and the pane really did
    /// generate repeat traffic worth memoizing.
    static func eachDistinctNameEvaluatedOnce(asked: [String], log: BadgeEvaluationLog,
                                              pane: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let distinct = Set(asked)

        // Anti-vacuity: the pane really did ask repeatedly, so a memo that answered nothing can't
        // pass. A `>` on the traffic, not an equality on the row count, because how many rows a
        // pane realizes is a layout detail this fixture shouldn't pin.
        #expect(asked.count > distinct.count * 2,
                "\(pane): asked \(asked.count) times about \(distinct.count) names — too little repeat traffic for this to prove anything",
                sourceLocation: sourceLocation)
        #expect(distinct.count >= 8,
                "\(pane): only \(distinct.count) distinct names reached the badge; the fixture's rows are not rendering",
                sourceLocation: sourceLocation)

        // The equality below is against the pane's own traffic, so it can't see traffic that
        // shouldn't exist: an eager walk asking about the whole tree inflates both sides equally.
        // So bound the traffic first: only names the pane shows may be asked about at all.
        let strays = distinct.subtracting(BadgeMemoFixture.visibleDistinctNames).sorted()
        // Counted before asserting: expanding the collection would bury the message under 600
        // names.
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
