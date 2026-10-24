import SwiftUI
import Testing
@testable import FileExplorer
import Sync

/// **The outline asks for a directory the walk did not read**, which it did not do at all until
/// this was reviewed.
///
/// The node budget landed with the request wired into `PaneColumnsView` only. In the outline the
/// same directory arrives with `children: []` and `isUnexplored`, which draws a disclosure triangle
/// that opens onto nothing and stays that way for as long as the pane is on that root — and it
/// looks exactly like an ordinary empty folder, so nobody would report it as a bug. The budget's
/// own log line said "columns load it when you open them", which was the admission.
///
/// Asserted on the binding rather than by mounting the outline: expanding is the request, so the
/// binding's setter is where the decision is, and a hosted `DisclosureGroup` would test SwiftUI.
@Suite struct OutlineGraftRequestTests {

    private func node(_ path: String, unexplored: Bool, children: [FileNode]?) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, isUnexplored: unexplored ? true : nil)
    }

    /// Drives the same code path the outline does: build the rows, flip the row's expansion
    /// binding open, and see what was asked for.
    @MainActor
    private func requestsWhenExpanding(_ rows: [FileNode], path: String, open: Bool) -> [String] {
        requestsWhenExpandingWithPassive(rows, path: path, open: open).map(\.path)
    }

    @MainActor
    private func requestsWhenExpandingWithPassive(_ rows: [FileNode], path: String,
                                                  open: Bool) -> [(path: String, passive: Bool)] {
        var asked: [(path: String, passive: Bool)] = []
        var expanded: Set<String> = open ? [] : [path]
        let tree = PaneTree(side: .left, version: 1, nodes: rows)
        let view = PaneOutlineRows(
            rows: tree.rows,
            expanded: Binding(get: { expanded }, set: { expanded = $0 }),
            onNeedChildren: { asked.append(($0, $1)) },
            row: { _ in EmptyView() })
        let target = try? #require(tree.rows.first { $0.node.id == path })
        guard let target else { return asked }
        view.expansionBindingForTesting(target).wrappedValue = open
        return asked
    }

    @MainActor
    @Test func openingAnUnreadDirectoryAsksForIt() {
        let rows = [node("/r/unread", unexplored: true, children: [])]
        #expect(requestsWhenExpanding(rows, path: "/r/unread", open: true) == ["/r/unread"],
                "expanding a folder the walk never read asked for nothing — it opens onto an empty body forever")
    }

    /// **Opening is an explicit ask, never a passive one** — so the manager retries a folder it
    /// found unreadable before (a slow cloud folder may have downloaded since), where a scroll
    /// past would not.
    @MainActor
    @Test func openingAsksExplicitly() {
        let rows = [node("/r/unread", unexplored: true, children: [])]
        let asked = requestsWhenExpandingWithPassive(rows, path: "/r/unread", open: true)
        #expect(asked.map(\.passive) == [false],
                "opening a row asked passively — a folder found unreadable once could never be retried")
    }

    /// **The placeholder's `onAppear` is the passive ask**, and the only one: it fires on every
    /// scroll past, which is what the manager's unreadable memory is for. Read from the body,
    /// since `onAppear` cannot be fired from a test.
    @Test func thePlaceholderAsksPassively() throws {
        let outline = try OrganizeScopeCallSiteTests.source("PaneOutlineRows.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "var body: some View {", in: outline)
        #expect(body.contains("onNeedChildren(paneRow.node.id, true)"),
                "the placeholder's appear-time ask is not marked passive — every scroll past re-lists an unreadable folder")
        #expect(!outline.contains("onNeedChildren(id, true)"),
                "opening a row asks passively")
    }

    /// **A walked folder must not be asked about.** Every ordinary directory in a normal source is
    /// this case, so a request here would relist the whole tree one folder at a time as the user
    /// browses it.
    @MainActor
    @Test func openingAWalkedDirectoryAsksForNothing() {
        let rows = [node("/r/walked", unexplored: false,
                         children: [node("/r/walked/a", unexplored: false, children: [])])]
        #expect(requestsWhenExpanding(rows, path: "/r/walked", open: true).isEmpty)
    }

    /// A genuinely empty walked folder is also not asked about — `[]` children and no mark is an
    /// answer, not an absence.
    @MainActor
    @Test func openingAnEmptyWalkedDirectoryAsksForNothing() {
        let rows = [node("/r/empty", unexplored: false, children: [])]
        #expect(requestsWhenExpanding(rows, path: "/r/empty", open: true).isEmpty)
    }

    /// **Closing is not a request.** A collapse fires the same setter, and starting a directory
    /// listing on the way out of a folder somebody is done with is work nobody will look at —
    /// during the collapse animation, which is the worst moment for it.
    @MainActor
    @Test func closingAnUnreadDirectoryAsksForNothing() {
        let rows = [node("/r/unread", unexplored: true, children: [])]
        #expect(requestsWhenExpanding(rows, path: "/r/unread", open: false).isEmpty,
                "collapsing a row started a directory listing")
    }
}

/// **An opened empty or unreadable folder says which in the tree (BR14).** Columns said "Empty"
/// or "Can’t be read"; the tree expanded onto nothing for both. The placeholder is the column's
/// own rule asked one level in, so each state below is pinned by its literal words.
@MainActor
@Suite struct OutlineEmptyPlaceholderTests {

    private func row(_ unexplored: Bool, children: [FileNode]?) throws -> PaneRow {
        let folder = FileNode(id: "/r/f", name: "f", isDirectory: children != nil,
                              children: children, isUnexplored: unexplored ? true : nil)
        return try #require(PaneTree(side: .left, version: 1, nodes: [folder]).rows.first)
    }

    private func caption(_ row: PaneRow, loading: Bool = false,
                         inFlight: Set<String> = []) -> PaneColumnsView.Caption? {
        PaneOutlineRows<EmptyView>.placeholder(for: row, isLoading: loading, graftsInFlight: inFlight)
    }

    @Test func anEmptyWalkedFolderSaysEmpty() throws {
        #expect(caption(try row(false, children: []))?.text == "Empty")
    }

    @Test func anUnreadFolderSaysItCannotBeRead() throws {
        #expect(caption(try row(true, children: []))?.text == "Can’t be read")
    }

    /// Being read is not unreadable: a spinner, no words.
    @Test func aFolderBeingReadShowsASpinner() throws {
        #expect(caption(try row(true, children: []), inFlight: ["/r/f"]) == .loading)
    }

    /// While the pane's own walk runs every folder is unexplored; nothing is claimed.
    @Test func nothingIsSaidWhileThePaneIsLoading() throws {
        #expect(caption(try row(true, children: []), loading: true) == nil)
    }

    /// The control: a folder with children, and a file, get no placeholder.
    @Test func aFolderWithChildrenOrAFileGetsNone() throws {
        let child = FileNode(id: "/r/f/a", name: "a", isDirectory: false)
        #expect(caption(try row(false, children: [child])) == nil)
        #expect(caption(try row(false, children: nil)) == nil)
    }

    /// **The outline draws it, and the pane hands it what it needs.** The rule above is one revert
    /// away from unused: the outline body must draw the placeholder row from it, and the pane must
    /// pass its own walk and in-flight state rather than the defaults.
    @Test func theOutlineDrawsItAndThePanePassesItsState() throws {
        let outline = try OrganizeScopeCallSiteTests.source("PaneOutlineRows.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "var body: some View {", in: outline)
        #expect(body.contains("Self.placeholder(for: paneRow, isLoading: isLoading,"))
        #expect(body.contains("Self.placeholderRow(caption)"))
        let pane = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        #expect(pane.contains("isLoading: isLoading, graftsInFlight: graftsInFlight) { row in"),
                "the tree's outline is not told the pane's walk and in-flight state")
    }
}
