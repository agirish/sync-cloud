import Testing
import Sync
@testable import FileExplorer

/// What one column of the destination picker decides to draw.
///
/// Three states: loading, a message, or rows. A folder that can't be opened must not say "Empty".
/// A SwiftUI view can't be driven from a unit test, so the decision is a value the body switches
/// over, and this asserts the value.
@Suite struct DestinationColumnStateTests {

    private func column(_ listing: DestinationFolderListing?) -> DestinationColumn {
        DestinationColumn(
            directory: "/p/Health",
            listing: listing,
            highlighted: "",
            onPathAt: nil,
            accent: .accentColor,
            onOpen: { _ in }
        )
    }

    @Test func nothingReadYetIsASpinnerNotAClaim() {
        #expect(column(nil).state == .loading)
    }

    @Test func aFolderThatCouldNotBeReadDoesNotSayItIsEmpty() {
        let unreadable = DestinationFolderListing(folders: [], outcome: .unreadable)

        // The words are the user-visible half, so they are asserted, not just "some message".
        #expect(column(unreadable).state == .message("Can’t be read"))
        #expect(column(unreadable).state != .message("Empty"))
    }

    @Test func aFolderWithNoSubfoldersStillSaysEmpty() {
        let empty = DestinationFolderListing(folders: [], outcome: .listed)
        #expect(column(empty).state == .message("Empty"))
    }

    @Test func aFolderWithSubfoldersDrawsRows() {
        let listed = DestinationFolderListing(
            folders: [DestinationFolder(path: "/p/Health/Medical")], outcome: .listed)
        #expect(column(listed).state == .rows)
    }
}
