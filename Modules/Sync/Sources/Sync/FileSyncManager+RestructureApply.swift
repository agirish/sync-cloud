import Events
import Foundation

/// §5.5's Apply: one landing, run in the eight steps the roadmap orders, plus the ledger undo
/// that survives a quit. Sits beside `+Restructure` (the scaffold) rather than inside it — the
/// scaffold is the safe subset and reads better unentangled from the destructive engine.
/// How far a landing has got — §5.5's eight steps, as the sheet can show them (proposal O7).
///
/// The engine's own comments already mark the steps; this publishes the boundaries it was
/// already crossing. Watching the inverse reach disk *before* anything moves is the trust the
/// design paid for and could not previously be seen.
public struct RestructureApplyProgress: Equatable, Sendable {

    /// The stages a reader can distinguish. Steps 7 and 8 fold into `artifacts`: the corpus
    /// replay, the memory rebuild and the log line are one wait with no separable meaning.
    ///
    /// **What is promised is the ORDER, not a dwell on each line.** `guards` and `inverse` are
    /// separated by synchronous work that takes well under a frame, so neither is ever the
    /// *current* line for long — the sheet's checklist is what carries the meaning, showing them
    /// ticked above `operations` while the moves run. The `Task.yield()`s in `applyPlan` exist so
    /// each one gets a chance at a frame rather than being coalesced away entirely, which is
    /// worth having on a slow disk and is not worth asserting a duration about.
    public enum Stage: Int, Comparable, Sendable, CaseIterable {
        case guards, inverse, operations, verify, rederive, artifacts

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var stage: Stage
    /// Operations completed and planned — both zero outside ``Stage/operations``.
    public var opsDone: Int
    public var opsTotal: Int

    public init(stage: Stage, opsDone: Int = 0, opsTotal: Int = 0) {
        self.stage = stage
        self.opsDone = opsDone
        self.opsTotal = opsTotal
    }


    /// What each stage says while it is the current one. Written as the thing being done, in the
    /// order the engine does it, because the point is that a reader can see the inverse land
    /// before anything moves.
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

/// **What a survey refresh did** — or the sentence saying why it would not run.
///
/// It replaces a bare `String?` whose `nil` meant success, which is what let the one surface that
/// calls it say nothing at all on the path that worked: the call site banner-ed the refusal and
/// had no branch for the other case. A result that has to be *destructured* cannot be silently
/// dropped the same way, and the success case carries the two numbers a reader wants — a walk
/// that changed nothing and a walk that found two thousand folders are not the same event.
public enum SurveyRefreshOutcome: Equatable, Sendable {
    /// The walk landed and the survey was replaced. `folders` is what the new one holds,
    /// `previousFolders` what the old one did.
    case updated(folders: Int, previousFolders: Int)
    /// A guard closed, or the re-derive failed. The sentence is the whole of what to show.
    case refused(String)

    /// The refusal sentence, or nil when it worked — for a caller that renders the two
    /// differently (the Scaffolded card puts its refusal on the card that asked).
    public var refusal: String? {
        if case .refused(let sentence) = self { return sentence }
        return nil
    }

    /// **The one spelling of what to tell the user**, success or refusal, so two call sites
    /// cannot drift into describing the same event differently.
    ///
    /// The success sentence names the delta rather than only the total, because the total alone
    /// cannot distinguish "it ran" from "it ran and the tree had not moved" — and on a settled
    /// tree the second is the ordinary outcome, which a reader has to be able to tell from a
    /// button that did nothing.
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
        /// Sentences naming what was skipped and why — a folder holding unlisted files, a source
        /// that vanished, a destination that got taken. Reported, never silent (invariant 2).
        public var skipped: [String] = []
        /// An undo's items that had changed since the landing — edited, or a document saved over
        /// one — and were moved back all the same, named so the person can check them.
        public var changedSince: [String] = []
        /// The independent verifier's disagreements — reported on the card and in the log, and
        /// never rolled back on their own (invariant 6).
        public var verifierMismatches: [String] = []
        public var producedProfileId: String?
        /// §5.7's third sentence: the landing ran but the survey could not be refreshed.
        public var surveyRefreshFailure: String?
        public var refusal: String?
        /// The manifest as it actually landed — performed actions only. A caller replaying the
        /// landing onto its own keys must use THIS: the planned manifest's renames include any
        /// the apply skipped, and `rekey` moved the store's keys through the performed set.
        public var landedManifest: RestructureManifest?

        public init() {}

        /// The ledger sentence — derived from what happened, never pasted.
        public var summary: String {
            var parts = ["\(renamed) rename\(renamed == 1 ? "" : "s")",
                         "\(filesMoved) moved"]
            if foldersMovedWhole > 0 {
                parts.append("\(foldersMovedWhole) folder"
                    + "\(foldersMovedWhole == 1 ? "" : "s") carried whole")
            }
            if created > 0 { parts.append("\(created) created") }
            if removedEmpty > 0 {
                // "empty", not "emptied". The removal step now serves two origins, and only one
                // of them drained the folders it trashes — §5.2's standing empties were empty
                // all along. The sheet's own title makes that split; this sentence is the one
                // that outlives it on the ledger card, so it may not claim otherwise. "Empty" is
                // true of both.
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

    /// Lands a §5.4 manifest: guards → inverse on disk → re-probed operations → independent
    /// verify → one grouped ⌘Z → profile re-derivation → key replay → one log line.
    public func applyPlan(_ manifest: RestructureManifest, now: Date = Date()) async
        -> RestructureApplyOutcome {
        var outcome = RestructureApplyOutcome()
        if let refusal = restructureLandingRefusal() {
            outcome.refusal = refusal
            return outcome
        }
        restructureLandingInProgress = true
        restructureApplyProgress = RestructureApplyProgress(stage: .guards)
        // Cleared however this returns — a progress value outliving its landing would leave the
        // sheet showing a checklist for work that finished or refused.
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

        // A manifest lands once. The finalize below rewrites the record found by this id, so a
        // second landing of the same id would replace the FIRST landing's stored inverse with
        // its own near-empty one — destroying the post-quit undo of the real landing.
        guard !store.applied.contains(where: { $0.manifest.manifestId == manifest.manifestId })
        else {
            outcome.refusal = "The ledger already records a landing of this plan "
                + "(\(manifest.manifestId)) — a manifest lands once. Derive a fresh plan to "
                + "run it again."
            return outcome
        }

        // Step 2: the record, inverse included, on disk BEFORE the first operation — a crash
        // mid-run leaves a reversible trace (invariant 3). VERIFIED on disk: a swallowed write
        // failure here would run a full reorganisation whose only inverse dies with the session.
        restructureApplyProgress = RestructureApplyProgress(stage: .inverse)
        // See `Stage`: this and the yield below give the two pre-operations lines a chance at a
        // frame. Without them the first thing drawn is `operations`, and the ordered checklist —
        // not a dwell — is what makes "the inverse reached disk first" visible.
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
        // The counter arrives from the executor's own loop, off the main actor, and is coalesced
        // there, through this module's own `ProgressPublishGate`. Publishing per file would be a
        // published write per file, and every write to this manager re-evaluates the window's
        // root view — both file panes, the differences pane and the inspector — which is the
        // storm that gate was written for.
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
        // **Two `fileExists` per performed action, and they run OFF the main actor.** On a
        // 1,000-action merge this was 2,000 stats on the actor that draws the window, between
        // the moves finishing and the checklist ticking over — a visible hang with a progress
        // sheet on screen. It goes through the same serial file-operation queue the executor
        // just used, which is also what keeps it honest: the queue is ordered, so the verify
        // still reads the tree strictly after the moves that made it and strictly before
        // anything else this app does to it. The verdict is awaited, so every reader below
        // (the ledger's `verifiedOK`, the log lines, the summary) sees the same answer it did.
        let performed = execution.performed
        outcome.verifierMismatches = await enqueueFileOperation {
            FileSyncManager.verifyRestructureLanding(performed, root: expandedRoot, fm: fm)
        }

        // Every skip and mismatch, one line each — the cards say "named in the log", and the
        // finalize below replaces the stored manifest with the performed subset, so these lines
        // are the only durable record of which planned actions did NOT run.
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
            // Registration order is undo order REVERSED: created dirs first (removed last),
            // then the era renames, then the content moves — so ⌘Z moves every file out of
            // `Forms/` before `Forms/` becomes `Federal Tax/` again.
            undo.beginUndoGrouping()
            for url in execution.createdURLs {
                registerCreateFolderUndo(url: url, fileManager: fm)
            }
            let actionName = "Reorganize \(RestructurePaths.familyLabel(manifest.family))"
            if !execution.renameItems.isEmpty {
                // The renames get their OWN pair, not `registerMoveUndo`: that path records a
                // shallow identity (child count AND the folder's mtime) at registration, and this
                // group's second half — the merges landing inside the renamed folder — perturbs
                // both by design, so the rename-back would be refused as drift by our own group's
                // first half. A wholesale directory rename is the one move whose undo cannot lose
                // content: everything inside travels with it, which is the move-undo doc's own
                // argument for its shallow (not deep) check, taken one step further.
                registerRestructureRenameUndo(items: execution.renameItems,
                                              actionName: actionName)
            }
            if !execution.moveItems.isEmpty {
                registerMoveUndo(items: execution.moveItems, actionName: actionName)
            }
            undo.endUndoGrouping()
            undo.setActionName(actionName)
        } else if execution.removedEmpty > 0, let undo = undoManager {
            // A removal landing registers no session undo of its own — nothing moved; folders
            // went to the Trash — so the TOP of the ⌘Z stack would still be the previous
            // landing's group, and a ⌘Z right after "remove emptied folders" would replay THAT
            // group into source folders this landing just trashed. Clear the stack instead: the
            // removal's own ledger card carries the undo that actually reverses it. The clear
            // is deliberately blunt — it takes unrelated stacked undos (a New Folder, a filing
            // move) with it, an accepted cost: a lost undo is redone by hand, a replay into
            // trashed folders is not.
            undo.removeAllActions()
            Logger.shared.info("Restructure apply \(manifest.manifestId): removal landing — "
                + "session ⌘Z cleared; Undo This Reorganization… is the way back")
        }

        // The manifest as it actually landed: performed actions only, with collision names
        // and byte counts. The inverse is recomputed from THAT — the inverse of the plan would
        // move files back from names they never landed at.
        var landed = manifest
        landed.actions = execution.performed
        outcome.landedManifest = landed
        let finalised = store.updateApplied(manifestId: manifest.manifestId) {
            $0.manifest = landed
            $0.inverse = landed.inverse
            $0.created = execution.created
            $0.skipped = execution.skipped.count
            $0.summary = outcome.summary
            // Step 4's verdict, recorded where the card can read it. It has only ever lived in
            // the log, so the one surface that says whether a landing checked out was the one
            // place nobody looks after the fact.
            $0.verifiedOK = outcome.verifierMismatches.isEmpty
            $0.verifierNote = outcome.verifierMismatches.isEmpty ? nil
                : Self.verifierNote(outcome.verifierMismatches)
        }
        // Finalised: the record now says what ran, so the running list has done its job.
        //
        // **Only once that record is on disk (FR16).** When the finalising write fails — a full
        // disk, an unreadable `restructure.json` the store refuses to overwrite — the record on
        // disk still has no summary, so the next launch refuses Undo as a landing that never
        // finished, and points at this journal as the list of what ran. Removed regardless, that
        // sentence read "No list of the steps that ran was found" about a landing that had kept
        // one. Kept, it is closed and stays where the refusal looks.
        if finalised {
            journal?.finish()
        } else {
            journal?.close()
            Logger.shared.warning("Restructure apply \(manifest.manifestId): the landing's record "
                + "could not be written, so its list of the steps that ran is kept")
        }

        restructureApplyProgress = RestructureApplyProgress(stage: .rederive)
        // Steps 6 and 7, extracted so the Scaffolded card can run the same re-derive with a
        // manifest that moved nothing (proposal O12).
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

        // Step 8: one greppable line — the truth of an apply gets found later by this id.
        Logger.shared.info("Restructure apply \(manifest.manifestId): \(manifest.family) — "
            + "\(outcome.summary); verifier "
            + (outcome.verifierMismatches.isEmpty ? "OK"
               : "MISMATCH (\(outcome.verifierMismatches.count))")
            + "; profile \(oldDirectoryId) → \(newId)")
        return outcome
    }

    /// What a re-derive came back with — the new profile directory, or the sentence that says
    /// why the tree the app reads is still the old one.
    enum RederiveResult {
        case success(String)
        case failure(String)
    }

    /// **Steps 6 and 7 of a landing, callable on their own.**
    ///
    /// Re-derive the profile from a fresh walk, carry the per-profile artifacts into the new
    /// directory, replay the corpus keys through `landed`, rebuild the memory, and swap every
    /// store to it. `applyPlan` runs this after its operations; the Scaffolded card runs it with
    /// a manifest that MOVED nothing, which makes the rename map empty and the replay an
    /// identity — the walk is still the point, because the folders a scaffold created are only
    /// in the profile once something reads the disk again.
    ///
    /// `ledgerId` is the landing this belongs to, or nil when there is none — a survey refresh
    /// has no ledger record to finalise, and passing one that does not exist would silently
    /// no-op the updates below rather than failing.
    private func rederiveProfile(
        through landed: RestructureManifest, profile: FolderProfile, oldDirectoryId: String,
        profilesDirectory: URL, store: RestructureStore, expandedRoot: String,
        ledgerId: String?, summaryForLedger: String?, now: Date) async -> RederiveResult {
        // Step 6: re-derive the profile from a fresh walk — the finding is gone because the tree
        // was re-read, never because it was marked done. A failure here is §5.7's third sentence,
        // not a rollback: the moves landed and the ledger records them.
        let rootURL = URL(fileURLWithPath: expandedRoot)
        let tree = await Self.buildTree(url: rootURL, sortOption: .name)
        let newId = FileSyncManager.availableReorgProfileId(now: now, in: profilesDirectory)
        // **The curated registry, not the one reconstructed from the profile's own tokens.**
        // `PersonRegistry.seeded(from:)` is `personRegistry`'s FALLBACK — what to do when there is
        // no `people.json` — and calling it directly here skipped the household file that was
        // sitting right beside the profile. His has 7 people carrying 10 aliases (`Abhi`,
        // `Father`, `Shwe`, …); the profile axis had kept 2. So every re-derivation recomputed
        // the person axis against a registry missing eight of the ten names, and `carryOver`
        // takes `fresh.personAliases`, so each pass wrote the impoverished set back and the next
        // pass started from that — it compounds. Measured on the live tree after one evening's
        // refreshes: person-axis agreement 0.998 → 0.905, which is what
        // `thePersonAndLifecycleAxesAgree` is asserting when it fails.
        let registry = FilingProfileStore.personRegistry(id: oldDirectoryId, profile: profile,
                                                         in: profilesDirectory)
        let jurisdictions = RestructureRederive.entryJurisdictions(of: profile)
        // As the file spells it, `~` and all — and never the `~` a file without one decodes to:
        // every landing refuses that profile before it gets here (`restructureLandingRefusal`).
        let recordedRoot = profile.root
        // **`carryOver` rides along in the same detached hop.** It is a pure function over two
        // profiles — 3,013 entries rebuilt one struct at a time — and it was the one step between
        // the detached walk and the write that had no reason to be on the actor drawing the
        // window. One hop, not two: the builder's result is only ever read by this.
        let derived = await Task.detached(priority: .userInitiated) {
            let fresh = FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: newId,
                                                  registry: registry,
                                                  jurisdictionValues: jurisdictions)
            return RestructureRederive.carryOver(from: profile, into: fresh, through: landed)
                .settingDerivedFrom(oldDirectoryId)
        }.value
        // **The write stays on the main actor, deliberately.** It amends `profiles.json` — the
        // one artifact here that is SHARED with everything else that can mint a profile — and the
        // landing flag does not stop a walk that was already under way from writing it. The
        // expensive half of the step (building `derived`) is off the actor above; moving the
        // index amendment off it too would trade a hitch for a lost-update race on the file that
        // decides which profile the app reads.
        //
        // **What the user made reaches the new folder BEFORE `profiles.json` names it (FR17).**
        // The write below re-points the index, and everything after it is awaited — the corpus
        // replay is seconds on a real tree. The roster, the verdicts and the ledger used to be
        // copied inside that wait, and the record's `producedProfileId` written after it, so a
        // quit there relaunched onto a folder with no `restructure.json` (or one whose record
        // still said nothing was produced): `undoableReorganisation` keys on
        // `producedProfileId ?? appliedUnderProfileId` being the active id, neither was, and the
        // landing's Undo was gone without a word. So the carry and the new ledger's whole tail
        // run first, synchronously, on this actor — no suspension between them and the write,
        // so nothing the user does can land in the gap. A cut-off re-derive now relaunches onto a
        // ledger that already names the folder it is in — and no record names the folder it left,
        // which holds the only corpus and memory until the replay writes them here; the retire
        // sweep keeps a folder holding either while the active one lacks it, and the next load
        // reads them back (`recoverInterruptedSurveyReplay`). If the write then
        // fails, the copies are removed again: the index never named that folder, so they are
        // only clutter.
        let fm = fileManager
        let alreadyThere = Set(FilingProfileStore.curatedArtifactNames.filter {
            fm.fileExists(atPath: profilesDirectory.appendingPathComponent("\(newId)/\($0)").path)
        })
        // The folder the write below would make — made first, or every copy has nowhere to land.
        try? fm.createDirectory(at: profilesDirectory.appendingPathComponent(newId),
                                withIntermediateDirectories: true, attributes: nil)
        let carriedExports = FileSyncManager.carryProfileArtifacts(from: oldDirectoryId, to: newId,
                                                                   in: profilesDirectory, fm: fm)
        let newStore = RestructureStore(directory: profilesDirectory, profileId: newId)
        // Which store this one carries on from, and through which renames — so an undo
        // registered against the old one can find its key here (`unsuppressStructureFinding`).
        newStore.adoptLineage(from: store, renames: RestructureRederive.renameMap(of: landed))
        // **One write for the new store's whole tail, not three.** The rekey, the rescue record
        // and the produced-id update are three mutations of one file, and each used to rewrite
        // the entire ledger. `recordApplied` inside is the deliberate exception the batch
        // documents — it always reaches the disk, because its answer is a safety claim.
        newStore.batchingSaves {
            newStore.rekey(renames: RestructureRederive.renameMap(of: landed),
                           context: ledgerId ?? "survey refresh")
            // The artifact carry copies best-effort, one file at a time — if restructure.json was
            // the copy that failed, the fresh store loads empty and the update below would no-op
            // silently, stranding the finalised record (and its inverse) in a directory nothing
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
                // **A survey refresh carries the undo chain across here too**, for the same
                // reason: `undoableReorganisation` is keyed on a landing's produced profile being
                // the current one, and this is about to mint a new current one without moving a
                // file. Done after the refresh returned, a quit in its corpus replay left the
                // last landing permanently un-undoable.
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
                + "profile re-derivation failed: \(error)")
            return .failure("the survey could not be refreshed — " + String(describing: error))
        }

        // **The stores the user edits move to the new folder NOW, before the replay's wait
        // (FR5).** The roster, the person verdicts and Restructure's answers were just copied
        // there, and `profiles.json` names it; the replay below is awaited for seconds, the
        // window is live through it, and the People pane is one click away. With the stores
        // still open on the old folder until after the wait, a person added or a verdict given
        // in those seconds was written to the OLD folder after its copy had already been taken
        // — kept on disk, read by nothing once the swap landed. Opened here, every edit made
        // from this point on is made in the folder the app will read. The profile, the memory
        // and the id stay where they are until the replay has produced the memory they belong
        // with — the stores write by their own folder, never by those.
        restructureStore = newStore
        filingPeopleStore = PeopleStore(directory: profilesDirectory, profileId: newId,
                                        profile: derived)
        filingPersonTagStore = PersonTagStore(directory: profilesDirectory, profileId: newId)

        restructureApplyProgress = RestructureApplyProgress(stage: .artifacts)
        // Step 7: the curated artifacts followed the profile into its new directory above, before
        // the re-point; here the corpus keys are replayed and the memory rebuilt from them. No
        // page is re-read for a file that only moved.
        // **All of step 7 in ONE detached hop.** Every byte of the replay lands under `newId`;
        // the one exception is the read-back first, which finishes an earlier cut-off replay
        // INTO the old folder (`recoverInterruptedSurveyReplay`), so this one has a corpus to
        // replay from.
        //
        // This ran on the main actor: a `JSONDecoder` pass over ~9,000 corpus documents, the key
        // replay, `flatten` over the whole walked tree, `buildMemory` (which tokenises every
        // document stem), and the encode-and-write of both artifacts — with a landing sheet on
        // screen and `restructureLandingInProgress` refusing every other scan. This module's own
        // rule says decoding on the main actor is a hitch the user sees; see
        // `FileSyncManager+FilingRefine.swift`.
        //
        // Safe to detach where the profile write above is not, and the reason is the *target*:
        // every path written here is the corpus, memory and progress inside the freshly minted
        // `\(newId)` directory, or the old one's when its own replay never finished — files
        // nothing else writes while the landing flag is up. There is no shared file to lose an
        // update on. The
        // result is awaited, so `filingMemory` is set before anything below reads it, exactly as
        // it was.
        let replayed: (memory: FilingMemory, failure: String?)? =
            await Task.detached(priority: .userInitiated) { () -> (FilingMemory, String?)? in
                // A replay of its own that never finished leaves the folder this one reads from
                // empty; finish it first, or this replay finds nothing (FR17, follow-up).
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
                // Logged from the main actor, as it was — `Logger` is the app's, and the sentence
                // is unchanged so the greppable line does not move.
                Logger.shared.warning("Restructure re-derive \(ledgerId ?? "(no landing)"): the replayed "
                    + "corpus could not be written under \(newId): \(failure)")
                // The old folder's date must not stand under the new one, which has no corpus.
                filingSurveyedAt = nil
            } else {
                // **Published only when the write succeeded**, which is what the old `do` block
                // did: a memory in hand that never reached disk must not become the live one.
                filingMemory = replayed.memory
                filingSurveyedAt = now
            }
        }

        // The new directory is the active one now: every store re-opens there, the finding cache
        // drops with the profile publish, and the fingerprint moves — which invalidates every
        // cached verdict, correctly, because they name paths that just changed.
        filingFolderProfile = derived
        filingProfileDirectoryId = newId
        filingArtifactFingerprint = FilingProfileStore.fingerprint(id: newId,
                                                                   in: profilesDirectory)
        // The OLD store keeps the finalised record too — it is the ledger Undo reads after the
        // re-point puts that directory back in charge.
        if let ledgerId {
            store.updateApplied(manifestId: ledgerId) { $0.producedProfileId = newId }
        }
        // **Retire what this re-derivation just superseded.** Every re-derive mints a new profile
        // directory, and until now nothing ever removed one — eight had accumulated in an evening.
        //
        // The protected set is the domain knowledge the store deliberately does not have: Undo
        // re-points at `appliedUnderProfileId` through `repointActiveProfile`, which requires the
        // target to still be on disk, so **every id any ledger record names is pinned** — the
        // profile a landing was applied under and the one it produced, and for records already
        // undone too, because an id that cheap to keep is not worth a rule about when it stops
        // mattering. The store adds the active profile and anything not provably derived.
        //
        // A failure here is logged and swallowed on purpose: the survey WAS refreshed, the moves
        // (if any) landed, and reporting a successful re-derivation as a failure because its
        // housekeeping tripped would be the worse lie of the two.
        //
        // **The immediate predecessor is deliberately NOT seeded in.** Keeping "just the last
        // one" would leave a stale profile standing after every refresh, which is the thing being
        // fixed — and it is not needed: after a plan apply the predecessor IS the record's
        // `appliedUnderProfileId` and the loop below pins it, while after a bare survey refresh
        // with no ledger records nothing can reach it at all. The rule is what the data says,
        // not a spare copy kept out of nerves.
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
                + "retired: \(error)")
        }
        // O16's point for the survey this re-derive just produced. `landing:` is whether a
        // manifest caused it — a survey refresh moves no files, so its point is an ordinary one
        // and gets no dot.
        stampStructureTrend(landing: ledgerId != nil, now: now)
        return .success(newId)

    }

    /// **Make the survey catch up** — §5.7's Scaffolded card, given the button its own sentence
    /// promised (proposal O12).
    ///
    /// A scaffold creates folders and lands, but the profile is an artifact read off disk: until
    /// something walks the tree again the backlog finding is still there, and the card says so
    /// rather than offering the same landing twice. This runs the landing's own re-derive with a
    /// manifest that moves nothing, so the walk is the entire content of the operation.
    ///
    /// **It replaces a hand-built profile with a derived one**, exactly as a plan's own step 6
    /// does — sanctioned by §5.5's decisions block, and said out loud in the button's help
    /// because this is the first time a scaffold causes it.
    ///
    /// Returns nil on success, or the sentence the card should show. A refusal is a sentence,
    /// never a queue: the guards are the landing's, so "wait for the scan" means wait and press
    /// it again.
    public func refreshDerivedProfile(now: Date = Date()) async -> SurveyRefreshOutcome {
        if let refusal = restructureLandingRefusal() { return .refused(refusal) }
        restructureLandingInProgress = true
        // The progress value belongs to the operation that publishes it. `rederiveProfile` is
        // shared with `applyPlan`, whose own defer clears it — without this one a refresh left
        // `.artifacts` published for the rest of the session, and the next plan sheet opened
        // showed a five-ticked checklist over a landing that never happened.
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
        // Read BEFORE the walk replaces it — the whole point of the number is the comparison,
        // and after `rederiveProfile` succeeds `filingFolderProfile` is already the new one.
        let previousFolders = profile.folders.count
        // Moves nothing: the rename map is empty and the corpus replay is an identity, so what
        // is left is the fresh walk — which is the whole point.
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
            // The undo chain was carried across inside `rederiveProfile` — `repointProduced`,
            // before `profiles.json` named the new folder (FR17) — so a landing that was undoable
            // a moment ago still is, even had the app quit in the corpus replay.
            //
            // The stamp is what the staleness note reads, and a successful refresh must clear
            // the caution even on a profile with no corpus to rewrite (`rederiveProfile` only
            // stamps inside the corpus branch).
            filingSurveyedAt = now
            let folders = filingFolderProfile?.folders.count ?? previousFolders
            Logger.shared.info("Restructure: survey re-derived on request — "
                + "\(oldDirectoryId) → \(newId); \(previousFolders) → \(folders) folder(s)")
            return .updated(folders: folders, previousFolders: previousFolders)
        case .failure(let sentence):
            return .refused("The survey was not refreshed — " + sentence)
        }
    }

    /// `Undo this reorganisation` — the ledger's inverse, run through the same guards and
    /// re-probes, then `profiles.json` re-pointed back to the profile recorded as
    /// `appliedUnderProfileId`, which was kept for exactly this. It is not ⌘Z; it survives a
    /// quit, and it is honest about drift: a file that moved on since is skipped and reported.
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
        // Only the NEWEST not-undone reorganisation can be undone: an older record's inverse
        // describes a tree a later landing has reshaped. The chain is walked by ledger order,
        // NOT by profile-id equality — a later landing whose re-derive failed never re-pointed
        // the survey, so an id comparison cannot see it sitting on top.
        if let index = store.applied.firstIndex(where: { $0.manifest.manifestId == manifestId }),
           store.applied[(index + 1)...].contains(where: {
               $0.appliedUnderProfileId != nil && $0.undoneAt == nil
           }) {
            outcome.refusal = "A later reorganization sits on top of this one — undo that one "
                + "first, newest first, the way ⌘Z would."
            return outcome
        }
        // A record without a summary never finalised: the app quit mid-apply, and the stored
        // inverse is the PLAN's — collision names never recorded — so replaying it could move
        // the wrong file. Refusing is the only honest answer — and the landing's journal, written
        // one line per action as each ran (FR16), is what names what actually landed. The log
        // used to be named here, and recorded nothing per action.
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
        // The survey must still be where the landing left it: the directory it produced, or —
        // when its re-derive failed before re-pointing — the one it was applied under.
        guard (record.producedProfileId ?? previousId) == (filingProfileDirectoryId ?? "") else {
            outcome.refusal = "The survey has moved since this landing — the active profile is "
                + "not the one it left behind, so re-pointing back would aim the survey at the "
                + "wrong tree."
            return outcome
        }
        // The store's `undoableReorganisation` is the ONE spelling of "which landing may be
        // undone" — it is what enables the menu item and the ledger cards. The guards above
        // exist to NAME the cause; this guard makes the decision itself the store's, so the
        // two can never drift into an enabled surface whose engine quietly refuses (or the
        // reverse). If a guard is ever edited without the predicate, this refusal is the tell.
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
        // Off the main actor and through the serial queue, for the reason the apply's own
        // verify documents: two stats per performed action is a main-thread hang on a big
        // landing, and the queue's order is what keeps "after the moves, before anything
        // else" true without the call being synchronous.
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

        // An undo that could do NOTHING — every inverse step skipped as drift — must not mark
        // the record undone or re-point the survey: the tree was not restored, so the kept
        // profile would describe a tree that does not exist, and the record could never be
        // retried after the drift is resolved by hand. Counted over OPERATIONAL actions:
        // `keep` "performs" by doing nothing, so it can neither satisfy nor demand an undo.
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

        // The session ⌘Z stack described the tree as the landing left it; the ledger inverse has
        // now reshaped it back, so every stacked group — and especially the landing's own redo —
        // would replay against a tree that no longer matches its registrations. Clearing is the
        // honest move: without it, ⌘⇧Z after this undo re-applied the era renames onto a tree
        // the ledger records as undone.
        if let undo = undoManager, undo.canUndo || undo.canRedo {
            undo.removeAllActions()
            Logger.shared.info("Restructure undo \(manifestId): session ⌘Z stack cleared — it "
                + "described the pre-undo tree")
        }

        // The active-profile guard, RE-CHECKED after the suspension: the inverse ran for
        // minutes on a real tree, and a Setup walk completed meanwhile writes and activates a
        // fresh profile — the pre-await guard cannot see it, and an unconditional re-point
        // would silently deactivate the profile the user just finished learning. This is the
        // undo-side twin of `writeDerivedProfile`'s raced-switch refusal, which protects the
        // apply's write but has no counterpart inside `repointActiveProfile`.
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
        // Re-point back and reload everything from the kept directory — the profile there
        // describes the restored tree, which is why the undo does not re-derive.
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
        // Marked in the CURRENT store first (the one that carried the record here), then in the
        // restored directory's own copy once it is re-opened below.
        store.updateApplied(manifestId: manifestId) {
            $0.undoneAt = undoneStamp
            $0.undoSummary = undoSummary
        }
        // What the user made since the landing comes back with the survey (FR7).
        var undoLanded = record.inverse
        undoLanded.actions = execution.performed
        let ledgerCarried = leavingId != previousId
            && carryCuratedEditsBack(from: leavingId, to: previousId, in: profilesDirectory)

        if let loaded = FilingProfileStore.active(in: profilesDirectory) {
            // The leaving folder's survey date is not the restored one's: cleared before the id
            // moves, as `FilingArtifacts.attach` does, not left under it while the read below runs.
            if filingProfileDirectoryId != loaded.id { filingSurveyedAt = nil }
            filingFolderProfile = loaded.profile
            filingMemory = loaded.memory
            filingProfileDirectoryId = loaded.id
            let restoredStore = RestructureStore(directory: profilesDirectory,
                                                 profileId: loaded.id)
            // The carried ledger's suppressions, answers and drafts are keyed in the landed
            // tree's paths; the undo just put those folders back under their old names, so the
            // keys go back through the renames the undo actually performed — the landing's own
            // rekey, run the other way.
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
            // Off the main actor: the stamp read parses the whole corpus, ~5 MB (speed audit 5).
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

    /// **Carries the user's edits made since a landing back onto the folder its Undo re-points
    /// to (FR7)** — and answers whether `restructure.json` was among them, so the caller can
    /// rekey it.
    ///
    /// Undo re-points `profiles.json` at the profile the landing was applied under, and every
    /// store re-opens there. That folder's roster, person verdicts and Restructure state are the
    /// copies the landing started from — so a person added, a verdict given, a finding
    /// suppressed, a draft saved or a scaffold landed after the landing was still on disk in the
    /// produced folder and read by nothing once the undo finished. The produced folder's copies
    /// began as these very files and took every edit since (FR5 keeps edits from reaching the old
    /// folder in between), so they are the newer state, and they are written over the old ones
    /// whenever the bytes differ. The produced folder keeps its own — the ledger pins it, and
    /// nothing is removed.
    ///
    /// `restructure.json` comes too, ledger and all, and that is the correct ledger: the
    /// produced copy holds this landing's record (already marked undone by the caller) and every
    /// record written after it. The person verdicts are carried as they stand: the landing never
    /// rekeyed them either. Best-effort per file, like the landing's own carry; a failure is
    /// logged and leaves the old copy.
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
        // A plan exported after the landing goes back too: the survey goes back to this folder,
        // and the sheet named the file as beside it. One already there by name is the same
        // day's export of the same plan, which `exportPlan` itself replaces.
        FileSyncManager.carryProfileArtifacts(from: producedId, to: previousId, in: directory,
                                              fm: fileManager, names: [])
        return ledgerCarried
    }

    // MARK: - The renames' own ⌘Z pair

    /// Undo for the era renames, on `registerCreateFolderUndo`'s pattern: existence re-probes at
    /// the moment of the action, no identity snapshot — see the registration site for why the
    /// move-undo's shallow identity cannot serve a compound group that reshapes the renamed
    /// folder by design. Items unwind in reverse, so a vacate-before-fill chain reverses in the
    /// only order that works.
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
                    // The case-only pass exists because a case-insensitive volume answers the
                    // existence probe for BOTH spellings; on a case-sensitive volume a standing
                    // `item.from` really is a distinct occupant, and waving it past would let
                    // `safeMoveItem` replace it wholesale.
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
        /// An undo's items that were not as the landing left them — edited, or saved over — and
        /// were moved back anyway (see `landedIdentity`). Named, never silent.
        var changedSince: [String] = []
        /// The actions that ran, with `collidedInto` and `bytes` filled from the disk.
        var performed: [RestructureManifest.Action] = []
        /// Directory renames — registered for ⌘Z as their OWN batch, before the content moves,
        /// so undo pops the moves first: a file must leave `Forms/` before `Forms/` stops
        /// existing under that name.
        var renameItems: [(from: URL, to: URL)] = []
        var moveItems: [(from: URL, to: URL, overwritten: URL?)] = []
        var createdURLs: [URL] = []
    }

    /// How many FILES sit anywhere beneath `path` — empty directories and OS noise do not count
    /// as contents. This is the removal step's definition of "still empty": a drained
    /// folder whose only remainders are the (equally drained) folders inside it can go to the
    /// Trash whole, which is what lets ``RestructureLedger/emptiedFolders(of:)`` stay
    /// shallowest-only without stranding the nested drained folders it deliberately drops —
    /// a shallow items-count probe called the parent "not empty" over an empty subfolder, and
    /// both lingered forever.
    /// nil when the walk could not see everything — a directory it could not open reads as
    /// UNKNOWN, never as empty: the old `return 0` default meant a permission-denied subtree
    /// silently counted as nothing, and the removal step would have trashed a folder whose
    /// contents it never saw. Callers treat nil as "not empty" and say so.
    nonisolated public static func visibleFileCount(atPath path: String,
                                                    fm: FileManaging) -> Int? {
        // NOT `.skipsHiddenFiles`: that prunes hidden DIRECTORIES wholesale, and a drained
        // folder holding `Old/.git/…` would have read "still empty" over a full repository.
        // The walk descends everywhere, because a hidden directory's contents are content,
        // however its container is named.
        //
        // **Only OS noise is ignorable — not every dotted name (FR18).** This skipped any file
        // whose name began with ".", which is `.DS_Store` and also `.env`, `.gitignore` and the
        // `.~lock.Return.ods#` an office suite leaves beside an open document. A folder holding
        // only those read "still empty", the removal step trashed it, and its inverse is a bare
        // `create-dir` — so Undo brought the folder back without the file. The names skipped now
        // are `ItemIdentity.deepIdentityIgnoredNames`, the set the OS writes on its own schedule
        // and the one New Folder's undo asks through this same count; one of those as a
        // directory (`.Trashes`) is skipped with everything inside it.
        //
        // **A folder whose contents are not on this Mac is asked for first, bounded (FR21).** This
        // runs inside the file queue, and the plain enumerator below would sit forever in a
        // cloud-only folder whose app has stopped — wedging the landing and everything queued
        // behind it. The root and every folder the walk meets are asked through
        // `DatalessFolderReads` before the walk reads them (the enumerator descends on the call
        // AFTER the one that yielded a folder, so an answered folder is on disk by then); one that
        // does not answer makes the count nil — unknown, so the folder is kept, never trashed.
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
            // `hasDirectoryPath` too: it is the enumerator's own word, and a test disk's folders
            // answer no resource values. The count below is unchanged.
            if isDir || url.hasDirectoryPath, !fm.waitForContentsBlocking(of: url) { return nil }
            if !isDir { files += 1 }
        }
        return sawError ? nil : files
    }

    /// One directory level's entry names — the listing the unlisted-file rule re-runs at the
    /// moment of the action. nil when the folder could not be listed.
    ///
    /// **Through `listing(of:)`, not a plain enumerator (FR21).** This runs inside the file queue,
    /// and an enumerator over a cloud-only folder whose app has stopped never returns, wedging the
    /// landing and every operation queued behind it; `listing(of:)` asks such a folder through
    /// `DatalessFolderReads`, bounded. And it tells "could not be read" from "empty", which the
    /// enumerator with no error handler did not: both came back `[]`, so the unlisted-file veto
    /// found nothing unlisted in a folder it never saw.
    nonisolated static func directoryNames(at path: String, fm: FileManaging) -> [String]? {
        let listed = fm.listing(of: URL(fileURLWithPath: path))
        guard listed.isComplete else { return nil }
        return listed.urls.map(\.lastPathComponent)
    }

    /// Runs the actions in order against the real tree, re-probing every `src` and `dst`
    /// immediately before each one (invariant 5). A folder holding a file the manifest never
    /// listed is skipped whole and reported, and the rest of the plan runs (invariant 2); a taken
    /// destination gets a unique name and a collision fact, never an overwrite.
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
        // **`ProgressPublishGate`, not a clock.** This module already owns the publish-storm
        // rule, and its doc gives the reason to prefer a percent gate over an interval: a gate
        // keyed on elapsed time can only be tested against a clock seam, and a percent gate caps
        // a run of ANY length at ~101 publishes where an interval is unbounded in total. The
        // first cut here re-invented the interval and was weaker on both counts. `nil` for every
        // caller that is not watching.
        var gate = ProgressPublishGate()
        var completed = 0
        var lastPublished = -1
        func report(force: Bool = false) {
            guard let onProgress else { return }
            // The gate already lets the terminal report through, so the forced call after the
            // loop would otherwise publish the final count twice.
            guard completed != lastPublished else { return }
            guard force || gate.admits(completed: completed, total: total) else { return }
            lastPublished = completed
            onProgress(completed)
        }
        func absolute(_ relative: String) -> String {
            (root as NSString).appendingPathComponent(relative)
        }
        // The unlisted-file rule, resolved per source folder ONCE, at the moment its first move
        // runs: the planned set is what the manifest lists out of that folder; anything else on
        // disk is a file the plan never read, and moving around it would be guessing.
        var plannedOut: [String: Set<String>] = [:]
        for action in actions
        where action.action == .moveFile || action.action == .moveDir || action.action == .keep {
            guard let src = action.src else { continue }
            // The item itself is listed at its parent — and so is every ancestor folder at ITS
            // parent, because a subfolder whose contents the plan moves (or keeps) one level
            // deeper is a folder the plan has accounted for, not a stray. Without the ancestor
            // credit, the same-name-subfolder merge the planner itself derives (`Payment/` into
            // `Payments/`, both holding `Receipts/`) vetoed its own parent folder: `Receipts`
            // is never a move src, only its files are.
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
            // The inverse runs with the veto OFF: its source folders legitimately hold files the
            // action list never names — a rename carried them — and the per-file re-probes are
            // the honesty the undo paragraph promises (a file that moved on is skipped and
            // reported; nothing is ever overwritten).
            guard vetoUnlistedSourceFolders else { return false }
            if vetoedSources.contains(parent) { return true }
            guard !checkedSources.contains(parent) else { return false }
            checkedSources.insert(parent)
            // A folder that exists but could not be listed — its cloud app did not answer, or it
            // is locked — is skipped whole: the rule cannot vouch that it holds nothing unlisted
            // (FR21). One that is gone is left to the per-action probes, which say so.
            guard let listed = FileSyncManager.directoryNames(at: absolute(parent), fm: fm) else {
                guard fm.fileExists(atPath: absolute(parent)) else { return false }
                vetoedSources.insert(parent)
                out.skipped.append("\(parent)/ could not be read — left untouched; a folder "
                    + "whose contents the plan cannot see is never moved out of")
                return true
            }
            // **Only OS noise is ignorable — not every dotted name** (review R10, as FR18 for the
            // emptiness walk). A `.env` or `.gitignore` the plan never read was skipped here, so a
            // merge drained the folder around it and split it from the files it belongs with.
            let unlisted = listed.filter { !ItemIdentity.deepIdentityIgnoredNames.contains($0) }
                .filter { !(plannedOut[parent] ?? []).contains($0) }
            guard !unlisted.isEmpty else { return false }
            vetoedSources.insert(parent)
            out.skipped.append("\(parent)/ holds \(unlisted.count) item(s) the plan never "
                + "listed (\(unlisted.sorted().prefix(3).joined(separator: ", "))"
                + (unlisted.count > 3 ? ", …" : "") + ") — left untouched")
            return true
        }
        // The subtree half of "skipped whole": once a folder is vetoed, nothing moves out of
        // any folder BENEATH it, and nothing lands INTO it or beneath it. The per-parent key
        // alone honoured neither — a one-level-down merge drained `S/Sub` right after the skip
        // sentence promised `S/` was left untouched, and a later group's arrivals merged into
        // the vetoed folder unreviewed.
        func vetoedAncestor(of path: String) -> String? {
            vetoedSources.first { path == $0 || path.hasPrefix($0 + "/") }
        }
        // **A rename refused as drift refuses the merges that were headed into it too (FR19).**
        // `Form W2 → Form W-2`, then `Form-W2/*` merged into `Form W-2/`: if a `Form W-2/` syncs
        // in first, the rename is skipped "rather than merged unreviewed" — and the merges, which
        // only ever checked `vetoedSources`, landed in that very folder anyway, unreviewed, under
        // a sentence saying the opposite. The plan's later actions name the destination as the
        // folder the rename WOULD have produced; the one standing there is somebody else's, so
        // nothing moves into it, out of it, or is created beneath it. Kept apart from
        // `vetoedSources` because that set's sentence ("holds items the plan never listed") is
        // about a different refusal.
        var refusedRenameDestinations: Set<String> = []
        func refusedRename(covering path: String) -> String? {
            refusedRenameDestinations.first { path == $0 || path.hasPrefix($0 + "/") }
        }
        func refusedRenameSentence(_ item: String, _ covering: String) -> String {
            "\(item) was planned against \(covering)/ as the rename would have made it, and that "
                + "rename was refused — left where it stands"
        }
        // **An undo puts an item back in the folder it came from, even when that folder is gone
        // (FR20).** A merge empties its source folder, and an emptied folder is exactly what a
        // person tidies away by hand. The inverse's move-back into it then failed for want of a
        // parent, the rename-back after it succeeded — and carried every merged file into a
        // folder they had never lived in, under a record marked undone. The missing parent is not
        // a guess: it is the folder the landing moved the item OUT of, recorded in the action
        // itself, so recreating it restores the tree rather than reshaping it. Stopping as drift
        // before the rename-back was the other choice, and it is the worse one: it leaves a half
        // undone tree with no record that can finish it. Only the inverse does this — a forward
        // plan names the folders it creates, and a missing destination there is drift.
        // **An undo moves back the item the landing moved, not whatever now has its name (M1).**
        // A landing that put `W2.pdf` in `Forms/`, followed by a newer `W2.pdf` dropped in its
        // place, used to send the newcomer back into the old folder and count it "moved" — the
        // only probe was that SOMETHING stood at the path.
        //
        // **But an edit and a same-name swap look alike, and the undo must not strand edits.**
        // Most apps save by swapping in a new file (`replaceItemAt`), which gets a new file number
        // and keeps the old creation date — and so does a different document saved over this one
        // through a Save dialog's Replace (measured 2026-10-27). No metadata tells the two apart.
        // His call (2026-10-27): only an item that is clearly new — a different file number AND
        // a creation date more than a second away — is left where it stands. Anything else that
        // changed (number, creation date or, for a file, size) goes back and is NAMED, so the
        // card says which files were not as the landing left them. A record from before the
        // number and date were kept has only the size, and size alone never refuses.
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
            // Counted per action attempted, including the ones that skip: the sheet is showing
            // how far through the list the landing is, not how much of it succeeded.
            defer {
                // What ran is on disk the moment it has run — see `RestructureLandingJournal`.
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
                // A taken destination turns a rename into a merge nobody reviewed — skipped,
                // unless this is the case-only rename `safeMoveItem` owns the two-step for.
                // The exemption holds only on a case-insensitive volume, where the existence
                // probe answers for both spellings; on a case-sensitive one a standing `dst`
                // differing only by case is a real, distinct occupant.
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
                    // Keep both, never overwrite, and count it (§5.4's collision policy).
                    destination = FileSyncManager.generateUniqueURL(for: destination,
                                                                   fileManager: fm)
                    let relative = String(destination.path.dropFirst(root.count + 1))
                    performed.collidedInto = relative
                    out.collisions += 1
                }
                do {
                    // The size is recorded NOW, from the disk (invariant 5) — before the move,
                    // while the source path is still the one the manifest names.
                    // (The re-probe window above is real but bounded: a file APPEARING at the
                    // destination between the probe and the move is replaced by `safeMoveItem`,
                    // which trashes the old copy and logs — recoverable, never silent.)
                    //
                    // **No digest. A same-volume move is a rename, and hashing made it a read.**
                    // `performed.md5` used to be an MD5 of every moved file, up to a 64 MB cap
                    // each — a gigabyte read for a 500-file merge, inside the window where
                    // `restructureLandingInProgress` refuses every other scan and file
                    // operation, to fill a field whose own doc said nothing verifies it. Nothing
                    // did: outside this line, the only reader in the repo was the test that
                    // asserted it had 32 characters. The field stays on
                    // `RestructureManifest.Action` so ledgers already on disk keep decoding
                    // theirs; new records simply do not carry one. `bytes` is the audit fact
                    // that survives, and it costs the `attributesOfItem` call already being made.
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
                // A folder already vetoed is left alone WHOLE — nothing drains out from under
                // it, and this holds for a relocation too: the plan has decided it cannot
                // safely touch that folder, and carrying one of its children away anyway would
                // be the drain by another name.
                if let covering = vetoedAncestor(of: parent) {
                    out.skipped.append("\(src)/ sits under \(covering)/ — left untouched with it")
                    continue
                }
                // But a relocation does not DRAIN its source's parent, so the unlisted-file rule
                // has nothing to protect there — and applying it anyway vetoed every
                // loose-folder plan, because that detector only fires when a sibling container
                // exists and a sibling is precisely what the veto reads as unlisted. Skipping
                // the call matters as much as skipping the `continue`: `sourceFolderVeto`
                // RECORDS the folder it refuses, and a relocation must not mark its parent
                // vetoed for every action that follows.
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
                    // To the Trash, never a hard delete — the removal step's own rule, and the
                    // right caution for an inverse's `create-dir` turned back around.
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    out.removedEmpty += 1
                    out.performed.append(action)
                } catch {
                    out.skipped.append("\(src)/ could not be removed: \(error.localizedDescription)")
                }
            }
        }
        // The last window may not have elapsed — the final count is the one that matters.
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

    /// The verifier's disagreement in one line, for the Applied card. The log keeps every
    /// mismatch; the card names the count and the first, because a card that listed forty would
    /// be the log with worse formatting.
    nonisolated static func verifierNote(_ mismatches: [String]) -> String? {
        guard let first = mismatches.first else { return nil }
        guard mismatches.count > 1 else { return first }
        return "\(first) (and \(mismatches.count - 1) more; each one is in the log)"
    }

    /// Invariant 6's verifier: re-lists the touched paths and checks the disk against what the
    /// performed actions claim — none of the mover's arithmetic, all of its subject.
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
                // A case-only rename's source "exists" to a case-insensitive volume because the
                // DESTINATION answers for both spellings — asking would flag every one of them.
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

    /// Copies the per-profile artifacts the app reads into the new directory — the roster, the
    /// person verdicts, and everything Restructure remembers. Copied, never moved: the old
    /// directory is what Undo re-points to, and it keeps its own set.
    ///
    /// The plans Export Plan wrote come too, unless `carryingExportedPlans` is false (a walk of a
    /// different folder, whose plans are about another tree): the sheet named the file "beside
    /// your survey", and the survey is about to be this folder.
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
                // **An export of the same name is not necessarily the same plan.** A re-export
                // after a landing, or a take-up over newer history, has its own contents; skipped
                // by name, the old folder's version went when the sweep retired that folder.
                // Identical bytes are the same file; anything else is kept beside it.
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

    /// **A stopped document survey keeps its resume point across a re-derive (FR6).**
    ///
    /// `survey-progress.json` lives in the profile's folder and the curated carry never took it,
    /// so a survey stopped at 5,000 of 7,558 and then a landing — or a plain *Update the survey* —
    /// left the app reading a folder with no progress: the next survey started from 0, and the
    /// retire sweep then deleted the old folder with the hours of reading inside it.
    ///
    /// **Rekeyed, not copied, and that is the point.** The checkpoint's `read` is keyed by path
    /// relative to the root, exactly as the corpus is, and the landing just moved those paths; it
    /// also names the profile it belongs to, and `adoptCheckpoint` refuses one naming another.
    /// A plain copy would therefore be refused outright, and even with the id fixed would hold
    /// keys at paths that no longer exist — every moved document read again. So `read` goes
    /// through ``RestructureRederive/rekeyedCorpus(_:through:)``, the same replay the corpus
    /// gets, and the plan's paths through the same moves and renames. A moved file was not
    /// changed, so what was read of it still holds. The resume index survives only if the plan
    /// kept its length; otherwise it restarts at 0, which `adoptCheckpoint` already does for
    /// any changed plan, skipping every document already read.
    ///
    /// A checkpoint that is not this profile's resumable run — unreadable, or naming another
    /// profile — is carried byte for byte: it was not resumable before and must not become so,
    /// but it stays where the app looks, so the card still says what is there. Copied, never
    /// moved: the old folder is what an Undo re-points to.
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

    /// **Finishes, off the main actor, the replay a cut-off re-derive left undone** for the
    /// profile this manager has loaded (review C5), and publishes the memory it rebuilt.
    ///
    /// ``FilingProfileStore/active(in:)`` used to do this inline, and its callers are on the
    /// main actor — the launch, Setup's Save and an Undo — so a corpus of thousands of documents
    /// was decoded, rekeyed, turned into a memory and written while the window waited. The load
    /// now attaches what is there and this runs after it. Returns whether a survey was carried.
    @discardableResult
    public func finishInterruptedSurveyReplay() async -> Bool {
        guard let directory = filingProfilesDirectory, let id = filingProfileDirectoryId,
              let profile = filingFolderProfile else { return false }
        // Counted, not flagged: launch, Setup's re-attach and Undo can each start one, and the
        // first to finish must not clear the guard while another is still carrying.
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

    /// **Reads back a survey a re-derive's replay never finished carrying** (FR17, follow-up).
    ///
    /// A re-derive names the new folder in `profiles.json` before its corpus replay, so a quit in
    /// the replay relaunches onto a folder with no corpus, memory or survey progress, while the
    /// folder it was derived from still holds them — and the retire sweep keeps that folder for
    /// exactly this reason. Nothing read it back: the next refresh replayed from the active
    /// folder and found nothing, so the survey was kept but lost to the app. This finishes the
    /// replay the quit cut off: when the active folder has no corpus, its `derivedFrom` folder's
    /// progress and corpus are carried in through the manifest that turned one into the other —
    /// the ledger record applied under that folder, or none (a survey refresh moves nothing) —
    /// and the memory rebuilt from the rekeyed corpus. Once it is here the sweep may retire the
    /// old folder. The corpus keeps its own `surveyedAt`: nothing was read again.
    ///
    /// A ledger that cannot be read carries nothing, since an unknown landing could have moved
    /// the files the keys name. Returns whether a corpus was carried.
    @discardableResult
    nonisolated static func recoverInterruptedSurveyReplay(into id: String,
                                                           profile: FolderProfile,
                                                           in directory: URL) -> Bool {
        // A stat, not a read: this runs on every load, and the active folder's corpus is
        // normally there and thousands of documents long. Present but unreadable is not absent.
        let here = FilingSurveyStore.corpusURL(id: id, in: directory).path
        guard let parent = profile.derivedFrom, parent != id,
              (try? FileManager.default.attributesOfItem(atPath: here)) == nil else { return false }
        // Stats too: the parent's corpus is decoded once, by the carry, and only when it runs.
        // **And nothing is read when there is nothing to carry** (review C5): a parent with no
        // corpus has only its progress to give, and a folder with progress of its own takes
        // none — the state a stopped first survey leaves — so the ledger is not decoded for it.
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
            // **Only a landing that finished, and the one that made this folder first** (review
            // C4). A record without a `summary` never finalised — a landing cut off before its
            // moves ran, then a second cut — and rekeying through it moved the keys through moves
            // that never happened. Among the finished, the one whose produced folder is this one.
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

    /// **Carries `parent`'s survey into `id`**: a stopped survey's progress, and the corpus —
    /// rekeyed through `landed` and renamed to `id` — with the memory rebuilt from it, keeping the
    /// folder stamps `parent`'s memory recorded under their new names (a folder whose stamp no
    /// longer matches reads as stale to the next survey, which is the safe side). Nothing is read
    /// again, so the corpus keeps its own `surveyedAt`. Does nothing where `id` already has a
    /// corpus. Returns whether a corpus was carried.
    ///
    /// The re-derive's read-back uses it, and so does a Setup walk of a folder whose survey is
    /// already on disk (review C3) — with no moves, since the folder's paths are unchanged.
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

    /// A fresh profile id for a re-derivation — `reorg-<stamp>`, suffixed if the second lands in
    /// the same second, the same discipline `availableWalkProfileId` has.
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

/// **What a landing has done so far, one line per action, written as each one runs** (FR16).
///
/// The ledger record is written before the first move and finalised after the last; nothing in
/// between recorded progress, so a quit, crash or power cut mid-run left a half-applied tree that
/// Undo rightly refuses — pointing at a log that named nothing. Each performed action, collision
/// name included, is appended here as JSON the moment it runs: a plain `write`, no flush per line,
/// so it survives the app dying (the common case) at the cost of the last lines on a power cut.
/// Removed once the record is finalised. `profiles/<id>/restructure-landing-<manifest>.jsonl`.
final class RestructureLandingJournal: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func url(manifestId: String, profileId: String, in directory: URL) -> URL {
        let safe = manifestId.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(profileId)/restructure-landing-\(safe).jsonl")
    }

    /// Nil when the file cannot be made — the landing then runs as it always did, unjournalled.
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
        try? handle.write(contentsOf: line)
    }

    func finish() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops writing and leaves the file where it is — for a landing whose record could not be
    /// finalised, so the journal is still the only list of what ran (FR16).
    func close() {
        try? handle.close()
    }
}
