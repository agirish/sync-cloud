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
    ///   the default is the point.** This function is otherwise read-only — bar the survey a
    ///   cut-off re-derive left in the parent folder, which it carries in afterwards, off the
    ///   main actor (`finishInterruptedSurveyReplay`) — and the app's own
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
        return attach(to: manager, profilesDirectory: profiles, recordingTrend: recordingTrend)
    }

    /// ``attach(to:recordingTrend:)`` against a given profiles directory — the seam tests use, so
    /// a scratch folder stands in for the real one. `readSurveyedAt` is the corpus-stamp read,
    /// passed so a test can see it runs off the main thread.
    @discardableResult
    static func attach(to manager: FileSyncManager, profilesDirectory profiles: URL,
                       recordingTrend: Bool = false,
                       readSurveyedAt: @escaping @Sendable (String, URL) -> Date?
                           = FilingSurveyStore.surveyedAt(id:in:)) -> Bool {

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

        // A different profile's date must not stand under this one while its own read runs:
        // Restructure's footnote would say "surveyed N days ago" about the profile just left.
        if manager.filingProfileDirectoryId != loaded.id { manager.filingSurveyedAt = nil }
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
        // When a survey last looked (§4.1) — the corpus's stamp. Nil for a corpus that predates
        // the stamp, which the footnote has words for.
        //
        // **Read off the main actor, and it arrives a moment late** (speed audit item 5). Even
        // without building the documents dictionary the read parses the whole corpus — about
        // 5 MB for a 9,500-document tree, 20–30 ms warm and more cold — before the first window,
        // for a date only a footnote shows. Both readers, Restructure's footnote and the survey
        // card's receipt, read the published value and leave the date out while it is nil.
        readSurveyDate(into: manager, id: loaded.id, in: profiles, using: readSurveyedAt)
        // **O16's baseline point.** Here rather than in `structureReport`, which a view body
        // reads on every render — and the stamp answers from the trend before it counts
        // anything, so a profile already recorded costs nothing at launch. Without this call
        // site the trend only ever gains points from landings: a user's first reorganisation
        // would leave one point and no chart, and a tree improved by hand between two walks
        // would have that improvement absorbed into the next landing's dot, crediting the
        // landing with work the user did themselves.
        if recordingTrend { manager.stampStructureTrend() }
        // A survey a cut-off re-derive left in the parent folder, read back without holding the
        // window (review C5): the memory arrives when it is rebuilt, a moment after launch.
        Task { await manager.finishInterruptedSurveyReplay() }
        Logger.shared.info("Filing profile '\(loaded.id)' loaded — "
                           + "\(loaded.profile.folders.count) folder(s), "
                           + "\(loaded.memory?.folders.count ?? 0) with filing memory, "
                           + "\(manager.filingPeopleStore?.people.count ?? 0) person(s), "
                           + "\(manager.filingPersonTagStore?.tags.count ?? 0) person tag(s)")
        return true
    }

    /// The latest stamp read per manager, and its generation. Its result is published only if it
    /// is still that manager's latest attach, the manager still holds the profile it was read for,
    /// and nothing set the date since — a re-survey that finished first publishes its own `now`,
    /// which a stale read must not overwrite.
    private static var surveyDateReads:
        [ObjectIdentifier: (generation: Int, task: Task<Void, Never>)] = [:]

    /// Only ever counts up. Numbering from the entry above restarted at 1 once a read had landed
    /// and removed it, so a third attach could share the first one's number and let that older
    /// read publish over the newest.
    private static var lastSurveyDateRead = 0

    /// The stamp read the latest attach to `manager` started and that has not landed yet, so a
    /// test can await it. Nil once it has.
    static func surveyDateRead(for manager: FileSyncManager) -> Task<Void, Never>? {
        surveyDateReads[ObjectIdentifier(manager)]?.task
    }

    private static func readSurveyDate(into manager: FileSyncManager, id: String, in profiles: URL,
                                       using read: @escaping @Sendable (String, URL) -> Date?) {
        let key = ObjectIdentifier(manager)
        lastSurveyDateRead += 1
        let generation = lastSurveyDateRead
        let seeded = manager.filingSurveyedAt
        let task = Task.detached(priority: .userInitiated) {
            let date = read(id, profiles)
            await MainActor.run {
                guard surveyDateReads[key]?.generation == generation else { return }
                surveyDateReads[key] = nil   // it holds the manager; let it go once landed
                // Undo and the interrupted-survey replay switch or set the date without an
                // attach; a read for the profile they left must not land under the new one.
                guard manager.filingProfileDirectoryId == id,
                      manager.filingSurveyedAt == seeded else { return }
                manager.filingSurveyedAt = date
            }
        }
        surveyDateReads[key] = (generation, task)
    }
}
