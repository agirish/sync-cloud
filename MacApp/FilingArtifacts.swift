import Events
import Foundation
import Sync

/// Handing the manager the filing artifacts this machine has on disk.
///
/// **Extracted from `SyncCloudApp.init` so it can happen more than once.** It ran exactly at launch,
/// which was fine while a profile could only arrive from an out-of-repo script: the app could not
/// create one, so there was never a second moment worth reading. Setup can now walk a tree and write
/// a profile, and one the user just produced has to take effect without a relaunch.
///
/// Read HERE, in the app, and not in `Sync` — library code must not reach into a real home directory
/// just because nobody said otherwise, the same rule the verdict cache and the hash index follow.
/// Absent is the ordinary state and costs nothing but the accuracy it would have added.
@MainActor
enum FilingArtifacts {

    /// Loads the active profile and everything keyed to it, or leaves the manager untouched.
    ///
    /// - Parameter recordingTrend: whether to stamp O16's baseline point. **Default false, and
    ///   the default is the point.** This function is otherwise read-only, and the app's own
    ///   binary is the test host — so `SyncCloudApp`'s launch path runs under `xcodebuild test`
    ///   too, and a stamp taken unconditionally here wrote a trend point into the developer's
    ///   real `restructure.json` on every test run. Caught by reading the file after an install:
    ///   its mtime was the test run's, not the launch's. Only a real launch passes true.
    ///
    /// - Returns: whether anything was attached — `false` means this machine has no active profile,
    ///   which is the ordinary state on a Mac that has never been surveyed. **Not** the answer to
    ///   "did the walk I just ran take effect": a walk that lands beside a hand-built profile
    ///   attaches that OTHER profile and returns `true`. `FolderWalkReport.becameActive` is the
    ///   value that answers that, and it is what the setup form reads.
    @discardableResult
    static func attach(to manager: FileSyncManager, recordingTrend: Bool = false) -> Bool {
        guard let profiles = FilingProfileStore.defaultDirectory() else { return false }

        // **Handed over before the profile is read, and that is a fix rather than a tidy-up.**
        // These two are *where things live*, not things that were found: the path is known on any
        // Mac, profile or no profile. They used to be set below the `active(in:)` guard, so a
        // machine that had never been surveyed — the one machine setup exists for — got a nil
        // `filingProfilesDirectory`, and the walk that setup runs to CREATE the first profile
        // failed with `.noProfilesDirectory` before it read a single folder. Nothing said so
        // anywhere: the guard is the first line of `deriveFolderProfile`, so the failure arrived
        // as a refusal with no walk behind it. Found by a fresh-machine rehearsal on 2026-09-08,
        // with the profiles directory moved aside.
        manager.filingProfilesDirectory = profiles
        // Where the byte-hash and PDF-fingerprint indexes live, for the same reason.
        manager.contentIndexDirectory = profiles.deletingLastPathComponent()

        guard let loaded = FilingProfileStore.active(in: profiles) else { return false }

        manager.filingFolderProfile = loaded.profile
        manager.filingMemory = loaded.memory
        // …and the id it was read UNDER, so the re-survey writes back to the same folder. The four
        // stores below already take `loaded.id` for this reason; `resurveyFilingMemory` runs inside
        // `Sync` and had no way to reach it, so it fell back to the field inside the artifact.
        manager.filingProfileDirectoryId = loaded.id
        // The roster is the one filing artifact the user edits, so it is handed over as a
        // STORE rather than a value — Settings writes through it, and the manager's
        // subscription recompiles the registry and the fingerprint without a relaunch.
        // `loaded.id` — the folder the artifacts were actually read from — NOT
        // `profile.profileId`, the field inside the file. See `FilingProfileStore.active`: the
        // two can disagree, and when they do the writes went where nothing reads.
        manager.filingPeopleStore = PeopleStore(directory: profiles,
                                                profileId: loaded.id,
                                                profile: loaded.profile)
        // His verdicts on whose document is whose. A store for the same reason the roster is:
        // the person view writes through it, and nothing else on this machine may.
        manager.filingPersonTagStore = PersonTagStore(directory: profiles,
                                                      profileId: loaded.id)
        // Everything Restructure remembers — suppressions and Ask answers, then drafts and the
        // ledger as §5.4/§5.5 land. `loaded.id`, not `profile.profileId`, like every store here.
        manager.restructureStore = RestructureStore(directory: profiles, profileId: loaded.id)
        // Part of the question every file is asked — a re-survey must not replay answers the
        // old tree produced. Read from the same directory the artifacts came from.
        manager.filingArtifactFingerprint =
            FilingProfileStore.fingerprint(id: loaded.id, in: profiles)
        // When a survey last looked (§4.1) — the corpus's stamp, read without building the
        // documents dictionary. Nil for a corpus that predates the stamp, which the footnote
        // has words for.
        manager.filingSurveyedAt = FilingSurveyStore.surveyedAt(id: loaded.id, in: profiles)
        // **O16's baseline point.** Here rather than in `structureReport`, which a view body
        // reads on every render — and the stamp answers from the trend before it counts
        // anything, so a profile already recorded costs nothing at launch. Without this call
        // site the trend only ever gains points from landings: a user's first reorganisation
        // would leave one point and no chart, and a tree improved by hand between two walks
        // would have that improvement absorbed into the next landing's dot, crediting the
        // landing with work the user did themselves.
        if recordingTrend { manager.stampStructureTrend() }
        Logger.shared.info("Filing profile '\(loaded.id)' loaded — "
                           + "\(loaded.profile.folders.count) folder(s), "
                           + "\(loaded.memory?.folders.count ?? 0) with filing memory, "
                           + "\(manager.filingPeopleStore?.people.count ?? 0) person(s), "
                           + "\(manager.filingPersonTagStore?.tags.count ?? 0) person tag(s)")
        return true
    }
}
