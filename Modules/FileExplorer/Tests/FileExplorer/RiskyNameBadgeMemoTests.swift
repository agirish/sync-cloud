import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Holds the row badge to the cost model `RiskyNameBadgeCache` was designed against: the pane asks
/// about a name on every visible row of every render pass, and the rules run **once per distinct
/// name, ever**.
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
/// evaluated, and every case here counts only names from its own fixture. That is not fastidiousness
/// — a plain process-wide counter was tried and flaked, because `DifferencesView` asks the same memo
/// and the suites that mount one run alongside these. See the seam's own note.
///
/// **What it catches.** Remove the memo, defeat it, key it on anything that varies per row or per
/// pass, or add an eager pass over the published tree, and these counts move by more than an order
/// of magnitude — measured, by mutation, for the first and the last of those.
@MainActor
@Suite(.serialized, .oneRiskyNameBadgeCacheOwner) struct RiskyNameBadgeMemoTests {

    // MARK: - The fixture

    static let root = "/root"

    /// Every fixture name starts with this. The memo is process-wide and shared with
    /// `DifferencesView`, so the token is what makes "evaluations of MY names" a well-defined
    /// quantity no other suite can contribute to — including `RiskyNameBadgePredicateTests`, whose
    /// fixtures would otherwise overlap these almost exactly.
    static let token = "memo-"

    /// The names the visible rows draw from. Deliberately fewer than the rows that show them: the
    /// memo's premise is that names repeat heavily, and a fixture of all-distinct names could not
    /// tell a per-name memo from a per-row one.
    ///
    /// Three of the twelve are risky — a trailing space, a colon, a zero-width character — so the
    /// badge actually draws on some rows rather than the whole pane taking the "nothing to show"
    /// path. The token prefix changes none of those verdicts.
    static let visibleFileNames = [
        "\(token)Statement 2026.pdf", "\(token)notes.txt", "\(token)Q3 final.pdf", "\(token)archive.zip",
        "\(token)receipt ", "\(token)photo.heic", "\(token)Q3: final.pdf", "\(token)budget.numbers",
        "\(token)read\u{200B}me.txt", "\(token)index.md", "\(token)cover.png", "\(token)invoice.pdf",
    ]

    /// Folder rows, visible alongside the files and collapsed. Their own names are asked about;
    /// their children's must not be.
    static let visibleFolderNames = ["\(token)Taxes", "\(token)Scans", "\(token)Archive"]

    /// Every distinct name a correctly-memoized pane may evaluate for this fixture.
    static var visibleDistinctNames: Set<String> {
        Set(visibleFileNames).union(visibleFolderNames)
    }

    static let hiddenPrefix = "\(token)hidden-"

    /// Rows drawn from `visibleFileNames`, five times round, so 60 rows carry 12 names. `id` is the
    /// only thing that distinguishes two rows with the same name — which is exactly the shape a
    /// per-row or per-path key would fail on.
    private static func visibleFiles() -> [FileNode] {
        (0..<60).map { i in
            let name = visibleFileNames[i % visibleFileNames.count]
            return FileNode(id: "\(root)/f\(i)-\(name)", name: name, isDirectory: false)
        }
    }

    /// Collapsed folders holding 600 names that appear NOWHERE among the visible rows. An
    /// `OutlineGroup` never builds a collapsed row's children, so a pane that stays lazy never sees
    /// these; anything that walks the published tree sees all of them at once.
    private static func hiddenFolders() -> [FileNode] {
        visibleFolderNames.enumerated().map { index, folder in
            let children = (0..<200).map { j in
                FileNode(id: "\(root)/\(folder)/\(hiddenPrefix)\(index)-\(j).pdf",
                         name: "\(hiddenPrefix)\(index)-\(j).pdf", isDirectory: false)
            }
            return FileNode(id: "\(root)/\(folder)", name: folder, isDirectory: true, children: children)
        }
    }

    private static func fixtureTree(side: PaneTree.Side) -> PaneTree {
        PaneTree(side: side, version: 1, nodes: hiddenFolders() + visibleFiles())
    }

    // MARK: - Recording evaluations

    /// Records the names the rules actually ran for, ignoring every name that is not this fixture's.
    ///
    /// `@MainActor` explicitly: a nested type does not inherit the suite's isolation, and both the
    /// memo it observes and the pane it observes it from are main-actor bound.
    @MainActor
    private final class EvaluationLog {
        private(set) var names: [String] = []

        /// Installs itself as the cache's observer for the duration of `body`, and unhooks after —
        /// an observer left behind would attribute the next case's evaluations to this one.
        static func record(_ body: (EvaluationLog) -> Void) {
            let log = EvaluationLog()
            RiskyNameBadgeCache.onEvaluateForTesting = { name in
                guard name.hasPrefix(RiskyNameBadgeMemoTests.token) else { return }
                log.names.append(name)
            }
            defer { RiskyNameBadgeCache.onEvaluateForTesting = nil }
            body(log)
        }

        var count: Int { names.count }

        /// Evaluations of names no visible row carries — an eager walk's signature, and the one
        /// thing a count alone cannot distinguish from honest work.
        var strays: [String] {
            names.filter { !RiskyNameBadgeMemoTests.visibleDistinctNames.contains($0) }
        }
    }

    // MARK: - The delegate

    /// Routes `riskyNameReason` through the memo exactly as `PaneActionDelegate` does, and records
    /// every name it was asked about.
    ///
    /// A class, not a struct: the pane holds this as an existential and the recording has to
    /// survive being copied into the view graph.
    private final class RecordingDelegate: FileActionDelegate {
        let provider: CloudProvider.ProviderType
        /// Every ask, in order and with repeats — `count` is the traffic the pane generates,
        /// `Set(…).count` is what the memo is allowed to charge for.
        private(set) var asked: [String] = []

        init(provider: CloudProvider.ProviderType) { self.provider = provider }

        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }

        /// No kept-name short-circuit, unlike production: it would let a name be asked about
        /// without reaching the memo, and these cases compare the two counts directly.
        func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
            asked.append(name)
            return RiskyNameBadgeCache.reason(name: name, isDirectory: isDirectory, provider: provider)
        }
    }

    // MARK: - Mounting

    final class Box: ObservableObject {
        @Published var selection: Set<String> = []
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let otherTree: PaneTree
        let delegate: FileActionDelegate

        var body: some View {
            FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: RiskyNameBadgeMemoTests.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: .empty)
        }
    }

    private func mount(_ box: Box, delegate: FileActionDelegate) -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: box,
                                                   tree: Self.fixtureTree(side: .left),
                                                   otherTree: Self.fixtureTree(side: .right),
                                                   delegate: delegate))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        // `NSWindow` defaults this to true, and `close()` then drops a reference ARC still owns —
        // a segfault at the end of the first mounted case, not a test failure. Each case here does
        // close its window rather than leaving three live panes on the main actor for whatever
        // runs next in this target.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// Settles the mount. Not a measurement — no deadline here decides anything, so a slow machine
    /// only makes this take longer, never makes it wrong.
    private func settle(_ window: NSWindow, seconds: Double = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    /// One full re-render of the pane and every visible row of it — the click a user pays for, and
    /// the pass the badge rides on.
    private func renderPass(_ window: NSWindow, _ box: Box, selecting index: Int) {
        box.selection = ["\(Self.root)/f\(index)-\(Self.visibleFileNames[index % Self.visibleFileNames.count])"]
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        window.layoutIfNeeded()
    }

    // MARK: - The memo, on its own

    /// The floor case, with no view in it: asking the same name repeatedly runs the rules once.
    /// Fails first, and most legibly, if the memo lookup is ever removed.
    @Test func askingOneNameRepeatedlyRunsTheRulesOnce() {
        RiskyNameBadgeCache.resetForTesting()
        EvaluationLog.record { log in
            for _ in 0..<500 {
                _ = RiskyNameBadgeCache.reason(name: "\(Self.token)Statement 2026 ",
                                               isDirectory: false, provider: .oneDrive)
            }
            #expect(log.count == 1, "500 asks about one name ran the rules \(log.count) times, not once")
        }
    }

    /// The count follows DISTINCT names, not calls: twelve names asked five hundred times each
    /// still cost twelve.
    @Test func theCountFollowsDistinctNamesNotCalls() {
        RiskyNameBadgeCache.resetForTesting()
        EvaluationLog.record { log in
            for _ in 0..<500 {
                for name in Self.visibleFileNames {
                    _ = RiskyNameBadgeCache.reason(name: name, isDirectory: false, provider: .oneDrive)
                }
            }
            #expect(log.count == Self.visibleFileNames.count,
                    "\(Self.visibleFileNames.count) distinct names, asked 500 times each, ran the rules \(log.count) times")
        }
    }

    // MARK: - The memo, under a mounted pane

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
        let delegate = RecordingDelegate(provider: .oneDrive)
        EvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            settle(window)
            for pass in 0..<6 { renderPass(window, box, selecting: pass) }

            let asked = delegate.asked
            let distinct = Set(asked)

            // Anti-vacuity, and the reason the equality below means anything: the pane really did
            // ask repeatedly, so a memo that answered nothing would not sail through. A `>` on the
            // traffic rather than an equality on the row count, because how many rows a List
            // realizes is a layout detail this fixture has no business pinning.
            #expect(asked.count > distinct.count * 2,
                    "the pane asked \(asked.count) times about \(distinct.count) names — too little repeat traffic for this to prove anything")
            #expect(distinct.count >= 8,
                    "only \(distinct.count) distinct names reached the badge; the fixture's rows are not rendering")

            // The equality below is against the pane's OWN traffic, so on its own it cannot see
            // traffic that should not exist: an eager walk that asks the delegate about the whole
            // tree inflates both sides equally and the equality still holds. (Measured — that
            // mutation passed this case until this assertion was added.) So bound the traffic
            // first: only names the pane actually shows may be asked about at all.
            let strays = distinct.subtracting(Self.visibleDistinctNames).sorted()
            // Counted before asserting: expanding the collection itself would bury the message
            // under 600 names.
            let strayCount = strays.count
            #expect(strayCount == 0,
                    """
                    \(strayCount) name(s) the pane never showed reached the badge, e.g. \
                    “\(strays.first ?? "")” — something is walking past the visible rows.
                    """)

            #expect(log.count == distinct.count,
                    """
                    \(asked.count) asks about \(distinct.count) distinct names ran the rules \
                    \(log.count) times — it must be once per distinct name. Above that, the memo has \
                    been removed, defeated, or keyed on something that varies per row or per pass; \
                    below it, something other than the memo is answering.
                    """)
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
        let delegate = RecordingDelegate(provider: .oneDrive)
        EvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            settle(window)
            renderPass(window, box, selecting: 0)

            let afterFirst = log.count
            let asksAfterFirst = delegate.asked.count
            #expect(afterFirst > 0, "the first pass evaluated nothing — the badge is not on the render path at all")

            for pass in 1..<6 { renderPass(window, box, selecting: pass) }

            #expect(delegate.asked.count > asksAfterFirst,
                    "the later passes asked nothing; they did not re-render, so this proves nothing")
            #expect(log.count == afterFirst,
                    """
                    five further render passes ran the rules \(log.count - afterFirst) more times; \
                    a re-render must cost zero evaluations.
                    """)
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
        let delegate = RecordingDelegate(provider: .oneDrive)
        EvaluationLog.record { log in
            let window = mount(box, delegate: delegate)
            settle(window)
            for pass in 0..<3 { renderPass(window, box, selecting: pass) }

            let hidden = delegate.asked.filter { $0.hasPrefix(Self.hiddenPrefix) }
            // Bound to a count before asserting, for the same reason as above.
            let hiddenAsks = hidden.count
            #expect(hiddenAsks == 0,
                    "\(hiddenAsks) asks came from inside a collapsed folder, e.g. “\(hidden.first ?? "")”")

            // And the same regression taking a route that bypasses the delegate lands here.
            let strays = log.strays
            let strayCount = strays.count
            #expect(strayCount == 0,
                    """
                    ran the rules for \(strayCount) name(s) the pane never showed, e.g. \
                    “\(strays.first ?? "")” — the 600 names in the collapsed subtree are being \
                    evaluated up front.
                    """)
            window.close()
        }
    }
}
