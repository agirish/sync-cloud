import Testing
import SwiftUI
import Sync
import Design
@testable import FileExplorer

/// Mutation-tests `FileTreeView.==`, which is the pane's re-render gate.
///
/// The conformance is an optimization with a correctness cliff on the other side of it. When `==`
/// answers true, SwiftUI keeps the pane it already has and does not re-evaluate it — so a stored
/// property the comparison forgets is a value the pane silently stops noticing. That failure has no
/// symptom at the call site: it looks like a stale badge, or a selection that doesn't highlight,
/// somewhere else entirely, and only under whatever sequence of renders happens to skip.
///
/// So this suite does not assert that equality "works". It changes each compared input in turn and
/// requires `==` to notice — the only shape of test that fails when someone adds a property and
/// forgets the comparison. Two properties are deliberately NOT in that list, and the last two tests
/// pin why.
@MainActor
@Suite struct FileTreeViewEquatableTests {

    private struct StubDelegate: FileActionDelegate {
        /// Distinguishes two stubs so the delegate half of the comparison can be driven.
        var id: Int = 0
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
        func isEquivalent(to other: FileActionDelegate) -> Bool {
            (other as? StubDelegate)?.id == id
        }
    }

    private func node(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, children: nil)
    }

    private func difference(_ relative: String) -> FileDifference {
        FileDifference(relativePath: relative, leftItemPath: "/root/" + relative,
                       rightItemPath: "/other/" + relative, type: .missingOnRight,
                       action: .copyToRight, description: "test")
    }

    /// The reference pane. Every test below builds this and one variant differing in exactly one
    /// input, so a failure names the property that went unnoticed.
    private func pane(
        tree: PaneTree = PaneTree(side: .left, version: 1, nodes: []),
        otherTree: PaneTree = PaneTree(side: .right, version: 1, nodes: []),
        isLoading: Bool = false,
        currentPath: String = "/root",
        selection: Set<String> = [],
        otherSelection: Set<String> = [],
        isLeft: Bool = true,
        delegate: FileActionDelegate = StubDelegate(),
        diffIndex: DiffStatusIndex = .empty,
        otherPaneName: String = "Right",
        rootPathIsValid: Bool = true,
        providerIsEnabled: Bool = true,
        hasOnlyHiddenEntries: Bool = false,
        rootPath: String = "/root",
        onOpenSettings: (() -> Void)? = {},
        isSingleSource: Bool = false,
        placement: PaneBarPlacement? = nil,
        onBarEdgeFlip: (() -> Void)? = {},
        isActivePane: Bool = true,
        viewMode: PaneViewMode = .tree,
        childrenIndex: PaneChildrenIndex? = nil,
        browsePath: PaneBrowsePath = PaneBrowsePath(),
        onColumnNavigate: ((PaneBrowsePath) -> Void)? = { _ in },
        onBackgroundDeselect: ((Int?) -> Void)? = { _ in },
        onQuickLook: ((URL) -> Void)? = { _ in },
        downloadChannel: NotificationCenter = .default
    ) -> FileTreeView {
        FileTreeView(
            tree: tree, otherTree: otherTree, isLoading: isLoading, currentPath: currentPath,
            selection: .constant(selection), otherSelection: otherSelection, isLeft: isLeft,
            delegate: delegate, diffIndex: diffIndex, otherPaneName: otherPaneName,
            rootPathIsValid: rootPathIsValid, providerIsEnabled: providerIsEnabled,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries, rootPath: rootPath,
            onOpenSettings: onOpenSettings, isSingleSource: isSingleSource,
            placement: placement, onBarEdgeFlip: onBarEdgeFlip, isActivePane: isActivePane,
            viewMode: viewMode, childrenIndex: childrenIndex,
            browsePath: .constant(browsePath), onColumnNavigate: onColumnNavigate,
            onBackgroundDeselect: onBackgroundDeselect, onQuickLook: onQuickLook,
            downloadChannel: downloadChannel)
    }

    @Test("An unchanged pane compares equal — otherwise the gate never engages at all")
    func identicalPanesAreEqual() {
        #expect(pane() == pane())
    }

    // MARK: The mutation sweep

    @Test("A republished tree is noticed")
    func treeVersionIsCompared() {
        #expect(pane() != pane(tree: PaneTree(side: .left, version: 2, nodes: [])))
    }

    @Test("The OTHER pane's tree is noticed — the row menu reads it")
    func otherTreeIsCompared() {
        #expect(pane() != pane(otherTree: PaneTree(side: .right, version: 2, nodes: [])))
    }

    @Test("The loading flag is noticed")
    func isLoadingIsCompared() {
        #expect(pane() != pane(isLoading: true))
    }

    @Test("The pane's folder is noticed")
    func currentPathIsCompared() {
        #expect(pane() != pane(currentPath: "/root/Docs"))
    }

    /// The one most likely to be got wrong: `selection` is a `Binding`, and comparing the binding
    /// rather than its value would make every click invisible to the gate.
    @Test("A selection change is noticed, through the binding")
    func selectionIsComparedByValue() {
        #expect(pane() != pane(selection: ["/root/a.txt"]))
    }

    @Test("The other pane's selection is noticed — it drives the paste-from-other menu item")
    func otherSelectionIsCompared() {
        #expect(pane() != pane(otherSelection: ["/other/a.txt"]))
    }

    @Test("Which side this is, is noticed")
    func isLeftIsCompared() {
        #expect(pane() != pane(isLeft: false))
    }

    @Test("A new difference index is noticed — the badges render from it")
    func diffIndexIsCompared() {
        let populated = DiffStatusIndex(differences: [difference("a.txt")], rootPath: "/root")
        #expect(pane() != pane(diffIndex: populated))
    }

    @Test("The other pane's display name is noticed — the menu labels name it")
    func otherPaneNameIsCompared() {
        #expect(pane() != pane(otherPaneName: "Dropbox"))
    }

    @Test("Root validity is noticed — it selects the placeholder")
    func rootValidityIsCompared() {
        #expect(pane() != pane(rootPathIsValid: false))
    }

    @Test("Provider enablement is noticed — it selects the placeholder")
    func providerEnabledIsCompared() {
        #expect(pane() != pane(providerIsEnabled: false))
    }

    @Test("The hidden-entries-only flag is noticed — it changes the empty state's caption")
    func hiddenEntriesFlagIsCompared() {
        #expect(pane() != pane(hasOnlyHiddenEntries: true))
    }

    @Test("The provider root is noticed — the invalid placeholder prints it")
    func rootPathIsCompared() {
        #expect(pane() != pane(rootPath: "/elsewhere"))
    }

    @Test("Single-source is noticed — it empties the diff index and reshapes the row menu")
    func singleSourceIsCompared() {
        #expect(pane() != pane(isSingleSource: true))
    }

    @Test("Which pane is active is noticed — it sets the selection wash's strength")
    func activePaneIsCompared() {
        #expect(pane() != pane(isActivePane: false))
    }

    @Test("The view mode is noticed — it picks the whole presentation")
    func viewModeIsCompared() {
        #expect(pane() != pane(viewMode: .columns))
    }

    @Test("A rebuilt children index is noticed — the columns resolve their rows from it")
    func childrenIndexIsCompared() {
        let a = PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: []), treeRoot: "/root")
        let b = PaneChildrenIndex(tree: PaneTree(side: .left, version: 2, nodes: []), treeRoot: "/root")
        #expect(pane(childrenIndex: a) != pane(childrenIndex: b))
    }

    @Test("A drill is noticed, through the binding")
    func browsePathIsComparedByValue() {
        var drilled = PaneBrowsePath()
        drilled.drill(into: "Docs", atDepth: 0)
        #expect(pane() != pane(browsePath: drilled))
    }

    @Test("A different placement box is noticed — two panes must never share one")
    func placementIsComparedByIdentity() {
        #expect(pane(placement: PaneBarPlacement()) != pane(placement: PaneBarPlacement()))
    }

    /// The channel the pane's `.cloudDownloadRequested` subscription is built on. Compared by
    /// identity, like the placement box: `.onReceive` is declared in `body`, so a pane that keeps
    /// the view it already has keeps the subscription it already has — and would go on listening to
    /// the channel it was first mounted with. In the app that never changes; in a test it is the
    /// only thing separating one mounted pane from another, which is a bad thing to hold stale.
    @Test("A different download channel is noticed — it decides which posts the pane hears")
    func downloadChannelIsComparedByIdentity() {
        #expect(pane(downloadChannel: NotificationCenter()) != pane(downloadChannel: NotificationCenter()))
    }

    @Test("Gaining or losing a callback is noticed — presence changes what the pane offers")
    func callbackPresenceIsCompared() {
        let noSettings: (() -> Void)? = nil
        let noFlip: (() -> Void)? = nil
        let noNavigate: ((PaneBrowsePath) -> Void)? = nil
        let noDeselect: ((Int?) -> Void)? = nil
        #expect(pane() != pane(onOpenSettings: noSettings))
        #expect(pane() != pane(onBarEdgeFlip: noFlip))
        #expect(pane() != pane(onColumnNavigate: noNavigate))
        #expect(pane() != pane(onBackgroundDeselect: noDeselect))
    }

    @Test("A delegate that says it is different is treated as different")
    func delegateInequivalenceIsCompared() {
        #expect(pane(delegate: StubDelegate(id: 0)) != pane(delegate: StubDelegate(id: 1)))
    }

    // MARK: What is deliberately NOT compared

    /// The four host callbacks are compared for PRESENCE only, and this pins that this is a
    /// decision rather than an oversight. Each dispatches through the host's reference types and
    /// property wrappers, so a closure built on an earlier render reads the same live state as a
    /// fresh one; comparing them by identity is impossible anyway (closures are not `Equatable`),
    /// and treating "a new closure instance" as a change is exactly the condition that made the
    /// gate useless before it existed.
    @Test("Rebuilt callbacks alone do not count as a change")
    func freshClosuresDoNotDefeatTheGate() {
        let a = pane(onOpenSettings: {}, onBarEdgeFlip: {},
                     onColumnNavigate: { _ in }, onBackgroundDeselect: { _ in })
        let b = pane(onOpenSettings: {}, onBarEdgeFlip: {},
                     onColumnNavigate: { _ in }, onBackgroundDeselect: { _ in })
        #expect(a == b)
    }

    /// The whole point, stated as an assertion: the host rebuilds the delegate on every render, and
    /// a delegate that vouches for itself must not drag the pane into a re-render with it.
    @Test("A rebuilt but equivalent delegate does not count as a change")
    func equivalentDelegateDoesNotDefeatTheGate() {
        #expect(pane(delegate: StubDelegate(id: 7)) == pane(delegate: StubDelegate(id: 7)))
    }

    /// A conformer that has not opted in gets the protocol's default `false`, so it keeps today's
    /// behaviour — the pane re-renders, as it always did. Asserted because the default is the thing
    /// standing between a future delegate and a silent staleness bug.
    @Test("A delegate that has not opted in blocks the gate rather than being assumed equivalent")
    func nonOptedInDelegateBlocksTheGate() {
        struct Bare: FileActionDelegate {
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
        #expect(pane(delegate: Bare()) != pane(delegate: Bare()))
    }

    /// Presence of the host's Quick Look callback decides where the row menu's preview goes — the
    /// host's panel, or this pane's own fallback state. A pane that gained or lost it renders a
    /// materially different menu action, so the gate has to notice.
    @Test("Gaining or losing the host's Quick Look presenter is noticed")
    func quickLookPresenterPresenceIsCompared() {
        #expect(pane() != pane(onQuickLook: nil))
        // …and presence ONLY: two different closures are the same pane, or the gate would open on
        // every render (the host builds a fresh closure each time), which is the whole hazard the
        // callback comparisons are written this way to avoid.
        #expect(pane(onQuickLook: { _ in }) == pane(onQuickLook: { _ in }))
    }
}
