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

/// ⌃⇥'s payload: where it will move focus, and doing it.
///
/// The name travels with the action for the same reason `FoldAllAction` carries its verb — the menu
/// item is the only resting surface that says which pane is focused now, so it has to read "Focus
/// Dropbox" rather than "Switch Pane". A menu title that named neither pane would leave the state
/// completely unreadable.
struct PaneFocusSwitch: Equatable {
    /// The pane this moves focus TO, by its provider display name.
    let targetName: String
    let run: () -> Void

    /// The closure is identity-free, so equality is the name — which is the only part the menu
    /// renders, and the only part a republish can meaningfully change.
    static func == (lhs: PaneFocusSwitch, rhs: PaneFocusSwitch) -> Bool {
        lhs.targetName == rhs.targetName
    }
}

extension FocusedValues {
    /// The workspace bar's selection, as the same binding the segments write — going through it
    /// (never `selectedWorkspace` directly) is what re-homes the Tidy rail on a switch.
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
}

// MARK: - ContentView's half

/// The eleven focused-value publications, bundled into one modifier with every field explicitly
/// typed. Not organizational: chained inline in `ContentView.body` — an expression the compiler
/// already strains under — the ternaries and property references pushed type-checking past its
/// time limit and failed the build. Stored properties give inference nothing to solve.
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

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.workspaceSelection, effectiveWorkspace)     // ⌘1–⌘5
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
            suspended: pendingDestination != nil
        )
    }

    var shortcutRescan: (() -> Void)? {
        isScanning ? nil : forceRefreshAction
    }
    /// The pane the pane-scoped chords act on — the same rule ⌘F resolves its field with, so
    /// "the focused pane" can never mean two different panes to two different shortcuts.
    private var shortcutTargetIsLeft: Bool { paneSearchTargetIsLeft }

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
        let mode = layoutMode == .singleSource
            ? railViewModeBinding : paneViewModeBinding(isLeft: shortcutTargetIsLeft)
        guard PaneViewMode.showsPreviewToggle(mode: mode.wrappedValue) else { return nil }
        return $previewColumnEnabled
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

/// View ▸ the five workspaces, ⌘1–⌘5 in bar order. `Toggle`s, so the menu carries the checkmark
/// a `Picker` would have given for free — a `Picker` can't put a distinct chord on each option.
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
        Button(focus.map { "Focus \($0.targetName)" } ?? "Focus Other Pane") { focus?.run() }
            .keyboardShortcut(AppChord.switchPaneFocus.key, modifiers: AppChord.switchPaneFocus.modifiers)
            .disabled(focus == nil)
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
