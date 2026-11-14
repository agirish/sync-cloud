import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Walking to a search hit reveals it, in whichever presentation the pane is in. These suites
/// assert the row's arrival, never the call: a `scrollTo` issued before the expansion lays out is
/// silently dropped. Each also asserts the pre-reveal state, so its fixture could have failed.
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

    struct StubDelegate: NoOpFileActions {
        func isEquivalent(to other: FileActionDelegate) -> Bool { other is StubDelegate }
    }

    /// The pane's inputs, observable so a change re-renders it: a bare `Binding(get:set:)` would
    /// move the box without the view noticing, failing every assertion for an unrelated reason.
    final class Box: ObservableObject {
        @Published var search: PaneSearchResults = .empty(side: .left)
        @Published var hitIndex = 0
        /// The host's reveal signal, bumped for a new query and a walk as
        /// `PaneSearchFieldState.revealNonce` is; results handed over without it are a republish.
        @Published var revealNonce = 0

        /// A (debounced) typed query landing: new results, walk restarted, reveal fired.
        func ask(_ results: PaneSearchResults, at index: Int = 0) {
            search = results
            hitIndex = index
            revealNonce &+= 1
        }

        /// ↩/⇧↩: the walk moves and the reveal fires.
        func walk(to index: Int) {
            hitIndex = index
            revealNonce &+= 1
        }

        /// A background republish: results and the standing index update; the nonce must not.
        func republish(_ results: PaneSearchResults, standingAt index: Int? = nil) {
            search = results
            if let index { hitIndex = index }
        }
        @Published var selection: Set<String> = []
        @Published var browsePath = PaneBrowsePath()
        @Published var navigated: [PaneBrowsePath] = []
        /// The pane's publish counter: bumping it republishes the same tree under a new stamp, which
        /// `PaneTree.==` treats as a change.
        @Published var treeVersion = 1
        /// The pane's root. A literal, not `PaneSearchTreeRevealTests.root`: that static is
        /// main-actor isolated and can't initialize a property of this nonisolated class.
        @Published var currentPath = "/root"
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
                currentPath: box.currentPath,
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                search: box.search,
                searchHitIndex: box.hitIndex,
                searchRevealNonce: box.revealNonce,
                viewMode: viewMode,
                childrenIndex: PaneChildrenIndex(tree: tree,
                                                 treeRoot: PaneSearchTreeRevealTests.root),
                browsePath: $box.browsePath,
                onColumnNavigate: { path in
                    box.navigated.append(path)
                    box.browsePath = path
                }
            )
            // The pane's own gate; without it the pane re-renders on everything.
            .equatable()
            // The reveal's scroll is a `withAnimation`, which only advances while something drives
            // frames, and an offscreen, never-key test window doesn't (see
            // `paneColumnRevealAnimation`). Unanimated, the destination is the same.
            .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    /// One column deep enough that a hit near its end starts below the fold, where "selected" and
    /// "revealed" are different claims.
    static func tallTree() -> PaneTree {
        let kids = (0..<80).map { i in
            let name = i == 70 ? "needle.txt" : "filler \(i).txt"
            return FileNode(id: "\(root)/\(name)", name: name, isDirectory: false)
        }
        return PaneTree(side: .left, version: 1, nodes: kids)
    }

    /// Whether the row for `path` is inside its column's visible rectangle, read from
    /// `NSTableView`'s geometry: what AppKit laid out and where it scrolled.
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

    /// How many rows the outline is showing: a row not yet revealed is not counted.
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

    /// The control: a tree that started expanded would pass every assertion below unrevealed.
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

    /// Walking to a hit three levels down brings its row into the list, selected (what Esc keeps).
    @Test("Walking to a hit opens its ancestors, the hit's own row arrives, and it is selected")
    func revealingAHitOpensItsAncestors() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }
        #expect(box.selection.isEmpty, "nothing should be selected before the walk")

        box.ask(Self.results("notes"), at: 0)

        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.financeOpenRowCount
        }
        #expect(settled.held,
                "revealing Documents/Finance/tax-notes.md should open both its ancestors (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
        let selected = await LayoutPumpWait.pump(window, upTo: 10) {
            box.selection == ["\(Self.root)/Documents/Finance/tax-notes.md"]
        }
        #expect(selected.held, "the hit should be selected (\(selected.pumps) pumps, got \(box.selection))")
    }

    /// Revealing a hit in Finance opens exactly its ancestors, not IRS; walking on to IRS's hit then
    /// opens it without closing Finance, as clicking your way down would.
    @Test("Walking on to the next branch opens it and keeps the first one open")
    func walkingOnAccumulatesExpansion() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        // "tax" matches in BOTH Finance and IRS; hit 0 is in Finance.
        box.ask(Self.results("tax"), at: 0)
        let first = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.financeOpenRowCount
        }
        #expect(first.held,
                "only Finance should have opened (\(first.pumps) pumps, \(Self.rowCount(window)) rows)")

        // Hit 2 is Documents/IRS/taxes.csv. A walk, so the nonce moves with the index.
        box.walk(to: 2)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowCount(window) == Self.bothOpenRowCount
        }
        #expect(settled.held,
                "IRS should open alongside Finance (\(settled.pumps) pumps, \(Self.rowCount(window)) rows)")
    }

    /// A query that matches nothing leaves the pane as it was: no expansion, no selection moved.
    @Test("A query with no hits reveals nothing")
    func aQueryWithNoHitsRevealsNothing() async {
        let box = Box()
        let window = Self.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Self.rowCount(window) == Self.collapsedRowCount }

        box.ask(Self.results("zzzz"), at: 0)
        let stayed = await LayoutPumpWait.pump(window, upTo: 2) { false }
        #expect(!stayed.held)   // the wait is a settle, not a condition
        #expect(Self.rowCount(window) == Self.collapsedRowCount, "nothing should have opened")
        #expect(box.selection.isEmpty, "nothing should have been selected")
    }
}

/// The outline (recursive `DisclosureGroup`s over a `Set<path>` the pane owns) keeps row identity
/// across a republish, or every scan, copy or hidden-files toggle would collapse it to its roots.
/// `PaneOutlineRepublishTests` covers the flat half; this is the nested case.
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

        box.ask(Fixture.results("notes"), at: 0)
        let opened = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowCount(window) == Fixture.financeOpenRowCount
        }
        #expect(opened.held, "the reveal should have opened two folders (\(opened.pumps) pumps)")

        // The same tree under a new stamp, so the pane really rebuilds.
        box.treeVersion += 1
        let settled = await LayoutPumpWait.pump(window, upTo: 5) { false }
        #expect(!settled.held)   // a settle, not a condition
        #expect(Fixture.rowCount(window) == Fixture.financeOpenRowCount,
                "a republish must not collapse the outline — got \(Fixture.rowCount(window)) rows")
    }
}

/// The two things a user does with a tree every day, the disclosure triangle and multi-select,
/// proven through `PaneOutlineRows`' `DisclosureGroup`s. Neither is about search.
@MainActor
@Suite struct PaneOutlineInteractionTests {

    typealias Fixture = PaneSearchTreeRevealTests

    /// The disclosure triangle exists and opens the folder.
    @Test("Clicking a row's disclosure triangle opens it")
    func theDisclosureTriangleStillWorks() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.rowCount(window) == Fixture.collapsedRowCount
        }
        let table = Fixture.tables(window.contentView!).first
        let rowView = table?.rowView(atRow: 0, makeIfNecessary: true)
        var triangles: [NSButton] = []
        func walk(_ v: NSView) { if let b = v as? NSButton { triangles.append(b) }; v.subviews.forEach(walk) }
        if let rowView { walk(rowView) }
        #expect(triangles.count == 1, "a folder row should carry exactly one disclosure control")

        if let button = triangles.first, let action = button.action {
            _ = button.target?.perform(action, with: button)
        }
        let opened = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.rowCount(window) > Fixture.collapsedRowCount
        }
        #expect(opened.held,
                "the triangle should expand the row (\(opened.pumps) pumps, \(Fixture.rowCount(window)) rows)")
    }

    /// Multi-select drives Copy, Move and Delete, and the tags that carry it sit on a
    /// `DisclosureGroup` label rather than in `OutlineGroup`'s content closure.
    @Test("Selecting more than one row still reaches the pane")
    func multiSelectStillReachesTheBinding() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.rowCount(window) == Fixture.collapsedRowCount
        }
        let table = Fixture.tables(window.contentView!).first
        #expect(table?.allowsMultipleSelection == true, "the pane's List must still be multi-select")
        table?.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        let landed = await LayoutPumpWait.pump(window, upTo: 5) { box.selection.count == 2 }
        #expect(landed.held,
                "both rows should reach the selection binding (\(landed.pumps) pumps, got \(box.selection))")
    }

    /// The same in Columns, whose `List` is built differently (one per open column, `.sidebar`,
    /// with `PaneListSelectionStyler` underneath). `ColumnTapSelectionTests` pins the predicate.
    @Test("Selecting more than one row still reaches the pane, in Columns")
    func multiSelectStillReachesTheBindingInColumns() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { !Fixture.tables(window.contentView!).isEmpty }

        let table = Fixture.tables(window.contentView!).first
        #expect(table != nil, "Columns mounted no table at all — the fixture is not exercising it")
        #expect(table?.allowsMultipleSelection == true,
                "the column's List refuses multiple selection, so ⌘-click cannot extend it")
        table?.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        let landed = await LayoutPumpWait.pump(window, upTo: 5) { box.selection.count == 2 }
        #expect(landed.held,
                "both rows should reach the selection binding (\(landed.pumps) pumps, got \(box.selection))")
    }
}

/// An appearance is not a walk: the pane reveals the current hit when it appears, but that fires on
/// every tab switch and collapse, so it must not select, or it would undo the user's click. The
/// control, that a walk still selects, is `PaneSearchTreeRevealTests.revealingAHitOpensItsAncestors`.
@MainActor
@Suite struct PaneSearchAppearanceTests {

    typealias Fixture = PaneSearchTreeRevealTests

    @Test("Appearing with a live search reveals the hit without taking the selection")
    func appearingRevealsButDoesNotSelect() async {
        let box = Fixture.Box()
        // The state a mode switch hands the new pane: results and a walk position already set, and a
        // selection the user made on something else.
        box.ask(Fixture.results("notes"), at: 0)
        box.selection = ["\(Fixture.root)/Movies"]

        let window = Fixture.mount(box, viewMode: .tree)
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowCount(window) == Fixture.financeOpenRowCount
        }
        #expect(revealed.held,
                "appearing should still open the hit's ancestors (\(revealed.pumps) pumps, \(Fixture.rowCount(window)) rows)")
        #expect(box.selection == ["\(Fixture.root)/Movies"],
                "appearing must not move a selection the user made — got \(box.selection)")
    }

    /// …and the same in Columns, where the appearance also re-opens the column stack.
    @Test("Appearing in Columns opens the stack without taking the selection")
    func appearingInColumnsDoesNotSelect() async {
        let box = Fixture.Box()
        box.ask(Fixture.results("notes"), at: 0)
        box.selection = ["\(Fixture.root)/Movies"]

        let window = Fixture.mount(box, viewMode: .columns)
        let opened = await LayoutPumpWait.pump(window, upTo: 10) {
            box.browsePath.components == ["Documents", "Finance"]
        }
        #expect(opened.held, "appearing should still open the columns (\(opened.pumps) pumps)")
        #expect(box.selection == ["\(Fixture.root)/Movies"],
                "appearing must not move a selection the user made — got \(box.selection)")
    }
}

/// The expansion set is bounded by the pane's current root. `@MainActor` because `FileTreeView` is,
/// statics included: without it the suite compiles and then traps at run time, a crash that takes
/// the whole bundle with it rather than a failure.
@MainActor
@Suite struct PaneOutlineExpansionTests {

    nonisolated static let remembered: Set<String> = [
        "/root/Documents", "/root/Documents/Finance", "/elsewhere/Archive", "/root2/Docs",
    ]

    /// Re-rooting drops every remembered expansion under the old root, including `/root2/Docs`,
    /// which a bare `hasPrefix` without the separator would let through.
    @Test("Re-rooting drops the expansions that belong to somewhere else")
    func reRootingDropsForeignPaths() {
        let kept = FileTreeView.expansionPruned(Self.remembered, toRoot: "/root")
        #expect(kept == ["/root/Documents", "/root/Documents/Finance"])
    }

    /// The prune's edges, each against what `/root` keeps.
    @Test("The prune's edges", arguments: [
        // A trailing slash must not make every path foreign: `currentPath` comes from a join, and
        // `PaneBrowsePath.normalized` is the one rule for this.
        (PaneOutlineExpansionTests.remembered, "/root/", ["/root/Documents", "/root/Documents/Finance"]),
        // The root itself is legitimately expandable, so it survives its own prune.
        (["/root"], "/root", ["/root"]),
        // An empty root is not a root: it arrives before a pane has one, and pruning everything
        // against it would silently collapse the outline.
        (PaneOutlineExpansionTests.remembered, "", PaneOutlineExpansionTests.remembered),
    ] as [(Set<String>, String, Set<String>)])
    func thePrunesEdges(paths: Set<String>, root: String, kept: Set<String>) {
        #expect(FileTreeView.expansionPruned(paths, toRoot: root) == kept, "root \"\(root)\"")
    }

    /// And the mounted pane really calls it. Only the root moves (a real re-root replaces the tree
    /// too), the only way to see the prune rather than the tree change.
    @Test("Re-rooting the mounted pane really does prune it")
    func theMountedPanePrunesOnReRoot() async {
        typealias Fixture = PaneSearchTreeRevealTests
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.rowCount(window) == Fixture.collapsedRowCount
        }
        box.ask(Fixture.results("notes"), at: 0)
        let opened = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowCount(window) == Fixture.financeOpenRowCount
        }
        #expect(opened.held, "the reveal should have opened two folders (\(opened.pumps) pumps)")

        box.currentPath = "/somewhere-else"
        let pruned = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowCount(window) == Fixture.collapsedRowCount
        }
        #expect(pruned.held,
                "re-rooting should drop the old root's expansions (\(pruned.pumps) pumps, \(Fixture.rowCount(window)) rows)")
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

    /// The reveal opens the columns down to the hit's parent and selects it, routed through
    /// `onColumnNavigate`: the seam link makes a column move a two-pane decision only the host makes.
    @Test("Walking to a hit opens the columns down to it, through the host, and selects it")
    func revealingAHitOpensItsColumns() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        box.ask(Fixture.results("notes"), at: 0)

        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.tables(window.contentView!).count == 3
        }
        #expect(settled.held,
                "root + Documents + Finance (\(settled.pumps) pumps, \(Fixture.tables(window.contentView!).count) columns)")
        #expect(box.browsePath.components == ["Documents", "Finance"])

        let routed = await LayoutPumpWait.pump(window, upTo: 10) { !box.navigated.isEmpty }
        #expect(routed.held, "the host should have been asked to navigate (\(routed.pumps) pumps)")
        #expect(box.navigated.last?.components == ["Documents", "Finance"])

        let selected = await LayoutPumpWait.pump(window, upTo: 10) {
            box.selection == ["\(Fixture.root)/Documents/Finance/tax-notes.md"]
        }
        #expect(selected.held, "the hit should be selected (\(selected.pumps) pumps, got \(box.selection))")
    }

    /// Selecting is not revealing: a hit far below the fold is scrolled into its column's visible rect.
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

        box.ask(PaneSearchResults(side: .left, generation: 1, query: "needle",
                                  tree: Fixture.tallTree(), otherPaths: nil), at: 0)

        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Fixture.rowIsVisible(window, path: needle, in: Fixture.tallTree())
        }
        #expect(revealed.held,
                "the hit's row should be scrolled into its column (\(revealed.pumps) pumps)")
        #expect(box.selection == [needle], "…and selected")
    }

    /// A hit at the top level closes the stack back to one column rather than leaving it wherever
    /// the previous hit put it: the browse path is set, not merely extended.
    @Test("Walking back out to a top-level hit closes the columns it opened")
    func revealingATopLevelHitClosesTheStack() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.tables(window.contentView!).count == 1 }

        // Walk into a nested hit first ("notes" lives under Documents/Finance), so there is an
        // open stack for the top-level "Movies" hit to close.
        box.ask(Fixture.results("notes"), at: 0)
        _ = await LayoutPumpWait.pump(window, upTo: 10) { Fixture.tables(window.contentView!).count == 3 }

        box.ask(Fixture.results("Movies", generation: 2), at: 0)
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            box.browsePath.components.isEmpty && Fixture.tables(window.contentView!).count == 1
        }
        #expect(settled.held,
                "a top-level hit needs no open columns (\(settled.pumps) pumps, \(box.browsePath.components))")
    }
}

/// The reveal fires on the host's nonce alone: a results generation moves on every republish, so a
/// reveal keyed on it would take back whatever the user selected since the walk.
@MainActor
@Suite struct PaneSearchRevealNonceTests {

    typealias Fixture = PaneSearchTreeRevealTests

    /// After a walk and a click elsewhere, a same-query republish keeps the click; the control, a
    /// nonce bump (↩) afterwards, still reveals.
    @Test("A same-query republish does not take back a selection made after the walk")
    func aRepublishDoesNotStealTheSelection() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .tree)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { Fixture.rowCount(window) == Fixture.collapsedRowCount }

        box.ask(Fixture.results("notes"), at: 0)
        let hit = "\(Fixture.root)/Documents/Finance/tax-notes.md"
        let landed = await LayoutPumpWait.pump(window, upTo: 10) { box.selection == [hit] }
        #expect(landed.held, "the walk itself must still select (\(landed.pumps) pumps)")

        // The user moves on: a different row, selected by hand.
        let elsewhere = "\(Fixture.root)/Movies"
        box.selection = [elsewhere]

        // A background republish: same query, recomputed results under a new generation.
        box.republish(Fixture.results("notes", generation: 2), standingAt: 0)
        let after = await LayoutPumpWait.pump(window, upTo: 6) { box.selection != [elsewhere] }
        #expect(!after.held,
                "a republish must not re-fire the reveal — the selection moved off the user's row after \(after.pumps) pumps")
        #expect(box.selection == [elsewhere])

        // ↩: the user asks to be taken back. Same index, so the nonce is the only thing moving.
        box.walk(to: 0)
        let back = await LayoutPumpWait.pump(window, upTo: 10) { box.selection == [hit] }
        #expect(back.held, "↩ must still reveal the hit (\(back.pumps) pumps)")
    }
}
