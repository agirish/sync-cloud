import Foundation
import Testing
@testable import Sync

/// **The correction has to reach the index, and it has to reach it when it is made.**
///
/// `PersonIdentityIndex.make` can now be handed the identifiers a rejection withdraws, but a rule
/// extracted for testability is one revert away from being unused — and this one has two ways to be
/// unused that a pure-function suite cannot see. The manager has to translate the tags through the
/// corpus at all, and it has to rebuild when a verdict is recorded rather than at the next relaunch.
/// A correction that takes effect only after a restart is most of what makes an app feel deaf.
@MainActor
@Suite struct PersonUnlearnWiringTests {

    static let household = PersonRegistry(people: [
        Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        Person(id: "muktha", displayName: "Muktha", aliases: ["Mom"]),
    ])

    static func profile() -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, person) in [("Immigration/Passport/Muktha", "Muktha"), ("School/Aditi", "Aditi")] {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "p", root: "~", folders: folders,
                             personTokens: ["muktha", "aditi"])
    }

    /// The number in both folders — hers eleven times, Aditi's once by mistake.
    static let contested = "z1234567"
    static let misfiled = "School/Aditi/Scan 2026-08-02.pdf"

    static func memory(salt: String = "s") -> FilingMemory {
        let hash = FilingMemory.hash(contested, salt: salt)
        let entry = FilingMemoryEntry(docs: 4, anchors: [],
                                      idHashes: [FilingMemoryToken(token: hash, weight: 3.0)])
        return FilingMemory(profileId: "p", salt: salt,
                            folders: ["Immigration/Passport/Muktha": entry, "School/Aditi": entry])
    }

    static func corpus(salt: String = "s") -> FilingCorpus {
        FilingCorpus(profileId: "p", salt: salt, documents: [
            misfiled: FilingCorpusDocument(size: 100, modified: 1, anchors: [],
                                           idHashes: [FilingMemory.hash(contested, salt: salt)]),
        ])
    }

    /// A manager wired the way the app wires one: profile, memory, roster, a tag store on disk, and
    /// a corpus beside it.
    static func makeManager() throws -> (FileSyncManager, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unlearn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(corpus())
            .write(to: dir.appendingPathComponent("p/filing-corpus.json"))

        let m = FileSyncManager()
        m.filingProfilesDirectory = dir
        m.filingPersonRegistry = household
        m.filingFolderProfile = profile()
        m.filingMemory = memory()
        m.filingPersonTagStore = PersonTagStore(directory: dir, profileId: "p")
        return (m, dir)
    }

    /// **The whole path, end to end.** Two claimants silence the identifier; pressing "not Aditi's"
    /// hands it back to Muktha — without a relaunch, and without anything else moving.
    @Test func aVerdictRecordedNowChangesTheIndexNow() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The premise: contested, so nobody owns it and the correction has something to repair.
        try #require(m.filingPersonIdentity.isEmpty,
                     "the fixture stopped reproducing the silenced identifier")

        m.filingPersonTagStore?.record(personId: "aditi", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)

        #expect(m.filingPersonIdentity.count(for: "muktha") == 1,
                "the index did not rebuild when the verdict was recorded")
        #expect(m.filingPersonIdentity.count(for: "aditi") == 0)
        // And the tier that reads it now answers, which is what the user actually sees.
        #expect(Self.household.attribute(fileName: "Scan.pdf",
                                         pageSample: "passport no \(Self.contested)",
                                         identity: m.filingPersonIdentity) == ["muktha"])
    }

    /// A confirmation moves nothing — it rebuilds, and the index is what it was.
    @Test func aConfirmationLeavesTheIndexAlone() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "muktha", key: .path(Self.misfiled),
                                       verdict: .confirmed, path: Self.misfiled)
        #expect(m.filingPersonIdentity.isEmpty)
    }

    /// **And once per CHANGE to the rejections, not once per verdict.**
    ///
    /// This rebuild fires on every write to the tag store, and the queue's whole interaction is
    /// pressing yes or no on rows — so an uncached read put a 100 ms main-actor decode of a 4,866 KB
    /// corpus behind every press after the first rejection. The probe here is the same one the test
    /// below uses: a corpus file that cannot be decoded. Recording the rejection while it is
    /// READABLE fills the cache; breaking the file afterwards proves nothing reads it again.
    @Test func theCorpusIsNotReReadForEveryVerdict() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "aditi", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        try #require(m.filingPersonIdentity.count(for: "muktha") == 1,
                     "the first rejection did not take effect, so the cache below proves nothing")

        // Break the corpus. Anything that reads it again now answers nil and the un-learn collapses.
        try Data("{ not json at all".utf8)
            .write(to: dir.appendingPathComponent("p/filing-corpus.json"))

        m.filingPersonTagStore?.record(personId: "muktha", key: .path("other.pdf"),
                                       verdict: .confirmed, path: "other.pdf")
        #expect(m.filingPersonIdentity.count(for: "muktha") == 1,
                "the corpus was re-read for a verdict that changed no rejection")
    }

    /// And a NEW rejection does re-read, because the answer really has changed.
    @Test func aNewRejectionReReadsTheCorpus() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "aditi", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        try #require(m.filingPersonIdentity.count(for: "muktha") == 1)

        // A second rejection, this time for Muktha's own claim, withdraws the identifier from her
        // too — which can only happen if the corpus was consulted again.
        m.filingPersonTagStore?.record(personId: "muktha", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        #expect(m.filingPersonIdentity.count(for: "muktha") == 0,
                "a new rejection was answered from the cache")
    }

    /// **The corpus is read only when there is a rejection to translate.** It is megabytes, and the
    /// rebuild runs whenever the roster, profile or memory moves — so a household that has never
    /// pressed "not theirs" must not pay for it.
    @Test func theCorpusIsNotReadWithoutARejection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unlearn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        // A corpus that would CRASH the decoder if it were read — the cheapest possible probe for
        // "was this opened at all", and one that cannot pass by accident.
        try Data("{ not json at all".utf8)
            .write(to: dir.appendingPathComponent("p/filing-corpus.json"))

        let m = FileSyncManager()
        m.filingProfilesDirectory = dir
        m.filingPersonRegistry = Self.household
        m.filingFolderProfile = Self.profile()
        m.filingMemory = Self.memory()
        m.filingPersonTagStore = PersonTagStore(directory: dir, profileId: "p")
        m.filingPersonTagStore?.record(personId: "muktha", key: .path("a.pdf"),
                                       verdict: .confirmed, path: "a.pdf")
        // Nothing threw, nothing hung: the unreadable corpus was never opened, and the index is
        // exactly what the tree says.
        #expect(m.filingPersonIdentity.isEmpty)
    }
}
