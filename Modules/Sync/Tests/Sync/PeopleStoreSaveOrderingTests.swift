import Combine
import Foundation
import Testing
@testable import Sync

/// **When the bytes on disk are the roster you just edited.**
///
/// `FileSyncManager` re-derives `filingArtifactFingerprint` when the household changes, so that
/// `FilingVerdictCache` — which is keyed on it — stops replaying classifications composed against
/// the previous roster. The fingerprint hashes `people.json` *on disk*, and it was driven from
/// `$people`, which publishes when the array is assigned: `save()` runs afterwards. Every edit
/// therefore left the fingerprint one save behind, and the cache went on serving answers from the
/// household the user had just changed, until a relaunch or a re-survey.
///
/// `savedRevision` is the post-write signal. These pin the ordering from both ends.
@Suite @MainActor struct PeopleStoreSaveOrderingTests {

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("people-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func namesOnDisk(_ dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("p/people.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let people = object["people"] as? [[String: Any]]
        else { return [] }
        return people.compactMap { $0["displayName"] as? String }
    }

    /// The fix: a `savedRevision` subscriber reading the file sees the edit that caused it.
    @Test func aSavedRevisionSubscriberSeesTheEditOnDisk() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)

        var seen: [[String]] = []
        let c = store.$savedRevision.dropFirst().sink { _ in seen.append(self.namesOnDisk(dir)) }
        defer { c.cancel() }

        store.add(displayName: "Muktha")
        #expect(seen.count == 1, "the write published \(seen.count) times, expected once")
        #expect(seen.first?.contains("Muktha") == true,
                "the post-save signal fired before the bytes were written — saw \(seen.first ?? [])")
    }

    /// **The control, and the bug itself.** The same subscription on `$people` sees the file as it
    /// was *before* the edit. Asserting this keeps the test above honest: it shows the two signals
    /// genuinely differ, so passing it is evidence about ordering rather than about the file
    /// happening to be written by the time anyone looked.
    @Test func aPeopleSubscriberStillSeesThePreviousFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Abhishek")           // something on disk to be stale about

        var seen: [[String]] = []
        let c = store.$people.dropFirst().sink { _ in seen.append(self.namesOnDisk(dir)) }
        defer { c.cancel() }

        store.add(displayName: "Muktha")
        #expect(seen.first?.contains("Muktha") == false,
                """
                `$people` now fires after the write — the two signals no longer differ and the \
                test above has stopped proving anything
                """)
    }

    /// A save that is **declined** must not claim to have written: an unreadable roster is refused
    /// (the file on disk is a household this build could not read, and the in-memory one is a
    /// seed), so nothing downstream should go re-read a file that did not change.
    @Test func aRefusedSaveDoesNotBumpTheRevision() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON that does not decode as a roster — the case that locks writing.
        try Data(#"{"schemaVersion":1,"people":{"not":"an array"}}"#.utf8)
            .write(to: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "the fixture did not produce a locked roster")
        let before = store.savedRevision
        store.add(displayName: "Muktha")
        #expect(store.savedRevision == before,
                "a save that refused to write still announced one")
    }

    /// A store with no profile has nowhere to write, and must not announce either.
    @Test func aNonPersistentStoreDoesNotBumpTheRevision() {
        let store = PeopleStore(people: [Person(id: "a", displayName: "Abhishek")])
        let before = store.savedRevision
        store.add(displayName: "Muktha")
        #expect(store.savedRevision == before)
    }
}
