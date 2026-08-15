import SwiftUI
import Design
import FileExplorer
import Sync

// MARK: - Menu-bar shortcuts
//
// Every chord in the ⌥-reveal follow-up lands here as a MENU ITEM, on the `FindInPaneCommand`
// pattern: the window publishes what each item needs through `.focusedSceneValue`, the item reads
// it with `@FocusedValue`, and `nil` renders it disabled. A menu item is the only form that (a)
// fires no matter where focus sits — a focus-scoped `.onKeyPress` never sees a key while focus is
// in a file table, which is where it always is — and (b) documents itself in the menu bar.
//
// None of these may ever move into a per-row context menu: a `.keyboardShortcut` there registers
// one key equivalent PER ROW.
//
// Deliberate, and documented at `ShortcutRevealMachine`: none of these chords can fire *through*
// the ⌥-hold reveal (⌘R arrives as ⌥⌘R and matches nothing) — look, release, press. That holds
// only while no registered chord contains ⌥, which is why fold-all is ⇧⌘F and not ⌥⌘F: the
// first cut used ⌥⌘F, and a user reading the magnifier's ⌘F badge who pressed ⌘F while still
// holding ⌥ folded every folder. `AppChordTests` guards the no-⌥ invariant itself.

// MARK: Focused values published by ContentView

private struct WorkspaceSelectionKey: FocusedValueKey {
    typealias Value = Binding<Workspace>
}

private struct PaneGoBackKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PaneGoForwardKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RescanPanesKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct NewFolderInFocusedPaneKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ShowHiddenFilesKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct PreviewColumnKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct InfoInspectorKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct DifferencesListVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct DeleteSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SwitchPaneFocusKey: FocusedValueKey {
    typealias Value = PaneFocusSwitch
}

private struct NewTabKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CloseTabKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CycleTabKey: FocusedValueKey {
    typealias Value = (Bool) -> Void
}

private struct ReopenClosedTabKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct TabBarVisibleKey: FocusedValueKey {
    typealias Value = TabBarSwitch
}

/// View ▸ Tab Bar's state, which a `Binding<Bool>` cannot carry.
///
/// The switch has THREE states, not two: off, on, and **on-because-a-second-tab-is-open** — where
/// it is ticked and disabled, so it can never hide a strip whose tabs would then be unreachable.
/// A nil binding (how every other view switch in this file spells "disabled") renders unticked and
/// disabled, which would show the tab bar's switch OFF while a tab bar is on screen.
struct TabBarSwitch {
    let isOn: Bool
    /// A second tab is open: the strip is on screen whatever the preference says.
    let isForced: Bool
    let set: (Bool) -> Void

    /// The rule, as a value: a second tab forces the switch on and freezes it there.
    ///
    /// Extracted so it can be tested — `ContentView` is a `View` with `@State` and cannot be
    /// instantiated in a test — and pinned at its call site by
    /// `PaneTabWiringTests.theTabBarSwitchIsResolvedThroughTheRule`, because a rule nothing calls
    /// is one revert away from being decoration.
    static func resolve(hasSecondTab: Bool, preference: Bool,
                        set: @escaping (Bool) -> Void) -> TabBarSwitch {
        TabBarSwitch(isOn: hasSecondTab || preference, isForced: hasSecondTab, set: set)
    }
}

/// ⌃⇥'s payload: where it will move focus, and doing it.
///
/// The name travels with the action for the same reason `FoldAllAction` carries its verb — the menu
/// item is the only resting surface that says which pane is focused now, so it has to read "Focus
/// Dropbox" rather than "Switch Pane". A menu title that named neither pane would leave the state
/// completely unreadable.
/// Not `Equatable`, matching `FoldAllShortcut` — a focused value needs no equality, and the
/// hand-written one this used to carry compared only `targetName`, so two switches pointing at
/// different panes' closures could compare equal. An `==` nothing calls and that cannot be right
/// is worse than none.
struct PaneFocusSwitch {
    /// The pane this moves focus TO, by its provider display name.
    let targetName: String
    /// What the item reads instead of "Focus <pane>", when the chord is not a pane switch at all.
    ///
    /// **⌃⇥ means two different things, and it has to.** In Compare it moves focus between the two
    /// panes; in Browse there is only one pane, so the chord is dead there — which is exactly why
    /// the v4.x roadmap scopes tab cycling onto it rather than spending a new chord. One key, one
    /// menu item, and a title that says which of the two you are about to get.
    let overrideTitle: String?
    let run: () -> Void

    init(targetName: String, overrideTitle: String? = nil, run: @escaping () -> Void) {
        self.targetName = targetName
        self.overrideTitle = overrideTitle
        self.run = run
    }

    /// Browse's form: the chord cycles this pane's tabs, and the item says so.
    static func nextTab(run: @escaping () -> Void) -> PaneFocusSwitch {
        PaneFocusSwitch(targetName: "", overrideTitle: "Next Tab", run: run)
    }

    /// The menu item's title. A rule rather than an inline ternary because it is the ONLY resting
    /// answer to "which pane is focused?" — the panes carry no indicator — so it is worth a test.
    /// The `nil` form is what a disabled item shows: it names no pane, because there is no second
    /// pane to name on a single-source workspace.
    static func menuTitle(for focus: PaneFocusSwitch?) -> String {
        guard let focus else { return "Focus Other Pane" }
        return focus.overrideTitle ?? "Focus \(focus.targetName)"
    }
}

extension FocusedValues {
    /// The workspace bar's selection, as the same binding the segments write — going through it
    /// (never `selectedWorkspace` directly) is what re-homes the single-source rail on a switch.
    var workspaceSelection: Binding<Workspace>? {
        get { self[WorkspaceSelectionKey.self] }
        set { self[WorkspaceSelectionKey.self] = newValue }
    }

    /// Back in the focused pane; `nil` when its history has nowhere to go.
    var paneGoBack: (() -> Void)? {
        get { self[PaneGoBackKey.self] }
        set { self[PaneGoBackKey.self] = newValue }
    }

    /// Forward in the focused pane; `nil` when its history has nowhere to go.
    var paneGoForward: (() -> Void)? {
        get { self[PaneGoForwardKey.self] }
        set { self[PaneGoForwardKey.self] = newValue }
    }

    /// The pane bar's scan action — global, both trees. `nil` while a scan is running, matching
    /// the rung's own `.disabled(isRefreshing)`.
    var rescanPanes: (() -> Void)? {
        get { self[RescanPanesKey.self] }
        set { self[RescanPanesKey.self] = newValue }
    }

    /// New folder in the focused pane's current folder — in Columns, the deepest open column,
    /// the same target the pane-bar rung resolves.
    var newFolderInFocusedPane: (() -> Void)? {
        get { self[NewFolderInFocusedPaneKey.self] }
        set { self[NewFolderInFocusedPaneKey.self] = newValue }
    }

    /// The hidden-files filter — one switch for both panes (`FileSyncManager.showHiddenFiles`).
    var showHiddenFiles: Binding<Bool>? {
        get { self[ShowHiddenFilesKey.self] }
        set { self[ShowHiddenFilesKey.self] = newValue }
    }

    /// The Columns preview column — one preference shared by every pane. `nil` while the focused
    /// pane's view mode has no preview to toggle, matching the pill's own withholding.
    var previewColumn: Binding<Bool>? {
        get { self[PreviewColumnKey.self] }
        set { self[PreviewColumnKey.self] = newValue }
    }

    /// The Info inspector, animated exactly as the toolbar button animates it.
    var infoInspector: Binding<Bool>? {
        get { self[InfoInspectorKey.self] }
        set { self[InfoInspectorKey.self] = newValue }
    }

    /// The differences list, in VISIBLE sense (the stored flag is "collapsed"). `nil` when the
    /// list is not on screen or a guided review owns it — the chevron's own withholding rules.
    var differencesListVisible: Binding<Bool>? {
        get { self[DifferencesListVisibleKey.self] }
        set { self[DifferencesListVisibleKey.self] = newValue }
    }

    /// Confirm-and-delete for the active pane's selection; `nil` with nothing selected.
    var deleteSelection: (() -> Void)? {
        get { self[DeleteSelectionKey.self] }
        set { self[DeleteSelectionKey.self] = newValue }
    }

    /// Moves the pane-scoped chords to the other comparison pane; `nil` on a single-source
    /// workspace, which has no other pane.
    var switchPaneFocus: PaneFocusSwitch? {
        get { self[SwitchPaneFocusKey.self] }
        set { self[SwitchPaneFocusKey.self] = newValue }
    }

    /// ⌘T — a new tab on the focused pane, at the folder it is showing.
    var newTab: (() -> Void)? {
        get { self[NewTabKey.self] }
        set { self[NewTabKey.self] = newValue }
    }

    /// ⌘W. Never `nil` while a pane exists: on the last tab it closes the WINDOW, as Finder does,
    /// so the item must stay enabled rather than becoming a dead ⌘W.
    var closeTab: (() -> Void)? {
        get { self[CloseTabKey.self] }
        set { self[CloseTabKey.self] = newValue }
    }

    /// ⇧⌘] / ⇧⌘[ — `true` is forward. One value for both directions, so a pane that cannot cycle
    /// disables the pair together.
    var cycleTab: ((Bool) -> Void)? {
        get { self[CycleTabKey.self] }
        set { self[CycleTabKey.self] = newValue }
    }

    /// File ▸ Reopen Closed Tab; `nil` when nothing has been closed this session.
    var reopenClosedTab: (() -> Void)? {
        get { self[ReopenClosedTabKey.self] }
        set { self[ReopenClosedTabKey.self] = newValue }
    }

    /// View ▸ Tab Bar.
    var tabBarVisible: TabBarSwitch? {
        get { self[TabBarVisibleKey.self] }
        set { self[TabBarVisibleKey.self] = newValue }
    }
}

// MARK: - ContentView's half

/// Every focused-value publication `ContentView` makes, bundled into one modifier with each field
/// explicitly typed. Not organizational: chained inline in `ContentView.body` — an expression the
/// compiler already strains under — the ternaries and property references pushed type-checking
/// past its time limit and failed the build. Stored properties give inference nothing to solve.
///
/// **Everything belongs in here**, which is the other half of the reason it exists: a value
/// published outside it is a value nobody thinks to suspend, and both chords that have been found
/// tunnelling under the destination picker (⌘K, then ⌘F) were published on their own. No count is
/// stated — the list below is the content, and a number beside it only goes stale.
struct ShortcutValuePublisher: ViewModifier {
    let workspace: Binding<Workspace>
    let goBack: (() -> Void)?
    let goForward: (() -> Void)?
    let rescan: (() -> Void)?
    let newFolder: (() -> Void)?
    let hiddenFiles: Binding<Bool>
    let previewColumn: Binding<Bool>?
    let inspector: Binding<Bool>
    let differencesList: Binding<Bool>?
    let delete: (() -> Void)?
    let switchPaneFocus: PaneFocusSwitch?
    /// ⌘K. **Published through here rather than on its own**, which is the whole reason this type
    /// exists: it was hung directly off `ContentView.body` and so was the one chord the suspension
    /// below did not reach. With the destination picker up — an in-flight file operation waiting on
    /// an answer — ⌘K still opened the palette over it, and a route from there switched workspace
    /// mid-pick. Exactly the tunnelling every other chord is suspended to prevent.
    ///
    /// It is suspended while the palette itself is up too, and that is correct rather than a side
    /// effect: the panel owns the chord then, through the event monitor in `CommandPalettePanel`,
    /// so a live menu item would be a second path to one act.
    let commandPalette: (() -> Void)?
    /// ⌘F, here for the same reason ⌘K is. It was published straight off `ContentView.body` —
    /// never nil, never suspended — which is precisely the shape `commandPalette`'s note above
    /// condemns. With the destination picker up, ⌘F expanded the focused pane's search field
    /// underneath the scrim and `ExpandingSearchField` took focus on appear, so the typing, the ↩
    /// and the esc that were meant for the pick went to a field the mouse is blocked from
    /// reaching.
    ///
    /// The convention that ⌘F stays live under Settings, Help and the first-run tour is untouched:
    /// those are ambient panels and do not set `suspended`. This is about the overlay that owns
    /// the keyboard.
    ///
    /// It is now also suspended **while the palette itself is up**, which the move brought with it:
    /// `suspended` carries both reasons. That is right rather than incidental — the panel owns the
    /// keyboard then, and the palette offers its own Find action that calls `beginPaneSearch()`
    /// after it dismisses — but it is a second behaviour change and worth naming.
    let beginPaneSearch: (() -> Void)?

    // The tab chords. All five suspend with the rest: a destination picker is up because an
    // in-flight file operation is waiting on an answer, and a tab switch under it would move the
    // pane the pick is describing.
    let newTab: (() -> Void)?
    /// Never `nil` while a pane exists — on the last tab it closes the WINDOW, which is what
    /// Finder's ⌘W does and what keeps this from being a chord that dies at one tab.
    let closeTab: (() -> Void)?
    let cycleTab: ((Bool) -> Void)?
    let reopenClosedTab: (() -> Void)?
    let tabBar: TabBarSwitch?

    /// True while the destination picker is up. The picker is a full-window overlay that
    /// deliberately blocks the mouse from every control these chords mirror — an in-flight
    /// file operation is waiting on an answer — but focused values are published by the still-
    /// mounted content underneath, so without this the keyboard tunnels straight past it:
    /// ⌘R republishes both trees mid-pick, ⇧⌘. flips the filters the pick is browsing, ⌘⌫
    /// pops a second modal over the decision. Suspended, every item disables at once.
    ///
    /// Settings/Help/first-run are NOT suspended, on the app's existing convention: they are
    /// ambient panels, and ⌘F, ⌘Z and ⌘, have always stayed live underneath them.
    let suspended: Bool

    /// The suspension applied — what actually gets published. Split from the stored values so
    /// a test can hold the rule without a scene: `suspended` must silence every one of these.
    var effectiveWorkspace: Binding<Workspace>? { suspended ? nil : workspace }
    var effectiveGoBack: (() -> Void)? { suspended ? nil : goBack }
    var effectiveGoForward: (() -> Void)? { suspended ? nil : goForward }
    var effectiveRescan: (() -> Void)? { suspended ? nil : rescan }
    var effectiveNewFolder: (() -> Void)? { suspended ? nil : newFolder }
    var effectiveHiddenFiles: Binding<Bool>? { suspended ? nil : hiddenFiles }
    var effectivePreviewColumn: Binding<Bool>? { suspended ? nil : previewColumn }
    var effectiveInspector: Binding<Bool>? { suspended ? nil : inspector }
    var effectiveDifferencesList: Binding<Bool>? { suspended ? nil : differencesList }
    var effectiveDelete: (() -> Void)? { suspended ? nil : delete }
    var effectiveSwitchPaneFocus: PaneFocusSwitch? { suspended ? nil : switchPaneFocus }
    var effectiveCommandPalette: (() -> Void)? { suspended ? nil : commandPalette }
    var effectiveBeginPaneSearch: (() -> Void)? { suspended ? nil : beginPaneSearch }
    var effectiveNewTab: (() -> Void)? { suspended ? nil : newTab }
    var effectiveCloseTab: (() -> Void)? { suspended ? nil : closeTab }
    var effectiveCycleTab: ((Bool) -> Void)? { suspended ? nil : cycleTab }
    var effectiveReopenClosedTab: (() -> Void)? { suspended ? nil : reopenClosedTab }
    var effectiveTabBar: TabBarSwitch? { suspended ? nil : tabBar }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.workspaceSelection, effectiveWorkspace)     // ⌘1…⌘N, one per workspace
            .focusedSceneValue(\.paneGoBack, effectiveGoBack)                // ⌘[
            .focusedSceneValue(\.paneGoForward, effectiveGoForward)          // ⌘]
            .focusedSceneValue(\.rescanPanes, effectiveRescan)               // ⌘R
            .focusedSceneValue(\.newFolderInFocusedPane, effectiveNewFolder) // ⇧⌘N
            .focusedSceneValue(\.showHiddenFiles, effectiveHiddenFiles)      // ⇧⌘.
            .focusedSceneValue(\.previewColumn, effectivePreviewColumn)      // ⇧⌘P
            .focusedSceneValue(\.infoInspector, effectiveInspector)          // ⌘I
            .focusedSceneValue(\.differencesListVisible, effectiveDifferencesList)  // ⌘D
            .focusedSceneValue(\.deleteSelection, effectiveDelete)           // ⌘⌫
            .focusedSceneValue(\.switchPaneFocus, effectiveSwitchPaneFocus)  // ⌃⇥
            .focusedSceneValue(\.commandPalette, effectiveCommandPalette)     // ⌘K
            .focusedSceneValue(\.beginPaneSearch, effectiveBeginPaneSearch)   // ⌘F
            .focusedSceneValue(\.newTab, effectiveNewTab)                     // ⌘T
            .focusedSceneValue(\.closeTab, effectiveCloseTab)                 // ⌘W
            .focusedSceneValue(\.cycleTab, effectiveCycleTab)                 // ⇧⌘] / ⇧⌘[
            .focusedSceneValue(\.reopenClosedTab, effectiveReopenClosedTab)   // File ▸ Reopen Closed Tab
            .focusedSceneValue(\.tabBarVisible, effectiveTabBar)              // ⇧⌘T
    }
}

extension ContentView {
    var shortcutValuePublisher: ShortcutValuePublisher {
        ShortcutValuePublisher(
            workspace: workspaceSelection,
            goBack: shortcutGoBack,
            goForward: shortcutGoForward,
            rescan: shortcutRescan,
            newFolder: shortcutNewFolder,
            hiddenFiles: $syncManager.showHiddenFiles,
            previewColumn: shortcutPreviewColumn,
            inspector: shortcutInfoInspector,
            differencesList: shortcutDifferencesList,
            delete: shortcutDeleteSelection,
            switchPaneFocus: switchPaneFocusAction,
            commandPalette: toggleCommandPalette,
            beginPaneSearch: beginPaneSearch,
            newTab: { openNewTabHere(isLeft: shortcutTabTargetIsLeft) },
            closeTab: shortcutCloseTab,
            cycleTab: shortcutCycleTab,
            reopenClosedTab: shortcutReopenClosedTab,
            tabBar: shortcutTabBar,
            // Suspended by the palette too, on the destination picker's own argument: it is a
            // full-window overlay whose scrim blocks the mouse from every control these chords
            // mirror, so without this ⌘R rescans underneath it and ⇧⌘. flips the filters behind
            // the field you are typing into. Unlike Settings and Help — ambient panels the app
            // deliberately keeps its chords live under — this one OWNS the keyboard while it is up.
            //
            // **⌘K is suspended with the rest, not exempt from it.** An earlier version of this note
            // said ⌘K "stays live (its own focused value) so the toggle can close it"; `a1c96082`
            // moved ⌘K into this publisher and that stopped being true. Closing the palette is the
            // panel's own keyDown monitor's job (`CommandPalettePanel.present`), not the menu
            // item's — the item is disabled for exactly as long as the palette is up.
            //
            // Suspending the *publication* is not the same as suspending the *act*:
            // `toggleCommandPalette` carries its own `pendingDestination` guard, because the toolbar
            // pill and the armed-on-launch path call it without going through a focused value.
            suspended: pendingDestination != nil || showCommandPalette
        )
    }

    var shortcutRescan: (() -> Void)? {
        isScanning ? nil : forceRefreshAction
    }
    /// The pane the pane-scoped chords act on — the same rule ⌘F resolves its field with, so
    /// "the focused pane" can never mean two different panes to two different shortcuts.
    private var shortcutTargetIsLeft: Bool { paneSearchTargetIsLeft }

    /// …and the same rule for the tab chords, named separately only so this file reads as what it
    /// is: a tab acts on the pane its strip belongs to, which is the focused one.
    var shortcutTabTargetIsLeft: Bool { paneSearchTargetIsLeft }

    /// ⌘W. Always live: on the last tab it closes the window, which is Finder's behaviour and the
    /// reason this is not withheld at one tab.
    var shortcutCloseTab: (() -> Void)? {
        let isLeft = shortcutTabTargetIsLeft
        return { closeTab(id: syncManager.paneTabs(isLeft: isLeft).active.id, isLeft: isLeft) }
    }

    /// ⇧⌘] / ⇧⌘[. `nil` at one tab — there is nowhere to cycle to, and a live item would be a
    /// chord that silently does nothing.
    var shortcutCycleTab: ((Bool) -> Void)? {
        let isLeft = shortcutTabTargetIsLeft
        guard syncManager.paneTabs(isLeft: isLeft).count > 1 else { return nil }
        return { forward in cycleTab(forward: forward, isLeft: isLeft) }
    }

    var shortcutReopenClosedTab: (() -> Void)? {
        let isLeft = shortcutTabTargetIsLeft
        guard syncManager.paneTabs(isLeft: isLeft).canReopen else { return nil }
        return { reopenClosedTab(isLeft: isLeft) }
    }

    /// View ▸ Tab Bar — **ticked and disabled while the pane holds a second tab**, so the switch
    /// can never hide a strip whose tabs would then be unreachable.
    var shortcutTabBar: TabBarSwitch {
        TabBarSwitch.resolve(
            hasSecondTab: syncManager.paneTabs(isLeft: shortcutTabTargetIsLeft).showsStrip,
            preference: tabBarVisible) { tabBarVisible = $0 }
    }

    var shortcutGoBack: (() -> Void)? {
        let isLeft = shortcutTargetIsLeft
        guard syncManager.canGoBack(isLeft: isLeft) else { return nil }
        return { syncManager.goBack(isLeft: isLeft) }
    }

    var shortcutGoForward: (() -> Void)? {
        let isLeft = shortcutTargetIsLeft
        guard syncManager.canGoForward(isLeft: isLeft) else { return nil }
        return { syncManager.goForward(isLeft: isLeft) }
    }

    /// One resolution of "where does a new folder go", shared by the pane-bar rung and ⇧⌘N:
    /// the pane's current folder, which in Columns is the deepest open column.
    func beginNewFolder(isLeft: Bool) {
        let pane = paneContext(isLeft: isLeft)
        let target = pane.viewMode == .columns
            ? (isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath)
                .currentDirectory(treeRoot: pane.currentPath)
            : pane.currentPath
        actionHandler?.beginCreateFolder(in: target)
    }

    var shortcutNewFolder: (() -> Void)? {
        guard actionHandler != nil else { return nil }
        let isLeft = shortcutTargetIsLeft
        return { beginNewFolder(isLeft: isLeft) }
    }

    var shortcutPreviewColumn: Binding<Bool>? {
        // Through the resolver, like every other reader of "which presentation is on screen".
        // Spelled out here as its own ternary, this was the third surface and the one that got
        // missed: in Browse it asked the RAIL's mode, so ⇧⌘P offered the preview column according
        // to a stack the user was not looking at — dead in Browse-Columns whenever the rail was in
        // Tree, and live in Browse-Tree whenever the rail was in Columns.
        let mode = resolvedViewModeBinding(isLeft: shortcutTargetIsLeft)
        guard PaneViewMode.showsPreviewToggle(mode: mode.wrappedValue) else { return nil }
        // Resolved the same way, for the same reason: Browse keeps its own preview preference, so a
        // chord hardwired to the shared key would turn Compare's preview off from a Browse window.
        return resolvedPreviewBinding
    }

    /// The same 0.15s ease the toolbar button wraps its toggle in — a menu item skipping the
    /// animation would make ⌘I feel like a different control from the button it badges.
    var shortcutInfoInspector: Binding<Bool> {
        Binding(
            get: { showInspector },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.15)) { showInspector = newValue }
            }
        )
    }

    var shortcutDifferencesList: Binding<Bool>? {
        guard compareBottomListActive, !reviewStore.isReviewing else { return nil }
        return Binding(
            get: { !bottomPaneCollapsed },
            set: { bottomPaneCollapsed = !$0 }
        )
    }

    var shortcutDeleteSelection: (() -> Void)? {
        // The review card's plain ⌫ means "skip this item" — one modifier away from ⌘⌫ meaning
        // "delete files", on the same keyboard the card owns. The card's surface takes the
        // keys during a session; the pane bar's Delete button stays clickable, as before.
        guard layoutMode == .compare, actionHandler != nil, !reviewStore.isReviewing else { return nil }
        guard !activeSelectionNodes.isEmpty else { return nil }
        // Fire-time resolution, deliberately not a captured array: a menu held open in
        // menu-tracking mode is not re-armed by a republish, so a snapshot could name rows a
        // background bulk sync has since replaced. Reading at fire keeps the destructive path
        // on live state; an emptied selection resolves to `[]`, which `confirmDelete` refuses.
        return { actionHandler?.confirmDelete(activeSelectionNodes) }
    }
}

// MARK: - The menu items

/// View ▸ the workspaces, one ⌘-digit each in bar order. `Toggle`s, so the menu carries the checkmark
/// a `Picker` would have given for free — a `Picker` can't put a distinct chord on each option.
///
/// The chords come from POSITION in `Workspace.allCases`, so adding Browse at the head shifted
/// every other workspace's number by one. That is the cost of numbering by position, and it is
/// the right cost: the badge on each segment is generated the same way, so the menu and the bar
/// cannot disagree about which key opens what.
struct WorkspaceCommands: View {
    @FocusedValue(\.workspaceSelection) private var selection

    var body: some View {
        ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
            Toggle(workspace.title, isOn: Binding(
                get: { selection?.wrappedValue == workspace },
                // Clicking the already-checked item asks to UN-select a workspace, which has no
                // meaning here — one of them is always current — so `false` is dropped.
                set: { isOn in if isOn { selection?.wrappedValue = workspace } }
            ))
            .keyboardShortcut(AppChord.workspace(index + 1).key, modifiers: AppChord.workspace(index + 1).modifiers)
            .disabled(selection == nil)
        }
    }
}

struct GoBackCommand: View {
    @FocusedValue(\.paneGoBack) private var go

    var body: some View {
        Button("Back") { go?() }
            .keyboardShortcut(AppChord.paneBack.key, modifiers: AppChord.paneBack.modifiers)
            .disabled(go == nil)
    }
}

struct GoForwardCommand: View {
    @FocusedValue(\.paneGoForward) private var go

    var body: some View {
        Button("Forward") { go?() }
            .keyboardShortcut(AppChord.paneForward.key, modifiers: AppChord.paneForward.modifiers)
            .disabled(go == nil)
    }
}

struct RescanCommand: View {
    @FocusedValue(\.rescanPanes) private var rescan

    var body: some View {
        Button("Rescan") { rescan?() }
            .keyboardShortcut(AppChord.rescan.key, modifiers: AppChord.rescan.modifiers)
            .disabled(rescan == nil)
    }
}

struct NewFolderCommand: View {
    @FocusedValue(\.newFolderInFocusedPane) private var newFolder

    var body: some View {
        // Ellipsis: it opens the name field, it doesn't create anything yet.
        Button("New Folder…") { newFolder?() }
            .keyboardShortcut(AppChord.newFolder.key, modifiers: AppChord.newFolder.modifiers)
            .disabled(newFolder == nil)
    }
}

struct DeleteSelectionCommand: View {
    @FocusedValue(\.deleteSelection) private var delete

    /// Whether the ⌘⌫ keystroke belongs to the text being edited rather than to this item.
    ///
    /// ⌘⌫ is also NSText's delete-to-beginning-of-line, and a menu key equivalent outranks the
    /// field editor — so with files selected (the normal state) and the caret in the pane
    /// search, a rename field, or the differences search, ⌘⌫-to-clear-the-line would confirm-
    /// delete the selection instead. Worse than surprising: with "Confirm before deleting" off,
    /// `confirmDelete` deletes immediately, silently, from a text-editing keystroke. Finder
    /// ships exactly this wart; it is not worth importing.
    ///
    /// Static and injected so the routing rule is testable — the live check reads the key
    /// window's first responder, which is the field editor (an `NSTextView`) whenever any text
    /// field has the caret.
    static func chordBelongsToTextEditor(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    var body: some View {
        // Ellipsis: the action confirms before touching anything (`NativeAlerts.confirmDelete`).
        Button("Delete Selection…") {
            if Self.chordBelongsToTextEditor(NSApp.keyWindow?.firstResponder) {
                // Hand the editing action back to the editor the equivalent took it from.
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.deleteToBeginningOfLine(nil)
            } else {
                delete?()
            }
        }
        .keyboardShortcut(AppChord.deleteSelection.key, modifiers: AppChord.deleteSelection.modifiers)
        .disabled(delete == nil)
    }
}

/// Go ▸ Focus <the other pane>, ⌃⇥.
///
/// The title names the destination — resolved from the same rule the chord acts on, exactly as
/// `FoldAllDifferencesCommand` takes its verb from the header's resolved `FoldAllAction` — so the
/// menu bar is where "which pane is focused?" can be answered at rest. Without that the state is
/// invisible: the panes carry no focus indicator, so a title reading "Switch Pane" would say
/// nothing about where you are or where you would end up.
struct SwitchPaneFocusCommand: View {
    @FocusedValue(\.switchPaneFocus) private var focus

    var body: some View {
        Button(PaneFocusSwitch.menuTitle(for: focus)) { focus?.run() }
            .keyboardShortcut(AppChord.switchPaneFocus.key, modifiers: AppChord.switchPaneFocus.modifiers)
            .disabled(focus == nil)
    }
}

// MARK: Tabs

struct NewTabCommand: View {
    @FocusedValue(\.newTab) private var newTab

    var body: some View {
        // **"New Tab", not "New Tab Here".** The roadmap's Fig. 9 names the menu item plainly and
        // puts the "here" on the ＋'s tooltip, which is the control that needs it: a File-menu item
        // reading "New Tab Here" asks the reader to wonder where "here" is before they have a strip
        // to look at.
        Button("New Tab") { newTab?() }
            .keyboardShortcut(AppChord.newTab.key, modifiers: AppChord.newTab.modifiers)
            .disabled(newTab == nil)
    }
}

/// ⌘W — and **it replaces File ▸ Close, so it has to still close things this app's tabs know
/// nothing about.**
///
/// The app has three auxiliary `Window` scenes (Keyboard Shortcuts, Activity Log, Sync History).
/// None of them publishes a focused value, so with one of them key this item's value is `nil` — and
/// as a plain `.disabled(close == nil)` item it left ⌘W dead in all three, having taken the standard
/// Close group's place. That is a regression the tab feature has no business causing, so a `nil`
/// value falls back to what the item replaced: close the key window.
///
/// The same fallback covers the suspended case (a destination pick is up), where ⌘W closing the
/// window is exactly what it did before this existed.
struct CloseTabCommand: View {
    @FocusedValue(\.closeTab) private var close

    /// What ⌘W does when nothing publishes a tab to close.
    ///
    /// Static and injectable so the rule can be tested: the live path reads the key window, which a
    /// unit test has none of.
    static func run(_ close: (() -> Void)?, closeWindow: () -> Void) {
        if let close { close() } else { closeWindow() }
    }

    var body: some View {
        // Never disabled — see above. The title stays "Close Tab" because the main window is where
        // this is ever read; on an auxiliary window the menu item is a chord, not a label anyone
        // goes looking for.
        Button("Close Tab") {
            Self.run(close) { NSApp.keyWindow?.performClose(nil) }
        }
        .keyboardShortcut(AppChord.closeTab.key, modifiers: AppChord.closeTab.modifiers)
    }
}

struct NextTabCommand: View {
    @FocusedValue(\.cycleTab) private var cycle

    var body: some View {
        Button("Next Tab") { cycle?(true) }
            .keyboardShortcut(AppChord.nextTab.key, modifiers: AppChord.nextTab.modifiers)
            .disabled(cycle == nil)
    }
}

struct PreviousTabCommand: View {
    @FocusedValue(\.cycleTab) private var cycle

    var body: some View {
        Button("Previous Tab") { cycle?(false) }
            .keyboardShortcut(AppChord.previousTab.key, modifiers: AppChord.previousTab.modifiers)
            .disabled(cycle == nil)
    }
}

/// **No chord, deliberately.** ⇧⌘T is View ▸ Tab Bar (Finder's mapping), and the only free
/// alternative would carry ⌥ — the one kind of chord that fires through the ⌥-hold reveal.
struct ReopenClosedTabCommand: View {
    @FocusedValue(\.reopenClosedTab) private var reopen

    var body: some View {
        Button("Reopen Closed Tab") { reopen?() }
            .disabled(reopen == nil)
    }
}

/// A noun with a tick, like every other view switch here — never a Show/Hide pair.
struct ToggleTabBarCommand: View {
    @FocusedValue(\.tabBarVisible) private var tabBar

    var body: some View {
        Toggle("Tab Bar", isOn: Binding(
            get: { tabBar?.isOn ?? false },
            set: { tabBar?.set($0) }
        ))
        .keyboardShortcut(AppChord.tabBar.key, modifiers: AppChord.tabBar.modifiers)
        // Ticked AND disabled while a second tab is open: the switch must never hide a strip whose
        // tabs would then be unreachable.
        .disabled(tabBar == nil || tabBar?.isForced == true)
    }
}

struct ToggleHiddenFilesCommand: View {
    @FocusedValue(\.showHiddenFiles) private var showHiddenFiles

    var body: some View {
        Toggle("Hidden Files", isOn: showHiddenFiles ?? .constant(false))
            .keyboardShortcut(AppChord.hiddenFiles.key, modifiers: AppChord.hiddenFiles.modifiers)
            .disabled(showHiddenFiles == nil)
    }
}

struct TogglePreviewColumnCommand: View {
    @FocusedValue(\.previewColumn) private var previewColumn

    var body: some View {
        Toggle("Preview Column", isOn: previewColumn ?? .constant(false))
            .keyboardShortcut(AppChord.previewColumn.key, modifiers: AppChord.previewColumn.modifiers)
            .disabled(previewColumn == nil)
    }
}

struct ToggleInspectorCommand: View {
    @FocusedValue(\.infoInspector) private var infoInspector

    var body: some View {
        Toggle("Info Inspector", isOn: infoInspector ?? .constant(false))
            .keyboardShortcut(AppChord.infoInspector.key, modifiers: AppChord.infoInspector.modifiers)
            .disabled(infoInspector == nil)
    }
}

struct ToggleDifferencesListCommand: View {
    @FocusedValue(\.differencesListVisible) private var differencesList

    var body: some View {
        Toggle("Differences List", isOn: differencesList ?? .constant(false))
            .keyboardShortcut(AppChord.differencesList.key, modifiers: AppChord.differencesList.modifiers)
            .disabled(differencesList == nil)
    }
}

struct FoldAllDifferencesCommand: View {
    @FocusedValue(\.foldAllDifferences) private var fold

    var body: some View {
        // Title from the same `FoldAllAction` the header's toggle resolved, so the item and the
        // toggle can never describe different clicks; menu-cased here, where menus live.
        Button(fold?.action == .expand ? "Expand All Folders" : "Collapse All Folders") {
            fold?.run()
        }
        .keyboardShortcut(AppChord.foldAllDifferences.key, modifiers: AppChord.foldAllDifferences.modifiers)
        .disabled(fold == nil)
    }
}

struct ReviewDifferencesCommand: View {
    @FocusedValue(\.startDifferencesReview) private var start

    var body: some View {
        Button("Review Differences") { start?() }
            .keyboardShortcut(AppChord.reviewDifferences.key, modifiers: AppChord.reviewDifferences.modifiers)
            .disabled(start == nil)
    }
}

struct VerifyDifferencesCommand: View {
    @FocusedValue(\.verifyDifferences) private var verify

    var body: some View {
        Button("Verify Differences") { verify?() }
            .keyboardShortcut(AppChord.verifyDifferences.key, modifiers: AppChord.verifyDifferences.modifiers)
            .disabled(verify == nil)
    }
}
