import Testing
import Foundation
@testable import FileExplorer
import Sync

/// The picker's pure decisions: which column stack shows a given folder, and what its Move button
/// refuses to do.
@Suite struct DestinationPickerTests {

    // MARK: - Opening position

    /// Opening on a nested folder must show the whole stack down to it, not just the root.
    @Test func testABrowsePathIsDerivedForANestedFolder() {
        let path = DestinationPicker.browsePath(for: "/p/Health/Medical", under: "/p")
        #expect(path.components == ["Health", "Medical"])
    }

    /// The root itself rests at one column.
    @Test func testTheRootRestsAtASingleColumn() {
        #expect(DestinationPicker.browsePath(for: "/p", under: "/p").isEmpty)
    }

    /// Trailing slashes on either side must not produce an empty leading component, which would
    /// render a nameless column.
    @Test func testTrailingSlashesAreNormalised() {
        let path = DestinationPicker.browsePath(for: "/p/Health/", under: "/p/")
        #expect(path.components == ["Health"])
    }

    /// A folder outside the root cannot be drawn as a stack under it, so it rests at the root —
    /// the only honest stack available. Reached when a recent survives a provider change.
    @Test func testAFolderOutsideTheRootRestsAtTheRoot() {
        #expect(DestinationPicker.browsePath(for: "/elsewhere/Deep", under: "/p").isEmpty)
    }

    /// Prefix aliasing: "/p" must not claim "/pictures/Deep" and render it as a stack.
    @Test func testASiblingSharingAPrefixIsNotUnderTheRoot() {
        #expect(DestinationPicker.browsePath(for: "/pictures/Deep", under: "/p").isEmpty)
    }

    // MARK: - Round trip

    /// Every folder under the root resolves back to itself through the stack, which is what makes
    /// the footer path and the highlighted column agree.
    @Test func testTheStackResolvesBackToTheFolderItOpenedOn() {
        let root = "/p"
        for folder in ["/p", "/p/Health", "/p/Health/Medical/Kaiser/Son"] {
            let path = DestinationPicker.browsePath(for: folder, under: root)
            #expect(path.currentDirectory(treeRoot: root) == folder, "round trip failed for \(folder)")
        }
    }
}
