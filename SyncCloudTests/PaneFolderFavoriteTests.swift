import Testing
import Foundation
import Sync
import Dashboard
@testable import SyncCloud

/// **"Add to Favorites" on a folder in a pane** — the third route to the list the sidebar draws.
@Suite struct PaneFolderFavoriteTests {

    private func place(_ path: String, isDirectory: Bool = true,
                       root: String = "/Users/x/Dropbox") -> (root: String, relativePath: String)? {
        PaneActionDelegate.favoritePlace(nodePath: path, isDirectory: isDirectory, paneRoot: root)
    }

    @Test func aFolderInsideThePaneResolvesToItsRelativePath() throws {
        let resolved = try #require(place("/Users/x/Dropbox/Health/Scans"))
        #expect(resolved.relativePath == "Health/Scans")
        #expect(resolved.root == FolderJumpStore.key(forRoot: "/Users/x/Dropbox"))
    }

    /// Favorites is a list of places a pane can be pointed at.
    @Test func aFileIsRefused() {
        #expect(place("/Users/x/Dropbox/Health/scan.pdf", isDirectory: false) == nil)
    }

    /// The same rule the pane header's jump menu applies: a source's own root already has a row in
    /// the sidebar's Locations section, so favoriting it would add a second row for one place.
    @Test func thePaneRootItselfIsRefused() {
        #expect(place("/Users/x/Dropbox") == nil)
    }

    /// **A bare string prefix must not claim a sibling.** `/Users/x/Dropbox` does not contain
    /// `/Users/x/DropboxOld`, and a favorite filed under the wrong root points somewhere real and
    /// wrong — which is worse than pointing nowhere.
    @Test func aSiblingWithASharedPrefixIsNotInside() {
        #expect(place("/Users/x/DropboxOld/Health") == nil)
    }

    @Test func aPaneWithNoSourceHasNoAnswer() {
        #expect(place("/Users/x/Dropbox/Health", root: "") == nil)
    }

    /// The pane's root arrives from settings, which may still hold a tilde.
    @Test func aTildeRootIsExpandedBeforeItIsCompared() throws {
        let home = NSHomeDirectory()
        let resolved = try #require(PaneActionDelegate.favoritePlace(
            nodePath: home + "/Documents/Taxes", isDirectory: true, paneRoot: "~/Documents"))
        #expect(resolved.relativePath == "Taxes")
    }
}
