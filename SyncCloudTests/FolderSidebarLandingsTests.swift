@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// The landing folders Recents subtracts: the host half of the rule in `CrossSourceRecentsTests`.
/// The rule, `FolderJumpStore.mostRecentAcrossRoots`, is pure and tested where it lives. What it
/// can't see is whether the map handed to it is keyed the way the store keys its recents. Get that
/// wrong and nothing fails or logs: Recents fills with every source's landing ("Documents, My
/// Drive, Documents…"), a silent no-op.
@Suite struct FolderSidebarLandingsTests {

    private func provider(_ id: String, root: String, openAt: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "folder.fill",
                      rootPath: root, openAt: openAt, type: .localFolder)
    }

    /// A typical install: every connected source lands somewhere, and those landings are what
    /// Recents would fill up with.
    @Test func everySourceContributesItsLandingUnderTheStoresKey() {
        let landings = ContentView.folderSidebarLandings([
            provider("dropbox", root: "/Users/x/Library/CloudStorage/Dropbox", openAt: "Documents"),
            provider("drive-emp", root: "/Users/x/Library/CloudStorage/GoogleDrive-emp", openAt: "My Drive"),
        ])
        #expect(landings["/Users/x/Library/CloudStorage/Dropbox"] == "Documents")
        #expect(landings["/Users/x/Library/CloudStorage/GoogleDrive-emp"] == "My Drive")
    }

    /// The keying, the half that fails silently. A folder source keeps the `~` in its stored path
    /// while the store keys recents on the expanded spelling (`FolderJumpStore.key(forRoot:)`), so a
    /// map built from the raw `rootPath` would match no root and subtract nothing.
    @Test func aFolderSourcesTildeIsExpandedTheWayTheStoreExpandsIt() {
        let landings = ContentView.folderSidebarLandings([
            provider("local", root: "~/Documents", openAt: "Finance")
        ])
        let key = FolderJumpStore.key(forRoot: "~/Documents")
        #expect(!key.hasPrefix("~"), "the fixture is not exercising an expansion")
        #expect(landings[key] == "Finance")
        #expect(landings["~/Documents"] == nil, "the raw spelling is keyed, which matches no recent")
    }

    /// A trailing slash is the other spelling of one root, and `key(forRoot:)` settles it. Stated
    /// here because a source path is user-editable in Settings.
    @Test func aTrailingSlashIsTheSameRoot() {
        let landings = ContentView.folderSidebarLandings([
            provider("local", root: "/Users/x/Sync/", openAt: "Documents")
        ])
        #expect(landings["/Users/x/Sync"] == "Documents")
    }

    /// A source that opens at its root carries an empty landing rather than being left out; it
    /// subtracts nothing, because `recordVisit` never writes a recent for a root.
    @Test func aSourceThatLandsOnItsRootCarriesAnEmptyLanding() {
        let landings = ContentView.folderSidebarLandings([
            provider("icloud", root: "/Users/x/iCloud", openAt: "")
        ])
        #expect(landings["/Users/x/iCloud"] == "")
    }

    /// No sources is the first-run state: an empty map, which the store reads as "subtract
    /// nothing".
    @Test func noSourcesYieldNoLandings() {
        #expect(ContentView.folderSidebarLandings([]).isEmpty)
    }
}
