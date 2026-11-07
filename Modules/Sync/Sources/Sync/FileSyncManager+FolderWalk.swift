import Events
import Foundation

/// Deriving a folder profile from a walk: walks a tree, builds a profile with
/// ``FolderSurveyBuilder`` and writes it with
/// ``FilingProfileStore/writeProfile(_:in:builtBy:now:)``. Without a profile there is no
/// `profileId`, so no routing, rename proposals or Restructure findings.
///
/// Only the walk: it reads folder and file names and opens no document, so it takes seconds where
/// the document survey takes hours.
extension FileSyncManager {

    /// What a walk produced, in the terms the user is shown.
    public struct FolderWalkReport: Sendable, Equatable {
        /// Folders the profile now describes.
        public let foldersProfiled: Int
        /// The id the profile was written under. Always fresh — a profile is never overwritten.
        public let profileId: String
        /// The tree it describes, as the profile records it.
        public let root: String
        /// Whether `profiles.json` now names this profile. False is not failure: the store won't
        /// re-point away from a hand-built profile, so the new one lands on disk unread, and the
        /// report says so.
        public let becameActive: Bool
        /// The jurisdiction values the profile was built with, as confirmed by the user.
        public let jurisdictions: [String]
        /// A sentence for Setup to show when this folder's earlier Restructure history could not
        /// be taken up, so the user knows why it is missing. Nil when there is nothing to say.
        public var historyNotice: String? = nil

        public var summary: String {
            let folders = "\(foldersProfiled.formatted()) folder\(foldersProfiled == 1 ? "" : "s")"
            guard becameActive else {
                return "Learned \(folders), but this Mac already has a folder profile it did not "
                    + "write, so that one is still in use."
            }
            return "Learned \(folders) in \(root)."
        }
    }

    /// Why a walk could not run at all.
    public enum FolderWalkFailure: Error, Equatable, CustomStringConvertible {
        /// No directory to write artifacts into — the app hands that in, and `Sync` never invents
        /// a home directory of its own.
        case noProfilesDirectory
        /// The root could not be read at all — missing, not a directory, or unlistable.
        case rootUnreadable(String)
        /// The root is readable and holds no folders to learn. Its own case because an empty
        /// profile is worse than none: it reads as a surveyed tree downstream, so every routing
        /// question gets a confident "no destination".
        case nothingToLearn(String)
        /// The store refused. Carries its own reason.
        case refused(String)
        /// A reorganization is landing. Its re-derive publishes its own profile when its replay
        /// ends, over whatever a walk wrote meanwhile, and the walk's carry would copy files the
        /// landing is still writing.
        case landingInProgress
        /// The documents are being read (a Refresh, which can't be stopped, or a reading started
        /// after Setup stopped the last one). Writing would replace the profile that reading
        /// writes into, so its results would land in the replaced one.
        case documentsBeingRead

        public var description: String {
            switch self {
            case .noProfilesDirectory:
                return "no profiles directory was configured"
            case .rootUnreadable(let path):
                return "\(path) could not be read"
            case .nothingToLearn(let path):
                return "\(path) has no folders to learn from"
            case .refused(let why):
                return "the profile could not be written — \(why)"
            case .landingInProgress:
                return "a reorganization is landing, so the profile was not written"
            case .documentsBeingRead:
                return "the documents are being read into the profile this would replace, so it "
                    + "was not written"
            }
        }

        /// The failure in one plain sentence, for a person. `description` is the log's, lowercase
        /// and path-first, and reads wrong on screen.
        public var plainReason: String {
            switch self {
            case .noProfilesDirectory:
                return "SyncCloud has nowhere to keep folder profiles on this Mac."
            case .rootUnreadable(let path):
                return "“\((path as NSString).lastPathComponent)” couldn’t be read."
            case .nothingToLearn(let path):
                return "“\((path as NSString).lastPathComponent)” has no folders in it to learn from."
            case .refused(let why):
                return why
            case .landingInProgress:
                return "A reorganization is landing — save once it finishes."
            case .documentsBeingRead:
                return "SyncCloud is reading your documents — save once that finishes."
            }
        }

        /// What a store error says to a person: the reason ``refused(_:)`` carries. The store's own
        /// refusals get a sentence each, anything else Foundation's localized description.
        /// **Never** `String(describing:)` of an `NSError`, which puts `Error Domain=…` on screen.
        public static func plainRefusal(_ error: Error) -> String {
            guard let refusal = error as? FilingProfileStore.WriteRefusal else {
                return error.localizedDescription
            }
            switch refusal {
            case .profileExists:
                return "A profile with the same name was saved a moment ago. Try again."
            case .indexUnreadable:
                return "SyncCloud can’t read its list of folder profiles (profiles.json), so it "
                    + "won’t change it."
            case .invalidProfileId:
                return "The profile’s name can’t be used as a folder name."
            case .notReplacingTheActiveProfile:
                return "The folder profile in use changed while this one was being saved."
            case .chainMissing:
                return "The new profile doesn’t record the one it replaces, so it couldn’t be undone."
            }
        }
    }

    /// Walks `root` and writes a folder profile describing it.
    ///
    /// - Parameters:
    ///   - root: the folder to learn. A folder, not a source: the profile records a tree such as
    ///     `~/Documents`, and a source root would pull in Desktop, Downloads and the rest.
    ///   - jurisdictionValues: the place names the user confirmed. Handed in, not mined, because
    ///     mining invents places (`EMP`, `IT`, `PRD`). See ``JurisdictionCandidates``.
    ///   - registry: the household, for the person axis and the `person-bucket` role. Nil means
    ///     both are absent; no folder is misattributed for want of a roster.
    ///
    /// Returns the report, or the reason it could not run. An existing profile is not a failure:
    /// the walk succeeds and the report says the new one is not in use.
    ///
    /// The one-call form, walk and write with no preview. The setup sheet instead walks with
    /// ``walkForSetup(root:known:)`` and writes with
    /// ``writeWalkProfile(tree:root:jurisdictionValues:registry:now:)`` once the user approves.
    /// `FolderWalkTests` measures the profile this produces.
    public func deriveFolderProfile(root: URL,
                                    jurisdictionValues: Set<String> = [],
                                    registry: PersonRegistry? = nil,
                                    now: Date = Date()) async -> Result<FolderWalkReport, FolderWalkFailure> {
        guard filingProfilesDirectory != nil else {
            return .failure(.noProfilesDirectory)
        }

        Logger.shared.info("Folder walk starting at \(root.path) — "
                           + "\(jurisdictionValues.count) confirmed place(s), "
                           + "roster \(registry?.people.count ?? 0) person(s)")

        // Ask the filesystem before the walk. `buildTree` on a missing path returns one node, the
        // root, so its output can't tell a missing folder from a real one.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
            Logger.shared.warning("Folder walk refused: \(root.path) is not a readable folder")
            return .failure(.rootUnreadable(root.path))
        }

        // The same walk the panes do: names and counts only. Unbounded on purpose: the user just
        // picked this root, and a size prompt would cost more than it protects. Other large walks
        // gate through `largeWalkConfirmer`; a setup path onto an unvetted root should too.
        let tree = await Self.buildTree(url: root, sortOption: .name)

        return await writeWalkProfile(tree: tree, root: root,
                                      jurisdictionValues: jurisdictionValues,
                                      registry: registry, now: now)
    }

    /// Builds a profile from a tree already in hand and writes it. Separate from the walk because
    /// the setup sheet walks at Learn and writes several screens later, after a preview.
    /// ``deriveFolderProfile(root:jurisdictionValues:registry:now:)`` is this plus the walk.
    ///
    /// - Parameter tree: the root's children, as ``buildTree(url:sortOption:fileManager:maxDepth:budget:linkedFolders:)``
    ///   returns them.
    public func writeWalkProfile(tree: [FileNode], root: URL,
                                 jurisdictionValues: Set<String> = [],
                                 registry: PersonRegistry? = nil,
                                 now: Date = Date()) async -> Result<FolderWalkReport, FolderWalkFailure> {
        guard let directory = filingProfilesDirectory else {
            return .failure(.noProfilesDirectory)
        }

        let recordedRoot = Self.recordedRoot(for: root)
        let profileId = Self.availableWalkProfileId(now: now, in: directory)

        // Off the main actor: `FolderSurveyBuilder.build` is pure (no `FileManager`, `Date()` or
        // defaults), so it can run detached over thousands of folders without stalling the window.
        let profile = await Task.detached(priority: .userInitiated) {
            FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: profileId,
                                      registry: registry, jurisdictionValues: jurisdictionValues)
        }.value

        // "Nothing to learn" means nothing below the root. The builder always emits the root
        // itself under `"."`, so `folders.isEmpty` is never true.
        guard profile.folders.keys.contains(where: { $0 != FolderSurveyBuilder.rootEntryPath }) else {
            Logger.shared.warning("Folder walk refused: \(root.path) is readable but holds no "
                                  + "folders, and an empty profile would read as a surveyed tree")
            return .failure(.nothingToLearn(root.path))
        }

        // Checked after the build's await, with no await between here and the write: a landing
        // that started during the build would publish its re-derived profile over this one.
        guard !restructureLandingInProgress else {
            Logger.shared.info("Folder walk refused: a reorganization is landing, and its "
                + "re-derive would replace this profile when it finishes")
            return .failure(.landingInProgress)
        }
        // Nor while documents are being read into the profile this would replace: that reading
        // would land in the replaced profile. Beside a hand-built profile nothing is replaced, so
        // the write goes ahead.
        if filingSurveyLifecycle.isRunning,
           FilingProfileStore.mayRepoint(activeId: FilingProfileStore.activeProfileId(in: directory),
                                         in: directory) {
            Logger.shared.info("Folder walk refused: the documents are being read into the "
                + "profile this would replace")
            return .failure(.documentsBeingRead)
        }

        // Read BEFORE the write re-points the index — the profile this walk may be replacing.
        let previousId = FilingProfileStore.activeProfileId(in: directory)
        // Record the folder left before the index names the new one. Afterwards, a failed map
        // write could only carry the old history in, and it would later be recorded as the new
        // folder's. So a map that can't be written refuses the Save, and nothing moves.
        var plan = WalkHistoryPlan.carryAll
        if let previousId, previousId != profileId {
            switch Self.recordFolderLeft(previousId: previousId, newId: profileId,
                                         newRoot: profile.recordedFolderPath, in: directory, now: now) {
            case .success(let recorded): plan = recorded
            case .failure(let refusal): return .failure(.refused(refusal.sentence))
            }
        }
        do {
            _ = try FilingProfileStore.writeProfile(profile, in: directory, now: now)
        } catch {
            Logger.shared.error("Folder walk could not write its profile: \(LogError.describe(error))")
            return .failure(.refused(FolderWalkFailure.plainRefusal(error)))
        }

        let becameActive = FilingProfileStore.activeProfileId(in: directory) == profileId
        var historyNotice: String?
        if becameActive, let previousId, previousId != profileId {
            let carried = Self.carryCuratedState(from: previousId, to: profileId,
                                                 root: profile.recordedFolderPath, plan: plan,
                                                 in: directory, now: now)
            historyNotice = carried.notice
            // The folder's survey comes too, off the main actor (thousands of documents to decode
            // and write). Awaited, so Setup's Save starts its reading only once it is in place.
            if !carried.surveyFrom.isEmpty {
                let recorded = profile.root
                await Task.detached(priority: .userInitiated) {
                    for source in carried.surveyFrom {
                        Self.carrySurvey(from: source, to: profileId, root: recorded, in: directory)
                    }
                }.value
            }
        }
        let report = FolderWalkReport(foldersProfiled: profile.folders.count,
                                      profileId: profileId,
                                      root: recordedRoot,
                                      becameActive: becameActive,
                                      jurisdictions: jurisdictionValues.sorted(),
                                      historyNotice: historyNotice)
        if becameActive {
            Logger.shared.info("Folder walk wrote profile '\(profileId)' — "
                               + "\(profile.folders.count) folder(s) from \(recordedRoot), and it "
                               + "is now the active profile")
        } else {
            // Looks like success but changes nothing: the store won't re-point away from a profile
            // it did not write.
            Logger.shared.warning("Folder walk wrote profile '\(profileId)' with "
                                  + "\(profile.folders.count) folder(s), but this Mac's active "
                                  + "profile was not written by SyncCloud, so it was left in place "
                                  + "and the new one is not in use")
        }
        return .success(report)
    }

    /// What a walk does with the path-keyed history, decided before the profile is written.
    enum WalkHistoryPlan: Equatable {
        /// Carry everything: the map can't be read (and is never written over), or the profile
        /// left records no folder.
        case carryAll
        /// The same folder walked again.
        case sameFolder
        /// Another folder; the map as it now stands on disk, the folder left recorded in it.
        case otherFolder([RestructureRootMap.Entry])
    }

    /// The map could not be written, so the walk must not switch folders.
    struct HistoryNotRecorded: Error {
        let sentence: String
    }

    /// The first half of the walk's carry, run before `profiles.json` is re-pointed: decides the
    /// plan and, for another folder, records the folder left in ``RestructureRootMap``. A failed
    /// map write is the one answer that stops the Save.
    static func recordFolderLeft(previousId: String, newId: String, newRoot: String?,
                                 in directory: URL,
                                 now: Date) -> Result<WalkHistoryPlan, HistoryNotRecorded> {
        let previousRecorded = FilingProfileStore.recordedRoot(id: previousId, in: directory)
        let previousRoot = previousRecorded.map(RestructureRootMap.expanded)
        if FilingProfileStore.namesSameRoot(previousRoot, newRoot) { return .success(.sameFolder) }
        guard let previousRecorded, let previousRoot, previousRoot.hasPrefix("/"),
              newRoot != nil else { return .success(.carryAll) }
        var entries: [RestructureRootMap.Entry]
        switch RestructureRootMap.read(in: directory) {
        case .unreadable(let why):
            Logger.shared.warning("Restructure: \(RestructureRootMap.filename) \(why) — the "
                + "Restructure history and person verdicts of \(previousRecorded) were carried to "
                + "\(newId) as before, and the map was left as it is")
            return .success(.carryAll)
        case .loaded(let loaded):
            entries = loaded
        }

        // Drop an entry whose folder is gone: it has no history to return to, and would pin its
        // profile folder (corpus, memory and all) for good. Only when the disk says so.
        entries.removeAll { entry in
            guard let why = RestructureRootMap.whyGone(entry, in: directory) else { return false }
            Logger.shared.info("Restructure: dropped the history entry for \(entry.root) — \(why)")
            return true
        }

        // Never displace an entry while it is the only way back: one whose take-up failed names
        // the folder's real history, and replacing it would hand that history to the next sweep.
        // Nor is it displaced by a folder with no history, which is not recorded at all: an entry
        // would pin it for nothing.
        if let old = RestructureRootMap.index(of: previousRoot, in: entries),
           entries[old].takeUpFailedAt != nil
            || (!RestructureRootMap.holdsHistory(id: previousId, in: directory)
                && RestructureRootMap.holdsHistory(id: entries[old].profileId, in: directory)) {
            Logger.shared.info("Restructure: kept \(entries[old].profileId) as the history of "
                + "\(previousRecorded) — "
                + (entries[old].takeUpFailedAt != nil
                   ? "it was never taken up, and what \(previousId) holds since stays there"
                   : "\(previousId) holds none"))
        } else {
            if let old = RestructureRootMap.index(of: previousRoot, in: entries) { entries.remove(at: old) }
            if RestructureRootMap.holdsHistory(id: previousId, in: directory) {
                // What every other history held now — the folder about to be taken up among them.
                // A landing found later that is not in this set came after the user left.
                let seen = RestructureRootMap.landings(in: entries.map(\.profileId),
                                                       directory: directory)
                entries.append(.init(root: previousRecorded, profileId: previousId,
                                     leftAt: FilingProfileStore.stamp(now), landingsSeen: seen))
            }
        }
        do {
            try RestructureRootMap.write(entries, in: directory)
        } catch {
            Logger.shared.error("Restructure: could not record \(previousRecorded) in "
                + "\(RestructureRootMap.filename): \(error.localizedDescription) — the walk was "
                + "refused, and \(previousId) stays in use")
            return .failure(HistoryNotRecorded(sentence: "SyncCloud couldn’t note where "
                + "“\((previousRecorded as NSString).lastPathComponent)” keeps its Restructure "
                + "history, so it didn’t switch to this folder. Nothing was changed."))
        }
        return .success(.otherFolder(entries))
    }

    /// Carries what the user made to the new profile, and keeps each folder's own Restructure
    /// history. The roster, person verdicts and Restructure ledger live in `profiles/<id>/`, and a
    /// walk writes a new id, so without this a re-run of Setup lands on an empty folder. Copied,
    /// never moved: the old folder is what an Undo re-points to.
    ///
    /// The roster follows every walk. The ledger and verdicts are keyed by paths in the folder
    /// walked (``RestructureRootMap/historyNames``), so they follow that folder:
    ///
    /// - **The same folder again** (``FilingProfileStore/namesSameRoot(_:_:)``): both are carried
    ///   and the last landing's Undo re-pointed at the new id. The folder's map entry is dropped,
    ///   unless its history was never taken up, in which case the take-up is retried.
    /// - **Another folder**: the folder left is already in the map
    ///   (``recordFolderLeft(previousId:newId:newRoot:in:now:)``), and the walk takes up the new
    ///   folder's history if the map has one. Its Undo is re-pointed unless a later landing in an
    ///   overlapping folder reshaped the tree it describes; then it stays withdrawn and the log
    ///   names that folder. No history starts an empty ledger and verdict file. A failed copy keeps
    ///   and marks the entry, starts empty, and returns a sentence for the screen.
    /// - **A map that can't be read** is never written over: both are carried, so nothing is lost.
    ///   Likewise for a profile that records no folder.
    ///
    /// The survey follows too: for the same folder or a taken-up history,
    /// ``CarryOutcome/surveyFrom`` names the profiles holding its corpus, memory and progress, so
    /// Setup's Save doesn't restart a survey of hours. The caller carries them off the main actor.
    ///
    /// - Returns: a sentence for Setup to show when a history could not be taken up, and where
    ///   the folder's survey is.
    @discardableResult
    static func carryCuratedState(from previousId: String, to newId: String,
                                  root newRoot: String?, plan: WalkHistoryPlan,
                                  in directory: URL, now: Date = Date()) -> CarryOutcome {
        let fm = FileManager.default
        switch plan {
        case .carryAll:
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm)
            return CarryOutcome()
        case .sameFolder:
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm)
            RestructureStore(directory: directory, profileId: newId)
                .repointProduced(from: previousId, to: newId)
            var outcome = CarryOutcome(surveyFrom: [previousId])
            guard case .loaded(var entries) = RestructureRootMap.read(in: directory),
                  let stale = RestructureRootMap.index(of: newRoot, in: entries) else { return outcome }
            // A history never taken up is taken up now, over what the empty start gathered.
            if entries[stale].takeUpFailedAt != nil {
                outcome.notice = takeUp(stale, of: &entries, into: newId, replacing: true,
                                        surveyFrom: &outcome.surveyFrom, in: directory, now: now)
                return outcome
            }
            // The entry goes only when this folder now holds the history: after a failed take-up
            // the active folder holds the empty files, and the entry is the only way back.
            if RestructureRootMap.holdsHistory(id: newId, in: directory)
                || !RestructureRootMap.holdsHistory(id: entries[stale].profileId, in: directory) {
                entries.remove(at: stale)
                do {
                    try RestructureRootMap.write(entries, in: directory)
                } catch {
                    Logger.shared.warning("Restructure: could not update "
                        + "\(RestructureRootMap.filename): \(error.localizedDescription)")
                }
            }
            return outcome
        case .otherFolder(var entries):
            let history = RestructureRootMap.historyNames
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm,
                                  names: FilingProfileStore.curatedArtifactNames.filter {
                                      !history.contains($0) },
                                  carryingExportedPlans: false)
            let file = { (id: String, name: String) in directory.appendingPathComponent("\(id)/\(name)") }
            guard let returning = RestructureRootMap.index(of: newRoot, in: entries),
                  history.contains(where: {
                      fm.fileExists(atPath: file(entries[returning].profileId, $0).path) }) else {
                if let empty = RestructureRootMap.index(of: newRoot, in: entries) {
                    // An entry whose folder holds neither file holds no history to return to.
                    let dropped = entries.remove(at: empty)
                    do {
                        try RestructureRootMap.write(entries, in: directory)
                    } catch {
                        Logger.shared.warning("Restructure: could not drop the empty history entry "
                            + "for \(dropped.root) from \(RestructureRootMap.filename): "
                            + "\(error.localizedDescription)")
                    }
                }
                RestructureRootMap.startEmptyHistory(in: directory, profileId: newId)
                return CarryOutcome()
            }
            var outcome = CarryOutcome()
            outcome.notice = takeUp(returning, of: &entries, into: newId, replacing: false,
                                    surveyFrom: &outcome.surveyFrom, in: directory, now: now)
            return outcome
        }
    }

    /// What the curated carry leaves to its caller.
    struct CarryOutcome: Equatable {
        /// The sentence Setup shows when a history could not be taken up.
        var notice: String?
        /// The profiles holding this folder's survey, the first to hold one wins.
        var surveyFrom: [String] = []
    }

    /// Carries `oldId`'s survey of the same folder (progress, corpus and memory) into `newId`
    /// where `newId` has none yet. No moves lie between them, so the keys hold. Runs off the main
    /// actor.
    nonisolated static func carrySurvey(from oldId: String, to newId: String, root: String,
                                        in directory: URL) {
        let unchanged = RestructureManifest(profileId: oldId, manifestId: "setup-walk",
                                            createdAt: FilingProfileStore.stamp(Date()),
                                            family: ".", kind: .deadWeight, actions: [])
        carrySurveyArtifacts(from: oldId, to: newId, through: unchanged, root: root, in: directory)
    }

    /// Takes `entries[index]`'s history up into `newId`: ledger and verdicts copied in (over
    /// `newId`'s own when `replacing`, a retry), survey carried where `newId` has none, the entry
    /// dropped, and the last landing's Undo re-pointed unless a later overlapping landing reshaped
    /// the tree. A failed copy leaves `newId`'s files as they were, marks the entry so no walk
    /// displaces it, and returns the sentence Setup shows.
    private static func takeUp(_ index: Int, of entries: inout [RestructureRootMap.Entry],
                               into newId: String, replacing: Bool,
                               surveyFrom: inout [String], in directory: URL,
                               now: Date) -> String? {
        let fm = FileManager.default
        let entry = entries[index]
        let file = { (id: String, name: String) in directory.appendingPathComponent("\(id)/\(name)") }
        // Staged beside the target and swapped in only once every copy has been made, so a copy
        // that fails part-way changes nothing in `newId`.
        var staged: [(temp: URL, target: URL)] = []
        do {
            for name in RestructureRootMap.historyNames
            where fm.fileExists(atPath: file(entry.profileId, name).path) {
                let temp = file(newId, ".\(name).take-up")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: file(entry.profileId, name), to: temp)
                staged.append((temp, file(newId, name)))
            }
            for (temp, target) in staged {
                if fm.fileExists(atPath: target.path) {
                    guard replacing else { try fm.removeItem(at: temp); continue }
                    _ = try fm.replaceItemAt(target, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: target)
                }
            }
        } catch {
            for item in staged { try? fm.removeItem(at: item.temp) }
            Logger.shared.warning("Restructure: could not take up the Restructure history and "
                + "person verdicts of \(entry.root) from \(entry.profileId): "
                + "\(error.localizedDescription) — they stay there, \(newId) "
                + (replacing ? "keeps what it holds" : "starts with none")
                + ", and the next walk of the folder tries again")
            entries[index].takeUpFailedAt = FilingProfileStore.stamp(now)
            do {
                try RestructureRootMap.write(entries, in: directory)
            } catch {
                Logger.shared.warning("Restructure: could not mark the history of \(entry.root) "
                    + "as not taken up in \(RestructureRootMap.filename): "
                    + "\(error.localizedDescription)")
            }
            RestructureRootMap.startEmptyHistory(in: directory, profileId: newId)
            return "SyncCloud couldn’t bring back the Restructure history and person checks "
                + "“\((entry.root as NSString).lastPathComponent)” had before, so this folder starts "
                + "without them. They’re kept, and learning this folder again tries once more."
        }
        // A history with only one of the two files gets an empty other.
        RestructureRootMap.startEmptyHistory(in: directory, profileId: newId)
        // The plans exported in this folder come back with its history, so the folder they sit
        // in is not kept forever for their sake once the map entry goes.
        carryProfileArtifacts(from: entry.profileId, to: newId, in: directory, fm: fm, names: [])
        surveyFrom.append(entry.profileId)
        entries.remove(at: index)
        do {
            try RestructureRootMap.write(entries, in: directory)
        } catch {
            Logger.shared.warning("Restructure: could not update \(RestructureRootMap.filename): "
                + "\(error.localizedDescription)")
        }
        Logger.shared.info("Restructure: took up the history of \(entry.root) from "
            + "\(entry.profileId), left \(entry.leftAt)")
        // As recorded (`~/Documents/Tax`): the overlap test expands it, and the card names it.
        let others = entries.map { (root: $0.root, profileId: $0.profileId) }
        if let withheld = RestructureRootMap.laterOverlappingLanding(
            in: entry.root, seen: entry.landingsSeen, others: others, directory: directory) {
            Logger.shared.warning("Restructure: the last landing in \(entry.root) cannot be "
                + "undone — " + (withheld.unsure
                    ? "the history of \(withheld.root) cannot say whether a landing there since "
                        + "\(entry.leftAt) reshaped the folders its Undo would move back"
                    : "a landing in \(withheld.root) since \(entry.leftAt) reshaped the folders "
                        + "its Undo would move back"))
            RestructureStore(directory: directory, profileId: newId)
                .withholdUndo(producedBy: entry.profileId, because: withheld.root,
                              unsure: withheld.unsure)
            return nil
        }
        RestructureStore(directory: directory, profileId: newId)
            .repointProduced(from: entry.profileId, to: newId)
        return nil
    }

    /// What the profile would say about a walked tree, for the Structure screen, touching no disk.
    /// Writing per preview would mint a directory on every Back, collide on ids within a second,
    /// and churn the fingerprint cached verdicts hang off.
    /// ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` is pure, so
    /// this is the same computation under an id that is never written.
    public static func previewProfile(walk: SetupWalk,
                                      registry: PersonRegistry?,
                                      jurisdictionValues: Set<String>) -> FolderProfile {
        FolderSurveyBuilder.build(tree: walk.tree,
                                  root: recordedRoot(for: walk.root),
                                  profileId: previewProfileId,
                                  registry: registry,
                                  jurisdictionValues: jurisdictionValues)
    }

    /// The id a preview carries. Never written: a profile on disk under this id means a preview
    /// escaped.
    public static let previewProfileId = "setup-preview"

    /// How the profile records the tree it describes: folded to `~` under the home directory, as
    /// hand-built profiles spell it (`root: "~/Documents"`). Nothing parses it, so this keeps the
    /// file readable and diffable against the offline builder's.
    static func recordedRoot(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A walk id not already on disk. The stamp has one-second resolution, so two walks in a second
    /// collide and `writeProfile` refuses. A suffix rather than a UUID, since people read these ids
    /// in `profiles.json`.
    static func availableWalkProfileId(now: Date, in directory: URL) -> String {
        let base = walkProfileId(now: now)
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: profileURLForId(candidate, in: directory).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            // A hundred walks inside one second is not a user, it is a loop; stop rather than spin.
            if suffix > 100 { return "\(base)-\(UUID().uuidString.prefix(8))" }
        }
        return candidate
    }

    private static func profileURLForId(_ id: String, in directory: URL) -> URL {
        FilingProfileStore.profileURL(id: id, in: directory)
    }

    /// A fresh id for each walk, never reused. Nothing is overwritten in place, so the profile in
    /// use before a walk stays on disk and can be pointed back at by hand.
    static func walkProfileId(now: Date) -> String {
        "walk-" + FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
