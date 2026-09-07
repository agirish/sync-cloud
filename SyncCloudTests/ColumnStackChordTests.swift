import Foundation
import Testing
import Sync
import FileExplorer
@testable import SyncCloud

/// ⌘↓ and ⌘↑ — the column-stack chords (roadmap RD5, decided 2026-09-06).
///
/// **What these hold is the axis**, which is the thing RD5 was deferred on for seventeen days. A
/// pane has two positions: the comparison scope, which reloads the tree and re-runs the scan, and
/// the column stack, which costs nothing. Both rules under test return a `PaneBrowsePath` or `nil`
/// — there is no return value here that *can* express a scope move, which is the strongest form
/// this invariant can take.
///
/// The `shortcut…` properties that call them live on `ContentView`, whose `init` is private and
/// whose `@State` nothing can construct, so the rules were lifted into `PaneLogic` to be reachable
/// at all. That lift is the reason these are tests rather than a source scan.
@Suite struct ColumnStackChordTests {

    private let root = "/r"

    /// `Documents/{Invoices, Notes.md}` and a sibling `Photos`.
    private func node(_ path: String, isDirectory: Bool) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
    }

    private var documents: FileNode { node("/r/Documents", isDirectory: true) }
    private var invoices: FileNode { node("/r/Documents/Invoices", isDirectory: true) }
    private var notes: FileNode { node("/r/Documents/Notes.md", isDirectory: false) }
    private var photos: FileNode { node("/r/Photos", isDirectory: true) }

    // MARK: - ⌘↓

    @Test func theOpenChordDrillsTheSelectedFolderAtTheDeepestColumn() throws {
        let stack = PaneBrowsePath()
        let next = try #require(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [documents], treeRoot: root))
        #expect(next.components == ["Documents"])
    }

    /// The property that makes the chord the same act as the click it replaces: from one column
    /// deep, drilling a row in *that* column appends rather than replacing.
    @Test func theOpenChordAppendsRatherThanRestartingTheStack() throws {
        let stack = PaneBrowsePath(components: ["Documents"])
        let next = try #require(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [invoices], treeRoot: root))
        #expect(next.components == ["Documents", "Invoices"])
    }

    /// **The rule with the most reason to be got wrong.** `drill(into:atDepth:)` discards every
    /// column past `atDepth`, so a selection held in an EARLIER column would silently close the
    /// columns to its right. Refused instead: a click there says where it landed, a chord does not.
    @Test func theOpenChordRefusesARowThatIsNotInTheDeepestColumn() {
        let stack = PaneBrowsePath(components: ["Documents", "Invoices"])
        // `Photos` lives in the ROOT column while two columns are open past it.
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [photos], treeRoot: root) == nil)
    }

    @Test func theOpenChordRefusesAFile() {
        let stack = PaneBrowsePath(components: ["Documents"])
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [notes], treeRoot: root) == nil)
    }

    @Test func theOpenChordRefusesAMultipleSelectionAndAnEmptyOne() {
        let stack = PaneBrowsePath()
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [documents, photos], treeRoot: root) == nil)
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [], treeRoot: root) == nil)
    }

    // MARK: - ⌘↑

    @Test func theEnclosingFolderChordClosesTheRightmostColumn() throws {
        let stack = PaneBrowsePath(components: ["Documents", "Invoices"])
        let next = try #require(PaneLogic.enclosingFolderStack(drawsColumns: true, stack: stack))
        #expect(next.components == ["Documents"])
    }

    /// **The rule that distinguishes ⌘↑ from ⌘[, and the reason both exist.**
    ///
    /// `⌘[` pops this same stack and then falls through to the pane's focus history once it is
    /// empty, stepping the comparison scope back and costing a reload. ⌘↑ returns `nil` here, so
    /// the menu item disables and the scope never moves. Deleting the `!stack.isEmpty` guard — the
    /// "simplification" this is written against — makes ⌘↑ pop an empty stack and fail this test.
    @Test func theEnclosingFolderChordStopsAtTheRootColumn() {
        #expect(PaneLogic.enclosingFolderStack(drawsColumns: true, stack: PaneBrowsePath()) == nil)
    }

    /// Popped columns stay walkable by `›`, exactly as they are when `‹` pops them: the two are
    /// the same move on the same axis.
    @Test func theEnclosingFolderChordLeavesTheColumnWalkableAgain() throws {
        let stack = PaneBrowsePath(components: ["Documents", "Invoices"])
        let next = try #require(PaneLogic.enclosingFolderStack(drawsColumns: true, stack: stack))
        #expect(next.canAdvance)
        var forward = next
        // Called OUTSIDE `#expect`: `advance()` is mutating, and the macro's autoclosure makes its
        // operand immutable — `#expect(forward.advance())` does not compile.
        let walkedBack = forward.advance()
        #expect(walkedBack)
        #expect(forward.components == ["Documents", "Invoices"])
    }

    // MARK: - Tree view

    /// Both chords are dead in Tree, which draws no columns. Asserted for each, because they have
    /// separate guards and one could be dropped without the other.
    @Test func neitherChordActsInTreeView() {
        let stack = PaneBrowsePath(components: ["Documents"])
        #expect(PaneLogic.enclosingFolderStack(drawsColumns: false, stack: stack) == nil)
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: false, stack: stack, selection: [invoices], treeRoot: root) == nil)
        // The positive control: the SAME inputs with columns on screen both answer, so the nils
        // above came from `drawsColumns` and not from a fixture that could never have worked.
        #expect(PaneLogic.enclosingFolderStack(drawsColumns: true, stack: stack) != nil)
        #expect(PaneLogic.openSelectedFolderStack(
            drawsColumns: true, stack: stack, selection: [invoices], treeRoot: root) != nil)
    }

    // MARK: - The wiring, scanned

    /// **⌘↑ must not be rewired into ⌘[**, which is the one change that would undo RD5's decision
    /// without failing any behavioural test above: `enclosingFolderStack` would still be correct
    /// and still be tested, and simply have no caller.
    ///
    /// The rules test what the chord DOES once it is asked; nothing there can see which rule the
    /// menu item asks. So this reads the source: `shortcutEnclosingFolder` must resolve its stack
    /// through `PaneLogic.enclosingFolderStack`, and must not mention the focus history at all —
    /// `canGoBack`/`goBack` are how ⌘[ steps the comparison scope back, and reaching them from here
    /// would put a rescan behind a chord whose whole contract is that it never moves the scope.
    ///
    /// A source scan, not a behaviour: `ContentView.init` is private and its `@State` cannot be
    /// constructed, which is the same reason `BrowseWorkspaceCallSiteTests` scans rather than
    /// drives. The `#require`s are its positive controls — a renamed member or a truncated read
    /// fails loudly instead of passing an empty scan.
    @MainActor @Test func theEnclosingFolderChordIsNotWiredToTheFocusHistory() throws {
        let source = try ShortcutCommandsTests.publisherSource()
        let body = ShortcutCommandsTests.codeOnly(
            try ShortcutCommandsTests.memberBody("var shortcutEnclosingFolder", in: source))
        try #require(body.count > 40, "shortcutEnclosingFolder read as near-empty — the scan would be vacuous")
        #expect(body.contains("PaneLogic.enclosingFolderStack"),
                "⌘↑ no longer resolves its stack through the rule this suite tests")
        #expect(!body.contains("canGoBack") && !body.contains("goBack"),
                "⌘↑ reaches the pane's focus history — that is ⌘[, and it steps the comparison scope back")
    }

    /// The same for ⌘↓: it must go through the rule, and through `applyColumnNavigation` rather
    /// than writing the binding, so the seam link mirrors it exactly as it mirrors a column click.
    @MainActor @Test func theOpenChordGoesThroughTheSameDoorAColumnClickUses() throws {
        let source = try ShortcutCommandsTests.publisherSource()
        let body = ShortcutCommandsTests.codeOnly(
            try ShortcutCommandsTests.memberBody("var shortcutOpenSelectedFolder", in: source))
        try #require(body.count > 40, "shortcutOpenSelectedFolder read as near-empty — the scan would be vacuous")
        #expect(body.contains("PaneLogic.openSelectedFolderStack"),
                "⌘↓ no longer resolves its stack through the rule this suite tests")
        #expect(body.contains("applyColumnNavigation"),
                "⌘↓ does not go through the door a column click uses — the linked pane will not mirror it")
    }
}
