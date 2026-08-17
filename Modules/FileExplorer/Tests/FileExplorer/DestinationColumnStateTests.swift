import Testing
import Sync
@testable import FileExplorer

/// What one column of the destination picker decides to draw.
///
/// The column has three states and used to have two: a listing that came back with no folders was
/// drawn as **"Empty"** whether the folder held nothing or could not be opened at all. Since a
/// SwiftUI view cannot be driven from a unit test, the decision is a value the body switches over,
/// and this asserts the value.
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

        // The words matter — this is the whole user-visible half of the fix — so they are asserted
        // rather than merely "some message".
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
