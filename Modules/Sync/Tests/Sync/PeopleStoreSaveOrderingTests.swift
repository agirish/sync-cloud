import Combine
import Foundation
import Testing
@testable import Sync

/// When the bytes on disk are the roster you just edited. `FileSyncManager` re-derives
/// `filingArtifactFingerprint`, which keys `FilingVerdictCache`, when the household changes. It
/// hashes `people.json` on disk, but `$people` publishes before `save()` runs, so driven from it the
/// fingerprint stays one save behind and the cache keeps serving the old household's answers.
/// `savedRevision` is the post-write signal; these pin the ordering from both ends.
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

    /// A `savedRevision` subscriber reading the file sees the edit that caused it.
    @Test func aSavedRevisionSubscriberSeesTheEditOnDisk() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)

        var seen: [[String]] = []
        let c = store.$savedRevision.dropFirst().sink { _ in seen.append(self.namesOnDisk(dir)) }
        defer { c.cancel() }

        store.add(displayName: "Granny")
        #expect(seen.count == 1, "the write published \(seen.count) times, expected once")
        #expect(seen.first?.contains("Granny") == true,
                "the post-save signal fired before the bytes were written — saw \(seen.first ?? [])")
    }

    /// The control: the same subscription on `$people` sees the file as it was before the edit. It
    /// shows the two signals differ, so the test above proves ordering, not lucky timing.
    @Test func aPeopleSubscriberStillSeesThePreviousFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Father")           // something on disk to be stale about

        var seen: [[String]] = []
        let c = store.$people.dropFirst().sink { _ in seen.append(self.namesOnDisk(dir)) }
        defer { c.cancel() }

        store.add(displayName: "Granny")
        #expect(seen.first?.contains("Granny") == false,
                """
                `$people` now fires after the write — the two signals no longer differ and the \
                test above has stopped proving anything
                """)
    }

    /// A declined save must not claim to have written. An unreadable roster is refused (the
    /// in-memory one is a seed), so nothing downstream should re-read a file that didn't change.
    @Test func aRefusedSaveDoesNotBumpTheRevision() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON that doesn't decode as a roster: the case that locks writing.
        try Data(#"{"schemaVersion":1,"people":{"not":"an array"}}"#.utf8)
            .write(to: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "the fixture did not produce a locked roster")
        let before = store.savedRevision
        store.add(displayName: "Granny")
        #expect(store.savedRevision == before,
                "a save that refused to write still announced one")
    }

    /// Provenance follows the write too. If `source` became `.file` before a refused save, the list
    /// would claim "saved in people.json" beside the banner saying edits won't be saved.
    @Test func aRefusedSaveDoesNotClaimTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"schemaVersion":1,"people":{"not":"an array"}}"#.utf8)
            .write(to: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "the fixture did not produce a locked roster")
        let before = store.source
        store.add(displayName: "Granny")
        #expect(store.source == before,
                "a save that refused to write still claimed the file as the household of record")
    }

    /// A save that does land claims the file, so the test above can't pass on `source` never
    /// changing.
    @Test func aSaveThatLandsClaimsTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Granny")
        #expect(store.source == .file)
    }

    /// A dismissal changes the file without moving the fingerprint, since moving it re-bills a paid
    /// pass. `notNames` feeds only the suggestion list; the compiled registry can't see it. Asserted
    /// on the digest, not on the signal: the fingerprint is recomputed from disk at launch, so
    /// suppressing the signal would only defer the re-bill.
    @Test func dismissingASuggestionDoesNotMoveTheFilingFingerprint() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Granny")

        let before = FilingProfileStore.fingerprint(id: "p", in: dir)
        #expect(before?.isEmpty == false, "the fixture produced no fingerprint to compare")
        let revision = store.savedRevision

        store.dismissSuggestion(PersonNameSuggestion(personId: store.people[0].id, form: "Mukta",
                                                     occurrences: 3, exampleFile: "Mukta bill.pdf"))

        // It really did land: read it back rather than trusting a counter.
        let data = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/people.json")))
        let object = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["notNames"] as? [String])?.isEmpty == false, "the dismissal was not written")
        #expect(store.savedRevision > revision, "the write was not announced")

        #expect(FilingProfileStore.fingerprint(id: "p", in: dir) == before,
                "a declined name suggestion moved the filing fingerprint and re-billed every file")
    }

    /// A real roster change still moves it, or the cache would serve answers composed against a
    /// household that has changed.
    @Test func addingAPersonDoesMoveTheFilingFingerprint() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Granny")
        let before = FilingProfileStore.fingerprint(id: "p", in: dir)

        store.add(displayName: "Son")
        #expect(FilingProfileStore.fingerprint(id: "p", in: dir) != before,
                "adding a person left the fingerprint unchanged; cached verdicts would survive it")
    }

    /// An unmodelled key left by a hand-edit or a future build doesn't move it either.
    @Test func aCarriedCommentDoesNotMoveTheFilingFingerprint() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/people.json")
        try Data(#"{"schemaVersion":1,"people":[{"id":"a","displayName":"Father"}]}"#.utf8)
            .write(to: url)
        let before = FilingProfileStore.fingerprint(id: "p", in: dir)

        try Data(#"{"schemaVersion":1,"_note":"Uncle files here too","people":[{"id":"a","displayName":"Father"}]}"#.utf8)
            .write(to: url)
        #expect(FilingProfileStore.fingerprint(id: "p", in: dir) == before,
                "a comment in people.json re-billed a full classification")
    }

    /// An edit that changes the household still announces one.
    @Test func anEditStillAnnouncesAHouseholdChange() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let revision = store.savedRevision
        store.add(displayName: "Granny")
        #expect(store.savedRevision > revision)
    }

    /// The call site, scanned because no test builds a `FileSyncManager` with a
    /// `filingPeopleStore`: deleting the `$savedRevision` subscription must fail here, since every
    /// behavioural test above would stay green.
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

        // And the refresh doesn't hang off `$people`, which would be one save stale. Bounded to
        // the `$people` sink's own closure.
        let start = try #require(source.range(of: "filingPeopleStore?.$people"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n                }"))
        #expect(!rest[..<end.lowerBound].contains("refreshFilingArtifactFingerprint"),
                "the fingerprint is refreshed from the pre-save publish again")
    }

    /// A store with no profile has nowhere to write, and must not announce either.
    @Test func aNonPersistentStoreDoesNotBumpTheRevision() {
        let store = PeopleStore(people: [Person(id: "a", displayName: "Father")])
        let before = store.savedRevision
        store.add(displayName: "Granny")
        #expect(store.savedRevision == before)
    }
}
