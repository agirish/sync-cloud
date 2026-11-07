import Events
import Foundation

/// Restructure's Apply: one landing, run in eight ordered steps, plus the ledger undo that
/// survives a quit. Kept apart from `+Restructure` (the scaffold), the safe subset.
///
/// How far a landing has got, as the sheet shows it: the step boundaries the engine crosses, so a
/// reader can see the inverse reach disk before anything moves.
public struct RestructureApplyProgress: Equatable, Sendable {

    /// The stages a reader can tell apart. The last two steps fold into `artifacts`: corpus
    /// replay, memory rebuild and the log line are one wait.
    ///
    /// The order is promised, not a dwell on each line: `guards` and `inverse` take well under a
    /// frame, and the checklist shows them ticked above `operations`. The `Task.yield()`s in
    /// `applyPlan` give each a chance at a frame; no duration is asserted.
    public enum Stage: Int, Comparable, Sendable, CaseIterable {
        case guards, inverse, operations, verify, rederive, artifacts

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var stage: Stage
    /// Operations completed and planned; both zero outside ``Stage/operations``.
    public var opsDone: Int
    public var opsTotal: Int

    public init(stage: Stage, opsDone: Int = 0, opsTotal: Int = 0) {
        self.stage = stage
        self.opsDone = opsDone
        self.opsTotal = opsTotal
    }


    /// What each stage says while current, written as the thing being done, in the engine's order.
    public static func label(_ stage: Stage) -> String {
        switch stage {
        case .guards: return "Checking nothing else is running"
        case .inverse: return "Writing the inverse to disk, before anything moves"
        case .operations: return "Running the operations, re-probing each one"
        case .verify: return "Verifying from a second code path"
        case .rederive: return "Re-reading the tree to rebuild the survey"
        case .artifacts: return "Carrying the survey’s artifacts across"
        }
    }

    /// The operations line, with its count once there is one to give.
    public func line() -> String {
        guard stage == .operations, opsTotal > 0 else { return Self.label(stage) }
        return "\(Self.label(stage)) — \(opsDone) of \(opsTotal)"
    }
}

/// What a survey refresh did, or the sentence saying why it would not run. An enum rather than a
/// `String?`, so a caller must handle success too, and success carries both folder counts: a walk
/// that changed nothing differs from one that found two thousand folders.
public enum SurveyRefreshOutcome: Equatable, Sendable {
    /// The walk landed and the survey was replaced. `folders` is what the new one holds,
    /// `previousFolders` what the old one did.
    case updated(folders: Int, previousFolders: Int)
    /// A guard closed, or the re-derive failed. The sentence is the whole of what to show.
    case refused(String)

    /// The refusal sentence, or nil when it worked, for a caller that renders the two differently
    /// (the Scaffolded card puts its refusal on the card that asked).
    public var refusal: String? {
        if case .refused(let sentence) = self { return sentence }
        return nil
    }

    /// The one spelling of what to tell the user, so call sites can't drift apart. Success names
    /// the delta, not just the total, so "the tree hadn't moved" reads differently from a button
    /// that did nothing.
    public var sentence: String {
        switch self {
        case .refused(let sentence):
            return sentence
        case .updated(let folders, let previousFolders):
            let delta = folders - previousFolders
            let total = "Survey updated — \(folders) folder\(folders == 1 ? "" : "s")"
            if delta > 0 { return total + ", \(delta) more than before." }
            if delta < 0 { return total + ", \(-delta) fewer than before." }
            return total + ", unchanged since the last survey."
        }
    }
}

@MainActor
extension FileSyncManager {

    /// What one plan landing did — or why it refused to start.
    public struct RestructureApplyOutcome: Equatable, Sendable {
        public var renamed = 0
        public var filesMoved = 0
        public var foldersMovedWhole = 0
        public var created = 0
        public var collisions = 0
        public var removedEmpty = 0
        /// Sentences naming what was skipped and why: a folder holding unlisted files, a source
        /// that vanished, a destination that got taken. Reported, never silent.
        public var skipped: [String] = []
        /// An undo's items that had changed since the landing (edited, or saved over) and were
        /// moved back all the same, named so the person can check them.
        public var changedSince: [String] = []
        /// The independent verifier's disagreements: reported on the card and in the log, never
        /// rolled back on their own.
        public var verifierMismatches: [String] = []
        public var producedProfileId: String?
        /// The landing ran but the survey could not be refreshed.
        public var surveyRefreshFailure: String?
        public var refusal: String?
        /// The manifest as it actually landed, performed actions only. A caller replaying the
        /// landing onto its own keys must use this: the planned manifest includes skipped renames,
        /// and `rekey` moved the store's keys through the performed set.
        public var landedManifest: RestructureManifest?

        public init() {}

        /// The ledger sentence, derived from what happened.
        public var summary: String {
            var parts = ["\(renamed) rename\(renamed == 1 ? "" : "s")",
                         "\(filesMoved) moved"]
            if foldersMovedWhole > 0 {
                parts.append("\(foldersMovedWhole) folder"
                    + "\(foldersMovedWhole == 1 ? "" : "s") carried whole")
            }
            if created > 0 { parts.append("\(created) created") }
            if removedEmpty > 0 {
                // "empty", not "emptied": the removal step also trashes standing empties that
                // were empty all along, and this sentence outlives the sheet on the ledger card.
                parts.append("\(removedEmpty) empty folder"
                    + "\(removedEmpty == 1 ? "" : "s") removed")
            }
            if collisions > 0 {
                parts.append("\(collisions) name collision\(collisions == 1 ? "" : "s"), both kept")
            }
            if !changedSince.isEmpty {
                parts.append("\(changedSince.count) changed since, moved back")
            }
            if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
            return parts.joined(separator: " · ")
        }
    }

    /// Lands a manifest: guards → inverse on disk → re-probed operations → independent verify →
    /// one grouped ⌘Z → profile re-derivation → key replay → one log line.
    public func applyPlan(_ manifest: RestructureManifest, now: Date = Date()) async
        -> RestructureApplyOutcome {
        let elapsed = Elapsed()
        var outcome = RestructureApplyOutcome()
        if let refusal = restructureLandingRefusal() {
            outcome.refusal = refusal
            return outcome
        }
        restructureLandingInProgress = true
        restructureApplyProgress = RestructureApplyProgress(stage: .guards)
        // Cleared however this returns, or the sheet would show a checklist for finished work.
        defer {
            restructureLandingInProgress = false
            restructureApplyProgress = nil
        }
        guard let store = restructureStore, let profile = filingFolderProfile,
              let expandedRoot = profile.recordedFolderPath,
              let profilesDirectory = filingProfilesDirectory else {
            outcome.refusal = "No folder survey is loaded."
            return outcome
        }
        let oldDirectoryId = filingProfileDirectoryId ?? profile.profileId
        let stamp = FilingProfileStore.stamp(now)

        // A manifest lands once. The finalize rewrites the record found by this id, so a second
        // landing would replace the first one's stored inverse, destroying its post-quit undo.
        guard !store.applied.contains(where: { $0.manifest.manifestId == manifest.manifestId })
        else {
            outcome.refusal = "The ledger already records a landing of this plan "
                + "(\(manifest.manifestId)) — a manifest lands once. Derive a fresh plan to "
                + "run it again."
            return outcome
        }

        // Step 2: the record, inverse included, on disk before the first operation, so a crash
        // mid-run leaves a reversible trace. A failed write refuses: never move unrecorded.
        restructureApplyProgress = RestructureApplyProgress(stage: .inverse)
        // See `Stage`: this and the yield below give the two pre-operations lines a chance at a
        // frame, or the first thing drawn would be `operations`.
        await Task.yield()
        guard store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: stamp, created: 0, skipped: 0,
            appliedUnderProfileId: oldDirectoryId)) else {
            outcome.refusal = "The ledger could not be written, so nothing was moved — a "
                + "reorganization only runs once its inverse is safely on disk. Check "
                + "restructure.json’s folder is writable."
            return outcome
        }

        // Step 3: the operations, re-probing every claim at the moment of the action.
        let fm = fileManager
        let actions = manifest.actions
        restructureApplyProgress = RestructureApplyProgress(
            stage: .operations, opsDone: 0, opsTotal: manifest.operationCount)
        // The counter comes from the executor's loop, off the main actor, coalesced there by
        // `ProgressPublishGate`: every write to this manager re-evaluates the window's root view,
        // so one per file would be a render storm.
        let progressSink: @Sendable (Int) -> Void = { [weak self] done in
            Task { @MainActor in
                guard let self, var current = self.restructureApplyProgress,
                      current.stage == .operations else { return }
                current.opsDone = done
                self.restructureApplyProgress = current
            }
        }
        await Task.yield()
        let journal = RestructureLandingJournal(
            at: RestructureLandingJournal.url(manifestId: manifest.manifestId,
                                              profileId: oldDirectoryId, in: profilesDirectory))
        let execution: RestructureExecution = await enqueueFileOperation {
            FileSyncManager.executeRestructureActions(actions, root: expandedRoot, fm: fm,
                                                      journal: journal, onProgress: progressSink)
        }
        outcome.renamed = execution.renamed
        outcome.filesMoved = execution.filesMoved
        outcome.foldersMovedWhole = execution.foldersMovedWhole
        outcome.created = execution.created
        outcome.collisions = execution.collisions
        outcome.removedEmpty = execution.removedEmpty
        outcome.skipped = execution.skipped

        // Step 4: verify from a different code path — re-list the touched folders and check the
        // tree against what the performed actions claim, sharing none of the mover's arithmetic.
        restructureApplyProgress = RestructureApplyProgress(stage: .verify)
        // Two `fileExists` per performed action, so off the main actor, or a large merge hangs
        // the window. Through the same serial file-operation queue, so the verify reads the tree
        // strictly after the moves and before anything else the app does to it. Awaited, so every
        // reader below sees the same verdict.
        let performed = execution.performed
        outcome.verifierMismatches = await enqueueFileOperation {
            FileSyncManager.verifyRestructureLanding(performed, root: expandedRoot, fm: fm)
        }

        // Every skip and mismatch, one line each: the finalize stores only the performed subset,
        // so these lines are the only durable record of planned actions that didn't run.
        for sentence in execution.skipped {
            Logger.shared.info("Restructure apply \(manifest.manifestId) skipped: \(sentence)")
        }
        for mismatch in outcome.verifierMismatches {
            Logger.shared.warning("Restructure apply \(manifest.manifestId) verifier: \(mismatch)")
        }

        // Step 5: one grouped ⌘Z for this launch; the ledger's inverse is every later one.
        if !execution.moveItems.isEmpty || !execution.renameItems.isEmpty
            || !execution.createdURLs.isEmpty,
           let undo = undoManager {
            // Registration order is undo order reversed: created dirs first (removed last), then
            // renames, then content moves, so ⌘Z moves every file out of `Forms/` before `Forms/`
            // becomes `Federal Tax/` again.
            undo.beginUndoGrouping()
            for url in execution.createdURLs {
                registerCreateFolderUndo(url: url, fileManager: fm)
            }
            let actionName = "Reorganize \(RestructurePaths.familyLabel(manifest.family))"
            if !execution.renameItems.isEmpty {
                // Renames get their own pair, not `registerMoveUndo`: its shallow identity (child
                // count and mtime) is changed by this group's own merges into the renamed folder,
                // so the rename-back would be refused as drift. A whole-folder rename can't lose
                // content on undo, since everything inside travels with it.
                registerRestructureRenameUndo(items: execution.renameItems,
                                              actionName: actionName)
            }
            if !execution.moveItems.isEmpty {
                registerMoveUndo(items: execution.moveItems, actionName: actionName)
            }
            undo.endUndoGrouping()
            undo.setActionName(actionName)
        } else if execution.removedEmpty > 0, let undo = undoManager {
            // A removal landing registers no session undo (folders went to the Trash), so ⌘Z
            // would replay the previous landing's group into folders this one just trashed.
            // Clear the stack; the removal's ledger card carries its real undo. Blunt on
            // purpose: unrelated undos go too, and a lost undo is redone by hand, a replay into
            // trashed folders is not.
            undo.removeAllActions()
            Logger.shared.info("Restructure apply \(manifest.manifestId): removal landing — "
                + "session ⌘Z cleared; Undo This Reorganization… is the way back")
        }

        // The manifest as it landed: performed actions only, with collision names and byte
        // counts. The inverse comes from this; the plan's would move files back from names they
        // never landed at.
        var landed = manifest
        landed.actions = execution.performed
        outcome.landedManifest = landed
        let finalised = store.updateApplied(manifestId: manifest.manifestId) {
            $0.manifest = landed
            $0.inverse = landed.inverse
            $0.created = execution.created
            $0.skipped = execution.skipped.count
            $0.summary = outcome.summary
            // Step 4's verdict, recorded where the card can read it, not only in the log.
            $0.verifiedOK = outcome.verifierMismatches.isEmpty
            $0.verifierNote = outcome.verifierMismatches.isEmpty ? nil
                : Self.verifierNote(outcome.verifierMismatches)
        }
        // The record now says what ran, so the journal is done, but only once that record is on
        // disk. If the write failed, the next launch refuses Undo as an unfinished landing and
        // points at this journal as the list of what ran, so it is closed and kept.
        if finalised {
            journal?.finish()
        } else {
            journal?.close()
            Logger.shared.warning("Restructure apply \(manifest.manifestId): the landing's record "
                + "could not be written, so its list of the steps that ran is kept")
        }

        restructureApplyProgress = RestructureApplyProgress(stage: .rederive)
        // Steps 6 and 7, separate so the Scaffolded card can run the same re-derive with a
        // manifest that moved nothing.
        switch await rederiveProfile(through: landed, profile: profile,
                                     oldDirectoryId: oldDirectoryId,
                                     profilesDirectory: profilesDirectory, store: store,
                                     expandedRoot: expandedRoot,
                                     ledgerId: manifest.manifestId,
                                     summaryForLedger: outcome.summary, now: now) {
        case .success(let newId):
            outcome.producedProfileId = newId
        case .failure(let sentence):
            outcome.surveyRefreshFailure = "Applied; " + sentence
            return outcome
        }
        let newId = outcome.producedProfileId ?? oldDirectoryId

        // Step 8: one log line, found later by grepping the manifest id.
        Logger.shared.info("Restructure apply \(manifest.manifestId): \(manifest.family) — "
            + "\(outcome.summary); verifier "
            + (outcome.verifierMismatches.isEmpty ? "OK"
               : "MISMATCH (\(outcome.verifierMismatches.count))")
            + "; profile \(oldDirectoryId) → \(newId) (\(elapsed.text))")
        return outcome
    }

    /// What a re-derive came back with: the new profile directory, or the sentence saying why the
    /// app still reads the old one.
    enum RederiveResult {
        case success(String)
        case failure(String)
    }

    /// Steps 6 and 7 of a landing, callable on their own: re-derive the profile from a fresh walk,
    /// carry the per-profile artifacts into the new directory, replay the corpus keys through
    /// `landed`, rebuild the memory, and swap every store to it. The Scaffolded card runs it with
    /// a manifest that moved nothing, so the replay is an identity and the walk is the point.
    ///
    /// `ledgerId` is the landing this belongs to, or nil for a survey refresh, which has no record
    /// to finalise (a made-up id would make the updates below silent no-ops).
    private func rederiveProfile(
        through landed: RestructureManifest, profile: FolderProfile, oldDirectoryId: String,
        profilesDirectory: URL, store: RestructureStore, expandedRoot: String,
        ledgerId: String?, summaryForLedger: String?, now: Date) async -> RederiveResult {
        // Step 6: re-derive the profile from a fresh walk: a finding goes because the tree was
        // re-read, never because it was marked done. A failure here is reported, not rolled back:
        // the moves landed and the ledger records them.
        let rootURL = URL(fileURLWithPath: expandedRoot)
        let tree = await Self.buildTree(url: rootURL, sortOption: .name)
        let newId = FileSyncManager.availableReorgProfileId(now: now, in: profilesDirectory)
        // The curated registry (`people.json`), not `PersonRegistry.seeded(from:)`, which is only
        // the fallback when there is none. `carryOver` writes `fresh.personAliases` back, so a
        // thinner registry would lose aliases on every pass, compounding.
        // `thePersonAndLifecycleAxesAgree` guards it.
        let registry = FilingProfileStore.personRegistry(id: oldDirectoryId, profile: profile,
                                                         in: profilesDirectory)
        let jurisdictions = RestructureRederive.entryJurisdictions(of: profile)
        // As the file spells it, `~` and all, never the `~` a file without one decodes to: every
        // landing refuses that profile first (`restructureLandingRefusal`).
        let recordedRoot = profile.root
        // `carryOver` rides in the same detached hop: a pure function rebuilding thousands of
        // entries, with no reason to be on the main actor. One hop, since only it reads the build.
        let derived = await Task.detached(priority: .userInitiated) {
            let fresh = FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: newId,
                                                  registry: registry,
                                                  jurisdictionValues: jurisdictions)
            return RestructureRederive.carryOver(from: profile, into: fresh, through: landed)
                .settingDerivedFrom(oldDirectoryId)
        }.value
        // The write stays on the main actor: it amends `profiles.json`, shared with everything
        // that can mint a profile, and a walk already under way may write it too. Off the actor
        // it would risk a lost update on the file that decides which profile the app reads.
        //
        // What the user made reaches the new folder before `profiles.json` names it. Everything
        // after the write is awaited (the replay takes seconds), and a quit in that wait would
        // relaunch onto a folder whose ledger doesn't name it, losing the landing's Undo
        // (`undoableReorganisation` keys on `producedProfileId ?? appliedUnderProfileId`). So the
        // carry and the new ledger's tail run first, synchronously, with no suspension before the
        // write. The old folder keeps the only corpus and memory until the replay; the retire
        // sweep keeps it, and the next load reads them back (`recoverInterruptedSurveyReplay`).
        // If the write fails, the copies are removed: the index never named that folder.
        let fm = fileManager
        let alreadyThere = Set(FilingProfileStore.curatedArtifactNames.filter {
            fm.fileExists(atPath: profilesDirectory.appendingPathComponent("\(newId)/\($0)").path)
        })
        // The folder the write below would make, made first so the copies have somewhere to land.
        try? fm.createDirectory(at: profilesDirectory.appendingPathComponent(newId),
                                withIntermediateDirectories: true, attributes: nil)
        let carriedExports = FileSyncManager.carryProfileArtifacts(from: oldDirectoryId, to: newId,
                                                                   in: profilesDirectory, fm: fm)
        let newStore = RestructureStore(directory: profilesDirectory, profileId: newId)
        // Which store this one carries on from, and through which renames, so an undo registered
        // against the old one can find its key here (`unsuppressStructureFinding`).
        newStore.adoptLineage(from: store, renames: RestructureRederive.renameMap(of: landed))
        // One write for the rekey, the rescue record and the produced-id update, not three.
        // `recordApplied` inside is the batch's documented exception: it always reaches disk,
        // because its answer is a safety claim.
        newStore.batchingSaves {
            newStore.rekey(renames: RestructureRederive.renameMap(of: landed),
                           context: ledgerId ?? "survey refresh")
            // The artifact carry is best-effort. If restructure.json failed to copy, the update
            // below would no-op and strand the finalised record and its inverse where nothing
            // reads. The ledger record is not best-effort: write it into the new store directly.
            if let ledgerId,
               !newStore.applied.contains(where: { $0.manifest.manifestId == ledgerId }),
               let finalised = store.applied.first(where: { $0.manifest.manifestId == ledgerId }) {
                newStore.recordApplied(finalised)
                Logger.shared.warning("Restructure re-derive \(ledgerId): restructure.json did not "
                    + "carry over; the ledger record was written into \(newId) directly")
            }
            if let ledgerId {
                newStore.updateApplied(manifestId: ledgerId) { $0.producedProfileId = newId }
            } else {
                // A survey refresh carries the undo chain across here too, before the write:
                // `undoableReorganisation` needs the produced profile to be the current one, and
                // a quit during the replay would leave the last landing un-undoable.
                newStore.repointProduced(from: oldDirectoryId, to: newId)
            }
        }
        do {
            try FilingProfileStore.writeDerivedProfile(derived, replacing: oldDirectoryId,
                                                       in: profilesDirectory, now: now)
        } catch {
            for name in FilingProfileStore.curatedArtifactNames where !alreadyThere.contains(name) {
                try? fm.removeItem(at: profilesDirectory.appendingPathComponent("\(newId)/\(name)"))
            }
            for name in carriedExports {
                try? fm.removeItem(at: profilesDirectory.appendingPathComponent("\(newId)/\(name)"))
            }
            let folder = profilesDirectory.appendingPathComponent(newId)
            if FileSyncManager.directoryNames(at: folder.path, fm: fm)?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
            if let ledgerId {
                store.updateApplied(manifestId: ledgerId) {
                    $0.summary = (summaryForLedger ?? "") + " — survey not refreshed"
                }
            }
            Logger.shared.warning("Restructure re-derive \(ledgerId ?? "(no landing)"): the "
                + "profile re-derivation failed: \(LogError.describe(error))")
            return .failure("the survey could not be refreshed — " + String(describing: error))
        }

        // The stores the user edits move to the new folder now, before the replay's wait. The
        // window stays live for those seconds, and an edit written to the old folder after its
        // copy was taken would be lost. The profile, memory and id wait for the replay; the
        // stores write by their own folder, never by those.
        restructureStore = newStore
        filingPeopleStore = PeopleStore(directory: profilesDirectory, profileId: newId,
                                        profile: derived)
        filingPersonTagStore = PersonTagStore(directory: profilesDirectory, profileId: newId)

        restructureApplyProgress = RestructureApplyProgress(stage: .artifacts)
        // Step 7: the curated artifacts moved above; here the corpus keys are replayed and the
        // memory rebuilt. No page is re-read for a file that only moved.
        //
        // All in one detached hop: decoding thousands of documents, flattening and building
        // memory would hitch the main actor (`FileSyncManager+FilingRefine.swift`). Safe where
        // the profile write is not because of what it writes: the corpus, memory and progress
        // under the new `\(newId)`, or the old folder's when finishing an interrupted replay
        // (`recoverInterruptedSurveyReplay`), files nothing else writes while the landing flag is
        // up. Awaited, so `filingMemory` is set before anything below reads it.
        let replayed: (memory: FilingMemory, failure: String?)? =
            await Task.detached(priority: .userInitiated) { () -> (FilingMemory, String?)? in
                // An earlier replay that never finished leaves the folder this one reads from
                // empty; finish it first, or this replay finds nothing.
                FileSyncManager.recoverInterruptedSurveyReplay(into: oldDirectoryId,
                                                               profile: profile,
                                                               in: profilesDirectory)
                // Before the corpus guard: a stopped first survey is exactly the profile that has
                // progress and no corpus yet.
                FileSyncManager.carrySurveyProgress(from: oldDirectoryId, to: newId,
                                                    in: profilesDirectory, through: landed)
                guard let corpus = FilingSurveyStore.corpus(id: oldDirectoryId,
                                                            in: profilesDirectory) else {
                    return nil
                }
                let rekeyed = RestructureRederive.rekeyedCorpus(corpus, through: landed)
                let renamed = FilingCorpus(profileId: newId, salt: rekeyed.salt,
                                           documents: rekeyed.documents,
                                           surveyedAt: rekeyed.surveyedAt)
                let flattened = FilingSurvey.flatten(tree)
                let memory = FilingSurvey.buildMemory(corpus: renamed,
                                                      folderModified: flattened.folders,
                                                      profileId: newId)
                do {
                    try FilingSurveyStore.write(corpus: renamed, memory: memory,
                                                previousMemory: nil, id: newId,
                                                in: profilesDirectory, root: recordedRoot,
                                                now: now)
                    return (memory, nil)
                } catch {
                    return (memory, String(describing: error))
                }
            }.value
        if let replayed {
            if let failure = replayed.failure {
                // Logged from the main actor.
                Logger.shared.warning("Restructure re-derive \(ledgerId ?? "(no landing)"): the replayed "
                    + "corpus could not be written under \(newId): \(failure)")
                // The old folder's date must not stand under the new one, which has no corpus.
                filingSurveyedAt = nil
            } else {
                // Published only when the write succeeded: a memory that never reached disk must
                // not become the live one.
                filingMemory = replayed.memory
                filingSurveyedAt = now
            }
        }

        // The new directory is active now: stores re-open there, the finding cache drops with the
        // profile publish, and the fingerprint moves, invalidating cached verdicts whose paths
        // just changed.
        filingFolderProfile = derived
        filingProfileDirectoryId = newId
        filingArtifactFingerprint = FilingProfileStore.fingerprint(id: newId,
                                                                   in: profilesDirectory)
        // The old store keeps the finalised record too: Undo reads that ledger after re-pointing
        // back to that directory.
        if let ledgerId {
            store.updateApplied(manifestId: ledgerId) { $0.producedProfileId = newId }
        }
        // Retire what this re-derivation superseded: every re-derive mints a new profile folder.
        //
        // Every id any ledger record names is pinned, undone records included: Undo
        // re-points at `appliedUnderProfileId` through `repointActiveProfile`, which needs the
        // folder on disk. The store adds the active profile and anything not provably derived.
        // The predecessor isn't pinned separately: after a plan apply it is the record's
        // `appliedUnderProfileId`, and after a bare refresh nothing can reach it.
        //
        // A failure is logged and swallowed: the survey was refreshed, and failing a successful
        // re-derivation over housekeeping would be the worse report.
        var protected: Set<String> = []
        for record in newStore.applied {
            if let applied = record.appliedUnderProfileId { protected.insert(applied) }
            if let produced = record.producedProfileId { protected.insert(produced) }
        }
        do {
            let retired = try FilingProfileStore.retireSupersededProfiles(
                protecting: protected, in: profilesDirectory, fileManager: fileManager)
            if !retired.isEmpty {
                Logger.shared.info("Filing profiles: retired \(retired.count) superseded "
                    + "profile(s) — \(retired.joined(separator: ", "))")
            }
        } catch {
            Logger.shared.warning("Filing profiles: the superseded profiles could not be "
                + "retired: \(LogError.describe(error))")
        }
        // The trend point for the new survey. `landing:` is whether a manifest caused it; a
        // survey refresh moves no files, so its point gets no dot.
        stampStructureTrend(landing: ledgerId != nil, now: now)
        return .success(newId)

    }

    /// Makes the survey catch up, for the Scaffolded card. A scaffold's folders reach the profile
    /// only once the tree is walked again, so this runs the landing's re-derive with a manifest
    /// that moves nothing: the walk is the whole operation.
    ///
    /// It replaces a hand-built profile with a derived one, as a plan's step 6 does; the button's
    /// help says so.
    ///
    /// Returns `.updated` with the folder counts, or `.refused` with the sentence the card shows.
    /// A refusal is never queued: "wait for the scan" means wait and press it again.
    public func refreshDerivedProfile(now: Date = Date()) async -> SurveyRefreshOutcome {
        if let refusal = restructureLandingRefusal() { return .refused(refusal) }
        restructureLandingInProgress = true
        // `rederiveProfile` publishes progress, and `applyPlan`'s defer doesn't run here, so this
        // one clears it, or the next plan sheet would open on a stale checklist.
        defer {
            restructureLandingInProgress = false
            restructureApplyProgress = nil
        }
        guard let store = restructureStore, let profile = filingFolderProfile,
              let expandedRoot = profile.recordedFolderPath,
              let profilesDirectory = filingProfilesDirectory else {
            return .refused("No folder survey is loaded.")
        }
        let oldDirectoryId = filingProfileDirectoryId ?? profile.profileId
        // Read before the walk replaces `filingFolderProfile`, for the comparison.
        let previousFolders = profile.folders.count
        // Moves nothing: the rename map is empty and the replay an identity, leaving the walk.
        let identity = RestructureManifest(
            profileId: oldDirectoryId, manifestId: "survey-refresh",
            createdAt: FilingProfileStore.stamp(now), family: ".", kind: .deadWeight,
            actions: [])
        switch await rederiveProfile(through: identity, profile: profile,
                                     oldDirectoryId: oldDirectoryId,
                                     profilesDirectory: profilesDirectory, store: store,
                                     expandedRoot: expandedRoot, ledgerId: nil,
                                     summaryForLedger: nil, now: now) {
        case .success(let newId):
            // `rederiveProfile` already carried the undo chain across (`repointProduced`, before
            // `profiles.json` named the new folder), so a landing that was undoable still is.
            //
            // The staleness note reads this stamp, and a refresh must clear it even with no
            // corpus to rewrite (`rederiveProfile` stamps only in the corpus branch).
            filingSurveyedAt = now
            let folders = filingFolderProfile?.folders.count ?? previousFolders
            Logger.shared.info("Restructure: survey re-derived on request — "
                + "\(oldDirectoryId) → \(newId); \(previousFolders) → \(folders) folder(s)")
            return .updated(folders: folders, previousFolders: previousFolders)
        case .failure(let sentence):
            return .refused("The survey was not refreshed — " + sentence)
        }
    }

    /// *Undo this reorganisation*: the ledger's inverse, run through the same guards and
    /// re-probes, then `profiles.json` re-pointed back to `appliedUnderProfileId`, kept for this.
    /// Unlike ⌘Z it survives a quit. A file that moved on since is skipped and reported.
    public func undoReorganisation(manifestId: String, now: Date = Date()) async
        -> RestructureApplyOutcome {
        var outcome = RestructureApplyOutcome()
        if let refusal = restructureLandingRefusal() {
            outcome.refusal = refusal
            return outcome
        }
        restructureLandingInProgress = true
        defer { restructureLandingInProgress = false }
        guard let store = restructureStore, let profilesDirectory = filingProfilesDirectory,
              let expandedRoot = filingFolderProfile?.recordedFolderPath else {
            outcome.refusal = "No folder survey is loaded."
            return outcome
        }
        guard let record = store.applied.first(where: { $0.manifest.manifestId == manifestId })
        else {
            outcome.refusal = "The ledger has no record of \(manifestId), so there is nothing "
                + "to undo."
            return outcome
        }
        guard record.undoneAt == nil else {
            outcome.refusal = "This reorganization was already undone (\(record.undoneAt ?? ""))."
            return outcome
        }
        guard let previousId = record.appliedUnderProfileId else {
            outcome.refusal = "The record does not name the profile it was applied under, so "
                + "there is nothing safe to re-point to."
            return outcome
        }
        // Only the newest not-undone reorganisation can be undone: an older inverse describes a
        // tree a later landing reshaped. Walked by ledger order, not profile id: a later landing
        // whose re-derive failed never re-pointed the survey, so ids can't see it on top.
        if let index = store.applied.firstIndex(where: { $0.manifest.manifestId == manifestId }),
           store.applied[(index + 1)...].contains(where: {
               $0.appliedUnderProfileId != nil && $0.undoneAt == nil
           }) {
            outcome.refusal = "A later reorganization sits on top of this one — undo that one "
                + "first, newest first, the way ⌘Z would."
            return outcome
        }
        // A record without a summary never finalised (the app quit mid-apply), and its stored
        // inverse is the plan's, without collision names, so replaying it could move the wrong
        // file. Refuse, and point at the landing's journal, one line per action as each ran.
        guard record.summary != nil else {
            let journalPath = filingProfilesDirectory.map {
                RestructureLandingJournal.url(manifestId: manifestId,
                                              profileId: record.appliedUnderProfileId ?? "", in: $0).path
            }
            let named = journalPath.flatMap {
                fileManager.fileExists(atPath: $0) ? "Each step that ran is listed, in order, in \($0)." : nil
            } ?? "No list of the steps that ran was found."
            outcome.refusal = "This landing never finished recording what it did — the app "
                + "quit mid-apply — so its stored inverse may not match the disk and will not "
                + "be replayed. " + named
            return outcome
        }
        // The survey must still be where the landing left it: the directory it produced, or, if
        // its re-derive failed before re-pointing, the one it was applied under.
        guard (record.producedProfileId ?? previousId) == (filingProfileDirectoryId ?? "") else {
            outcome.refusal = "The survey has moved since this landing — the active profile is "
                + "not the one it left behind, so re-pointing back would aim the survey at the "
                + "wrong tree."
            return outcome
        }
        // The store's `undoableReorganisation` is the one spelling of "which landing may be
        // undone", and it enables the menu item and the cards. The guards above name the cause;
        // this makes the decision the store's, so a surface and the engine can never disagree.
        guard store.undoableReorganisation(currentProfileId: filingProfileDirectoryId)?
                .manifest.manifestId == manifestId else {
            outcome.refusal = "This landing is not the one the ledger offers to undo right now "
                + "— the cards and the Organize menu carry the one that is."
            return outcome
        }

        let fm = fileManager
        let actions = record.inverse.actions
        let execution: RestructureExecution = await enqueueFileOperation {
            FileSyncManager.executeRestructureActions(actions, root: expandedRoot, fm: fm,
                                                      vetoUnlistedSourceFolders: false,
                                                      restoringMissingParents: true,
                                                      refusingReplacedItems: true)
        }
        outcome.renamed = execution.renamed
        outcome.filesMoved = execution.filesMoved
        outcome.foldersMovedWhole = execution.foldersMovedWhole
        outcome.created = execution.created
        outcome.collisions = execution.collisions
        outcome.removedEmpty = execution.removedEmpty
        outcome.skipped = execution.skipped
        outcome.changedSince = execution.changedSince
        for item in execution.changedSince {
            Logger.shared.info("Restructure undo \(manifestId): \(item) had changed since the "
                + "landing — moved back")
        }
        // Off the main actor and through the serial queue, as in the apply's verify: no hang on
        // a big landing, and still after the moves and before anything else.
        let performed = execution.performed
        outcome.verifierMismatches = await enqueueFileOperation {
            FileSyncManager.verifyRestructureLanding(performed, root: expandedRoot, fm: fm)
        }
        for sentence in execution.skipped {
            Logger.shared.info("Restructure undo \(manifestId) skipped: \(sentence)")
        }
        for mismatch in outcome.verifierMismatches {
            Logger.shared.warning("Restructure undo \(manifestId) verifier: \(mismatch)")
        }

        // An undo that did nothing (every step skipped as drift) must not mark the record undone
        // or re-point: the kept profile would describe a tree that doesn't exist, and the record
        // couldn't be retried. Counted over operational actions; `keep` does nothing either way.
        let inverseIsOperational = record.inverse.actions.contains { $0.action != .keep }
        let anythingMovedBack = execution.performed.contains { $0.action != .keep }
        if inverseIsOperational && !anythingMovedBack {
            outcome.refusal = "Nothing could be moved back — every step of the stored inverse "
                + "found the tree already changed (each is named in the log). The record stays "
                + "applied; resolve the drift and try again."
            Logger.shared.warning("Restructure undo \(manifestId): refused — the whole inverse "
                + "skipped as drift; record left applied")
            return outcome
        }

        // The session ⌘Z stack describes the tree as the landing left it. Now that the inverse has
        // reshaped it, every group, the landing's redo above all, would replay against the wrong
        // tree (⌘⇧Z would re-apply renames the ledger records as undone). So clear it.
        if let undo = undoManager, undo.canUndo || undo.canRedo {
            undo.removeAllActions()
            Logger.shared.info("Restructure undo \(manifestId): session ⌘Z stack cleared — it "
                + "described the pre-undo tree")
        }

        // The active-profile guard, re-checked after the await: the inverse can run for minutes,
        // and a Setup walk finishing meanwhile activates a new profile, which an unconditional
        // re-point would silently deactivate. The undo-side twin of `writeDerivedProfile`'s
        // raced-switch refusal, which `repointActiveProfile` lacks.
        guard (record.producedProfileId ?? previousId) == (filingProfileDirectoryId ?? "") else {
            outcome.surveyRefreshFailure = "The files were moved back, but the active profile "
                + "changed while the inverse ran — the survey was left where it now points "
                + "rather than re-pointed over it. The record stays applied."
            Logger.shared.warning("Restructure undo \(manifestId): "
                + outcome.surveyRefreshFailure!)
            return outcome
        }

        // The folder the landing left the survey in, read before the re-point moves it.
        let leavingId = filingProfileDirectoryId ?? previousId
        // Re-point back and reload from the kept directory, whose profile describes the restored
        // tree, so the undo doesn't re-derive.
        do {
            try FilingProfileStore.repointActiveProfile(to: previousId, in: profilesDirectory,
                                                        now: now)
        } catch {
            outcome.surveyRefreshFailure = "The inverse ran, but profiles.json could not be "
                + "re-pointed to \(previousId): \(String(describing: error))"
            Logger.shared.warning("Restructure undo \(manifestId): \(outcome.surveyRefreshFailure!)")
            return outcome
        }
        let undoneStamp = FilingProfileStore.stamp(now)
        let undoSummary = outcome.summary
        // Marked in the current store first (which carried the record here), then in the restored
        // directory's own copy once it is re-opened below.
        store.updateApplied(manifestId: manifestId) {
            $0.undoneAt = undoneStamp
            $0.undoSummary = undoSummary
        }
        // What the user made since the landing comes back with the survey.
        var undoLanded = record.inverse
        undoLanded.actions = execution.performed
        let ledgerCarried = leavingId != previousId
            && carryCuratedEditsBack(from: leavingId, to: previousId, in: profilesDirectory)

        if let loaded = FilingProfileStore.active(in: profilesDirectory) {
            // The leaving folder's survey date isn't the restored one's: cleared before the id
            // moves, as `FilingArtifacts.attach` does, not left standing during the read below.
            if filingProfileDirectoryId != loaded.id { filingSurveyedAt = nil }
            filingFolderProfile = loaded.profile
            filingMemory = loaded.memory
            filingProfileDirectoryId = loaded.id
            let restoredStore = RestructureStore(directory: profilesDirectory,
                                                 profileId: loaded.id)
            // The carried ledger's suppressions, answers and drafts are keyed by the landed
            // tree's paths, so they go back through the renames the undo performed: the
            // landing's rekey, run the other way.
            if ledgerCarried, loaded.id == previousId {
                restoredStore.rekey(renames: RestructureRederive.renameMap(of: undoLanded),
                                    context: "undo of \(manifestId)")
            }
            restoredStore.updateApplied(manifestId: manifestId) {
                $0.undoneAt = undoneStamp
                $0.undoSummary = undoSummary
            }
            restructureStore = restoredStore
            filingPeopleStore = PeopleStore(directory: profilesDirectory, profileId: loaded.id,
                                            profile: loaded.profile)
            filingPersonTagStore = PersonTagStore(directory: profilesDirectory,
                                                  profileId: loaded.id)
            filingArtifactFingerprint = FilingProfileStore.fingerprint(id: loaded.id,
                                                                      in: profilesDirectory)
            // Off the main actor: the stamp read parses the whole corpus, about 5 MB.
            let restoredId = loaded.id
            let restoredDate = await Task.detached(priority: .userInitiated) {
                FilingSurveyStore.surveyedAt(id: restoredId, in: profilesDirectory)
            }.value
            if filingProfileDirectoryId == restoredId { filingSurveyedAt = restoredDate }
            // A folder its own re-derive left without a survey gets it back, off this actor.
            await finishInterruptedSurveyReplay()
        }
        outcome.producedProfileId = previousId
        Logger.shared.info("Restructure undo \(manifestId): \(outcome.summary); verifier "
            + (outcome.verifierMismatches.isEmpty ? "OK"
               : "MISMATCH (\(outcome.verifierMismatches.count))")
            + "; profile re-pointed to \(previousId)")
        return outcome
    }

    /// Carries the user's edits made since a landing back onto the folder its Undo re-points to,
    /// and answers whether `restructure.json` was among them, so the caller can rekey it.
    ///
    /// The old folder holds the copies the landing started from; the produced folder's copies
    /// took every edit since (a person added, a verdict, a suppression, a draft, a scaffold), so
    /// they are written over the old ones wherever the bytes differ. The produced folder keeps
    /// its own; the ledger pins it, and nothing is removed.
    ///
    /// `restructure.json` comes too, and that is the right ledger: it holds this landing's record
    /// (already marked undone) and every later one. Person verdicts are carried as they stand,
    /// never rekeyed. Best-effort per file; a failure is logged and leaves the old copy.
    func carryCuratedEditsBack(from producedId: String, to previousId: String,
                               in directory: URL) -> Bool {
        var ledgerCarried = false
        for name in FilingProfileStore.curatedArtifactNames {
            let source = directory.appendingPathComponent("\(producedId)/\(name)")
            let target = directory.appendingPathComponent("\(previousId)/\(name)")
            guard let bytes = try? Data(contentsOf: source) else { continue }
            if let existing = try? Data(contentsOf: target), existing == bytes { continue }
            do {
                try bytes.write(to: target, options: .atomic)
                if name == "restructure.json" { ledgerCarried = true }
                Logger.shared.info("Restructure undo: \(name) carried back from \(producedId) to "
                    + "\(previousId) — it held edits made since the landing")
            } catch {
                Logger.shared.warning("Restructure undo: could not carry \(name) back to "
                    + "\(previousId): \(error.localizedDescription) — the edits made since the "
                    + "landing are still in \(producedId)")
            }
        }
        // A plan exported after the landing goes back too, beside the survey, as the sheet said.
        // One already there by name is the same day's export, which `exportPlan` replaces anyway.
        FileSyncManager.carryProfileArtifacts(from: producedId, to: previousId, in: directory,
                                              fm: fileManager, names: [])
        return ledgerCarried
    }

    // MARK: - The renames' own ⌘Z pair

    /// Undo for the folder renames, on `registerCreateFolderUndo`'s pattern: existence re-probes
    /// at the moment of the action, no identity snapshot (the registration site says why). Items
    /// unwind in reverse, the only order that reverses a vacate-before-fill chain.
    func registerRestructureRenameUndo(items: [(from: URL, to: URL)], actionName: String,
                                       fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            guard !target.undoReplayBlockedByLanding(actionName) else { return }
            Logger.shared.info("User triggered Undo: \(actionName)")
            let logger = Logger.shared
            target.registerRestructureRenameRedo(items: items, actionName: actionName,
                                                 fileManager: fm)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) {
                for item in items.reversed() {
                    guard fm.fileExists(atPath: item.to.path) else {
                        logger.info("Undo (\(actionName)): \(item.to.lastPathComponent) is no "
                            + "longer there — nothing to rename back")
                        continue
                    }
                    // Case-only renames pass only on a case-insensitive volume, which answers the
                    // probe for both spellings. On a case-sensitive one a standing `item.from` is
                    // a real occupant, and `safeMoveItem` would replace it wholesale.
                    let caseOnly = item.from.path.lowercased() == item.to.path.lowercased()
                        && !FileSyncManager.volumeSupportsCaseSensitiveNames(for: item.to)
                    guard caseOnly || !fm.fileExists(atPath: item.from.path) else {
                        logger.warning("Undo (\(actionName)): \(item.from.lastPathComponent) is "
                            + "occupied — the rename back was refused rather than merged")
                        continue
                    }
                    do {
                        try FileSyncManager.safeMoveItem(at: item.to, to: item.from,
                                                         fileManager: fm)
                    } catch {
                        logger.warning("Undo (\(actionName)): could not rename "
                            + "\(item.to.lastPathComponent) back: \(error.localizedDescription)")
                    }
                }
            } }
        }
        undoManager?.setActionName(actionName)
    }

    func registerRestructureRenameRedo(items: [(from: URL, to: URL)], actionName: String,
                                       fileManager fm: FileManaging = FileManager.default) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            guard !target.undoReplayBlockedByLanding(actionName) else { return }
            Logger.shared.info("User triggered Redo: \(actionName)")
            let logger = Logger.shared
            target.registerRestructureRenameUndo(items: items, actionName: actionName,
                                                 fileManager: fm)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) {
                for item in items {
                    guard fm.fileExists(atPath: item.from.path) else {
                        logger.info("Redo (\(actionName)): \(item.from.lastPathComponent) is no "
                            + "longer there — nothing to rename")
                        continue
                    }
                    let caseOnly = item.from.path.lowercased() == item.to.path.lowercased()
                        && !FileSyncManager.volumeSupportsCaseSensitiveNames(for: item.from)
                    guard caseOnly || !fm.fileExists(atPath: item.to.path) else {
                        logger.warning("Redo (\(actionName)): \(item.to.lastPathComponent) is "
                            + "occupied — the rename was refused rather than merged")
                        continue
                    }
                    do {
                        try FileSyncManager.safeMoveItem(at: item.from, to: item.to,
                                                         fileManager: fm)
                    } catch {
                        logger.warning("Redo (\(actionName)): could not rename "
                            + "\(item.from.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - The disk runner

    /// What the executor hands back: counters, the actions as they actually ran, and the raw
    /// material for ⌘Z.
    struct RestructureExecution: Sendable {
        var renamed = 0
        var filesMoved = 0
        var foldersMovedWhole = 0
        var created = 0
        var collisions = 0
        var removedEmpty = 0
        var skipped: [String] = []
        /// An undo's items that weren't as the landing left them (edited, or saved over) and were
        /// moved back anyway (see `landedIdentity`). Named, never silent.
        var changedSince: [String] = []
        /// The actions that ran, with `collidedInto` and `bytes` filled from the disk.
        var performed: [RestructureManifest.Action] = []
        /// Directory renames, registered for ⌘Z as their own batch before the content moves, so
        /// undo pops the moves first: a file must leave `Forms/` before `Forms/` is renamed.
        var renameItems: [(from: URL, to: URL)] = []
        var moveItems: [(from: URL, to: URL, overwritten: URL?)] = []
        var createdURLs: [URL] = []
    }

    /// How many files sit anywhere beneath `path`; empty folders and OS noise don't count. The
    /// removal step's "still empty": a drained folder holding only drained folders goes to the
    /// Trash whole, so ``RestructureLedger/emptiedFolders(of:)`` can stay shallowest-only.
    ///
    /// nil when the walk couldn't see everything: an unopenable folder is unknown, never empty,
    /// or the removal step would trash contents it never saw. Callers treat nil as "not empty".
    nonisolated public static func visibleFileCount(atPath path: String,
                                                    fm: FileManaging) -> Int? {
        // Not `.skipsHiddenFiles`: it prunes hidden folders whole, so `Old/.git/…` would read
        // "still empty" over a full repository. Hidden contents are content.
        //
        // Only OS noise is ignorable, not every dotted name. `.env`, `.gitignore` or an
        // office lock file is real content; counted as empty, the folder would be trashed and its
        // `create-dir` inverse would bring it back without them. The skipped names are
        // `ItemIdentity.deepIdentityIgnoredNames`, as New Folder's undo uses; a directory among
        // them (`.Trashes`) is skipped whole.
        //
        // A folder whose contents aren't on this Mac is asked for first, bounded. This runs in
        // the file queue, and the enumerator would hang forever on a cloud-only folder whose app
        // has stopped, wedging everything queued behind it. The root and every folder met are
        // asked through `DatalessFolderReads` before the walk reads them (the enumerator descends
        // on the next call); one that doesn't answer makes the count nil, so the folder is kept.
        guard fm.waitForContentsBlocking(of: URL(fileURLWithPath: path)) else { return nil }
        var sawError = false
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [],
                                         errorHandler: { _, _ in sawError = true; return false })
        else { return nil }
        var files = 0
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if ItemIdentity.deepIdentityIgnoredNames.contains(url.lastPathComponent) {
                if isDir { walker.skipDescendants() }
                continue
            }
            // `hasDirectoryPath` too: the enumerator's own word, since a test disk's folders answer
            // no resource values.
            if isDir || url.hasDirectoryPath, !fm.waitForContentsBlocking(of: url) { return nil }
            if !isDir { files += 1 }
        }
        return sawError ? nil : files
    }

    /// One folder level's entry names: the listing the unlisted-file rule re-runs at the moment of
    /// the action. nil when the folder couldn't be listed.
    ///
    /// Through `listing(of:)`, not an enumerator: in the file queue an enumerator over a stopped
    /// cloud-only folder never returns, wedging everything behind it, while `listing(of:)` asks
    /// through `DatalessFolderReads`, bounded. It also tells "unreadable" from "empty", so the
    /// unlisted-file veto can't pass a folder it never saw.
    nonisolated static func directoryNames(at path: String, fm: FileManaging) -> [String]? {
        let listed = fm.listing(of: URL(fileURLWithPath: path))
        guard listed.isComplete else { return nil }
        return listed.urls.map(\.lastPathComponent)
    }

    /// Runs the actions in order against the real tree, re-probing every `src` and `dst` right
    /// before each one. A folder holding a file the manifest never listed is skipped whole and
    /// reported, and the rest runs; a taken destination gets a unique name and a collision fact,
    /// never an overwrite.
    nonisolated static func executeRestructureActions(
        _ actions: [RestructureManifest.Action], root: String, fm: FileManaging,
        vetoUnlistedSourceFolders: Bool = true,
        restoringMissingParents: Bool = false,
        refusingReplacedItems: Bool = false,
        journal: RestructureLandingJournal? = nil,
        onProgress: (@Sendable (Int) -> Void)? = nil)
        -> RestructureExecution {
        var out = RestructureExecution()
        // The denominator the sheet renders against: operations, not signature `keep` rows.
        let total = actions.count { $0.action != .keep }
        // `ProgressPublishGate`, not a clock: a percent gate caps a run of any length at ~101
        // publishes and needs no clock seam to test. `onProgress` is nil for callers not watching.
        var gate = ProgressPublishGate()
        var completed = 0
        var lastPublished = -1
        func report(force: Bool = false) {
            guard let onProgress else { return }
            // The gate already lets the final report through; don't publish it twice.
            guard completed != lastPublished else { return }
            guard force || gate.admits(completed: completed, total: total) else { return }
            lastPublished = completed
            onProgress(completed)
        }
        func absolute(_ relative: String) -> String {
            (root as NSString).appendingPathComponent(relative)
        }
        // The unlisted-file rule, resolved once per source folder when its first move runs: the
        // planned set is what the manifest lists out of it, and anything else on disk is a file
        // the plan never read, so moving around it would be guessing.
        var plannedOut: [String: Set<String>] = [:]
        for action in actions
        where action.action == .moveFile || action.action == .moveDir || action.action == .keep {
            guard let src = action.src else { continue }
            // The item is listed at its parent, and so is every ancestor at its parent: a
            // subfolder whose contents the plan moves or keeps is accounted for. Otherwise a
            // same-name-subfolder merge (`Payment/` into `Payments/`, both holding `Receipts/`)
            // would veto its own parent, since only `Receipts`' files are move sources.
            var name = (src as NSString).lastPathComponent
            var parent = (src as NSString).deletingLastPathComponent
            while !name.isEmpty {
                plannedOut[parent, default: []].insert(name)
                guard !parent.isEmpty else { break }
                name = (parent as NSString).lastPathComponent
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var vetoedSources: Set<String> = []
        var checkedSources: Set<String> = []
        func sourceFolderVeto(_ parent: String) -> Bool {
            // The inverse runs with the veto off: its source folders hold files a rename carried,
            // which the actions never name. The per-file re-probes still skip and report a file
            // that moved on, and nothing is overwritten.
            guard vetoUnlistedSourceFolders else { return false }
            if vetoedSources.contains(parent) { return true }
            guard !checkedSources.contains(parent) else { return false }
            checkedSources.insert(parent)
            // A folder that exists but can't be listed (its cloud app didn't answer, or it is
            // locked) is skipped whole: nothing can vouch it holds nothing unlisted. One that is
            // gone is left to the per-action probes, which say so.
            guard let listed = FileSyncManager.directoryNames(at: absolute(parent), fm: fm) else {
                guard fm.fileExists(atPath: absolute(parent)) else { return false }
                vetoedSources.insert(parent)
                out.skipped.append("\(parent)/ could not be read — left untouched; a folder "
                    + "whose contents the plan cannot see is never moved out of")
                return true
            }
            // Only OS noise is ignorable, not every dotted name, as in `visibleFileCount`: a merge
            // must not drain a folder around a `.env` and split it from its files.
            let unlisted = listed.filter { !ItemIdentity.deepIdentityIgnoredNames.contains($0) }
                .filter { !(plannedOut[parent] ?? []).contains($0) }
            guard !unlisted.isEmpty else { return false }
            vetoedSources.insert(parent)
            out.skipped.append("\(parent)/ holds \(unlisted.count) item(s) the plan never "
                + "listed (\(unlisted.sorted().prefix(3).joined(separator: ", "))"
                + (unlisted.count > 3 ? ", …" : "") + ") — left untouched")
            return true
        }
        // The subtree half of "skipped whole": once a folder is vetoed, nothing moves out of any
        // folder beneath it, and nothing lands in it or beneath it, or the skip sentence's
        // "left untouched" would be false.
        func vetoedAncestor(of path: String) -> String? {
            vetoedSources.first { path == $0 || path.hasPrefix($0 + "/") }
        }
        // A rename refused as drift refuses the merges headed into it too. Later actions name
        // the folder the rename would have made (`Form W2 → Form W-2`, then `Form-W2/*` into
        // `Form W-2/`); if another `Form W-2/` synced in first, it is someone else's, so nothing
        // moves into or out of it or is created beneath it. Kept apart from `vetoedSources`,
        // whose sentence is about a different refusal.
        var refusedRenameDestinations: Set<String> = []
        func refusedRename(covering path: String) -> String? {
            refusedRenameDestinations.first { path == $0 || path.hasPrefix($0 + "/") }
        }
        func refusedRenameSentence(_ item: String, _ covering: String) -> String {
            "\(item) was planned against \(covering)/ as the rename would have made it, and that "
                + "rename was refused — left where it stands"
        }
        // An undo puts an item back in the folder it came from, even if that folder is gone.
        // A merge empties its source folder, which a person may tidy away; without it the
        // move-back fails while the rename-back succeeds, carrying merged files into a folder they
        // never lived in. The parent is recorded in the action, so recreating it restores the
        // tree. Stopping as drift would leave a half-undone tree nothing can finish. Only the
        // inverse does this; in a forward plan a missing destination is drift.
        //
        // An undo moves back the item the landing moved, not whatever now has its name. But
        // an edit and a same-name swap look alike: most apps save by swapping in a new file (new
        // file number, old creation date), as does a Save dialog's Replace. So only an item that
        // is clearly new (a different file number and a creation date more than a second away)
        // is left where it stands. Anything else changed (number, creation date or a file's size)
        // goes back and is named on the card. A record with only the size never refuses on it.
        enum LandedIdentity { case same, changed, different }
        func landedIdentity(_ action: RestructureManifest.Action, at path: String) -> LandedIdentity {
            guard refusingReplacedItems,
                  let attributes = try? fm.attributesOfItem(atPath: path) else { return .same }
            let sizeChanged = action.action == .moveFile
                && action.bytes.map { $0 != attributes[.size] as? Int } == true
            let number = FileSyncManager.restructureFileNumber(in: attributes)
            let numberDiffers = action.fileNumber != nil && number != nil && number != action.fileNumber
            let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970
            let createdDiffers = action.created.flatMap { recorded in
                created.map { abs($0 - recorded) > 1 } } ?? false
            if numberDiffers && createdDiffers { return .different }
            if numberDiffers || createdDiffers || sizeChanged { return .changed }
            return .same
        }
        func differentSentence(_ item: String) -> String {
            "\(item) is a different item from the one the landing put there — it was left where "
                + "it stands"
        }
        func restoreParent(of relative: String) {
            guard restoringMissingParents else { return }
            let parent = (absolute(relative) as NSString).deletingLastPathComponent
            guard !fm.fileExists(atPath: parent) else { return }
            do {
                try fm.createDirectory(at: URL(fileURLWithPath: parent),
                                       withIntermediateDirectories: true, attributes: nil)
                Logger.shared.info("Restructure undo: \((relative as NSString).deletingLastPathComponent)/ "
                    + "was gone, so it was recreated to take \((relative as NSString).lastPathComponent) back")
            } catch {
                // The move below then fails and says so; nothing is moved anywhere else.
                Logger.shared.warning("Restructure undo: could not recreate the folder "
                    + "\(relative) came from: \(error.localizedDescription)")
            }
        }

        for action in actions {
            let performedBefore = out.performed.count
            // Counted per action attempted, skips included: the sheet shows how far through the
            // list the landing is, not how much succeeded.
            defer {
                // What ran is on disk the moment it has run (`RestructureLandingJournal`).
                if let journal, out.performed.count > performedBefore {
                    for done in out.performed[performedBefore...] { journal.record(done) }
                }
                if action.action != .keep {
                    completed += 1
                    report()
                }
            }
            switch action.action {
            case .keep:
                out.performed.append(action)

            case .createDir:
                guard let dst = action.dst else { continue }
                if let covering = refusedRename(covering: dst) {
                    out.skipped.append(refusedRenameSentence("\(dst)/", covering))
                    continue
                }
                let path = absolute(dst)
                if fm.fileExists(atPath: path) {
                    out.skipped.append("\(dst)/ already exists — left as it stands")
                    continue
                }
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: path),
                                           withIntermediateDirectories: false, attributes: nil)
                    out.created += 1
                    out.createdURLs.append(URL(fileURLWithPath: path))
                    out.performed.append(action)
                } catch {
                    out.skipped.append("\(dst)/ could not be created: \(error.localizedDescription)")
                }

            case .renameDir:
                guard let src = action.src, let dst = action.dst else { continue }
                if let covering = refusedRename(covering: src) ?? refusedRename(covering: dst) {
                    out.skipped.append(refusedRenameSentence("\(src)/", covering))
                    continue
                }
                let srcPath = absolute(src), dstPath = absolute(dst)
                guard fm.fileExists(atPath: srcPath) else {
                    out.skipped.append("\(src)/ is no longer there — its rename was skipped")
                    continue
                }
                let identity = landedIdentity(action, at: srcPath)
                guard identity != .different else {
                    out.skipped.append(differentSentence("\(src)/"))
                    continue
                }
                // A taken destination would make the rename an unreviewed merge, so it is
                // skipped, unless it is a case-only rename (`safeMoveItem` does the two-step) on
                // a case-insensitive volume. On a case-sensitive one that `dst` is a real occupant.
                if fm.fileExists(atPath: dstPath),
                   src.lowercased() != dst.lowercased()
                    || FileSyncManager.volumeSupportsCaseSensitiveNames(
                        for: URL(fileURLWithPath: srcPath)) {
                    out.skipped.append("\(dst)/ appeared since the plan — the rename of "
                        + "\(src)/ was skipped rather than merged unreviewed")
                    refusedRenameDestinations.insert(dst)
                    continue
                }
                var performed = action
                FileSyncManager.recordIdentity(of: srcPath, into: &performed, fm: fm)
                do {
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: URL(fileURLWithPath: dstPath),
                                                    fileManager: fm)
                    out.renamed += 1
                    if identity == .changed { out.changedSince.append("\(src)/") }
                    out.renameItems.append((from: URL(fileURLWithPath: srcPath),
                                            to: URL(fileURLWithPath: dstPath)))
                    out.performed.append(performed)
                } catch {
                    out.skipped.append("\(src)/ could not be renamed: \(error.localizedDescription)")
                }

            case .moveFile:
                guard let src = action.src, let dst = action.dst else { continue }
                let parent = (src as NSString).deletingLastPathComponent
                if let covering = refusedRename(covering: parent)
                    ?? refusedRename(covering: (dst as NSString).deletingLastPathComponent) {
                    out.skipped.append(refusedRenameSentence(src, covering))
                    continue
                }
                if let covering = vetoedAncestor(of: parent) {
                    out.skipped.append("\(src) sits under \(covering)/ — left untouched with it")
                    continue
                }
                guard !sourceFolderVeto(parent) else { continue }
                if let covering = vetoedAncestor(of: (dst as NSString).deletingLastPathComponent) {
                    out.skipped.append("\(src) was headed into \(covering)/, which holds items "
                        + "the plan never listed — left where it stands")
                    continue
                }
                let srcPath = absolute(src)
                guard fm.fileExists(atPath: srcPath) else {
                    out.skipped.append("\(src) was deleted between plan and apply — skipped")
                    continue
                }
                let identity = landedIdentity(action, at: srcPath)
                guard identity != .different else {
                    out.skipped.append(differentSentence(src))
                    continue
                }
                restoreParent(of: dst)
                var destination = URL(fileURLWithPath: absolute(dst))
                var performed = action
                if fm.fileExists(atPath: destination.path) {
                    // Keep both, never overwrite, and count it.
                    destination = FileSyncManager.generateUniqueURL(for: destination,
                                                                   fileManager: fm)
                    let relative = String(destination.path.dropFirst(root.count + 1))
                    performed.collidedInto = relative
                    out.collisions += 1
                }
                do {
                    // The size is read from disk now, before the move, while the source path is
                    // still the manifest's. The window since the probe is bounded: a file that
                    // appears at the destination meanwhile is replaced by `safeMoveItem`, which
                    // trashes the old copy and logs, so it is recoverable.
                    //
                    // No digest: a same-volume move is a rename, and hashing would read every
                    // file while the landing blocks all else. `md5` stays on
                    // `RestructureManifest.Action` so old ledgers decode; `bytes` is the audit
                    // fact, from the `attributesOfItem` call already made.
                    let attributes = try? fm.attributesOfItem(atPath: srcPath)
                    performed.bytes = attributes?[.size] as? Int
                    FileSyncManager.recordIdentity(from: attributes, into: &performed)
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: destination, fileManager: fm)
                    out.filesMoved += 1
                    if identity == .changed { out.changedSince.append(src) }
                    out.moveItems.append((from: URL(fileURLWithPath: srcPath),
                                          to: destination, overwritten: nil))
                    out.performed.append(performed)
                } catch {
                    out.skipped.append("\(src) could not be moved: \(error.localizedDescription)")
                }

            case .moveDir:
                guard let src = action.src, let dst = action.dst else { continue }
                let parent = (src as NSString).deletingLastPathComponent
                if let covering = refusedRename(covering: src)
                    ?? refusedRename(covering: (dst as NSString).deletingLastPathComponent) {
                    out.skipped.append(refusedRenameSentence("\(src)/", covering))
                    continue
                }
                // A vetoed folder is left alone whole, relocations included: carrying a child
                // away would drain it by another name.
                if let covering = vetoedAncestor(of: parent) {
                    out.skipped.append("\(src)/ sits under \(covering)/ — left untouched with it")
                    continue
                }
                // But a relocation doesn't drain its source's parent, so the unlisted-file rule
                // has nothing to protect; applied, it would veto every loose-folder plan, whose
                // sibling container reads as unlisted. Skip the call itself: `sourceFolderVeto`
                // records the folder, which would veto it for every later action.
                if action.movesWholeFolder != true, sourceFolderVeto(parent) { continue }
                if let covering = vetoedAncestor(of: (dst as NSString).deletingLastPathComponent) {
                    out.skipped.append("\(src)/ was headed into \(covering)/, which holds items "
                        + "the plan never listed — left where it stands")
                    continue
                }
                let srcPath = absolute(src), dstPath = absolute(dst)
                guard fm.fileExists(atPath: srcPath) else {
                    out.skipped.append("\(src)/ is no longer there — skipped")
                    continue
                }
                let identity = landedIdentity(action, at: srcPath)
                guard identity != .different else {
                    out.skipped.append(differentSentence("\(src)/"))
                    continue
                }
                guard !fm.fileExists(atPath: dstPath) else {
                    out.skipped.append("\(dst)/ appeared since the plan — \(src)/ was kept "
                        + "rather than merged unreviewed")
                    continue
                }
                restoreParent(of: dst)
                var performed = action
                FileSyncManager.recordIdentity(of: srcPath, into: &performed, fm: fm)
                do {
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: URL(fileURLWithPath: dstPath),
                                                    fileManager: fm)
                    out.foldersMovedWhole += 1
                    if identity == .changed { out.changedSince.append("\(src)/") }
                    out.moveItems.append((from: URL(fileURLWithPath: srcPath),
                                          to: URL(fileURLWithPath: dstPath), overwritten: nil))
                    out.performed.append(performed)
                } catch {
                    out.skipped.append("\(src)/ could not be moved: \(error.localizedDescription)")
                }

            case .removeEmptyDir:
                guard let src = action.src else { continue }
                let path = absolute(src)
                guard fm.fileExists(atPath: path) else {
                    out.skipped.append("\(src)/ is already gone")
                    continue
                }
                guard let files = FileSyncManager.visibleFileCount(atPath: path, fm: fm) else {
                    out.skipped.append("\(src)/ could not be fully read — kept; a folder "
                        + "whose contents the walk cannot see is never treated as empty")
                    continue
                }
                guard files == 0 else {
                    out.skipped.append("\(src)/ still holds \(files) file(s) — "
                        + "kept; no file is ever deleted")
                    continue
                }
                do {
                    // To the Trash, never a hard delete, here and for an inverse's `create-dir`.
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    out.removedEmpty += 1
                    out.performed.append(action)
                } catch {
                    out.skipped.append("\(src)/ could not be removed: \(error.localizedDescription)")
                }
            }
        }
        // The gate may have held the last count back; the final one must be published.
        report(force: true)
        return out
    }

    /// A `.systemFileNumber` as the ledger stores it. Test doubles hand back a bare integer
    /// where a real file manager hands back an `NSNumber`.
    nonisolated static func restructureFileNumber(in attributes: [FileAttributeKey: Any]) -> Int? {
        switch attributes[.systemFileNumber] {
        case let number as NSNumber: return number.intValue
        case let number as UInt64: return Int(truncatingIfNeeded: number)
        case let number as Int: return number
        default: return nil
        }
    }

    /// The facts the undo tells the landed item by: its file number and its creation date.
    nonisolated static func recordIdentity(from attributes: [FileAttributeKey: Any]?,
                                           into action: inout RestructureManifest.Action) {
        guard let attributes else { return }
        action.fileNumber = restructureFileNumber(in: attributes)
        action.created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970
    }

    nonisolated static func recordIdentity(of path: String,
                                           into action: inout RestructureManifest.Action,
                                           fm: FileManaging) {
        recordIdentity(from: try? fm.attributesOfItem(atPath: path), into: &action)
    }

    /// The verifier's disagreement in one line, for the Applied card: the first and a count. The
    /// log keeps every mismatch.
    nonisolated static func verifierNote(_ mismatches: [String]) -> String? {
        guard let first = mismatches.first else { return nil }
        guard mismatches.count > 1 else { return first }
        return "\(first) (and \(mismatches.count - 1) more; each one is in the log)"
    }

    /// The independent verifier: re-checks the touched paths against what the performed actions
    /// claim, sharing none of the mover's arithmetic.
    nonisolated static func verifyRestructureLanding(
        _ performed: [RestructureManifest.Action], root: String, fm: FileManaging) -> [String] {
        var mismatches: [String] = []
        func exists(_ relative: String?) -> Bool {
            guard let relative else { return false }
            return fm.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
        }
        for action in performed {
            switch action.action {
            case .renameDir, .moveDir:
                // A case-only rename's source "exists" on a case-insensitive volume, because the
                // destination answers for both spellings, so asking would flag every one.
                let caseOnly = action.src?.lowercased() == action.dst?.lowercased()
                if !caseOnly, exists(action.src) {
                    mismatches.append("\(action.src ?? "?") still exists after its move")
                }
                if !exists(action.dst) {
                    mismatches.append("\(action.dst ?? "?") is missing after its move")
                }
            case .moveFile:
                let landed = action.collidedInto ?? action.dst
                if !exists(landed) {
                    mismatches.append("\(landed ?? "?") is missing after its move")
                }
                if exists(action.src) {
                    mismatches.append("\(action.src ?? "?") still exists after its move")
                }
            case .createDir:
                if !exists(action.dst) {
                    mismatches.append("\(action.dst ?? "?") was created and is not there")
                }
            case .removeEmptyDir:
                if exists(action.src) {
                    mismatches.append("\(action.src ?? "?") was removed and is still there")
                }
            case .keep:
                break
            }
        }
        return mismatches
    }

    // MARK: - Step 7's carriage

    /// Copies the per-profile artifacts the app reads into the new directory: the roster, the
    /// person verdicts, and everything Restructure remembers. Copied, never moved: the old
    /// directory is what Undo re-points to.
    ///
    /// Exported plans come too ("beside your survey", the sheet said), unless
    /// `carryingExportedPlans` is false: a walk of another folder, whose plans are about another
    /// tree.
    ///
    /// - Returns: the exported plans it copied, for a caller that must take them back out.
    @discardableResult
    nonisolated static func carryProfileArtifacts(
        from oldId: String, to newId: String, in directory: URL, fm: FileManaging,
        names: [String] = FilingProfileStore.curatedArtifactNames,
        carryingExportedPlans: Bool = true) -> [String] {
        let exported = carryingExportedPlans
            ? FilingProfileStore.exportedPlanNames(inProfile: oldId, in: directory,
                                                   fileManager: fm) ?? []
            : []
        var carriedExports: [String] = []
        for name in names + exported {
            let source = directory.appendingPathComponent("\(oldId)/\(name)")
            var target = directory.appendingPathComponent("\(newId)/\(name)")
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: target.path) {
                // An export of the same name isn't necessarily the same plan, and skipped by name
                // the old version would go when the sweep retires its folder. Identical bytes are
                // the same file; anything else is kept beside it.
                guard exported.contains(name),
                      let theirs = try? Data(contentsOf: source),
                      (try? Data(contentsOf: target)) != theirs else { continue }
                target = FileSyncManager.generateUniqueURL(for: target, fileManager: fm)
            }
            do {
                try fm.copyItem(at: source, to: target)
                if exported.contains(name) { carriedExports.append(target.lastPathComponent) }
            } catch {
                Logger.shared.warning("Restructure: could not carry \(name) to \(newId): "
                    + error.localizedDescription)
            }
        }
        if !carriedExports.isEmpty {
            Logger.shared.info("Restructure: carried \(carriedExports.count) exported plan(s) from "
                + "\(oldId) to \(newId) — \(carriedExports.joined(separator: ", "))")
        }
        return carriedExports
    }

    /// Keeps a stopped document survey's resume point across a re-derive. `survey-progress.json`
    /// lives in the profile's folder; left behind, the next survey would start from 0 and the
    /// retire sweep would delete hours of reading.
    ///
    /// Rekeyed, not copied: `read` is keyed by root-relative path, like the corpus, and the
    /// landing just moved those paths; the checkpoint also names its profile, and
    /// `adoptCheckpoint` refuses another's. So `read` goes through
    /// ``RestructureRederive/rekeyedCorpus(_:through:)``, and the plan's paths through the same
    /// moves. A moved file is unchanged, so its reading holds. The resume index survives only if
    /// the plan kept its length; otherwise it restarts at 0, skipping documents already read.
    ///
    /// A checkpoint that isn't this profile's resumable run (unreadable, or another profile's) is
    /// copied byte for byte: it must not become resumable, but stays where the card looks.
    /// Copied, never moved: the old folder is what an Undo re-points to.
    nonisolated static func carrySurveyProgress(from oldId: String, to newId: String,
                                                in directory: URL,
                                                through landed: RestructureManifest) {
        let target = DocumentSurveyCheckpointStore.url(id: newId, in: directory)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        switch DocumentSurveyCheckpointStore.read(id: oldId, in: directory) {
        case .absent:
            return
        case .loaded(let checkpoint) where checkpoint.profileId == oldId:
            let carried = RestructureRederive.rekeyedCheckpoint(checkpoint, through: landed,
                                                               profileId: newId)
            do {
                try DocumentSurveyCheckpointStore.write(carried, id: newId, in: directory)
                Logger.shared.info("Restructure: the unfinished survey's progress "
                    + "(\(carried.read.count) read, \(carried.progress.done) of "
                    + "\(carried.progress.total)) was carried to \(newId)")
            } catch {
                Logger.shared.warning("Restructure: could not carry the unfinished survey's "
                    + "progress to \(newId): \(error.localizedDescription) — the next survey "
                    + "starts over")
            }
        case .loaded, .unreadable:
            do {
                try FileManager.default.copyItem(
                    at: DocumentSurveyCheckpointStore.url(id: oldId, in: directory), to: target)
            } catch {
                Logger.shared.warning("Restructure: could not carry survey-progress.json to "
                    + "\(newId): \(error.localizedDescription)")
            }
        }
    }

    /// Finishes, off the main actor, the replay a cut-off re-derive left undone for the loaded
    /// profile, and publishes the memory it rebuilt. Separate from
    /// ``FilingProfileStore/active(in:)``, whose callers are on the main actor, so the window
    /// never waits on thousands of documents. Returns whether a survey was carried.
    @discardableResult
    public func finishInterruptedSurveyReplay() async -> Bool {
        guard let directory = filingProfilesDirectory, let id = filingProfileDirectoryId,
              let profile = filingFolderProfile else { return false }
        // Counted, not flagged: launch, Setup and Undo can each start one, and the first to
        // finish must not clear the guard while another is still carrying.
        surveyReplaysInFlight += 1
        defer { surveyReplaysInFlight -= 1 }
        let memory = await Task.detached(priority: .utility) { () -> FilingMemory?? in
            guard FileSyncManager.recoverInterruptedSurveyReplay(into: id, profile: profile,
                                                                 in: directory) else { return nil }
            return .some(FilingProfileStore.memory(id: id, in: directory))
        }.value
        // Published only onto the folder it was carried for: a walk or landing meanwhile moved on.
        guard let memory, filingProfileDirectoryId == id else { return false }
        // The stamp read parses the whole corpus; off the main actor, and published only if the
        // folder is still the one it was read for.
        let surveyedAt = await Task.detached(priority: .utility) {
            FilingSurveyStore.surveyedAt(id: id, in: directory)
        }.value
        guard filingProfileDirectoryId == id else { return false }
        filingMemory = memory
        filingSurveyedAt = surveyedAt
        filingArtifactFingerprint = FilingProfileStore.fingerprint(id: id, in: directory)
        return true
    }

    /// Reads back a survey a re-derive's replay never finished carrying. A re-derive names the
    /// new folder in `profiles.json` before its replay, so a quit then relaunches onto a folder
    /// with no corpus, memory or progress, while the folder it was derived from (kept by the
    /// retire sweep for this) still has them.
    ///
    /// When the active folder has no corpus, its `derivedFrom` folder's progress and corpus are
    /// carried in through the manifest between them (the ledger record applied under that
    /// folder, or none for a survey refresh), and the memory rebuilt. The sweep may then retire
    /// the old folder. The corpus keeps its own `surveyedAt`: nothing was read again.
    ///
    /// An unreadable ledger carries nothing: an unknown landing could have moved the files the
    /// keys name. Returns whether a corpus was carried.
    @discardableResult
    nonisolated static func recoverInterruptedSurveyReplay(into id: String,
                                                           profile: FolderProfile,
                                                           in directory: URL) -> Bool {
        // A stat, not a read: this runs on every load, and the active folder's corpus is
        // normally there and thousands of documents long. Present but unreadable is not absent.
        let here = FilingSurveyStore.corpusURL(id: id, in: directory).path
        guard let parent = profile.derivedFrom, parent != id,
              (try? FileManager.default.attributesOfItem(atPath: here)) == nil else { return false }
        // Stats too: the parent's corpus is decoded once, by the carry, only when it runs. And
        // nothing is read when there is nothing to carry: a parent with no corpus has only its
        // progress to give, and a folder with progress of its own takes none.
        let parentHasCorpus = (try? FileManager.default.attributesOfItem(
            atPath: FilingSurveyStore.corpusURL(id: parent, in: directory).path)) != nil
        let parentProgress = DocumentSurveyCheckpointStore.url(id: parent, in: directory)
        let hereProgress = DocumentSurveyCheckpointStore.url(id: id, in: directory)
        guard parentHasCorpus
            || (FileManager.default.fileExists(atPath: parentProgress.path)
                && (try? FileManager.default.attributesOfItem(atPath: hereProgress.path)) == nil)
        else { return false }

        struct Ledger: Decodable { let applied: [RestructureStore.AppliedRecord]? }
        let ledgerURL = directory.appendingPathComponent("\(id)/restructure.json")
        var landed = RestructureManifest(profileId: parent, manifestId: "survey-refresh",
                                         createdAt: FilingProfileStore.stamp(Date()),
                                         family: ".", kind: .deadWeight, actions: [])
        if (try? FileManager.default.attributesOfItem(atPath: ledgerURL.path)) != nil {
            guard let data = try? Data(contentsOf: ledgerURL),
                  let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
                Logger.shared.warning("Filing profiles: \(id) has no survey and \(parent) does, but "
                    + "\(id)/restructure.json could not be read, so what moved between them is "
                    + "unknown — the survey was not carried")
                return false
            }
            // Only a landing that finished, preferring the one that made this folder. A record
            // without a `summary` never finalised, and rekeying through it would move keys
            // through moves that may never have happened.
            let finished = (ledger.applied ?? []).filter {
                $0.appliedUnderProfileId == parent && $0.undoneAt == nil && $0.summary != nil
            }
            if let record = finished.last(where: { $0.producedProfileId == id }) ?? finished.last {
                landed = record.manifest
            }
        }

        guard carrySurveyArtifacts(from: parent, to: id, through: landed, root: profile.root,
                                   in: directory) else { return false }
        Logger.shared.info("Filing profiles: carried \(parent)'s survey into \(id) — the "
            + "re-derive that made \(id) stopped before its replay"
            + (landed.actions.isEmpty ? "" : ", rekeyed through \(landed.manifestId)"))
        return true
    }

    /// Carries `parent`'s survey into `id`: a stopped survey's progress, and the corpus, rekeyed
    /// through `landed` and renamed to `id`, with the memory rebuilt keeping `parent`'s folder
    /// stamps under their new names (a stamp that no longer matches reads as stale, the safe
    /// side). The corpus keeps its `surveyedAt`. Does nothing where `id` already has a corpus.
    /// Returns whether a corpus was carried.
    ///
    /// Used by the re-derive's read-back, and by a Setup walk of a folder whose survey is on disk
    /// (with no moves, since its paths are unchanged).
    @discardableResult
    nonisolated static func carrySurveyArtifacts(from parent: String, to id: String,
                                                 through landed: RestructureManifest,
                                                 root: String, in directory: URL) -> Bool {
        let here = FilingSurveyStore.corpusURL(id: id, in: directory).path
        carrySurveyProgress(from: parent, to: id, in: directory, through: landed)
        guard (try? FileManager.default.attributesOfItem(atPath: here)) == nil,
              let parentCorpus = FilingSurveyStore.corpus(id: parent, in: directory) else {
            return false
        }
        let rekeyed = RestructureRederive.rekeyedCorpus(parentCorpus, through: landed)
        let corpus = FilingCorpus(profileId: id, salt: rekeyed.salt, documents: rekeyed.documents,
                                  surveyedAt: rekeyed.surveyedAt)
        let renames = RestructureRederive.renameMap(of: landed)
        var folderModified: [String: Int] = [:]
        for (folder, entry) in FilingProfileStore.memory(id: parent, in: directory)?.folders ?? [:] {
            if let stamp = entry.folderModified {
                folderModified[RestructureRederive.mapped(folder, through: renames)] = stamp
            }
        }
        let memory = FilingSurvey.buildMemory(corpus: corpus, folderModified: folderModified,
                                              profileId: id)
        // Asked again just before the write: a survey that wrote one meanwhile is newer.
        guard (try? FileManager.default.attributesOfItem(atPath: here)) == nil else { return false }
        do {
            try FilingSurveyStore.write(corpus: corpus, memory: memory, previousMemory: nil, id: id,
                                        in: directory, root: root,
                                        now: corpus.surveyedAt ?? Date())
        } catch {
            Logger.shared.warning("Filing profiles: could not carry \(parent)'s survey into \(id): "
                + error.localizedDescription)
            return false
        }
        Logger.shared.info("Filing profiles: carried \(parent)'s survey "
            + "(\(corpus.documents.count) document(s)) into \(id)")
        return true
    }

    /// A fresh profile id for a re-derivation, `reorg-<stamp>`, suffixed when two land in the same
    /// second, as in `availableWalkProfileId`.
    nonisolated static func availableReorgProfileId(now: Date, in directory: URL) -> String {
        let base = "reorg-" + FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(
            atPath: FilingProfileStore.profileURL(id: candidate, in: directory).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}

/// What a landing has done so far, one line per action, written as each runs. The ledger record
/// is written before the first move and finalised after the last, so a quit or crash in between
/// leaves a half-applied tree Undo refuses; this journal names what ran.
///
/// Each performed action, collision name included, is appended as JSON when it runs: a plain
/// `write`, no flush per line, so it survives the app dying but may lose the last lines on a power
/// cut. Removed once the record is finalised. `profiles/<id>/restructure-landing-<manifest>.jsonl`.
final class RestructureLandingJournal: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    /// Whether a failed write has been reported: once per landing, since every later line fails
    /// the same way. Touched only from the landing's own sequence of `record` calls.
    private var reportedWriteFailure = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func url(manifestId: String, profileId: String, in directory: URL) -> URL {
        let safe = manifestId.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(profileId)/restructure-landing-\(safe).jsonl")
    }

    /// Nil when the file can't be made; the landing then runs unjournalled.
    init?(at url: URL) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            Logger.shared.warning("Restructure: could not start the landing journal at \(url.path)")
            return nil
        }
        self.url = url
        self.handle = handle
    }

    func record(_ action: RestructureManifest.Action) {
        guard var line = try? encoder.encode(action) else { return }
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            // Was silent: a landing interrupted after this point couldn't be recovered from the
            // journal, and nothing said the journal had stopped.
            guard !reportedWriteFailure else { return }
            reportedWriteFailure = true
            Logger.shared.warning("Restructure: the landing journal \(url.lastPathComponent) stopped accepting "
                                  + "lines (\(error.localizedDescription)) — an interruption from here on can't be "
                                  + "recovered from it")
        }
    }

    func finish() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops writing and leaves the file in place, for a landing whose record couldn't be
    /// finalised: the journal is then the only list of what ran.
    func close() {
        try? handle.close()
    }
}
