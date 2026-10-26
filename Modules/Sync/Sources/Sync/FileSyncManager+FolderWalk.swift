import Events
import Foundation

/// Deriving a folder profile from a walk — the half of the filing artifacts the app could produce
/// but had no way to *run*.
///
/// ``FolderSurveyBuilder`` has been able to derive a profile since `d4280231`, and
/// ``FilingProfileStore/writeProfile(_:in:builtBy:now:)`` has been able to write one; what was
/// missing between them was anything that walked a tree and put the two together. Without it,
/// `resurveyFilingMemory` opens by requiring a `profileId` that only a profile carries, so a machine
/// that never ran the out-of-repo script got no routing, no rename proposals and no Restructure
/// findings — and nothing on screen said why.
///
/// **This is the walk, and only the walk.** It reads folder and file *names* and opens no document:
/// seconds on a 3,000-folder tree, against the hours the document survey needs. That split is
/// deliberate — a lens that can answer in seconds should not wait forty minutes for a corpus it does
/// not read.
extension FileSyncManager {

    /// What a walk produced, in the terms the user is shown.
    public struct FolderWalkReport: Sendable, Equatable {
        /// Folders the profile now describes.
        public let foldersProfiled: Int
        /// The id the profile was written under. Always fresh — a profile is never overwritten.
        public let profileId: String
        /// The tree it describes, as the profile records it.
        public let root: String
        /// Whether `profiles.json` now names this profile.
        ///
        /// **False is not failure, and it is the case worth reporting.** The store refuses to
        /// re-point away from a hand-built profile, so on a machine that has one the walk succeeds,
        /// the profile lands on disk, and nothing reads it. Saying so is the difference between
        /// "done" and "done, and it changed nothing you will notice".
        public let becameActive: Bool
        /// The jurisdiction values the profile was built with, as confirmed by the user.
        public let jurisdictions: [String]
        /// A sentence for Setup to show when this folder's earlier Restructure history could not
        /// be taken up (review C1) — the log's warning alone left the user looking at a folder
        /// with none of it and no word why. Nil when there is nothing to say.
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
        /// The root is readable and holds no folders to learn.
        ///
        /// **Its own case, because an empty profile is worse than no profile.** It decodes
        /// perfectly and reads as a surveyed tree everywhere downstream, so every routing question
        /// gets a confident "no destination" — and the user is told their tree was learned.
        case nothingToLearn(String)
        /// The store refused. Carries its own reason.
        case refused(String)
        /// A reorganization is landing (review R5). Its re-derive publishes its own profile when
        /// its corpus replay ends, over whatever a walk wrote meanwhile — and the walk's carry
        /// would copy files the landing is still writing.
        case landingInProgress

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
            }
        }

        /// The failure in one plain sentence, for a person rather than the log.
        ///
        /// **`description` is the log's**: lowercase and path-first. Setup's Structure screen
        /// showed it under its own heading, so a failed Save read "Couldn’t save your folder
        /// profile, so nothing was written." over "the profile could not be written — …".
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
            }
        }

        /// What a store error says to a person — the reason ``refused(_:)`` carries.
        ///
        /// **Never `String(describing:)` of an `NSError`**, which is `Error Domain=NSCocoaErrorDomain
        /// Code=… UserInfo={…}`: that is what a failed Save put on screen. The store's own refusals
        /// get a sentence each; anything else gets Foundation's localized description.
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
    ///   - root: the folder to learn. **A folder, not a source**: what the store records is a tree,
    ///     and on this machine the hand-built profile's is `~/Documents` rather than the whole of
    ///     iCloud Drive. Surveying a source root would pull in Desktop, Downloads and everything
    ///     else beside it.
    ///   - jurisdictionValues: the place names the user confirmed. Handed in rather than mined,
    ///     because the mining is only 83.2% right and every point of the gap is an invention —
    ///     `EMP`, `IT` and `PRD` are an employer, a department and a product stage. See
    ///     ``JurisdictionCandidates``.
    ///   - registry: the household, for the person axis and the `person-bucket` role. Nil is fine
    ///     and means both are simply absent; no folder is misattributed for want of a roster.
    ///
    /// Returns the report, or the reason it could not run. **Never throws for "there was already a
    /// profile"** — that is a successful walk whose result is not in use, and the report says so.
    ///
    /// **The guided setup sheet no longer calls this**: it reads the tree once with
    /// ``walkForSetup(root:known:)``, shows the user what a profile of it would say, and writes
    /// with ``writeWalkProfile(tree:root:jurisdictionValues:registry:now:)`` when they approve.
    /// This stays as the one-call form — walk and write, no preview — and as the behaviour net
    /// under that split: `FolderWalkTests` measures the profile it produces, and A2 was verified
    /// by diffing its output byte for byte across the change.
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

        // **Asked of the filesystem before the walk, not inferred from the walk's output.**
        // `buildTree` on a path that does not exist returns a tree of ONE node — the root itself —
        // so `tree.isEmpty` never fires for the case it was written for, and the walk cheerfully
        // recorded a one-folder profile of a directory that is not there. Same shape as
        // `enumerator(at:)` handing back a non-nil enumerator that yields nothing for an unlistable
        // directory, which made a `guard let` a dead branch one file over.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else {
            Logger.shared.warning("Folder walk refused: \(root.path) is not a readable folder")
            return .failure(.rootUnreadable(root.path))
        }

        // The same walk the panes do. Names and counts only — no document is opened.
        //
        // **Unbounded, and deliberately so — a setup-scope decision, not an oversight.** The
        // setup walks run over the profile root the user just pointed the sheet at, in a flow
        // where a size prompt would cost more than it protects. The four Organize/Storage passes
        // and the folder-memory re-survey all gate through `largeWalkConfirmer`; if setup ever
        // grows a path onto an unvetted root, these join them.
        let tree = await Self.buildTree(url: root, sortOption: .name)

        return await writeWalkProfile(tree: tree, root: root,
                                      jurisdictionValues: jurisdictionValues,
                                      registry: registry, now: now)
    }

    /// Builds a profile from a tree already in hand and writes it.
    ///
    /// **Split out of ``deriveFolderProfile(root:jurisdictionValues:registry:now:)`` so the tree
    /// and the write stop being one step.** The guided setup sheet reads the tree once, at Learn,
    /// and shows the user what a profile of it would say several screens before anything is
    /// written — so the write has to be reachable without walking again, and the preview has to be
    /// reachable without writing. `deriveFolderProfile` is now this plus the walk, and produces a
    /// byte-identical `folder-profile.json` for the same tree and the same `now`.
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

        // **Hoisted off the main actor.** `FileSyncManager` is `@MainActor`, and
        // `FolderSurveyBuilder.build` is a pure function of its arguments — no `FileManager`, no
        // `Date()`, no defaults — precisely so it can run detached over a few thousand folders
        // without the window going unresponsive.
        let profile = await Task.detached(priority: .userInitiated) {
            FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: profileId,
                                      registry: registry, jurisdictionValues: jurisdictionValues)
        }.value

        // **`isEmpty` is never true, which is why this counts something else.** The builder always
        // emits an entry for the root itself under `"."`, so a walk of a folder with nothing in it
        // produces a profile of exactly one folder — and a guard on `folders.isEmpty` is a branch
        // that cannot be taken. What "nothing to learn" means is nothing *below* the root.
        guard profile.folders.keys.contains(where: { $0 != FolderSurveyBuilder.rootEntryPath }) else {
            Logger.shared.warning("Folder walk refused: \(root.path) is readable but holds no "
                                  + "folders, and an empty profile would read as a surveyed tree")
            return .failure(.nothingToLearn(root.path))
        }

        // **Checked after the build's await, with none between here and the write** (review R5):
        // a landing that started while the profile was being built would publish its re-derived
        // profile over this one at the end of its replay.
        guard !restructureLandingInProgress else {
            Logger.shared.warning("Folder walk refused: a reorganization is landing, and its "
                + "re-derive would replace this profile when it finishes")
            return .failure(.landingInProgress)
        }

        // Read BEFORE the write re-points the index — the profile this walk may be replacing.
        let previousId = FilingProfileStore.activeProfileId(in: directory)
        // **The folder left is recorded BEFORE the index names the new one** (review C2). Once
        // `profiles.json` points at the new folder, a map that could not be written left the walk
        // only one move — carrying the old folder's history in, as before the map — and that
        // history was then recorded as the NEW folder's at the next walk away, over the entry
        // naming its real one. So a map that cannot be written refuses the Save, and nothing moves.
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
            Logger.shared.warning("Folder walk could not write its profile: \(error)")
            return .failure(.refused(FolderWalkFailure.plainRefusal(error)))
        }

        let becameActive = FilingProfileStore.activeProfileId(in: directory) == profileId
        var historyNotice: String?
        if becameActive, let previousId, previousId != profileId {
            historyNotice = Self.carryCuratedState(from: previousId, to: profileId,
                                                   root: profile.recordedFolderPath, plan: plan,
                                                   in: directory, now: now)
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
            // The one outcome that looks like success and is not useful, said plainly. The store
            // refuses to re-point away from a profile it did not write.
            Logger.shared.warning("Folder walk wrote profile '\(profileId)' with "
                                  + "\(profile.folders.count) folder(s), but this Mac's active "
                                  + "profile was not written by SyncCloud, so it was left in place "
                                  + "and the new one is not in use")
        }
        return .success(report)
    }

    /// What a walk does with the path-keyed history, decided before the profile is written.
    enum WalkHistoryPlan: Equatable {
        /// Carry everything, as before the map: the map cannot be read (and is never written
        /// over), or the profile left records no folder.
        case carryAll
        /// The same folder walked again.
        case sameFolder
        /// Another folder; the map as it now stands on disk, the folder left recorded in it.
        case otherFolder([RestructureRootMap.Entry])
    }

    /// The map could not be written, so the walk must not switch folders (review C2).
    struct HistoryNotRecorded: Error {
        let sentence: String
    }

    /// **The first half of the walk's carry, run before `profiles.json` is re-pointed**: decides
    /// the plan and, for another folder, records the folder left in ``RestructureRootMap``.
    /// A failure to write the map is the one answer that stops the Save.
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

        // **An entry whose folder is gone goes** (review R4): a Setup folder deleted since, or a
        // profile folder no longer there, has no history to return to, and the entry would pin
        // its profile folder — corpus, memory and all — for good. Only when the disk says so.
        entries.removeAll { entry in
            guard let why = RestructureRootMap.whyGone(entry, in: directory) else { return false }
            Logger.shared.info("Restructure: dropped the history entry for \(entry.root) — \(why)")
            return true
        }

        // **Never displaced while it is the only way back.** An entry whose take-up failed
        // (review C1) names the folder's real history while the folder being left holds what
        // the user made since it started empty — replacing it handed the real history to the
        // next sweep. Nor is it displaced by an empty folder (an older entry with no mark).
        // **And a folder with no history is not recorded at all** (review R4): an entry would
        // pin it for nothing.
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
            Logger.shared.warning("Restructure: could not record \(previousRecorded) in "
                + "\(RestructureRootMap.filename): \(error.localizedDescription) — the walk was "
                + "refused, and \(previousId) stays in use")
            return .failure(HistoryNotRecorded(sentence: "SyncCloud couldn’t note where "
                + "“\((previousRecorded as NSString).lastPathComponent)” keeps its Restructure "
                + "history, so it didn’t switch to this folder. Nothing was changed."))
        }
        return .success(.otherFolder(entries))
    }

    /// **What the user made follows the active profile to its new folder** (FR4), and **each
    /// folder Setup walks keeps its own Restructure history** (FR4, follow-up).
    ///
    /// The household roster, the person verdicts and Restructure's ledger live in
    /// `profiles/<id>/`, and a walk writes a brand-new id. Only the Restructure re-derive used to
    /// copy them, so re-running Setup's Learn and Save moved the app onto an empty folder: the
    /// roster read back as the folder-name seed, the verdicts and the last landing's Undo were
    /// gone, and the next survey refresh retired the old folder with everything in it. Copied,
    /// never moved — the old folder is what an Undo re-points to, as for a re-derive.
    ///
    /// The roster is about people alone and follows every walk. The ledger and the verdicts are
    /// keyed by paths relative to the folder walked (``RestructureRootMap/historyNames``), so
    /// they follow that folder:
    ///
    /// - **The same folder walked again** (``FilingProfileStore/namesSameRoot(_:_:)``, links and
    ///   case resolved): both are carried and the last landing's Undo re-pointed at the new id.
    ///   Any ``RestructureRootMap`` entry for the folder is dropped — the new id is its latest —
    ///   unless its history was never taken up (review C1): then the take-up is tried again.
    /// - **Another folder**: the folder left was recorded in the map before the profile was
    ///   written (``recordFolderLeft(previousId:newId:newRoot:in:now:)``), and the walk takes up
    ///   the NEW folder's history if the map has one — copied in, with its last landing's Undo
    ///   re-pointed unless a landing applied since the user left it, in a folder that is it or
    ///   inside it or holds it, reshaped the tree that Undo describes (the Undo then stays
    ///   withdrawn, and the log names that folder). A folder with no history starts an empty
    ///   ledger and an empty verdict file. A copy that fails keeps the entry, marks it, starts
    ///   empty, and says so on screen — the returned sentence.
    /// - **A map that cannot be read** is never written over: the walk carries both as it did
    ///   before the map existed, so nothing is lost on a read error. So does a walk from a
    ///   profile that records no folder.
    ///
    /// - Returns: a sentence for Setup to show when a history could not be taken up, else nil.
    @discardableResult
    static func carryCuratedState(from previousId: String, to newId: String,
                                  root newRoot: String?, plan: WalkHistoryPlan,
                                  in directory: URL, now: Date = Date()) -> String? {
        let fm = FileManager.default
        switch plan {
        case .carryAll:
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm)
            return nil
        case .sameFolder:
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm)
            RestructureStore(directory: directory, profileId: newId)
                .repointProduced(from: previousId, to: newId)
            guard case .loaded(var entries) = RestructureRootMap.read(in: directory),
                  let stale = RestructureRootMap.index(of: newRoot, in: entries) else { return nil }
            // A history never taken up is taken up now, over what the empty start gathered.
            if entries[stale].takeUpFailedAt != nil {
                return takeUp(stale, of: &entries, into: newId, replacing: true,
                              in: directory, now: now)
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
            return nil
        case .otherFolder(var entries):
            let history = RestructureRootMap.historyNames
            carryProfileArtifacts(from: previousId, to: newId, in: directory, fm: fm,
                                  names: FilingProfileStore.curatedArtifactNames.filter {
                                      !history.contains($0) })
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
                return nil
            }
            return takeUp(returning, of: &entries, into: newId, replacing: false,
                          in: directory, now: now)
        }
    }

    /// Takes `entries[index]`'s history up into `newId`: its ledger and verdicts copied in —
    /// over what `newId` holds when `replacing` (a retry, review C1) — its survey carried where
    /// `newId` has none, the entry dropped, and its last landing's Undo re-pointed unless a later
    /// landing in an overlapping folder reshaped the tree. A copy that fails leaves `newId`'s
    /// own files as they were (starting empty ones where it has none), marks the entry so no
    /// walk displaces it, and answers the sentence Setup shows.
    private static func takeUp(_ index: Int, of entries: inout [RestructureRootMap.Entry],
                               into newId: String, replacing: Bool, in directory: URL,
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
        if let reshaped = RestructureRootMap.laterOverlappingLanding(
            in: entry.root, seen: entry.landingsSeen, others: others, directory: directory) {
            Logger.shared.warning("Restructure: the last landing in \(entry.root) cannot be "
                + "undone — a landing in \(reshaped) since \(entry.leftAt) reshaped the folders "
                + "its Undo would move back")
            RestructureStore(directory: directory, profileId: newId)
                .withholdUndo(producedBy: entry.profileId, because: reshaped)
            return nil
        }
        RestructureStore(directory: directory, profileId: newId)
            .repointProduced(from: entry.profileId, to: newId)
        return nil
    }

    /// What the profile would say about a walked tree, without writing anything.
    ///
    /// **The Structure screen's whole content, and it touches no disk.** Writing a profile per
    /// preview would mint a directory each time the user pressed Back to fix a name, refuse over
    /// an existing id inside the same second, and churn the fingerprint that cached verdicts hang
    /// off. ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` is
    /// pure, so the preview is the same computation with an id that is never written.
    public static func previewProfile(walk: SetupWalk,
                                      registry: PersonRegistry?,
                                      jurisdictionValues: Set<String>) -> FolderProfile {
        FolderSurveyBuilder.build(tree: walk.tree,
                                  root: recordedRoot(for: walk.root),
                                  profileId: previewProfileId,
                                  registry: registry,
                                  jurisdictionValues: jurisdictionValues)
    }

    /// The id a preview carries. Never minted, never written — a profile on disk under this id
    /// would mean the preview escaped.
    public static let previewProfileId = "setup-preview"

    /// How the profile records the tree it describes.
    ///
    /// Folded to `~` when it is under the home directory, because that is how every hand-built
    /// profile on this machine spells it (`root: "~/Documents"`) and the field is compared against
    /// them. Nothing parses it — ``FolderSurveyBuilder`` never touches the root on disk — so this is
    /// about the file being readable by a person, and diffable against the offline builder's.
    static func recordedRoot(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A walk id that is not already on disk.
    ///
    /// **The stamp is second-resolution, so two walks in one second collide** — and `writeProfile`
    /// refuses over an existing id, correctly, which surfaced as "the profile could not be written"
    /// for the ordinary act of pressing *Learn again* on a small tree. Disambiguated with a suffix
    /// rather than a UUID because these ids are read by a person in `profiles.json`; `walk-…-2` says
    /// what it is where `walk-3f9c…` does not.
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

    /// A fresh id for each walk.
    ///
    /// **Always fresh, never reused.** A profile is written under its own id and `profiles.json` is
    /// re-pointed; nothing is ever overwritten in place, so the profile that was in use before a
    /// walk is still on disk afterwards and can be pointed back at by hand.
    static func walkProfileId(now: Date) -> String {
        "walk-" + FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
