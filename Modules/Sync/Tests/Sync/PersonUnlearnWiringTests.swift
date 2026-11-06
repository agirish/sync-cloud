import Foundation
import Testing
@testable import Sync

/// A correction has to reach the index, and when it is made. `PersonIdentityIndex.make` takes the
/// identifiers a rejection withdraws, but a pure-function suite can't see whether the manager
/// translates the tags through the corpus, or rebuilds when a verdict is recorded rather than at
/// the next relaunch. A correction that waits for a restart makes the app feel deaf.
@MainActor
@Suite struct PersonUnlearnWiringTests {

    static let household = PersonRegistry(people: [
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        Person(id: "granny", displayName: "Granny", aliases: ["Mom"]),
    ])

    static func profile() -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for (path, person) in [("Immigration/Passport/Granny", "Granny"), ("School/Daughter", "Daughter")] {
            folders[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "p", root: "~", folders: folders,
                             personTokens: ["granny", "daughter"])
    }

    /// The number in both folders: hers, and Daughter's by mistake.
    static let contested = "z1234567"
    static let misfiled = "School/Daughter/Scan 2026-08-02.pdf"

    static func memory(salt: String = "s") -> FilingMemory {
        let hash = FilingMemory.hash(contested, salt: salt)
        let entry = FilingMemoryEntry(docs: 4, anchors: [],
                                      idHashes: [FilingMemoryToken(token: hash, weight: 3.0)])
        return FilingMemory(profileId: "p", salt: salt,
                            folders: ["Immigration/Passport/Granny": entry, "School/Daughter": entry])
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

    /// The whole path, end to end: two claimants silence the identifier, and pressing "not
    /// Daughter's" hands it back to Granny without a relaunch.
    @Test func aVerdictRecordedNowChangesTheIndexNow() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The premise: contested, so nobody owns it and the correction has something to repair.
        try #require(m.filingPersonIdentity.isEmpty,
                     "the fixture stopped reproducing the silenced identifier")

        m.filingPersonTagStore?.record(personId: "daughter", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)

        #expect(m.filingPersonIdentity.count(for: "granny") == 1,
                "the index did not rebuild when the verdict was recorded")
        #expect(m.filingPersonIdentity.count(for: "daughter") == 0)
        // And the tier that reads it now answers, which is what the user sees.
        #expect(Self.household.attribute(fileName: "Scan.pdf",
                                         pageSample: "passport no \(Self.contested)",
                                         identity: m.filingPersonIdentity) == ["granny"])
    }

    /// The same correction on a tree whose folder name and `profileId` field disagree, as they do
    /// when a hand-built `folder-profile.json` omits `profileId` (it decodes to `"default"`).
    /// ``FilingProfileStore/active(in:)`` lets the folder win, so the corpus must be read under the
    /// folder; under the field it isn't there, and every "not theirs" silently withdraws nothing.
    /// Same assertions as `aVerdictRecordedNowChangesTheIndexNow`, so only the lookup varies.
    @Test func aRejectionStillAppliesWhenTheProfileFieldDisagreesWithItsFolder() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The artifacts are under `p/`, the directory id the app hands over; the profile's field
        // says something else.
        m.filingProfileDirectoryId = "p"
        m.filingFolderProfile = FolderProfile(profileId: "default", root: "~",
                                              folders: Self.profile().folders,
                                              personTokens: ["granny", "daughter"])
        try #require(m.filingPersonIdentity.isEmpty,
                     "the fixture stopped reproducing the silenced identifier")

        m.filingPersonTagStore?.record(personId: "daughter", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)

        #expect(m.filingPersonIdentity.count(for: "granny") == 1,
                "the rejection was read against the wrong folder, so it withdrew nothing")
        #expect(m.filingPersonIdentity.count(for: "daughter") == 0)
    }

    /// A confirmation moves nothing: it rebuilds, and the index is what it was.
    @Test func aConfirmationLeavesTheIndexAlone() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "granny", key: .path(Self.misfiled),
                                       verdict: .confirmed, path: Self.misfiled)
        #expect(m.filingPersonIdentity.isEmpty)
    }

    /// The corpus is read once per change to the rejections, not once per verdict. The rebuild
    /// fires on every tag-store write and the queue is all yes/no presses, so uncached each press
    /// would decode megabytes on the main actor. A readable corpus fills the cache; breaking it
    /// afterwards proves nothing reads it again.
    @Test func theCorpusIsNotReReadForEveryVerdict() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "daughter", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        try #require(m.filingPersonIdentity.count(for: "granny") == 1,
                     "the first rejection did not take effect, so the cache below proves nothing")

        // Break the corpus. Anything that reads it again now answers nil and the un-learn collapses.
        try Data("{ not json at all".utf8)
            .write(to: dir.appendingPathComponent("p/filing-corpus.json"))

        m.filingPersonTagStore?.record(personId: "granny", key: .path("other.pdf"),
                                       verdict: .confirmed, path: "other.pdf")
        #expect(m.filingPersonIdentity.count(for: "granny") == 1,
                "the corpus was re-read for a verdict that changed no rejection")
    }

    /// A new rejection does re-read, because the answer really has changed.
    @Test func aNewRejectionReReadsTheCorpus() throws {
        let (m, dir) = try Self.makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        m.filingPersonTagStore?.record(personId: "daughter", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        try #require(m.filingPersonIdentity.count(for: "granny") == 1)

        // A second rejection, for Granny's own claim, withdraws the identifier from her too, which
        // can only happen if the corpus was consulted again.
        m.filingPersonTagStore?.record(personId: "granny", key: .path(Self.misfiled),
                                       verdict: .rejected, path: Self.misfiled)
        #expect(m.filingPersonIdentity.count(for: "granny") == 0,
                "a new rejection was answered from the cache")
    }

    /// The corpus is read only when there is a rejection to translate. It is megabytes, and the
    /// rebuild runs whenever the roster, profile or memory moves, so a household that never pressed
    /// "not theirs" must not pay for it.
    @Test func theCorpusIsNotReadWithoutARejection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unlearn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        // An undecodable corpus. Read, it decodes to nil and withdraws nothing, the same as never
        // read, so this can't tell whether it was opened.
        try Data("{ not json at all".utf8)
            .write(to: dir.appendingPathComponent("p/filing-corpus.json"))

        let m = FileSyncManager()
        m.filingProfilesDirectory = dir
        m.filingPersonRegistry = Self.household
        m.filingFolderProfile = Self.profile()
        m.filingMemory = Self.memory()
        m.filingPersonTagStore = PersonTagStore(directory: dir, profileId: "p")
        m.filingPersonTagStore?.record(personId: "granny", key: .path("a.pdf"),
                                       verdict: .confirmed, path: "a.pdf")
        // Nothing threw, nothing hung, and the index is exactly what the tree says.
        #expect(m.filingPersonIdentity.isEmpty)
    }
}
