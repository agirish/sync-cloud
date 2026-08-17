import Testing
import AppKit
import SwiftUI
@testable import FileExplorer
import Sync

/// `carryBack` can be perfect while nothing calls it, and the call it needs is a SwiftUI `onAppear`.
/// This mounts the Columns presentation for real and watches the channel a column move actually
/// travels on — `onColumnNavigate`, not the binding, because the seam link mirrors a drill into the
/// sibling pane and writing the binding straight would move this pane alone.
@MainActor
@Suite struct PaneTreeCarryBackWiringTests {

    private struct StubDelegate: FileActionDelegate {
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
    }

    static let root = "/carry-back"

    private func tree() -> PaneTree {
        func dir(_ path: String, _ name: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: name, isDirectory: true, children: children)
        }
        let root = Self.root
        return PaneTree(side: .left, version: 1, nodes: [
            dir("\(root)/Claude", "Claude", [
                dir("\(root)/Claude/Projects", "Projects", [
                    FileNode(id: "\(root)/Claude/Projects/notes.md", name: "notes.md", isDirectory: false),
                ]),
            ]),
            // Deliberately somewhere the selection below is NOT, so a search hit and the Tree's
            // selection give different answers and the precedence test can tell them apart.
            dir("\(root)/Family", "Family", [
                FileNode(id: "\(root)/Family/reunion.txt", name: "reunion.txt", isDirectory: false),
            ]),
        ])
    }

    /// Mounts a Columns pane holding `selection` and a resting stack, and returns every column move
    /// it asked its host for.
    private func mountColumns(selection selected: Set<String>,
                              parked: PaneBrowsePath = PaneBrowsePath(),
                              search: PaneSearchResults? = nil,
                              isLoading: Bool = false,
                              tree: PaneTree? = nil) -> [PaneBrowsePath] {
        final class Box: @unchecked Sendable { var moves: [PaneBrowsePath] = [] }
        let box = Box()
        var selection = selected
        var browse = parked
        let tree = tree ?? self.tree()
        let view = FileTreeView(
            tree: tree,
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            isLoading: isLoading,
            currentPath: Self.root,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            otherSelection: [],
            isLeft: true,
            delegate: StubDelegate(),
            isSingleSource: true,
            search: search,
            isActivePane: true,
            viewMode: .columns,
            childrenIndex: PaneChildrenIndex(tree: tree, treeRoot: Self.root),
            browsePath: Binding(get: { browse }, set: { browse = $0 }),
            onColumnNavigate: { box.moves.append($0); browse = $0 })

        let host = NSHostingView(rootView: AnyView(view.frame(width: 640, height: 420)))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return box.moves
    }

    /// A hit is a place asked for by name; the Tree's selection is a place left behind. When both
    /// speak on the same arrival the hit has to win, or searching and then flipping presentation
    /// would walk the user away from the very row they searched for.
    @Test func testASearchHitOutranksTheTreesSelection() {
        let hits = PaneSearchResults(side: .left, generation: 1, query: "reunion",
                                     tree: tree(), otherPaths: nil)
        let moves = mountColumns(selection: ["\(Self.root)/Claude/Projects"], search: hits)
        #expect(moves.last?.components == ["Family"],
                "the columns followed the selection instead of the search hit (moves: \(moves.map(\.components)))")
    }

    /// Drives the state a real pane is in when a tab switch lands mid-scan: mounted while the tree
    /// is still loading, then the load finishes under it.
    private final class LoadFlag: ObservableObject { @Published var loading = true }

    private struct LoadHarness: View {
        @ObservedObject var flag: LoadFlag
        let tree: PaneTree
        let selection: Set<String>
        var search: PaneSearchResults? = nil
        let onNavigate: (PaneBrowsePath) -> Void
        @State private var browse = PaneBrowsePath()
        @State private var selected: Set<String> = []

        var body: some View {
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: flag.loading,
                currentPath: PaneTreeCarryBackWiringTests.root,
                selection: Binding(get: { selected.isEmpty ? selection : selected },
                                   set: { selected = $0 }),
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                isSingleSource: true,
                search: search,
                isActivePane: true,
                viewMode: .columns,
                childrenIndex: PaneChildrenIndex(tree: tree,
                                                 treeRoot: PaneTreeCarryBackWiringTests.root),
                browsePath: Binding(get: { browse }, set: { browse = $0 }),
                onColumnNavigate: { onNavigate($0); browse = $0 })
                .frame(width: 640, height: 420)
        }
    }

    private func mountColumnsThenFinishLoading(selection: Set<String>,
                                               search: PaneSearchResults? = nil) -> [PaneBrowsePath] {
        final class Box: @unchecked Sendable { var moves: [PaneBrowsePath] = [] }
        let box = Box()
        let flag = LoadFlag()
        let host = NSHostingView(rootView: AnyView(
            LoadHarness(flag: flag, tree: tree(), selection: selection, search: search,
                        onNavigate: { box.moves.append($0) })))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // The arrival happened under a load; nothing may have moved yet. THEN the load lands.
        let duringLoad = box.moves
        if search == nil {
            #expect(duringLoad.isEmpty, "the mid-load arrival moved the columns before the tree settled")
        }
        flag.loading = false
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return box.moves
    }

    /// Re-roots the pane under a mounted Columns presentation, exactly as `focusOn` does: a new
    /// tree, a new `currentPath`, and the column stack reset (which is `resetBrowsePath`).
    private final class RootFlag: ObservableObject {
        @Published var index = 0
        /// A re-root reloads the tree, so the pane really does pass through a load — that is what
        /// re-asks the carry (`onChange(of: isLoading)`); the reset of `carriedTreePlace` is what
        /// lets the answer through once it does.
        @Published var loading = false
    }

    private struct ReRootHarness: View {
        @ObservedObject var flag: RootFlag
        let roots: [String]
        let onNavigate: (PaneBrowsePath) -> Void
        @State private var browse = PaneBrowsePath()

        private var root: String { roots[flag.index] }

        /// The same two folders under whichever root is live, so the two roots' answers are
        /// component-identical — which is the whole point: `carriedTreePlace` compares components.
        private func tree() -> PaneTree {
            PaneTree(side: .left, version: flag.index + 1, nodes: [
                FileNode(id: "\(root)/Claude", name: "Claude", isDirectory: true, children: []),
            ])
        }

        var body: some View {
            FileTreeView(
                tree: tree(),
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: flag.loading,
                currentPath: root,
                selection: .constant(["\(root)/Claude"]),
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                isSingleSource: true,
                isActivePane: true,
                viewMode: .columns,
                childrenIndex: PaneChildrenIndex(tree: tree(), treeRoot: root),
                browsePath: Binding(get: { browse }, set: { browse = $0 }),
                onColumnNavigate: { onNavigate($0); browse = $0 })
                .frame(width: 640, height: 420)
                // `focusOn` resets the stack when a pane re-roots; without this the fixture would
                // arrive at the new root still holding the old root's columns and the carry would
                // be skipped for a reason the app never has.
                .onChange(of: root) { _, _ in browse = PaneBrowsePath() }
        }
    }

    /// A place carried out of the OLD tree says nothing about a new one. Both roots here hold a
    /// `Claude`, so the two answers are component-identical — and the latch that stops a tab switch
    /// re-yanking the columns would otherwise swallow the second carry entirely.
    @Test func testReRootingLetsAnIdenticallyNamedPlaceCarryAgain() {
        final class Box: @unchecked Sendable { var moves: [PaneBrowsePath] = [] }
        let box = Box()
        let flag = RootFlag()
        let host = NSHostingView(rootView: AnyView(
            ReRootHarness(flag: flag, roots: ["/root-one", "/root-two"],
                          onNavigate: { box.moves.append($0) })))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(box.moves.count == 1, "the first root did not carry at all — this test proves nothing")

        // Re-root exactly as the app does: the focus moves and the tree reloads under it.
        flag.loading = true
        flag.index = 1
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        flag.loading = false
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(box.moves.count == 2,
                "the new root's identically named place was read as already carried and skipped")
        #expect(box.moves.last?.components == ["Claude"])
    }

    /// The precedence has to survive the RETRY too. A hit still owns the columns when the load
    /// lands — otherwise finishing a scan walks the user off the row they searched for, which is
    /// the arrival rule reappearing as a delayed regression one gate further along.
    @Test func testTheLoadsFallingEdgeStillLetsASearchHitWin() {
        let hits = PaneSearchResults(side: .left, generation: 1, query: "reunion",
                                     tree: tree(), otherPaths: nil)
        let moves = mountColumnsThenFinishLoading(selection: ["\(Self.root)/Claude/Projects"],
                                                  search: hits)
        #expect(moves.last?.components == ["Family"],
                """
                the load's falling edge carried the Tree's selection over a live search hit \
                (moves: \(moves.map(\.components)))
                """)
    }

    /// **The shallow-tree trap.** Progressive loading publishes the root's children and nothing
    /// under them before the deep walk finishes, and the carry-back resolves the selection against
    /// exactly that index — so a selection three folders down prunes to its first component. Applied
    /// then, it would move the columns somewhere the user never was AND latch, so the right answer
    /// never arrives. `pruneBrowsePath` refuses under the same circumstances and says why at length.
    @Test func testAnArrivalMidLoadDecidesNothingFromTheShallowTree() {
        let shallow = PaneTree(side: .left, version: 1, nodes: [
            FileNode(id: "\(Self.root)/Claude", name: "Claude", isDirectory: true, children: []),
        ])
        let moves = mountColumns(selection: ["\(Self.root)/Claude/Projects"],
                                 isLoading: true, tree: shallow)
        #expect(moves.isEmpty,
                "the columns were moved to \(moves.map(\.components)) on a tree that had not finished loading")
    }

    /// And refusing is only half of it: the load's falling edge has to re-ask, or an arrival that
    /// landed mid-load is never carried at all.
    @Test func testTheCarryIsRetriedWhenTheLoadFinishes() {
        let moves = mountColumnsThenFinishLoading(selection: ["\(Self.root)/Claude/Projects"])
        #expect(moves.last?.components == ["Claude", "Projects"],
                "an arrival during a load was refused and never retried (moves: \(moves.map(\.components)))")
    }

    /// The reported gap: walk into a folder in the Tree, flip to Columns, and the columns open there
    /// instead of replaying the stack they were parked with.
    @Test func testTheColumnsOpenOnTheFolderTheTreeWasStandingIn() {
        let moves = mountColumns(selection: ["\(Self.root)/Claude/Projects"])
        #expect(moves.last?.components == ["Claude", "Projects"],
                "arriving in Columns did not follow the Tree's selection (moves: \(moves.map(\.components)))")
    }

    /// Nothing selected is no answer, and the parked stack is what the user last chose with the
    /// columns themselves — it must survive untouched rather than be reset to the root.
    @Test func testAParkedStackSurvivesWhenTheTreeNamesNoPlace() {
        let moves = mountColumns(selection: [], parked: PaneBrowsePath(components: ["Claude"]))
        #expect(moves.isEmpty, "the columns were moved on no evidence at all")
    }

    /// The stack the pane is already showing is not a move: asking the host to navigate to it would
    /// mirror a drill into the sibling pane and log a walk that never happened.
    @Test func testAnAgreeingSelectionAsksForNoMove() {
        let moves = mountColumns(selection: ["\(Self.root)/Claude/Projects"],
                                 parked: PaneBrowsePath(components: ["Claude", "Projects"]))
        #expect(moves.isEmpty)
    }
}
