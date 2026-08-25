import SwiftUI
import Dashboard
import Design
import Events
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

/// View ▸ Organize ▸ the five sections, and the one that is current.
///
/// **Not a `Binding<OrganizeLens?>`, deliberately.** Writing the stored key directly is what the
/// palette's `aimOrganize` exists to prevent: the aim — which pane, which provider root — has to be
/// read *before* the workspace moves, because moving it changes the answer. A binding would let a
/// menu item set the lens and leave the workspace behind, or move the workspace and resolve the
/// scope against the wrong tree. The closure routes through the same call ⌘K's Organize rows use,
/// so there is one way to aim Organize rather than two.
struct OrganizeLensSwitch {
    /// The section showing now — `nil` is the overview, or any workspace that is not Organize — for
    /// the checkmark.
    let current: OrganizeLens?
    /// Selects a section, switching to Organize if the window is elsewhere.
    let select: (OrganizeLens) -> Void

    /// **Which section the menu ticks — nothing, unless Organize is the workspace on screen.**
    ///
    /// The stored key survives leaving Organize, which is what makes ⌘3 return you where you were.
    /// Ticking it from Browse would be a checkmark claiming a section is showing when the window is
    /// displaying something else entirely — the menu asserting a state the user can see is false.
    /// Selecting a section from elsewhere still works and still switches workspace; only the
    /// *claim* is withheld.
    static func tick(workspace: Workspace, stored: OrganizeLens?) -> OrganizeLens? {
        workspace == .filing ? stored : nil
    }
}

/// File ▸ the four verbs Organize offers on a row, aimed at the pane selection instead.
///
/// **One value for four items** for `TransferShortcut`'s reason: they read one selection and would
/// otherwise be four chances to disagree about it. Each closure is `nil` on its own though, because
/// unlike the transfers these become available at different moments — a folder can be organized
/// when a file cannot, and only a risky name can be fixed.
struct OrganizeVerbs {
    /// A single selected folder. Files are not organized; the lens is about where things live.
    let organizeFolder: (() -> Void)?
    /// A single selection of either kind — a folder's duplicates are its contents'.
    let findDuplicates: (() -> Void)?
    /// Both `nil` unless the single selection's name is one the app would rewrite. Rare, and that
    /// is the argument for the row menu carrying them too rather than instead: the badge that
    /// explains *why* is on the row, and a menu item cannot show it.
    let fixName: (() -> Void)?
    let keepName: (() -> Void)?
}

/// File ▸ the verbs the row menu has always had, over the pane selection.
///
/// **Reachable only by right-clicking the right row until now.** Every one has a working handler
/// and no menu-bar route, so none of them can be found without already knowing where to look.
///
/// One value rather than six, on `TransferShortcut`'s argument: they read one selection, and six
/// values would be six chances to disagree about it.
struct PaneRowVerbs {
    /// A single folder, when the pane can open tabs at all.
    let openInNewTab: (() -> Void)?
    /// A single node of either kind.
    let quickLook: (() -> Void)?
    let revealInFinder: (() -> Void)?
    let rename: (() -> Void)?
    /// The destination picker, for any selection. `true` moves, `false` copies.
    let chooseDestination: ((Bool) -> Void)?
    /// Ignore/Include, whose **title flips with the selection's state** — the row menu resolves the
    /// same pair from `isNodeIgnored`, and a menu item that named only one direction would be wrong
    /// half the time. `nil` when the workspace has no comparison to ignore anything from.
    let ignore: IgnoreToggle?

    struct IgnoreToggle {
        /// Already resolved: "Ignore in Comparison" or "Include in Comparison".
        let title: String
        let run: () -> Void
    }
}

/// What the pane-row verbs offer for a selection.
///
/// Pure, for `DifferencesShortcutRules`' reason — the resolver reads `ContentView` state, and a
/// rule left inline is a rule no test can flip.
enum PaneRowVerbAvailability {
    struct Answer: Equatable {
        let openInNewTab: Bool
        let singleNodeVerbs: Bool
        let chooseDestination: Bool
        let ignore: Bool
    }

    /// **Download is deliberately absent**, and this is the note that keeps it that way. Its row
    /// menu action starts a per-pane watch on `downloadChannel` so the cloud badge clears when the
    /// content lands; a menu item has no pane to scope that to, and firing the download without
    /// the watch leaves a badge that never clears. The row menu's own comment names Reveal in
    /// Finder as the reliable download path everywhere, and that IS in the menu.
    ///
    /// **Get Info is absent too**, for the reason the mockup settled: it wants Finder's ⌘I, which
    /// is the Info Inspector here, and the inspector already answers it without leaving the window.
    static func resolve(selectionCount: Int, isDirectory: Bool,
                        canOpenInNewTab: Bool, isComparing: Bool) -> Answer {
        let single = selectionCount == 1
        return Answer(
            openInNewTab: single && isDirectory && canOpenInNewTab,
            singleNodeVerbs: single,
            // A destination pick works on a batch; the picker prunes nested nodes downstream
            // (`FileOperations` does it again), so a folder and its child cannot both travel.
            chooseDestination: selectionCount >= 1,
            // Ignoring is a statement about a comparison. On Browse or Storage there is none.
            ignore: selectionCount >= 1 && isComparing)
    }
}

/// Whether ⌘A means the focused pane's rows.
///
/// **The differences table can own the selection, and then it does not.** Registering ⌘A on a menu
/// item took the chord app-wide, so it fires wherever the user is standing — including a Compare
/// window whose selection lives in the Differences table. Selecting the whole pane there changes a
/// selection the user was not looking at, and the pane's selection is what `⌘⌫` and the transfer
/// verbs then act on: a chord meaning "select what I am working in" would have quietly re-aimed
/// the destructive ones at something else.
///
/// The table has no select-all of its own, so withholding costs nothing that existed — and a
/// disabled item does not consume its key equivalent, so `⌘A` still reaches a text field's own
/// select-all underneath. This is the rule the transfer chords already follow
/// (`DifferencesShortcutRules.transferAvailable`), applied to the one chord that was missing it.
enum SelectAllScope {
    static func appliesToPane(surface: SelectionSurface?) -> Bool {
        surface != .differences
    }
}

/// Which of the four verbs a selection offers, as a pure rule.
///
/// Extracted for `DifferencesShortcutRules`' reason: the resolver reads `ContentView` state and a
/// `View` cannot be built in a test, so a rule left inline is a rule no test can flip. Every
/// parameter here changes an answer — one that could not would be a parameter the view had stopped
/// passing correctly with nothing failing.
enum OrganizeVerbAvailability {
    struct Answer: Equatable {
        let organizeFolder: Bool
        let findDuplicates: Bool
        let fixName: Bool
        let keepName: Bool
    }

    /// **One selected thing, always.** Each verb takes a single `FileNode`: organizing two folders
    /// is two questions, and "find duplicates of this" has no referent for two things at once. With
    /// several rows selected every item disables rather than quietly acting on the first — the
    /// failure mode a menu cannot show and the row menu never had, because a right-click has one
    /// row under the pointer by construction.
    static func resolve(selectionCount: Int, isDirectory: Bool, isRisky: Bool) -> Answer {
        guard selectionCount == 1 else {
            return Answer(organizeFolder: false, findDuplicates: false, fixName: false, keepName: false)
        }
        return Answer(
            // Files are not organized: the lens answers "where does this live", which is a question
            // about a folder's contents.
            organizeFolder: isDirectory,
            findDuplicates: true,
            fixName: isRisky,
            keepName: isRisky)
    }
}

private struct OrganizeLensKey: FocusedValueKey {
    typealias Value = OrganizeLensSwitch
}

private struct OrganizeVerbsKey: FocusedValueKey {
    typealias Value = OrganizeVerbs
}

private struct PaneRowVerbsKey: FocusedValueKey {
    typealias Value = PaneRowVerbs
}

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
    typealias Value = CloseTabAction
}

private struct CycleTabKey: FocusedValueKey {
    typealias Value = (Bool) -> Void
}

private struct ReopenClosedTabKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SelectAllInPaneKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ClipboardActionsKey: FocusedValueKey {
    typealias Value = ClipboardActions
}

private struct TabBarVisibleKey: FocusedValueKey {
    typealias Value = TabBarSwitch
}

private struct FolderSidebarVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
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

/// Edit ▸ Cut / Copy / Paste, as one value.
///
/// **The three travel together because they are one question asked three ways** — *which pane, and
/// what is selected in it* — and a value that answers it once cannot answer it differently for Copy
/// than for Paste. Published as three separate closures they could disagree by a render: the pane
/// chords resolve through `paneSearchTargetIsLeft`, and a focus change between two `@FocusedValue`
/// reads is exactly the drift `ShortcutValuePublisher` exists to prevent.
///
/// `cut` and `copy` are `nil` with nothing selected; `paste` is `nil` when neither clipboard holds
/// files.
///
/// **A `nil` here does not disable the menu item, and must not be made to.** `CutCommand`,
/// `CopyCommand` and `PasteCommand` are never `.disabled` — see the reasoning on `CutCommand` and
/// the guard `EditMenuTests.theEditItemsAreNeverDisabled` — because a menu item cannot know
/// where the caret is when it renders, and greying Copy over an empty selection would grey it out
/// while somebody is typing in the ⌘K field. So the item stays live, `TextEditingChord.route`
/// picks the meaning at fire time, and `nil` makes the *file* half a no-op rather than making the
/// item unavailable. This sentence used to say the opposite, which is one reading away from
/// "fixing" these into `.disabled(…)` and taking ⌘C from every text field in the app.
struct ClipboardActions {
    let cut: (() -> Void)?
    let copy: (() -> Void)?
    let paste: (() -> Void)?
}

/// ⌘W's payload — **three states, because an optional closure only has two and ⌘W needs three.**
///
/// `nil` (nothing published) and `.suspended` used to arrive as the same `nil`, and
/// `CloseTabCommand` treated that one value as "close the key window". That is right for one of
/// them and wrong for the other:
///
/// - **nothing published** — one of the three auxiliary `Window` scenes (Keyboard Shortcuts,
///   Activity Log, Sync History) is key. None of them publishes a focused value, and this item
///   took File ▸ Close's place, so ⌘W still has to close the window. Unchanged.
/// - **`.suspended`** — the main window is there, but the destination picker or the ⌘K palette
///   owns the keyboard. ⌘W closed the WINDOW out from under an in-flight pick: the overlay is up
///   precisely because a file operation is waiting on an answer, and every other chord is silenced
///   for that reason. Taking the whole window is the one thing worse than tunnelling.
///
/// Not a second focused value beside the closure, deliberately: two values that must be read
/// together are two values one call site can forget to read together, and a `switch` over this is
/// the compiler noticing when a fourth state appears.
enum CloseTabAction {
    /// A pane published a tab to close. On its last tab that closure closes the window itself,
    /// which is Finder's ⌘W and why this is never withheld at one tab.
    case closeTab(() -> Void)
    /// A pane is present but an overlay owns the keyboard: ⌘W does nothing at all.
    case suspended

    /// The publisher's rule, as a value — static so the three-way resolution can be tested without
    /// a scene, and so the suspension cannot be expressed anywhere but here.
    ///
    /// `suspended` wins over a live closure rather than trusting the caller to have nil'd it: the
    /// argument is already `effectiveCloseTab`, which is suspension-filtered, so the two agree —
    /// but a value that decides the same thing twice should not be able to disagree with itself.
    static func resolve(suspended: Bool, _ close: (() -> Void)?) -> CloseTabAction? {
        if suspended { return .suspended }
        return close.map(CloseTabAction.closeTab)
    }

    /// Whether ⌘W is refusing right now — **the one thing the menu item needs to read, and the
    /// reason this enum cannot be `Equatable`.**
    ///
    /// `.closeTab` holds a closure, so there is no `==` to compare `self` against `.suspended`
    /// with; a `case` test is the only form available and a computed property is where it belongs
    /// rather than at the call site. Deliberately NOT true for `nil`: nothing published means an
    /// auxiliary window, where this item stands in for File ▸ Close and must stay live.
    var isSuspended: Bool {
        if case .suspended = self { return true }
        return false
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

    /// ⌘W. Never `nil` while a pane exists — on the last tab it closes the WINDOW, as Finder does,
    /// so the item stays enabled rather than becoming a dead ⌘W. While the chords are suspended it
    /// is `.suspended` rather than `nil`, which is what keeps "an overlay owns the keyboard" from
    /// reading as "this window has no tabs, close it" (see ``CloseTabAction``).
    var closeTab: CloseTabAction? {
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

    /// ⌘A — everything in the focused pane's current folder. `nil` when that folder is empty,
    /// so the item disables rather than selecting nothing.
    var selectAllInPane: (() -> Void)? {
        get { self[SelectAllInPaneKey.self] }
        set { self[SelectAllInPaneKey.self] = newValue }
    }

    /// ⌘X / ⌘C / ⌘V, as one value — see ``ClipboardActions``.
    var clipboardActions: ClipboardActions? {
        get { self[ClipboardActionsKey.self] }
        set { self[ClipboardActionsKey.self] = newValue }
    }

    /// View ▸ Organize ▸ the five sections.
    var organizeLens: OrganizeLensSwitch? {
        get { self[OrganizeLensKey.self] }
        set { self[OrganizeLensKey.self] = newValue }
    }

    /// File ▸ Organize's row verbs, aimed at the pane selection.
    var organizeVerbs: OrganizeVerbs? {
        get { self[OrganizeVerbsKey.self] }
        set { self[OrganizeVerbsKey.self] = newValue }
    }

    /// File ▸ the pane row menu's verbs, aimed at the pane selection.
    var paneRowVerbs: PaneRowVerbs? {
        get { self[PaneRowVerbsKey.self] }
        set { self[PaneRowVerbsKey.self] = newValue }
    }

    /// View ▸ Tab Bar.
    var tabBarVisible: TabBarSwitch? {
        get { self[TabBarVisibleKey.self] }
        set { self[TabBarVisibleKey.self] = newValue }
    }

    /// What **View ▸ Sidebar** reads. `nil` wherever the column cannot be drawn at all — see
    /// `shortcutFolderSidebar`, which is the one place that decides it — and a plain
    /// `Binding<Bool>` rather than `TabBarSwitch` because nothing ever forces it on.
    ///
    /// Carried nothing from 2026-08-20 until v4.4, while the column was held: the channel stayed
    /// live and empty rather than being deleted, which is why re-attaching the item was one `Toggle`
    /// and a menu line rather than a rebuild. Kept intact for the same reason it survived the hold —
    /// the publisher's suspension rule for it is asserted by `ShortcutCommandsTests`, and deleting
    /// the channel would delete the only tests saying a destination pick silences this switch with
    /// the rest.
    var folderSidebarVisible: Binding<Bool>? {
        get { self[FolderSidebarVisibleKey.self] }
        set { self[FolderSidebarVisibleKey.self] = newValue }
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
    let selectAll: (() -> Void)?
    let clipboard: ClipboardActions
    let newTab: (() -> Void)?
    /// Never `nil` while a pane exists — on the last tab it closes the WINDOW, which is what
    /// Finder's ⌘W does and what keeps this from being a chord that dies at one tab.
    ///
    /// Suspension does not flatten it into `nil` on the way out: it is published as
    /// ``CloseTabAction``, whose `.suspended` case is what stops ⌘W falling through to
    /// `performClose` mid-pick. `effectiveCloseTab` below still nils, like every other value here.
    let closeTab: (() -> Void)?
    let cycleTab: ((Bool) -> Void)?
    let reopenClosedTab: (() -> Void)?
    let tabBar: TabBarSwitch?
    /// `nil` wherever the column cannot be drawn — see `shortcutFolderSidebar`, which is the one
    /// place that decides it.
    let folderSidebar: Binding<Bool>?
    let organizeLens: OrganizeLensSwitch?
    let organizeVerbs: OrganizeVerbs?
    let paneRowVerbs: PaneRowVerbs?

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
    var effectiveSelectAll: (() -> Void)? { suspended ? nil : selectAll }
    /// Suspended as a whole, so a destination pick cannot be answered by pasting into the pane
    /// underneath it — and so the three verbs go silent together rather than one at a time.
    var effectiveClipboard: ClipboardActions? {
        suspended ? nil : clipboard
    }
    var effectiveNewTab: (() -> Void)? { suspended ? nil : newTab }
    var effectiveCloseTab: (() -> Void)? { suspended ? nil : closeTab }
    var effectiveCycleTab: ((Bool) -> Void)? { suspended ? nil : cycleTab }
    var effectiveReopenClosedTab: (() -> Void)? { suspended ? nil : reopenClosedTab }
    var effectiveTabBar: TabBarSwitch? { suspended ? nil : tabBar }
    var effectiveFolderSidebar: Binding<Bool>? { suspended ? nil : folderSidebar }
    var effectiveOrganizeLens: OrganizeLensSwitch? { suspended ? nil : organizeLens }
    var effectiveOrganizeVerbs: OrganizeVerbs? { suspended ? nil : organizeVerbs }
    var effectivePaneRowVerbs: PaneRowVerbs? { suspended ? nil : paneRowVerbs }

    /// ⌘W's published value, which is the one that does NOT go silent — see ``CloseTabAction``.
    /// `effectiveCloseTab` still nils with the rest (a suspended ⌘W closes no tab); what this adds
    /// is that the item hears *why* it got nothing, so it stops short of closing the window.
    var closeTabAction: CloseTabAction? {
        CloseTabAction.resolve(suspended: suspended, effectiveCloseTab)
    }

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
            .focusedSceneValue(\.selectAllInPane, effectiveSelectAll)          // ⌘A
            .focusedSceneValue(\.clipboardActions, effectiveClipboard)         // ⌘X / ⌘C / ⌘V
            .focusedSceneValue(\.newTab, effectiveNewTab)                     // ⌘T
            // ⌘W — three states, not two: `.suspended` is what the silenced value publishes, so the
            // item can tell it from the auxiliary windows that publish nothing at all.
            .focusedSceneValue(\.closeTab, closeTabAction)
            .focusedSceneValue(\.cycleTab, effectiveCycleTab)                 // ⇧⌘] / ⇧⌘[
            .focusedSceneValue(\.reopenClosedTab, effectiveReopenClosedTab)   // File ▸ Reopen Closed Tab
            .focusedSceneValue(\.tabBarVisible, effectiveTabBar)              // ⇧⌘T
            .focusedSceneValue(\.folderSidebarVisible, effectiveFolderSidebar) // View ▸ Sidebar, ⌃⌘S
            .focusedSceneValue(\.organizeLens, effectiveOrganizeLens)         // View ▸ Organize ▸ …
            .focusedSceneValue(\.organizeVerbs, effectiveOrganizeVerbs)       // File ▸ Organize's verbs
            .focusedSceneValue(\.paneRowVerbs, effectivePaneRowVerbs)         // File ▸ the row menu's verbs
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
            selectAll: shortcutSelectAll,
            clipboard: shortcutClipboard,
            newTab: { openNewTabHere(isLeft: shortcutTabTargetIsLeft) },
            closeTab: shortcutCloseTab,
            cycleTab: shortcutCycleTab,
            reopenClosedTab: shortcutReopenClosedTab,
            tabBar: shortcutTabBar,
            folderSidebar: shortcutFolderSidebar,
            organizeLens: shortcutOrganizeLens,
            organizeVerbs: shortcutOrganizeVerbs,
            paneRowVerbs: shortcutPaneRowVerbs,
            // Suspended by the palette too, on the destination picker's own argument: it is a
            // full-window overlay whose scrim blocks the mouse from every control these chords
            // mirror, so without this ⌘R rescans underneath it and ⇧⌘. flips the filters behind
            // the field you are typing into. Unlike Settings and Help — ambient panels the app
            // deliberately keeps its chords live under — this one OWNS the keyboard while it is up.
            //
            // **⌘K is suspended with the rest, not exempt from it.** An earlier version of this note
            // said ⌘K "stays live (its own focused value) so the toggle can close it"; `a1c96082`
            // moved ⌘K into this publisher and that stopped being true. Closing the palette is not
            // the menu item's job — the item is disabled for exactly as long as the palette is up.
            //
            // **Escape is what closes it, from the field editor**, not from a monitor: the Go-to
            // field's `cancelOperation:` calls `palettePanel.dismiss()` (`GoToFieldBar`). The panel
            // DID carry a keyDown monitor, and this note went on naming it after `7e8fff03` removed
            // it — §7 moved the field into the toolbar, so the host keeps key and the field editor
            // sees the key first. The panel's remaining monitor watches the mouse only.
            //
            // Suspending the *publication* is not the same as suspending the *act*:
            // `toggleCommandPalette` carries its own `pendingDestination` guard, because the toolbar
            // pill and the armed-on-launch path call it without going through a focused value —
            // and so do the two pane key handlers, through `paneChordsSuspended` below.
            suspended: paneChordsSuspended
        )
    }

    /// Whether a surface that owns the keyboard is up: the destination picker, or the ⌘K palette.
    ///
    /// **Named because two things read it, and one of them is not a menu item.** `suspended:` above
    /// silences every mirrored chord while a pick is pending — but ↩ (Rename) and Space (Quick Look)
    /// are `.onKeyPress` handlers on the file list, not menu equivalents, so they never went through
    /// that publication and were live underneath the picker.
    ///
    /// **Focus scoping does not cover this, which is the assumption worth naming.** ↩'s own
    /// reasoning is that `.onKeyPress` fires "only while the file list holds focus", and the picker
    /// is a full-window SwiftUI overlay drawn over `NSViewRepresentable` file panes — the exact
    /// arrangement `CommandPalettePanel.swift` records as NOT taking key from the tables underneath
    /// it, off this app's own log. So the table keeps first responder, focus stays inside the tree
    /// view, and ↩ reached `paneRename` and renamed a row while the user was confirming where to
    /// copy files — swallowing the keystroke from the picker's default button on the way.
    var paneChordsSuspended: Bool { pendingDestination != nil || showCommandPalette }

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

    /// View ▸ Sidebar's binding, and `nil` wherever the column cannot be drawn.
    ///
    /// The gate is the workspace and not `layoutMode`, and it is asked through
    /// `FolderSidebarModel.appliesTo` so the menu item, the toolbar button and the column itself
    /// cannot come to disagree about where a sidebar is possible. Every shipping workspace supports
    /// one as of v4.4 — the lens workspaces were excluded on the reasoning that their 220pt-clamped
    /// rail left no room, which `PaneLogic.lensSidebarWidth` answered with a clamp instead — so in
    /// practice the live `nil` is the collapsed-panes one.
    var shortcutFolderSidebar: Binding<Bool>? {
        // **`appliesTo`, not `isShowing`**: the item is live with the column switched off, because
        // the item is how it gets switched on. Asking `isShowing` here would make the
        // tick the only way to reach the tick. This call carried the v4.2/v4.3 hold too, through
        // `appliesTo`'s `isEnabled` — one condition, never a second one written at this site.
        guard FolderSidebarModel.appliesTo(
            workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
            panesCollapsed: panesHiddenForCurrentTab) else { return nil }
        return Binding(get: { browseSidebarVisible }, set: { browseSidebarVisible = $0 })
    }

    /// View ▸ Tab Bar — **ticked and disabled while a strip on screen holds a second tab**, so the
    /// switch can never hide a strip whose tabs would then be unreachable.
    ///
    /// **It has to ask both panes, because the strip's visibility rule does.** This used to ask only
    /// `shortcutTabTargetIsLeft` — the focused pane — while `PaneTabStripVisibility.shows` decides
    /// from `own` *and* `sibling`. In Compare with two tabs in the unfocused pane only, the rule put
    /// a strip on screen and the menu item read unticked and live, so the switch offered to hide a
    /// strip it did not describe and the tabs in it became unreachable — which is the exact case the
    /// disabling exists to prevent, arrived at from the other side.
    ///
    /// The condition is `PaneTabStripVisibility.forcesTabBarSwitch`, which is defined as the
    /// visibility rule with the switch's own term removed — so the two cannot drift again. Inlining
    /// the disjunction here is what let them drift the first time.
    var shortcutTabBar: TabBarSwitch {
        let isLeft = shortcutTabTargetIsLeft
        let forced = PaneTabStripVisibility.forcesTabBarSwitch(
            own: syncManager.paneTabs(isLeft: isLeft).showsStrip,
            sibling: syncManager.paneTabs(isLeft: !isLeft).showsStrip,
            isCompare: layoutMode == .compare)
        return TabBarSwitch.resolve(hasSecondTab: forced,
                                    preference: tabBarVisible) { tabBarVisible = $0 }
    }

    /// Resolved once and used for both the gate and the act, so the menu item can never be enabled
    /// by a column stack the pane on screen does not draw — the same pairing the header's arrows
    /// make. See `paneDrawsColumns(isLeft:)`.
    /// ⌘A — the rows of the focused pane's **current folder**.
    ///
    /// **Not every visible row, and the reason is a real limit rather than a preference.** In Tree
    /// mode a pane can have folders expanded, and which rows those are lives in
    /// `FileTreeView.expanded` — `@State private`, inside the view. A menu item is published from
    /// the App scope and cannot see it, so an item claiming to select "everything visible" would be
    /// guessing. Selecting the current folder's contents is a promise this layer can actually keep.
    ///
    /// Columns resolves through the deepest open column, the same target `beginNewFolder` uses, so
    /// ⌘A and ⇧⌘N cannot disagree about which folder the pane is "in".
    var shortcutSelectAll: (() -> Void)? {
        guard SelectAllScope.appliesToPane(surface: syncManager.lastSelectionSurface) else { return nil }
        let isLeft = shortcutTargetIsLeft
        let pane = paneContext(isLeft: isLeft)
        let ids: [String]
        if pane.viewMode == .columns {
            let directory = (isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath)
                .currentDirectory(treeRoot: pane.currentPath)
            let index = isLeft ? syncManager.leftChildrenIndex(treeRoot: pane.currentPath)
                               : syncManager.rightChildrenIndex(treeRoot: pane.currentPath)
            ids = (index.children(atPath: directory) ?? []).map(\.id)
        } else {
            // **Top-level rows only, and this is not an oversight.** A Tree pane draws a hierarchy,
            // so "everything visible" would include the children of every expanded folder — and
            // selecting a folder *and* its contents is a transfer that copies both, once as the
            // folder and again as its parts. Selecting the roots already covers everything beneath
            // them, because every verb here treats a folder as its contents.
            ids = pane.tree.nodes.map(\.id)
        }
        // Empty folder: withheld, so ⌘A disables rather than clearing the selection you had.
        guard !ids.isEmpty else { return nil }
        return {
            if isLeft { syncManager.selectedLeftPaths = Set(ids) }
            else { syncManager.selectedRightPaths = Set(ids) }
        }
    }

    /// ⌘X / ⌘C / ⌘V, resolved together — see ``ClipboardActions``. Edit ▸ Cut / Copy / Paste, over
    /// the file clipboard — the app's own list, or the system pasteboard, whichever was written
    /// last (`ClipboardSource.resolve`).
    ///
    /// **The source and the destination are resolved by different rules, and that is what makes
    /// cut-and-paste a cross-pane move.** Cut and Copy take `activeSelectionNodes` — wherever the
    /// selection *is*. Paste targets `shortcutTargetIsLeft` — wherever focus *is*. They agree until
    /// ⌃⇥ moves focus without moving the selection, and then they are exactly what is wanted:
    /// select on the left, ⌃⇥, paste on the right. Making them one rule would break that.
    ///
    /// Cut and Copy read the selection at FIRE time, matching `DeleteSelectionCommand`'s rule that
    /// a menu held open is not re-armed by a republish. The paste destination is captured at
    /// publish time instead, which is safe for the one reason worth stating: a pane's directory
    /// only changes by navigating, and the menu being open is what stops that happening.
    var shortcutClipboard: ClipboardActions {
        let isLeft = shortcutTargetIsLeft
        let hasSelection = !activeSelectionNodes.isEmpty
        let pane = paneContext(isLeft: isLeft)
        let destination = pane.viewMode == .columns
            ? (isLeft ? syncManager.leftBrowsePath : syncManager.rightBrowsePath)
                .currentDirectory(treeRoot: pane.currentPath)
            : pane.currentPath
        return ClipboardActions(
            cut: hasSelection ? { actionHandler?.handleCopyToClipboard(activeSelectionNodes, isCut: true) } : nil,
            copy: hasSelection ? { actionHandler?.handleCopyToClipboard(activeSelectionNodes, isCut: false) } : nil,
            // Withheld when neither clipboard has files: pasting nothing is a no-op, and an
            // enabled item that does nothing is the thing `clipboardHasItems` was added to the row
            // menu to prevent. **Through `ClipboardSource.current`, which is the same call the
            // paste itself makes** — asking `clipboardNodes.isEmpty` here was right while the app's
            // clipboard was the only one, and would now grey out a paste of files copied in Finder.
            paste: ClipboardSource.current(pasteboard: actionHandler?.pasteboard ?? .general,
                                           hasInAppItems: !syncManager.clipboardNodes.isEmpty,
                                           ownChangeCount: syncManager.clipboardPasteboardChangeCount) == .none
                 ? nil
                 : { actionHandler?.pasteClipboard(toPath: destination) })
    }

    /// The Organize menu's sections — routed through `aimOrganize`, never by writing the stored key.
    var shortcutOrganizeLens: OrganizeLensSwitch {
        OrganizeLensSwitch(current: OrganizeLensSwitch.tick(workspace: selectedWorkspace,
                                                           stored: selectedOrganizeLens)) { section in
            // `scope: nil` leaves whatever Organize is aimed at alone: this item chooses a
            // section, it does not re-aim the lens at a folder the way ⌘K's "organize legal" does.
            aimOrganize(lens: section, scope: nil)
        }
    }

    /// File ▸ the row menu's verbs, over the active pane's selection.
    ///
    /// Built on the same `PaneActionDelegate` the row menu routes through, so a menu item and a
    /// right-click are one act rather than two similar ones.
    var shortcutPaneRowVerbs: PaneRowVerbs {
        let selection = activeSelectionNodes
        let none = PaneRowVerbs(openInNewTab: nil, quickLook: nil, revealInFinder: nil,
                                rename: nil, chooseDestination: nil, ignore: nil)
        guard actionHandler != nil, let pane = activePane, !selection.isEmpty else { return none }
        let context = paneContext(isLeft: pane == .left)
        let delegate = paneActionDelegate(for: context)
        let node = selection.first
        let can = PaneRowVerbAvailability.resolve(
            selectionCount: selection.count,
            isDirectory: node?.isDirectory ?? false,
            canOpenInNewTab: delegate.canOpenInNewTab,
            isComparing: layoutMode == .compare)
        // Resolved here, not in the item: the row menu reads the same `isNodeIgnored` to decide
        // which of the two verbs it is offering, and the two must not answer differently.
        let allIgnored = selection.allSatisfy { delegate.isNodeIgnored($0, currentPath: context.currentPath) }
        return PaneRowVerbs(
            openInNewTab: can.openInNewTab ? { node.map { delegate.handleOpenInNewTab($0) } } : nil,
            quickLook: can.singleNodeVerbs
                ? { node.map { toggleQuickLook(URL(fileURLWithPath: $0.id), followsPane: true) } } : nil,
            revealInFinder: can.singleNodeVerbs
                ? { node.map { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.id)]) } } : nil,
            rename: can.singleNodeVerbs ? { node.map { delegate.handleRename($0) } } : nil,
            // Fire-time selection, like `DeleteSelectionCommand`: a menu held open is not re-armed
            // by a republish, so a captured array could name rows a bulk sync has since replaced.
            chooseDestination: can.chooseDestination
                ? { isMove in delegate.handleChooseDestination(activeSelectionNodes, isMove: isMove) } : nil,
            ignore: can.ignore
                ? PaneRowVerbs.IgnoreToggle(
                    title: allIgnored ? "Include in Comparison" : "Ignore in Comparison",
                    run: { delegate.handleIgnore(activeSelectionNodes) })
                : nil)
    }

    /// File ▸ Organize's verbs, over the active pane's selection.
    ///
    /// **Single selection throughout, and that is the verbs' own rule rather than a simplification.**
    /// Every one of them takes a `FileNode`: organizing two folders is two questions, and "find
    /// duplicates of this" has no meaning for two things at once. With several rows selected each
    /// item disables rather than silently acting on the first.
    var shortcutOrganizeVerbs: OrganizeVerbs {
        // **The row menu's own delegate, for the pane the selection is in.** Not `actionHandler`
        // directly: these four verbs live on `PaneActionDelegate`, which is what decides a risky
        // name and what the row menu routes through. Building the same value here is what keeps a
        // menu item and a right-click doing one thing rather than two similar things.
        // Read ONCE. `activeSelectionNodes` resolves every selected path through the manager's
        // index on each access, and the first cut evaluated it three times to answer one question.
        let selection = activeSelectionNodes
        guard actionHandler != nil,
              let pane = activePane,
              selection.count == 1,
              let node = selection.first else {
            return OrganizeVerbs(organizeFolder: nil, findDuplicates: nil, fixName: nil, keepName: nil)
        }
        let delegate = paneActionDelegate(for: paneContext(isLeft: pane == .left))
        let can = OrganizeVerbAvailability.resolve(selectionCount: selection.count,
                                                   isDirectory: node.isDirectory,
                                                   isRisky: delegate.riskyName(for: node) != nil)
        return OrganizeVerbs(
            organizeFolder: can.organizeFolder ? { delegate.handleOrganizeFolder(node) } : nil,
            findDuplicates: can.findDuplicates ? { delegate.handleFindDuplicates(node) } : nil,
            fixName: can.fixName ? { delegate.handleFixName(node) } : nil,
            keepName: can.keepName ? { delegate.handleKeepName(node) } : nil)
    }

    var shortcutGoBack: (() -> Void)? {
        let isLeft = shortcutTargetIsLeft
        let columns = paneDrawsColumns(isLeft: isLeft)
        guard syncManager.canGoBack(isLeft: isLeft, drawsColumns: columns) else { return nil }
        return { syncManager.goBack(isLeft: isLeft, drawsColumns: columns) }
    }

    var shortcutGoForward: (() -> Void)? {
        let isLeft = shortcutTargetIsLeft
        let columns = paneDrawsColumns(isLeft: isLeft)
        guard syncManager.canGoForward(isLeft: isLeft, drawsColumns: columns) else { return nil }
        return { syncManager.goForward(isLeft: isLeft, drawsColumns: columns) }
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
            // A tenth workspace gets no chord rather than crashing the menu bar — see
            // `AppChord.workspace(_:)`. `keyboardShortcut` takes an optional shortcut, so "no
            // chord" is a state SwiftUI already has a spelling for.
            .keyboardShortcut(AppChord.workspace(index + 1).map {
                KeyboardShortcut($0.key, modifiers: $0.modifiers)
            })
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

    var body: some View {
        // Ellipsis: the action confirms before touching anything (`NativeAlerts.confirmDelete`).
        Button("Delete Selection…") {
            // ⌘⌫ is also NSText's delete-to-beginning-of-line — see `TextEditingChord`.
            TextEditingChord.route(
                editorAction: { $0.deleteToBeginningOfLine(nil) },
                fileAction: { delete?() })
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

// MARK: The file clipboard

/// Edit ▸ Select All, ⌘A.
///
/// Routed through ``TextEditingChord`` like its three neighbours: ⌘A is *select all text* whenever
/// the caret is in a field, and a menu equivalent would take it.
struct SelectAllCommand: View {
    @FocusedValue(\.selectAllInPane) private var selectAll

    var body: some View {
        Button("Select All") {
            TextEditingChord.route(editorAction: { $0.selectAll(nil) },
                                   fileAction: { selectAll?() })
        }
        .keyboardShortcut(AppChord.selectAll.key, modifiers: AppChord.selectAll.modifiers)
        // Never disabled: with the caret in a field the item is still live, because it selects the
        // TEXT. Withholding it on an empty pane would take ⌘A away from every field in the window.
    }
}

/// Edit ▸ Cut / Copy / Paste — the file clipboard, **and since v4.2 the system pasteboard too**.
///
/// It was the app's internal list alone (`FileSyncManager.clipboardNodes`), which is why the
/// comment here used to end "not `NSPasteboard`". A copy now also writes file URLs to the general
/// pasteboard, so ⌘C here and ⌘V in Finder works, and a paste takes whichever clipboard was written
/// last — `ClipboardSource.resolve` decides, and the internal list stays the only one that carries
/// `isCut`.
///
/// **These verbs already worked; they had no menu and no chord.** Cut, Copy and *Paste here* have
/// been on the row menu and the empty-area menu since before v4.0, spending through the same
/// `copyItems`/`moveItems` as every transfer — grouped undo and success banner included. So ⌘C over
/// a selected file did nothing visible while the working verb hid in a right-click.
///
/// **⌘X then ⌘V is move-here.** The clipboard carries `isCut`, so Finder's ⌥⌘V has nothing left to
/// do — which is fortunate, because it could not be registered anyway: no chord in this app may
/// contain ⌥ (`AppChordTests.noChordContainsOption`).
/// **None of the three is ever `.disabled`, and that is deliberate rather than an oversight.**
///
/// A menu item cannot know where the caret is when it renders. Disabling Copy whenever no *files*
/// are selected would grey it out while someone is typing in the ⌘K field or a rename box — the
/// item would read as unavailable at the exact moment it is doing its most ordinary job. So the
/// items stay live and `TextEditingChord.route` decides at fire time which of the two meanings
/// applies.
///
/// The cost is accepted, not overlooked: with no caret and no selection, Paste is an enabled item
/// that does nothing. `theEditItemsAreNeverDisabled` pins the property so this is not "fixed" into
/// a regression that kills ⌘C in every text field the moment a pane has no selection.
struct CutCommand: View {
    @FocusedValue(\.clipboardActions) private var clipboard

    var body: some View {
        Button("Cut") {
            TextEditingChord.route(editorAction: { $0.cut(nil) },
                                   fileAction: { clipboard?.cut?() })
        }
        .keyboardShortcut(AppChord.cut.key, modifiers: AppChord.cut.modifiers)
    }
}

struct CopyCommand: View {
    @FocusedValue(\.clipboardActions) private var clipboard

    var body: some View {
        Button("Copy") {
            TextEditingChord.route(editorAction: { $0.copy(nil) },
                                   fileAction: { clipboard?.copy?() })
        }
        .keyboardShortcut(AppChord.copy.key, modifiers: AppChord.copy.modifiers)
    }
}

struct PasteCommand: View {
    @FocusedValue(\.clipboardActions) private var clipboard

    var body: some View {
        Button("Paste") {
            TextEditingChord.route(editorAction: { $0.paste(nil) },
                                   fileAction: { clipboard?.paste?() })
        }
        .keyboardShortcut(AppChord.paste.key, modifiers: AppChord.paste.modifiers)
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
/// **The fallback does NOT cover the suspended case, and that is the point of ``CloseTabAction``.**
/// While a destination pick or the ⌘K palette is up every mirrored chord is silenced, and ⌘W used
/// to arrive here as the same `nil` an auxiliary window publishes — so the one chord that was not
/// silenced closed the main window out from under the pick the user was in the middle of making.
/// Suspended, ⌘W now does nothing.
///
/// **And it SAYS so, twice, because a refusal that neither greys out nor logs is this app's own
/// named bug.** Doing nothing was the whole fix and it was also the whole of it: the item stayed
/// black in a File menu whose other eleven items had greyed, and the keystroke left no trace. Both
/// halves are covered here, on the pattern `ContentView` already states for the ambient panels
/// ("with the latch refusing, an enabled button would be a control that silently does nothing …
/// Disabled says so") — the latch refuses *and* the toolbar button disables, and neither one is
/// redundant:
///
/// - **The item disables** while `close` is `.suspended`. That is the surface a person actually
///   reads: the menu is the only place ⌘W's state is legible at rest, and every sibling chord is
///   already grey there for the same reason. Disabling only on `.suspended` and not on `nil` is
///   what keeps `theCloseItemIsNeverDisabled`'s real subject intact — an auxiliary window's ⌘W
///   stays live, because this item is also its Close.
/// - **``run`` logs** the refusal, at `.info`, for the same reason `toggleCommandPalette` logs
///   ⌘K's ("⌘K did nothing and the log is silent"). With the item disabled AppKit never performs
///   the action, so this is the residual path rather than the common one — and that is precisely
///   its worth: the disable is one deleted modifier away from being gone, menu validation follows
///   SwiftUI's update cycle rather than the flag it is derived from, and `run` is the rule every
///   other reader of this behaviour goes through. If ⌘W is ever silently dead again, the log is
///   where that is answered.
struct CloseTabCommand: View {
    @FocusedValue(\.closeTab) private var close

    /// What ⌘W does, in all three of its states.
    ///
    /// Static and injectable so the rule can be tested: the live path reads the key window, which a
    /// unit test has none of. A `switch` rather than `if let`, so a fourth state cannot be added
    /// without the compiler asking what ⌘W should do in it.
    static func run(_ close: CloseTabAction?, closeWindow: () -> Void) {
        switch close {
        case .closeTab(let closeTab): closeTab()
        // An overlay owns the keyboard. Doing nothing is the whole fix: the alternative — falling
        // through to `closeWindow` — takes the window an in-flight file operation is asking about.
        // Said out loud, though, on ⌘K's rule: `.info` rather than `.debug`, because `.debug` is
        // dropped at Settings ▸ Advanced ▸ Info and this is a refusal a user can trigger by hand.
        case .suspended:
            Logger.shared.info("⌘W ignored: an overlay owns the keyboard")
        // Nothing published: an auxiliary window, where this item stands in for File ▸ Close.
        case nil: closeWindow()
        }
    }

    var body: some View {
        // The title stays "Close Tab" because the main window is where this is ever read; on an
        // auxiliary window the menu item is a chord, not a label anyone goes looking for.
        Button("Close Tab") {
            Self.run(close) { NSApp.keyWindow?.performClose(nil) }
        }
        .keyboardShortcut(AppChord.closeTab.key, modifiers: AppChord.closeTab.modifiers)
        // **`isSuspended`, never `close == nil`** — see the note above. A `nil` value is an
        // auxiliary window and this item is its Close; disabling there is the regression the
        // three-state value was introduced to undo.
        .disabled(close?.isSuspended == true)
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

/// The Organize menu's five sections, ticked.
///
/// **Flat, because this IS the menu.** An earlier cut nested these in a `Menu("Organize")` inside
/// View, which put a second item reading "Organize" four rows under the ⌘3 workspace item — one
/// menu, one word, two meanings. The word now appears once per menu, exactly as View ▸ Compare ⌘2
/// and the Compare menu have coexisted since v4.0.
struct OrganizeLensCommands: View {
    @FocusedValue(\.organizeLens) private var lens

    var body: some View {
        ForEach(OrganizeLens.allCases) { section in
            Toggle(section.title, isOn: Binding(
                get: { lens?.current == section },
                // Clicking the ticked section asks to un-choose it, which has no meaning —
                // Organize always shows something — so `false` is dropped, as the workspace
                // toggles drop theirs.
                set: { isOn in if isOn { lens?.select(section) } }
            ))
            .disabled(lens == nil)
        }
    }
}

/// File ▸ the row menu's verbs.
///
/// Titles match the row menu's exactly — the same act must not have two names — except that
/// "Ignore in comparison" is menu-cased here, where menus live.
struct PaneRowVerbCommands: View {
    @FocusedValue(\.paneRowVerbs) private var verbs

    var body: some View {
        Button("Open in New Tab") { verbs?.openInNewTab?() }
            .disabled(verbs?.openInNewTab == nil)
        Button("Quick Look") { verbs?.quickLook?() }
            .disabled(verbs?.quickLook == nil)
        Button("Reveal in Finder") { verbs?.revealInFinder?() }
            .disabled(verbs?.revealInFinder == nil)
        Divider()
        // No chord: ↩ is the one people try, and it cannot be a menu key equivalent — it outranks
        // every default button in the app. Order step 6 teaches the pane to handle it directly.
        Button("Rename") { verbs?.rename?() }
            .disabled(verbs?.rename == nil)
        // Ellipses: both open the destination picker rather than moving anything.
        Button("Copy to…") { verbs?.chooseDestination?(false) }
            .disabled(verbs?.chooseDestination == nil)
        Button("Move to…") { verbs?.chooseDestination?(true) }
            .disabled(verbs?.chooseDestination == nil)
        Button(verbs?.ignore?.title ?? "Ignore in Comparison") { verbs?.ignore?.run() }
            .disabled(verbs?.ignore == nil)
    }
}

/// Organize ▸ the four verbs, aimed at the pane selection.
///
/// They were under File until `c75927be` gave Organize a menu of its own — where the sections above
/// them already were, and where a verb about Organize belongs. `fileNoLongerCarriesTheVerbs` is what
/// stops File keeping a stale copy.
struct OrganizeVerbCommands: View {
    @FocusedValue(\.organizeVerbs) private var verbs

    var body: some View {
        // Ellipsis: it opens the lens on a question, it does not file anything.
        Button("Organize This Folder…") { verbs?.organizeFolder?() }
            .disabled(verbs?.organizeFolder == nil)
        Button("Find Duplicates of This") { verbs?.findDuplicates?() }
            .disabled(verbs?.findDuplicates == nil)
        // The two name verbs are a different act from the two above — those ask Organize a question
        // about a folder, these repair or bless a name — and unlike them they are available only
        // for a name the app would rewrite, so they are usually the greyed half of this menu.
        Divider()
        Button("Fix Name…") { verbs?.fixName?() }
            .disabled(verbs?.fixName == nil)
        Button("Always Allow This Name") { verbs?.keepName?() }
            .disabled(verbs?.keepName == nil)
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

/// **View ▸ Sidebar** — the Favorites / Sources / Recents column, ⌃⌘S.
///
/// `nil` — and therefore disabled — wherever the column cannot be drawn, which
/// `FolderSidebarModel.appliesTo(workspaceSupportsSidebar:panesCollapsed:)` decides once for the
/// item, the column and the refresh together. Every shipping workspace supports the column as of
/// v4.4, so in practice the live `nil` is the collapsed-panes one — see `shortcutFolderSidebar`
/// for the reasoning. **Disabled rather than absent**, matching the toolbar button beside it: a
/// toolbar that reflowed as the gate flipped is unsettling, and a greyed row still answers "where
/// did the sidebar go" where a missing one leaves the reader looking for it.
struct ToggleFolderSidebarCommand: View {
    @FocusedValue(\.folderSidebarVisible) private var folderSidebar

    var body: some View {
        Toggle("Sidebar", isOn: folderSidebar ?? .constant(false))
            .keyboardShortcut(AppChord.folderSidebar.key, modifiers: AppChord.folderSidebar.modifiers)
            .disabled(folderSidebar == nil)
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

/// Compare ▸ the four directional transfers — ⌘← / ⌘→ copy, ⇧ makes it a move.
///
/// **One `View` for four items**, because the four differ only in two booleans and a title, and
/// four hand-written copies is four chances for one of them to register a chord its title
/// contradicts. The chord and the badge on the header button both come from
/// `AppChord.transfer(toRight:isMove:)`.
///
/// **The titles name the providers, not the sides.** "Copy to Dropbox" is what the header buttons,
/// the row menu and the floating action bar all say; a Compare menu reading "Copy to Right" would
/// be the only surface in the app asking the reader to work out which side that is.
struct TransferCommands: View {
    @FocusedValue(\.transferSelection) private var transfer

    var body: some View {
        ForEach(Self.items, id: \.self) { item in
            let chord = AppChord.transfer(toRight: item.toRight, isMove: item.isMove)
            Button(Self.title(item, transfer)) {
                // ⌘← and ⌘→ are NSText's move-to-beginning/end-of-line, and a menu key equivalent
                // outranks the field editor — so with rows selected and the caret in the
                // differences search, ⌘→ would transfer files instead of moving the cursor. This
                // is the objection the old `.onKeyPress` scoping existed to avoid, answered rather
                // than dodged. Through `TextEditingChord.route` like the other five colliding
                // chords: it reads the first responder ONCE, where the hand-rolled branch this
                // replaces read it twice and could in principle answer two different questions.
                TextEditingChord.route(
                    editorAction: { editor in
                        switch (item.toRight, item.isMove) {
                        case (true, false):  editor.moveToEndOfLine(nil)
                        case (false, false): editor.moveToBeginningOfLine(nil)
                        case (true, true):   editor.moveToEndOfLineAndModifySelection(nil)
                        case (false, true):  editor.moveToBeginningOfLineAndModifySelection(nil)
                        }
                    },
                    fileAction: { transfer?.run(item.toRight ? .copyToRight : .copyToLeft, item.isMove) })
            }
            .keyboardShortcut(chord.key, modifiers: chord.modifiers)
            .disabled(transfer == nil)
        }
    }

    struct Item: Hashable {
        let toRight: Bool
        let isMove: Bool
    }

    /// Copy before Move, left before right — the order the header's own buttons sit in.
    static let items: [Item] = [
        Item(toRight: false, isMove: false), Item(toRight: true, isMove: false),
        Item(toRight: false, isMove: true), Item(toRight: true, isMove: true),
    ]

    /// The item's title. Static so the naming rule can be tested without a scene — and so the
    /// disabled form is written down rather than improvised: with nothing published there are no
    /// provider names to use, and "Copy to Right" is the honest fallback for a dead item.
    static func title(_ item: Item, _ transfer: TransferShortcut?) -> String {
        let verb = item.isMove ? "Move" : "Copy"
        guard let transfer else { return "\(verb) to \(item.toRight ? "Right" : "Left")" }
        return "\(verb) to \(item.toRight ? transfer.rightName : transfer.leftName)"
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
