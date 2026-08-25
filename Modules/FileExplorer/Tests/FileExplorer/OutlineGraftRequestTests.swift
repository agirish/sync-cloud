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
        var asked: [String] = []
        var expanded: Set<String> = open ? [] : [path]
        let tree = PaneTree(side: .left, version: 1, nodes: rows)
        let view = PaneOutlineRows(
            rows: tree.rows,
            expanded: Binding(get: { expanded }, set: { expanded = $0 }),
            onNeedChildren: { asked.append($0) },
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
