import Combine
import Foundation
import Testing
@testable import Sync

/// **Re-deriving the artifact digest after a roster edit, under the right id.**
///
/// `FilingArtifacts.attach` builds every store from `loaded.id` — the folder the artifacts were
/// actually read from — and its comment says why: `profile.profileId`, the field *inside*
/// `folder-profile.json`, can disagree, "and when they do the writes went where nothing reads".
/// `refreshFilingArtifactFingerprint` read the field instead.
///
/// The digest that comes back from the wrong folder is `""`, not nil — `fingerprint` answers `""`
/// for a directory holding none of the three artifacts — and `""` is NOT nil, so both cache gates
/// (`FileSyncManager+Filing`, `FileSyncManager+FilingRefine`) stay OPEN. Every verdict for the rest
/// of the session is then recorded under `artifacts: ""`, billed and unreachable at the next
/// launch, and a `""`-keyed verdict from one artifact set can be served against another. That is
/// the exact failure the `String?` change was made to prevent, arriving through the other door.
@Suite @MainActor struct FilingArtifactFingerprintRefreshTests {

    /// A profiles directory whose ACTIVE folder is `work` while the profile inside calls itself
    /// `abhishek` — the split `FilingProfileStore.active` warns about and keeps working through.
    private func makeSplitProfiles() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fpr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("work"),
                                                withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"activeProfileId":"work"}"#.utf8)
            .write(to: dir.appendingPathComponent("profiles.json"))
        try Data(#"{"profileId":"abhishek","root":"~/Documents","folders":[]}"#.utf8)
            .write(to: dir.appendingPathComponent("work/folder-profile.json"))
        return dir
    }

    /// Wired the way the app wires it: the stores get the FOLDER id, the manager's
    /// `filingFolderProfile` carries the field inside the file.
    private func makeManager(_ dir: URL) throws -> FileSyncManager {
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.id == "work" && loaded.profile.profileId == "abhishek",
                "fixture: the two ids stopped disagreeing, so this proves nothing")
        let manager = FileSyncManager()
        manager.filingProfilesDirectory = dir
        manager.filingFolderProfile = loaded.profile
        manager.filingArtifactFingerprint = FilingProfileStore.fingerprint(id: loaded.id, in: dir)
        manager.filingPeopleStore = PeopleStore(directory: dir, profileId: loaded.id,
                                                profile: loaded.profile)
        return manager
    }

    /// The whole finding in one run: launch digest is real, an edit lands, the digest must still
    /// name the folder the roster was written into.
    @Test func aRosterEditRefreshesTheDigestUnderTheFolderItWasWrittenTo() throws {
        let dir = try makeSplitProfiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try makeManager(dir)

        let atLaunch = manager.filingArtifactFingerprint
        #expect(atLaunch?.isEmpty == false, "fixture: the launch digest must be real")

        manager.filingPeopleStore?.add(displayName: "Muktha")

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work/people.json").path),
                "fixture: the roster must actually have been written")
        #expect(manager.filingArtifactFingerprint ==
                    FilingProfileStore.fingerprint(id: "work", in: dir),
                "the refresh digested a different folder than the roster was written to")
        #expect(manager.filingArtifactFingerprint != atLaunch,
                "the digest did not move when the roster did")
    }

    /// The sharp half, stated on its own so the assertion above cannot pass by luck: whatever else
    /// the refresh does, it must never leave `""` — a perfectly recurring digest that keeps the
    /// cache ON while naming an empty artifact set.
    @Test func theRefreshNeverLeavesTheDigestEmpty() throws {
        let dir = try makeSplitProfiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try makeManager(dir)

        // The premise, measured: looking under the field inside the file finds nothing at all.
        #expect(FilingProfileStore.fingerprint(id: "abhishek", in: dir) == "",
                "fixture: the wrong id no longer yields the empty digest")

        manager.filingPeopleStore?.add(displayName: "Muktha")
        #expect(manager.filingArtifactFingerprint != "",
                """
                the session's verdicts are now recorded under `artifacts: ""` — billed, and \
                unreachable at the next launch
                """)
    }

    /// And when the profile goes away the previous digest must not stay behind with the cache
    /// still on: a stale key is the same "recorded under a digest that no longer describes the
    /// question" failure, held one step longer.
    @Test func aVanishedProfileTurnsTheCacheOffRatherThanKeepingAStaleDigest() throws {
        let dir = try makeSplitProfiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try makeManager(dir)
        #expect(manager.filingArtifactFingerprint?.isEmpty == false, "fixture: a real digest first")

        // The in-memory store is the "no file behind it" shape — nothing on disk to digest.
        manager.filingPeopleStore = PeopleStore(people: [])
        manager.refreshFilingArtifactFingerprint()
        #expect(manager.filingArtifactFingerprint == nil,
                "the digest of the profile that went away is still keying this session's verdicts")
    }
}
