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

    private static let root = "/carry-back"

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
            dir("\(root)/Family", "Family"),
        ])
    }

    /// Mounts a Columns pane holding `selection` and a resting stack, and returns every column move
    /// it asked its host for.
    private func mountColumns(selection selected: Set<String>,
                              parked: PaneBrowsePath = PaneBrowsePath()) -> [PaneBrowsePath] {
        final class Box: @unchecked Sendable { var moves: [PaneBrowsePath] = [] }
        let box = Box()
        var selection = selected
        var browse = parked
        let view = FileTreeView(
            tree: tree(),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            isLoading: false,
            currentPath: Self.root,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            otherSelection: [],
            isLeft: true,
            delegate: StubDelegate(),
            isSingleSource: true,
            isActivePane: true,
            viewMode: .columns,
            childrenIndex: PaneChildrenIndex(tree: tree(), treeRoot: Self.root),
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
