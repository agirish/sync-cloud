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
            listing: listing,
            highlighted: "",
            onPathAt: nil,
            accent: .accentColor,
            onOpen: { _ in }
        )
    }

    /// Nothing read yet is a spinner, not a claim. A folder that couldn't be read says so in the
    /// words the column shows, never "Empty"; one with no subfolders still says "Empty".
    @Test(arguments: [
        (nil, .loading),
        (DestinationFolderListing(folders: [], outcome: .unreadable), .message("Can’t be read")),
        (DestinationFolderListing(folders: [], outcome: .listed), .message("Empty")),
        (DestinationFolderListing(folders: [DestinationFolder(path: "/p/Health/Medical")], outcome: .listed),
         .rows),
    ] as [(DestinationFolderListing?, DestinationColumn.State)])
    func theColumnDraws(_ listing: DestinationFolderListing?, _ expected: DestinationColumn.State) {
        #expect(column(listing).state == expected)
    }
}
