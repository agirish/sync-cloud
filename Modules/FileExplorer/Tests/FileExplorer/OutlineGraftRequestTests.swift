import SwiftUI
import Testing
@testable import FileExplorer
import Sync

/// The outline asks for a directory the walk did not read. Such a directory arrives with
/// `children: []` and `isUnexplored`; without the ask its disclosure triangle opens onto nothing,
/// and looks exactly like an ordinary empty folder, so nobody would report it.
///
/// Asserted on the expansion binding rather than by mounting the outline: expanding is the
/// request, so the setter is where the decision is, and a hosted `DisclosureGroup` would test
/// SwiftUI.
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

    /// Opening is an explicit ask, never a passive one, so the manager retries a folder it found
    /// unreadable before (a slow cloud folder may have downloaded since), where a scroll past would
    /// not.
    @MainActor
    @Test func openingAnUnreadDirectoryAsksForIt() {
        let rows = [node("/r/unread", unexplored: true, children: [])]
        let asked = requestsWhenExpandingWithPassive(rows, path: "/r/unread", open: true)
        #expect(asked.map(\.path) == ["/r/unread"],
                "expanding a folder the walk never read asked for nothing — it opens onto an empty body forever")
        #expect(asked.map(\.passive) == [false],
                "opening a row asked passively — a folder found unreadable once could never be retried")
    }

    /// The placeholder's `onAppear` is the passive ask, and the only one: it fires on every scroll
    /// past, which is what the manager's unreadable memory is for. Read from the body, since
    /// `onAppear` cannot be fired from a test.
    @Test func thePlaceholderAsksPassively() throws {
        let outline = try SourceText.fileExplorer("PaneOutlineRows.swift")
        let body = try SourceText.body(of: "var body: some View {", in: outline)
        #expect(body.contains("onNeedChildren(paneRow.node.id, true)"),
                "the placeholder's appear-time ask is not marked passive — every scroll past re-lists an unreadable folder")
    }

    /// A walked folder must not be asked about, empty or not: `[]` children and no mark is an
    /// answer, not an absence. Every ordinary directory is this case, so a request here would
    /// relist the whole tree one folder at a time as the user browses it.
    @MainActor
    @Test(arguments: [("/r/walked", 1), ("/r/empty", 0)] as [(String, Int)])
    func openingAWalkedDirectoryAsksForNothing(path: String, children: Int) {
        let rows = [node(path, unexplored: false,
                         children: (0..<children).map { node("\(path)/\($0)", unexplored: false, children: []) })]
        #expect(requestsWhenExpanding(rows, path: path, open: true).isEmpty)
    }

    /// Closing is not a request. A collapse fires the same setter, and a listing started then is
    /// work nobody will look at, run during the collapse animation.
    @MainActor
    @Test func closingAnUnreadDirectoryAsksForNothing() {
        let rows = [node("/r/unread", unexplored: true, children: [])]
        #expect(requestsWhenExpanding(rows, path: "/r/unread", open: false).isEmpty,
                "collapsing a row started a directory listing")
    }
}

/// An opened empty or unreadable folder says which in the tree, as Columns does with "Empty" and
/// "Can’t be read". The placeholder is the column's own rule asked one level in, so each state is
/// pinned by its literal words.
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

    /// Each state by its literal words where it has them. Being read is not unreadable: a spinner,
    /// no words. While the pane's own walk runs every folder is unexplored, so nothing is claimed.
    /// The controls: a folder with children, and a file (`children` nil), get no placeholder.
    @Test(arguments: [
        (false, 0, false, false, nil, "Empty"),
        (true, 0, false, false, nil, "Can’t be read"),
        (true, 0, false, true, .loading, nil),
        (true, 0, true, false, nil, nil),
        (false, 1, false, false, nil, nil),
        (false, nil, false, false, nil, nil),
    ] as [(Bool, Int?, Bool, Bool, PaneColumnsView.Caption?, String?)])
    func theCaptionForAnOpenedFolder(unexplored: Bool, children: Int?, loading: Bool, inFlight: Bool,
                                     expected: PaneColumnsView.Caption?, words: String?) throws {
        let kids = children.map { n in (0..<n).map { FileNode(id: "/r/f/\($0)", name: "\($0)", isDirectory: false) } }
        let shown = caption(try row(unexplored, children: kids), loading: loading, inFlight: inFlight ? ["/r/f"] : [])
        if let words {
            #expect(shown?.text == words)
        } else {
            #expect(shown == expected)
        }
    }

    /// The outline draws the placeholder and the pane hands it what it needs: the outline body must
    /// draw the row from the rule above, and the pane must pass its own walk and in-flight state
    /// rather than the defaults.
    @Test func theOutlineDrawsItAndThePanePassesItsState() throws {
        let outline = try SourceText.fileExplorer("PaneOutlineRows.swift")
        let body = try SourceText.body(of: "var body: some View {", in: outline)
        #expect(body.contains("Self.placeholder(for: paneRow, isLoading: isLoading,"))
        #expect(body.contains("Self.placeholderRow(caption)"))
        let pane = try SourceText.fileExplorer("FileTreeView.swift")
        #expect(pane.contains("isLoading: isLoading, graftsInFlight: graftsInFlight) { row in"),
                "the tree's outline is not told the pane's walk and in-flight state")
    }
}
