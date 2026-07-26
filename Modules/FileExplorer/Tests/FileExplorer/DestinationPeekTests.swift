import Testing
import Foundation
@testable import FileExplorer

/// Pins the Filing card's destination "peek" (G6) — and above all its cancellation rule.
///
/// The card loads the count from `.task(id: dest.path)`, so "Try another" cancels the in-flight
/// read and starts one for the new folder. But the listing itself runs in a `Task.detached`, which
/// does NOT inherit cancellation: a slow cloud directory keeps going and can resolve after the new
/// destination's read has already published its count. Without the post-await check the loser of
/// that race writes last, and the card states a wrong item count for the folder it is showing —
/// while the user is deciding whether to file into it.
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

        // Exactly the "Try another" race: this read's task is cancelled while the detached listing
        // is still allowed to finish (detached work never sees the cancellation), so the count it
        // produces is real — 3 — but it describes the destination the card has already left.
        let read = Task { await DestinationPeek.itemCount(atPath: path) }
        read.cancel()

        // nil, NOT 3: a superseded read must publish nothing rather than overwrite the count that
        // belongs to the destination now on screen.
        #expect(await read.value == nil)
    }
}
