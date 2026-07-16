import Testing
import Foundation
@testable import Sync

/// Coverage for the pane action bar's "N selected · SIZE" total: recursive folder sums, symlink
/// exclusion, and the count-always / size-when-known text.
@Suite struct SelectionSummaryTests {

    private func file(_ id: String, _ size: Int, symlink: Bool = false) -> FileNode {
        FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: false,
                 fileSize: size, isSymbolicLink: symlink ? true : nil)
    }
    private func dir(_ id: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: id, name: (id as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    @Test func fileContributesItsOwnSize() {
        #expect(SelectionSummary.totalBytes(of: file("/a.txt", 1000)) == 1000)
    }

    @Test func folderSumsItsDescendantsRecursively() {
        let tree = dir("/D", [file("/D/a", 100), file("/D/b", 250), dir("/D/sub", [file("/D/sub/c", 50)])])
        #expect(SelectionSummary.totalBytes(of: tree) == 400)
    }

    @Test func symlinkContributesZeroEvenInsideAFolder() {
        #expect(SelectionSummary.totalBytes(of: file("/link", 9999, symlink: true)) == 0)
        let tree = dir("/D", [file("/D/real", 100), file("/D/link", 9999, symlink: true)])
        #expect(SelectionSummary.totalBytes(of: tree) == 100)
    }

    @Test func emptyOrUnwalkedFolderIsZero() {
        #expect(SelectionSummary.totalBytes(of: dir("/D", [])) == 0)
        #expect(SelectionSummary.totalBytes(of: FileNode(id: "/D", name: "D", isDirectory: true, children: nil)) == 0)
    }

    @Test func totalSumsAcrossASelection() {
        let selection = [file("/a", 100), file("/b", 200), file("/link", 5, symlink: true)]
        #expect(SelectionSummary.totalBytes(of: selection) == 300)
    }

    @Test func overlappingSelectionCountsNestedBytesOnce() {
        // ⌘-click can select a folder AND items inside it; the bytes under the folder must not be
        // counted again for the nested selections. The COUNT stays the raw selection count.
        let inner = file("/D/a", 100)
        let sub = dir("/D/sub", [file("/D/sub/c", 50)])
        let folder = dir("/D", [inner, file("/D/b", 250), sub])
        let selection = [folder, inner, sub]

        #expect(SelectionSummary.totalBytes(of: selection) == 400)  // not 400 + 100 + 50
        #expect(SelectionSummary.text(for: selection).hasPrefix("3 selected · "))
    }

    @Test func unexploredFolderUndercountsToItsWalkedChildren() {
        // A folder whose children weren't fully walked contributes only what IS known — the
        // total is a floor, never a guess. Fully unwalked (children nil) → 0.
        let partial = FileNode(id: "/D", name: "D", isDirectory: true,
                               children: [file("/D/seen", 100)], isUnexplored: true)
        #expect(SelectionSummary.totalBytes(of: partial) == 100)
        let unwalked = FileNode(id: "/E", name: "E", isDirectory: true,
                                children: nil, isUnexplored: true)
        #expect(SelectionSummary.totalBytes(of: unwalked) == 0)
    }

    @Test func symlinkedDirectoryContributesZeroDespiteChildren() {
        // A symlinked DIRECTORY is skipped wholesale — its subtree mirrors a target that may
        // already be counted elsewhere in the tree, so even walked children must not add bytes.
        let linkedDir = FileNode(id: "/L", name: "L", isDirectory: true,
                                 children: [file("/L/inner", 500)], isSymbolicLink: true)
        #expect(SelectionSummary.totalBytes(of: linkedDir) == 0)
    }

    /// The full matrix in one selection: overlap (folder + nested picks), a symlink, an
    /// unexplored dir, and an empty dir together. Pins the interplay — nested bytes counted
    /// once, symlink zero, unexplored floor, empty zero — while the COUNT stays the raw
    /// selection count.
    @Test func mixedSelectionMatrixPinsTotalAndText() {
        let inner = file("/D/a", 100)
        let folder = dir("/D", [inner,
                                file("/D/link", 9_999, symlink: true),
                                dir("/D/sub", [file("/D/sub/c", 50)])])
        let unexplored = FileNode(id: "/U", name: "U", isDirectory: true,
                                  children: [file("/U/seen", 25)], isUnexplored: true)
        let empty = dir("/Empty", [])
        let loneLink = file("/lonelink", 7_777, symlink: true)

        // folder(150) once — inner is nested inside it; unexplored floor 25; empty 0; links 0.
        let selection = [folder, inner, unexplored, empty, loneLink]
        #expect(SelectionSummary.totalBytes(of: selection) == 175)
        #expect(SelectionSummary.text(for: selection) == "5 selected · \(FileSyncManager.formatBytes(175))")
    }

    @Test func textAlwaysShowsCountAndSizeWhenKnown() {
        let withSize = SelectionSummary.text(for: [file("/a", 1000), file("/b", 2000)])
        #expect(withSize.hasPrefix("2 selected · "))
        // Nothing with a known size → the count stands alone (no dangling separator).
        #expect(SelectionSummary.text(for: [dir("/D", [])]) == "1 selected")
    }
}
