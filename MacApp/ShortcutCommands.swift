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
// the ⌥-hold reveal (⌘R arrives as ⌥⌘R and matches nothing) — look, release, press. The one
// exception is ⌥⌘F, whose chord contains ⌥ and therefore matches while the reveal is up.

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
}

// MARK: - ContentView's half

/// The ten focused-value publications, bundled into one modifier with every field explicitly
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

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.workspaceSelection, workspace)     // ⌘1–⌘5
            .focusedSceneValue(\.paneGoBack, goBack)                // ⌘[
            .focusedSceneValue(\.paneGoForward, goForward)          // ⌘]
            .focusedSceneValue(\.rescanPanes, rescan)               // ⌘R
            .focusedSceneValue(\.newFolderInFocusedPane, newFolder) // ⇧⌘N
            .focusedSceneValue(\.showHiddenFiles, hiddenFiles)      // ⇧⌘.
            .focusedSceneValue(\.previewColumn, previewColumn)      // ⇧⌘P
            .focusedSceneValue(\.infoInspector, inspector)          // ⌘I
            .focusedSceneValue(\.differencesListVisible, differencesList)  // ⌘D
            .focusedSceneValue(\.deleteSelection, delete)           // ⌘⌫
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
            delete: shortcutDeleteSelection
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
        guard layoutMode == .compare, actionHandler != nil else { return nil }
        let nodes = activeSelectionNodes
        guard !nodes.isEmpty else { return nil }
        return { actionHandler?.confirmDelete(nodes) }
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
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            .disabled(selection == nil)
        }
    }
}

struct GoBackCommand: View {
    @FocusedValue(\.paneGoBack) private var go

    var body: some View {
        Button("Back") { go?() }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(go == nil)
    }
}

struct GoForwardCommand: View {
    @FocusedValue(\.paneGoForward) private var go

    var body: some View {
        Button("Forward") { go?() }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(go == nil)
    }
}

struct RescanCommand: View {
    @FocusedValue(\.rescanPanes) private var rescan

    var body: some View {
        Button("Rescan") { rescan?() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(rescan == nil)
    }
}

struct NewFolderCommand: View {
    @FocusedValue(\.newFolderInFocusedPane) private var newFolder

    var body: some View {
        // Ellipsis: it opens the name field, it doesn't create anything yet.
        Button("New Folder…") { newFolder?() }
            .keyboardShortcut("n", modifiers: [.shift, .command])
            .disabled(newFolder == nil)
    }
}

struct DeleteSelectionCommand: View {
    @FocusedValue(\.deleteSelection) private var delete

    var body: some View {
        // Ellipsis: the action confirms before touching anything (`NativeAlerts.confirmDelete`).
        Button("Delete Selection…") { delete?() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(delete == nil)
    }
}

struct ToggleHiddenFilesCommand: View {
    @FocusedValue(\.showHiddenFiles) private var showHiddenFiles

    var body: some View {
        Toggle("Hidden Files", isOn: showHiddenFiles ?? .constant(false))
            .keyboardShortcut(".", modifiers: [.shift, .command])
            .disabled(showHiddenFiles == nil)
    }
}

struct TogglePreviewColumnCommand: View {
    @FocusedValue(\.previewColumn) private var previewColumn

    var body: some View {
        Toggle("Preview Column", isOn: previewColumn ?? .constant(false))
            .keyboardShortcut("p", modifiers: [.shift, .command])
            .disabled(previewColumn == nil)
    }
}

struct ToggleInspectorCommand: View {
    @FocusedValue(\.infoInspector) private var infoInspector

    var body: some View {
        Toggle("Info Inspector", isOn: infoInspector ?? .constant(false))
            .keyboardShortcut("i", modifiers: .command)
            .disabled(infoInspector == nil)
    }
}

struct ToggleDifferencesListCommand: View {
    @FocusedValue(\.differencesListVisible) private var differencesList

    var body: some View {
        Toggle("Differences List", isOn: differencesList ?? .constant(false))
            .keyboardShortcut("d", modifiers: .command)
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
        .keyboardShortcut("f", modifiers: [.option, .command])
        .disabled(fold == nil)
    }
}

struct ReviewDifferencesCommand: View {
    @FocusedValue(\.startDifferencesReview) private var start

    var body: some View {
        Button("Review Differences") { start?() }
            .keyboardShortcut("r", modifiers: [.shift, .command])
            .disabled(start == nil)
    }
}

struct VerifyDifferencesCommand: View {
    @FocusedValue(\.verifyDifferences) private var verify

    var body: some View {
        Button("Verify Differences") { verify?() }
            .keyboardShortcut("v", modifiers: [.shift, .command])
            .disabled(verify == nil)
    }
}
