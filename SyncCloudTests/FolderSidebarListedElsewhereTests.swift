@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// **What Recents subtracts because the column already offers it** — the host half of the rule
/// asserted in `FolderSidebarModelTests`.
///
/// The rule itself is `FolderSidebarModel.rows`, which is pure and tested where it lives. What
/// cannot be seen from there is whether the map handed to it is keyed and spelled the way the
/// recents are: get either wrong and nothing fails, nothing logs, and the section comes back
/// exactly as it was — the same silent no-op `FolderSidebarLandingsTests` exists for.
@Suite struct FolderSidebarListedElsewhereTests {

    private func row(_ path: String, band: SidebarSourceRow.Band = .shortcut) -> SidebarSourceRow {
        SidebarSourceRow(id: path, name: (path as NSString).lastPathComponent, detail: nil,
                         symbol: "folder", absolutePath: path, band: band,
                         state: .unknown, isAvailable: true)
    }

    /// The ordinary case: a Favorites place inside a source becomes that source's relative path,
    /// which is the spelling a recent is stored under.
    @Test func aPlaceInsideASourceBecomesThatSourcesRelativePath() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Desktop"), row("/Users/x/Documents")],
            roots: ["/Users/x"], links: [:])
        #expect(listed["/Users/x"] == ["Desktop", "Documents"])
    }

    /// **The root itself yields nothing.** A Locations row IS its source, so it relativizes to the
    /// empty path — and a root is never a recent (`FolderJumpStore.recordVisit` refuses to write
    /// one), so an entry for it cannot exist to be subtracted. `""` in the set would be a member
    /// nothing reads.
    @Test func aRowThatIsTheRootItselfContributesNothing() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Dropbox", band: .cloud)], roots: ["/Users/x/Dropbox"], links: [:])
        #expect(listed["/Users/x/Dropbox"] == nil)
    }

    /// A place outside every source names no relative path and is simply absent — an external disk
    /// in Locations says nothing about what is inside an iCloud account.
    @Test func aPlaceOutsideEverySourceIsNotListedUnderIt() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Volumes/Backup", band: .device)], roots: ["/Users/x/Dropbox"], links: [:])
        #expect(listed.isEmpty)
    }

    /// **The case this is worth having for.** iCloud Drive's `Desktop` and `Documents` are links
    /// into the container, so the Favorites place at `~/Documents` and the recent recorded as
    /// `Documents` under the iCloud root are one folder spelled two ways that no prefix comparison
    /// relates. `PathBoundary.relativize` reads the links table; a lexical-only version would
    /// subtract nothing here and the duplicate row would stay.
    @Test func aLinkedFolderIsRelativizedThroughTheLinksTable() {
        let container = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs"
        let links: PathBoundary.LinkedFolders = [container: ["Documents": "/Users/x/Documents"]]
        // The fixture only means something if the two paths are unrelated by prefix.
        #expect(!"/Users/x/Documents".hasPrefix(container))

        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Documents")], roots: [container], links: links)
        #expect(listed[container] == ["Documents"])
    }

    /// **Per root, and the same path can be inside two of them.** A source over the home folder and
    /// a source over `Sync` both contain their own view of a place, and each root's set is that
    /// root's own arithmetic.
    @Test func onePlaceCanBeListedUnderMoreThanOneRoot() {
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("/Users/x/Sync/Shared")], roots: ["/Users/x", "/Users/x/Sync"], links: [:])
        #expect(listed["/Users/x"] == ["Sync/Shared"])
        #expect(listed["/Users/x/Sync"] == ["Shared"])
    }

    /// A folder source keeps its `~` in Settings while the recents are keyed on the expanded
    /// spelling. The roots handed in are already `FolderJumpStore.key(forRoot:)`-normalised, so
    /// the tilde a ROW carries is what has to be expanded here — a raw `~/Desktop` matches no
    /// root at all and subtracts nothing.
    @Test func aRowsTildeIsExpandedBeforeItIsMatched() {
        let home = NSHomeDirectory()
        let listed = ContentView.folderSidebarListedElsewhere(
            [row("~/Desktop")], roots: [home], links: [:])
        #expect(listed[home] == ["Desktop"])
    }

    /// No rows, or no sources: the empty map, which `FolderSidebarModel.rows` reads as "subtract
    /// nothing". Both are real states — a first run has no folder sources at all.
    @Test func nothingToMatchYieldsAnEmptyMap() {
        #expect(ContentView.folderSidebarListedElsewhere([], roots: ["/Users/x"], links: [:]).isEmpty)
        #expect(ContentView.folderSidebarListedElsewhere([row("/Users/x/Desktop")],
                                                         roots: [], links: [:]).isEmpty)
    }
}
