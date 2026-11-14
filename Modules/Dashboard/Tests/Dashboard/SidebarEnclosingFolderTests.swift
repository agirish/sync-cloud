import Foundation
import Testing
@testable import Dashboard

/// "Show in Enclosing Folder", the row that names where a favorite lives.
@Suite struct SidebarEnclosingFolderTests {

    private func row(_ relativePath: String, root: String = "/iCloud",
                     sourceName: String? = "iCloud",
                     isAvailable: Bool = true) -> FolderSidebarRow {
        FolderSidebarRow(group: .pinned, root: root, sourceName: sourceName,
                         relativePath: relativePath,
                         name: (relativePath as NSString).lastPathComponent,
                         detail: nil, isAvailable: isAvailable)
    }

    @Test func aNestedFolderResolvesToItsParent() throws {
        let parent = try #require(FolderSidebarModel.enclosingFolder(of: row("Clients/Legal/2026")))
        #expect(parent.relativePath == "Clients/Legal")
        #expect(parent.name == "Legal", "the row must read as the parent, not as the row it came from")
        #expect(parent.root == "/iCloud")
    }

    /// A top-level folder's enclosing folder is the source root — a real destination, so the item
    /// is offered.
    @Test func aTopLevelFolderResolvesToTheSourceRoot() throws {
        let parent = try #require(FolderSidebarModel.enclosingFolder(of: row("Work")))
        #expect(parent.relativePath.isEmpty)
        #expect(parent.name == "iCloud", "with no parent path left, the row is the source itself")
    }

    /// Two different nils: a row at the root has no enclosing folder to point a pane at, and an
    /// unavailable row has no answer at all. Both refuse, so the menu item is absent, not disabled,
    /// and never names a place that doesn't exist.
    @Test func aRootRowAndAnUnavailableRowBothRefuse() {
        #expect(FolderSidebarModel.enclosingFolder(of: row("")) == nil)
        #expect(FolderSidebarModel.enclosingFolder(of: row("Work", isAvailable: false)) == nil)
    }

    /// With no source name to fall back on, a top-level row still has to read as something.
    @Test func aRootWithNoSourceNameFallsBackToTheRootsOwnLeaf() throws {
        let parent = try #require(FolderSidebarModel.enclosingFolder(
            of: row("Work", root: "/Volumes/Backup", sourceName: nil)))
        #expect(parent.name == "Backup")
    }
}
