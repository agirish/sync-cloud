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

    /// **Provenance follows the write too.** `source = .file` was set by the callers, before a
    /// `save()` that refuses outright when the roster on disk is one this build could not read — so
    /// the list claimed "saved in people.json" beside the banner saying edits would not be saved.
    /// The same "two answers about one roster" the flag was introduced to remove.
    @Test func aRefusedSaveDoesNotClaimTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"schemaVersion":1,"people":{"not":"an array"}}"#.utf8)
            .write(to: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "the fixture did not produce a locked roster")
        let before = store.source
        store.add(displayName: "Muktha")
        #expect(store.source == before,
                "a save that refused to write still claimed the file as the household of record")
    }

    /// And a save that DOES land claims it — the other direction, so the test above is not passing
    /// on `source` simply never changing.
    @Test func aSaveThatLandsClaimsTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Muktha")
        #expect(store.source == .file)
    }

    /// **A dismissal writes the file but does not announce a household change.**
    ///
    /// `savedRevision`'s only subscriber re-derives the filing artifact fingerprint, which keys the
    /// verdict cache — so a bump costs a full paid re-classification. What a dismissal writes
    /// (`notNames`) is not part of the compiled registry and cannot change any classification, so
    /// announcing it re-billed the user for a name they declined to add. `writeCount` is the
    /// honest "did this reach the disk" counter.
    @Test func dismissingASuggestionWritesWithoutInvalidatingCachedVerdicts() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Muktha")
        let writes = store.writeCount
        let revision = store.savedRevision

        store.dismissSuggestion(PersonNameSuggestion(personId: store.people[0].id, form: "Mukta",
                                                     occurrences: 3, exampleFile: "Mukta bill.pdf"))

        #expect(store.writeCount > writes, "the dismissal did not reach the disk")
        #expect(store.savedRevision == revision,
                "a dismissal announced a household change and invalidated every cached verdict")
        // It really did land — read it back rather than trusting the counter.
        let data = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/people.json")))
        let object = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["notNames"] as? [String])?.isEmpty == false, "the dismissal was not written")
    }

    /// And an edit that DOES change the household still announces one.
    @Test func anEditStillAnnouncesAHouseholdChange() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let revision = store.savedRevision
        store.add(displayName: "Muktha")
        #expect(store.savedRevision > revision)
    }

    /// **The call site**, because nothing in the repo builds a `FileSyncManager` with a
    /// `filingPeopleStore` — so deleting the `$savedRevision` subscription restores the original
    /// bug exactly and leaves every behavioural test above green. What the tests prove is that the
    /// two signals differ; this proves the fingerprint is driven by the right one.
    @Test func theFingerprintRefreshFollowsTheWriteNotThePublish() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read FileSyncManager.swift — this scan would be vacuous")
        try #require(source.count > 500, "FileSyncManager.swift is implausibly short")

        // Two subscriptions, each on the publisher that answers its question.
        #expect(source.contains("filingPeopleStore?.$savedRevision"),
                "the artifact fingerprint is not driven by the post-write signal")
        #expect(source.contains("peopleSaveCancellable"),
                "the post-write subscription is not retained, so it is cancelled immediately")
        #expect(source.contains("filingPeopleStore?.$people"),
                "the registry is no longer recompiled when the roster changes in memory")

        // And the refresh is NOT still hanging off `$people`, which is the shape that was one save
        // stale. Bounded to the `$people` sink's own closure.
        let start = try #require(source.range(of: "filingPeopleStore?.$people"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n                }"))
        #expect(!rest[..<end.lowerBound].contains("refreshFilingArtifactFingerprint"),
                "the fingerprint is refreshed from the pre-save publish again")
    }

    /// A store with no profile has nowhere to write, and must not announce either.
    @Test func aNonPersistentStoreDoesNotBumpTheRevision() {
        let store = PeopleStore(people: [Person(id: "a", displayName: "Abhishek")])
        let before = store.savedRevision
        store.add(displayName: "Muktha")
        #expect(store.savedRevision == before)
    }
}
