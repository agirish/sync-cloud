import Testing
import Foundation
@testable import FileExplorer
import Sync

/// The return trip. Navigating in the Tree writes the outline's own state and nothing else, so
/// flipping back to Columns replayed the stack the columns were parked with — the last place the
/// user was, but not the most recent one.
///
/// The Tree's half of "where you are" is an expansion, which can have several branches open at once
/// and names no single folder; its selection is the one unambiguous place, and that is what carries
/// back.
@Suite struct PaneTreeCarryBackTests {

    private let root = "/Users/me/Documents"

    /// `Claude/Projects` exists as folders; `Investing` is a FILE inside `Projects`, and `Ghost` is
    /// nothing at all — the two ways a selected path stops naming a folder.
    private func index() -> PaneChildrenIndex {
        func dir(_ path: String, _ name: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: name, isDirectory: true, children: children)
        }
        let projects = dir("\(root)/Claude/Projects", "Projects", [
            FileNode(id: "\(root)/Claude/Projects/Investing", name: "Investing", isDirectory: false),
        ])
        let tree = PaneTree(side: .left, version: 1, nodes: [
            dir("\(root)/Claude", "Claude", [projects]),
            dir("\(root)/Family", "Family"),
        ])
        return PaneChildrenIndex(tree: tree, treeRoot: root)
    }

    @Test func testASelectedFolderBecomesTheColumnStack() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Claude/Projects"],
                                             treeRoot: root, index: index())
        #expect(carried?.components == ["Claude", "Projects"])
    }

    /// Finder's rule, and the one that makes a click on a file useful: the columns open on the
    /// folder holding it, with the file in the last column.
    @Test func testASelectedFileOpensTheFolderHoldingIt() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Claude/Projects/Investing"],
                                             treeRoot: root, index: index())
        #expect(carried?.components == ["Claude", "Projects"], "the file itself is not a column")
    }

    /// A row selected at the top level says "the root" — a real answer, and the columns have to come
    /// back out to it rather than keep the stack they were parked with.
    @Test func testATopLevelSelectionComesAllTheWayBackOut() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Family"],
                                             treeRoot: root, index: index())
        #expect(carried?.components == ["Family"])
    }

    /// Two selected rows are two answers, and picking either would be a guess. Nil leaves the parked
    /// stack exactly where it was.
    @Test func testAMultipleSelectionNamesNoPlace() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Family", "\(root)/Claude"],
                                             treeRoot: root, index: index())
        #expect(carried == nil)
        #expect(FileTreeView.carryBack(selection: [], treeRoot: root, index: index()) == nil,
                "nothing selected is likewise no answer, not an answer of `the root`")
    }

    /// A selection left over from another root — the pane re-rooted, or the provider changed — must
    /// not be read as a path inside this one.
    @Test func testASelectionFromAnotherRootIsIgnored() {
        #expect(FileTreeView.carryBack(selection: ["/somewhere/else/Claude"],
                                       treeRoot: root, index: index()) == nil)
        // And the root itself is not a path INSIDE the root: `hasPrefix` must respect the boundary,
        // or a sibling root sharing a name prefix would resolve as if it were inside.
        #expect(FileTreeView.carryBack(selection: [root], treeRoot: root, index: index()) == nil)
        #expect(FileTreeView.carryBack(selection: ["\(root)-other/Claude"],
                                       treeRoot: root, index: index()) == nil)
    }

    /// A path the tree no longer has stops at the deepest surviving folder, so a stale selection can
    /// never leave the columns standing somewhere that is gone.
    @Test func testAStaleSelectionStopsAtTheDeepestSurvivingFolder() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Claude/Ghost/Deeper"],
                                             treeRoot: root, index: index())
        #expect(carried?.components == ["Claude"])
    }

    /// A trailing slash on the root would otherwise leave a leading empty component, and the stack
    /// would name `…//Claude` — a folder no index has.
    @Test func testTheRootIsNormalisedBeforeTheStackIsBuilt() {
        let carried = FileTreeView.carryBack(selection: ["\(root)/Family"],
                                             treeRoot: root + "/", index: index())
        #expect(carried?.components == ["Family"])
    }

    // MARK: - Below a folder link

    /// The walk's own spellings, as `ColumnsBelowALinkTests` measures them on a real link
    /// (`/r/link → /t`): the link and its child keep the link's spelling, and from there down the
    /// ids are where it leads. Under a root spelled `/var/…` every id comes back `/private/var/…`.
    private func linkedIndex(root: String = "/r", resolved: String = "/t/sub") -> PaneChildrenIndex {
        func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
        }
        let deeper = dir("\(resolved)/deeper", [
            FileNode(id: "\(resolved)/deeper/e.txt", name: "e.txt", isDirectory: false),
        ])
        let tree = PaneTree(side: .left, version: 1, nodes: [
            dir("\(root)/link", [dir("\(root)/link/sub", [deeper])]),
            dir("\(root)/plain"),
        ])
        return PaneChildrenIndex(tree: tree, treeRoot: root, links: [:])
    }

    /// **A selection below a link carries back the names down to it**, which its id cannot give:
    /// `/t/sub/deeper/e.txt` is not under `/r`, so the flip back to Columns kept the parked stack.
    @Test func testASelectionBelowAFolderLinkCarriesBackTheNamesDownToIt() {
        let carried = FileTreeView.carryBack(selection: ["/t/sub/deeper/e.txt"],
                                             treeRoot: "/r", index: linkedIndex())
        #expect(carried?.components == ["link", "sub", "deeper"])
    }

    /// And under a root spelled through a link, where no id at all is spelled under the root.
    @Test func testASelectionUnderARootSpelledThroughALinkCarriesBack() {
        let index = linkedIndex(root: "/var/x/r", resolved: "/private/var/x/r/link/sub")
        let carried = FileTreeView.carryBack(selection: ["/private/var/x/r/link/sub/deeper"],
                                             treeRoot: "/var/x/r", index: index)
        #expect(carried?.components == ["link", "sub", "deeper"])
    }

    /// **A folder the tree holds twice carries back along the route its id names.** Home holds
    /// `~/Dropbox` and the folder it leads to; below the link both rows carry one id, and the
    /// selection cannot say which was clicked. The id is under the root, so it is the answer — the
    /// names would take whichever route sorts first, here the link.
    @Test func testASelectionTheTreeHoldsTwiceCarriesBackTheRouteItsIdNames() {
        func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
        }
        let tree = PaneTree(side: .left, version: 1, nodes: [
            dir("/r/Dropbox", [dir("/r/Dropbox/x", [dir("/r/Library/Dropbox/x/y")])]),
            dir("/r/Library", [dir("/r/Library/Dropbox", [dir("/r/Library/Dropbox/x", [dir("/r/Library/Dropbox/x/y")])])]),
        ])
        let index = PaneChildrenIndex(tree: tree, treeRoot: "/r", links: [:])
        let carried = FileTreeView.carryBack(selection: ["/r/Library/Dropbox/x/y"], treeRoot: "/r", index: index)
        #expect(carried?.components == ["Library", "Dropbox", "x", "y"])
    }

    /// A selection the tree does not hold is still no answer — the names are looked up in the tree,
    /// so the fallback cannot invent a place out of an unrelated path.
    @Test func testASelectionTheLinkedTreeDoesNotHoldIsStillIgnored() {
        #expect(FileTreeView.carryBack(selection: ["/t/elsewhere/x.txt"], treeRoot: "/r", index: linkedIndex()) == nil)
    }
}
