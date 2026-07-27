import Testing
import Foundation
import Events
@testable import Sync

/// `PaneBrowsePath` is the Columns view's position *inside* a loaded tree, kept deliberately
/// separate from the pane's `relativePath` (its comparison scope). Two behaviours here are
/// load-bearing rather than conveniences:
///
///   - `currentDirectory` is what New Folder, paste and background drops target. If it can name a
///     path that does not exist, those operations act somewhere the user cannot see.
///   - `pruned` is the only thing standing between a republish that deletes a folder and a column
///     stack still pointing into it.
///
/// The fixtures build real `PaneChildrenIndex` values rather than stubbing lookups, so the two
/// types are pinned against each other the way the pane uses them.
@Suite struct PaneBrowsePathTests {

    private let root = "/r"

    /// `Documents/{Invoices/{a.pdf}, Notes.md}` plus an empty `Photos`.
    private func index() -> PaneChildrenIndex {
        let invoices = FileNode(id: "/r/Documents/Invoices", name: "Invoices", isDirectory: true,
                                children: [FileNode(id: "/r/Documents/Invoices/a.pdf", name: "a.pdf", isDirectory: false)])
        let notes = FileNode(id: "/r/Documents/Notes.md", name: "Notes.md", isDirectory: false)
        let documents = FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [invoices, notes])
        let photos = FileNode(id: "/r/Photos", name: "Photos", isDirectory: true, children: [])
        return PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: [documents, photos]), treeRoot: root)
    }

    // MARK: - Resting state

    /// Empty is the pane that exists today: one column listing the tree root. If this ever
    /// produced zero columns, the default view would render nothing at all.
    @Test func testRestingPathIsOneColumnAtTheRoot() {
        let path = PaneBrowsePath()
        #expect(path.isEmpty)
        #expect(path.depth == 0)
        #expect(path.relativePath == "")
        #expect(path.columnDirectories(treeRoot: root) == ["/r"])
        #expect(path.currentDirectory(treeRoot: root) == "/r")
    }

    @Test func testColumnDirectoriesWalkDownFromTheRoot() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(path.columnDirectories(treeRoot: root) == ["/r", "/r/Documents", "/r/Documents/Invoices"])
        // One column per level plus the root column — the count the layout budgets width for.
        #expect(path.columnDirectories(treeRoot: root).count == path.depth + 1)
        #expect(path.currentDirectory(treeRoot: root) == "/r/Documents/Invoices")
    }

    /// A trailing slash on the root must not double the separator: these strings are compared
    /// exactly against `FileNode.id`, so "/r//Documents" matches nothing.
    @Test func testTrailingSlashOnRootDoesNotDoubleSeparators() {
        let path = PaneBrowsePath(components: ["Documents"])
        #expect(path.columnDirectories(treeRoot: "/r/") == ["/r", "/r/Documents"])
        #expect(path.currentDirectory(treeRoot: "/r///") == "/r/Documents")
    }

    // MARK: - Navigation

    @Test func testDrillFromAnEarlierColumnClosesTheDeeperOnes() {
        var path = PaneBrowsePath(components: ["Documents", "Invoices"])
        // Clicking a folder in column 0 while three columns are open.
        path.drill(into: "Photos", atDepth: 0)
        #expect(path.components == ["Photos"])
        #expect(path.depth == 1)
    }

    @Test func testDrillAtTheDeepestColumnAppends() {
        var path = PaneBrowsePath(components: ["Documents"])
        path.drill(into: "Invoices", atDepth: 1)
        #expect(path.components == ["Documents", "Invoices"])
    }

    /// Selecting a file truncates but opens nothing — otherwise a file would get a column.
    @Test func testTruncateClosesDeeperColumnsWithoutOpeningOne() {
        var path = PaneBrowsePath(components: ["Documents", "Invoices"])
        path.truncate(toDepth: 1)
        #expect(path.components == ["Documents"])
    }

    /// A depth past the end must not fabricate components; a negative one must not crash.
    @Test func testOutOfRangeDepthsAreClamped() {
        var path = PaneBrowsePath(components: ["Documents"])
        path.drill(into: "X", atDepth: 99)
        #expect(path.components == ["Documents", "X"])

        var other = PaneBrowsePath(components: ["Documents"])
        other.drill(into: "Y", atDepth: -5)
        #expect(other.components == ["Y"])

        var third = PaneBrowsePath(components: ["A", "B"])
        third.truncate(toDepth: 99)
        #expect(third.components == ["A", "B"])
    }

    /// `popLast` returning false is the signal that `‹` should fall through to the focus history.
    /// If it ever returned true at the root, Back would silently do nothing there.
    @Test func testPopLastReportsWhetherItConsumedTheClick() {
        var path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(path.popLast() == true)
        #expect(path.components == ["Documents"])
        #expect(path.popLast() == true)
        #expect(path.isEmpty)
        // At the root there is nothing left to pop — the caller must take over.
        #expect(path.popLast() == false)
        #expect(path.isEmpty)
    }

    @Test func testEmptyComponentsAreNeverStored() {
        #expect(PaneBrowsePath(components: ["", "Documents", ""]).components == ["Documents"])
        #expect(PaneBrowsePath(relativePath: "/Documents//Invoices/").components == ["Documents", "Invoices"])
        #expect(PaneBrowsePath(relativePath: "").isEmpty)

        var path = PaneBrowsePath(components: ["Documents"])
        path.drill(into: "", atDepth: 1)
        #expect(path.components == ["Documents"])
    }

    // MARK: - Pruning against a republished tree

    @Test func testPruneKeepsAPathThatStillResolves() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(path.pruned(against: index(), treeRoot: root) == path)
    }

    /// The regression this exists for: a folder disappears under the user's feet. The stack must
    /// fall back to the deepest surviving ancestor, not to the root and not stay where it was.
    @Test func testPruneStopsAtTheFirstMissingFolder() {
        let path = PaneBrowsePath(components: ["Documents", "Gone", "Deeper"])
        let pruned = path.pruned(against: index(), treeRoot: root)
        #expect(pruned.components == ["Documents"])
        #expect(pruned.currentDirectory(treeRoot: root) == "/r/Documents")
    }

    /// A file is not a column. Pruning must reject it, or `currentDirectory` would name a file as
    /// the folder New Folder creates into.
    @Test func testPruneRejectsAFileAsAColumn() {
        let path = PaneBrowsePath(components: ["Documents", "Notes.md"])
        #expect(path.pruned(against: index(), treeRoot: root).components == ["Documents"])
    }

    /// An empty directory is still a directory — it must survive pruning and show an empty column.
    @Test func testPruneKeepsAnEmptyDirectory() {
        let path = PaneBrowsePath(components: ["Photos"])
        #expect(path.pruned(against: index(), treeRoot: root) == path)
    }

    /// Everything gone (a provider swap between publishes) collapses to the resting column rather
    /// than leaving the pane pointed into a tree that no longer exists.
    @Test func testPruneAgainstAnUnrelatedTreeCollapsesToRest() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(path.pruned(against: PaneChildrenIndex.empty(side: .left), treeRoot: root).isEmpty)
    }

    /// Mutation guard: a `pruned` that returned `self` unconditionally would pass every
    /// keep-case above. Pin that a dropped component actually changes the value.
    @Test func testPruneReturnsADifferentValueWhenItDropsSomething() {
        let path = PaneBrowsePath(components: ["Documents", "Gone"])
        #expect(path.pruned(against: index(), treeRoot: root) != path)
    }
}
