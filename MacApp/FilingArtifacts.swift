import Events
import Foundation
import Sync

/// Handing the manager the filing artifacts this machine has on disk. Callable more than once, so a
/// profile setup just wrote takes effect without a relaunch.
///
/// Read here in the app, not in `Sync`: library code must not reach into a real home directory by
/// default, the rule the verdict cache and the hash index follow too. Absent is the ordinary
/// state and costs only the accuracy it would have added.
@MainActor
enum FilingArtifacts {

    /// Loads the active profile and everything keyed to it, or leaves the manager untouched.
    ///
    /// - Parameter recordingTrend: whether to stamp the structure trend's baseline point.
    ///   **Defaults to false**: the app is the test host, so its launch path also runs under
    ///   `xcodebuild test`, and an unconditional stamp would write into the developer's real
    ///   `restructure.json`. Only a real launch passes true. Otherwise this is read-only, apart from
    ///   carrying in an interrupted survey off the main actor (`finishInterruptedSurveyReplay`).
    ///
    /// - Returns: whether anything was attached; `false` means no active profile, the ordinary
    ///   state on a Mac never surveyed. Not whether a walk just run took effect: a walk beside a
    ///   hand-built profile attaches that other profile and returns `true`.
    ///   `FolderWalkReport.becameActive` answers that, and the setup form reads it.
    @discardableResult
    static func attach(to manager: FileSyncManager, recordingTrend: Bool = false) -> Bool {
        guard let profiles = FilingProfileStore.defaultDirectory() else { return false }
        return attach(to: manager, profilesDirectory: profiles, recordingTrend: recordingTrend)
    }

    /// ``attach(to:recordingTrend:)`` against a given profiles directory, the seam tests use with a
    /// scratch folder. `readSurveyedAt` is the corpus-stamp read, passed so a test can see it runs
    /// off the main thread.
    @discardableResult
    static func attach(to manager: FileSyncManager, profilesDirectory profiles: URL,
                       recordingTrend: Bool = false,
                       readSurveyedAt: @escaping @Sendable (String, URL) -> Date?
                           = FilingSurveyStore.surveyedAt(id:in:)) -> Bool {

        // Set before the `active(in:)` guard: these are where things live, known with or without
        // a profile. Below it, a never-surveyed Mac would get a nil `filingProfilesDirectory`, and
        // the setup walk that creates the first profile would fail with `.noProfilesDirectory`.
        manager.filingProfilesDirectory = profiles
        // Where the byte-hash and PDF-fingerprint indexes live, for the same reason.
        manager.contentIndexDirectory = profiles.deletingLastPathComponent()

        guard let loaded = FilingProfileStore.active(in: profiles) else { return false }

        // A different profile's date must not stand under this one while its own read runs:
        // Restructure's footnote would say "surveyed N days ago" about the profile just left.
        if manager.filingProfileDirectoryId != loaded.id { manager.filingSurveyedAt = nil }
        manager.filingFolderProfile = loaded.profile
        manager.filingMemory = loaded.memory
        // …and the id it was read under, so `resurveyFilingMemory` writes back to the same folder,
        // as the stores below do.
        manager.filingProfileDirectoryId = loaded.id
        // The roster is the one filing artifact the user edits, so it is a store, not a value:
        // Settings writes through it, and the manager recompiles the registry and fingerprint
        // without a relaunch. Keyed by `loaded.id`, the folder actually read, not
        // `profile.profileId`: the two can disagree (`FilingProfileStore.active`), and writes keyed
        // by the latter would go where nothing reads.
        manager.filingPeopleStore = PeopleStore(directory: profiles,
                                                profileId: loaded.id,
                                                profile: loaded.profile)
        // His verdicts on whose document is whose. A store for the same reason the roster is:
        // the person view writes through it, and nothing else on this machine may.
        manager.filingPersonTagStore = PersonTagStore(directory: profiles,
                                                      profileId: loaded.id)
        // Everything Restructure remembers, such as suppressions and Ask answers. `loaded.id`, not
        // `profile.profileId`, like every store here.
        manager.restructureStore = RestructureStore(directory: profiles, profileId: loaded.id)
        // Part of the question every file is asked, so a re-survey doesn't replay answers the old
        // tree produced. Read from the same directory the artifacts came from.
        manager.filingArtifactFingerprint =
            FilingProfileStore.fingerprint(id: loaded.id, in: profiles)
        // When a survey last looked: the corpus's stamp, nil for a corpus that predates it. Read
        // off the main actor, so it arrives a moment late: the read parses the whole corpus (about
        // 5 MB for 9,500 documents) for a date only a footnote shows. Its readers leave the date
        // out while it is nil.
        readSurveyDate(into: manager, id: loaded.id, in: profiles, using: readSurveyedAt)
        // The structure trend's baseline point. Here, not in `structureReport`, which a view body
        // reads every render; a profile already recorded costs nothing. Without it the trend
        // gains points only from landings, so a first reorganisation would show no chart and a
        // tree improved by hand would be credited to the next landing.
        if recordingTrend { manager.stampStructureTrend() }
        // A survey a cut-off re-derive left in the parent folder, read back without holding the
        // window: the memory arrives when it is rebuilt, a moment after launch.
        Task { await manager.finishInterruptedSurveyReplay() }
        Logger.shared.info("Filing profile '\(loaded.id)' loaded — "
                           + "\(loaded.profile.folders.count) folder(s), "
                           + "\(loaded.memory?.folders.count ?? 0) with filing memory, "
                           + "\(manager.filingPeopleStore?.people.count ?? 0) person(s), "
                           + "\(manager.filingPersonTagStore?.tags.count ?? 0) person tag(s)")
        return true
    }

    /// The latest stamp read per manager, and its generation. Its result is published only if it
    /// is still that manager's latest attach, the manager still holds that profile, and nothing set
    /// the date since: a re-survey that finished first publishes its own `now`, which a stale read
    /// must not overwrite.
    private static var surveyDateReads:
        [ObjectIdentifier: (generation: Int, task: Task<Void, Never>)] = [:]

    /// Only ever counts up. Numbering from the entry above would restart once a read landed and
    /// removed it, letting an older read share the newest's number and publish over it.
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
