import CoreGraphics
import Design
import Events
import FileExplorer
import Foundation
import Sync

/// The two panes' selections, as the selection bindings need them. A protocol so
/// `PaneLogic.applySelectionWrite` — which owns the ordering of a click's two halves — can be
/// driven over a stub in tests instead of a live `FileSyncManager`.
@MainActor
protocol PaneSelectionState: AnyObject {
    var selectedLeftPaths: Set<String> { get set }
    var selectedRightPaths: Set<String> { get set }
    /// Claimed by a non-empty pane write, so Space can tell a pane selection from a Differences one.
    var lastSelectionSurface: SelectionSurface? { get set }
}

extension FileSyncManager: PaneSelectionState {}

/// Orders the deferred half of the one-pane-selected invariant.
///
/// A pane click clears the *other* pane a runloop turn later (clearing it synchronously reloads
/// that pane's `List` mid-commit and drops the click). The queued clear writes a blind `[]`, so if
/// the user clicks the other pane before it drains, it wipes that fresh selection. Each commit
/// takes a token here; a deferral runs only while its token is still the newest.
///
/// A plain counter rather than anything observable: this must not invalidate a view. `&+` so a
/// long session cannot trap on overflow — only equality is ever asked of it, and a wrapped token
/// can collide with a live one no sooner than 2^63 clicks.
@MainActor
final class PaneSelectionSequencer {
    private var newest = 0

    /// Records a commit and returns its token.
    func commit() -> Int {
        newest &+= 1
        return newest
    }

    /// Whether `token` is still the newest commit — i.e. whether the deferral queued alongside it
    /// still speaks for the pane the user is on.
    func isNewest(_ token: Int) -> Bool { token == newest }
}

/// The @AppStorage provider-id writes needed to repoint the Compare panes at target providers,
/// plus how many of ContentView's id `onChange` handlers those writes will fire.
///
/// Every programmatic pane retarget (pane swap, `compareCopies`, `restoreCompareState`) must
/// suppress the id onChanges its writes trigger — otherwise the handlers clear the Tidy results
/// and reset navigation, sabotaging the retarget. The suppression protocol is a hand-counted
/// contract: exactly one `pendingSwapProviderChanges` unit per id that ACTUALLY changes (SwiftUI's
/// `onChange` never fires for an equal-value write), or the counter strands and silently swallows
/// the user's next real provider switches. This plan is that count made pure: the writers apply
/// `assignments` and seed the counter with `suppressCount`, so the two can't drift.
struct ProviderPinPlan: Equatable {
    enum Side: Equatable {
        case left
        case right
    }

    /// One id write that really changes the stored value (an equal-value write is omitted —
    /// it neither fires an onChange nor needs suppressing).
    struct Assignment: Equatable {
        let side: Side
        let providerId: String
    }

    /// The id writes to perform, left before right (matching the historical write order of
    /// every call site).
    let assignments: [Assignment]

    /// How many id onChanges the assignments will fire — one per real change. This is what the
    /// writer adds to `pendingSwapProviderChanges` BEFORE applying the assignments.
    var suppressCount: Int { assignments.count }

    /// Plans the retarget from the panes' current @AppStorage ids to the target ids, keeping
    /// only the writes that change something.
    static func make(
        currentLeft: String,
        currentRight: String,
        targetLeft: String,
        targetRight: String
    ) -> ProviderPinPlan {
        var assignments: [Assignment] = []
        if currentLeft != targetLeft {
            assignments.append(Assignment(side: .left, providerId: targetLeft))
        }
        if currentRight != targetRight {
            assignments.append(Assignment(side: .right, providerId: targetRight))
        }
        return ProviderPinPlan(assignments: assignments)
    }
}

/// Pure pane-related decision rules extracted from ContentView and its pane delegates so
/// they are unit-testable (the views delegate here and keep only state plumbing).
enum PaneLogic {

    /// Which pane owns the current selection.
    enum ActivePane {
        case left
        case right
    }

    /// The provider the action bar's Copy/Move buttons target: the pane opposite the one
    /// holding the selection. `nil` when nothing is selected — there is no direction yet,
    /// so the buttons fall back to a neutral label.
    static func copyTargetName(activePane: ActivePane?, paneNames: PaneProviderNames) -> String? {
        activePane.map { paneNames.other(isLeft: $0 == .left) }
    }

    /// What a pane's search run is FOR: which side's results it produces, and whether it annotates
    /// hits with the other pane's contents.
    ///
    /// Extracted because it is the one part of the search host that can be wrong invisibly. A
    /// left/right mix-up here searches the correct tree and stamps the answer with the other side —
    /// `PaneSearchResults.==` reads the side first, so the pane would then compare its own results
    /// unequal forever and re-render on every pass, or (worse, the other way round) never notice a
    /// change at all. `PaneOutlineRepublishTests.testPaneRendersItsOwnTreeNotTheOtherPanes` exists
    /// for the same class of bug one layer down.
    struct SearchPlan: Equatable {
        let side: PaneTree.Side
        /// Whether to walk the opposite pane's tree for "both sides" / "left only".
        let annotatesSides: Bool
    }

    /// - Parameters:
    ///   - isSingleSource: the Tidy rail, which has no opposite pane at all.
    ///   - query: empty means no search is running, so there is nothing to annotate and the other
    ///     tree must not be walked — that walk is the only part of a search that touches a tree the
    ///     user is not looking at.
    static func searchPlan(isLeft: Bool, isSingleSource: Bool, query: String) -> SearchPlan {
        SearchPlan(side: isLeft ? .left : .right,
                   annotatesSides: !query.isEmpty && !isSingleSource)
    }

    /// Whether landing `results` over `previous` is a NEW QUESTION — the one recomputation event
    /// that fires a reveal (the other trigger, ↩/⇧↩, bumps the nonce at its own call site).
    ///
    /// A republish answers false: same query, recomputed against a moved tree. Firing there is the
    /// selection-stealing bug the nonce exists to end — every background scan re-revealed the
    /// current hit over whatever the user had selected or navigated to since. Both sides compare
    /// the NORMALIZED query `PaneSearchResults` stores, so a whitespace-only edit is not a new
    /// question either.
    static func searchAsksNewQuestion(previous: PaneSearchResults,
                                      results: PaneSearchResults) -> Bool {
        results.query != previous.query
    }

    /// Which pane the pane-scoped chords act on — ⌘F, ⌘[, ⌘], ⇧⌘N and ⇧⌘P, all of which route
    /// through here so "the focused pane" can never mean two different panes to two shortcuts.
    ///
    /// **`focusedSide` is the answer whenever there is one.** It is set by ⌃⇥ and by clicking in a
    /// pane (`ContentView.paneSelectionBinding`), which makes it the one fact that survives letting
    /// go of a selection — the case the rule below cannot answer.
    ///
    /// **The selection is the fallback, with a floor.** `activePane` is the rule that decides where
    /// the action bar draws and which pane's selection wash is strong, so before anything has taken
    /// focus these chords still land where every other pane-scoped affordance points. But it is
    /// `nil` whenever nothing is selected, which on a cold window is *everything* — and the left
    /// pane is the floor there, matching the reading order of a left-to-right comparison. That
    /// floor is exactly what `focusedSide` exists to stop being the only answer: it used to mean a
    /// user who had never clicked a row had no way at all to aim ⌘F at the right-hand pane.
    ///
    /// On the single-source rail the question does not arise at all: the rail IS the left pane (see
    /// `ContentView.paneContext`) and is the only pane on screen, so a right answer there would open
    /// a field on a pane nobody can see — including a stale `focusedSide` left over from Compare,
    /// which is why the rail's guard comes first.
    static func searchTargetIsLeft(isSingleSource: Bool,
                                   focusedSide: PaneTree.Side?,
                                   activePane: ActivePane?) -> Bool {
        guard !isSingleSource else { return true }
        if let focusedSide { return focusedSide == .left }
        return activePane != .right
    }

    /// What Compare's not-scanned card says, given the persisted summary and where the panes point.
    ///
    /// The rule, not just the sentence: `ComparePrompt` owns the wording and `LastScanSummary`
    /// owns "is this the same comparison", but the DECISION to consult the summary at all lives
    /// here so a test can hold it. Inline in a view's computed property it had no reachable test,
    /// and the failure it guards against is silent — a count for the wrong pair of folders reads
    /// as current, which is worse than the cold "Nothing scanned yet" it replaces.
    static func notScannedMessage(summary: LastScanSummary?,
                                  leftProviderID: String, leftPath: String,
                                  rightProviderID: String, rightPath: String,
                                  now: Date) -> String {
        guard let summary,
              summary.describes(leftProviderID: leftProviderID, leftPath: leftPath,
                                rightProviderID: rightProviderID, rightPath: rightPath)
        else { return ComparePrompt.neverScanned }
        return ComparePrompt.lastScan(differenceCount: summary.differenceCount,
                                      date: summary.date, now: now)
    }

    /// The focused side after one pane-selection write — the mouse's half of the same fact ⌃⇥ sets.
    ///
    /// Extracted rather than written inline at the binding because the interesting case is the one
    /// that changes NOTHING: an empty write is a deselect, and a deselect is not leaving the pane.
    /// Moving focus there would send the next ⌘F back to the left-hand floor the moment you pressed
    /// Escape, which is the behaviour the focused side exists to end — and inline in a `Binding`'s
    /// setter that rule has no test that can reach it.
    static func focusedSideAfterSelectionWrite(_ newSelection: Set<String>,
                                               isLeft: Bool,
                                               current: PaneTree.Side?) -> PaneTree.Side? {
        guard !newSelection.isEmpty else { return current }
        return isLeft ? .left : .right
    }

    /// Where ⌃⇥ moves focus from the pane the chords act on now.
    ///
    /// Resolved from the *effective* target rather than from the stored `focusedSide`, so the first
    /// press always flips what is actually in effect. Flipping the stored value instead would make
    /// the first press a no-op for anyone whose focus is still implicit: `nil` has no opposite, and
    /// picking one arbitrarily lands on the pane the fallback had already chosen half the time.
    static func focusSwitchTarget(isSingleSource: Bool,
                                  focusedSide: PaneTree.Side?,
                                  activePane: ActivePane?) -> PaneTree.Side {
        searchTargetIsLeft(isSingleSource: isSingleSource,
                           focusedSide: focusedSide,
                           activePane: activePane) ? .right : .left
    }

    /// SF Symbols for the action bar's Copy/Move buttons, drawn from the shared `TransferGlyph`
    /// vocabulary so the toolbar, the Differences header, and the right-click menus can't drift.
    /// Copy is the universal duplicate glyph in every state — instantly recognizable, with its
    /// direction carried in the "Copy to <pane>" label since SF Symbols has no left-pointing copy
    /// glyph to pair with the right one. Move stays directional: a box-with-arrow pointing toward
    /// the pane the operation targets (opposite the selection), falling back to right-pointing
    /// when there is no selection yet.
    static func actionBarSymbols(activePane: ActivePane?) -> (copy: String, move: String) {
        switch activePane {
        case .left: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
        case .right: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: false))
        case nil: return (copy: TransferGlyph.copy, move: TransferGlyph.move(toRight: true))
        }
    }

    /// Reconciles a pane-selection write with the one-pane-selected invariant: setting a
    /// non-empty selection in one pane clears the other pane in the same update, so no
    /// consumer ever observes both panes selected. Setting an empty selection (a deselect,
    /// or SwiftUI re-writing an unchanged empty set) leaves the other pane alone — this is
    /// what keeps right-click context menus working, since right-click never sets selection
    /// and "Copy N items from other pane" needs the other pane's selection to survive.
    /// Only the FileTreeView selection bindings route through this; selection pruning and
    /// navigation resets write the manager's properties directly.
    static func reconciledSelections(
        settingSelection newSelection: Set<String>,
        isLeft: Bool,
        currentLeft: Set<String>,
        currentRight: Set<String>
    ) -> (left: Set<String>, right: Set<String>) {
        if isLeft {
            return (left: newSelection, right: newSelection.isEmpty ? currentRight : [])
        } else {
            return (left: newSelection.isEmpty ? currentLeft : [], right: newSelection)
        }
    }

    /// Applies one pane-selection write, enforcing the one-pane-selected invariant across the two
    /// halves of a click.
    ///
    /// The clicked pane commits **synchronously** — that is the write its `List` is waiting on, and
    /// clearing the sibling here instead reloads that List mid-commit and drops the click outright
    /// (the two-clicks-to-select bug, `aa9d407`). The other pane's clear is therefore handed to the
    /// next runloop turn.
    ///
    /// That deferral is only safe **while it is still the newest click**. The queued block writes a
    /// blind `[]` to the other pane, and it carries no memory of which pane the user is on by the
    /// time it runs. Click the left pane and then the right one before the first block drains, and
    /// the left's deferral wipes the selection the right click just made: the row un-highlights, the
    /// action bar never appears, and the click reads as ignored. `aa9d407` argued the two clicks
    /// always land in separate runloop turns "with this block draining between them" — true only
    /// while the main thread keeps up, which it does not once a click also rebuilds a Columns stack
    /// and mirrors it onto the linked pane.
    ///
    /// So every commit takes a token and a deferral stands down unless its token is still the
    /// newest. Standing down loses nothing: the newer click queued a deferral of its own, and that
    /// one clears the correct pane.
    ///
    /// `schedule` is injected so the ordering — not just the arithmetic — can be tested.
    @MainActor
    static func applySelectionWrite(
        _ newSelection: Set<String>,
        isLeft: Bool,
        state: PaneSelectionState,
        sequencer: PaneSelectionSequencer,
        schedule: (@escaping () -> Void) -> Void
    ) {
        let reconciled = reconciledSelections(
            settingSelection: newSelection,
            isLeft: isLeft,
            currentLeft: state.selectedLeftPaths,
            currentRight: state.selectedRightPaths
        )
        // Commit the clicked pane now — this is the write the List is waiting on.
        if isLeft {
            if state.selectedLeftPaths != reconciled.left { state.selectedLeftPaths = reconciled.left }
        } else {
            if state.selectedRightPaths != reconciled.right { state.selectedRightPaths = reconciled.right }
        }
        // A deselect (empty write) enforces nothing — leave the other pane untouched (this is what
        // keeps the right-click "Copy from other pane" menu working). It takes no token either: it
        // queues no deferral, so it has no newer-click race to lose, and letting it bump the counter
        // would cancel a live deferral without replacing it.
        guard !newSelection.isEmpty else { return }
        // The user just picked something in a pane, so the panes are what "the current file" means
        // until they pick something elsewhere. Guarded so a run of pane clicks publishes once
        // rather than per click — this is observed state, and the panes re-render off it.
        if state.lastSelectionSurface != .pane { state.lastSelectionSurface = .pane }
        let token = sequencer.commit()
        // Timing from here spans the button HOLD, not just work.
        //
        // This runs from the selection commit, which `NSTableView` performs on mouse-DOWN from
        // inside its own tracking loop, so the gap to the deferred block covers however long the
        // button stayed down. It was originally read as "the cost of the click" and reported
        // 230-720ms; rebuilding the app with optimisations left those numbers completely unchanged,
        // which is what exposed it — real computation would have moved. `PaneColumnsView`'s
        // `[render]` line starts after mouse-up and is the one to trust for cost. This stays because
        // press-to-settled is still what the user's hand experiences, but it is labelled for what it
        // is so nobody optimises against it again.
        let committed = CFAbsoluteTimeGetCurrent()
        schedule {
            let heldAndSettledMs = (CFAbsoluteTimeGetCurrent() - committed) * 1000
            let side = isLeft ? "left" : "right"
            guard sequencer.isNewest(token) else {
                Logger.shared.debug(
                    "[click] \(side) selection superseded before its cross-pane clear ran "
                    + "(press→settled \(Self.ms(heldAndSettledMs)), includes button hold)")
                return
            }
            if isLeft {
                if state.selectedRightPaths != reconciled.right { state.selectedRightPaths = reconciled.right }
            } else {
                if state.selectedLeftPaths != reconciled.left { state.selectedLeftPaths = reconciled.left }
            }
            Logger.shared.debug(
                "[click] \(side) pane selected \(newSelection.count) item(s), "
                + "press→settled \(Self.ms(heldAndSettledMs)) (includes button hold)")
        }
    }

    /// One decimal place, so a log line reads `412.4ms` rather than `412.35917663574219ms`.
    static func ms(_ value: Double) -> String { String(format: "%.1fms", value) }

    /// Lets go of the selection in **both** panes, for a plain click on a pane's empty space.
    ///
    /// Deliberately not routed through `applySelectionWrite`. That path treats an empty write as
    /// enforcing nothing and leaves the other pane alone on purpose — which is what keeps the
    /// right-click "Copy N items from other pane" menu working, since a right-click never sets a
    /// selection. A click on empty space is the opposite case: it is a deliberate "I am done with
    /// that", and the one-pane-selected invariant means the selection it dismisses usually lives in
    /// the pane the user did *not* just click. Clearing only the clicked side would leave the
    /// gesture looking dead on its most common path.
    ///
    /// Synchronous, and safely so: this runs from a click recognizer on mouse-UP, outside the
    /// mouse-down tracking loop an `NSTableView` commits its selection from. It is therefore not
    /// the mid-commit sibling write that dropped clicks in `aa9d407`, and it queues nothing that
    /// could go stale the way `94554e9`'s deferral did.
    @MainActor
    static func clearBothSelections(state: PaneSelectionState) {
        if !state.selectedLeftPaths.isEmpty { state.selectedLeftPaths = [] }
        if !state.selectedRightPaths.isEmpty { state.selectedRightPaths = [] }
    }

    /// The column stack a background click leaves behind, or nil when it changes nothing.
    ///
    /// Finder's rule: clicking a column's empty space closes the columns to its right but opens
    /// none — the same truncation a click on a *file* in that column performs, which is why both go
    /// through `PaneBrowsePath.truncate(toDepth:)`.
    ///
    /// `depth` is nil where there is no column to truncate to: Tree mode, the Tidy rail, and the
    /// dead space past the last column. Closing the stack from a click *past* it would be a
    /// navigation the user did not ask for.
    static func backgroundDeselectPath(from browsePath: PaneBrowsePath, depth: Int?) -> PaneBrowsePath? {
        guard let depth else { return nil }
        var path = browsePath
        path.truncate(toDepth: depth)
        return path == browsePath ? nil : path
    }

    /// The left pane wins when both panes have selections (it is checked first, matching
    /// the historical behavior of the details/actions targeting). The selection bindings
    /// enforce exclusivity via `reconciledSelections`, clearing the other pane one runloop
    /// tick after a pick lands, so a both-non-empty state can exist for at most a single
    /// frame — this left-wins tiebreak keeps that frame pointing at a real pane.
    static func activePane(leftSelection: Set<String>, rightSelection: Set<String>) -> ActivePane? {
        if !leftSelection.isEmpty { return .left }
        if !rightSelection.isEmpty { return .right }
        return nil
    }

    // `primarySelectionPath` lived here. The rule is now `CurrentSelection.primaryPanePath` in
    // `Sync`, where the Differences table and the Info inspector can reach it too — neither can see
    // `MacApp`, which is precisely why the inspector grew its own hand-written copy and drifted.
    // Left as a forwarder at first; deleted once it turned out no caller had survived the move, so
    // the only thing exercising it was a test pinning a pass-through.

    /// Whether Escape, pressed over a pane, should clear that pane's selection (and so swallow the
    /// key) rather than let it bubble to a dialog.
    ///
    /// The gate used to be the action bar's resolved selection alone — and that bar is hard-gated to
    /// COMPARE (`paneActionBarSideActive`), so on the single-source Tidy rail `hasActionBarSelection`
    /// is always false and Escape was always `.ignored`. The rail is precisely the surface that needs
    /// this most: it shows no action bar, so it has no ✕ either, and the file lists offer no deselect
    /// gesture — a folder picked there could never be un-picked, the exact state the Escape handler
    /// exists to prevent.
    ///
    /// Compare keeps the action-bar gate unchanged, deliberately: there, a selected path that no
    /// longer resolves to a node keeps the bar hidden, and Escape must stay `.ignored` in that state
    /// exactly as it did before.
    static func escapeClearsSelection(
        isSingleSource: Bool,
        hasActionBarSelection: Bool,
        paneHasSelection: Bool
    ) -> Bool {
        isSingleSource ? paneHasSelection : hasActionBarSelection
    }

    /// Which pane a single-source Tidy scan/inspect should target. The Tidy rail is always the LEFT
    /// pane, so in single-source mode the answer is always "left" — even when a selection lingers in
    /// the (hidden) right pane from a prior Compare session, which would otherwise make `activePane`
    /// resolve to `.right` and silently aim Tidy's scans (Find Duplicates / Organize / Rename /
    /// Storage) at the wrong provider while the rail shows the left one. In compare mode the focused
    /// pane still wins, so a Tidy scan launched from a Compare menu targets the pane the user is in.
    static func tidyTargetsRightPane(isCompare: Bool, activePane: ActivePane?) -> Bool {
        isCompare && activePane == .right
    }

    /// Builds a pane's full path from its provider root and in-pane relative path.
    /// An empty or absolute "relative" path yields just the root, so a stale or
    /// cross-provider relative path can never escape the pane's root.
    static func fullPath(root: String, relativePath: String) -> String {
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return expandedRoot }
        return (expandedRoot as NSString).appendingPathComponent(relativePath)
    }

    /// The folder a Tidy scan targets: the focus root, walked down to where the pane is
    /// **browsing**. Column clicks move `PaneBrowsePath`, not the pane's comparison focus — that
    /// split is deliberate (browsing must not rescan the comparison) but it left every Tidy scan
    /// and the "Scan '<folder>'" offer reading only the focus root, so clicking through columns
    /// never moved the target and the offer sat dead at the root no matter what was selected.
    ///
    /// At rest (no columns open) the focus root is returned **unchanged**, trailing slashes and
    /// all — the join below normalizes them, and normalizing a root nothing was joined onto would
    /// change paths for panes that never browsed.
    static func tidyScanRoot(focusRootExpanded root: String, browsePath: PaneBrowsePath) -> String {
        guard !root.isEmpty, !browsePath.isEmpty else { return root }
        return browsePath.currentDirectory(treeRoot: root)
    }

    /// The base path a pane's "Ignore in comparison" targets are measured against: that pane's
    /// OWN provider root (tilde-expanded) joined with that pane's OWN in-pane relative path.
    ///
    /// Extracted from `PaneActionDelegate.handleIgnore` because `relativeIgnoreTargets` — which is
    /// tested — is only as good as the base handed to it: pairing one side's root with the other
    /// side's focus, or forgetting the tilde expansion, yields relative paths that miss the base
    /// entirely and get stored verbatim as absolute paths in the durable per-pair ignore store,
    /// hiding the wrong files from every future comparison. An empty relative path means the pane
    /// is at its root, which is the root path itself.
    static func ignoreBasePath(
        isLeft: Bool,
        leftRoot: String,
        rightRoot: String,
        leftRelativePath: String,
        rightRelativePath: String
    ) -> String {
        let root = isLeft ? leftRoot : rightRoot
        let relativePath = isLeft ? leftRelativePath : rightRelativePath
        let expandedRoot = (root as NSString).expandingTildeInPath
        return relativePath.isEmpty
            ? expandedRoot
            : (expandedRoot as NSString).appendingPathComponent(relativePath)
    }

    /// Reduces absolute node paths to ignore targets relative to the pane's focal path,
    /// so an ignore set applies to both panes regardless of provider roots.
    /// Paths outside `basePath` are passed through unchanged. Stripping happens only at a
    /// path-component boundary — "/root/ab" is not a base of "/root/abc/x", so a sibling
    /// root that merely shares a string prefix can never alias into relative targets.
    static func relativeIgnoreTargets(nodeIds: [String], basePath: String) -> [String] {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return nodeIds.map { id in
            if id == base { return "" }
            guard id.hasPrefix(base + "/") else { return id }
            return String(id.dropFirst(base.count + 1))
        }
    }

    /// The provider ids the two panes should show after a left↔right swap: each id moves to
    /// the opposite side. Pure so ContentView's swap action and its test agree on the mapping
    /// without a running view. This is only the @AppStorage half of a pane swap; the manager's
    /// focused relative paths, selections, and navigation histories are swapped in lockstep by
    /// `FileSyncManager.swapPanes()`.
    static func swappedProviderIds(
        leftProviderId: String,
        rightProviderId: String
    ) -> (leftProviderId: String, rightProviderId: String) {
        (leftProviderId: rightProviderId, rightProviderId: leftProviderId)
    }

    // The "Ignore in comparison" toggle semantics moved to
    // `FileSyncManager.toggleIgnored(focusRelativePaths:)`, which also reconciles the
    // durable ignore store; its behavior is pinned by Sync's PersistentIgnoresTests.

    // MARK: - Window bootstrap

    /// One step of ContentView's `onAppear` bootstrap. The app is single-window, but closing
    /// the window and reopening it from the Dock recreates the ContentView, so `onAppear` runs
    /// again mid-session. Each step is therefore classified once-per-session vs per-window;
    /// `bootstrapSteps(isFirstAppearance:)` is the single source of that classification (pinned
    /// by tests), and the view executes whatever list it returns so the two can't drift.
    enum BootstrapStep: Equatable {
        /// Session: seed `showHiddenFiles` from the General default. Re-running on a window
        /// reopen would discard a mid-session toggle.
        case resetShowHiddenFilesFromDefault
        /// Session: the launch-time overlay diagnostics (`openSettingsOnLaunch`,
        /// `openCommandPaletteOnLaunch`) are launch hooks; a window reopen must not re-open an
        /// overlay the user has since dismissed.
        ///
        /// Plural since ⌘K: a palette is driven entirely by the keyboard and cannot be opened by
        /// a script — `System Events` keystroke needs assistive access, which this machine refuses
        /// — so a launch hook is the only way anything but a human can get it on screen to look at.
        case honorLaunchOverlayDiagnostics
        /// Window: `FileActionHandler` lives in view `@State`, so every fresh ContentView
        /// starts with nil and needs its own.
        case createActionHandler
        /// Window: each window brings a fresh `UndoManager`; the shared sync manager must
        /// register undos with the one actually on screen.
        case rewireUndoManager
        /// Session: seeds the manager from Settings once; the `onChange(of:)` observer keeps
        /// it current afterwards (both objects outlive the window).
        case syncProviderQuirkSettings
        /// Session: provider discovery, the distinct-pair pane selection, and the initial
        /// scan. Re-running would silently flip a deliberately-same right pane to a different
        /// provider and redo discovery + rescan over live state. Clears the view's
        /// provider-bootstrap guard when the discovery task finishes.
        case discoverProvidersAndApplyInitialSelection
        /// Window, re-appearance only: a recreated view's `isBootstrappingProviders` `@State`
        /// starts true, but no discovery is pending — clear it immediately, or provider
        /// switches and pane swaps stay refused for the rest of the session.
        case endProviderBootstrapGuard
    }

    /// The bootstrap steps to run for an appearance of ContentView, in execution order.
    static func bootstrapSteps(isFirstAppearance: Bool) -> [BootstrapStep] {
        if isFirstAppearance {
            return [
                .resetShowHiddenFilesFromDefault,
                .honorLaunchOverlayDiagnostics,
                .createActionHandler,
                .rewireUndoManager,
                .syncProviderQuirkSettings,
                .discoverProvidersAndApplyInitialSelection,
            ]
        }
        return [
            .createActionHandler,
            .rewireUndoManager,
            .endProviderBootstrapGuard,
        ]
    }

    // MARK: - Last-session pane focus

    /// One pane's reopen instruction: the relative path to focus and the absolute path it was
    /// validated at. `isLeft` names the pane so the caller's log line and `focusOn` can't disagree.
    struct PaneFocusRestore: Equatable {
        let relativePath: String
        let fullPath: String
        let isLeft: Bool
    }

    /// The panes to reopen on the folder they showed when the app last quit, in left-then-right
    /// order — the whole decision behind `ContentView.restoreLastPaneFocusIfEnabled`.
    ///
    /// A pane is restored only when the General setting is on, it has a remembered relative path,
    /// its provider root resolves, and the composed path still exists ON DISK as a DIRECTORY.
    /// Anything else is dropped, which leaves that pane at its provider root — the fallback. The
    /// composition is the risky part: every later operation in the session is expressed relative to
    /// the focus this sets, so a root/relative mix-up reopens the pane on the wrong folder and
    /// every subsequent relative path inherits the error.
    ///
    /// `isRestorableDirectory` defaults to the real check, hopped off the main actor because cloud
    /// provider roots stat slowly; tests pass their own to pin which paths get probed.
    static func paneFocusRestores(
        isEnabled: Bool,
        left: (relativePath: String, root: String),
        right: (relativePath: String, root: String),
        isRestorableDirectory: (String) async -> Bool = { path in
            await Task.detached(priority: .userInitiated) { () -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }.value
        }
    ) async -> [PaneFocusRestore] {
        guard isEnabled else { return [] }
        var restores: [PaneFocusRestore] = []
        for pane in [(left, true), (right, false)] {
            let (saved, isLeft) = pane
            guard !saved.relativePath.isEmpty, !saved.root.isEmpty else { continue }
            let fullPath = ((saved.root as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(saved.relativePath)
            guard await isRestorableDirectory(fullPath) else { continue }
            restores.append(PaneFocusRestore(relativePath: saved.relativePath,
                                             fullPath: fullPath,
                                             isLeft: isLeft))
        }
        return restores
    }

    // MARK: - Resize split layout

    /// Math for the two invisible resize dividers (the left↔right pane split and the panes↔bottom
    /// split). Kept pure and out of the `GeometryReader` view builders so the clamp guards — which
    /// are what stop a too-small window from inverting the split — are exercised by tests instead
    /// of only ever running against live geometry.

    /// The horizontal pane split's minimum fraction: the smallest share the left pane may take so
    /// it never shrinks below `minPane` points. Capped at 0.5 so a window narrower than 2×minPane
    /// degrades to an even split rather than demanding an impossible width — which would push the
    /// minimum past `1 - minFraction` and invert the clamp bounds — and 0 for a degenerate
    /// zero-width window so the arithmetic stays finite.
    static func horizontalMinFraction(totalWidth: CGFloat, minPane: CGFloat) -> Double {
        totalWidth > 0 ? min(0.5, Double(minPane / totalWidth)) : 0
    }

    /// The bottom (Differences/Details) pane's laid-out area: the total content height less the
    /// 1pt divider, floored at 0 so a collapsed window never yields a negative height.
    static func verticalPanesHeight(totalHeight: CGFloat, dividerHeight: CGFloat) -> CGFloat {
        max(0, totalHeight - dividerHeight)
    }

    /// The vertical split's minimum fraction — the bottom pane's smallest share, so it never drops
    /// below `minBottom` points. Capped at 0.85 (mirroring the horizontal rule) and 0 for a
    /// zero-height area.
    static func verticalMinFraction(panesHeight: CGFloat, minBottom: CGFloat) -> Double {
        panesHeight > 0 ? min(0.85, Double(minBottom / panesHeight)) : 0
    }

    /// The vertical split's maximum fraction so the top panes never drop below `minTop` points.
    /// The `max(minFraction, …)` floor is the important guard: when the window is too short to
    /// honor both mins at once, `1 - minTop/panesHeight` can fall below `minFraction`, which would
    /// invert the clamp bounds; keeping the upper bound at or above the lower one means the bottom
    /// pane's minimum wins that tie and the clamp still resolves to a sane fraction.
    static func verticalMaxFraction(panesHeight: CGFloat, minTop: CGFloat, minFraction: Double) -> Double {
        panesHeight > 0 ? max(minFraction, 1 - Double(minTop / panesHeight)) : 1
    }

    /// Clamps a desired split fraction into `[lower, upper]`. One shared helper so the laid-out
    /// fraction and the live drag gesture clamp identically. If the bounds are ever inverted
    /// (`upper < lower`, an over-constrained window) the outer `min` wins and the result pins to
    /// `upper` — the larger section's minimum is the one sacrificed.
    static func clampedFraction(_ desired: Double, lower: Double, upper: Double) -> Double {
        min(max(desired, lower), upper)
    }

    /// The split fraction implied by the cursor's absolute x within the pane row during a
    /// horizontal divider drag. The caller guards `totalWidth > 0` before calling.
    static func horizontalDragFraction(locationX: CGFloat, totalWidth: CGFloat) -> Double {
        Double(locationX / totalWidth)
    }

    /// The bottom-pane fraction implied by the cursor's absolute y during a vertical divider drag.
    /// The bottom pane grows as the cursor moves up, so the fraction is the cursor's distance from
    /// the bottom of the pane area, not its distance from the top. The caller guards
    /// `panesHeight > 0` before calling.
    static func verticalDragFraction(locationY: CGFloat, panesHeight: CGFloat) -> Double {
        Double((panesHeight - locationY) / panesHeight)
    }

    /// The Info inspector's minimum width — matches `DetailsSidebar`'s own `minWidth: 200` content
    /// floor, below which the metadata rows stop reflowing cleanly.
    static let inspectorMinWidth: Double = 200
    /// The inspector's maximum width, so a drag can't let the panel swallow the whole window and
    /// starve the comparison panes. A fixed cap (rather than a window-relative one) keeps the math
    /// pure and geometry-free; the flexible panes absorb whatever is left.
    static let inspectorMaxWidth: Double = 600

    /// The inspector width during a resize drag. The handle sits on the panel's leading (left)
    /// edge, so dragging left (`translation` negative) widens it. `base` is the width at drag start
    /// — held constant for the whole gesture since it's only committed to storage on release — and
    /// `translation` is the gesture's cumulative horizontal translation. Clamped to
    /// `[inspectorMinWidth, inspectorMaxWidth]` so the same guard runs in tests, not only live.
    static func inspectorDragWidth(base: Double, translation: CGFloat) -> Double {
        min(max(base - Double(translation), inspectorMinWidth), inspectorMaxWidth)
    }

    /// Whether the kept LEFT copy of a duplicate review is still where — AND what — the scan
    /// saw it, mirroring the engine's `keeperStillExists` gate (FileSyncManager+Duplicates)
    /// that every other duplicate-removal path honors: existence, plus for FILES a byte-size
    /// comparison against the scan snapshot. An in-place edit or replacement changes the size,
    /// and the "redundant" right copy is then no longer provably identical to the keeper —
    /// trashing it could trash the last copy of the original content. Folders keep the
    /// existence-only check (a folder's stat size isn't its recursive content size).
    ///
    /// `statSucceeded: false` (the attributes read threw) refuses for a file, exactly like the
    /// engine's failed-attributes guard; `currentSize` nil with a successful stat (never happens
    /// on the real FS) falls back to the existence check rather than over-refuse — also like
    /// the engine.
    static func duplicateKeeperMatchesScan(
        exists: Bool,
        isDirectory: Bool,
        statSucceeded: Bool,
        currentSize: Int?,
        scannedSize: Int
    ) -> Bool {
        guard exists else { return false }
        guard !isDirectory else { return true }
        guard statSucceeded else { return false }
        if let currentSize, currentSize != scannedSize { return false }
        return true
    }
}
