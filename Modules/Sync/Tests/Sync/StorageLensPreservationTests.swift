import Foundation
import Testing
@testable import Sync

/// **Both writers are read-modify-writes over a read that answered `[]` for everything.**
///
/// `load` returned an empty list for a file that is absent, one it could not decode, and one
/// written under another schema alike — and the doc said that costs a re-scan. It cost more than
/// that: the next analysis wrote a file holding ONE snapshot with the other eleven roots gone, and
/// "Forget this root" filtered `[]` to `[]`, which trips the guard that deletes the file. Forget
/// one silently meant forget all, with the request itself as the trigger.
///
/// `FilingProfileStore.indexForAmending` is the sibling that gets this right: it refuses to amend
/// what it could not read.
@Suite struct StorageLensPreservationTests {

    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StoragePreserve-\(name)")
        return dir.appendingPathComponent("storage-lens.json")
    }

    private func report(_ bytes: Int = 1234) -> StorageLensReport {
        StorageLensReport(treemap: [TreemapNode(name: "D", path: "/r/D", bytes: bytes)],
                          largest: [], stale: [], reclaimCandidates: [], totalBytes: bytes)
    }

    private func snapshot(_ root: String, at: TimeInterval = 1_800_000_000) -> StorageLensSnapshot {
        StorageLensSnapshot(root: root, report: report(), completedAt: Date(timeIntervalSince1970: at))
    }

    /// A new analysis must not replace a file it could not read with a single snapshot.
    @Test func anUnreadableFileIsKeptRatherThanReplaced() throws {
        let url = try storeURL("save")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\":\"/a\"".utf8)   // truncated
        try corrupt.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        let kept = url.appendingPathExtension("unreadable")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the other roots were destroyed rather than kept")
        // ...and the app kept working: the new analysis is on disk beside it.
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"])
    }

    /// **The sharper half: a file from a NEWER build is good data, not corruption.** A schema this
    /// build does not know used to read as empty and be overwritten.
    @Test func aForeignSchemaIsKeptRatherThanOverwritten() throws {
        let url = try storeURL("schema")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let future = Data("{\"schema\":99,\"snapshots\":[]}".utf8)
        try future.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        #expect(FileManager.default.contents(atPath: url.appendingPathExtension("unreadable").path)
                == future, "a newer build's file was overwritten")
    }

    /// **"Forget this root" may not empty a file it could not read.**
    @Test func forgettingOneRootDoesNotForgetAllOfAnUnreadableFile() throws {
        let url = try storeURL("clear")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()

        #expect(FileManager.default.contents(atPath: url.appendingPathExtension("unreadable").path)
                == corrupt, "forgetting one root destroyed the whole file")
    }

    /// The ordinary paths are untouched — the refusals must not be "the store stopped working".
    @Test func aReadableFileStillSavesAndForgetsOneRoot() throws {
        let url = try storeURL("ordinary")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/a", at: 1_800_000_000), to: url)
        StorageLensStore.saveInBackground(snapshot("/b", at: 1_800_000_100), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(Set(StorageLensStore.load(from: url).map(\.root)) == ["/a", "/b"])

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"],
                "forgetting one root took the other with it")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path) == false,
                "a readable file was set aside")
    }

    /// Forget-all still deletes the file — that is what the user asked for either way.
    @Test func forgettingEverythingStillRemovesTheFile() throws {
        let url = try storeURL("clearall")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/a"), to: url)
        StorageLensStore.waitForPendingWrites()
        StorageLensStore.clearInBackground(root: nil, from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    /// And forgetting the last remaining root removes it too — an empty store has no file, which is
    /// the existing rule and not what this change is about.
    @Test func forgettingTheLastRootRemovesTheFile() throws {
        let url = try storeURL("last")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/only"), to: url)
        StorageLensStore.waitForPendingWrites()
        StorageLensStore.clearInBackground(root: "/only", from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}
