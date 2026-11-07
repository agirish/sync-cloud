import Testing
import Foundation
@testable import FileExplorer

/// The Filing card's destination peek, and above all its cancellation rule. "Try another" cancels
/// the `.task(id: dest.path)` read, but the listing runs in a `Task.detached`, which doesn't inherit
/// cancellation. Without the post-await check a slow cloud listing could write last, and the card
/// would show a wrong item count while the user decides whether to file there.
@Suite struct DestinationPeekTests {

    /// A temp directory containing `visible` ordinary entries plus `hidden` dot-files.
    private func makeDirectory(visible: Int, hidden: Int = 0) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<visible {
            try Data().write(to: dir.appendingPathComponent("file\(i).txt"))
        }
        for i in 0..<hidden {
            try Data().write(to: dir.appendingPathComponent(".hidden\(i)"))
        }
        return dir.path
    }

    @Test func countsVisibleEntriesAndSkipsDotFiles() async throws {
        let path = try makeDirectory(visible: 3, hidden: 2)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(await DestinationPeek.itemCount(atPath: path) == 3)
    }

    @Test func anEmptyFolderCountsZeroRatherThanReadingAsUnknown() async throws {
        let path = try makeDirectory(visible: 0)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // 0 and nil mean different things to the card: 0 renders "· empty", nil renders no peek.
        #expect(await DestinationPeek.itemCount(atPath: path) == 0)
    }

    @Test func anUnreadablePathPublishesNothing() async {
        #expect(await DestinationPeek.itemCount(atPath: "/nonexistent-\(UUID().uuidString)") == nil)
    }

    @Test func aSupersededReadPublishesNothingEvenThoughTheListingSucceeded() async throws {
        let path = try makeDirectory(visible: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // The "Try another" race: the read is cancelled while the detached listing finishes, so
        // its count is real (3) but describes a destination the card has left.
        let read = Task { await DestinationPeek.itemCount(atPath: path) }
        read.cancel()

        // nil, not 3: a superseded read must not overwrite the count for the destination on screen.
        #expect(await read.value == nil)
    }
}
