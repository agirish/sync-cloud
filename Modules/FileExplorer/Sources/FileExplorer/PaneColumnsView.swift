import AppKit
import Design
import Events
import SwiftUI
import Sync

/// The Columns presentation of one pane: Finder-style Miller columns over the pane's loaded tree.
///
/// At rest (empty `browsePath`) it renders one column spanning the pane, listing the tree view's
/// rows, so Columns can be the default without rearranging anyone's pane. More columns appear once
/// a folder is clicked.
///
/// Navigation is not re-rooting: drilling writes `browsePath` and nothing else, with no reload,
/// rescan or change of comparison scope, so every difference badge stays valid.
/// `FileActionHandler.focusFolder` is the separate way to narrow the comparison.
struct PaneColumnsView: View {
    let tree: PaneTree
    let otherTree: PaneTree
    /// Path → children for this pane's published tree, built once per publish (see
    /// `PaneChildrenIndex`). A column resolves its rows with a lookup; `PaneRow.children` per column
    /// per render is a recursive walk that freezes the main thread.
    let childrenIndex: PaneChildrenIndex
    /// Absolute path of the pane's tree root: the folder the first column lists.
    let treeRoot: String
    @Binding var browsePath: PaneBrowsePath
    /// Applies a new column stack for this pane. Routed through the host, not the binding, because
    /// the seam link makes it a two-pane decision and only the host sees the other pane's tree.
    let onNavigate: (PaneBrowsePath) -> Void
    @Binding var selection: Set<String>
    let otherSelection: Set<String>
    let isLeft: Bool
    let delegate: FileActionDelegate
    let diffIndex: DiffStatusIndex
    let otherPaneName: String
    let isSingleSource: Bool
    let density: ListDensity
    let isActivePane: Bool
    /// Whether the pane's walk is still running. Defaulted for test call sites that don't care.
    var isLoading: Bool = false
    /// Shared placement scratch space. Each column reports its visible rows' bottoms into it through
    /// a `ColumnListProbe` (from the table, never a per-row geometry reader) so the action bar can
    /// flip edges. `nil` on surfaces with no action bar.
    let placement: PaneBarPlacement?
    let onBarEdgeFlip: (() -> Void)?
    /// Presents a Quick Look preview; owned by the hosting `FileTreeView`.
    let onQuickLook: (URL) -> Void
    /// Asks the host to walk a directory the pane's budgeted walk did not read: a column opened past
    /// `FileSyncManager.paneNodeBudget` has no rows otherwise. Asked by the column, not at
    /// navigation, because a column opens by click, restored stack, search reveal or the seam link,
    /// and only the column sees all four.
    ///
    /// Defaulted to a no-op for tests; `PaneColumnsGraftWiringTests` pins that the app connects it.
    /// The second argument is `passive`, always `false` here: a column on screen is one somebody
    /// opened, so it asks even for a folder found unreadable before (`loadColumnChildren`).
    var onNeedChildren: (String, Bool) -> Void = { _, _ in }
    /// Directories whose deferred listing is running now: `FileSyncManager`'s in-flight set. It
    /// tells "being read" from "can't be read", which otherwise look alike (empty children plus
    /// `isUnexplored`); every budgeted-out folder passes through the first.
    var graftsInFlight: Set<String> = []
    /// The panes' sort order, ticked in the background menu's Sort By.
    var sortOption: SortOption = .name
    /// A plain click on empty space, with the depth of the column it landed in (`nil` past the last
    /// column). Routed to the host like `onNavigate`: the selection being cleared may be the other
    /// pane's.
    let onBackgroundDeselect: (Int?) -> Void
    /// The downloads this pane is watching, by path. Owned and polled by the hosting `FileTreeView`;
    /// read here by the row whose file each names (`FileRowView.awaitingDownloadID`). A value, not
    /// the `PaneDownloadWatch` object, whose reference compares identical and would let SwiftUI skip
    /// this subtree.
    var awaitingDownloads: [String: CloudDownloadRequest] = [:]
    /// The pane's resolved row fonts (see `PaneRowFonts`).
    var fonts: PaneRowFonts = .unscaled

    /// This pane's search results, for the row decoration. The column move is the hosting
    /// `FileTreeView`'s, which owns the hit index and routes it through `onColumnNavigate` like a
    /// click. Defaulted to inactive.
    var search: PaneSearchResults = .empty(side: .left)
    /// The type filter's folder counts, for the closed folders' pills. `nil` with no filter.
    var typeFilter: PaneTypeFilterDecor?
    /// The path of the hit the walk is standing on, or `nil`. Only the column that lists it scrolls
    /// to it (see `revealRow`). Separate from `search`: the hit index lives in `FileTreeView`.
    var searchRevealTarget: String?
    /// The host's row reveal, from the hosting `FileTreeView`. The column that lists the row
    /// scrolls to it and the stack brings that column into view, while the row is still the
    /// selection (see `FileTreeView.revealsRow`).
    var rowReveal: PaneRowReveal?
    /// Told when the column holding `rowReveal`'s row has scrolled to it: the hosting
    /// `FileTreeView`'s `onRowRevealed`.
    var onRowRevealed: ((PaneRowReveal) -> Void)?

    /// The `NotificationCenter` this pane's downloads are announced on, handed to each row's context
    /// menu so its Download posts where the owning pane listens (from `FileTreeView.downloadChannel`).
    /// Threaded through because a test pane on a private channel can't hear a post on `.default`, but
    /// every other suite's listener can. See "A mounted view is a live subscriber, in every suite at
    /// once" in `docs/flaky-tests.md`.
    var downloadChannel: NotificationCenter = .default

    /// The pane's resolver for selections, shared by every row menu in every column (see
    /// `PaneSelectionResolver`); the app hands over `FileTreeView`'s. The default still answers
    /// correctly: a fresh one per render is shared by that render's rows.
    var selectionResolver = PaneSelectionResolver()

    /// The width every column takes unless sized on its own: one value for every pane, so a
    /// comparison stays symmetric. Clamped on every write (see `PaneViewMode.clampColumnWidth`).
    @AppStorage(PaneViewMode.columnWidthDefaultsKey) private var storedColumnWidth: Double =
        Double(PaneViewMode.defaultColumnWidth)
    /// The column positions sized on their own, over `storedColumnWidth`, shared across panes for
    /// the same symmetry. See `ColumnWidthOverrides`.
    @AppStorage(PaneViewMode.columnWidthOverridesDefaultsKey) private var storedOverrides =
        ColumnWidthOverrides()
    /// Whether a divider drag moves its own column or all of them: the Readability setting, which ⌥
    /// inverts for the length of a gesture. See `ColumnResizeMode`.
    @AppStorage(ColumnResizeMode.defaultsKey) private var resizeModeRaw: String =
        ColumnResizeMode.default.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// A column divider drag in flight, held here so the drag doesn't write defaults per frame.
    /// `@GestureState`, so a drag that never ends (its divider pruned, the window losing key) is
    /// reset by SwiftUI instead of leaving a stale width and anchor.
    @GestureState private var columnDrag: ColumnDrag?

    /// How long after a reveal the second attempt is made: past the 0.18s scroll animation, so after
    /// a first attempt that landed the retry is a no-op (see `revealDeepestColumn`).
    static let revealRetryDelay: TimeInterval = 0.25

    /// How many times a reveal held off by a wheel gesture in its own pane re-checks the hold,
    /// spaced `WheelGestureTracker.staleness` apart: a minute of a gesture that keeps delivering.
    ///
    /// Counted, not clocked: each check schedules the next, so a starved main thread stretches the
    /// budget instead of burning it on the loaded machine where the reveal is slowest.
    ///
    /// It bounds retention, not a latched lock: the hold decays `staleness` after the last wheel
    /// event whatever the phase machinery decides. Exhaustion logs and scrolls anyway (see
    /// `revealDeepestColumn`), so the cap only needs to outlast any real gesture, and it still limits
    /// how long one chain retains the pane's captures. `PaneColumnHoldGate` keeps one chain per pane
    /// and cancels it on teardown.
    ///
    /// `nonisolated` so the environment key below can default to it: an `EnvironmentKey` is
    /// nonisolated and can't read a MainActor-isolated value.
    nonisolated static let revealHoldChecks = 600

    /// This pane's handle on its own mounted overscroll watchdog (see `PaneColumnHoldGate`).
    @State private var holdGate = PaneColumnHoldGate()

    /// The animation `revealDeepestColumn` scrolls with; the shipped ease unless a window opts out
    /// (see `paneColumnRevealAnimation`).
    @Environment(\.paneColumnRevealAnimation) private var revealAnimation

    /// The modifiers a click here is read as carrying, or `nil` (the shipped default) to ask the
    /// keyboard. See `paneClickModifiers`.
    @Environment(\.paneClickModifiers) private var pinnedClickModifiers

    /// How many hold re-checks a deferred reveal gets; `revealHoldChecks` unless a host shortens it
    /// (see `paneColumnRevealHoldChecks`).
    @Environment(\.paneColumnRevealHoldChecks) private var revealHoldChecks

    /// Where this pane's scroll offsets outlive the pane (see `PaneScrollMemory`). `nil`, the
    /// default, keeps nothing.
    @Environment(\.paneScrollMemory) private var scrollMemory

    /// The room the app's Info column takes after the deepest column, or nil for none (see
    /// `PaneInfoSlot`). The stack keeps it as it keeps a column: in its scrolling content, so Info
    /// follows the deepest column and a drill brings it into view.
    @Environment(\.paneInfoRoom) private var infoRoom

    /// Whether a rebuilt pane may put the stack's kept position back. Not while the host has asked
    /// for a row reveal, which brings the deepest column in (`revealColumnHolding`) and wins.
    ///
    /// A search hit doesn't stop it: the hit is standing state, not a request, and the walk moves
    /// `browsePath` to a hit in another folder, so a moved stack is revealed rather than restored.
    private var stackRestores: Bool { FileTreeView.revealsRow(rowReveal, selection: selection) == nil }

    /// Whether the column listing `directory` may restore its folder's kept position as it mounts:
    /// not when it lists the row a search hit or row reveal is about to scroll to. Only that column
    /// yields.
    private func listRestores(directory: String) -> Bool {
        let folder = PaneBrowsePath.normalized(directory)
        return ![searchRevealTarget, FileTreeView.revealsRow(rowReveal, selection: selection)].contains {
            guard let target = $0 else { return false }
            return PaneBrowsePath.normalized((target as NSString).deletingLastPathComponent) == folder
        }
    }

    /// What every navigation guard in this view tests. With no pin (the shipped case) this is
    /// `NSEvent.modifierFlags`.
    private var clickModifiers: NSEvent.ModifierFlags { pinnedClickModifiers ?? NSEvent.modifierFlags }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var resizeMode: ColumnResizeMode { ColumnResizeMode(rawValue: resizeModeRaw) ?? .default }

    /// A divider drag in flight: the column it hangs off, the width that column started at, where
    /// the drag has reached, and whether it moves every column.
    ///
    /// `anchor` is captured once, at the first frame, because `DragGesture.translation` is
    /// cumulative and folding it into the live width would compound (see
    /// `PaneViewMode.draggedColumnWidth`). `all` is re-read every frame, so ⌥ mid-drag switches
    /// between one column and all, as in Finder.
    private struct ColumnDrag {
        let depth: Int
        let anchor: CGFloat
        var width: CGFloat
        var all: Bool
    }

    /// The width the column at `depth` has on screen right now, mid-drag included.
    private func columnWidth(atDepth depth: Int) -> CGFloat {
        if let columnDrag, columnDrag.all || columnDrag.depth == depth { return columnDrag.width }
        return committedColumnWidth(atDepth: depth)
    }

    /// The width the column at `depth` has once no drag is in flight.
    private func committedColumnWidth(atDepth depth: Int) -> CGFloat {
        storedOverrides.width(atDepth: depth, base: CGFloat(storedColumnWidth))
    }

    /// The directories each open column lists, root first.
    private var directories: [String] { browsePath.columnDirectories(treeRoot: treeRoot) }

    var body: some View {
        // The measured width feeds the layout directly; mirrored into @State, the first render
        // would decide push-vs-stack from a width of 0.
        GeometryReader { geo in
            columnStack(paneWidth: geo.size.width)
        }
    }

    /// The pane: the Miller-column stack, scrolling horizontally within the pane's width. With Info
    /// open as a column the stack keeps its room after the deepest column; Info itself is the app's,
    /// drawn over that room (`PaneInfoSlot`).
    @ViewBuilder
    private func columnStack(paneWidth: CGFloat) -> some View {
        // Below two minimum columns there is no room for a second one, so the pane shows a single
        // column that replaces its contents as you drill and `‹` walks back out.
        let usesPush = PaneViewMode.usesPushNavigation(paneWidth: paneWidth)
        // Push mode shows only the deepest column; the rest of the stack is still in `browsePath`,
        // which is what lets `‹` walk back out and `›` walk back in.
        let visible = usesPush ? Array(directories.suffix(1)) : directories
        // Only push mode spans its area: it shows one column at every depth, with nothing to size
        // it against, and no divider. A stack showing only the root column is a stack like any
        // other (own width, a divider, dead space after it, as in Finder), so the first click
        // doesn't resize the column under the pointer.
        let spansStack = usesPush
        // A stack keeps a strip clear after its last column, outside the scroll view (see
        // `PaneViewMode.columnStackTrailingGutter` for why).
        let gutter = spansStack ? 0 : PaneViewMode.columnStackTrailingGutter
        let viewportWidth = paneWidth - gutter
        // Each column as wide as sized, but never wider than the viewport: sizes are shared and go
        // up to 600pt, and a wider column revealed by its trailing edge would cut off its icons and
        // the start of every name.
        let widths = visible.indices.map { offset in
            spansStack ? paneWidth
                : min(columnWidth(atDepth: offset), viewportWidth)
        }
        // Info's room, as wide as Info, never wider than the viewport, as a column. None in push mode:
        // the app's line keeps Info a drawer in any pane that narrow.
        let infoWidth: CGFloat? = spansStack ? nil : infoRoom.map { min($0.width, viewportWidth) }
        let fillerWidth = PaneViewMode.trailingFillerWidth(paneWidth: viewportWidth,
                                                           columnWidths: widths + [infoWidth ?? 0])
        // The empty area past the columns answers a right-click as the deepest column's own empty
        // area does; at rest that is most of the pane.
        let menuDirectory = visible.last

        HStack(spacing: 0) {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: !spansStack) {
                HStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element) { offset, directory in
                        let depth = usesPush ? browsePath.depth : offset
                        column(directory: directory, depth: depth)
                            .frame(width: widths[offset])
                            .id(directory)
                            .overlay(alignment: .trailing) {
                                // Every column has its own divider, the deepest included:
                                // columns are sized one at a time, and the deepest, listing
                                // files, is the one most often widened.
                                if !spansStack {
                                    divider(depth: depth)
                                }
                            }
                    }
                    if let infoWidth, let infoRoom {
                        // Empty: the app draws Info over it. Its id lets a reveal scroll to it.
                        Color.clear
                            .frame(width: infoWidth)
                            .id(PaneInfoSlot.stackID)
                            .reportsPaneInfoRoom(infoRoom.slot, edge: .trailing)
                            // Tells Info which scroll view to hand its swipes to.
                            .background(PaneInfoStackProbe(slot: infoRoom.slot))
                    }
                    if fillerWidth > 0 {
                        deselectCatcher(width: fillerWidth, place: "past last column",
                                        menuDirectory: menuDirectory)
                    }
                }
                // Inside the ScrollView, so the ancestor walk resolves the stack's scroll view
                // rather than a column's own list. See `PaneColumnsOverscrollReturn`.
                .background(PaneColumnsOverscrollReturn(holdGate: holdGate))
                // Same placement, same reason: the offset this remembers is the stack's.
                .background(stackScrollMemoryProbe(
                    contentWidth: widths.reduce(0, +) + (infoWidth ?? 0) + fillerWidth))
            }
            .scrollDisabled(spansStack)
            // Keep the deepest column in view as you drill, like Finder.
            .onChange(of: browsePath) { _, _ in
                revealDeepestColumn(proxy)
            }
            // The host's row reveal, stack half: the column holding the row must be on screen for
            // its own scroll (`revealRow`) to show anything. Also on appearing, since a pane mounted
            // by the workspace switch that asked never sees the request change.
            .onChange(of: rowReveal) { _, reveal in revealColumnHolding(reveal, proxy) }
            .onAppear { revealColumnHolding(rowReveal, proxy) }
            // A pane rebuilt over a stack it has no offset for (first visit, or a stack changed while
            // away) shows its deepest column, as a drill would, not its first. A remembered offset is
            // put back by `PaneStackScrollMemoryProbe` instead.
            .onAppear { revealWhenNothingToRestore(proxy) }
            // And when the pane narrows (window resized, a panel opening beside it, the split
            // dragged): the clip keeps its origin, so the deepest column slides off the trailing edge.
            //
            // This and the drivers below follow one rule: reveal only on the edge that can newly
            // occlude the deepest column (content growing, or viewport shrinking). The other edge
            // only un-hides, and firing there would force-scroll a stack the user scrolled back.
            //
            // A live narrowing fires this every frame, safely: no wheel gesture holds the stack, and
            // each reveal supersedes the last one's retry (`PaneColumnHoldGate.beginReveal`).
            // Widening is left alone except across the push threshold (below); a pane going to
            // nothing has no column to show.
            .onChange(of: paneWidth) { previous, current in
                guard current < previous, current > 0 else { return }
                revealDeepestColumn(proxy)
            }
            // And when a pane widens out of push mode, the one widening that occludes: the content
            // grows from one column to the whole stack at origin 0, leaving the user's column off
            // the trailing edge (closing the Info inspector over a pushed Compare pane, say).
            .onChange(of: usesPush) { wasPushing, isPushing in
                guard wasPushing, !isPushing else { return }
                revealDeepestColumn(proxy)
            }
            // And once the column divider settles wider: every column grows, pushing the deepest
            // past the pane's edge while the clip's origin stays put (`legalOrigin` has nothing to
            // clamp). Keyed on the stored width, written only on release, so this is the drag's end:
            // a programmatic scroll inside a live gesture can recurse `enforceHold` and crash.
            //
            // Not gated on this pane: the width is one shared key, so every pane's deepest column is
            // pushed out by the same drag. Gated on growing, per the rule above: narrowing only
            // reduces occlusion, and firing would yank a pane scrolled back to x=0 forward.
            //
            // No "already fully visible" pre-check: it would need the laid-out column frames. So a
            // pane scrolled back by choice is still brought to its deepest column when any divider
            // commits wider, a trade-off pinned by a test.
            .onChange(of: storedColumnWidth) { previous, current in
                guard current > previous else { return }
                revealDeepestColumn(proxy)
            }
            // And when a column sized on its own commits wider: the per-column form, same rule. A
            // column that narrowed, or one not open, has nothing to correct.
            .onChange(of: storedOverrides) { previous, current in
                let base = CGFloat(storedColumnWidth)
                let grew = directories.indices.contains {
                    current.width(atDepth: $0, base: base) > previous.width(atDepth: $0, base: base)
                }
                guard grew else { return }
                revealDeepestColumn(proxy)
            }
            // And when Info opens as a column, or commits wider: its room is the stack's last item,
            // so either can push it past the trailing edge. Narrowing only un-hides, per the rule.
            .onChange(of: infoRoom?.width) { previous, current in
                guard let current, current > (previous ?? 0) else { return }
                revealDeepestColumn(proxy)
            }
            // And when Get Info asks for Info already open, maybe scrolled off the trailing edge.
            .onChange(of: infoRoom?.slot.revealRequests) { _, _ in revealDeepestColumn(proxy) }
            // A reveal waiting out a hold must not outlive its pane: the queued chain holds this
            // view's captures and the `ScrollViewProxy` (see `PaneColumnHoldGate.cancelPendingReveal`).
            .onDisappear { holdGate.cancelPendingReveal() }
        }
        .frame(width: viewportWidth)
        if gutter > 0 {
            deselectCatcher(width: gutter, place: "in the gutter",
                            menuDirectory: menuDirectory)
        }
        }
    }

    /// The rebuilt pane's reveal, for a stack the memory holds no offset for (see the `.onAppear`
    /// that calls it). Only with a memory.
    private func revealWhenNothingToRestore(_ proxy: ScrollViewProxy) {
        guard let scrollMemory, stackRestores,
              scrollMemory.memory.stackPosition(surface: scrollMemory.surface, treeRoot: treeRoot,
                                                components: browsePath.components) == nil
        else { return }
        revealDeepestColumn(proxy)
    }

    /// - Parameter contentWidth: how wide the stack's content is once laid out, which tells the probe
    ///   the columns have arrived and a kept position can be measured against them.
    @ViewBuilder
    private func stackScrollMemoryProbe(contentWidth: CGFloat) -> some View {
        if let scrollMemory {
            PaneStackScrollMemoryProbe(slot: scrollMemory, treeRoot: treeRoot,
                                       components: browsePath.components, contentWidth: contentWidth,
                                       holdGate: holdGate, restores: stackRestores)
        }
    }

    /// Where this column's rows end, for the action bar, and where it is scrolled, for the scroll
    /// memory: one probe on the column's table, mounted only when there is a bar or memory to feed.
    /// See `ColumnListProbe`.
    @ViewBuilder
    private func columnListProbe(rows: [PaneRow], directory: String) -> some View {
        if placement != nil || scrollMemory != nil {
            ColumnListProbe(rows: rows, placement: placement, onBarEdgeFlip: onBarEdgeFlip,
                            memory: scrollMemory, directory: directory,
                            restores: listRestores(directory: directory))
        }
    }

    /// Brings the column holding a host-revealed row into view when it is the deepest, the only one
    /// the host asks about (it reveals a file in the folder the pane shows). A shallower column's
    /// row is one the user walked past, so the stack stays put. Uses `revealDeepestColumn`, hold
    /// deferral and retry included, not a second scroll with its own idea of settled layout.
    private func revealColumnHolding(_ reveal: PaneRowReveal?, _ proxy: ScrollViewProxy) {
        guard let path = FileTreeView.revealsRow(reveal, selection: selection),
              let deepest = directories.last,
              PaneBrowsePath.normalized((path as NSString).deletingLastPathComponent)
                == PaneBrowsePath.normalized(deepest) else { return }
        revealDeepestColumn(proxy)
    }

    /// Brings the deepest column back to the trailing edge of the stack's viewport, or, with Info open
    /// as a column, Info's room after it.
    ///
    /// Deferred, because `onChange` fires while SwiftUI is still applying the update, so the scroll
    /// would resolve against the old geometry and land short of a fresh column.
    ///
    /// Issued twice, because a too-early scroll is silently dropped, not short: `.trailing`
    /// resolved against a viewport the old stack already fits needs no scrolling, so the stack
    /// stays at origin 0. One turn usually suffices but is a race; a second attempt after layout
    /// settles costs nothing when the first worked.
    ///
    /// Each attempt resolves its own target from `browsePath` as it reads then, never the stack it
    /// was scheduled against: after a second drill, a retry aimed at the older stack would jerk the
    /// stack back a column. The same live read as `DeferredColumnNavigation`'s staleness check.
    ///
    /// The price: a deliberate scroll within `revealRetryDelay` of a drill is overridden, toward the
    /// column just clicked. When the pane is held, that window lasts until the holding gesture ends;
    /// only a new gesture right after it can be overridden.
    ///
    /// `anchor: .trailing` always shows a whole column: none is wider than the viewport.
    ///
    /// The animation comes from the environment so a host that can't run one can say so (see
    /// `paneColumnRevealAnimation`). Read once, before the closure, so both attempts use this
    /// update's value; the target, by contrast, is re-resolved each time.
    ///
    /// An attempt made while this pane's own stack is held is deferred, not spent. `enforceHold`
    /// can't tell a vertical gesture's leaked drift from this programmatic scroll, and a momentum
    /// tail outlasts `revealRetryDelay`, so both attempts would be reverted; nothing else would fire
    /// afterwards, and the new column would stay hidden. Asking first makes the reveal wait the
    /// gesture out while the hold works as before. The question is the scoped, per-pane one.
    /// Replaying reverted scrolls on release isn't an option: the watchdog sees only bounds
    /// changes, and would replay the leaked drift too.
    ///
    /// The waiting is one chain per pane, parked on the gate: a later reveal replaces it, teardown
    /// cancels it, and the gate's generation also retires the uncancellable attempts an earlier
    /// reveal queued. See `PaneColumnHoldGate.beginReveal()`, `deferReveal(generation:by:_:)` and
    /// `revealHoldChecks`.
    private func revealDeepestColumn(_ proxy: ScrollViewProxy) {
        let animation = revealAnimation
        let gate = holdGate
        let budget = revealHoldChecks
        // With Info open as a column its room follows the deepest column, so the reveal shows both.
        let toInfo = infoRoom != nil
        // A fresh reveal supersedes any chain waiting out a hold and every attempt an earlier
        // reveal queued; the new chain re-resolves its target against the current `treeRoot`.
        // See `PaneColumnHoldGate.beginReveal`.
        let generation = gate.beginReveal()
        func attempt(checksLeft: Int) {
            // The two attempts below are uncancellable queued blocks that can outlive their reveal
            // by `revealRetryDelay`, so each asks whether it still speaks for this pane: a
            // superseded one neither scrolls nor parks, even after teardown or a newer reveal.
            guard gate.isCurrent(generation) else { return }
            if gate.isStackHeld {
                if checksLeft > 0 {
                    gate.deferReveal(generation: generation, by: WheelGestureTracker.staleness) {
                        attempt(checksLeft: checksLeft - 1)
                    }
                    return
                }
                // Exhaustion scrolls anyway, and logs it. Giving up would strand the column with
                // nothing logged; a reverted scroll costs nothing, and one that lands wins. The line
                // makes a genuinely stuck lock diagnosable.
                Logger.shared.debug(String(
                    format: "[columns] reveal waited out %d hold checks (%.0fs) and is scrolling anyway",
                    budget, Double(budget) * WheelGestureTracker.staleness))
            }
            guard let deepest = browsePath.columnDirectories(treeRoot: treeRoot).last else { return }
            let target: AnyHashable = toInfo ? AnyHashable(PaneInfoSlot.stackID) : AnyHashable(deepest)
            withAnimation(animation) { proxy.scrollTo(target, anchor: .trailing) }
            // The gate answer above is a snapshot: a main-thread hitch can open a gap in momentum
            // delivery, so this scrolls, the next event re-engages the lock and `enforceHold`
            // reverts it. So ask again, `staleness` later. Not zero: a zero-delay re-ask lands
            // inside the same gap. After `staleness` the answer is unambiguous: held means the
            // reveal may have been undone, so wait again; not held means nothing can revert it.
            //
            // Not an origin comparison: the 0.18s ease is mid-flight a cadence later, and a reveal
            // that needed no movement looks like a reverted one. The re-ask consumes a check, so the
            // budget still bounds the chain.
            guard checksLeft > 0 else { return }
            gate.deferReveal(generation: generation, by: WheelGestureTracker.staleness) {
                guard gate.isStackHeld else { return }
                attempt(checksLeft: checksLeft - 1)
            }
        }
        // Both hops are `DispatchQueue.main`, which puts `attempt` on the main actor. It compiles
        // without `MainActor.assumeIsolated` only because SwiftUI's `@MainActor @preconcurrency`
        // `body` requirement downgrades the diagnostic: the isolation holds because the queue is
        // `main`, not because the compiler checked it (unlike `PaneColumnHoldGate.deferReveal`).
        DispatchQueue.main.async { attempt(checksLeft: budget) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealRetryDelay) {
            attempt(checksLeft: budget)
        }
    }

    /// Empty space beside the columns (the dead space past a narrow stack, and the trailing
    /// gutter), made a deselect target like the space below a column's last row. It clears the
    /// selection and truncates nothing: there is no column to truncate to, and closing the stack
    /// from a click past it would be an unasked navigation.
    ///
    /// The filler is zero-width whenever the stack overflows, so it can't pad the scroll content
    /// (see `PaneViewMode.trailingFillerWidth`); the gutter sits outside the scroll view for the
    /// same reason. A right-click opens `menuDirectory`'s empty-area menu, the deepest column's: at
    /// rest this area is most of the pane.
    private func deselectCatcher(width: CGFloat, place: String, menuDirectory: String?) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            // Plain clicks only, like the row path and the list catcher: ⌘ and ⇧ belong to the
            // lists' extend and range-select.
            .onTapGesture {
                guard PaneViewMode.clickNavigates(modifiers: clickModifiers) else { return }
                Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") \(place)")
                onBackgroundDeselect(nil)
            }
            .contextMenu {
                if let menuDirectory {
                    emptyAreaMenu(directory: menuDirectory)
                }
            }
    }

    /// What a column with no rows says about itself, telling apart a folder with nothing in it, one
    /// the walk hasn't read (`isUnexplored`, carried by `PaneChildrenIndex`), and one the OS refused.
    /// Worded as `DestinationFolderListing.emptyMessage` is, so the app says one thing per state.
    ///
    /// Never at depth 0: an empty tree already draws the pane's "Folder is empty" placeholder in the
    /// same space, and the two would stack. Under a type filter an empty column is a filtered one,
    /// as the pane's own placeholder is, not "Empty".
    ///
    /// `nonisolated` and pure so the rule can be asserted without mounting the column stack.
    nonisolated static func emptyCaption(rowsEmpty: Bool, depth: Int, isUnexplored: Bool,
                                         isLoading: Bool, isBeingRead: Bool,
                                         typeFiltered: Bool = false) -> Caption? {
        guard rowsEmpty, depth > 0 else { return nil }
        // The pane's walk outranks unexplored: during the shallow first paint (`loadTree` at
        // `maxDepth: 1`) every directory is unexplored, and "can't be read" would be wrong. It
        // answers with silence, not a spinner: the walk's one indicator is `PaneBusyIndicator`.
        if isLoading { return nil }
        // A listing on its way outranks "can't be read", but only while the answer is unknown.
        // `isUnexplored` matters: the in-flight set is cleared in a `defer` after the graft
        // publishes, so for one render a walked, empty folder can still be listed as in flight.
        if isBeingRead, isUnexplored { return .loading }
        if isUnexplored { return .unreadable }
        return typeFiltered ? .filteredOut : .empty
    }

    /// The things a column with no rows can be.
    enum Caption: Equatable {
        case empty
        case unreadable
        /// This column's own listing is on its way while the pane is idle: the one case a column
        /// carries a spinner of its own.
        case loading
        /// Nothing here that the pane's type filter shows.
        case filteredOut

        /// `nil` while loading: that state draws a spinner, and a caption beside it would be the
        /// same sentence twice.
        var text: String? {
            switch self {
            case .empty: return "Empty"
            // `DestinationFolderListing.emptyMessage`'s wording, curly apostrophe included, so the
            // two surfaces can't drift apart.
            case .unreadable: return "Can’t be read"
            case .loading: return nil
            case .filteredOut: return "No matching files"
            }
        }

        /// What VoiceOver says for the loading spinner, which otherwise reads as an unnamed
        /// progress indicator. The column and the tree's placeholder row both use it.
        static let loadingLabel = "Reading this folder"
    }

    /// This column's caption, with the three state questions answered from the column's own inputs.
    private func caption(rowsEmpty: Bool, depth: Int, directory: String) -> Caption? {
        Self.emptyCaption(rowsEmpty: rowsEmpty, depth: depth,
                          isUnexplored: childrenIndex.isUnexplored(atPath: directory),
                          isLoading: isLoading,
                          isBeingRead: graftsInFlight.contains(directory),
                          typeFiltered: typeFilter?.hidesEverything(inFolder: directory) ?? false)
    }

    /// Whether this column should ask for its directory's contents. Not while the walk runs: in the
    /// shallow first paint every directory is unexplored, and asking would duplicate the deep walk
    /// already on its way. And only when unexplored: asking for a genuinely empty folder would
    /// relist it on every render, forever.
    ///
    /// No guard for the tree root: it is never in `unexploredPaths` (`PaneChildrenIndex` keys it
    /// directly, and `adoptRawTree` unwraps the unreadable-root marker first).
    ///
    /// `nonisolated` and pure so a test can check it; its call sites are view modifiers.
    nonisolated static func asksForChildren(isLoading: Bool, isUnexplored: Bool) -> Bool {
        !isLoading && isUnexplored
    }

    private func requestChildrenIfNeeded(_ directory: String) {
        guard Self.asksForChildren(isLoading: isLoading,
                                   isUnexplored: childrenIndex.isUnexplored(atPath: directory))
        else { return }
        onNeedChildren(directory, false)
    }

    /// One column: the rows of `directory`, or a placeholder when it has none.
    ///
    /// A `List` per column rather than a `LazyVStack`, so `onDeleteCommand`, the selection binding
    /// and `PaneListSelectionStyler` work without being reimplemented.
    @ViewBuilder
    private func column(directory: String, depth: Int) -> some View {
        let rows = childrenIndex.children(atPath: directory) ?? []
        // The reader wraps the column's own `List`, not the stack: the stack's proxy scrolls
        // horizontally and can't scroll a row into view vertically. A hit needs both; see
        // `revealRow`.
        ScrollViewReader { proxy in
        List(selection: columnSelection(for: rows, depth: depth)) {
            ForEach(rows) { row in
                columnRow(row, depth: depth)
            }
        }
        // Bring the walked-to hit into view when it lands in this column. `.onAppear` too: a reveal
        // that drills creates this column already carrying the target, so `.onChange` never fires.
        .onChange(of: searchRevealTarget) { _, target in revealRow(target, in: rows, proxy: proxy) }
        .onAppear { revealRow(searchRevealTarget, in: rows, proxy: proxy) }
        // The host's row reveal, row half: the same scroll, for a row the host selected on the
        // user's behalf, only while it is still the selection.
        .onChange(of: rowReveal) { _, reveal in answerRowReveal(reveal, in: rows, proxy: proxy) }
        .onAppear { answerRowReveal(rowReveal, in: rows, proxy: proxy) }
        // On appear, and again when the walk finishes: during the walk every directory is
        // unexplored, so asking would duplicate it (see `asksForChildren`), and a column already on
        // screen has fired `onAppear` long before.
        .onAppear { requestChildrenIfNeeded(directory) }
        .onChange(of: isLoading) { _, _ in requestChildrenIfNeeded(directory) }
        .listStyle(.sidebar)
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        // Clicking below this column's last row deselects and closes the columns to its right,
        // like Finder. The depth is this column's own, so a click in column 0 of three closes two.
        .background(PaneBackgroundDeselect {
            Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") col\(depth) empty area")
            onBackgroundDeselect(depth)
        })
        // Instrumentation for the "first column moves up and down" report; see
        // `PaneColumnJitterProbe`.
        .background(PaneColumnJitterProbe(depth: depth, isLeft: isLeft))
        // Row bottoms for the action bar and scroll offset for the memory, both from the column's
        // table, so the stack's sideways scroll re-lays out no row. See `ColumnListProbe`.
        .background(columnListProbe(rows: rows, directory: directory))
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, density.metrics.treeIconSize + 6)
        .onDeleteCommand {
            let selected = tree.selectedNodes(at: selection)
            if !selected.isEmpty { delegate.handleDelete(selected) }
        }
        .overlay {
            // Resolved in a helper: inline, five inputs make the type checker give up ("unable to
            // type-check in reasonable time").
            if let caption = caption(rowsEmpty: rows.isEmpty, depth: depth, directory: directory) {
                Group {
                    if let text = caption.text {
                        Text(text)
                            .scaledFont(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(Caption.loadingLabel)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .contextMenu { emptyAreaMenu(directory: directory) }
        }
    }

    /// The empty-area menu for `directory`: a column's, and the dead space past the columns
    /// (`deselectCatcher`), which answers for the deepest one.
    @ViewBuilder
    private func emptyAreaMenu(directory: String) -> some View {
        SharedFileMenuItems.refresh(delegate: delegate)
        Divider()
        SharedFileMenuItems.newFolder(at: directory, delegate: delegate)
        // The column's own directory, so "New Tab" from the third column opens a tab there, not at
        // the pane's scope.
        SharedFileMenuItems.tabActions(at: directory, delegate: delegate)
        SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
            delegate.handlePasteToPath(directory)
        }
        Divider()
        SharedFileMenuItems.getInfo(for: directory, delegate: delegate)
        Divider()
        SharedFileMenuItems.sortBy(sortOption) { delegate.handleSort($0) }
        // The pane's view options live where Finder keeps them, in the columns' empty-area menu.
        // Not in `FileContextMenu`, which is built per row, once per visible file.
        Divider()
        Button(action: resetColumnWidths) {
            Label("Reset Column Widths", systemImage: "arrow.left.and.right")
        }
        .disabled(columnWidthsAreDefault)
    }

    /// The host's row reveal, answered by the column that lists its row: scrolled to, and the host
    /// told (`onRowRevealed`) so it retires the request and a later appearance doesn't scroll back.
    /// The stack half (`revealColumnHolding`) needs no report: the host retires on the next turn.
    private func answerRowReveal(_ reveal: PaneRowReveal?, in rows: [PaneRow], proxy: ScrollViewProxy) {
        guard let reveal, let path = FileTreeView.revealsRow(reveal, selection: selection),
              rows.contains(where: { $0.id == path }) else { return }
        revealRow(path, in: rows, proxy: proxy)
        onRowRevealed?(reveal)
    }

    /// Scrolls this column to `target` when it is one of its rows: selecting a row far down a column
    /// doesn't bring it on screen.
    ///
    /// Issued twice, as in `revealDeepestColumn`: a `scrollTo` before layout settles is silently
    /// dropped, and a reveal that drilled scrolls a `List` created in the same update. The
    /// membership check is an economy, not a guard: `scrollTo` for an id outside this reader is a
    /// no-op, so removing it breaks no test, but it saves every other column two queued blocks.
    private func revealRow(_ target: String?, in rows: [PaneRow], proxy: ScrollViewProxy) {
        guard let target, rows.contains(where: { $0.id == target }) else { return }
        let animation = revealAnimation
        func attempt() {
            withAnimation(animation) { proxy.scrollTo(target, anchor: .center) }
        }
        DispatchQueue.main.async { attempt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealRetryDelay) { attempt() }
    }

    @ViewBuilder
    private func columnRow(_ row: PaneRow, depth: Int) -> some View {
        let node = row.node
        // The folder you drilled through stays marked after the selection moves deeper, so the
        // stack shows how you got there.
        let isOnPath = depth < browsePath.depth && browsePath.components[depth] == node.name

        ColumnRowView(
            row: row,
            isIgnored: FileTreeView.rowIsIgnored(node, currentPath: treeRoot, delegate: delegate, isSingleSource: isSingleSource),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density,
            showsChevron: node.isDirectory,
            fonts: fonts,
            riskyReason: delegate.riskyNameReason(forName: row.info.name, isDirectory: row.info.isDirectory),
            editorRefusal: delegate.editorRefusal(forPath: row.info.id, isDirectory: row.info.isDirectory,
                                                  size: row.info.fileSize ?? 0),
            isArmedForCompare: delegate.armedComparePath == row.info.id,
            awaitingDownloadID: awaitingDownloads[node.id]?.requestID,
            // A column's “expanded” is `isOnPath`: the drilled-through folder's contents are
            // already on screen to its right, so its “N matches” would repeat them.
            searchContext: {
                let phrase = node.isDirectory ? typeFilter?.phrase(forFolder: node.id) : nil
                guard search.isActive else { return .typeFilter(phrase, isExpanded: isOnPath) }
                var context = PaneSearchRowContext(results: search, path: node.id, isExpanded: isOnPath)
                context.typeFilterPhrase = phrase
                return context
            }(),
            isLeftPane: isLeft,
            otherPaneName: otherPaneName,
            accent: glassHue.accentColor
        )
        .tag(node.id)
        // **Never** put a gesture on this row: selection and the column drill are the List's alone.
        // A tap gesture claims the mouse-down and often never completes, so the click never reaches
        // `NSTableView` and nothing is selected; ⌘/⇧ clicks, which only the table commits, die
        // outright. `columnSelection`'s setter navigates, so a click still opens a folder's column;
        // Open in New Tab is in the row's context menu and on ⌘T. `PaneColumnRowHasNoGestureTests`
        // fails if a gesture returns.
        .contextMenu {
            FileContextMenu(
                row: row, selection: selection, tree: tree, otherTree: otherTree,
                otherSelection: otherSelection, isLeft: isLeft, currentPath: treeRoot,
                delegate: delegate, otherPaneName: otherPaneName, isSingleSource: isSingleSource,
                onQuickLook: onQuickLook,
                selectionResolver: selectionResolver,
                downloadChannel: downloadChannel
            )
        }
        .listRowBackground(rowBackground(for: node, isOnPath: isOnPath))
    }

    /// Selection is confined to one column, as in Finder and the pane's flat `Set<String>`: each
    /// column reads the shared selection filtered to its own rows and writes it wholesale, so
    /// selecting here clears every other column.
    private func columnSelection(for rows: [PaneRow], depth: Int) -> Binding<Set<String>> {
        // Filtered in the getter, not as a `Set` of every row built per render: with no selection
        // (every frame of a scroll) it costs nothing, and otherwise allocates only the matches.
        Binding(
            get: {
                guard !selection.isEmpty else { return [] }
                return Set(rows.lazy.map(\.id).filter(selection.contains))
            },
            set: { newValue in
                // Logs empty writes too: they are silent elsewhere (`applySelectionWrite` takes no
                // token for them), so a selection landed then cleared would look like one that never
                // landed. Gated with the dead-click instrumentation; `[click]` is the ungated record.
                if PaneScrollTrace.isEnabled {
                    Logger.shared.debug("[sel] \(isLeft ? "left" : "right") list wrote \(newValue.count) item(s)")
                }
                selection = newValue
                // The only place a column click navigates from; the row carries no gesture (see the
                // note on the row).
                guard PaneViewMode.clickNavigates(modifiers: clickModifiers),
                      newValue.count == 1,
                      let id = newValue.first,
                      let row = rows.first(where: { $0.id == id })
                else { return }
                // The target and the stack it was computed against are captured now. Deferred a
                // turn: `browsePath` restructures the stack, and writing it inside the List's own
                // selection commit drops clicks.
                let stackAtWrite = browsePath
                let path = navigation(for: row, depth: depth)
                DispatchQueue.main.async {
                    guard DeferredColumnNavigation.isStillValid(
                        current: browsePath, computedAgainst: stackAtWrite, target: path)
                    else {
                        Logger.shared.debug("[columns] dropped a stale deferred navigation to \(path.relativePath.isEmpty ? "root" : path.relativePath)")
                        return
                    }
                    onNavigate(path)
                }
            }
        )
    }

    /// Where a click on `row` in the column at `depth` should leave the stack: a folder opens its
    /// own column, a file closes any deeper ones without opening one.
    ///
    /// Called from the List's selection commit, the only place a click navigates.
    private func navigation(for row: PaneRow, depth: Int) -> PaneBrowsePath {
        var path = browsePath
        if row.node.isDirectory {
            path.drill(into: row.node.name, atDepth: depth)
        } else {
            path.truncate(toDepth: depth)
        }
        return path
    }

    @ViewBuilder
    private func rowBackground(for node: FileNode, isOnPath: Bool) -> some View {
        if selection.contains(node.id) {
            wash(opacity: PaneSelectionWash.opacity(isActivePane: isActivePane))
        } else if isOnPath {
            // Quieter than a selection: this row is the trail, not the target.
            wash(opacity: PaneSelectionWash.opacity(isActivePane: false) * 0.6)
        } else {
            Color.clear
        }
    }

    private func wash(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .fill(glassHue.accentColor.opacity(opacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// The draggable seam on a column's trailing edge.
    ///
    /// A drag resizes that column alone or every column, per the Readability setting "Column
    /// widths", with ⌥ doing the other (`ColumnResizeMode.resizesAll`). A double-click fits the
    /// column to its longest name, or as the "all" gesture gives every open column the widest one's
    /// need. Finder's gestures. Defaults are written only when a gesture ends.
    private func divider(depth: Int) -> some View {
        let drag = DragGesture(coordinateSpace: .global)
            .updating($columnDrag) { value, drag, _ in
                let anchor = drag?.anchor ?? committedColumnWidth(atDepth: depth)
                drag = ColumnDrag(
                    depth: depth, anchor: anchor,
                    width: PaneViewMode.draggedColumnWidth(anchor: anchor,
                                                           translation: value.translation.width),
                    all: resizeMode.resizesAll(optionHeld: clickModifiers.contains(.option)))
            }
            // Recomputed from the gesture's own value, since SwiftUI resets the live state as the
            // gesture ends. The anchor is still the committed width: nothing commits until the end.
            .onEnded { value in
                let width = PaneViewMode.draggedColumnWidth(anchor: committedColumnWidth(atDepth: depth),
                                                            translation: value.translation.width)
                commitColumnWidth(width, depth: depth, cause: "drag",
                                  all: resizeMode.resizesAll(optionHeld: clickModifiers.contains(.option)))
            }
        let fit = TapGesture(count: 2).onEnded {
            fitColumnWidth(depth: depth,
                           all: resizeMode.resizesAll(optionHeld: clickModifiers.contains(.option)))
        }
        return PaneDividerHandle(gesture: drag.simultaneously(with: fit))
    }

    /// Writes a column gesture's result (the rule is `PaneViewMode.resizedColumnWidths`). Each value
    /// is written only if it moved, so a no-op gesture fires no width driver.
    private func commitColumnWidth(_ width: CGFloat, depth: Int, cause: String, all: Bool) {
        let next = PaneViewMode.resizedColumnWidths(base: CGFloat(storedColumnWidth),
                                                    overrides: storedOverrides,
                                                    depth: depth, to: width, all: all)
        let baseMoved = Double(next.base) != storedColumnWidth
        let overridesMoved = next.overrides != storedOverrides
        guard baseMoved || overridesMoved else { return }
        Logger.shared.debug("[columns] \(cause) sized \(all ? "every column" : "column \(depth)") to \(Int(PaneViewMode.clampColumnWidth(width)))")
        if baseMoved { storedColumnWidth = Double(next.base) }
        if overridesMoved { storedOverrides = next.overrides }
    }

    /// The double-click fit: this column to its own longest name, or, as the "all" gesture, every
    /// open column to the widest one's need.
    private func fitColumnWidth(depth: Int, all: Bool) {
        guard directories.indices.contains(depth) else { return }
        let width = all ? directories.map(fittedColumnWidth(for:)).max() ?? 0
                        : fittedColumnWidth(for: directories[depth])
        commitColumnWidth(width, depth: depth, cause: "fit", all: all)
    }

    /// Every column back to the default width, the one way to undo per-column widths. Widths are
    /// shared by every pane, so this is too.
    private func resetColumnWidths() {
        Logger.shared.debug("[columns] column widths reset to \(Int(PaneViewMode.defaultColumnWidth))")
        storedColumnWidth = Double(PaneViewMode.defaultColumnWidth)
        storedOverrides = ColumnWidthOverrides()
    }

    /// Whether the widths are all the default, which disables "Reset Column Widths".
    private var columnWidthsAreDefault: Bool {
        storedOverrides.widths.isEmpty && CGFloat(storedColumnWidth) == PaneViewMode.defaultColumnWidth
    }

    /// The width the column listing `directory` needs for its longest row to show whole: see
    /// `fittedWidth(for:density:fonts:diffIndex:riskyReason:)`, fed with the pane's own inputs.
    private func fittedColumnWidth(for directory: String) -> CGFloat {
        let rows = childrenIndex.children(atPath: directory) ?? []
        guard !rows.isEmpty else { return CGFloat(storedColumnWidth) }
        return Self.fittedWidth(for: rows, density: density, fonts: fonts, diffIndex: diffIndex) {
            delegate.riskyNameReason(forName: $0.name, isDirectory: $0.isDirectory)
        }
    }

    /// The width a column needs for its longest row to show whole.
    ///
    /// Measured, not estimated: candidate rows are laid out once off screen as the column draws
    /// them (same `ColumnRowView`, fonts, density), so icon, badges, chevron and the held ☁ slot
    /// count at any text size. The list adds `PaneViewMode.columnRowHorizontalInset` around a row.
    ///
    /// Only the forty names that set widest in a plain system font are laid out, so a huge folder
    /// doesn't build thousands of rows. Set width, not character count, since wide letters (CJK,
    /// emoji, capitals) need more room; forty, not one, since badges and chevron add to a row.
    ///
    /// Measured at rest, not for a search's bold hit or a compare pick. A scroll bar that takes room
    /// ("always show scroll bars") is added. Static, with every input passed in, so a test can check
    /// it without mounting a pane.
    static func fittedWidth(for rows: [PaneRow], density: ListDensity, fonts: PaneRowFonts,
                            diffIndex: DiffStatusIndex,
                            riskyReason: (FileRowInfo) -> String?) -> CGFloat {
        let ranking = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        // Each candidate's badge resolved up front: the layout below is an escaping builder, and the
        // badge is part of the row's width.
        let candidates = rows
            .map { (row: $0, set: (NameDisplay.visibleName($0.node.name) as NSString).size(withAttributes: ranking).width) }
            .sorted { $0.set > $1.set }
            .prefix(40)
            .map { (row: $0.row, reason: riskyReason($0.row.info)) }
        let measuring = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates, id: \.row.id) { candidate in
                ColumnRowView(
                    row: candidate.row, isIgnored: false,
                    diffStatus: diffIndex.status(forNodeId: candidate.row.node.id),
                    containedDiffCount: candidate.row.node.isDirectory
                        ? diffIndex.containedDiffCount(forNodeId: candidate.row.node.id) : 0,
                    density: density, showsChevron: candidate.row.node.isDirectory, fonts: fonts,
                    riskyReason: candidate.reason)
                .fixedSize()
            }
        })
        let scrollBar = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let needed = measuring.fittingSize.width + PaneViewMode.columnRowHorizontalInset + scrollBar
        return PaneViewMode.clampColumnWidth(needed.rounded(.up))
    }
}

/// Whether a column navigation queued a runloop turn ago still speaks for the stack.
///
/// The List's selection commit can't navigate inline (writing `browsePath` mid-commit drops
/// clicks), so it hands the move to the next turn, and the block can't know what happened in
/// between. If `‹`, a mirrored drill or a republish prune lands first, a stale block would re-apply
/// the click on top of the newer move, so Back would seem not to work.
///
/// Pure, to pin its one subtlety: `target` counts as current alongside `computedAgainst`, so a
/// navigation already applied (`browsePath` equal to `target`) doesn't read as stale.
enum DeferredColumnNavigation {
    static func isStillValid(
        current: PaneBrowsePath,
        computedAgainst: PaneBrowsePath,
        target: PaneBrowsePath
    ) -> Bool {
        current == computedAgainst || current == target
    }
}

/// Preference carrying every visible row's bottom edge in GLOBAL space, keyed by node id.
///
/// The tree's source of `PaneBarPlacement.rowBottoms`. Columns write the placement from each
/// column's table instead (`ColumnListProbe`): the stack scrolls sideways, and per-row global
/// readers would pay for every frame; the tree doesn't, so its readers move only with rows. Global,
/// not a named space: List rows live in their own AppKit subtrees, where a named space silently
/// degrades to global and misplaces the action bar.
struct PaneRowBottomsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { existing, _ in existing }
    }
}

/// A column row: the tree row minus its trailing detail, plus a trailing chevron on folders.
///
/// Wraps `FileRowView`, so icon, name and badges can't drift between the presentations. Columns
/// differs in two ways, both decided here: it adds the chevron, and withholds the trailing detail
/// (date, size) through `showsSecondaryText`, as Finder's column view does while its List view
/// keeps it. The chevron is then last on the row and lands on its trailing edge with no spacer.
///
/// That is the row's edge, not the column's: the List insets the row, so the chevron sits about
/// 16.5pt clear of the divider, the rail Finder draws. `theChevronReachesTheTrailingEdge` pins the
/// part this view controls, the 0.5pt inside the row.
struct ColumnRowView: View {
    let row: PaneRow
    let isIgnored: Bool
    let diffStatus: FileDifference.DifferenceType?
    let containedDiffCount: Int
    let density: ListDensity
    let showsChevron: Bool
    /// The pane's resolved fonts (see `PaneRowFonts`).
    var fonts: PaneRowFonts = .unscaled
    /// See `FileRowView.riskyReason`. Resolved by the column: only the pane can reach the delegate.
    var riskyReason: String? = nil
    /// See `FileRowView.editorRefusal`. Resolved by the column, like `riskyReason`.
    var editorRefusal: String? = nil
    /// Forwarded to ``FileRowView/isArmedForCompare``. Defaulted for callers with no pick context.
    var isArmedForCompare: Bool = false
    /// See `FileRowView.awaitingDownloadID`. Threaded through, not observed here: a per-row
    /// subscription for a per-session event would be waste.
    var awaitingDownloadID: UUID? = nil
    /// See `FileRowView.searchContext`: the row's search decoration, resolved by the column, which
    /// alone knows whether this folder is drilled through.
    var searchContext: PaneSearchRowContext = .none
    var isLeftPane: Bool = true
    var otherPaneName: String = ""
    var accent: Color = LiquidGlassHue.stored().accentColor

    var body: some View {
        HStack(spacing: 6) {
            FileRowView(node: row.info, isIgnored: isIgnored, diffStatus: diffStatus,
                        containedDiffCount: containedDiffCount, density: density,
                        fonts: fonts, riskyReason: riskyReason, editorRefusal: editorRefusal,
                        isArmedForCompare: isArmedForCompare,
                        awaitingDownloadID: awaitingDownloadID,
                        searchContext: searchContext, isLeftPane: isLeftPane,
                        otherPaneName: otherPaneName, accent: accent,
                        showsSecondaryText: false)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(fonts.chevron)
                    .foregroundStyle(.tertiary)
                    // The chevron recedes with its row, or it would read as the one live thing on a
                    // row the search has set aside.
                    .opacity(searchContext.isDimmed ? PaneSearchDim.opacity : 1)
            }
        }
    }
}

// MARK: - Click modifiers

private struct PaneClickModifiersKey: EnvironmentKey {
    /// `nil` means "ask the keyboard", the shipped behaviour.
    static let defaultValue: NSEvent.ModifierFlags? = nil
}

extension EnvironmentValues {
    /// The modifiers `PaneColumnsView`'s navigation guards read, or `nil` to read the live keyboard.
    ///
    /// A click navigates only when plain: ⌘, ⇧ and ⌃ belong to the list's extend, range-select and
    /// context menu (see `PaneViewMode.clickNavigates`). `NSEvent.modifierFlags` is the machine's
    /// global keyboard state at the moment the selection commits.
    ///
    /// For a real click that's right: the setter runs inside `NSTableView`'s mouse-down tracking, so
    /// the flags are the ones held while clicking. A test driving `selectRowIndexes` directly
    /// (`ColumnDrillSourceTests`) would read whatever key the person at the Mac is holding; ⇧ held
    /// while typing drops the navigation and mimics the dropped-click defect. Pinning `[]` makes
    /// "this is a plain click" part of the test.
    var paneClickModifiers: NSEvent.ModifierFlags? {
        get { self[PaneClickModifiersKey.self] }
        set { self[PaneClickModifiersKey.self] = newValue }
    }
}

// MARK: - Reveal animation

private struct PaneColumnRevealAnimationKey: EnvironmentKey {
    /// What `revealDeepestColumn` scrolls with unless a host opts out.
    static let defaultValue: Animation? = .easeOut(duration: 0.18)
}

extension EnvironmentValues {
    /// The animation `PaneColumnsView` scrolls its deepest-column reveal with, or `nil` to place
    /// the stack outright.
    ///
    /// For hosts where CoreAnimation doesn't tick. The app's on-screen, key window always drives
    /// frames, but an offscreen, never-key test window does not when the machine throttles
    /// CoreAnimation (display asleep, Low Power Mode): the animation never advances and the deepest
    /// column stays off screen, which looks exactly like the defect the tests catch. See "The
    /// machine decides the verdict — throttled CoreAnimation" in `docs/flaky-tests.md`.
    ///
    /// An ambient `.transaction { $0.animation = nil }` can't fix it, because an explicit
    /// `withAnimation` wins over it; the call itself must read that it shouldn't animate. A `nil`
    /// host gives up only the easing: `scrollTo`'s destination, which the tests measure, resolves
    /// the same way, twice-issued attempt included.
    var paneColumnRevealAnimation: Animation? {
        get { self[PaneColumnRevealAnimationKey.self] }
        set { self[PaneColumnRevealAnimationKey.self] = newValue }
    }
}

// MARK: - Reveal hold budget

private struct PaneColumnRevealHoldChecksKey: EnvironmentKey {
    /// The shipped budget.
    static let defaultValue = PaneColumnsView.revealHoldChecks
}

extension EnvironmentValues {
    /// How many times a deferred reveal re-checks this pane's hold before it stops waiting and
    /// scrolls anyway: `PaneColumnsView.revealHoldChecks` unless a host shortens it.
    ///
    /// Exists so a test can reach the exhaustion branch: the shipped budget outlasts any real
    /// gesture, and no suite can hold a stack for a minute. Injected, like
    /// `paneColumnRevealAnimation`, because the reveal reads it inside a closure tests can't reach,
    /// and a view parameter would burden every call site.
    var paneColumnRevealHoldChecks: Int {
        get { self[PaneColumnRevealHoldChecksKey.self] }
        set { self[PaneColumnRevealHoldChecksKey.self] = newValue }
    }
}
