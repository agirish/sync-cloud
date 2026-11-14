@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// The landing folders Recents subtracts: the host half of `FolderJumpStore.mostRecentAcrossRoots`,
/// tested in `CrossSourceRecentsTests`. What the rule can't see is whether the map handed to it is
/// keyed as the store keys its recents; get that wrong and nothing fails or logs, and Recents fills
/// with every source's landing ("Documents, My Drive, Documents…").
@Suite struct FolderSidebarLandingsTests {
    private func provider(_ id: String, root: String, openAt: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "folder.fill",
                      rootPath: root, openAt: openAt, type: .localFolder)
    }

    /// Every connected source lands somewhere, and those landings are what Recents would fill with.
    @Test func everySourceContributesItsLandingUnderTheStoresKey() {
        let landings = ContentView.folderSidebarLandings([
            provider("dropbox", root: "/Users/x/Library/CloudStorage/Dropbox", openAt: "Documents"),
            provider("drive-emp", root: "/Users/x/Library/CloudStorage/GoogleDrive-emp", openAt: "My Drive"),
        ])
        #expect(landings["/Users/x/Library/CloudStorage/Dropbox"] == "Documents")
        #expect(landings["/Users/x/Library/CloudStorage/GoogleDrive-emp"] == "My Drive")
    }

    /// A folder source keeps the `~` in its stored path while the store keys recents on the expanded
    /// spelling (`FolderJumpStore.key(forRoot:)`), so a map from the raw `rootPath` would match no root
    /// and subtract nothing.
    @Test func aFolderSourcesTildeIsExpandedTheWayTheStoreExpandsIt() {
        let landings = ContentView.folderSidebarLandings([
            provider("local", root: "~/Documents", openAt: "Finance")
        ])
        let key = FolderJumpStore.key(forRoot: "~/Documents")
        #expect(!key.hasPrefix("~"), "the fixture is not exercising an expansion")
        #expect(landings[key] == "Finance")
        #expect(landings["~/Documents"] == nil, "the raw spelling is keyed, which matches no recent")
    }

    /// A trailing slash (a source path is user-editable) is one root, which `key(forRoot:)` settles. A
    /// source opening at its root carries an empty landing rather than being left out.
    @Test(arguments: [("/Users/x/Sync/", "Documents", "/Users/x/Sync"),
                      ("/Users/x/iCloud", "", "/Users/x/iCloud")])
    func aSourceIsKeyedOnItsRootsOneSpelling(root: String, openAt: String, key: String) {
        let landings = ContentView.folderSidebarLandings([provider("local", root: root, openAt: openAt)])
        #expect(landings[key] == openAt)
    }

    /// No sources (the first run): an empty map, read as "subtract nothing".
    @Test func noSourcesYieldNoLandings() {
        #expect(ContentView.folderSidebarLandings([]).isEmpty)
    }
}
