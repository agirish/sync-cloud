import Foundation
import Testing
@testable import Dashboard

/// **"Show in Enclosing Folder"** — the row that names where a favorite lives.
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

    /// **Two different nils.** A row already at the root has no enclosing folder a pane can be
    /// pointed at; an unavailable row has no answer at all. Both must refuse, and the menu item is
    /// absent rather than disabled, so it never names a place that does not exist.
    @Test func aRootRowAndAnUnavailableRowBothRefuse() {
        #expect(FolderSidebarModel.enclosingFolder(of: row("")) == nil)
        #expect(FolderSidebarModel.enclosingFolder(of: row("Work", isAvailable: false)) == nil)
    }

    /// The parent is a destination, and the only thing that decides where a jump lands is the root
    /// plus the relative path — so a favorite in another account must keep ITS root, not borrow the
    /// pane's. `openFolderSidebarRow` switches sources on exactly this value.
    @Test func theParentKeepsTheRowsOwnRoot() throws {
        let parent = try #require(FolderSidebarModel.enclosingFolder(
            of: row("Health/Scans", root: "/Dropbox", sourceName: "Dropbox")))
        #expect(parent.root == "/Dropbox")
        #expect(parent.relativePath == "Health")
    }

    /// With no source name to fall back on, a top-level row still has to read as something.
    @Test func aRootWithNoSourceNameFallsBackToTheRootsOwnLeaf() throws {
        let parent = try #require(FolderSidebarModel.enclosingFolder(
            of: row("Work", root: "/Volumes/Backup", sourceName: nil)))
        #expect(parent.name == "Backup")
    }
}
