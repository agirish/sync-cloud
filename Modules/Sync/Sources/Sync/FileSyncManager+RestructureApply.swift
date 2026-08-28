import CryptoKit
import Events
import Foundation

/// §5.5's Apply: one landing, run in the eight steps the roadmap orders, plus the ledger undo
/// that survives a quit. Sits beside `+Restructure` (the scaffold) rather than inside it — the
/// scaffold is the safe subset and reads better unentangled from the destructive engine.
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
        /// The independent verifier's disagreements — reported on the card and in the log, and
        /// never rolled back on their own (invariant 6).
        public var verifierMismatches: [String] = []
        public var producedProfileId: String?
        /// §5.7's third sentence: the landing ran but the survey could not be refreshed.
        public var surveyRefreshFailure: String?
        public var refusal: String?

        public init() {}

        /// The ledger sentence — derived from what happened, never pasted.
        public var summary: String {
            var parts = ["\(renamed) rename\(renamed == 1 ? "" : "s")",
                         "\(filesMoved) moved"]
            if foldersMovedWhole > 0 { parts.append("\(foldersMovedWhole) folders carried whole") }
            if created > 0 { parts.append("\(created) created") }
            if removedEmpty > 0 { parts.append("\(removedEmpty) emptied folders removed") }
            if collisions > 0 {
                parts.append("\(collisions) name collision\(collisions == 1 ? "" : "s"), both kept")
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
        defer { restructureLandingInProgress = false }
        guard let store = restructureStore, let profile = filingFolderProfile,
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
        guard store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest, inverse: manifest.inverse, at: stamp, created: 0, skipped: 0,
            appliedUnderProfileId: oldDirectoryId)) else {
            outcome.refusal = "The ledger could not be written, so nothing was moved — a "
                + "reorganisation only runs once its inverse is safely on disk. Check "
                + "restructure.json's folder is writable."
            return outcome
        }

        // Step 3: the operations, re-probing every claim at the moment of the action.
        let expandedRoot = (profile.root as NSString).expandingTildeInPath
        let fm = fileManager
        let actions = manifest.actions
        let execution: RestructureExecution = await enqueueFileOperation {
            FileSyncManager.executeRestructureActions(actions, root: expandedRoot, fm: fm)
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
        outcome.verifierMismatches = FileSyncManager.verifyRestructureLanding(
            execution.performed, root: expandedRoot, fm: fm)

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
                registerCreateFolderUndo(url: url)
            }
            let actionName = "Reorganise \(RestructurePaths.familyLabel(manifest.family))"
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
                + "session ⌘Z cleared; Undo This Reorganisation is the way back")
        }

        // The manifest as it actually landed: performed actions only, with collision names,
        // bytes and digests. The inverse is recomputed from THAT — the inverse of the plan would
        // move files back from names they never landed at.
        var landed = manifest
        landed.actions = execution.performed
        store.updateApplied(manifestId: manifest.manifestId) {
            $0.manifest = landed
            $0.inverse = landed.inverse
            $0.created = execution.created
            $0.skipped = execution.skipped.count
            $0.summary = outcome.summary
        }

        // Step 6: re-derive the profile from a fresh walk — the finding is gone because the tree
        // was re-read, never because it was marked done. A failure here is §5.7's third sentence,
        // not a rollback: the moves landed and the ledger records them.
        let rootURL = URL(fileURLWithPath: expandedRoot)
        let tree = await Self.buildTree(url: rootURL, sortOption: .name)
        let newId = FileSyncManager.availableReorgProfileId(now: now, in: profilesDirectory)
        let registry = PersonRegistry.seeded(from: profile)
        let jurisdictions = RestructureRederive.entryJurisdictions(of: profile)
        let recordedRoot = profile.root
        let fresh = await Task.detached(priority: .userInitiated) {
            FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: newId,
                                      registry: registry, jurisdictionValues: jurisdictions)
        }.value
        let derived = RestructureRederive.carryOver(from: profile, into: fresh, through: landed)
            .settingDerivedFrom(oldDirectoryId)
        do {
            try FilingProfileStore.writeDerivedProfile(derived, replacing: oldDirectoryId,
                                                       in: profilesDirectory, now: now)
        } catch {
            outcome.surveyRefreshFailure = "Applied; the survey could not be refreshed — "
                + String(describing: error)
            store.updateApplied(manifestId: manifest.manifestId) {
                $0.summary = outcome.summary + " — survey not refreshed"
            }
            Logger.shared.warning("Restructure apply \(manifest.manifestId): landed, but the "
                + "profile re-derivation failed: \(error)")
            return outcome
        }
        outcome.producedProfileId = newId

        // Step 7: the per-profile artifacts follow the profile into its new directory — copied
        // as they stand, then the corpus keys replayed and the memory rebuilt from them. No page
        // is re-read for a file that only moved.
        FileSyncManager.carryProfileArtifacts(from: oldDirectoryId, to: newId,
                                              in: profilesDirectory, fm: fm)
        if let corpus = FilingSurveyStore.corpus(id: oldDirectoryId, in: profilesDirectory) {
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
                                            in: profilesDirectory, root: recordedRoot, now: now)
                filingMemory = memory
                filingSurveyedAt = now
            } catch {
                Logger.shared.warning("Restructure apply \(manifest.manifestId): the replayed "
                    + "corpus could not be written under \(newId): \(error)")
            }
        }

        // The new directory is the active one now: every store re-opens there, the finding cache
        // drops with the profile publish, and the fingerprint moves — which invalidates every
        // cached verdict, correctly, because they name paths that just changed.
        filingFolderProfile = derived
        filingProfileDirectoryId = newId
        let newStore = RestructureStore(directory: profilesDirectory, profileId: newId)
        newStore.rekey(renames: RestructureRederive.renameMap(of: landed),
                       context: manifest.manifestId)
        // The artifact carry copies best-effort, one file at a time — if restructure.json was
        // the copy that failed, the fresh store loads empty and the update below would no-op
        // silently, stranding the finalised record (and its inverse) in a directory nothing
        // reads. The ledger record is not best-effort: write it into the new store directly.
        if !newStore.applied.contains(where: { $0.manifest.manifestId == manifest.manifestId }),
           let finalised = store.applied.first(where: {
               $0.manifest.manifestId == manifest.manifestId
           }) {
            newStore.recordApplied(finalised)
            Logger.shared.warning("Restructure apply \(manifest.manifestId): restructure.json "
                + "did not carry over; the ledger record was written into \(newId) directly")
        }
        newStore.updateApplied(manifestId: manifest.manifestId) {
            $0.producedProfileId = newId
        }
        restructureStore = newStore
        filingPeopleStore = PeopleStore(directory: profilesDirectory, profileId: newId,
                                        profile: derived)
        filingPersonTagStore = PersonTagStore(directory: profilesDirectory, profileId: newId)
        filingArtifactFingerprint = FilingProfileStore.fingerprint(id: newId,
                                                                   in: profilesDirectory)
        // The OLD store keeps the finalised record too — it is the ledger Undo reads after the
        // re-point puts that directory back in charge.
        store.updateApplied(manifestId: manifest.manifestId) {
            $0.producedProfileId = newId
        }

        // Step 8: one greppable line — the truth of an apply gets found later by this id.
        Logger.shared.info("Restructure apply \(manifest.manifestId): \(manifest.family) — "
            + "\(outcome.summary); verifier "
            + (outcome.verifierMismatches.isEmpty ? "OK"
               : "MISMATCH (\(outcome.verifierMismatches.count))")
            + "; profile \(oldDirectoryId) → \(newId)")
        return outcome
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
        guard let store = restructureStore, let profilesDirectory = filingProfilesDirectory else {
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
            outcome.refusal = "This reorganisation was already undone (\(record.undoneAt ?? ""))."
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
            outcome.refusal = "A later reorganisation sits on top of this one — undo that one "
                + "first, newest first, the way ⌘Z would."
            return outcome
        }
        // A record without a summary never finalised: the app quit mid-apply, and the stored
        // inverse is the PLAN's — collision names never recorded — so replaying it could move
        // the wrong file. Refusing is the only honest answer; the log from that run names what
        // actually landed.
        guard record.summary != nil else {
            outcome.refusal = "This landing never finished recording what it did — the app "
                + "quit mid-apply — so its stored inverse may not match the disk and will not "
                + "be replayed. The log from that run (\(manifestId)) names what landed."
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

        let expandedRoot = ((filingFolderProfile?.root ?? "~") as NSString).expandingTildeInPath
        let fm = fileManager
        let actions = record.inverse.actions
        let execution: RestructureExecution = await enqueueFileOperation {
            FileSyncManager.executeRestructureActions(actions, root: expandedRoot, fm: fm,
                                                      vetoUnlistedSourceFolders: false)
        }
        outcome.renamed = execution.renamed
        outcome.filesMoved = execution.filesMoved
        outcome.foldersMovedWhole = execution.foldersMovedWhole
        outcome.created = execution.created
        outcome.collisions = execution.collisions
        outcome.removedEmpty = execution.removedEmpty
        outcome.skipped = execution.skipped
        outcome.verifierMismatches = FileSyncManager.verifyRestructureLanding(
            execution.performed, root: expandedRoot, fm: fm)
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

        if let loaded = FilingProfileStore.active(in: profilesDirectory) {
            filingFolderProfile = loaded.profile
            filingMemory = loaded.memory
            filingProfileDirectoryId = loaded.id
            let restoredStore = RestructureStore(directory: profilesDirectory,
                                                 profileId: loaded.id)
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
            filingSurveyedAt = FilingSurveyStore.surveyedAt(id: loaded.id, in: profilesDirectory)
        }
        outcome.producedProfileId = previousId
        Logger.shared.info("Restructure undo \(manifestId): \(outcome.summary); verifier "
            + (outcome.verifierMismatches.isEmpty ? "OK"
               : "MISMATCH (\(outcome.verifierMismatches.count))")
            + "; profile re-pointed to \(previousId)")
        return outcome
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
        /// The actions that ran, with `collidedInto`, `bytes` and `md5` filled from the disk.
        var performed: [RestructureManifest.Action] = []
        /// Directory renames — registered for ⌘Z as their OWN batch, before the content moves,
        /// so undo pops the moves first: a file must leave `Forms/` before `Forms/` stops
        /// existing under that name.
        var renameItems: [(from: URL, to: URL)] = []
        var moveItems: [(from: URL, to: URL, overwritten: URL?)] = []
        var createdURLs: [URL] = []
    }

    /// How many visible FILES sit anywhere beneath `path` — empty directories and dotfiles do
    /// not count as contents. This is the removal step's definition of "still empty": a drained
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
        // The walk descends everywhere; only files whose own name is dotted are ignorable —
        // the same junk class (.DS_Store) the shallow probe always ignored — because a hidden
        // directory's contents are content, however its container is named.
        var sawError = false
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [],
                                         errorHandler: { _, _ in sawError = true; return false })
        else { return nil }
        var files = 0
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir && !url.lastPathComponent.hasPrefix(".") { files += 1 }
        }
        return sawError ? nil : files
    }

    /// The audit digest for one moved file — bounded, and never a download trigger. A dataless
    /// (cloud-only) placeholder is skipped before any byte is read, because opening one forces
    /// the provider to fetch the whole file mid-landing — a multi-GB stall between the ledger
    /// write and the finalize, exactly the window where a force-quit mints the
    /// "never finished recording" record. Files over `cap` are skipped too (streamed hashing
    /// still holds the landing for their full read), and the digest is audit-only — nothing
    /// verifies it — so nil loses a nicety, not a safety.
    nonisolated static func restructureDigest(atPath path: String, size: Int?,
                                              cap: Int = 64 << 20) -> String? {
        guard !MaterializationStatus.isCloudOnly(atPath: path) else { return nil }
        if let size, size > cap { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        do {
            // A read ERROR is not the end of the file: finalising what came before it would
            // record a truncated prefix's hash as the file's digest — and a wrong digest
            // misleads the exact audit the field exists for. nil is the honest shape, the same
            // one cloud-only and over-cap files already wear.
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One directory level's entry names, through the protocol's own enumerator — the listing
    /// the unlisted-file rule re-runs at the moment of the action.
    /// (`FileManaging` has no `contentsOfDirectory`; adding one strands every test double.)
    nonisolated static func directoryNames(at path: String, fm: FileManaging) -> [String] {
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsSubdirectoryDescendants],
                                         errorHandler: nil) else { return [] }
        var names: [String] = []
        for case let url as URL in walker { names.append(url.lastPathComponent) }
        return names
    }

    /// Runs the actions in order against the real tree, re-probing every `src` and `dst`
    /// immediately before each one (invariant 5). A folder holding a file the manifest never
    /// listed is skipped whole and reported, and the rest of the plan runs (invariant 2); a taken
    /// destination gets a unique name and a collision fact, never an overwrite.
    nonisolated static func executeRestructureActions(
        _ actions: [RestructureManifest.Action], root: String, fm: FileManaging,
        vetoUnlistedSourceFolders: Bool = true)
        -> RestructureExecution {
        var out = RestructureExecution()
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
            let listed = FileSyncManager.directoryNames(at: absolute(parent), fm: fm)
            let unlisted = listed.filter { !$0.hasPrefix(".") }
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

        for action in actions {
            switch action.action {
            case .keep:
                out.performed.append(action)

            case .createDir:
                guard let dst = action.dst else { continue }
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
                let srcPath = absolute(src), dstPath = absolute(dst)
                guard fm.fileExists(atPath: srcPath) else {
                    out.skipped.append("\(src)/ is no longer there — its rename was skipped")
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
                    continue
                }
                do {
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: URL(fileURLWithPath: dstPath),
                                                    fileManager: fm)
                    out.renamed += 1
                    out.renameItems.append((from: URL(fileURLWithPath: srcPath),
                                            to: URL(fileURLWithPath: dstPath)))
                    out.performed.append(action)
                } catch {
                    out.skipped.append("\(src)/ could not be renamed: \(error.localizedDescription)")
                }

            case .moveFile:
                guard let src = action.src, let dst = action.dst else { continue }
                let parent = (src as NSString).deletingLastPathComponent
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
                    // Bytes and digest are recorded NOW, from the disk (invariant 5) — before
                    // the move, while the source path is still the one the manifest names.
                    // (The re-probe window above is real but bounded: a file APPEARING at the
                    // destination between the probe and the move is replaced by `safeMoveItem`,
                    // which trashes the old copy and logs — recoverable, never silent.)
                    let attributes = try? fm.attributesOfItem(atPath: srcPath)
                    performed.bytes = attributes?[.size] as? Int
                    performed.md5 = FileSyncManager.restructureDigest(atPath: srcPath,
                                                                      size: performed.bytes)
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: destination, fileManager: fm)
                    out.filesMoved += 1
                    out.moveItems.append((from: URL(fileURLWithPath: srcPath),
                                          to: destination, overwritten: nil))
                    out.performed.append(performed)
                } catch {
                    out.skipped.append("\(src) could not be moved: \(error.localizedDescription)")
                }

            case .moveDir:
                guard let src = action.src, let dst = action.dst else { continue }
                let parent = (src as NSString).deletingLastPathComponent
                if let covering = vetoedAncestor(of: parent) {
                    out.skipped.append("\(src)/ sits under \(covering)/ — left untouched with it")
                    continue
                }
                guard !sourceFolderVeto(parent) else { continue }
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
                guard !fm.fileExists(atPath: dstPath) else {
                    out.skipped.append("\(dst)/ appeared since the plan — \(src)/ was kept "
                        + "rather than merged unreviewed")
                    continue
                }
                do {
                    try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: srcPath),
                                                    to: URL(fileURLWithPath: dstPath),
                                                    fileManager: fm)
                    out.foldersMovedWhole += 1
                    out.moveItems.append((from: URL(fileURLWithPath: srcPath),
                                          to: URL(fileURLWithPath: dstPath), overwritten: nil))
                    out.performed.append(action)
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
        return out
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
    nonisolated static func carryProfileArtifacts(from oldId: String, to newId: String,
                                                  in directory: URL, fm: FileManaging) {
        for name in ["people.json", "person-tags.json", "restructure.json"] {
            let source = directory.appendingPathComponent("\(oldId)/\(name)")
            let target = directory.appendingPathComponent("\(newId)/\(name)")
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                Logger.shared.warning("Restructure: could not carry \(name) to \(newId): "
                    + error.localizedDescription)
            }
        }
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
