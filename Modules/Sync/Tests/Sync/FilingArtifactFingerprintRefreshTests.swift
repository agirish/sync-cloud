import Combine
import Foundation
import Testing
@testable import Sync

/// Re-deriving the artifact digest after a roster edit, under the right id.
///
/// `FilingArtifacts.attach` builds every store from `loaded.id`, the folder the artifacts were
/// read from, because `profile.profileId` (the field inside `folder-profile.json`) can disagree,
/// and then writes go where nothing reads. `refreshFilingArtifactFingerprint` must use the same id.
///
/// From the wrong folder the digest is `""`, not nil (`fingerprint` answers `""` for a directory
/// holding none of the three artifacts), so both cache gates (`FileSyncManager+Filing`,
/// `FileSyncManager+FilingRefine`) stay open. Every later verdict would be recorded under
/// `artifacts: ""`, billed and unreachable at the next launch, and a `""`-keyed verdict from one
/// artifact set could be served against another.
@Suite @MainActor struct FilingArtifactFingerprintRefreshTests {

    /// A profiles directory whose ACTIVE folder is `work` while the profile inside calls itself
    /// `father` — the split `FilingProfileStore.active` warns about and keeps working through.
    private func makeSplitProfiles() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fpr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("work"),
                                                withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"activeProfileId":"work"}"#.utf8)
            .write(to: dir.appendingPathComponent("profiles.json"))
        try Data(#"{"profileId":"father","root":"~/Documents","folders":[]}"#.utf8)
            .write(to: dir.appendingPathComponent("work/folder-profile.json"))
        return dir
    }

    /// Wired the way the app wires it: the stores get the FOLDER id, the manager's
    /// `filingFolderProfile` carries the field inside the file.
    private func makeManager(_ dir: URL) throws -> FileSyncManager {
        let loaded = try #require(FilingProfileStore.active(in: dir))
        #expect(loaded.id == "work" && loaded.profile.profileId == "father",
                "fixture: the two ids stopped disagreeing, so this proves nothing")
        let manager = FileSyncManager()
        manager.filingProfilesDirectory = dir
        manager.filingFolderProfile = loaded.profile
        manager.filingArtifactFingerprint = FilingProfileStore.fingerprint(id: loaded.id, in: dir)
        manager.filingPeopleStore = PeopleStore(directory: dir, profileId: loaded.id,
                                                profile: loaded.profile)
        return manager
    }

    /// In one run: the launch digest is real, an edit lands, and the digest must still name the
    /// folder the roster was written into. This is also the guard on the call site: the refresh
    /// follows `$savedRevision`, and a refresh moved to `$people` (which publishes before the save)
    /// would hash the previous roster and leave the digest at `atLaunch`.
    ///
    /// The sharp half: whatever else the refresh does, it must never leave `""`, a perfectly
    /// recurring digest that keeps the cache ON while naming an empty artifact set.
    @Test func aRosterEditRefreshesTheDigestUnderTheFolderItWasWrittenTo() throws {
        let dir = try makeSplitProfiles()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try makeManager(dir)

        let atLaunch = manager.filingArtifactFingerprint
        #expect(atLaunch?.isEmpty == false, "fixture: the launch digest must be real")
        // The premise, measured: looking under the field inside the file finds nothing at all.
        #expect(FilingProfileStore.fingerprint(id: "father", in: dir) == "",
                "fixture: the wrong id no longer yields the empty digest")

        manager.filingPeopleStore?.add(displayName: "Granny")

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("work/people.json").path),
                "fixture: the roster must actually have been written")
        #expect(manager.filingArtifactFingerprint ==
                    FilingProfileStore.fingerprint(id: "work", in: dir),
                "the refresh digested a different folder than the roster was written to")
        #expect(manager.filingArtifactFingerprint != atLaunch,
                "the digest did not move when the roster did")
        #expect(manager.filingArtifactFingerprint != "",
                """
                the session's verdicts are now recorded under `artifacts: ""` — billed, and \
                unreachable at the next launch
                """)
        #expect(manager.filingPersonRegistry?.people.contains { $0.displayName == "Granny" } == true,
                "the registry is no longer recompiled when the roster changes")
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
