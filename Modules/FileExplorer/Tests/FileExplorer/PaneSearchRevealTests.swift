import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Walking to a search hit has to REVEAL it, in whichever presentation the pane is in — and the
/// reveal is the half of this feature with no pure function behind it. `PaneTreeSearch` can be asked
/// which ancestors a hit has; only a mounted pane can say whether the row actually arrived.
///
/// Both suites therefore assert ARRIVAL, never the call returning. That is not pedantry here: a
/// `scrollTo` issued before the expansion has laid out is silently dropped, and `onColumnNavigate`
/// firing says nothing about whether the columns opened — so a test that watched either call would
/// pass against a pane that reveals nothing.
///
/// Each also establishes that its fixture COULD have failed, by asserting the pre-reveal state.
@MainActor
@Suite struct PaneSearchTreeRevealTests {

    // Documents/Finance/{Tax Return 2025.pdf, tax-notes.md, Receipts 2025.numbers}
    // Documents/IRS/{taxes.csv}
    // Movies/{Holiday.mov}
    static let root = "/root"

    static func tree(side: PaneTree.Side = .left, version: Int = 1) -> PaneTree {
        func file(_ path: String) -> FileNode {
            FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent, isDirectory: false)
        }
        func folder(_ path: String, _ kids: [FileNode]) -> FileNode {
            FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent,
                     isDirectory: true, children: kids)
        }
        return PaneTree(side: side, version: version, nodes: [
            folder("Documents", [
                folder("Documents/Finance", [
                    file("Documents/Finance/Tax Return 2025.pdf"),
                    file("Documents/Finance/tax-notes.md"),
                    file("Documents/Finance/Receipts 2025.numbers"),
                ]),
                folder("Documents/IRS", [file("Documents/IRS/taxes.csv")]),
            ]),
            folder("Movies", [file("Movies/Holiday.mov")]),
        ])
    }

    /// Results for `query`, stamped with `generation` so a change is one the pane notices.
    static func results(_ query: String, generation: Int = 1,
                        side: PaneTree.Side = .left) -> PaneSearchResults {
        PaneSearchResults(side: side, generation: generation, query: query,
                          tree: tree(side: side), otherPaths: nil)
    }

    struct StubDelegate: FileActionDelegate {
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
        func isEquivalent(to other: FileActionDelegate) -> Bool { other is StubDelegate }
    }

    /// The pane's inputs, observable so a change actually re-renders it — a bare `Binding(get:set:)`
    /// would move the box and leave the view none the wiser, and every assertion here would then
    /// fail for a reason that has nothing to do with the reveal.
    final class Box: ObservableObject {
        @Published var search: PaneSearchResults = .empty(side: .left)
        @Published var hitIndex = 0
        @Published var selection: Set<String> = []
        @Published var browsePath = PaneBrowsePath()
        @Published var navigated: [PaneBrowsePath] = []
        /// The pane's publish counter. Bumping it republishes the same tree under a new stamp, which
        /// is what `PaneTree.==` treats as a genuine change — the pane rebuilds its rows from it.
        @Published var treeVersion = 1
    }

    struct Harness: View {
        @ObservedObject var box: Box
        let viewMode: PaneViewMode
        var treeOverride: PaneTree?

        var body: some View {
            let tree = treeOverride ?? PaneSearchTreeRevealTests.tree(version: box.treeVersion)
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneSearchTreeRevealTests.root,
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                search: box.search,
                searchHitIndex: box.hitIndex,
                viewMode: viewMode,
                childrenIndex: PaneChildrenIndex(tree: tree,
                                                 treeRoot: PaneSearchTreeRevealTests.root),
                browsePath: $box.browsePath,
                onColumnNavigate: { path in
                    box.navigated.append(path)
                    box.browsePath = path
                }
            )
            // The pane's own gate. Without it the conformance is inert and the pane re-renders on
            // everything, which would make these tests pass for the wrong reason.
            .equatable()
            // The reveal's scroll is a `withAnimation`, and a SwiftUI animation only advances while
            // something drives frames. An offscreen, never-key test window is exactly the host that
            // does not — see `paneColumnRevealAnimation`. Unanimated, the destination is identical.
            .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    /// One column deep enough that a hit near its end starts below the fold — the shape that showed
    /// "selected" and "revealed" are different claims.
    static func tallTree() -> PaneTree {
        let kids = (0..<80).map { i in
            let name = i == 70 ? "needle.txt" : "filler \(i).txt"
            return FileNode(id: "\(root)/\(name)", name: name, isDirectory: false)
        }
        return PaneTree(side: .left, version: 1, nodes: kids)
    }

    /// Whether the row for `path` is inside its column's visible rectangle. Resolved through
    /// `NSTableView`'s own geometry rather than anything SwiftUI reports — the question is what
    /// AppKit laid out and where it scrolled to.
    static func rowIsVisible(_ window: NSWindow, path: String, in tree: PaneTree) -> Bool {
        guard let index = tree.rows.firstIndex(where: { $0.id == path }) else { return false }
        for table in tables(window.contentView!) {
            guard table.numberOfRows > index, let scroll = table.enclosingScrollView else { continue }
            let rowRect = table.rect(ofRow: index)
            if scroll.documentVisibleRect.intersects(rowRect) { return true }
        }
        return false
    }

    static func mount(_ box: Box, viewMode: PaneViewMode, tree: PaneTree? = nil) -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: box, viewMode: viewMode, treeOverride: tree))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// Every `NSTableView` AppKit built for this window. The tree presentation is one; Columns is
    /// one per open column.
    static func tables(_ view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { found.append(t) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// How many rows the outline is actually showing. This is the observable the whole suite turns
    /// on: a row that has not been revealed is not in here.
    static func rowCount(_ window: NSWindow) -> Int {
        tables(window.contentView!).map(\.numberOfRows).reduce(0, +)
    }

    /// Rows visible with everything collapsed: the two top-level folders.
    static let collapsedRowCount = 2
    /// After `Documents` and `Documents/Finance` open: Documents, Finance, its three children, IRS,
    /// Movies.
    static let financeOpenRowCount = 7
    /// …and then `Documents/IRS` too, keeping Finance open: one more row for `taxes.csv`.
    static let bothOpenRowCount = 8

    // MARK: -

    /// The control. If the tree started expanded, every assertion below would pass without the
    /// reveal doing anything at all.
    @Test("The tree starts collapsed — so a revealed row is one the reveal opened")
    func theTreeStartsCollapsed() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        let settled = await LayoutPumpWait.pump(window, upTo: 5) {
            Self.rowCount(window) == Self.collapsedRowCount
        }
        #expect(settled.held,
                "the pane should show its two top-level folders and nothing else (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
    }

    /// The feature: walking to a hit three levels down brings its row into the list.
    @Test("Walking to a hit opens its ancestors, and the hit's own row arrives")
    func revealingAHitOpensItsAncestors() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        box.search = Self.results("notes")
        box.hitIndex = 0

        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.financeOpenRowCount
        }
        #expect(settled.held,
                "revealing Documents/Finance/tax-notes.md should open both its ancestors (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
    }

    /// “Exactly the hit's ancestors”, measured: revealing a hit in Finance must not open IRS.
    /// `financeOpenRowCount` is one short of `bothOpenRowCount` precisely because IRS stayed shut.
    @Test("Revealing one hit does not open a sibling folder that also has matches")
    func revealingAHitLeavesOtherBranchesShut() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        // "tax" matches in BOTH Finance and IRS; hit 0 is in Finance.
        box.search = Self.results("tax")
        box.hitIndex = 0
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.financeOpenRowCount
        }
        #expect(settled.held,
                "only Finance should have opened (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
        #expect(Self.rowCount(window) != Self.bothOpenRowCount,
                "IRS must stay shut until the walk reaches its hit")
    }

    /// …and walking on to that sibling's hit opens it WITHOUT closing the first. The reveal adds to
    /// the expansion, exactly as clicking your way down would.
    @Test("Walking on to the next branch opens it and keeps the first one open")
    func walkingOnAccumulatesExpansion() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        box.search = Self.results("tax")
        box.hitIndex = 0
        _ = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.financeOpenRowCount
        }

        // Hit 2 is Documents/IRS/taxes.csv.
        box.hitIndex = 2
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.bothOpenRowCount
        }
        #expect(settled.held,
                "IRS should open alongside Finance (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
    }

    /// The current hit takes the selection highlight — which is also what leaves something selected
    /// for Esc to keep.
    @Test("The revealed hit becomes the pane's selection")
    func revealingAHitSelectsIt() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }
        #expect(box.selection.isEmpty, "nothing should be selected before the walk")

        box.search = Self.results("notes")
        box.hitIndex = 0
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            box.selection == ["\(Self.root)/Documents/Finance/tax-notes.md"]
        }
        #expect(settled.held, "the hit should be selected (\(settled.pumps) pumps, got \(box.selection))")
    }

    /// A query that matches nothing must leave the pane exactly as it was — no expansion, no
    /// selection moved, nothing scrolled.
    @Test("A query with no hits reveals nothing")
    func aQueryWithNoHitsRevealsNothing() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        box.search = Self.results("zzzz")
        box.hitIndex = 0
        let stayed = await LayoutPumpWait.pump(window, upTo: 2) { false }
        #expect(!stayed.held)   // the wait is a settle, not a condition
        #expect(Self.rowCount(window) == Self.collapsedRowCount, "nothing should have opened")
        #expect(box.selection.isEmpty, "nothing should have been selected")
    }
}

/// The pane's outline stopped being an `OutlineGroup` — it is recursive `DisclosureGroup`s over a
/// `Set<path>` the pane owns, because `OutlineGroup` exposes no way to open a hit's ancestors. This
/// is the behaviour-preservation net for that swap.
///
/// The property at risk is IDENTITY on republish. `OutlineGroup` and `ForEach` alike *store* the
/// collection they are handed, and the pane republishes its tree constantly — a scan, a copy, a
/// hidden-files toggle. If the rows' identity did not survive that, every republish would collapse
/// the outline back to its roots under the user, which is the sort of thing that reads as "the app
/// keeps losing my place" rather than as a regression in a specific control.
///
/// `PaneOutlineRepublishTests` covers the neighbouring half — that a republish's CONTENTS reach the
/// laid-out rows at all — over a flat tree, where expansion does not arise. This is the nested case.
@MainActor
@Suite struct PaneOutlineExpansionRepublishTests {

    typealias Fixture = PaneSearchTreeRevealTests

    @Test("Expansion survives a republish — the rows keep their identity")
    func expansionSurvivesARepublish() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.rowCount(window) == Fixture.collapsedRowCount
        }

        box.search = Fixture.results("notes")
        box.hitIndex = 0
        let opened = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowCount(window) == Fixture.financeOpenRowCount
        }
        #expect(opened.held, "the reveal should have opened two folders (\(opened.pumps) pumps)")

        // The same tree, republished under a new stamp — which `PaneTree.==` reports as a change, so
        // the pane genuinely rebuilds rather than being handed the value it already had.
        box.treeVersion += 1
        let settled = await LayoutPumpWait.pump(window, upTo: 5) { false }
        #expect(!settled.held)   // a settle, not a condition
        #expect(Fixture.rowCount(window) == Fixture.financeOpenRowCount,
                "a republish must not collapse the outline — got \(Fixture.rowCount(window)) rows")
    }
}

/// The Columns half: the reveal writes the hit's parent chain through the host's navigation seam and
/// selects the hit, and the columns really do open down to it.
@MainActor
@Suite struct PaneSearchColumnsRevealTests {

    typealias Fixture = PaneSearchTreeRevealTests

    /// The control: at rest the stack is one column, so an opened column is one the reveal opened.
    @Test("The stack starts at one column")
    func theStackStartsAtRest() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        let settled = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.tables(window.contentView!).count == 1
        }
        #expect(settled.held,
                "a resting Columns pane is one column (\(settled.pumps) pumps, \(Fixture.tables(window.contentView!).count) columns)")
        #expect(box.navigated.isEmpty)
    }

    /// The reveal opens the columns down to the hit's PARENT — three columns for a file two folders
    /// deep: the root, Documents, and Finance, whose rows include the hit.
    @Test("Walking to a hit opens the columns down to it")
    func revealingAHitOpensItsColumns() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        box.search = Fixture.results("notes")
        box.hitIndex = 0

        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.tables(window.contentView!).count == 3
        }
        #expect(settled.held,
                "root + Documents + Finance (\(settled.pumps) pumps, \(Fixture.tables(window.contentView!).count) columns)")
        #expect(box.browsePath.components == ["Documents", "Finance"])
    }

    /// Routed through `onColumnNavigate`, not written straight to the binding — the seam link makes
    /// a column move a two-pane decision, and only the host can mirror it.
    @Test("The column move goes through the host's navigation callback")
    func theMoveIsRoutedThroughTheHost() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        box.search = Fixture.results("notes")
        box.hitIndex = 0

        let settled = await LayoutPumpWait.pump(window, upTo: 10) { !box.navigated.isEmpty }
        #expect(settled.held, "the host should have been asked to navigate (\(settled.pumps) pumps)")
        #expect(box.navigated.last?.components == ["Documents", "Finance"])
    }

    /// **Selecting a row is not revealing it**, and this suite could not tell the difference until
    /// this test existed: it asserted the column COUNT and the selection, both of which pass while
    /// the hit sits far below the fold. Measured on the shipped build — a hit 70 rows down was
    /// selected at y = 2330 with the viewport showing 0…500.
    @Test("A hit below the fold is scrolled into view, not just selected")
    func aHitBelowTheFoldIsBroughtIntoView() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns, tree: Fixture.tallTree())
        _ = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.tables(window.contentView!).count == 1
        }
        let needle = "\(Fixture.root)/needle.txt"
        // The control: it starts off screen, or this test proves nothing.
        #expect(!Fixture.rowIsVisible(window, path: needle, in: Fixture.tallTree()),
                "the fixture must start with the hit below the fold")

        box.search = PaneSearchResults(side: .left, generation: 1, query: "needle",
                                       tree: Fixture.tallTree(), otherPaths: nil)
        box.hitIndex = 0

        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowIsVisible(window, path: needle, in: Fixture.tallTree())
        }
        #expect(revealed.held,
                "the hit's row should be scrolled into its column (\(revealed.pumps) pumps)")
        #expect(box.selection == [needle], "…and selected")
    }

    @Test("The revealed hit becomes the pane's selection in Columns too")
    func revealingAHitSelectsItInColumns() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        box.search = Fixture.results("notes")
        box.hitIndex = 0
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            box.selection == ["\(Fixture.root)/Documents/Finance/tax-notes.md"]
        }
        #expect(settled.held, "the hit should be selected (\(settled.pumps) pumps, got \(box.selection))")
    }

    /// A hit at the top level closes the stack back to one column rather than leaving it wherever
    /// the previous hit put it — the browse path is set, not merely extended.
    @Test("Walking back out to a top-level hit closes the columns it opened")
    func revealingATopLevelHitClosesTheStack() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        // "s" matches Documents (0), Finance (1), … and Movies. Walk into Finance first.
        box.search = Fixture.results("notes")
        box.hitIndex = 0
        _ = await LayoutPumpWait.pump(window, upTo: 10) { Fixture.tables(window.contentView!).count == 3 }

        box.search = Fixture.results("Movies", generation: 2)
        box.hitIndex = 0
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            box.browsePath.components.isEmpty && Fixture.tables(window.contentView!).count == 1
        }
        #expect(settled.held,
                "a top-level hit needs no open columns (\(settled.pumps) pumps, \(box.browsePath.components))")
    }
}

/// The reveal's trigger, pinned where a test can reach it: `.onChange` fires exactly when this
/// compares unequal.
@Suite struct PaneSearchRevealTokenTests {

    @Test("Walking to another hit fires a reveal")
    func theHitIndexIsCompared() {
        #expect(PaneSearchRevealToken(generation: 1, hitIndex: 0)
                != PaneSearchRevealToken(generation: 1, hitIndex: 1))
    }

    /// The half an index-only token misses: retyping a query rebuilds the results and puts the walk
    /// back at hit 0, so the index does not move — and the first hit of the new query would never
    /// be revealed.
    @Test("A new result set at the same index still fires a reveal")
    func theGenerationIsCompared() {
        #expect(PaneSearchRevealToken(generation: 1, hitIndex: 0)
                != PaneSearchRevealToken(generation: 2, hitIndex: 0))
    }

    @Test("An unchanged token does not fire — a render is not a reveal")
    func anUnchangedTokenIsEqual() {
        #expect(PaneSearchRevealToken(generation: 3, hitIndex: 2)
                == PaneSearchRevealToken(generation: 3, hitIndex: 2))
    }
}
