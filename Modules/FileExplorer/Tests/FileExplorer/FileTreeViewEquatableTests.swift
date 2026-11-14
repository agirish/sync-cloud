import Testing
import SwiftUI
import Sync
import Design
@testable import FileExplorer

/// Mutation-tests `FileTreeView.==`, the pane's re-render gate. When `==` answers true SwiftUI keeps
/// the pane it has, so a stored property the comparison forgets is a value the pane silently stops
/// noticing (a stale badge, a selection that doesn't highlight).
///
/// Each compared input is changed in turn and `==` must notice: the only shape of test that fails
/// when someone adds a property and forgets the comparison. The inputs deliberately left out (the
/// delegate and the host callbacks) are pinned in the last section.
@MainActor
@Suite struct FileTreeViewEquatableTests {

    private struct StubDelegate: NoOpFileActions {
        /// Distinguishes two stubs so the delegate half of the comparison can be driven.
        var id: Int = 0
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
        search: PaneSearchResults? = nil,
        searchHitIndex: Int = 0,
        searchRevealNonce: Int = 0,
        isActivePane: Bool = true,
        viewMode: PaneViewMode = .tree,
        childrenIndex: PaneChildrenIndex? = nil,
        browsePath: PaneBrowsePath = PaneBrowsePath(),
        onColumnNavigate: ((PaneBrowsePath) -> Void)? = { _ in },
        onNeedChildren: ((String, Bool) -> Void)? = { _, _ in },
        graftsInFlight: Set<String> = [],
        onBackgroundDeselect: ((Int?) -> Void)? = { _ in },
        onQuickLook: ((URL) -> Void)? = { _ in },
        downloadChannel: NotificationCenter = .default,
        hostExpanded: Set<String>? = nil
    ) -> FileTreeView {
        FileTreeView(
            tree: tree, otherTree: otherTree, isLoading: isLoading, currentPath: currentPath,
            selection: .constant(selection), otherSelection: otherSelection, isLeft: isLeft,
            delegate: delegate, diffIndex: diffIndex, otherPaneName: otherPaneName,
            rootPathIsValid: rootPathIsValid, providerIsEnabled: providerIsEnabled,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries, rootPath: rootPath,
            onOpenSettings: onOpenSettings, isSingleSource: isSingleSource,
            placement: placement, onBarEdgeFlip: onBarEdgeFlip,
            search: search, searchHitIndex: searchHitIndex, searchRevealNonce: searchRevealNonce, isActivePane: isActivePane,
            viewMode: viewMode, childrenIndex: childrenIndex,
            browsePath: .constant(browsePath), onColumnNavigate: onColumnNavigate,
            onNeedChildren: onNeedChildren, graftsInFlight: graftsInFlight,
            onBackgroundDeselect: onBackgroundDeselect, onQuickLook: onQuickLook,
            downloadChannel: downloadChannel,
            hostExpanded: hostExpanded.map { value in .constant(value) })
    }

    @Test("An unchanged pane compares equal — otherwise the gate never engages at all")
    func identicalPanesAreEqual() {
        #expect(pane() == pane())
    }

    // MARK: The mutation sweep

    /// The open folders arrive from `ContentView` as a binding; left out of `==`, every disclosure
    /// triangle in the tree would stop responding to clicks. Compared by value: two bindings onto the
    /// same storage are fresh structs on every render, so anything else never differs or always does.
    @Test("The open folders are noticed — the host owns them now, so the gate must see them")
    func hostExpansionIsCompared() {
        #expect(pane(hostExpanded: []) != pane(hostExpanded: ["/root/Documents"]))
    }

    /// A pane with no host keeps its own set and compares equal to another such pane, so the many
    /// call sites that mount a pane to ask about something else are unaffected.
    @Test("An unhosted pane is unchanged by the hoist")
    func anUnhostedPaneStillComparesEqual() {
        #expect(pane(hostExpanded: nil) == pane(hostExpanded: nil))
        #expect(pane(hostExpanded: nil) != pane(hostExpanded: []),
                "a hosted pane and an unhosted one read as the same view")
    }

    /// A write through `expanded`'s setter (the search reveal, the columns carry-over, the prune on a
    /// root change) lands in the host's set, not the pane's own. Mutation: inverting the setter's
    /// condition, so a hosted pane writes its dead `ownExpanded`, must fail it.
    ///
    /// Drives the property, not the binding: a write through the binding skips the setter, so the
    /// mutation would pass.
    @Test("A reveal or a prune writes through to the window's set")
    func writingTheExpansionReachesTheHost() {
        final class Box { var value: Set<String> = [] }
        let box = Box()
        let hosted = FileTreeView(
            tree: PaneTree(side: .left, version: 1, nodes: []),
            otherTree: PaneTree(side: .right, version: 1, nodes: []),
            isLoading: false, currentPath: "/root", selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: StubDelegate(),
            hostExpanded: Binding(get: { box.value }, set: { box.value = $0 }))

        hosted.expandedForTesting = ["/root/Documents"]

        #expect(box.value == ["/root/Documents"],
                "the pane wrote its expansion into its own storage while the window held the set — a search reveal opens nothing")
        #expect(hosted.expandedForTesting == ["/root/Documents"],
                "the pane cannot read back what it just wrote")
    }

    // The unhosted half of that setter is deliberately not tested: the fallback is `@State`, and a
    // `@State` write on a struct never installed in the view tree is discarded, so a round-trip test
    // fails against correct code. Every suite that mounts an unhosted pane covers it.

    /// Each input the gate compares, changed alone against the reference pane.
    enum Input: String, CaseIterable {
        case tree, otherTree, isLoading, currentPath
        /// A `Binding`: comparing the binding rather than its value would make every click
        /// invisible to the gate.
        case selection
        /// Drives the paste-from-other menu item.
        case otherSelection
        case isLeft
        /// The badges render from it.
        case diffIndex
        /// The menu labels name it.
        case otherPaneName
        /// Both select the placeholder.
        case rootPathIsValid, providerIsEnabled
        /// Changes the empty state's caption.
        case hasOnlyHiddenEntries
        /// The invalid placeholder prints it.
        case rootPath
        /// Empties the diff index and reshapes the row menu.
        case isSingleSource
        /// Changes what every row draws; a kept view would show the previous query's answer.
        case search
        /// What fires the reveal: kept, ↩ would move the hit and the reveal's `.onChange` would
        /// never fire.
        case searchHitIndex
        /// The reveal's only trigger: ↩ over a single hit moves nothing but the nonce.
        case searchRevealNonce
        /// Sets the selection wash's strength.
        case isActivePane
        /// Picks the whole presentation.
        case viewMode
        /// The columns resolve their rows from it.
        case childrenIndex
        /// A `Binding`, compared by value.
        case browsePath
        /// By identity: two panes must never share one.
        case placement
        /// By identity: `.onReceive` is declared in `body`, so a pane that keeps its view keeps
        /// its subscription to the channel it was first mounted with.
        case downloadChannel
        /// A delegate that says it is different.
        case delegate
    }

    /// Two panes differing only in `input`.
    private func variants(_ input: Input) -> (FileTreeView, FileTreeView) {
        switch input {
        case .tree: return (pane(), pane(tree: PaneTree(side: .left, version: 2, nodes: [])))
        case .otherTree: return (pane(), pane(otherTree: PaneTree(side: .right, version: 2, nodes: [])))
        case .isLoading: return (pane(), pane(isLoading: true))
        case .currentPath: return (pane(), pane(currentPath: "/root/Docs"))
        case .selection: return (pane(), pane(selection: ["/root/a.txt"]))
        case .otherSelection: return (pane(), pane(otherSelection: ["/other/a.txt"]))
        case .isLeft: return (pane(), pane(isLeft: false))
        case .diffIndex:
            return (pane(), pane(diffIndex: DiffStatusIndex(differences: [difference("a.txt")], rootPath: "/root")))
        case .otherPaneName: return (pane(), pane(otherPaneName: "Dropbox"))
        case .rootPathIsValid: return (pane(), pane(rootPathIsValid: false))
        case .providerIsEnabled: return (pane(), pane(providerIsEnabled: false))
        case .hasOnlyHiddenEntries: return (pane(), pane(hasOnlyHiddenEntries: true))
        case .rootPath: return (pane(), pane(rootPath: "/elsewhere"))
        case .isSingleSource: return (pane(), pane(isSingleSource: true))
        case .search:
            return (pane(), pane(search: PaneSearchResults(side: .left, generation: 1, query: "a",
                                                           tree: PaneTree(side: .left, version: 1, nodes: []),
                                                           otherPaths: nil)))
        case .searchHitIndex: return (pane(), pane(searchHitIndex: 1))
        case .searchRevealNonce: return (pane(), pane(searchRevealNonce: 1))
        case .isActivePane: return (pane(), pane(isActivePane: false))
        case .viewMode: return (pane(), pane(viewMode: .columns))
        case .childrenIndex:
            return (pane(childrenIndex: PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: []), treeRoot: "/root")),
                    pane(childrenIndex: PaneChildrenIndex(tree: PaneTree(side: .left, version: 2, nodes: []), treeRoot: "/root")))
        case .browsePath:
            var drilled = PaneBrowsePath()
            drilled.drill(into: "Docs", atDepth: 0)
            return (pane(), pane(browsePath: drilled))
        case .placement: return (pane(placement: PaneBarPlacement()), pane(placement: PaneBarPlacement()))
        case .downloadChannel:
            return (pane(downloadChannel: NotificationCenter()), pane(downloadChannel: NotificationCenter()))
        case .delegate: return (pane(delegate: StubDelegate(id: 0)), pane(delegate: StubDelegate(id: 1)))
        }
    }

    @Test("Each compared input is noticed", arguments: Input.allCases)
    func eachComparedInputIsNoticed(_ input: Input) {
        let (a, b) = variants(input)
        #expect(a != b, "\(input.rawValue) changed and the gate kept the old pane")
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
        let noChildren: ((String, Bool) -> Void)? = nil
        #expect(pane() != pane(onNeedChildren: noChildren))
    }

    /// The directories being read right now drive the column's spinner, on when a listing starts and
    /// off when it lands. Left out of the gate, neither edge redraws the pane on its own.
    @Test("The in-flight graft set is noticed — it is what turns the column's spinner on and off")
    func graftsInFlightIsCompared() {
        #expect(pane() != pane(graftsInFlight: ["/root/deep"]))
        #expect(pane(graftsInFlight: ["/root/a"]) != pane(graftsInFlight: ["/root/b"]))
        #expect(pane(graftsInFlight: ["/root/a"]) == pane(graftsInFlight: ["/root/a"]),
                "equal sets must not defeat the gate — the pane would re-render on every render")
    }

    // MARK: What is deliberately NOT compared

    /// The host callbacks are compared for presence only, by decision: each reads the host's live
    /// state through reference types, so an old closure behaves like a fresh one, and treating a new
    /// closure instance as a change would open the gate on every render.
    @Test("Rebuilt callbacks alone do not count as a change")
    func freshClosuresDoNotDefeatTheGate() {
        let a = pane(onOpenSettings: {}, onBarEdgeFlip: {},
                     onColumnNavigate: { _ in }, onBackgroundDeselect: { _ in })
        let b = pane(onOpenSettings: {}, onBarEdgeFlip: {},
                     onColumnNavigate: { _ in }, onBackgroundDeselect: { _ in })
        #expect(a == b)
    }

    /// The host rebuilds the delegate on every render; one that vouches for itself must not force a
    /// re-render.
    @Test("A rebuilt but equivalent delegate does not count as a change")
    func equivalentDelegateDoesNotDefeatTheGate() {
        #expect(pane(delegate: StubDelegate(id: 7)) == pane(delegate: StubDelegate(id: 7)))
    }

    /// A conformer that has not opted in gets the protocol's default `false`, so the pane re-renders
    /// rather than going stale.
    @Test("A delegate that has not opted in blocks the gate rather than being assumed equivalent")
    func nonOptedInDelegateBlocksTheGate() {
        #expect(pane(delegate: NoOpFileActionDelegate()) != pane(delegate: NoOpFileActionDelegate()))
    }

    /// Presence of the host's Quick Look callback decides where the row menu's preview goes (the
    /// host's panel or the pane's own fallback), so the gate has to notice it.
    @Test("Gaining or losing the host's Quick Look presenter is noticed")
    func quickLookPresenterPresenceIsCompared() {
        #expect(pane() != pane(onQuickLook: nil))
        // Presence only: the host builds a fresh closure each render.
        #expect(pane(onQuickLook: { _ in }) == pane(onQuickLook: { _ in }))
    }
}
