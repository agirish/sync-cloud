@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// **The landing folders Recents subtracts** — the host half of the rule asserted in
/// `CrossSourceRecentsTests`.
///
/// The rule itself is `FolderJumpStore.mostRecentAcrossRoots`, which is pure and tested where it
/// lives. What cannot be seen from there is whether the map handed to it is keyed the way the store
/// keys its recents: get that wrong and nothing fails, nothing logs, and the section comes back
/// exactly as it was — which is what "Documents, Documents, My Drive, My Drive, Documents" down the
/// whole column looked like before, so a silent no-op is indistinguishable from the bug.
@Suite struct FolderSidebarLandingsTests {

    private func provider(_ id: String, root: String, openAt: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "folder.fill",
                      rootPath: root, openAt: openAt, type: .localFolder)
    }

    /// The shape of his own install, 2026-08-27: every connected source lands somewhere, and the
    /// landing is what the sidebar's Recents section was filling up with.
    @Test func everySourceContributesItsLandingUnderTheStoresKey() {
        let landings = ContentView.folderSidebarLandings([
            provider("dropbox", root: "/Users/x/Library/CloudStorage/Dropbox", openAt: "Documents"),
            provider("drive-hpe", root: "/Users/x/Library/CloudStorage/GoogleDrive-hpe", openAt: "My Drive"),
        ])
        #expect(landings["/Users/x/Library/CloudStorage/Dropbox"] == "Documents")
        #expect(landings["/Users/x/Library/CloudStorage/GoogleDrive-hpe"] == "My Drive")
    }

    /// **The keying, which is the half that fails silently.** A folder source keeps the `~` in its
    /// stored path while the store keys its recents on the expanded spelling — the exact defect
    /// `FolderJumpStore.key(forRoot:)` exists to close — so a map built from `rootPath` raw would
    /// match no root at all and subtract nothing.
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

    /// A source that opens at its root carries an empty landing rather than being left out — it
    /// subtracts nothing, because `recordVisit` will not write a recent for a root.
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
