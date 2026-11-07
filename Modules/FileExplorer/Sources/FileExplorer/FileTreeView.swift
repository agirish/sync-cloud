import AppKit
import Combine
import Design
import Events
import QuickLook
import SwiftUI
import Sync

extension Notification.Name {
    /// Posted after a cloud-only "Download" request is accepted, carrying a `CloudDownloadRequest`
    /// in `object`. The pane listens (one subscription, not one per row) and watches the content
    /// arrive for the requester: the row menu, the Info inspector's Download button and the row are
    /// separate views with no shared state, so otherwise the badge would linger.
    ///
    /// The payload names the posting pane (`CloudDownloadRequest.paneToken`): both panes can show
    /// the same path, and a bare-path post would make both watch it, with twin polls and a duplicate
    /// `forget` bumping the memo generation app-wide. A row reads the pane's watches
    /// (`FileRowView.awaitingDownloadID`).
    static let cloudDownloadRequested = Notification.Name("SyncCloudCloudDownloadRequested")

    /// Posted by the pane when its watch of a requested download ends — the content landed, or the
    /// attempts ran out — carrying the `CloudDownloadRequest` it watched in `object`, on the channel
    /// the request came in on.
    ///
    /// For the Info inspector's preview (`InspectorFilePreview`), which is outside the pane's view
    /// tree and can't be handed its watches; a watch of its own would double the polls and
    /// `CloudOnlyBadgeCache.forget`s. Not posted for a superseded request.
    static let cloudDownloadWatchEnded = Notification.Name("SyncCloudCloudDownloadWatchEnded")
}

/// Recursive tree view for one comparison pane (left or right); context menu and actions go through the delegate.
///
/// `Equatable`, and wrapped in `.equatable()` by its host, so the pane doesn't re-render on
/// unrelated changes: `ContentView` re-evaluates both panes on any of its manager's many
/// `@Published` writes, and hands each pane a fresh delegate, closures and `Binding`s that a
/// memberwise comparison would always call different.
///
/// `==` compares by value everything the pane renders from, asks the delegate to vouch for itself
/// (`FileActionDelegate.isEquivalent(to:)`), and checks callbacks only for presence: they dispatch
/// through the host's live state, so an older closure acts like a fresh one. **Add every new
/// stored property to `==`**, or the pane stops noticing it.
public struct FileTreeView: View, Equatable {
    /// File tree for this pane. Boxed so SwiftUI compares one `Int` instead of recursing through
    /// tens of thousands of nodes on the main thread; see `PaneTree`.
    public let tree: PaneTree
    /// File tree for the opposite pane (e.g. for “copy to other pane”). Boxed like `tree`: it is
    /// never rendered here, only looked up by menus.
    public let otherTree: PaneTree
    /// Whether this pane’s tree is currently loading.
    public let isLoading: Bool
    /// Absolute path of the current folder shown in this pane.
    public let currentPath: String

    @Binding public var selection: Set<String>
    /// Selected paths in the opposite pane (for mutual exclusivity and paste-from-other).
    public let otherSelection: Set<String>
    /// `true` if this view is for the left pane, `false` for the right.
    public let isLeft: Bool

    /// Handles copy, move, delete, rename, focus, and other file actions.
    public let delegate: FileActionDelegate

    /// Diff status per absolute node path, as rendered: `init` forces it to `.empty` on the
    /// single-source rail, so this is the one gate for every difference accessory (a row's badge, a
    /// folder's pill) in both presentations. It reads back what is drawn, not what was handed in.
    public let diffIndex: DiffStatusIndex

    /// Display name of the opposite pane's provider, used as the copy/move target in menu labels.
    public let otherPaneName: String

    /// Whether the provider's root path was a directory at Settings' last validity check (a
    /// focused subfolder isn't tracked; see `PaneEmptyState.classify`).
    public let rootPathIsValid: Bool
    /// Whether the pane's provider is enabled in Settings.
    public let providerIsEnabled: Bool
    /// True when the folder has entries but the hidden-files filter removed all of them.
    public let hasOnlyHiddenEntries: Bool
    /// The provider's root path, shown as the offending path in the invalid placeholder.
    public let rootPath: String
    /// Opens the Settings scene (preselected on the providers tab by the caller); nil hides
    /// the "Open Settings" buttons.
    public let onOpenSettings: (() -> Void)?

    /// True for the single-source rail rather than a comparison pane. With no other pane, its row
    /// menu drops Ignore and Copy/Move to the other provider, and "Compare only this folder" becomes
    /// "Open".
    public let isSingleSource: Bool

    /// Shared placement scratch space, one per pane, owned by the host. This view fills its live
    /// geometry (`rowBottoms`/`viewportHeight`) from probes; the host reads the edge in its `body`.
    /// The single-source rail has one too: its result message docks by the bar's rule. `nil` only
    /// where no host asks.
    private let placement: PaneBarPlacement?
    /// Called when a scroll flips the resolved edge, so the host re-renders and the bar
    /// cross-fades. A selection change needs no callback: it already re-renders the host.
    private let onBarEdgeFlip: (() -> Void)?

    /// How this pane presents its tree. Defaults to `.tree` (the single-source rail); only the two
    /// comparison panes pass `.columns`.
    public let viewMode: PaneViewMode
    /// Path → children for this pane's published tree, used only by the columns presentation.
    /// Built once per publish by the host; see `PaneChildrenIndex`.
    public let childrenIndex: PaneChildrenIndex?
    /// Where the pane is browsing inside its loaded tree. Writing this drills a column; it never
    /// re-roots, so the comparison scope and every difference badge survive navigation.
    @Binding public var browsePath: PaneBrowsePath
    /// Applies a new column stack. The host owns this because the seam link makes a column drill a
    /// two-pane move; defaults to writing the binding for callers with no sibling pane.
    public let onColumnNavigate: ((PaneBrowsePath) -> Void)?
    /// Walks a directory the pane's budgeted walk didn't read, via
    /// `FileSyncManager.loadColumnChildren`. Passed to `PaneColumnsView`, the only view that sees
    /// when a column needs it. The second argument is `passive`; see
    /// `PaneOutlineRows.onNeedChildren`.
    public let onNeedChildren: ((String, Bool) -> Void)?
    /// Directories whose deferred listing is running, for `PaneColumnsView` to tell "being read"
    /// from "could not be read". See its `graftsInFlight`.
    public let graftsInFlight: Set<String>
    /// The panes' sort order, for the background menus' Sort By to tick. Written through
    /// `delegate.handleSort`, as the pane bar's picker writes the same key.
    public let sortOption: SortOption
    /// A plain click on the pane's empty space, carrying the depth of the column it landed in
    /// (`nil` in Tree mode, and past the last column, where nothing is truncated).
    ///
    /// The host owns it, as it owns `onColumnNavigate`: the selection this dismisses is usually in
    /// the other pane (only one pane holds a selection), and only the host reaches across. `nil` for
    /// callers with no sibling pane.
    public let onBackgroundDeselect: ((Int?) -> Void)?

    /// This pane's search results: what matched, what has matches beneath it, and which side each
    /// hit is on. `.empty` (the default) is a pane with no query.
    ///
    /// Stamped, not walked: a broad query fills three maps with thousands of entries and this is
    /// compared by `==` on every render. See `PaneSearchResults`.
    public let search: PaneSearchResults
    /// The type filter's folder counts, or `nil` for a pane with no filter.
    public let typeFilter: PaneTypeFilterDecor?
    /// The filter that left this folder showing nothing, for the empty state and its button that
    /// clears it. `nil` unless the filter emptied the folder.
    public let typeFilterEmptied: PaneTypeFilter?
    /// What that empty state calls the folder ("No PDFs in Downloads"). The host's name for it: at a
    /// provider's root the last path component is a container name nobody would recognize.
    public let typeFilterFolderName: String?
    public let onClearTypeFilter: (() -> Void)?
    /// Which hit ↩/⇧↩ have walked to. This view reveals it on arrival, one hit at a time: expanding
    /// its ancestors and scrolling to it in Tree, opening the columns down to it in Columns.
    public let searchHitIndex: Int
    /// The host's reveal signal, bumped only for a new query and for ↩/⇧↩. The reveal fires on this,
    /// never on `search.generation`, which also moves on every background republish and would yank
    /// the user back from wherever they went. See `PaneSearchFieldState.revealNonce`.
    public let searchRevealNonce: Int
    /// The host's request to bring one row into view: the open document, selected for the user.
    /// See `PaneRowReveal`; acted on only while that row is the whole selection (`revealsRow`).
    /// `nil`, the default, for every caller but the app's left pane.
    public let rowReveal: PaneRowReveal?
    /// Told when this pane has acted on `rowReveal` (scrolled to its row) so the host can retire
    /// it. Only the pane knows when: at once if on screen, or when it next appears. Left standing,
    /// the reveal would jump back to the document on every appearance while its row stayed
    /// selected. Not in the equality gate: a closure, and the host's to hold.
    public let onRowRevealed: ((PaneRowReveal) -> Void)?

    /// Whether this pane is the one the action bar acts on. Drives the strength of the selection
    /// wash, since nothing else shows which pane holds the selection: `PaneListSelectionStyler`
    /// turns the system highlight off, and the window is pinned to `controlActiveState == .active`.
    /// Defaults true: the single-source rail is the only pane on screen.
    public let isActivePane: Bool

    /// Presents the row menu's Quick Look through the host's panel, when it offers one. There is
    /// one shared `QLPreviewPanel`, so it needs one owner: two could not see each other's preview,
    /// and the row menu's would go stale when the selection moved (see
    /// `CurrentSelection.previewFollow`).
    ///
    /// Optional, so a caller with no panel (every test) keeps the self-contained behaviour.
    private let onQuickLook: ((URL) -> Void)?

    /// The fallback presenter, used only when `onQuickLook` is nil.
    @State private var quickLookItem: URL?

    /// Where a row menu's preview goes: the host if it offered a panel, this pane's own otherwise.
    private func presentQuickLook(_ url: URL) {
        if let onQuickLook { onQuickLook(url) } else { quickLookItem = url }
    }
    /// The downloads this pane is watching, keyed by path; see `PaneDownloadWatch`. While a path is
    /// here, its row re-resolves its badge from here rather than watching anything itself; the Info
    /// inspector's preview hears when it ends (`.cloudDownloadWatchEnded`).
    ///
    /// A collection, so a second download queued from the row menu doesn't cancel the first one's
    /// watch and leave a stale cloud-only badge. One subscription here, not a Combine subscription
    /// per visible row. The result reaches the row through the memo: the watch `record`s it and
    /// drops its entry, which re-keys the row's badge task (`FileRowView.BadgeID`) to re-read it.
    @StateObject private var downloads = PaneDownloadWatch()

    /// Resolves this pane's selection — and the other pane's, for the cross-pane items — once for
    /// every row menu that asks, in whichever presentation is showing. See `PaneSelectionResolver`.
    @State private var selectionResolver = PaneSelectionResolver()

    /// The folders whose children are showing, in the Tree presentation. Pane state, not model
    /// state: it survives a republish (identity is the node path) and nothing resets it. Here, not
    /// in `PaneOutlineRows`, because search writes it: revealing a hit is
    /// `expanded.formUnion(hit.ancestorPaths)`. See `PaneOutlineRows`.
    ///
    /// The fallback when no host offers storage (as in tests); see ``hostExpanded``. As `@State` it
    /// dies with the view, and every workspace switch remounts `paneColumn` in a different place,
    /// so opened folders would close on the way to Compare and back.
    @State private var ownExpanded: Set<String> = []

    /// Where the host keeps this pane's expansion, when it keeps it at all. Optional, so test call
    /// sites keep their own storage; a defaulted `.constant([])` would silently drop every write,
    /// including a search reveal's.
    var hostExpanded: Binding<Set<String>>?

    /// The expansion set, wherever it lives. Every reader and writer in this file goes through here,
    /// so none reads the fallback while the host writes the real one.
    private var expanded: Set<String> {
        get { hostExpanded?.wrappedValue ?? ownExpanded }
        nonmutating set {
            if let hostExpanded { hostExpanded.wrappedValue = newValue } else { ownExpanded = newValue }
        }
    }

    /// `expanded` as a binding, for `PaneOutlineRows` to open and close single rows.
    private var expandedBinding: Binding<Set<String>> {
        hostExpanded ?? $ownExpanded
    }

    /// The expansion set as this view reads and writes it, for tests, like
    /// `PaneOutlineRows.expansionBindingForTesting`. The property, not the binding: the search
    /// reveal, the columns carry-over and the prune on a root change write through ``expanded``'s
    /// setter, while the triangles use ``expandedBinding``. Inverting that setter's condition must
    /// fail a test through this seam; a binding would bypass the setter.
    var expandedForTesting: Set<String> {
        get { expanded }
        nonmutating set { expanded = newValue }
    }

    /// The column stack this pane last carried into its Tree presentation; `carryColumnsIntoTree`
    /// scrolls only when the parked stack differs. Pane state, so it survives the switch between
    /// presentations, the transition it exists to notice.
    @State private var carriedStack = PaneBrowsePath()

    /// The place this pane last carried out of the Tree into its columns; `carryTreeIntoColumns`
    /// stands down while the Tree's answer is unchanged. Pane state, for `carriedStack`'s reason.
    @State private var carriedTreePlace: PaneBrowsePath?

    /// The channel `.cloudDownloadRequested` travels on for this pane: `.default` in the app, a
    /// private `NotificationCenter` in a test that mounts a pane.
    ///
    /// `paneToken` names a surface, not a pane, and under `swift test` several suites mount panes at
    /// once, so on the shared center one suite's post would run another's watch and move the value
    /// it asserts on. The app has one pane per surface and passes nothing; each test pane gets its
    /// own channel. See "A mounted view is a live subscriber, in every suite at once" in
    /// `docs/flaky-tests.md`.
    public let downloadChannel: NotificationCenter

    /// This pane's identity for download-notification scoping, the receiving side of
    /// `CloudDownloadRequest.paneToken`. Computed from facts `==` already compares. Not `private` so
    /// `FileTreeViewPaneNameTests` can catch a receiver hardcoded to one token.
    var paneToken: PaneToken { PaneToken(isLeft: isLeft, isSingleSource: isSingleSource) }

    /// The root a republish's badge-memo clear is scoped to: `currentPath`, not `rootPath`. Focused
    /// on a subfolder, the republished tree holds only what is under `currentPath`, so `rootPath`
    /// would clear entries this pane can't serve. Non-private so `FileTreeViewPaneNameTests` pins it.
    var badgeMemoRoot: String { currentPath }

    public init(tree: PaneTree, otherTree: PaneTree, isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, otherSelection: Set<String>, isLeft: Bool, delegate: FileActionDelegate, diffIndex: DiffStatusIndex = .empty, otherPaneName: String? = nil, rootPathIsValid: Bool = true, providerIsEnabled: Bool = true, hasOnlyHiddenEntries: Bool = false, rootPath: String? = nil, onOpenSettings: (() -> Void)? = nil, isSingleSource: Bool = false, placement: PaneBarPlacement? = nil, onBarEdgeFlip: (() -> Void)? = nil, search: PaneSearchResults? = nil, searchHitIndex: Int = 0, searchRevealNonce: Int = 0, rowReveal: PaneRowReveal? = nil, onRowRevealed: ((PaneRowReveal) -> Void)? = nil, isActivePane: Bool = true, viewMode: PaneViewMode = .tree, childrenIndex: PaneChildrenIndex? = nil, browsePath: Binding<PaneBrowsePath> = .constant(PaneBrowsePath()), onColumnNavigate: ((PaneBrowsePath) -> Void)? = nil, onNeedChildren: ((String, Bool) -> Void)? = nil, graftsInFlight: Set<String> = [], sortOption: SortOption = .name, onBackgroundDeselect: ((Int?) -> Void)? = nil, onQuickLook: ((URL) -> Void)? = nil, downloadChannel: NotificationCenter = .default, hostExpanded: Binding<Set<String>>? = nil, typeFilter: PaneTypeFilterDecor? = nil, typeFilterEmptied: PaneTypeFilter? = nil, typeFilterFolderName: String? = nil, onClearTypeFilter: (() -> Void)? = nil) {
        self.typeFilter = typeFilter
        self.typeFilterEmptied = typeFilterEmptied
        self.typeFilterFolderName = typeFilterFolderName
        self.onClearTypeFilter = onClearTypeFilter
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self.otherSelection = otherSelection
        self.isLeft = isLeft
        self.delegate = delegate
        // A difference is about the other pane, and the rail has none: its badges would be
        // whatever Compare last scanned. Emptied here, not at each render site, so neither
        // presentation can draw one.
        self.diffIndex = isSingleSource ? .empty : diffIndex
        self.otherPaneName = otherPaneName ?? (isLeft ? "Right" : "Left")
        self.rootPathIsValid = rootPathIsValid
        self.providerIsEnabled = providerIsEnabled
        self.hasOnlyHiddenEntries = hasOnlyHiddenEntries
        self.rootPath = rootPath ?? currentPath
        self.onOpenSettings = onOpenSettings
        self.isSingleSource = isSingleSource
        self.placement = placement
        self.onBarEdgeFlip = onBarEdgeFlip
        // This pane's own empty results, not a shared constant, so the side is right even with no
        // search: `PaneSearchResults.==` reads the side, and a wrong one never compares equal.
        self.search = search ?? .empty(side: tree.side)
        self.searchHitIndex = searchHitIndex
        self.searchRevealNonce = searchRevealNonce
        self.rowReveal = rowReveal
        self.onRowRevealed = onRowRevealed
        self.isActivePane = isActivePane
        self.viewMode = viewMode
        self.childrenIndex = childrenIndex
        self._browsePath = browsePath
        self.onColumnNavigate = onColumnNavigate
        self.onNeedChildren = onNeedChildren
        self.graftsInFlight = graftsInFlight
        self.sortOption = sortOption
        self.onBackgroundDeselect = onBackgroundDeselect
        self.onQuickLook = onQuickLook
        self.downloadChannel = downloadChannel
        self.hostExpanded = hostExpanded
    }

    /// See the note on the type. Every stored property is accounted for: values by `==`, the
    /// `Binding`s by their wrapped values, the placement box by identity, the delegate by its own
    /// equivalence, and the host callbacks by presence.
    ///
    /// `nonisolated` because `Equatable` is; `assumeIsolated` because the view and its `@MainActor`
    /// delegate are main-actor, and SwiftUI's view diffing, the only caller, runs on the main actor.
    nonisolated public static func == (lhs: FileTreeView, rhs: FileTreeView) -> Bool {
        MainActor.assumeIsolated { isEqualOnMainActor(lhs, rhs) }
    }

    private static func isEqualOnMainActor(_ lhs: FileTreeView, _ rhs: FileTreeView) -> Bool {
        lhs.tree == rhs.tree
            && lhs.otherTree == rhs.otherTree
            && lhs.isLoading == rhs.isLoading
            && lhs.currentPath == rhs.currentPath
            && lhs.selection == rhs.selection
            && lhs.otherSelection == rhs.otherSelection
            && lhs.isLeft == rhs.isLeft
            && lhs.diffIndex == rhs.diffIndex
            && lhs.otherPaneName == rhs.otherPaneName
            && lhs.rootPathIsValid == rhs.rootPathIsValid
            && lhs.providerIsEnabled == rhs.providerIsEnabled
            && lhs.hasOnlyHiddenEntries == rhs.hasOnlyHiddenEntries
            && lhs.rootPath == rhs.rootPath
            && lhs.isSingleSource == rhs.isSingleSource
            && lhs.search == rhs.search
            && lhs.typeFilter == rhs.typeFilter
            && lhs.typeFilterEmptied == rhs.typeFilterEmptied
            && lhs.typeFilterFolderName == rhs.typeFilterFolderName
            && (lhs.onClearTypeFilter == nil) == (rhs.onClearTypeFilter == nil)
            && lhs.searchHitIndex == rhs.searchHitIndex
            // In the gate because the reveal's `.onChange` only sees values that cause a re-render.
            && lhs.searchRevealNonce == rhs.searchRevealNonce
            // In the gate for the nonce's reason: the row reveal listens to it with `.onChange`.
            && lhs.rowReveal == rhs.rowReveal
            && lhs.isActivePane == rhs.isActivePane
            // Without this a graft landing or finishing can't redraw the pane, and its spinner
            // sticks in whatever state the last unrelated update left.
            && lhs.graftsInFlight == rhs.graftsInFlight
            // The background menus tick the current order; a stale value ticks the wrong one.
            && lhs.sortOption == rhs.sortOption
            && lhs.viewMode == rhs.viewMode
            // The value, not the binding: a `Binding` isn't `Equatable` and is a fresh struct every
            // render. Leave this out and a host-held expansion change builds a new pane that
            // `EquatableView` calls unchanged, so no disclosure triangle responds to clicks.
            // `FileTreeViewEquatableTests` holds this line.
            && lhs.hostExpanded?.wrappedValue == rhs.hostExpanded?.wrappedValue
            && lhs.childrenIndex == rhs.childrenIndex
            && lhs.browsePath == rhs.browsePath
            && lhs.placement === rhs.placement
            && lhs.downloadChannel === rhs.downloadChannel
            && (lhs.onOpenSettings == nil) == (rhs.onOpenSettings == nil)
            && (lhs.onBarEdgeFlip == nil) == (rhs.onBarEdgeFlip == nil)
            && (lhs.onColumnNavigate == nil) == (rhs.onColumnNavigate == nil)
            // Presence: a pane without it leaves a column the walk skipped blank for good.
            && (lhs.onNeedChildren == nil) == (rhs.onNeedChildren == nil)
            && (lhs.onBackgroundDeselect == nil) == (rhs.onBackgroundDeselect == nil)
            // Presence decides whether the row menu presents through the host's panel or this
            // pane's fallback, so gaining or losing it must re-render.
            && (lhs.onQuickLook == nil) == (rhs.onQuickLook == nil)
            && lhs.delegate.isEquivalent(to: rhs.delegate)
    }

    /// The list viewport's global frame (height + window-space top edge).
    private struct ViewportFrameKey: PreferenceKey {
        static let defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    /// Applies `carryBack` when the Columns presentation arrives, so leaving the Tree opens the
    /// columns on the folder the Tree was in, not the older stack they were parked with. Through
    /// `onColumnNavigate`, not the binding: the seam link mirrors a column move into the sibling
    /// pane, which only the host can reach.
    ///
    /// Gated on the place having changed since the last carry: this branch appears on every tab
    /// switch and pane collapse, and a stale answer would pull the columns away from where the user
    /// walked since.
    private func carryTreeIntoColumns(index: PaneChildrenIndex) {
        // **Never decide from a tree that is still arriving.** Progressive loading first publishes
        // a shallow tree, where a selection three folders down prunes to its first component: a
        // confident wrong answer that would be applied and latched. `pruneBrowsePath` guards the
        // same hazard. The falling edge of `isLoading` re-runs this (see the Columns branch), so an
        // arrival during a load is still carried.
        guard !isLoading else { return }
        guard let target = Self.carryBack(selection: selection, treeRoot: currentPath, index: index),
              target != carriedTreePlace else { return }
        carriedTreePlace = target
        guard target != browsePath else { return }
        (onColumnNavigate ?? { browsePath = $0 })(target)
    }

    /// After a scroll or layout change to the row positions, re-resolves the edge and, if it
    /// flipped, asks the host to re-render (an animated cross-fade). A selection change re-renders
    /// the host anyway, so isn't handled here. Two rules keep this out of the layout pass that
    /// called it:
    ///
    /// 1. It re-resolves against the bar's selection of record, never this pane's raw List
    ///    selection. The two disagree for a runloop turn after a click, and resolving from each
    ///    makes pane and host commit opposite edges forever; see `PaneBarPlacement.barSelection`.
    /// 2. The flip runs on the next runloop turn. This runs inside a preference callback, inside
    ///    AppKit's layout pass, and writing host state synchronously re-enters that pass until
    ///    AppKit crashes on too many constraint passes. The delay hides under the cross-fade.
    private func flipEdgeIfScrolledAcross() {
        placement?.flipIfEdgeMoved(onBarEdgeFlip)
    }

    // MARK: - Revealing a search hit

    /// How long after a reveal the second scroll attempt is made, as with
    /// `PaneColumnsView.revealRetryDelay`. A `scrollTo` issued before layout settles is silently
    /// dropped, and the hit's row doesn't exist until its ancestors have opened. A second attempt
    /// on a row already in view moves nothing.
    ///
    /// So neither attempt proves anything: a test must observe the row arrive, never the call
    /// return. See `PaneSearchRevealTests`.
    static let searchRevealRetryDelay: TimeInterval = 0.25

    /// The animation the reveal scrolls with; see `paneColumnRevealAnimation`, which governs both
    /// presentations (an offscreen window on a machine throttling CoreAnimation never finishes the
    /// ease, so the scroll would never land).
    @Environment(\.paneColumnRevealAnimation) private var revealAnimation

    /// Reveals the current hit in the Tree presentation: open its ancestors, select it, bring it
    /// into view. Per hit, on arrival: opening every hit's ancestors while the query is typed would
    /// blow up a large tree. Folders an earlier hit opened stay open, as if clicked.
    ///
    /// The selection goes through the pane's binding, the host's `applySelectionWrite`, so the
    /// one-pane-selected rule runs the same code a click does and the sibling's clear is deferred.
    private func revealInTree(_ proxy: ScrollViewProxy, selecting: Bool) {
        guard let hit = search.hit(at: searchHitIndex) else { return }
        expanded = PaneTreeSearch.expansion(expanded, revealing: hit)
        if selecting, selection != [hit.path] { selection = [hit.path] }
        scrollTreeRow(hit.path, proxy)
    }

    /// Brings `path`'s row to the middle of the Tree's viewport, for both the search walk and the
    /// host's row reveal. Both hops are deferred: a reveal runs while SwiftUI is still applying the
    /// update that adds the row, so an immediate scroll would resolve against a list without it.
    /// See `searchRevealRetryDelay` for the second.
    private func scrollTreeRow(_ path: String, _ proxy: ScrollViewProxy) {
        let animation = revealAnimation
        func attempt() {
            withAnimation(animation) { proxy.scrollTo(path, anchor: .center) }
        }
        DispatchQueue.main.async { attempt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchRevealRetryDelay) { attempt() }
    }

    // MARK: - Revealing a row the host selected

    /// The row a host's reveal may scroll to, or `nil`: only while that row (or rows,
    /// `PaneRowReveal.selection`) is the pane's whole selection, so the reveal never fights the
    /// user. A request outlives the moment it was made, since a collapsed pane answers it when it
    /// next appears; once the user selects something else it would only drag them back.
    ///
    /// Static so `PaneRowRevealTests` can pin the rule without a mounted pane; `PaneColumnsView`
    /// asks the same one.
    static func revealsRow(_ reveal: PaneRowReveal?, selection: Set<String>) -> String? {
        guard let reveal, selection == reveal.selection else { return nil }
        return reveal.path
    }

    /// The Tree's answer to a row reveal: scroll the row to the middle of the list. No expansion:
    /// the host asks only for a row in the pane's root folder, and `scrollTo` an id the list
    /// doesn't hold does nothing. Answered once: `onRowRevealed` lets the host retire it.
    private func revealRowInTree(_ reveal: PaneRowReveal?, _ proxy: ScrollViewProxy) {
        guard let reveal, let path = Self.revealsRow(reveal, selection: selection) else { return }
        scrollTreeRow(path, proxy)
        onRowRevealed?(reveal)
    }

    /// Carries a parked column stack over when the pane flips to Tree: opens the folders the
    /// columns were in and brings the deepest into view. The presentations keep "where you are" in
    /// different state (`browsePath` and the expansion set), and the stack isn't consumed, so
    /// flipping back restores the same columns.
    ///
    /// Expanding is idempotent and scrolling isn't, so only the scroll is gated on the stack having
    /// changed: this fires on every appearance of the Tree branch, and would otherwise yank a tree
    /// the user has scrolled since. A live search hit outranks it (`revealInTree`).
    private func carryColumnsIntoTree(_ proxy: ScrollViewProxy) {
        // Mirrors `carryTreeIntoColumns`'s guard: during a load the deep rows may not exist yet,
        // so both scroll attempts can be dropped, and latching `carriedStack` would make that
        // permanent. Refused here, and re-asked on the load's falling edge.
        guard !isLoading else { return }
        let carry = Self.carryOver(expanded, stack: browsePath, treeRoot: currentPath, tree: tree.nodes)
        guard let deepest = carry.deepest else { return }
        // Only when it changes: assigning an equal set to `@State` still re-renders the whole list.
        if carry.expanded != expanded { expanded = carry.expanded }
        guard carriedStack != browsePath else { return }
        carriedStack = browsePath
        let animation = revealAnimation
        func attempt() {
            withAnimation(animation) { proxy.scrollTo(deepest, anchor: .center) }
        }
        // Deferred twice, as in `scrollTreeRow`: the update that opened the ancestors is still
        // being applied, so the list doesn't hold the deepest row yet.
        DispatchQueue.main.async { attempt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchRevealRetryDelay) { attempt() }
    }

    /// The carry-over's decision, without a view: which folders the Tree must open to show where
    /// the columns were parked, and which row to bring into view. `deepest` is nil for a resting
    /// stack, and the caller then leaves the scroll alone.
    ///
    /// The tree's root is dropped, having no row to open. Existing expansions are kept: folders the
    /// user opened are theirs to close. Each folder is named by its row's id, found by names down
    /// `tree`, because ids and composed paths part below a folder symlink (`TreeShape`); a component
    /// the tree lacks keeps its composed path.
    ///
    /// Static and non-private so `PaneColumnCarryOverTests` can pin it. `nonisolated` because it is
    /// pure, and a main-actor closure traps when a test calls it off the main actor.
    nonisolated static func carryOver(_ expanded: Set<String>, stack: PaneBrowsePath, treeRoot: String,
                                      tree: [FileNode]) -> (expanded: Set<String>, deepest: String?) {
        // A resting stack yields an empty trail (`columnDirectories` answers the root alone, and
        // `dropFirst` takes it), so one guard covers "nothing parked" and "nothing to open".
        let composed = stack.columnDirectories(treeRoot: treeRoot).dropFirst()
        guard !composed.isEmpty else { return (expanded, nil) }
        let rows = TreeShape.folders(along: stack.components, in: tree).map(\.id)
        let trail = composed.enumerated().map { depth, path in depth < rows.count ? rows[depth] : path }
        return (expanded.union(trail), trail.last)
    }

    /// Reveals the current hit in the Columns presentation: open the column stack down to the hit's
    /// parent, then select the hit in it.
    ///
    /// Through `onColumnNavigate`, not the binding: the seam link mirrors a drill into the other
    /// pane, which only the host can reach. A caller with no sibling pane writes its own binding.
    /// Drilling re-roots and rescans nothing (`PaneBrowsePath`), so difference badges stay valid.
    private func revealInColumns(selecting: Bool) {
        guard let hit = search.hit(at: searchHitIndex) else { return }
        let target = hit.browsePath
        if browsePath != target { (onColumnNavigate ?? { browsePath = $0 })(target) }
        if selecting, selection != [hit.path] { selection = [hit.path] }
    }

    /// The expansion set, dropped to paths under `root`, so a re-rooted pane stops remembering
    /// folders no row can match.
    ///
    /// Pruned when the root changes, not on every republish: republishes are constant, and asking
    /// "is this still a folder" walks the whole tree on the main thread, while a prefix test is one
    /// comparison per path. A folder deleted under the current root stays remembered, so one
    /// recreated comes back open.
    ///
    /// Static and non-private so `PaneOutlineExpansionTests` can pin it.
    static func expansionPruned(_ expanded: Set<String>, toRoot root: String) -> Set<String> {
        let normalized = PaneBrowsePath.normalized(root)
        guard !normalized.isEmpty else { return expanded }
        return expanded.filter { $0 == normalized || $0.hasPrefix(normalized + "/") }
    }

    /// One row's search decoration, in the Tree presentation. `isExpanded` is the outline's own
    /// answer, so a folder's “N matches” disappears the moment the reveal opens it.
    private func searchContext(for row: PaneRow) -> PaneSearchRowContext {
        let isExpanded = expanded.contains(row.node.id)
        let phrase = row.node.isDirectory ? typeFilter?.phrase(forFolder: row.node.id) : nil
        guard search.isActive else { return .typeFilter(phrase, isExpanded: isExpanded) }
        var context = PaneSearchRowContext(results: search, path: row.node.id, isExpanded: isExpanded)
        context.typeFilterPhrase = phrase
        return context
    }

    /// Where the Tree says the pane is, as a column stack: the flip's return trip, or nil when the
    /// Tree offers no single place. An expansion can have many branches open, so the selection is
    /// the only unambiguous place, and only a single row; two would be a guess.
    ///
    /// A selected file resolves to its folder, as `pruned` keeps leading directory components, and
    /// the same walk drops paths the tree no longer has. An empty stack is a real answer (a
    /// top-level row means the root); only "no single selection under this root" is nil.
    ///
    /// The id is tried first, then the names down the tree: below a folder symlink a row's id is
    /// where the link leads (`TreeShape`), not a path under the root. A folder can appear twice, and
    /// an id under the root names the real route, as `FileSyncManager.paneRelativePath` rules.
    ///
    /// Static and non-private so `PaneTreeCarryBackTests` can pin it, as `rowIsIgnored` is.
    nonisolated static func carryBack(selection: Set<String>, treeRoot: String,
                                      index: PaneChildrenIndex) -> PaneBrowsePath? {
        guard selection.count == 1, let path = selection.first else { return nil }
        let root = PaneBrowsePath.normalized(treeRoot)
        let stack: PaneBrowsePath
        // `PathBoundary`, so a row the walk lists under its real spelling — iCloud Drive's
        // `Documents`, which is `~/Documents` — still reads as inside the root that links it in.
        if let relative = PathBoundary.relativize(path, under: root) {
            guard !relative.isEmpty else { return nil }
            stack = PaneBrowsePath(relativePath: relative)
        } else if let names = TreeShape.names(downTo: path, in: (index.children(atPath: root) ?? []).map(\.node)) {
            stack = PaneBrowsePath(components: names)
        } else {
            return nil
        }
        return stack.pruned(against: index, treeRoot: root)
    }

    /// Whether a pane row gets the ignored treatment (struck-through, secondary). Both
    /// presentations route through it, so they can't drift.
    ///
    /// Comparison-only: `ignoredPaths` means "exclude from the Left↔Right diff", and the rail,
    /// which has no "Ignore in comparison" item, would show an exclusion it can't undo. So the rail
    /// renders every row plain; the stored ignores are untouched and Compare still honors them.
    static func rowIsIgnored(_ node: FileNode, currentPath: String, delegate: FileActionDelegate, isSingleSource: Bool) -> Bool {
        guard !isSingleSource else { return false }
        return delegate.isNodeIgnored(node, currentPath: currentPath)
    }

    private func isPathIgnored(_ node: FileNode) -> Bool {
        Self.rowIsIgnored(node, currentPath: currentPath, delegate: delegate, isSingleSource: isSingleSource)
    }
    
    /// The placeholder to show when the tree has no rows (see `PaneEmptyState.classify`).
    var emptyState: PaneEmptyState {
        PaneEmptyState.classify(
            treeIsEmpty: tree.isEmpty,
            isLoading: isLoading,
            providerIsEnabled: providerIsEnabled,
            rootIsValid: rootPathIsValid,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries,
            typeFilterEmptied: typeFilterEmptied
        )
    }

    /// The pane's one "reading its folder" indicator (see `PaneBusyIndicator`).
    var busyIndicator: PaneBusyIndicator {
        PaneBusyIndicator.resolve(isLoading: isLoading, treeIsEmpty: tree.isEmpty)
    }

    // No surface style here: the pane's shape is decided by its container (`paneCardIfNeeded` /
    // `panesRegionFrame`), and its material by the glass level. This view only paints the tint.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// List-density setting, read once here and passed to every row: a per-row @AppStorage would
    /// register a defaults observer per visible row.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var density: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .comfortable
    }
    /// Read once for the whole pane, like the density, rather than five `scaledFont` reads per row.
    /// Changing the text size still invalidates this view (dynamic properties bypass `==`, as the
    /// `@AppStorage` hue does), so the setting stays live.
    @Environment(\.appFontScale) private var appFontScale
    private var rowFonts: PaneRowFonts { PaneRowFonts(scale: appFontScale) }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    public var body: some View {
        ZStack {
            presentation
                // The pane's single subscription for the whole list; see `downloads`. Scoped by
                // `downloadChannel` (which pane instance) and `paneToken` (which surface, so the
                // other pane's request for a path both show is ignored).
                .onReceive(downloadChannel.publisher(for: .cloudDownloadRequested)) { note in
                    if let request = CloudDownloadRequest.accepted(from: note, paneToken: paneToken) {
                        downloads.begin(request, announcingOn: downloadChannel)
                    }
                }
                // A republish refreshes every other fact on a row, so the cloud-only memo is
                // cleared too, once per publish (`PaneTree` compares by stamp). Scoped to this
                // pane's root, since the memo is process-wide and serves the other pane's rows too;
                // see `badgeMemoRoot`.
                .onChange(of: tree) { _, _ in CloudOnlyBadgeCache.clear(underRoot: badgeMemoRoot) }
                // A re-root prunes expansions under the old root (`expansionPruned`); keyed on the
                // root, not the tree, so republishes cost nothing. The carry latches reset too, or a
                // place with the same components under the new root would read as already carried.
                // On the always-mounted wrapper, since a re-root can happen in either branch.
                .onChange(of: currentPath) { _, root in
                    expanded = Self.expansionPruned(expanded, toRoot: root)
                    carriedTreePlace = nil
                    carriedStack = PaneBrowsePath()
                }

            switch emptyState {
            case .none:
                EmptyView()
            case .loading:
                // Nothing in the centre: the corner chip below is the one busy indicator. This case
                // keeps "Folder is empty" off a pane still being read. See `PaneBusyIndicator`.
                EmptyView()
            case .providerDisabled:
                settingsProblemPlaceholder(
                    icon: "externaldrive.badge.xmark",
                    title: "Provider is disabled",
                    detail: "Enable it in Settings to browse its files."
                )
            case .invalidRoot:
                settingsProblemPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: "Folder not found",
                    detail: "The configured folder is missing or not a directory.",
                    path: rootPath
                )
            case .emptyFolder(let hasOnlyHiddenEntries):
                EmptyStateView(
                    icon: "folder",
                    title: "Folder is empty",
                    caption: hasOnlyHiddenEntries
                        ? "It only contains hidden items — use the Hidden toggle to show them."
                        : nil,
                    layout: .compact
                )
                // Hug the content so clicks around the placeholder still reach the pane
                // list underneath (the empty-area context menu).
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            case .filteredOut(let filter):
                // Its own state, never "Folder is empty": the folder has files, and an empty pane
                // must not look like a missing folder.
                VStack(spacing: 10) {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: PaneEmptyState.filteredOutTitle(
                            filter, folder: typeFilterFolderName ?? (currentPath as NSString).lastPathComponent),
                        caption: filter.isEmpty ? "Tick a type to see its files." : nil,
                        layout: .compact
                    )
                    if let onClearTypeFilter {
                        Button(filter.isEmpty ? "Show All" : "Clear Filter", action: onClearTypeFilter)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            if case .chip(let backed) = busyIndicator {
                PaneBusyChip(backed: backed)
            }
        }
    }

    /// Placeholder for states the user fixes in Settings (missing root, disabled provider):
    /// warning icon, explanation, optionally the offending path, and an Open Settings button.
    @ViewBuilder
    private func settingsProblemPlaceholder(icon: String, title: String, detail: String, path: String? = nil) -> some View {
        EmptyStateView(
            icon: icon,
            tint: SemanticColor.warning,
            title: title,
            message: detail,
            path: path,
            secondary: onOpenSettings.map { .init("Open Settings", handler: $0) },
            layout: .compact
        )
        // Hug the content so clicks around the placeholder still reach the pane list
        // underneath (the empty-area context menu).
        .frame(maxWidth: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Tree or columns. Columns needs a children index to resolve each column's rows, so a caller
    /// that asks for it without supplying one falls back rather than rendering an empty pane.
    @ViewBuilder
    private var presentation: some View {
        if viewMode == .columns, let childrenIndex {
            PaneColumnsView(
                tree: tree, otherTree: otherTree, childrenIndex: childrenIndex, treeRoot: currentPath,
                browsePath: $browsePath,
                onNavigate: onColumnNavigate ?? { browsePath = $0 },
                selection: $selection, otherSelection: otherSelection,
                isLeft: isLeft, delegate: delegate, diffIndex: diffIndex, otherPaneName: otherPaneName,
                isSingleSource: isSingleSource, density: density, isActivePane: isActivePane,
                isLoading: isLoading,
                placement: placement, onBarEdgeFlip: onBarEdgeFlip,
                onQuickLook: { presentQuickLook($0) },
                onNeedChildren: onNeedChildren ?? { _, _ in },
                graftsInFlight: graftsInFlight,
                sortOption: sortOption,
                onBackgroundDeselect: onBackgroundDeselect ?? { _ in },
                awaitingDownloads: downloads.requests,
                fonts: rowFonts,
                search: search,
                typeFilter: typeFilter,
                searchRevealTarget: search.hit(at: searchHitIndex)?.path,
                rowReveal: rowReveal,
                onRowRevealed: onRowRevealed,
                downloadChannel: downloadChannel,
                selectionResolver: selectionResolver
            )
            // The reveal, Columns side, on the Tree branch's signal, so switching mode mid-search
            // keeps your place.
            .onChange(of: searchRevealNonce) { _, _ in revealInColumns(selecting: true) }
            // On arrival a search hit wins; with none, open where the Tree was standing
            // (`carryTreeIntoColumns`). The Tree branch mirrors this.
            .onAppear {
                revealInColumns(selecting: false)
                if search.hit(at: searchHitIndex) == nil { carryTreeIntoColumns(index: childrenIndex) }
            }
            // And on the load's falling edge, since an arrival mid-load was refused. As in
            // `ColumnStackPruning`: the deep tree publishes before the flag clears, so waiting on
            // the tree alone would never re-fire. Same precedence as above.
            .onChange(of: isLoading) { _, loading in
                guard !loading, search.hit(at: searchHitIndex) == nil else { return }
                carryTreeIntoColumns(index: childrenIndex)
            }
            .contentSurface(hue: glassHue, tint: surfaceTint)
            .quickLookPreview($quickLookItem)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportFrameKey.self, value: geo.frame(in: .global))
                }
            )
            .onPreferenceChange(ViewportFrameKey.self) { frame in
                placement?.viewportHeight = frame.height
                placement?.viewportGlobalMinY = frame.minY
                flipEdgeIfScrolledAcross()
            }
            // No `PaneRowBottomsKey` handler, unlike the tree: each column's `ColumnListProbe`
            // writes the placement and re-resolves the edge itself.
        } else {
            paneList
                // The tree's preference replaces the row table wholesale, while the columns' probes
                // write only their own rows, so leaving the tree clears it: a stale tree row would
                // read as on screen to the columns' first resolves.
                .onDisappear { placement?.rowBottoms = [:] }
        }
    }

    /// The pane's List plus its list-level chrome: the empty-area context menu and the pane's own
    /// Quick Look presenter.
    @ViewBuilder
    private var paneList: some View {
        ScrollViewReader { proxy in
            paneListBody
                // The reveal, Tree side. Fires only on the host's nonce (a new query or ↩), so a
                // background republish walks the user nowhere; see `searchRevealNonce`.
                .onChange(of: searchRevealNonce) { _, _ in revealInTree(proxy, selecting: true) }
                // And on arrival, so switching Tree↔Columns mid-search lands on the current hit.
                // `selecting: false`: this also fires on every tab switch and pane collapse, and
                // selecting would undo a click the user made since the walk.
                //
                // With no hit, the carry-over lands where the columns were parked. A hit always
                // wins: `revealInTree` no-ops without one, and the carry stands down with one.
                .onAppear {
                    revealInTree(proxy, selecting: false)
                    if search.hit(at: searchHitIndex) == nil {
                        carryColumnsIntoTree(proxy)
                        // After the carry, so its scroll lands last: the carry shows the parked
                        // folder, this the file the host selected in it.
                        revealRowInTree(rowReveal, proxy)
                    }
                }
                // The host's row reveal: a row selected for the user (the document Edit opened, the
                // file Reveal in Browse points at) brought into view. On its own token, never on a
                // republish; see `PaneRowReveal`.
                .onChange(of: rowReveal) { _, reveal in revealRowInTree(reveal, proxy) }
                // And on the load's falling edge, since an arrival during a load is refused; the
                // Columns branch does the same, and a search hit still wins.
                .onChange(of: isLoading) { _, loading in
                    guard !loading, search.hit(at: searchHitIndex) == nil else { return }
                    carryColumnsIntoTree(proxy)
                }
        }
    }

    /// The pane's List, with its list-level chrome.
    @ViewBuilder
    private var paneListBody: some View {
        List(selection: $selection) {
            // `tree.rows`, not `tree.nodes`: the outline's `ForEach` stores the collection it is
            // given, and raw `[FileNode]` would put the recursive `FileNode.==` back in the view
            // graph.
            PaneOutlineRows(rows: tree.rows, expanded: expandedBinding,
                            onNeedChildren: onNeedChildren ?? { _, _ in },
                            isLoading: isLoading, graftsInFlight: graftsInFlight) { row in
                treeRow(for: row)
            }
        }
        .listStyle(SidebarListStyle())
        // Tints disclosure chevrons with the app accent rather than the OS one. The row highlight
        // ignores tint (macOS paints selectedContentBackgroundColor), so the styler below turns it
        // off and each row draws its own accent via `.listRowBackground`.
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        // Clicking below the last row deselects. Depth is `nil`: Tree mode (and the single-source
        // rail, always Tree) has no column stack to truncate, so this only clears.
        .background(PaneBackgroundDeselect {
            Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") tree empty area")
            onBackgroundDeselect?(nil)
        })
        // Drop the sidebar list's own vibrant background so the pane picks up the selected
        // content surface, matching the bottom workspace.
        .scrollContentBackground(.hidden)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        // The viewport's global frame: height plus top edge in window coordinates. Rows report in
        // global space too, since a named space can't be resolved inside a List row (each is its
        // own AppKit-hosted subtree); the placement math subtracts the two.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ViewportFrameKey.self, value: geo.frame(in: .global))
            }
        )
        // These preferences fire every frame while scrolling, but only mutate the shared placement
        // and ask the host to re-render on a real edge flip, so scrolling doesn't re-render the List.
        .onPreferenceChange(ViewportFrameKey.self) { frame in
            placement?.viewportHeight = frame.height
            placement?.viewportGlobalMinY = frame.minY
            flipEdgeIfScrolledAcross()
        }
        .onPreferenceChange(PaneRowBottomsKey.self) { bottoms in
            placement?.rowBottoms = bottoms
            flipEdgeIfScrolledAcross()
        }
        // No .onChange(of: selection) committer: a selection change re-renders the host, whose
        // body is the one place the edge (and its hysteresis anchor) commits. A second committer
        // here would race it and flip-flop.
        .onDeleteCommand {
            // Pruned like the context menu (`FileContextMenu.resolvedSelection`), so a folder
            // selected with something inside it doesn't make the confirmation name and count
            // children its parent's trash already covers.
            let selectedNodes = tree.selectedNodes(at: selection)
            if !selectedNodes.isEmpty {
                delegate.handleDelete(selectedNodes)
            }
        }
        .contextMenu { emptyAreaContextMenu }
        .quickLookPreview($quickLookItem)
    }

    /// One tree row: content and its context menu. Single-click selection is left to the List;
    /// drilling into a folder is via the Compare button or context menu.
    private func treeRow(for row: PaneRow) -> some View {
        let node = row.node
        return FileRowView(
            node: row.info,
            isIgnored: isPathIgnored(node),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density,
            fonts: rowFonts,
            // Asked per visible row per render, hence `RiskyNameBadgeCache`. Reads `row.info`,
            // never `row.node`, so a folder's subtree stays out of reach of a per-row call.
            riskyReason: delegate.riskyNameReason(forName: row.info.name, isDirectory: row.info.isDirectory),
            // What Edit would refuse: path math and the row's size, so no memo. Also `row.info`.
            editorRefusal: delegate.editorRefusal(forPath: row.info.id, isDirectory: row.info.isDirectory,
                                                  size: row.info.fileSize ?? 0),
            isArmedForCompare: delegate.armedComparePath == row.info.id,
            awaitingDownloadID: downloads.request(forPath: node.id)?.requestID,
            searchContext: searchContext(for: row),
            isLeftPane: isLeft,
            otherPaneName: otherPaneName,
            accent: glassHue.accentColor
        )
        .tag(node.id)
        .contextMenu {
            FileContextMenu(
                row: row,
                selection: selection,
                tree: tree,
                otherTree: otherTree,
                otherSelection: otherSelection,
                isLeft: isLeft,
                currentPath: currentPath,
                delegate: delegate,
                otherPaneName: otherPaneName,
                isSingleSource: isSingleSource,
                onQuickLook: { presentQuickLook($0) },
                selectionResolver: selectionResolver,
                downloadChannel: downloadChannel
            )
        }
        // Each visible row reports its bottom edge, so a clicked row's position is known as it
        // becomes selected and placement resolves synchronously. The reports mutate the probe, not
        // @State, so scrolling costs no re-render.
        .background(rowPositionProbe(for: node))
        // Our own selection highlight in the app's hue (`PaneListSelectionStyler` disables the
        // system's gray one).
        .listRowBackground(rowSelectionBackground(for: node))
    }

    /// The accent-tinted background for a selected row, keyed on the selection binding so window
    /// focus doesn't matter. The inactive pane's wash is weaker (`PaneSelectionWash`), so with both
    /// panes selected you can tell which one the action bar acts on.
    @ViewBuilder
    private func rowSelectionBackground(for node: FileNode) -> some View {
        if selection.contains(node.id) {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(glassHue.accentColor.opacity(PaneSelectionWash.opacity(isActivePane: isActivePane)))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    /// Reports a row's bottom edge in global space, keyed by its id. Global because a named space
    /// can't be resolved inside a List row; the placement math subtracts the viewport's global
    /// origin. Withheld when no host asked for placement.
    @ViewBuilder
    private func rowPositionProbe(for node: FileNode) -> some View {
        if placement != nil {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PaneRowBottomsKey.self,
                    value: [node.id: proxy.frame(in: .global).maxY]
                )
            }
        }
    }

    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        SharedFileMenuItems.refresh(delegate: delegate)
        Divider()
        SharedFileMenuItems.newFolder(at: currentPath, delegate: delegate)
        SharedFileMenuItems.tabActions(at: currentPath, delegate: delegate)
        SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
            delegate.handlePasteToPath(currentPath)
        }
        Divider()
        SharedFileMenuItems.getInfo(for: currentPath, delegate: delegate)
        Divider()
        SharedFileMenuItems.sortBy(sortOption) { delegate.handleSort($0) }
    }
}

/// Menu items shared by the pane's empty-area menu and the row menu (`FileContextMenu`), so their
/// labels, icons and enabled states can't drift. Row-only items stay in `FileContextMenu`. Each
/// item takes its target path explicitly.
enum SharedFileMenuItems {
    /// Sort By with the current order ticked: the pane bar's picker in a submenu, drawn by both
    /// presentations' background menus, so the three places that sort agree.
    @MainActor
    static func sortBy(_ current: SortOption,
                       onSort: @escaping @MainActor (SortOption) -> Void) -> some View {
        Menu("Sort By") {
            Picker("Sort By", selection: Binding(get: { current }, set: { onSort($0) })) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    /// Copy Path: the absolute path as plain text, as the tab strip, Info sidebar and Differences
    /// rows copy it.
    static func copyPath(_ path: String) -> some View {
        Button(action: { copyPath(path, to: .general) }) {
            Label("Copy Path", systemImage: "doc.on.clipboard")
        }
    }

    /// The write itself, on a pasteboard the caller names — a test hands it a private one.
    static func copyPath(_ path: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    static func refresh(delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleRefresh() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    /// "Open in Edit": the hand-off to Edit, where a file's contents are worked on. Offered only for
    /// a file the editor opens (text, or a read-only PDF), through `EditableText.opensInEdit`, the
    /// gate every other entry point asks, so the editor never refuses what the menu offered.
    @ViewBuilder
    static func openInEditor(_ path: String, delegate: FileActionDelegate) -> some View {
        if EditableText.opensInEdit(path: path) {
            Button(action: { delegate.handleOpenInEditor(path) }) {
                // "Open in Edit", like the reverse "Reveal in Browse": each names a workspace by
                // its bar segment's word.
                Label("Open in Edit", systemImage: "square.and.pencil")
            }
        }
    }

    @MainActor
    static func newFolder(at path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleCreateFolder(at: path) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        .lockedDuringRun()
    }

    static func getInfo(for path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleGetInfo(for: path) }) {
            Label("Get Info", systemImage: "info.circle")
        }
    }

    /// New Tab and Close Tab for a pane's background menu: the right-click route that needs no
    /// folder under the pointer and no strip (see `handleNewTab(at:)`). Beside New Folder, grouping
    /// the pane-container actions. `@MainActor` because `canOpenInNewTab` and `canCloseTab` ask the
    /// live pane.
    @MainActor @ViewBuilder
    static func tabActions(at path: String, delegate: FileActionDelegate) -> some View {
        if delegate.canOpenInNewTab {
            Button(action: { delegate.handleNewTab(at: path) }) {
                Label("New Tab", systemImage: "plus.rectangle.on.rectangle")
            }
            // Withheld at one tab: there is no tab left to close, only the window.
            if delegate.canCloseTab {
                Button(action: { delegate.handleCloseTab() }) {
                    Label("Close Tab", systemImage: "xmark.rectangle")
                }
            }
        }
    }

    /// The empty-area menu pastes into the current folder (handlePasteToPath) while the
    /// row menu pastes relative to the clicked node (handlePaste), so the action comes
    /// from the caller; the label and the clipboard gating stay shared.
    @MainActor
    static func pasteHere(clipboardHasItems: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Paste Here", systemImage: "doc.on.clipboard")
        }
        .disabled(!clipboardHasItems)
        .lockedDuringRun()
    }
}

/// The row context menu, adapting its items to whether one file, several items, or a folder was
/// right-clicked.
struct FileContextMenu: View {
    /// Boxed, since a menu is built per row and a bare folder `FileNode` would bring its subtree
    /// into every row's comparison. Unlike the row, the menu needs the real node (the delegate's
    /// handlers take `FileNode`), so it is boxed rather than flattened.
    let row: PaneRow
    private var node: FileNode { row.node }
    let selection: Set<String>
    /// Boxed like `FileTreeView.tree`: a bare `[FileNode]` would put a deep compare of the whole
    /// tree into every row's body.
    let tree: PaneTree
    let otherTree: PaneTree
    let otherSelection: Set<String>
    let isLeft: Bool
    let currentPath: String
    let delegate: FileActionDelegate
    let otherPaneName: String
    /// True on the single-source rail: with no opposite pane, the comparison-only items (Ignore,
    /// Copy/Move to and from the other pane) are dropped and "Compare only this folder" reads "Open".
    let isSingleSource: Bool
    /// Presents a Quick Look preview for the given item (parity with the Differences
    /// table's row menu); provided by the owning pane's `FileTreeView`.
    let onQuickLook: (URL) -> Void
    /// The pane's one resolver for selections; see ``PaneSelectionResolver``. Required, not
    /// defaulted: a fresh one per menu still answers correctly but walks the tree once per row.
    let selectionResolver: PaneSelectionResolver

    /// Where this menu's Download announces the request: the owning pane's
    /// `FileTreeView.downloadChannel`, which its watch listens on. Defaulted to the app's, which is
    /// correct; only a test isolating itself passes another.
    var downloadChannel: NotificationCenter = .default

    /// The home whose `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Desktop` and
    /// `~/Documents` decide Download All and Keep Downloaded. A test passes a scratch folder: the
    /// offers `lstat` and `getxattr` the row's path, and in a real File Provider domain a process
    /// without the privacy grant blocks until someone answers the consent dialog
    /// (docs/flaky-tests.md, "A consent dialog for iCloud Drive nobody answered holds a main-actor
    /// `lstat` until the job times out").
    var cloudHome: String = NSHomeDirectory()

    /// Where those reads run: off the main thread, waited for only so long (`BoundedCloudRead`). A
    /// test passes its own, so a read it holds up cannot stop another suite's menus reading.
    var cloudReads: BoundedCloudRead = .shared

    /// The three doors onto the file-pair viewer that a row offers. "Compare with…" is
    /// unconditional, since arming needs no counterpart yet, so the menu always has a Compare item;
    /// the other two are shortcuts for when a counterpart is already there.
    ///
    /// The cross-pane pair works only from a right-click: `PaneLogic.applySelectionWrite` keeps at
    /// most one pane selected, and a right-click writes no selection (as with "Copy '…' from
    /// ⟨pane⟩"). ``ComparePick`` reaches a pair by keeping the armed file outside both selections.
    /// The preconditions live in ``PaneComparePairMenu``, testable without a menu.
    @ViewBuilder
    private func compareItems(node: FileNode, selectedNodes: [FileNode]) -> some View {
        if delegate.canCompareFilePair {
            // First and always, for a file: the door that has no precondition to fail.
            if !node.isDirectory {
                Button {
                    delegate.handleArmComparePick(node)
                } label: {
                    Label("Compare with…", systemImage: "rectangle.split.2x1")
                }
            }
            if let counterpart = PaneComparePairMenu.crossPaneCounterpart(
                clicked: node, otherTree: otherTree, otherSelection: otherSelection,
                isSingleSource: isSingleSource,
                resolve: { selectionResolver.nodes(at: $0, in: $1) }) {
                Button {
                    delegate.handleCompareFilePair(node, with: counterpart,
                                                   secondIsInOtherPane: true)
                } label: {
                    Label("Compare with “\(counterpart.name)” from \(otherPaneName)",
                          systemImage: "rectangle.split.2x1")
                }
            }
            if let counterpart = PaneComparePairMenu.samePaneCounterpart(
                clicked: node, selectedNodes: selectedNodes) {
                Button {
                    delegate.handleCompareFilePair(node, with: counterpart,
                                                   secondIsInOtherPane: false)
                } label: {
                    Label("Compare These Two Files", systemImage: "rectangle.split.2x1")
                }
            }
        }
    }

    /// Whether a Favorites click should toggle: only while the folder is still in the state its
    /// label described. The label is read when the row renders, so by the click it may be stale
    /// (added from the sidebar, say), and toggling would do the opposite of what the item said.
    static func favoriteLabelStillHolds(labelSaidFavorite: Bool, isFavoriteNow: Bool) -> Bool {
        labelSaidFavorite == isFavoriteNow
    }

    /// The Download offer as an item, or nothing. The verb is `CloudDownloadRequest.request`,
    /// shared with File ▸ Download; on success the pane watches for the content so the badges clear,
    /// and on failure they stay. Scoped to this pane, so the other pane's twin row doesn't poll too,
    /// and posted on this pane's own channel (`.default` in the app).
    @ViewBuilder
    private func downloadItem(_ offer: CloudDownloadOffer?) -> some View {
        if let offer {
            Button {
                CloudDownloadRequest.request(offer, from: PaneToken(isLeft: isLeft, isSingleSource: isSingleSource),
                                             through: downloadChannel)
            } label: {
                Label(offer.title, systemImage: "icloud.and.arrow.down")
            }
            .help(Self.downloadHelp(offer))
        }
    }

    static func downloadHelp(_ offer: CloudDownloadOffer) -> String {
        switch offer {
        case .file: return "Downloads it from the cloud."
        case .all(let files, let folders) where files.isEmpty && folders.count == 1:
            return "Downloads every file in “\((folders[0] as NSString).lastPathComponent)” that is only in the cloud."
        case .all: return "Downloads every selected file, and every file in the selected folders, that is only in the cloud."
        }
    }

    /// Keep Downloaded as a ticked item, or nothing outside iCloud Drive or past
    /// `KeepDownloadedOffer.selectionCap` items. A click sets the opposite of what the tick showed,
    /// off the main thread and against the same `cloudHome`.
    @ViewBuilder
    private func keepDownloadedToggle(_ offer: KeepDownloadedOffer?, for nodes: [FileNode]) -> some View {
        if let offer {
            Toggle(isOn: Binding(get: { offer.isOn }, set: { kept in
                let pane = PaneToken(isLeft: isLeft, isSingleSource: isSingleSource)
                Task { [downloadChannel, cloudHome] in
                    await CloudDownloadRequest.setKeepDownloaded(
                        kept, for: nodes, from: pane, through: downloadChannel, home: cloudHome)
                }
            })) {
                Label("Keep Downloaded", systemImage: "pin")
            }
            .disabled(offer.isLocked)
            .help(Self.keepHelp(offer, count: nodes.count))
        }
    }

    static func keepHelp(_ offer: KeepDownloadedOffer, count: Int) -> String {
        if let folder = offer.keptBy { return "Kept downloaded by “\((folder as NSString).lastPathComponent)”." }
        if offer.isLocked { return "Kept downloaded by the folders they are in." }
        let them = count == 1 ? "it" : "them"
        return offer.isOn ? "Lets macOS remove the download again when space is needed."
                          : "Downloads \(them) now and keeps \(them) on this Mac, even when space is low."
    }

    /// What Download and Keep Downloaded offer for `nodes`.
    struct CloudOffers: Sendable {
        let download: CloudDownloadOffer?
        let keep: KeepDownloadedOffer?
    }

    /// Both offers, read off the main thread through `cloudReads`, or nil when the reads didn't
    /// answer in time and the menu leaves both out. A file asks the badge memo first (read here on
    /// the main actor); `statsFiles` lets the single-row menu `lstat` one the memo hasn't answered.
    private func cloudOffers(for nodes: [FileNode], statsFiles: Bool) -> CloudOffers? {
        let badges = nodes.reduce(into: [String: Bool]()) { known, node in
            if !node.isDirectory { known[node.id] = CloudOnlyBadgeCache.cached(node.id) }
        }
        let home = cloudHome
        return cloudReads.run {
            CloudOffers(
                download: CloudDownloadOffer.forSelection(
                    nodes,
                    isCloudOnly: { badges[$0] ?? (statsFiles ? MaterializationStatus.isCloudOnly(atPath: $0) : nil) },
                    home: home),
                keep: KeepDownloadedOffer.forSelection(nodes, state: { KeepDownloaded.state(ofPath: $0, home: home) }))
        }
    }

    static func resolvedSelection(node: FileNode, selection: Set<String>, tree: [FileNode]) -> [FileNode] {
        let effectiveSelection: Set<String>
        if selection.isEmpty {
            effectiveSelection = [node.id]
        } else if selection.contains(node.id) {
            effectiveSelection = selection
        } else {
            effectiveSelection = [node.id]
        }
        // Prune nested nodes, so Copy/Move/Delete on a folder and an item inside it never hands a
        // handler the superset. The same two steps as `PaneTree.selectedNodes(at:)`, which
        // `onDeleteCommand` and `PaneSelectionResolver` use, so they must not drift; pinned by
        // `ContextMenuSelectionTests` here and `PaneTreeSelectedNodesTests` in Sync.
        return tree.findNodes(at: effectiveSelection).pruneNestedNodes()
    }

    /// What a menu opened on `row` acts on: `resolvedSelection`'s answer, skipping the walk where
    /// the answer is in hand.
    ///
    /// A row outside the selection acts on itself, and a row cut from `tree` (same side and
    /// version) holds the node the walk would find, by `PaneRow`'s stamp. A row from another publish
    /// still walks. Where a tree holds two nodes at one path (`FileNode.isCoveredElsewhere`), this
    /// answers with the one clicked, which no verb notices, since they act by path.
    ///
    /// A row inside the selection gets the selection, resolved once for all rows by `resolver`.
    /// With nothing selected, the pane's entry there is released: it may hold a replaced tree.
    static func menuNodes(row: PaneRow, selection: Set<String>, tree: PaneTree,
                          resolver: PaneSelectionResolver) -> [FileNode] {
        if selection.contains(row.id) { return resolver.nodes(at: selection, in: tree) }
        if selection.isEmpty { resolver.release(tree.side) }
        if row.side == tree.side, row.version == tree.version { return [row.node] }
        return resolvedSelection(node: row.node, selection: selection, tree: tree.nodes)
    }

    var body: some View {
        let selectedNodes = Self.menuNodes(row: row, selection: selection, tree: tree,
                                           resolver: selectionResolver)
        let count = selectedNodes.count
        // The other pane's selection, for "Copy '…' from ⟨pane⟩" and the cross-pane Compare item,
        // resolved once for every row. The rail withholds both, so never asks.
        let otherSelectedNodes = isSingleSource
            ? [] : selectionResolver.nodes(at: otherSelection, in: otherTree)
        
        Group {
            SharedFileMenuItems.refresh(delegate: delegate)
            Divider()
            // Several PDFs: the batch tools, first after Refresh. Hidden if the selection holds
            // anything a tool can't read (a folder, another kind, a cloud-only file). The
            // single-file submenu is in the branch below.
            if count > 1, delegate.canRunPDFTools,
               case .several(let paths)? = PanePDFToolOffer.forSelection(selectedNodes, reads: cloudReads) {
                PanePDFToolsSubmenu(offer: .several(paths: paths), delegate: delegate)
                Divider()
            }
            // Several files Save as PDF can convert: the same slot, never shared with PDF Tools (a
            // PDF hides this, anything but PDFs hides that). Hidden for a folder, a kind nothing
            // converts, or a cloud-only file.
            if count > 1, delegate.canSaveAsPDF,
               case .several(let paths)? = SaveAsPDFOffer.forSelection(selectedNodes, reads: cloudReads) {
                SaveAsPDFMenuItem(offer: .several(paths: paths), delegate: delegate)
                Divider()
            }
            // Several items: Download All and Keep Downloaded over the lot, in the same slot. Memo
            // only: each opened menu rebuilds with its row, so an `lstat` per file would cost
            // rows × selection.
            if count > 1, let cloud = cloudOffers(for: selectedNodes, statsFiles: false),
               cloud.download != nil || cloud.keep != nil {
                downloadItem(cloud.download)
                keepDownloadedToggle(cloud.keep, for: selectedNodes)
                Divider()
            }
            if count == 1, let singleNode = selectedNodes.first {
                // First after the divider, ahead of Get Info and Reveal in Finder: Edit is this
                // app's own workspace, and this is the door into it every surface with rows has.
                if !singleNode.isDirectory {
                    SharedFileMenuItems.openInEditor(singleNode.id, delegate: delegate)
                }
                SharedFileMenuItems.getInfo(for: singleNode.id, delegate: delegate)
                // Same direct reveal the Differences row menu and the error alert use;
                // there is no FileActionHandler reveal to delegate to.
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: singleNode.id)]) }) {
                    Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)
                }
                // A file one-way sync copied from iCloud is changed there: the way to it.
                if let iCloudPath = OneWaySyncController.shared.iCloudFile(forDropbox: singleNode.id) {
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: iCloudPath)]) }) {
                        Label("Show in iCloud", systemImage: "icloud")
                    }
                }
                // Ahead of Quick Look: with no ＋ on screen until a second tab exists, this item is
                // how people discover tabs.
                if singleNode.isDirectory, delegate.canOpenInNewTab {
                    Button(action: { delegate.handleOpenInNewTab(singleNode) }) {
                        Label("Open in New Tab", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                Button(action: { onQuickLook(URL(fileURLWithPath: singleNode.id)) }) {
                    Label("Quick Look", systemImage: "doc.viewfinder")
                }
                // As on tabs, the Info sidebar and the Differences rows.
                SharedFileMenuItems.copyPath(singleNode.id)
                // After Copy Path, so the positions the pinned order tests read stay put.
                if delegate.canAskClaude {
                    AskClaudeMenuItems(nodes: [singleNode], delegate: delegate)
                }
                // Download a cloud-only placeholder: one file, or Download All for every cloud-only
                // file in a cloud folder. Works on iCloud and Google Drive; Dropbox and OneDrive are
                // untested. A refused request reveals the item in Finder. Uses the row's ☁ answer
                // when it has one, else an `lstat`.
                //
                // Keep Downloaded beside it, iCloud Drive only, the one provider known to honour it
                // (`KeepDownloaded`); ticked and greyed under a kept folder. Both read off the main
                // thread, and neither is offered when the reads hang.
                let cloud = cloudOffers(for: [singleNode], statsFiles: true)
                downloadItem(cloud?.download)
                keepDownloadedToggle(cloud?.keep, for: [singleNode])
                // Its own section under the open-and-inspect items, so it never shifts Rename or
                // comes between Refresh and Open in Edit. Hidden, not greyed, for a folder, a non-PDF
                // or a cloud-only file, and when its reads hang.
                if delegate.canRunPDFTools, let offer = PanePDFToolOffer.forSelection([singleNode], reads: cloudReads) {
                    Divider()
                    PanePDFToolsSubmenu(offer: offer, delegate: delegate)
                        .lockedDuringRun()
                }
                // Save as PDF, in PDF Tools' section, so Rename never moves. A PDF keeps its tools
                // and is never offered this.
                if delegate.canSaveAsPDF, let offer = SaveAsPDFOffer.forSelection([singleNode], reads: cloudReads) {
                    Divider()
                    SaveAsPDFMenuItem(offer: offer, delegate: delegate)
                        .lockedDuringRun()
                }
                Divider()
                // A file one-way sync keeps as a copy is renamed in iCloud: not offered here.
                let syncedCopy = OneWaySyncController.shared.refusal(forChanging: [singleNode.id])
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(syncedCopy != nil)
                .lockedDuringRun()
                // Offered only when this provider will reject the name. **This runs on the main
                // thread at the right-click, before the menu shows**, and again on each render of a
                // row whose menu has been opened (macOS 27). It is cheap, via `RiskyNameBadgeCache`'s
                // memo, but nothing costlier belongs here.
                if let risky = delegate.riskyName(for: singleNode) {
                    Button(action: { delegate.handleFixName(singleNode) }) {
                        // No ellipsis: it renames at once, undoably, and asks nothing more.
                        Label("Fix Name", systemImage: RiskyNameGlyph.lens)
                    }
                    .lockedDuringRun()
                    .help("\(risky.reason) Renames it to “\(risky.sanitizedName)”, undoably.")
                    // Keep, and its only way back: keeping is durable and a kept name draws no
                    // badge, so without the withdrawal here it would be a one-way door.
                    if delegate.isKeptName(singleNode.name) {
                        Button(action: { delegate.handleStopKeepingName(singleNode) }) {
                            Label("Stop Allowing This Name", systemImage: "eye")
                        }
                        .help("Report “\(singleNode.name)” again, here and in Organize.")
                    } else {
                        Button(action: { delegate.handleKeepName(singleNode) }) {
                            Label("Always Allow This Name", systemImage: "hand.raised")
                        }
                        .help("Stop flagging “\(singleNode.name)”, in this and every later session. "
                              + "The file is not changed.")
                    }
                }

                // Beside "Fix name", the same door for the other lens. A standing item, not a
                // finding: "does this file have copies?" needs a scan, so the offer is to go look.
                // Files only: a folder overlap group is a different unit, drawn differently.
                //
                // **No `.keyboardShortcut`**: this menu is built per row, so a window-level key
                // equivalent binds to whichever row's menu registered, and this one opens a
                // workspace and starts a scan. See the destination verbs below.
                if !singleNode.isDirectory, delegate.canFindDuplicates {
                    Button(action: { delegate.handleFindDuplicates(singleNode) }) {
                        Label("Find Duplicates of This", systemImage: "doc.on.doc")
                    }
                    .help("Open Duplicates and reveal the group holding “\(singleNode.name)”.")
                }

                if singleNode.isDirectory {
                    // Point Organize at this folder, the folder counterpart to "Find duplicates of
                    // this". It must land somewhere before any scan has found anything.
                    if delegate.canOrganizeFolder {
                        // Glyphed like the rest: AppKit indents every title to clear the widest
                        // image, so an item without one reads as a hanging line.
                        Button {
                            delegate.handleOrganizeFolder(singleNode)
                        } label: {
                            Label("Organize This Folder…", systemImage: "folder.badge.gearshape")
                        }
                        // The shape question, from the row you are on. Same gate as its sibling:
                        // one workspace behind both.
                        Button {
                            delegate.handleCheckFolderShape(singleNode)
                        } label: {
                            Label("Check This Folder’s Shape", systemImage: "rectangle.3.group")
                        }
                        Divider()
                    }
                    // The sidebar's Favorites list, from the folder under the pointer, which the
                    // sidebar and the pane header's jump menu can't reach.
                    if delegate.canFavoriteFolder {
                        // The label is decided when the menu is built, so the click does what it
                        // said: an "Add" already done adds nothing rather than removing the folder.
                        let isFavorite = delegate.isFolderFavorite(singleNode)
                        Button {
                            guard Self.favoriteLabelStillHolds(labelSaidFavorite: isFavorite,
                                                               isFavoriteNow: delegate.isFolderFavorite(singleNode))
                            else { return }
                            delegate.handleToggleFolderFavorite(singleNode)
                        } label: {
                            // A star and a struck-through star, the pair Finder and Safari use.
                            Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                  systemImage: isFavorite ? "star.slash" : "star")
                        }
                        Divider()
                    }
                    SharedFileMenuItems.newFolder(at: singleNode.id, delegate: delegate)
                    Divider()
                    Button(action: { delegate.handleFocus(singleNode) }) {
                        // On the comparison panes this isolates one folder mapping; on the rail,
                        // with nothing to compare, it just drills in, so it reads "Open".
                        if isSingleSource {
                            Label("Open", systemImage: "arrow.forward")
                        } else {
                            Label("Compare Only This Folder", systemImage: "scope")
                        }
                    }
                }
            }

            if count > 1, delegate.canAskClaude {
                AskClaudeMenuItems(nodes: selectedNodes, delegate: delegate)
                Divider()
            }

            // Comparison-only: Ignore and Copy/Move to the other provider are meaningless on the
            // single-source rail (there is no opposite pane), so they're dropped there.
            if !isSingleSource {
                let allIgnored = selectedNodes.allSatisfy { n in
                    delegate.isNodeIgnored(n, currentPath: currentPath)
                }
                Button(action: { delegate.handleIgnore(selectedNodes) }) {
                    Label(allIgnored ? "Include in Comparison" : "Ignore in Comparison", systemImage: allIgnored ? "eye" : "eye.slash")
                }
            }

            // Separator before the clipboard section, skipped when nothing sits between it and the
            // Refresh divider (single-source multi-select), so two dividers never stack.
            if count == 1 || !isSingleSource {
                Divider()
            }

            // One section for every verb that puts the selection somewhere: Cut, Copy, the two
            // transfers, then Paste Here, the one item acting on the clicked row's folder instead.
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: true) }) {
                Label(count > 1 ? "Cut \(count) Items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: false) }) {
                Label(count > 1 ? "Copy \(count) Items" : "Copy", systemImage: "doc.on.doc")
            }

            // The absolute destination verbs, in the comparison transfers' slot. Single-source only:
            // on the two-pane menu they would sit beside "Move to <other pane>", two items opening
            // with the same words, one asking a question and one not.
            //
            // **No `.keyboardShortcut` on either.** This menu is built per row, and `selectedNodes`
            // falls back to this row's node, so a window-level key equivalent would bind to
            // whichever row's menu registered and file a file the user never pointed at. It is also
            // consulted before the first responder. Such a shortcut belongs on the window's command
            // set, keyed off the live selection.
            if isSingleSource {
                // Copy before Move, as in the two-pane items below and File ▸ Copy to… / Move to….
                Button(action: { delegate.handleChooseDestination(selectedNodes, isMove: false) }) {
                    Label(count > 1 ? "Copy \(count) Items to…" : "Copy to…", systemImage: TransferGlyph.copy)
                }
                .lockedDuringRun()

                Button(action: { delegate.handleChooseDestination(selectedNodes, isMove: true) }) {
                    Label(count > 1 ? "Move \(count) Items to…" : "Move to…", systemImage: TransferGlyph.move(toRight: true))
                }
                .lockedDuringRun()
            }

            if !isSingleSource {
                // The toolbar's `TransferGlyph`s: Copy is non-directional (the label names the
                // pane), and Move points its arrow at the target pane, as the toolbar does.
                Button(action: { delegate.handleCopy(selectedNodes) }) {
                    Label(count > 1 ? "Copy \(count) Items to \(otherPaneName)" : "Copy to \(otherPaneName)", systemImage: TransferGlyph.copy)
                }
                .lockedDuringRun()

                Button(action: { delegate.handleMove(selectedNodes) }) {
                    Label(count > 1 ? "Move \(count) Items to \(otherPaneName)" : "Move to \(otherPaneName)", systemImage: TransferGlyph.move(toRight: isLeft))
                }
                .lockedDuringRun()
            }

            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePaste(node)
            }

            // Pruned like every entry point, so the count isn't wrong ("Copy 3 items" for a folder
            // and two of its children, which transfer as 1). Empty on the rail and with no selection.
            if !otherSelectedNodes.isEmpty {
                Button(action: { delegate.handlePasteExplicit(node, nodes: otherSelectedNodes) }) {
                    if otherSelectedNodes.count > 1 {
                        Label("Copy \(otherSelectedNodes.count) Items from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                    } else if let first = otherSelectedNodes.first {
                        Label("Copy “\(first.name)” from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                    }
                }
                .lockedDuringRun()
            }

            compareItems(node: node, selectedNodes: selectedNodes)

            Divider()
            
            // Ellipsis, as File ▸ Move Selection to Trash… has it: it asks first whenever "Confirm
            // before deleting" is on (the default), and this menu cannot see that setting.
            let syncedCopies = OneWaySyncController.shared.refusal(forChanging: selectedNodes.map(\.id))
            Button(role: .destructive, action: { delegate.handleDelete(selectedNodes) }) {
                Label(count > 1 ? "Move \(count) Items to Trash…" : "Move to Trash…", systemImage: "trash")
            }
            .disabled(syncedCopies != nil)
            .lockedDuringRun()
        }
    }
}

/// Renders a single row representing a file or directory node with its associated system icon,
/// plus a trailing sync-status badge when the node (or, for folders, anything beneath it) differs.
struct FileRowView: View {
    /// The scalars this row renders. Flat because a folder `FileNode` carries its subtree, which
    /// the derived `FileNode.==` would recurse through on every comparison; `FileRowInfo` makes the
    /// subtree unreachable from the view.
    let node: FileRowInfo
    let isIgnored: Bool
    /// Diff status of the node itself, or nil when it is in sync.
    let diffStatus: FileDifference.DifferenceType?
    /// Number of differences beneath this node (directories only; 0 elsewhere).
    let containedDiffCount: Int
    /// Whether this file is a cloud-only placeholder. Detected lazily per row by one `lstat`, so a
    /// big tree pays nothing until a row appears, and memoized by `CloudOnlyBadgeCache`.
    @State private var isCloudOnly = false
    /// Whether the name is drawn cut short, which is exactly when the tooltip carries the full name
    /// (`rowHelp`). Measured by `reportsTruncation` only while the pointer is over the row, when a
    /// tooltip can show, and written only when it differs.
    @State private var nameIsTruncated = false
    /// Whether the pointer is over the row, the only time the name is measured: a probe on every
    /// row would lay out a hidden copy of every name and re-render each one that starts cut.
    @State private var isPointerOver = false
    /// List-density setting, from `FileTreeView` (which reads the @AppStorage once per pane).
    /// Compact tightens the row and drops the size and date detail.
    let density: ListDensity
    /// The pane's resolved fonts, handed down rather than derived per row; see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled
    /// Why this provider will give this name trouble, or nil when it won't or the user kept it.
    /// Resolved by the pane, memoized by (provider, name) in `RiskyNameBadgeCache`. Defaulted for
    /// callers with no provider context, such as test doubles.
    var riskyReason: String? = nil
    /// Why the Editor workspace would refuse this row, or nil when it would open it or the
    /// workspace isn't Edit. Resolved per visible row from `FileActionDelegate.editorRefusal`,
    /// like `riskyReason`. A refused row dims to the search-dim opacity with the reason as its
    /// tooltip; a folder never has one, so the way out of the listing stays bright.
    var editorRefusal: String? = nil
    /// Whether this row is the file armed for comparison; see ``ComparePick``.
    var isArmedForCompare: Bool = false
    /// The id of the download request the pane is watching for this row, or nil. Part of the badge
    /// task's `.task(id:)` key, so the badge re-resolves when the watch starts and when it ends, by
    /// which point the pane has put the answer in the memo.
    ///
    /// A UUID, not a `Bool`, because downloading the same file again mid-watch moves straight to a
    /// new request, which a `Bool` wouldn't see as a change. The row doesn't poll or subscribe: the
    /// pane owns the one watch and subscription (`PaneDownloadWatch`) and hands this down.
    var awaitingDownloadID: UUID? = nil
    /// What a running search says about this row: the matched run, whether it recedes, the count
    /// of matches inside a closed folder, and its side. `.none` is a pane with no query.
    var searchContext: PaneSearchRowContext = .none
    /// Which pane this row is in, so a one-sided hit can name its side. Read only while a search
    /// annotates.
    var isLeftPane: Bool = true
    /// The opposite pane's display name, for the side annotation's tooltip.
    var otherPaneName: String = ""
    /// The pane's accent, for the “N matches” count. Passed, not inherited; see
    /// `PaneSearchAnnotation.accent`.
    var accent: Color = LiquidGlassHue.stored().accentColor
    /// Whether the row carries its trailing detail: a folder's modification date, a file's size.
    /// False in Columns (`ColumnRowView`), true in Tree, as in Finder's column and list views. In a
    /// column the name needs the width more, and a folder's own mtime only says when it was last
    /// tidied.
    ///
    /// The detail stays in the Info inspector and in Tree, so the pane still publishes `fileSize`
    /// and `modificationDate`, and Sort ▸ Size and Date still work in Columns. A property of the
    /// presentation, not the workspace: each surface stores its own mode (`browseDefaultsKey`,
    /// `defaultsKey(isLeft:)`, `railDefaultsKey`). Defaulted true.
    var showsSecondaryText: Bool = true

    /// The badge task's `.task(id:)` key: this row's path, and the pane's watch for it. Named and
    /// non-private so a test can pin `==`, and with it when `.task(id:)` re-runs.
    struct BadgeID: Equatable {
        let path: String
        let awaitingDownloadID: UUID?
    }

    /// One row's badge answer, or nil when this resolution was superseded and must not be written.
    /// Named and non-private, like `BadgeID`, so a test can pin `.task(id:)`'s cancellation.
    ///
    /// **The `Task.isCancelled` check after the stat is the point.** The stat suspends in a
    /// detached `lstat`, which doesn't inherit cancellation, so a task cancelled when the watch
    /// ends still resumes with the pre-download `true`, racing the replacement's `false`. Without
    /// the check the badge can claim cloud-only for a landed file; it needs an `lstat` slower than
    /// the poll's ~1 s (a wedged provider).
    ///
    /// `stat` is injectable because a test can't land a cancellation inside a real `lstat`.
    /// Optional, not defaulted, so the shipped stat has one definition, `CloudOnlyBadgeCache`'s;
    /// `nil` means use it.
    @MainActor
    static func resolveBadge(
        path: String,
        isDirectory: Bool,
        stat: (@MainActor (String) async -> Bool?)? = nil
    ) async -> Bool? {
        // No suspension on this branch, so there is no window to be superseded in.
        guard !isDirectory else { return false }
        let answer: Bool
        if let stat {
            answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path, stat: stat)
        } else {
            answer = await CloudOnlyBadgeCache.isCloudOnly(atPath: path)
        }
        guard !Task.isCancelled else { return nil }
        return answer
    }

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// Shared formatter (sizes use `FileSizeFormat.byteCount`): one per row body would churn as
    /// rows scroll.
    @MainActor private static let modifiedFormatter = ZoneRefreshedFormatter.localized(date: .medium,
                                                                                        time: .none)

    /// Size for files, date modified for folders (a folder's fileSize is the entry's, not its
    /// contents'); nil when the scan didn't fill the metadata or the surface withholds it
    /// (`showsSecondaryText`).
    private var secondaryText: String? {
        Self.secondaryText(for: node, showsSecondaryText: showsSecondaryText)
    }

    /// The rule behind `secondaryText`, as a pure function of the row's scalars. Static and
    /// non-private so a test can pin which string a row asks for, since no test can drive the
    /// row's body; `ColumnRowDateTests` pins the rendering by its pixels.
    @MainActor
    static func secondaryText(for node: FileRowInfo, showsSecondaryText: Bool) -> String? {
        guard showsSecondaryText else { return nil }
        if node.isDirectory {
            guard let date = node.modificationDate else { return nil }
            return modifiedFormatter.string(from: date)
        }
        guard let size = node.fileSize else { return nil }
        return FileSizeFormat.byteCount.string(fromByteCount: Int64(size))
    }

    var body: some View {
        // Spacing 0, with each drawn element bringing its own leading gap: a stack pays spacing
        // around every child, including ones that draw nothing (the `Spacer`, an empty search
        // note), which would stop a truncated name well short of the next thing painted.
        //
        // The search note keeps layout priority -1, so it yields to the name: shown whole beside a
        // name that leaves room, not at all beside one that needs it (`PaneSearchAnnotation`).
        let gap: CGFloat = density == .compact ? 8 : 10
        HStack(spacing: 0) {
            Image(nsImage: FileIconCache.icon(name: node.name, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: densityMetrics.treeIconSize, height: densityMetrics.treeIconSize)
            // Affix whitespace made visible ("Swimming " → "Swimming␣"), since such a node can have
            // a pixel-identical sibling. A search hit's matched run is bold in that same form; see
            // `PaneSearchName`.
            PaneSearchName(name: node.name, match: searchContext.match, font: fonts.name)
                .lineLimit(1)
                // Cut in the middle, as Finder does: names in a folder share long prefixes
                // ("Statement - Account - January.pdf"), and cutting the end would make rows look
                // identical. A search hit is cut away from its match instead; see `nameTruncation`.
                .truncationMode(Self.nameTruncation(match: searchContext.match, in: node.name))
                // Measured on the drawn name, before its leading gap, and only under the pointer.
                .reportsTruncation(of: PaneSearchName(name: node.name, match: searchContext.match,
                                                      font: fonts.name),
                                   while: isPointerOver) { truncated in
                    if nameIsTruncated != truncated { nameIsTruncated = truncated }
                }
                .strikethrough(isIgnored, color: .secondary)
                .foregroundStyle(isIgnored ? .secondary : .primary)
                .padding(.leading, gap)
            // Beside the name, not in the trailing cluster: the cloud and difference badges report
            // the file's relation to somewhere else, while this is about the characters to its
            // left. It also stays out of `FileRowAccessories`' reserved widths.
            if let riskyReason {
                RiskyNameBadge(reason: riskyReason, fonts: fonts)
                    .padding(.leading, gap)
            }
            // Beside the name, for `RiskyNameBadge`'s reason: it is about this row ("you armed
            // this one"). Additive, never in the cloud slot, where it would hide a cloud-only badge
            // while the pick is armed.
            if isArmedForCompare {
                ComparePickBadge(fonts: fonts, accent: accent)
                    .padding(.leading, gap)
            }
            // Zero minimum: in a zero-spaced stack a spacer that yields costs nothing at all.
            Spacer(minLength: 0)
            if densityMetrics.showsSecondaryDetail, let secondaryText {
                Text(secondaryText)
                    .font(fonts.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, gap)
            }
            // Ahead of the badge cluster: the user asked for it by typing the query. Mounted only
            // when there is something to say, with its gap inside the label, so a row with no note
            // spends nothing.
            if searchContext.hasAnnotation {
                PaneSearchAnnotation(context: searchContext, isLeft: isLeftPane,
                                     otherPaneName: otherPaneName, accent: accent, fonts: fonts,
                                     leadingGap: gap)
                    .layoutPriority(-1)
            }
            FileRowAccessories(
                isCloudOnly: isCloudOnly,
                reservesCloudSlot: !node.isDirectory,
                diffStatus: diffStatus,
                containedDiffCount: containedDiffCount,
                fonts: fonts,
                leadingGap: gap
            )
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
        // A find, not a filter: a row off every path to an answer recedes but stays readable, so
        // the tree's shape (the answer to "where is this?") never changes. A row Edit can't open
        // recedes the same way.
        .opacity(searchContext.isDimmed || editorRefusal != nil ? PaneSearchDim.opacity : 1)
        // A possibly empty string, not a branch: an `if let` around a modifier would give the row
        // two identities and drop `isCloudOnly` whenever the refusal flipped.
        .help(Self.rowHelp(name: node.name, nameIsTruncated: nameIsTruncated,
                           editorRefusal: editorRefusal))
        .contentShape(Rectangle())
        // Arms the name's measurement. After the shape, so the whole row counts, as for the tooltip.
        .onHover { isPointerOver = $0 }
        // One keyed task for the badge, consulting the memo first, so the syscall happens once per
        // path per republish, not each time `List` realizes the row while scrolling.
        //
        // The pane's watch is part of the key (`BadgeID`): the pane forgets the memo, polls,
        // records the answer and drops its latch, which re-keys this task to re-read it. The
        // assignment is conditional because a superseded resolution must not land; see
        // `resolveBadge`.
        .task(id: BadgeID(path: node.id, awaitingDownloadID: awaitingDownloadID)) {
            if let answer = await FileRowView.resolveBadge(path: node.id,
                                                          isDirectory: node.isDirectory) {
                isCloudOnly = answer
            }
        }
    }

    static func badgeHelp(for type: FileDifference.DifferenceType) -> String {
        switch type {
        case .missingOnRight: return "Missing on right"
        case .missingOnLeft: return "Missing on left"
        case .differentDates: return "Different dates or sizes"
        case .nameConflict: return "Name conflict (names differ only invisibly)"
        }
    }
}

extension FileRowView {
    /// Where a name too long for its row is cut: in the middle, except on a search hit. The middle
    /// cut keeps the start and end that tell long-prefixed siblings apart, but would cut away a
    /// match in the middle, so a hit is cut at the end away from its match: the tail when the match
    /// is in the first half, the head when in the second. A mid-name match in a narrow column can
    /// still be lost.
    ///
    /// The match indexes the name as `PaneSearchName` draws it (`NameDisplay.visibleName`, which
    /// swaps affix whitespace one character for one), so it is measured against that form.
    static func nameTruncation(match: Range<Int>?, in name: String) -> Text.TruncationMode {
        guard let match else { return .middle }
        let length = NameDisplay.visibleName(name).count
        guard length > 0 else { return .middle }
        return match.lowerBound + match.upperBound < length ? .tail : .head
    }

    /// The row's tooltip: the full name when the row cut it short, then Edit's refusal when there
    /// is one, or "" (no tooltip). Only a cut name gets the name, as in Finder: tooltips show after
    /// 300 ms (`ToolTipDelay`), so one on every row would pop up wherever the pointer rests. The
    /// name is shown as the row draws it (`NameDisplay.visibleName`).
    static func rowHelp(name: String, nameIsTruncated: Bool, editorRefusal: String?) -> String {
        let fullName = nameIsTruncated ? NameDisplay.visibleName(name) : nil
        return [fullName, editorRefusal].compactMap { $0 }.joined(separator: "\n")
    }
}

extension View {
    /// Reports, while `measuring` is true, whether this one-line label is drawn narrower than
    /// `ideal` (the same content at natural width), i.e. truncated. SwiftUI has no such query, so it
    /// compares the drawn width with a hidden `fixedSize` copy's.
    ///
    /// Nothing is measured while `measuring` is false, so a list can arm it for the row under the
    /// pointer only. Armed, it reports at once and then each flip, keeping no state, so a re-arm
    /// reports afresh. Not a `ViewThatFits`, which would change how the row shares its width.
    func reportsTruncation(of ideal: some View, while measuring: Bool,
                           _ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(TruncationProbe(ideal: ideal, measuring: measuring, onChange: onChange))
    }
}

/// The measurement behind `reportsTruncation`.
struct TruncationProbe<Ideal: View>: ViewModifier {
    let ideal: Ideal
    let measuring: Bool
    let onChange: (Bool) -> Void

    /// The space the hidden copy reads the drawn width from.
    private static var drawn: NamedCoordinateSpace { .named("TruncationProbe.drawn") }

    /// Cut, by more than layout's sub-point rounding. A truncation drops at least a glyph for an
    /// ellipsis, so half a point cannot hide one. Nothing measured yet is not cut.
    static func isTruncated(shown: CGFloat, ideal: CGFloat) -> Bool {
        shown > 0 && ideal > shown + 0.5
    }

    func body(content: Content) -> some View {
        content.background(alignment: .leading) {
            if measuring {
                // `Color.clear` takes the drawn size; the hidden copy takes its natural width and
                // reads the drawn one off the clear's space. One observer whose value is the
                // answer, so only a flip calls back.
                Color.clear
                    .overlay(alignment: .leading) {
                        ideal
                            .lineLimit(1)
                            .fixedSize()
                            .hidden()
                            .onGeometryChange(for: Bool.self, of: { proxy in
                                Self.isTruncated(shown: proxy.bounds(of: Self.drawn)?.width ?? 0,
                                                 ideal: proxy.size.width)
                            }, action: onChange)
                    }
                    .coordinateSpace(Self.drawn)
            }
        }
    }
}


/// A file row's trailing badges: the cloud-only marker, then either the difference badge or the
/// contained-differences count.
///
/// Split out of `FileRowView` so both cloud states can be rendered and measured. The cloud badge
/// arrives after the row, from a per-row `lstat` off the main actor, so without a reserved slot the
/// trailing cluster would jump sideways as each answer lands.
///
/// The slot is reserved like `PaneActionBar`'s summary zone: a hidden copy of the glyph sets the
/// width, so it stays right at every text size. Only file rows reserve it; `FileRowView` never
/// marks a folder cloud-only.
struct FileRowAccessories: View {
    let isCloudOnly: Bool
    /// Whether to hold the cloud badge's width even when it isn't showing.
    let reservesCloudSlot: Bool
    let diffStatus: FileDifference.DifferenceType?
    let containedDiffCount: Int
    /// The pane's resolved fonts — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled
    /// The gap each drawn accessory keeps from what precedes it. `FileRowView` uses zero spacing, so
    /// an absent accessory takes its gap with it. Zero by default, for a caller in a spaced stack.
    var leadingGap: CGFloat = 0

    /// The bare glyph, which is also what sizes the reserved slot. A generic cloud (not the iCloud
    /// glyph) since it applies to any File Provider (Dropbox, Drive, OneDrive, Box).
    private var cloudGlyph: some View {
        Image(systemName: "cloud")
            .font(fonts.cloudBadge)
            .foregroundStyle(.secondary)
    }

    /// The glyph as the user meets it — with its tooltip and VoiceOver label.
    private var cloudBadge: some View {
        cloudGlyph
            .help("Cloud-only — content isn’t downloaded to this Mac")
            .accessibilityLabel("Cloud-only, not downloaded")
    }

    var body: some View {
        if reservesCloudSlot {
            // `.hidden()` keeps the space and drops the twin from hit-testing and the
            // accessibility tree, so the reservation is invisible to VoiceOver and to the cursor.
            cloudGlyph
                .hidden()
                .overlay { if isCloudOnly { cloudBadge } }
                .padding(.leading, leadingGap)
        } else if isCloudOnly {
            // No slot held, but the badge still shows when it applies. Folding this into the branch
            // above would drop the badge for every caller that opts out of the reservation.
            cloudBadge
                .padding(.leading, leadingGap)
        }
        if let diffStatus {
            // Shape encodes direction/kind so status is readable without color
            // (colors match the Differences table in the Differences pane).
            Image(systemName: DifferenceGlyph.symbol(for: diffStatus, filled: false))
                .font(fonts.differenceBadge)
                .foregroundStyle(DifferenceGlyph.color(for: diffStatus))
                .help(FileRowView.badgeHelp(for: diffStatus))
                .accessibilityLabel(FileRowView.badgeHelp(for: diffStatus))
                .padding(.leading, leadingGap)
        } else if containedDiffCount > 0 {
            Text("\(containedDiffCount)")
                .font(fonts.countPill)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
                .help("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
                .accessibilityLabel("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
                .padding(.leading, leadingGap)
        }
    }
}
