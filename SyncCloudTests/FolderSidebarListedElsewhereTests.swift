@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// What Recents subtracts because the column already offers it: the host half of
/// `FolderSidebarModel.rows`, which is tested where it lives. What it can't see is whether the map
/// handed to it is keyed and spelled as the recents are; get either wrong and nothing fails or
/// logs (the silent no-op `FolderSidebarLandingsTests` also guards against).
@Suite struct FolderSidebarListedElsewhereTests {
    private func row(_ path: String, band: SidebarSourceRow.Band = .shortcut) -> SidebarSourceRow {
        SidebarSourceRow(id: path, name: (path as NSString).lastPathComponent, detail: nil,
                         symbol: "folder", absolutePath: path, band: band,
                         state: .unknown, isAvailable: true)
    }

    /// A Favorites place inside a source becomes that source's relative path, the spelling a recent
    /// is stored under.
    @Test func aPlaceInsideASourceBecomesThatSourcesRelativePath() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Desktop"), row("/Users/x/Documents")],
            roots: ["/Users/x"], links: [:])
        #expect(listed["/Users/x"] == ["Desktop", "Documents"])
    }

    /// The root itself yields nothing: it relativizes to the empty path, and a root is never a recent
    /// (`FolderJumpStore.recordVisit` refuses one).
    @Test func aRowThatIsTheRootItselfContributesNothing() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Dropbox", band: .cloud)], roots: ["/Users/x/Dropbox"], links: [:])
        #expect(listed["/Users/x/Dropbox"] == nil)
    }

    /// A place outside every source is absent: an external disk says nothing about what is inside an
    /// iCloud account.
    @Test func aPlaceOutsideEverySourceIsNotListedUnderIt() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Volumes/Backup", band: .device)], roots: ["/Users/x/Dropbox"], links: [:])
        #expect(listed.isEmpty)
    }

    /// iCloud Drive's `Desktop` and `Documents` are links into the container, so `~/Documents` and the
    /// recent `Documents` under the iCloud root are one folder no prefix comparison relates.
    /// `PathBoundary.relativize` reads the links table; a lexical-only version would subtract nothing.
    @Test func aLinkedFolderIsRelativizedThroughTheLinksTable() {
        let container = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs"
        let links: PathBoundary.LinkedFolders = [container: ["Documents": "/Users/x/Documents"]]
        // The fixture only means something if the two paths are unrelated by prefix.
        #expect(!"/Users/x/Documents".hasPrefix(container))

        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Documents")], roots: [container], links: links)
        #expect(listed[container] == ["Documents"])
    }

    /// One path can be inside two roots: a source over home and one over `Sync` each get their own
    /// relative path for the place.
    @Test func onePlaceCanBeListedUnderMoreThanOneRoot() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Sync/Shared")], roots: ["/Users/x", "/Users/x/Sync"], links: [:])
        #expect(listed["/Users/x"] == ["Sync/Shared"])
        #expect(listed["/Users/x/Sync"] == ["Shared"])
    }

    /// A folder source keeps its `~` in Settings while recents are keyed on the expanded spelling,
    /// so a row's tilde is expanded here; a raw `~/Desktop` matches no root and subtracts nothing.
    @Test func aRowsTildeIsExpandedBeforeItIsMatched() {
        let home = NSHomeDirectory()
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("~/Desktop")], roots: [home], links: [:])
        #expect(listed[home] == ["Desktop"])
    }

    /// No rows, or no sources (a first run has none): the empty map, read as "subtract nothing".
    @Test func nothingToMatchYieldsAnEmptyMap() {
        #expect(ContentView.folderSidebarListedElsewhere([], roots: ["/Users/x"], links: [:]).isEmpty)
        #expect(ContentView.folderSidebarListedElsewhere([row("/Users/x/Desktop")],
                                                         roots: [], links: [:]).isEmpty)
    }
}
