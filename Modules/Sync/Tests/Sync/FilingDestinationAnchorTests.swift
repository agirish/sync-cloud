import Testing
import Foundation
@testable import Sync

/// Pins filing's destination-anchor guard — the stat `transferItems` has always had and the filing
/// path never did.
///
/// `performFiling` creates the destination with `withIntermediateDirectories: true`, so a tree that
/// went away since the scan (a provider unmounted, an external volume ejected) was silently
/// recreated as an ordinary local folder. Filing is a MOVE, so the file left a live tree to sit in a
/// dead one the provider never syncs — under a success banner. The guard stats the folder the new
/// segments hang off; everything above what we are asked to create must already be there.
@Suite struct FilingDestinationAnchorTests {

    private func write(_ url: URL, bytes: Int = 512) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// The headline case: the anchor (`Documents/Vehicles`) is gone, so the two new segments have
    /// nothing legitimate to hang off. Nothing is created and nothing moves.
    @MainActor
    @Test func aVanishedAnchorRefusesTheMoveAndCreatesNothing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(src)
        // Deliberately NOT created: this is the provider subtree that has gone away.
        let anchor = root.appendingPathComponent("Documents/Vehicles")

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: src.path, fileName: "Tesla Policy.pdf",
                                          size: 512, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: anchor.appendingPathComponent("Tesla/Insurance").path,
                                     confidence: .medium, reasons: [],
                                     newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let result = await manager.applyFilingSuggestion(suggestion, to: dest)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path), "the file must stay put")
        #expect(!FileManager.default.fileExists(atPath: anchor.path),
                "the vanished tree must NOT be recreated")
        // The suggestion stays listed so the user can retry once the volume is back.
        #expect(manager.filingSuggestions.count == 1)
        // And the alert names the actual condition rather than a generic failure. `SyncError`
        // carries the cause in `reason`; `message` is always the "Couldn't sync …" headline.
        #expect(manager.currentError?.reason?.contains("no longer available") == true)
    }

    /// A destination the user browsed to carries no new segments, so the anchor IS the folder. If it
    /// vanished between the pick and the apply, refusing beats re-creating it.
    @MainActor
    @Test func aPickedFolderThatVanishedIsRefusedRatherThanRecreated() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorPicked")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Downloads/Statement.pdf")
        try write(src)
        let picked = root.appendingPathComponent("Documents/Statements")   // never created

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: src.path, fileName: "Statement.pdf",
                                          size: 512, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: picked.path, confidence: .high,
                                     reasons: ["You chose this folder"], newSegments: [])
        manager.filingSuggestions = [suggestion]

        let result = await manager.applyFilingSuggestion(suggestion, to: dest)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(!FileManager.default.fileExists(atPath: picked.path))
    }

    /// Mutation guard: with the anchor PRESENT the same call must still move the file and create the
    /// new segments. Without this the guard could be satisfied by refusing everything.
    @MainActor
    @Test func aLiveAnchorStillCreatesTheNewSegmentsAndMoves() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorLive")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(src)
        // The anchor exists this time; only Tesla/Insurance below it are new.
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: src.path, fileName: "Tesla Policy.pdf",
                                          size: 512, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance").path,
                                     confidence: .medium, reasons: [],
                                     newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let result = await manager.applyFilingSuggestion(suggestion, to: dest)

        let moved = root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/Tesla Policy.pdf")
        #expect(result == .moved)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }

    /// `newSegments` is scan-time data and can be stale. When the whole path has since been created,
    /// the guard stats a shallower ancestor that exists and lets the move through — a stale plan must
    /// not refuse a destination that is demonstrably there.
    @MainActor
    @Test func aStaleNewSegmentsListStillAllowsAnExistingDestination() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorStale")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Downloads/Report.pdf")
        try write(src)
        // The full destination exists NOW, though the suggestion still calls its leaves "new".
        try write(root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/.keep"), bytes: 1)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: src.path, fileName: "Report.pdf",
                                          size: 512, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance").path,
                                     confidence: .medium, reasons: [],
                                     newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let result = await manager.applyFilingSuggestion(suggestion, to: dest)

        #expect(result == .moved)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/Report.pdf").path))
    }
}
