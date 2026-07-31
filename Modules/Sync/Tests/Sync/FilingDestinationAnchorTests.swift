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

    // MARK: The anchor derivation itself

    /// The ordinary case: one level up per new segment.
    @Test func theAnchorIsTheDestinationMinusItsNewSegments() {
        let dest = FilingDestination(path: "/root/Documents/Vehicles/Tesla/Insurance",
                                     confidence: .medium, reasons: [], newSegments: ["Tesla", "Insurance"])
        #expect(FileSyncManager.filingAnchor(for: dest, under: "/root").path
                == "/root/Documents/Vehicles")

        let one = FilingDestination(path: "/root/Documents/Vehicles/Tesla",
                                    confidence: .medium, reasons: [], newSegments: ["Tesla"])
        #expect(FileSyncManager.filingAnchor(for: one, under: "/root").path == "/root/Documents/Vehicles")

        let none = FilingDestination(path: "/root/Documents/Vehicles",
                                     confidence: .medium, reasons: [], newSegments: [])
        #expect(FileSyncManager.filingAnchor(for: none, under: "/root").path == "/root/Documents/Vehicles")
    }

    /// The clamp. An over-long `newSegments` would otherwise walk past the provider root and
    /// saturate at "/", which always exists — the guard would still "pass" while checking nothing.
    /// `FilingEngine` builds `newSegments` as a suffix of the destination's own segments so it
    /// cannot over-count today; this keeps that a property of the anchor function rather than of a
    /// caller far away.
    @Test func anOverLongNewSegmentsListIsClampedToTheProviderRoot() {
        let dest = FilingDestination(path: "/root/Documents/Vehicles",
                                     confidence: .medium, reasons: [],
                                     newSegments: ["a", "b", "c", "d", "e", "f"])
        #expect(FileSyncManager.filingAnchor(for: dest, under: "/root").path == "/root")
        // Unclamped, this walks to "/" — the tautology the clamp exists to prevent.
        #expect(FileSyncManager.filingAnchor(for: dest, under: nil).path == "/")
    }

    /// An EMPTY provider root is no root at all. `URL(fileURLWithPath: "")` resolves against the
    /// process working directory, so clamping to it would aim the guard at an unrelated folder —
    /// and `PathBoundary.contains(_, under: "")` is now false, which is what makes the empty case
    /// easy to fall into. The anchor must simply stay unclamped.
    @Test func anEmptyProviderRootDoesNotClampTheAnchorToTheWorkingDirectory() {
        let dest = FilingDestination(path: "/root/Documents/Vehicles/Tesla",
                                     confidence: .medium, reasons: [], newSegments: ["Tesla"])
        let anchor = FileSyncManager.filingAnchor(for: dest, under: "")
        #expect(anchor.path == "/root/Documents/Vehicles")
        #expect(anchor.path.hasPrefix("/root"), "must never resolve against the CWD")
    }

    /// A destination the user picked on another volume is not under the provider root, so the clamp
    /// must not drag its anchor back to that root — it is checked where it actually lives.
    @Test func aDestinationOutsideTheProviderRootIsNotClamped() {
        let dest = FilingDestination(path: "/Volumes/External/Archive/2026",
                                     confidence: .high, reasons: [], newSegments: ["2026"])
        #expect(FileSyncManager.filingAnchor(for: dest, under: "/root").path
                == "/Volumes/External/Archive")
    }

    // MARK: Batch path and message routing

    /// The batch path is what automations drive, so it gets its own coverage rather than riding on
    /// the single-file test: a vanished anchor must refuse there too, leaving every file in place.
    @MainActor
    @Test func theRecommendedBatchAlsoRefusesAVanishedAnchor() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorBatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        let b = root.appendingPathComponent("Downloads/Tesla Invoice.pdf")
        try write(a); try write(b)
        let anchor = root.appendingPathComponent("Documents/Vehicles")   // never created

        let dest = FilingDestination(path: anchor.appendingPathComponent("Tesla").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla"])
        let suggestions = [a, b].map {
            FilingSuggestion(filePath: $0.path, fileName: $0.lastPathComponent, size: 512,
                             modificationDate: nil, candidates: [dest], providerRoot: root.path)
        }
        let manager = FileSyncManager()
        manager.filingSuggestions = suggestions

        await manager.applyRecommendedFiling(suggestions)

        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(!FileManager.default.fileExists(atPath: anchor.path))
        #expect(manager.filingSuggestions.count == 2, "nothing filed, nothing dropped from the list")
    }

    /// Mutation guard for the batch test above. "Nothing moved" is only evidence of a refusal if
    /// these suggestions would otherwise have been filed — an ineligible batch (wrong confidence,
    /// `fromContent`, `fromAI`) would move nothing for reasons that have nothing to do with the
    /// anchor, and the assertions above would pass while testing nothing at all.
    @MainActor
    @Test func theRecommendedBatchFilesTheSameSuggestionsWhenTheAnchorIsLive() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorBatchLive")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        let b = root.appendingPathComponent("Downloads/Tesla Invoice.pdf")
        try write(a); try write(b)
        let anchor = root.appendingPathComponent("Documents/Vehicles")
        try write(anchor.appendingPathComponent(".keep"), bytes: 1)   // the ONLY difference

        let dest = FilingDestination(path: anchor.appendingPathComponent("Tesla").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla"])
        let suggestions = [a, b].map {
            FilingSuggestion(filePath: $0.path, fileName: $0.lastPathComponent, size: 512,
                             modificationDate: nil, candidates: [dest], providerRoot: root.path)
        }
        let manager = FileSyncManager()
        manager.filingSuggestions = suggestions
        let allEligible = suggestions.allSatisfy { $0.isBatchEligible }
        #expect(allEligible, "the batch must be eligible to begin with")

        await manager.applyRecommendedFiling(suggestions)

        let filed = anchor.appendingPathComponent("Tesla")
        #expect(FileManager.default.fileExists(atPath: filed.appendingPathComponent("Tesla Policy.pdf").path))
        #expect(FileManager.default.fileExists(atPath: filed.appendingPathComponent("Tesla Invoice.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    /// The specific "no longer available" wording is reserved for the vanished-tree refusal. Any
    /// OTHER failure must still get the generic message — without this, threading a reason through
    /// could quietly relabel every filing failure as a missing volume.
    @MainActor
    @Test func anUnrelatedFailureKeepsTheGenericReason() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAnchorGeneric")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Downloads/Report.pdf")
        try write(src)
        // The anchor EXISTS but is a regular file, so `createDirectory` fails for a reason that has
        // nothing to do with a vanished tree.
        let blocker = root.appendingPathComponent("Documents/Vehicles")
        try write(blocker, bytes: 4)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: src.path, fileName: "Report.pdf", size: 512,
                                          modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: blocker.appendingPathComponent("Tesla").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla"])
        manager.filingSuggestions = [suggestion]

        let result = await manager.applyFilingSuggestion(suggestion, to: dest)

        #expect(result == .failed)
        #expect(FileManager.default.fileExists(atPath: src.path))
        #expect(manager.currentError?.reason == "Couldn't file this item; it was left in place.")
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
