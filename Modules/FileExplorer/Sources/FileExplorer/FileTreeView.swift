import AppKit
import Combine
import Design
import Events
import QuickLook
import SwiftUI
import Sync

extension Notification.Name {
    /// Posted after a cloud-only "Download" request is accepted, carrying a `CloudDownloadRequest`
    /// in `object`. The PANE listens (one subscription, not one per row) and watches the content
    /// materialize on the requester's behalf: the row context menu, the preview column's Download
    /// button and the row showing that file are separate views with no shared state, and without
    /// this the badge lingered until the row was recycled.
    ///
    /// The payload names the posting pane (`CloudDownloadRequest.paneToken`): both panes default to
    /// the same provider, so the same absolute path can be on screen twice, and a bare-path post
    /// was latched by BOTH panes — twin rows polling, and a duplicate `forget` bumping the memo
    /// generation app-wide.
    ///
    /// There is deliberately no matching "poll concluded" notification. The pane runs the watch
    /// itself, so it needs no one to tell it the watch is over; the two views that care read the
    /// pane's watches they are already handed (`FileRowView.awaitingDownloadID`,
    /// `ColumnPreviewColumn.isAwaitingDownload`).
    static let cloudDownloadRequested = Notification.Name("SyncCloudCloudDownloadRequested")
}

/// Recursive tree view for one comparison pane (left or right); context menu and actions go through the delegate.
///
/// **`Equatable`, and wrapped in `.equatable()` by its host.** Not decoration — it is the boundary
/// that stops the pane re-rendering on things that have nothing to do with it.
///
/// `ContentView` is a single `View` observing a manager with ~56 `@Published` properties, so a
/// write to *any* of them — a scan progress tick, a banner, a bulk-copy counter — re-evaluates its
/// whole body, which builds both panes. That is survivable only if SwiftUI can then say "this pane
/// is unchanged" and stop. It could not: the host hands each pane a freshly-built
/// `PaneActionDelegate` (an existential holding closures), four freshly-built callback closures and
/// two freshly-built `Binding`s, and SwiftUI's memberwise comparison treats every one of those as
/// different. So every pane compared unequal on every render, and with the delegate threaded into
/// each row's context menu, so did every visible row.
///
/// The `==` below therefore compares what the pane RENDERS FROM — all of it, by value — and asks
/// the delegate to vouch for itself (`FileActionDelegate.isEquivalent(to:)`). The callbacks are
/// compared only for presence, because presence is the only thing about them the pane's layout
/// depends on: each one dispatches through the host's reference types and property wrappers, so a
/// closure captured on an earlier render reads exactly the same live state as a fresh one would.
/// Anything added to this view later must be added to `==` as well — a stored property left out of
/// it is a value the pane will stop noticing.
public struct FileTreeView: View, Equatable {
    /// File tree for this pane. Boxed rather than a bare `[FileNode]` so SwiftUI compares one
    /// `Int` instead of recursing through ~40,000 nodes on the main thread — see `PaneTree`.
    public let tree: PaneTree
    /// File tree for the opposite pane (e.g. for “copy to other pane”). Boxed for the same
    /// reason as `tree`, and it matters at least as much: the opposite pane's tree is never
    /// rendered here, so every node of it was being compared purely to reach a menu lookup.
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

    /// Diff status per absolute node path for this pane (precomputed by the caller), and the index
    /// this pane actually renders from — `init` forces it to `.empty` on the single-source rail,
    /// so this property is the one gate for every difference accessory the pane draws (the row's
    /// own status badge and a folder's contained-difference pill), in both presentations. Reading
    /// it back gives what will be drawn, not what was handed in.
    public let diffIndex: DiffStatusIndex

    /// Display name of the opposite pane's provider, used as the copy/move target in menu labels.
    public let otherPaneName: String

    /// Whether the provider's ROOT path existed as a directory at Settings' last validity
    /// check (validity of a focused subfolder is not tracked — see `PaneEmptyState.classify`).
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

    /// True when this pane is the Tidy single-source rail rather than one of the two comparison
    /// panes. The rail has no "other pane" to compare or copy across, so its row menu drops the
    /// comparison-only items (Ignore, Copy/Move to the other provider) and renames "Compare only
    /// this folder" to a plain "Open".
    public let isSingleSource: Bool

    /// Shared placement scratch space, owned by the host (one per pane). This view fills its live
    /// geometry (`rowBottoms`/`viewportHeight`) from row/viewport probes; the host reads the edge
    /// straight from its own `body`. `nil` on the Tidy rail, which has no action bar.
    private let placement: PaneBarPlacement?
    /// Called when a SCROLL crossing flips the resolved edge — the host re-renders (with animation)
    /// so the bar cross-fades. Selection-driven placement needs no callback: changing the selection
    /// already re-renders the host, which recomputes the edge synchronously and instantly.
    private let onBarEdgeFlip: (() -> Void)?

    /// How this pane presents its tree. Defaults to `.tree` so every existing caller — most
    /// importantly the Tidy single-source rail — is unaffected until it opts in; only the two
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
    /// A plain click on the pane's empty space, carrying the depth of the column it landed in
    /// (`nil` in Tree mode, and past the last column, where nothing is truncated).
    ///
    /// The host owns it for the same reason it owns `onColumnNavigate`: the selection this dismisses
    /// may live in the *other* pane — the one-pane-selected invariant means it usually does — and
    /// only the host can reach across the seam. `nil` for callers with no sibling pane, which leaves
    /// the pane exactly as it behaves today.
    public let onBackgroundDeselect: ((Int?) -> Void)?

    /// This pane's search results — what matched, what has matches beneath it, and which side each
    /// hit is on. `.empty` (the default) is a pane with no query, which renders exactly as it did
    /// before search existed.
    ///
    /// Stamped, not walked: a broad query fills three maps with thousands of entries and this is
    /// compared by `==` on every render. See `PaneSearchResults`.
    public let search: PaneSearchResults
    /// Which hit ↩/⇧↩ have walked to. Revealing it is this view's job — expanding its ancestors and
    /// scrolling to it in Tree, opening the columns down to it in Columns — and it happens on
    /// ARRIVAL, per hit, never for every hit of the query at once.
    public let searchHitIndex: Int

    /// Whether this pane is the one the action bar is currently acting on. Drives the strength of
    /// the row-selection wash, restoring the emphasized/unemphasized distinction AppKit used to
    /// draw for free: `PaneListSelectionStyler` turns the system highlight off (to get the accent
    /// instead of OS gray) and the window is pinned to `controlActiveState == .active` (to stop the
    /// glass graying out), so between them nothing was left to say WHICH pane holds the selection.
    /// Defaults true — the Tidy rail is the only pane on screen.
    public let isActivePane: Bool

    /// Item previewed via the row context menu's Quick Look. Presented by this pane's own
    /// `.quickLookPreview` — the host's presenter (spacebar) is not reachable through the
    /// delegate, and the shared QL panel only ever shows one preview at a time anyway.
    @State private var quickLookItem: URL?
    /// The downloads THIS pane is watching, keyed by path — see `PaneDownloadWatch`. While a path is
    /// in there, the row showing that file re-resolves its badge and the preview column showing it
    /// says "Downloading…"; both read it from here rather than watching anything themselves.
    ///
    /// A collection, not a single latch. One latch meant a second download in this pane — a
    /// different file, queued back to back from the row menu — cancelled the first one's watch, and
    /// that file then landed unobserved behind a stale cloud-only badge.
    ///
    /// One subscription here rather than one per row. `FileRowView` used to observe
    /// `.cloudDownloadRequested` itself, which meant a live Combine subscription per VISIBLE ROW,
    /// churned as the list recycled them, to deliver a notice that at most one row per session
    /// ever acts on.
    ///
    /// The result reaches the row through the MEMO rather than back down the tree: the watch
    /// `record`s the landed answer and then drops its entry here, and dropping it re-keys that
    /// row's badge task (see `FileRowView.BadgeID`), which re-reads the memo — one dictionary hit,
    /// no second syscall.
    @StateObject private var downloads = PaneDownloadWatch()

    /// The folders whose children are showing, in the Tree presentation. Pane state, not model
    /// state: it survives a republish (identity is the node path) and is reset by nothing, exactly
    /// as `OutlineGroup`'s private equivalent behaved.
    ///
    /// It is here rather than inside `PaneOutlineRows` because the SEARCH writes it — revealing a
    /// hit is `expanded.formUnion(hit.ancestorPaths)` and nothing else. That is the whole reason the
    /// outline stopped being an `OutlineGroup`; see `PaneOutlineRows`.
    @State private var expanded: Set<String> = []

    /// The channel `.cloudDownloadRequested` travels on for THIS pane — `.default` in the app, and
    /// a private `NotificationCenter` in a test that mounts a pane.
    ///
    /// `NotificationCenter` is process-wide and a mounted SwiftUI view is a live subscriber, so
    /// `paneToken` alone cannot separate two panes on the same surface: it names a *surface*, and
    /// under `swift test` several suites mount one at once. Every mounted left pane in the process
    /// therefore accepted every `.left` post in the process — one suite's post ran another suite's
    /// watch, and its `CloudOnlyBadgeCache.forget` moved the value that suite was asserting on.
    /// Picking a token no other suite posts was the previous answer and it has run out: all three
    /// surfaces are already used as the *ignored* token somewhere, and a foreign pane on the same
    /// surface can accept the very post a routing test uses as its POSITIVE control — which passes
    /// the test with the pane under test completely deaf.
    ///
    /// A channel is the identity a token is not. Production has exactly one pane per surface and
    /// passes nothing, so `.default` is what the app runs on and the routing decision it makes is
    /// bit-identical; a test gives each mounted pane its own channel and no two can reach each
    /// other, whatever tokens they use. See `docs/flaky-tests.md` mechanism 9.
    public let downloadChannel: NotificationCenter

    /// This pane's identity for download-notification scoping — the receiving side of
    /// `CloudDownloadRequest.paneToken`. Computed from facts already compared by `==`, so it adds
    /// nothing the pane could fail to notice.
    ///
    /// Not `private`: `FileTreeViewPaneNameTests` pins it, because a receiver hardcoded to one
    /// token is a mutation nothing else in the suite can see — the routing helper it feeds is
    /// tested, but only against tokens a test made up.
    var paneToken: PaneToken { PaneToken(isLeft: isLeft, isSingleSource: isSingleSource) }

    /// The root a republish's badge-memo clear is scoped to: the folder this pane is actually
    /// showing, which is where the memo's keys for it come from.
    ///
    /// `currentPath`, NOT `rootPath`. The two diverge whenever a pane is focused on a subfolder —
    /// `rootPath` stays the provider root while `currentPath` follows the focus — and the tree that
    /// just republished holds only what is under `currentPath`. Scoping to `rootPath` would clear
    /// entries no row of this pane can currently serve, which is the over-broad clear this scoping
    /// exists to stop. Named and non-private so `FileTreeViewPaneNameTests` can pin the choice.
    var badgeMemoRoot: String { currentPath }

    public init(tree: PaneTree, otherTree: PaneTree, isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, otherSelection: Set<String>, isLeft: Bool, delegate: FileActionDelegate, diffIndex: DiffStatusIndex = .empty, otherPaneName: String? = nil, rootPathIsValid: Bool = true, providerIsEnabled: Bool = true, hasOnlyHiddenEntries: Bool = false, rootPath: String? = nil, onOpenSettings: (() -> Void)? = nil, isSingleSource: Bool = false, placement: PaneBarPlacement? = nil, onBarEdgeFlip: (() -> Void)? = nil, search: PaneSearchResults? = nil, searchHitIndex: Int = 0, isActivePane: Bool = true, viewMode: PaneViewMode = .tree, childrenIndex: PaneChildrenIndex? = nil, browsePath: Binding<PaneBrowsePath> = .constant(PaneBrowsePath()), onColumnNavigate: ((PaneBrowsePath) -> Void)? = nil, onBackgroundDeselect: ((Int?) -> Void)? = nil, downloadChannel: NotificationCenter = .default) {
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self.otherSelection = otherSelection
        self.isLeft = isLeft
        self.delegate = delegate
        // A difference is a statement about the OTHER pane, and the rail has no other pane: Tidy
        // scans one folder. The badges it drew came from whatever Compare last scanned, so Tidy
        // showed counts against a provider it isn't looking at — and left them standing after the
        // scan that produced them was long stale. Emptying the index here, rather than at each of
        // the three render sites, means neither presentation can reintroduce the badge.
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
        // Defaulted to this pane's own empty results rather than to a shared constant, so the side
        // is right even for a caller that never searches — `PaneSearchResults.==` reads the side
        // first, and a right pane holding a `.left` empty would compare unequal to itself forever.
        self.search = search ?? .empty(side: tree.side)
        self.searchHitIndex = searchHitIndex
        self.isActivePane = isActivePane
        self.viewMode = viewMode
        self.childrenIndex = childrenIndex
        self._browsePath = browsePath
        self.onColumnNavigate = onColumnNavigate
        self.onBackgroundDeselect = onBackgroundDeselect
        self.downloadChannel = downloadChannel
    }

    /// See the note on the type. Every stored property is accounted for here: the value ones by
    /// `==`, the two `Binding`s by their wrapped values (so a selection or a column stack changing
    /// still re-renders), the shared placement box by identity, the delegate by its own
    /// equivalence, and the four host callbacks by presence alone.
    ///
    /// `nonisolated` because `Equatable` is, and `assumeIsolated` because this view — and the
    /// `@MainActor` delegate it compares — are not. The assumption is the one SwiftUI already
    /// guarantees: view-tree diffing, which is the only thing that calls this, runs on the main
    /// actor. Same reasoning (and same call) as the pane's AppKit bounds observers.
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
            && lhs.searchHitIndex == rhs.searchHitIndex
            && lhs.isActivePane == rhs.isActivePane
            && lhs.viewMode == rhs.viewMode
            && lhs.childrenIndex == rhs.childrenIndex
            && lhs.browsePath == rhs.browsePath
            && lhs.placement === rhs.placement
            && lhs.downloadChannel === rhs.downloadChannel
            && (lhs.onOpenSettings == nil) == (rhs.onOpenSettings == nil)
            && (lhs.onBarEdgeFlip == nil) == (rhs.onBarEdgeFlip == nil)
            && (lhs.onColumnNavigate == nil) == (rhs.onColumnNavigate == nil)
            && (lhs.onBackgroundDeselect == nil) == (rhs.onBackgroundDeselect == nil)
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

    /// After a scroll/layout update to the row positions, re-resolve the edge (the resolve commits
    /// its own anchor); if it flipped, ask the host to re-render (animated cross-fade). Selection
    /// changes are NOT handled here — they re-render the host anyway, which recomputes the edge
    /// synchronously and instantly.
    ///
    /// Two rules keep this from feeding back into the layout pass that called it:
    ///
    /// 1. It re-resolves against the bar's selection of record (`reresolveAtTop`), never against
    ///    this pane's raw List selection. The two disagree for a runloop turn after every click,
    ///    and resolving from each in turn made the pane and its host commit opposite edges to the
    ///    same anchor, forever — see `PaneBarPlacement.barSelection`.
    /// 2. The flip itself is handed to the next runloop turn. This runs inside a preference
    ///    callback, i.e. inside AppKit's layout pass; writing host state synchronously from here
    ///    re-enters that pass, and a pass that keeps re-entering is the crash AppKit raises when a
    ///    window needs more constraint passes than it has views. A turn's delay is invisible under
    ///    the flip's own 0.22s cross-fade.
    private func flipEdgeIfScrolledAcross() {
        guard let placement, let onBarEdgeFlip else { return }
        let wasAtTop = placement.atTop
        guard placement.reresolveAtTop() != wasAtTop else { return }
        DispatchQueue.main.async { onBarEdgeFlip() }
    }

    // MARK: - Revealing a search hit

    /// How long after a reveal the second scroll attempt is made.
    ///
    /// The same number, and the same reason, as `PaneColumnsView.revealRetryDelay`: a `scrollTo`
    /// issued before the layout it is resolving against has settled is not merely early, it is
    /// SILENTLY DROPPED and never retried. Here the unsettled thing is the expansion this reveal
    /// just wrote — the hit's row does not exist in the list until its ancestors have opened, and a
    /// scroll to a row that is not there yet scrolls nowhere. A second attempt costs nothing when
    /// the first one worked, because a `scrollTo` onto a row already in view moves zero points.
    ///
    /// Which is also why NEITHER attempt may be treated as proof: a test must observe the row's
    /// ARRIVAL, never the call returning. See `PaneSearchRevealTests`.
    static let searchRevealRetryDelay: TimeInterval = 0.25

    /// The animation the reveal scrolls with — see `paneColumnRevealAnimation`, which governs both
    /// presentations' reveals for the same reason (an offscreen, never-key window on a machine that
    /// throttles CoreAnimation never advances the ease, so the scroll never lands).
    @Environment(\.paneColumnRevealAnimation) private var revealAnimation

    /// Reveals the current hit in the Tree presentation: open its ancestors, select it, bring it
    /// into view.
    ///
    /// **Per hit, on arrival.** Only this hit's ancestors are opened, and only when the walk reaches
    /// it — expanding every ancestor of every hit as the query is typed would detonate a large tree
    /// for a question that is still being asked. Folders opened by an earlier hit stay open, exactly
    /// as they would had the user clicked their way down.
    ///
    /// The selection write goes through the pane's own binding, which is the host's
    /// `applySelectionWrite` — so the one-pane-selected invariant is enforced by the same code a
    /// click goes through, and the sibling pane's clear is deferred rather than written synchronously
    /// from here.
    private func revealInTree(_ proxy: ScrollViewProxy) {
        guard let hit = search.hit(at: searchHitIndex) else { return }
        expanded = PaneTreeSearch.expansion(expanded, revealing: hit)
        if selection != [hit.path] { selection = [hit.path] }
        let animation = revealAnimation
        func attempt() {
            withAnimation(animation) { proxy.scrollTo(hit.path, anchor: .center) }
        }
        // Both hops are deferred: this runs while SwiftUI is still applying the update that opened
        // the ancestors, so the list the scroll resolves against is the one WITHOUT the hit's row
        // in it.
        DispatchQueue.main.async { attempt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchRevealRetryDelay) { attempt() }
    }

    /// Reveals the current hit in the Columns presentation: open the column stack down to the hit's
    /// parent, then select the hit in it.
    ///
    /// **Through `onColumnNavigate`, not the binding.** Drilling is a two-pane decision — the seam
    /// link mirrors it into the other pane — and only the host can see the other side. Writing
    /// `browsePath` straight would move this pane and silently break the link for every move search
    /// makes. The fallback matches `presentation`'s: a caller with no sibling pane writes its own
    /// binding.
    ///
    /// Drilling re-roots nothing and rescans nothing (see `PaneBrowsePath`), so every difference
    /// badge stays valid across a search walk — the same property a click already relies on.
    private func revealInColumns() {
        guard let hit = search.hit(at: searchHitIndex) else { return }
        let target = hit.browsePath
        if browsePath != target { (onColumnNavigate ?? { browsePath = $0 })(target) }
        if selection != [hit.path] { selection = [hit.path] }
    }

    /// One row's search decoration, in the Tree presentation. `isExpanded` is the outline's own
    /// answer, so a folder's “N matches” disappears the moment the reveal opens it.
    private func searchContext(for row: PaneRow) -> PaneSearchRowContext {
        guard search.isActive else { return .none }
        return PaneSearchRowContext(results: search, path: row.node.id,
                                    isExpanded: expanded.contains(row.node.id))
    }

    /// Whether a pane row should carry the ignored treatment (struck-through name, secondary
    /// foreground). The single choke point for that decision — both the tree presentation and
    /// `PaneColumnsView` route through it, so the two can't drift.
    ///
    /// Comparison-only, deliberately. `ignoredPaths` means "exclude from the Left↔Right diff": it
    /// is set and cleared through the row menu's "Ignore in comparison", which `FileContextMenu`
    /// already drops on the single-source rail because there is nothing over there to compare
    /// against. Striking the rows anyway told a Tidy user their folders were excluded from
    /// something Tidy does not do, and offered no way to undo it — so the rail renders every row
    /// plain. The stored ignores are untouched; Compare still honors them.
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
            hasOnlyHiddenEntries: hasOnlyHiddenEntries
        )
    }

    // No surface style here: the pane's shape is decided by its container (`paneCardIfNeeded` /
    // `panesRegionFrame`), and its material by the glass level. This view only paints the tint.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// List-density setting (H7), read ONCE here and injected into every row — a per-row
    /// @AppStorage would register a defaults observer per visible row.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var density: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .comfortable
    }
    /// Read ONCE here for the whole pane, for the same reason the density default is: what was a
    /// per-row `@Environment` read (five of them, via `scaledFont`) is now one. Changing the text
    /// size still invalidates this view — dynamic properties drive invalidation independently of
    /// `==`, exactly as the `@AppStorage` hue above already does — so the setting stays live.
    @Environment(\.appFontScale) private var appFontScale
    private var rowFonts: PaneRowFonts { PaneRowFonts(scale: appFontScale) }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    public var body: some View {
        ZStack {
            presentation
                // The pane's single subscription for the whole list — see `downloads`.
                // Scoped twice over: by `downloadChannel` (which pane INSTANCE — one channel in the
                // app, one per mounted pane in a test) and by `paneToken` (which surface, so the
                // other pane's request for a path both panes are showing is ignored rather than
                // latched).
                .onReceive(downloadChannel.publisher(for: .cloudDownloadRequested)) { note in
                    if let request = CloudDownloadRequest.accepted(from: note, paneToken: paneToken) {
                        downloads.begin(request)
                    }
                }
                // A republish is the moment every other fact on a row is refreshed, so it is the
                // moment the cloud-only memo stops being allowed to speak for them too. `PaneTree`
                // compares by publish stamp, so this fires once per publish rather than per render.
                // Scoped to this pane's root: the memo is process-wide, and an unscoped clear wiped
                // the answers the OTHER pane's rows were still relying on. See `badgeMemoRoot` for
                // why that root is `currentPath` rather than `rootPath`.
                .onChange(of: tree) { _, _ in CloudOnlyBadgeCache.clear(underRoot: badgeMemoRoot) }

            switch emptyState {
            case .none:
                EmptyView()
            case .loading:
                ProgressView("Scanning Directory...")
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
                    .shadow(
                        color: LiquidGlass.subtleShadow.color,
                        radius: LiquidGlass.subtleShadow.radius,
                        x: LiquidGlass.subtleShadow.x,
                        y: LiquidGlass.subtleShadow.y
                    )
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
            }

            if !tree.isEmpty && isLoading {
                // Subtle corner overlay when refreshing non-empty tree; display-only, so it
                // must never intercept clicks meant for the rows underneath it.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(20)
                    }
                }
                .allowsHitTesting(false)
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
                placement: placement, onBarEdgeFlip: onBarEdgeFlip,
                onQuickLook: { quickLookItem = $0 },
                onBackgroundDeselect: onBackgroundDeselect ?? { _ in },
                awaitingDownloads: downloads.requests,
                fonts: rowFonts,
                search: search,
                searchRevealTarget: search.hit(at: searchHitIndex)?.path,
                downloadChannel: downloadChannel
            )
            // The reveal, Columns side. Same token as the Tree branch, so the two presentations walk
            // the same hits in the same order and switching mode mid-search keeps your place.
            .onChange(of: revealToken) { _, _ in revealInColumns() }
            .onAppear { revealInColumns() }
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
            .onPreferenceChange(PaneRowBottomsKey.self) { bottoms in
                placement?.rowBottoms = bottoms
                flipEdgeIfScrolledAcross()
            }
        } else {
            paneList
        }
    }

    /// The pane's List plus its list-level chrome: the empty-area context menu and the pane's own
    /// Quick Look presenter.
    @ViewBuilder
    private var paneList: some View {
        ScrollViewReader { proxy in
            paneListBody
                // The reveal, Tree side. Keyed on the hit rather than on the query, so typing costs
                // nothing and only arriving at a hit opens anything — see `revealInTree`.
                .onChange(of: revealToken) { _, _ in revealInTree(proxy) }
                // And once on arrival, so switching Tree↔Columns mid-search lands on the hit you
                // were standing on rather than at the top of a tree you have to walk again. Costs
                // an inactive pane one guarded return per appearance: `revealInTree` finds no hit
                // and does nothing, which is every launch and every tab switch.
                .onAppear { revealInTree(proxy) }
        }
    }

    /// The token a reveal fires on: which result set, and which hit within it.
    ///
    /// Both halves are needed. The index alone misses ↩ landing on index 0 of a new result set after
    /// index 0 of the old one — which is every query that is retyped — and the generation alone
    /// misses the walk, which is the whole feature.
    private var revealToken: PaneSearchRevealToken {
        PaneSearchRevealToken(generation: search.generation, hitIndex: searchHitIndex)
    }

    /// The pane's List, with its list-level chrome.
    @ViewBuilder
    private var paneListBody: some View {
        List(selection: $selection) {
            // `tree.rows`, NOT `tree.nodes`: the outline STORES the collection it is given, so
            // handing it the raw `[FileNode]` puts the recursive `FileNode.==` straight back into
            // the view graph — which is exactly what `PaneTree` alone failed to prevent. That was
            // true of `OutlineGroup` and is equally true of the `ForEach` inside `PaneOutlineRows`.
            PaneOutlineRows(rows: tree.rows, expanded: $expanded) { row in
                treeRow(for: row)
            }
        }
        .listStyle(SidebarListStyle())
        // Tint disclosure chevrons etc. with the app accent (the OS accent otherwise). The selected
        // ROW highlight ignores this — macOS paints it from selectedContentBackgroundColor (gray on
        // a Graphite accent) — so the styler below disables that highlight and each row draws its own
        // accent background via `.listRowBackground`.
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        // Clicking below the last row deselects. Depth is `nil`: Tree mode has no column stack, so
        // there is nothing to truncate — this surface (and the Tidy rail, which is always Tree)
        // only clears.
        .background(PaneBackgroundDeselect {
            Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") tree empty area")
            onBackgroundDeselect?(nil)
        })
        // Drop the sidebar list's own vibrant background so the pane picks up the selected
        // content surface, matching the bottom workspace.
        .scrollContentBackground(.hidden)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        // The viewport's GLOBAL frame — height plus its top edge in window coordinates. Rows report
        // their positions in global space too (a named space can't be resolved from inside a List
        // row — each row is its own AppKit-hosted subtree — and silently fell back to global,
        // inflating every row by this very offset and flipping the bar a quarter-viewport early);
        // the placement math subtracts the two, so the frame of reference finally agrees.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ViewportFrameKey.self, value: geo.frame(in: .global))
            }
        )
        // The row/frame preferences fire every frame while scrolling, but they only mutate the
        // shared placement (no view invalidation) and ask the host to re-render solely on a genuine
        // edge flip — so scrolling stays free of per-frame List re-renders.
        .onPreferenceChange(ViewportFrameKey.self) { frame in
            placement?.viewportHeight = frame.height
            placement?.viewportGlobalMinY = frame.minY
            flipEdgeIfScrolledAcross()
        }
        .onPreferenceChange(PaneRowBottomsKey.self) { bottoms in
            placement?.rowBottoms = bottoms
            flipEdgeIfScrolledAcross()
        }
        // No .onChange(of: selection) committer here: the selection change re-renders the host,
        // whose body resolve is the ONE place the edge (and its hysteresis anchor) commits. A second
        // committer racing it from this side was part of the old flip-flop.
        .onDeleteCommand {
            // Pruned, exactly like the context-menu path (see `FileContextMenu.resolvedSelection`,
            // which applies the same rule): selecting a folder AND something inside it and
            // pressing ⌫ otherwise handed the superset to the handler, so the confirmation named
            // and counted children that the single trash of their parent already covers. The disk
            // outcome was always right — `deleteItems` prunes before trashing — but the dialog the
            // user answers should describe what will actually happen.
            let selectedNodes = tree.selectedNodes(at: selection)
            if !selectedNodes.isEmpty {
                delegate.handleDelete(selectedNodes)
            }
        }
        .contextMenu { emptyAreaContextMenu }
        .quickLookPreview($quickLookItem)
    }

    /// One tree row: content and its context menu. Single-click selection is left entirely to
    /// the List; drilling into a folder is via the Compare button / context menu.
    ///
    /// No `@ViewBuilder` — the single `return` below disables it anyway, so the attribute only
    /// advertised a capability this body does not use.
    private func treeRow(for row: PaneRow) -> some View {
        let node = row.node
        return FileRowView(
            node: row.info,
            isIgnored: isPathIgnored(node),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density,
            fonts: rowFonts,
            // Asked per visible row, per render pass — the one eagerly-rendered delegate answer,
            // and the reason `RiskyNameBadgeCache` exists. Reads `row.info`, never `row.node`, so
            // a folder's subtree stays out of reach of a per-row call.
            riskyReason: delegate.riskyNameReason(forName: row.info.name, isDirectory: row.info.isDirectory),
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
                onQuickLook: { quickLookItem = $0 },
                downloadChannel: downloadChannel
            )
        }
        // Every visible row reports its bottom edge so the clicked row's position is already known
        // the instant it becomes selected (placement can then resolve synchronously). Only visible
        // rows lay out, and the reports mutate the reference probe rather than any @State, so this
        // adds no re-render cost during scroll.
        .background(rowPositionProbe(for: node))
        // Our own selection highlight (the system one is disabled by PaneListSelectionStyler): an
        // accent-tinted capsule so the selected row follows the app's chosen hue, not the OS gray.
        .listRowBackground(rowSelectionBackground(for: node))
    }

    /// The accent-tinted background for a selected row; nothing for an unselected one. Keyed on the
    /// SwiftUI selection binding, so it stays correct regardless of window focus.
    ///
    /// The inactive pane's wash is deliberately weaker (`PaneSelectionWash.inactive` vs `.active`).
    /// Both panes can hold a selection at once, and with the system highlight disabled and the
    /// window pinned active, an equal-strength wash left no way to tell which pane the action bar
    /// was about to act on — two identically-highlighted selections, one Delete button.
    @ViewBuilder
    private func rowSelectionBackground(for node: FileNode) -> some View {
        if selection.contains(node.id) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(glassHue.accentColor.opacity(PaneSelectionWash.opacity(isActivePane: isActivePane)))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    /// Reports a row's bottom edge in GLOBAL space, keyed by its id, so the list always knows where
    /// every visible row sits. Global, not a named space: List rows live in their own AppKit-hosted
    /// subtrees where a named space can't be resolved (the lookup silently degraded to global
    /// anyway, while the viewport half measured locally — the mismatched frames of reference were
    /// the premature flip). The placement math subtracts the viewport's global origin.
    /// Withheld on the Tidy rail (no action bar to place).
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
        SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
            delegate.handlePasteToPath(currentPath)
        }
        Divider()
        SharedFileMenuItems.getInfo(for: currentPath, delegate: delegate)
        Divider()
        Menu("Sort By") {
            Button("Name") { delegate.handleSort(.name) }
            Button("Kind") { delegate.handleSort(.kind) }
            Button("Date Modified") { delegate.handleSort(.dateModified) }
            Button("Size") { delegate.handleSort(.size) }
            Button("Tags") { delegate.handleSort(.tags) }
        }
    }
}

/// Menu items shared verbatim between the pane's empty-area menu and the row menu
/// (FileContextMenu), so their labels, icons, and enabled states can't drift. Row-only
/// items (Reveal, Quick Look, Rename, …) stay in FileContextMenu. The two menus target
/// different paths, so each item takes its target explicitly.
enum SharedFileMenuItems {
    static func refresh(delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleRefresh() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    static func newFolder(at path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleCreateFolder(at: path) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }

    static func getInfo(for path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleGetInfo(for: path) }) {
            Label("Get Info", systemImage: "info.circle")
        }
    }

    /// The empty-area menu pastes into the current folder (handlePasteToPath) while the
    /// row menu pastes relative to the clicked node (handlePaste), so the action comes
    /// from the caller; the label and the clipboard gating stay shared.
    static func pasteHere(clipboardHasItems: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Paste here", systemImage: "doc.on.clipboard")
        }
        .disabled(!clipboardHasItems)
    }
}

/// Dynamically generated context menu for file operations bounding the selected node and the overarching selection
/// Adapts its available buttons depending on whether a single file, a batch of files, or a folder was right-clicked.
struct FileContextMenu: View {
    /// Stamped for the same reason as `FileRowView.row` — a menu is built per row, so a bare
    /// folder `FileNode` put its entire subtree into every row's comparison. Unlike the row, this
    /// view does need the real node (the delegate handlers take `FileNode`), which is why it is
    /// boxed rather than flattened.
    let row: PaneRow
    private var node: FileNode { row.node }
    let selection: Set<String>
    /// Boxed for the same reason as `FileTreeView.tree`: a menu is built per row, so a bare
    /// `[FileNode]` here put a full ~40,000-node deep compare into every row's body output.
    let tree: PaneTree
    let otherTree: PaneTree
    let otherSelection: Set<String>
    let isLeft: Bool
    let currentPath: String
    let delegate: FileActionDelegate
    let otherPaneName: String
    /// True on the Tidy single-source rail: no opposite pane exists, so the comparison-only items
    /// (Ignore, Copy/Move to the other provider, Copy from the other pane) are dropped and the
    /// folder-focus item reads as a plain "Open" rather than "Compare only this folder".
    let isSingleSource: Bool
    /// Presents a Quick Look preview for the given item (parity with the Differences
    /// table's row menu); provided by the owning pane's `FileTreeView`.
    let onQuickLook: (URL) -> Void

    /// Where this menu's Download ANNOUNCES the request, which must be the channel the pane that
    /// will watch it is listening on — the owning pane's `FileTreeView.downloadChannel`, passed
    /// down by whichever presentation built this menu.
    ///
    /// Defaulted to the app's, because that is a correct answer and not a silently broken one:
    /// only a test isolating itself from the other suites passes anything else.
    var downloadChannel: NotificationCenter = .default

    static func resolvedSelection(node: FileNode, selection: Set<String>, tree: [FileNode]) -> [FileNode] {
        let effectiveSelection: Set<String>
        if selection.isEmpty {
            effectiveSelection = [node.id]
        } else if selection.contains(node.id) {
            effectiveSelection = selection
        } else {
            effectiveSelection = [node.id]
        }
        // Prune nested nodes (a folder and its descendant never travel together), so a
        // context-menu Copy/Move/Delete on a selection spanning a folder AND an item inside it
        // can't pass the superset to a handler — matching the downstream copy/move prune.
        //
        // `onDeleteCommand` applies the SAME rule through a DIFFERENT helper
        // (`PaneTree.selectedNodes(at:)`), so the two must not drift. Each is pinned separately:
        // `ContextMenuSelectionTests` here, `PaneTreeSelectedNodesTests` in Sync.
        return tree.findNodes(at: effectiveSelection).pruneNestedNodes()
    }

    var body: some View {
        let selectedNodes = Self.resolvedSelection(node: node, selection: selection, tree: tree.nodes)
        let count = selectedNodes.count
        
        Group {
            SharedFileMenuItems.refresh(delegate: delegate)
            Divider()
            if count == 1, let singleNode = selectedNodes.first {
                SharedFileMenuItems.getInfo(for: singleNode.id, delegate: delegate)
                // Same direct reveal the Differences row menu and the error alert use;
                // there is no FileActionHandler reveal to delegate to.
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: singleNode.id)]) }) {
                    Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)
                }
                Button(action: { onQuickLook(URL(fileURLWithPath: singleNode.id)) }) {
                    Label("Quick Look", systemImage: "doc.viewfinder")
                }
                // Materialize a cloud-only placeholder. Works cleanly for iCloud (the one public,
                // non-blocking download API); for other File Provider providers it fails and we log
                // a pointer to Finder rather than pretend. Reveal in Finder (above) is the reliable
                // download path everywhere.
                if !singleNode.isDirectory, MaterializationStatus.isCloudOnly(atPath: singleNode.id) {
                    Button {
                        do {
                            try MaterializationStatus.download(atPath: singleNode.id)
                            Logger.shared.info("Requested download of cloud-only file: \(singleNode.id)")
                            // Tell the row to watch for the content landing so its cloud badge
                            // clears; on the failure path the badge (correctly) stays. Scoped to
                            // THIS pane — the twin row the other pane may show for the same path
                            // must not start a second poll.
                            //
                            // And through this pane's own CHANNEL, not `.default`. In the app they
                            // are the same object, so this changes no shipped behaviour; it makes
                            // the invariant true rather than incidentally true — a pane and its own
                            // poster are on one channel, whichever channel that is.
                            CloudDownloadRequest.post(
                                path: singleNode.id,
                                from: PaneToken(isLeft: isLeft, isSingleSource: isSingleSource),
                                through: downloadChannel)
                        } catch {
                            Logger.shared.warning("Download unavailable for “\(singleNode.name)” — reveal it in Finder to download it (\(error.localizedDescription))")
                        }
                    } label: {
                        Label("Download", systemImage: "icloud.and.arrow.down")
                    }
                }
                Divider()
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                // Offered only when this provider will actually reject the name — a finding, not a
                // standing menu item. The check runs here, while the menu is being built on open,
                // rather than in the row: `FileContextMenu` is constructed per row and the pane's
                // render budget is the app's tightest.
                if let risky = delegate.riskyName(for: singleNode) {
                    Button(action: { delegate.handleFixName(singleNode) }) {
                        Label("Fix name…", systemImage: NameNormalizeGlyph.lens)
                    }
                    .help("\(risky.reason) Renames it to “\(risky.sanitizedName)”, undoably.")
                    // The badge's answer, and the ONLY way back from one. Keeping is durable, so
                    // without a withdrawal offered from the file itself it would be a one-way door
                    // — and a kept name draws no badge, so there is nothing else on screen left to
                    // click. Both directions live here, on the row, where the decision is made.
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
                
                if singleNode.isDirectory {
                    SharedFileMenuItems.newFolder(at: singleNode.id, delegate: delegate)
                    Divider()
                    Button(action: { delegate.handleFocus(singleNode) }) {
                        // On the comparison panes this isolates a specific folder mapping ("Compare
                        // only this folder"); on the single-source rail there's nothing to compare —
                        // it just drills the rail into the folder, so it reads as a plain "Open".
                        if isSingleSource {
                            Label("Open", systemImage: "arrow.forward")
                        } else {
                            Label("Compare only this folder", systemImage: "scope")
                        }
                    }
                }
            }

            // Comparison-only: Ignore and Copy/Move to the other provider are meaningless on the
            // single-source rail (there is no opposite pane), so they're dropped there.
            if !isSingleSource {
                let allIgnored = selectedNodes.allSatisfy { n in
                    delegate.isNodeIgnored(n, currentPath: currentPath)
                }
                Button(action: { delegate.handleIgnore(selectedNodes) }) {
                    Label(allIgnored ? "Include in comparison" : "Ignore in comparison", systemImage: allIgnored ? "eye" : "eye.slash")
                }
            }

            // Separator before the clipboard section. Skipped only when nothing sits between it and
            // the Refresh divider above (single-source multi-select drops the single-node block and
            // every comparison item), so two dividers never stack.
            if count == 1 || !isSingleSource {
                Divider()
            }

            // The absolute destination verbs, in the slot the comparison transfers occupy on the
            // two-pane menu. Single-source only, and deliberately: over there they would sit beside
            // "Move to <other pane>" — two entries opening with the same two words, one of which
            // asks a question and one of which does not. Here there is nothing to confuse them
            // with, because the rail drops every comparison item (see below), which is also why it
            // had no way to send a file anywhere at all before this.
            //
            // No `.keyboardShortcut` on either, deliberately. This menu is built PER ROW, and
            // `selectedNodes` falls back to *this row's* node when the selection is empty or does
            // not contain it — so a window-level key equivalent declared here is bound to whichever
            // row's menu instance the framework happened to register, and would file a file the
            // user never pointed at. It is also consulted before the first responder, the reason
            // `ReviewCardView` and the Differences table both went to `.onKeyPress` instead. A
            // shortcut for this verb belongs on the window's own command set, keyed off the live
            // selection — not here.
            if isSingleSource {
                Button(action: { delegate.handleChooseDestination(selectedNodes, isMove: true) }) {
                    Label(count > 1 ? "Move \(count) items to…" : "Move to…", systemImage: TransferGlyph.move(toRight: true))
                }

                Button(action: { delegate.handleChooseDestination(selectedNodes, isMove: false) }) {
                    Label(count > 1 ? "Copy \(count) items to…" : "Copy to…", systemImage: TransferGlyph.copy)
                }

                Divider()
            }

            if !isSingleSource {
                // Copy/Move to the other pane share the toolbar/header vocabulary (TransferGlyph).
                // Copy is non-directional (the target pane is named in the label); Move points its
                // box-arrow at the actual target pane, like the toolbar — right when this is the
                // left pane, left when it's the right pane.
                Button(action: { delegate.handleCopy(selectedNodes) }) {
                    Label(count > 1 ? "Copy \(count) items to \(otherPaneName)" : "Copy to \(otherPaneName)", systemImage: TransferGlyph.copy)
                }

                Button(action: { delegate.handleMove(selectedNodes) }) {
                    Label(count > 1 ? "Move \(count) items to \(otherPaneName)" : "Move to \(otherPaneName)", systemImage: TransferGlyph.move(toRight: isLeft))
                }

                Divider()
            }

            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: true) }) {
                Label(count > 1 ? "Cut \(count) items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: false) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePaste(node)
            }

            if !isSingleSource, !otherSelection.isEmpty {
                // Pruned like every other entry point: the transfer prunes downstream anyway,
                // so an unpruned list here only mislabeled the count ("Copy 3 items" for a
                // folder plus two of its own children, which transfer as 1).
                let otherSelectedNodes = otherTree.selectedNodes(at: otherSelection)
                if !otherSelectedNodes.isEmpty {
                    Button(action: { delegate.handlePasteExplicit(node, nodes: otherSelectedNodes) }) {
                        if otherSelectedNodes.count > 1 {
                            Label("Copy \(otherSelectedNodes.count) items from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                        } else if let first = otherSelectedNodes.first {
                            Label("Copy '\(first.name)' from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                        }
                    }
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: { delegate.handleDelete(selectedNodes) }) {
                Label(count > 1 ? "Delete \(count) items" : "Delete", systemImage: "trash")
            }
        }
    }
}

/// Renders a single row representing a file or directory node with its associated system icon,
/// plus a trailing sync-status badge when the node (or, for folders, anything beneath it) differs.
struct FileRowView: View {
    /// The five scalars this row renders. Flat by design: a FOLDER `FileNode` carries its whole
    /// subtree in `children`, and the derived `FileNode.==` would recurse through all of it every
    /// time SwiftUI compared this row's body output. Holding `FileRowInfo` makes that subtree
    /// structurally unreachable from the view rather than merely uncompared.
    let node: FileRowInfo
    let isIgnored: Bool
    /// Diff status of the node itself, or nil when it is in sync.
    let diffStatus: FileDifference.DifferenceType?
    /// Number of differences beneath this node (directories only; 0 elsewhere).
    let containedDiffCount: Int
    /// Whether this file is a cloud-only placeholder (content not on disk). Detected lazily per row
    /// via one `lstat` — off the scan, so a big tree pays nothing until a row actually appears —
    /// and memoized by `CloudOnlyBadgeCache`, so a row scrolling back in does not re-stat.
    @State private var isCloudOnly = false
    /// List-density setting (H7), injected by `FileTreeView` (which reads the @AppStorage once
    /// for the whole pane): comfortable renders exactly the pre-setting look; compact tightens
    /// the row and drops the secondary size/date detail.
    let density: ListDensity
    /// The pane's resolved fonts. Handed down rather than derived per row — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled
    /// Why this provider will give this name trouble, or nil when it won't (and nil when the user
    /// has kept it). Resolved by the pane from the delegate, memoized by (provider, name) — see
    /// `RiskyNameBadgeCache`. Defaulted so every caller that has no provider context, and every
    /// test double, renders exactly the row it rendered before the badge existed.
    var riskyReason: String? = nil
    /// The identity of the download request the pane is watching for THIS row; nil when it is not
    /// this row's file (or nothing is being watched). Part of the badge task's `.task(id:)` key, so
    /// the badge re-resolves when the pane arms a watch for this file and again when that watch
    /// concludes — by which point the pane has recorded the fresh answer in the memo, making the
    /// second resolve a dictionary hit.
    ///
    /// The request's UUID rather than a `Bool` because two requests can follow each other with no
    /// gap between them: downloading the same file again while a watch is in flight moves the latch
    /// from one request straight to the next, which a `Bool` would not report as a change at all.
    ///
    /// The row does not poll. It briefly did — ten one-second detached `lstat`s of its own, plus
    /// its own `CloudOnlyBadgeCache.forget` — which duplicated the preview column's watch for a
    /// preview-started download and tied the watch's lifetime to whether this row was ever
    /// realized. The pane owns it now: see `PaneDownloadWatch`.
    ///
    /// Supplied by the pane rather than discovered here. Every row used to hold its own
    /// `.onReceive(NotificationCenter…)` subscription for the download notice — one live Combine
    /// subscription per visible row, created and torn down as the list recycles them, so that at
    /// most one row per session could ever receive anything. The pane holds the single
    /// subscription now and hands the answer down.
    var awaitingDownloadID: UUID? = nil
    /// What a running search says about this row — the matched run, whether it recedes, the count
    /// of matches inside a closed folder, and which side it is on. `.none` is a pane with no query,
    /// which renders exactly the row this view rendered before search existed.
    var searchContext: PaneSearchRowContext = .none
    /// Which pane this row is in, so a one-sided hit can name its side. Only read while a search is
    /// annotating; defaulted so no existing caller has to answer it.
    var isLeftPane: Bool = true
    /// The opposite pane's display name, for the side annotation's tooltip.
    var otherPaneName: String = ""
    /// The pane's accent, for the “N matches” count. Passed rather than inherited — see
    /// `PaneSearchAnnotation.accent`.
    var accent: Color = .accentColor

    /// The badge task's `.task(id:)` key: this row's path, and the pane's watch for it.
    ///
    /// A named type, and not private, because "the badge re-resolves when the watch concludes" is
    /// otherwise a claim about SwiftUI's re-firing that no test can reach. `.task(id:)` re-runs
    /// exactly when this value compares unequal, so pinning `==` pins the behaviour.
    struct BadgeID: Equatable {
        let path: String
        let awaitingDownloadID: UUID?
    }

    /// One row's badge answer, or nil when this resolution was SUPERSEDED and must not be written.
    ///
    /// A named function, and not private, for the reason `BadgeID` is a named type: what it pins is
    /// otherwise a claim about `.task(id:)`'s cancellation that no test can reach. The row's task
    /// assigns whatever this returns, so "returns nil" and "the badge does not move" are the same
    /// statement.
    ///
    /// **The `Task.isCancelled` check after the stat is the whole point.** The memo grew two guards
    /// for exactly this race — a stat that was out while an invalidation landed hands its answer
    /// back but writes nothing — and the row sat one layer above them, assigning unconditionally.
    /// The window: a download is requested, `PaneDownloadWatch.begin` forgets the memo and re-keys
    /// this task, whose arming re-stat suspends inside `Task.detached { lstat }.value`. A detached
    /// task does not inherit cancellation and `.value` on `Task<Bool?, Never>` does not throw, so
    /// when the watch concludes and `.task(id:)` cancels this one, it still RESUMES carrying the
    /// pre-download `true`. The replacement task reads the memo's `false`; which of the two writes
    /// last is unconstrained. The badge then went on claiming cloud-only for a file that had
    /// landed, until the row recycled or the pane republished — precisely the harm the memo's own
    /// guards were added to stop, surviving one layer above them. Needs an `lstat` slower than the
    /// poll's ~1 s interval (a wedged provider), which is narrow and is not never.
    ///
    /// `stat` is injectable for the same reason the memo's is: the race has no seam otherwise — a
    /// test cannot land a cancellation inside a real detached `lstat`.
    ///
    /// **Optional rather than defaulted, so the shipped stat has exactly one definition.** Giving
    /// this parameter its own copy of the real one reads as harmless — the literal is identical —
    /// but it made the row pass that copy on every production render, which left
    /// `CloudOnlyBadgeCache.isCloudOnly`'s own default with no production caller at all. The two
    /// could then drift with every test still green, and the copy the app actually runs is this
    /// one. `nil` here means "whatever the memo ships", which is what the row asked for before this
    /// function existed.
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

    /// Shared formatter (sizes use FileSizeFormat.byteCount): rows render lazily but
    /// scroll fast, so allocating a formatter per row body would still churn.
    @MainActor private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Size for files, date modified for directories (a directory's fileSize is just the
    /// entry size, not its contents); nil when the scan didn't populate the metadata.
    private var secondaryText: String? {
        if node.isDirectory {
            guard let date = node.modificationDate else { return nil }
            return Self.modifiedFormatter.string(from: date)
        }
        guard let size = node.fileSize else { return nil }
        return FileSizeFormat.byteCount.string(fromByteCount: Int64(size))
    }

    var body: some View {
        HStack(spacing: density == .compact ? 8 : 10) {
            Image(nsImage: FileIconCache.icon(name: node.name, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: densityMetrics.treeIconSize, height: densityMetrics.treeIconSize)
            // Affix whitespace made visible ("Swimming " → "Swimming␣"): such a node can
            // have a pixel-identical sibling that is actually a different item. The matched run of
            // a search hit is emboldened inside that same marked form — see `PaneSearchName`.
            PaneSearchName(name: node.name, match: searchContext.match, font: fonts.name)
                .strikethrough(isIgnored, color: .secondary)
                .foregroundStyle(isIgnored ? .secondary : .primary)
            // Beside the NAME, not out in the trailing accessory cluster with the cloud and
            // difference badges. Those report on the file's relationship to somewhere else — is it
            // downloaded, does it match the other pane — and belong together at the far edge. This
            // one is a statement about the characters immediately to its left, and reads as one only
            // while it is next to them. It also keeps the trailing cluster's carefully reserved
            // widths (see `FileRowAccessories`) out of the question entirely.
            RiskyNameBadge(reason: riskyReason, fonts: fonts)
            Spacer()
            if densityMetrics.showsSecondaryDetail, let secondaryText {
                Text(secondaryText)
                    .font(fonts.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // Ahead of the badge cluster, because it is the only thing on the row the user asked
            // for: they typed the query. The badges report standing facts and keep their places.
            PaneSearchAnnotation(context: searchContext, isLeft: isLeftPane,
                                 otherPaneName: otherPaneName, accent: accent, fonts: fonts)
            FileRowAccessories(
                isCloudOnly: isCloudOnly,
                reservesCloudSlot: !node.isDirectory,
                diffStatus: diffStatus,
                containedDiffCount: containedDiffCount,
                fonts: fonts
            )
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
        // A find, not a filter: a row off every path to an answer recedes and stays readable, so
        // the tree's shape — which is the answer to “where is this?” — never changes under the
        // question being asked.
        .opacity(searchContext.isDimmed ? PaneSearchDim.opacity : 1)
        .contentShape(Rectangle())
        // ONE keyed task for the badge, and it consults the memo first — so the syscall happens
        // once per path per republish rather than once per realization. `List` realizes and
        // discards rows continuously while scrolling, which is what made "once per realization"
        // expensive.
        //
        // The pane's watch for this row is part of the key (see `BadgeID`), which is the whole of
        // this row's involvement in a download: the pane forgets the memo, polls, records the
        // answer and drops its latch, and that last step re-keys this task to re-read it. Both
        // re-reads are cheap — the one on arming stats a file the user just clicked, the one on
        // conclusion is a dictionary hit.
        //
        // The assignment is conditional because a superseded resolution must not make it — see
        // `resolveBadge`, which is where that decision lives so a test can reach it.
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

/// A file row's trailing badges: the cloud-only marker, then either the difference badge or the
/// contained-differences count.
///
/// Split out of `FileRowView` so both cloud states can be RENDERED and measured. The cloud badge is
/// the one thing on a row that arrives *after* the row does — `FileRowView` resolves it with a
/// per-row `lstat` off the main actor, so it lands one row at a time, well after the rows are on
/// screen. Without a reserved slot the row's trailing cluster jumps sideways as each answer comes
/// back, which on a folder of cloud-only files is a visible ripple down the pane.
///
/// The slot is reserved the same way `PaneActionBar` reserves its summary zone: a hidden copy of
/// the real glyph establishes the width, and the visible one draws inside it. That needs no pt
/// constant, which matters because the glyph is `scaledFont` — a hard-coded width would be wrong at
/// every text size but the default.
///
/// Only FILE rows reserve it. `FileRowView` forces `isCloudOnly` false for directories, so a
/// reserved slot there would be permanently empty space that can never be filled.
struct FileRowAccessories: View {
    let isCloudOnly: Bool
    /// Whether to hold the cloud badge's width even when it isn't showing.
    let reservesCloudSlot: Bool
    let diffStatus: FileDifference.DifferenceType?
    let containedDiffCount: Int
    /// The pane's resolved fonts — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled

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
            .help("Cloud-only — content isn't downloaded to this Mac")
            .accessibilityLabel("Cloud-only, not downloaded")
    }

    var body: some View {
        if reservesCloudSlot {
            // `.hidden()` keeps the space and drops the twin from hit-testing and the
            // accessibility tree, so the reservation is invisible to VoiceOver and to the cursor.
            cloudGlyph
                .hidden()
                .overlay { if isCloudOnly { cloudBadge } }
        } else if isCloudOnly {
            // No slot held, but the badge still shows when it applies. Folding this into the branch
            // above (reserve-or-nothing) silently dropped the badge for any caller that opted out of
            // the reservation — caught only because the stability suite asserts that an unreserved
            // zone genuinely DOES resize, which it cannot do if it never renders anything.
            cloudBadge
        }
        if let diffStatus {
            // Shape encodes direction/kind so status is readable without color
            // (colors match the Differences table in the Differences pane).
            Image(systemName: DifferenceGlyph.symbol(for: diffStatus, filled: false))
                .font(fonts.differenceBadge)
                .foregroundStyle(DifferenceGlyph.color(for: diffStatus))
                .help(FileRowView.badgeHelp(for: diffStatus))
                .accessibilityLabel(FileRowView.badgeHelp(for: diffStatus))
        } else if containedDiffCount > 0 {
            Text("\(containedDiffCount)")
                .font(fonts.countPill)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
                .help("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
                .accessibilityLabel("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
        }
    }
}
