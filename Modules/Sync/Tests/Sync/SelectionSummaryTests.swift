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

    @Test func textAlwaysShowsCountAndSizeWhenKnown() {
        let withSize = SelectionSummary.text(for: [file("/a", 1000), file("/b", 2000)])
        #expect(withSize.hasPrefix("2 selected · "))
        // Nothing with a known size → the count stands alone (no dangling separator).
        #expect(SelectionSummary.text(for: [dir("/D", [])]) == "1 selected")
    }
}
