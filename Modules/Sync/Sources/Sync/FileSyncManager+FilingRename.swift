import Events
import Foundation

/// The rename pass: Organize's answer to what a file is called once it lands.
///
/// The house convention `NN. Mon YYYY.pdf` is applied by hand, so it decays. This finds every
/// folder that has drifted from its own convention and offers to bring it back, on the walk the
/// Filing scan already does. Mirrors +NameNormalize: a pure detector over a tree already in memory,
/// and an apply path through the serial `enqueueFileOperation` queue as one grouped undo.
extension FileSyncManager {

    // MARK: Scan

    /// Builds a rename plan for every folder under a tree the caller has already walked. No second
    /// walk or button: the Filing scan already reads the whole provider, and ``RenamePlanner`` is
    /// pure, so the backlog comes back on that pass for free. Detached, like the names detector:
    /// planning thousands of folders inline would block the main actor.
    func detectRenamePlans(in tree: [FileNode], root: URL,
                           isCancelled: @Sendable () -> Bool = { Task.isCancelled }) async {
        // The names detector's wall: an unreadable root walks back as one marker carrying the
        // root's own path, and planning renames for a folder we can't list is the worst thing this
        // feature could do with it.
        if Self.isUnreadableRootMarker(tree, root: root) {
            renamePlans = []
            Logger.shared.warning("Filing scan: could not read \(root.lastPathComponent) — permission denied; no renames planned")
            return
        }
        // Snapshotted on the main actor and handed in, because the planner runs off it.
        let profile = filingFolderProfile
        let rootPath = root.path

        let plans = await Task.detached(priority: .userInitiated) {
            Self.planRenames(in: tree, rootPath: rootPath, profile: profile)
        }.value
        if isCancelled() { return }

        renamePlans = plans
        let steps = plans.reduce(0) { $0 + $1.steps.count }
        Logger.shared.info("Filing scan planned \(steps) rename(s) across \(plans.count) folder(s) under \(root.lastPathComponent)")
    }

    /// Every non-empty folder plan under a walked tree. Pure and nonisolated, so the detector can
    /// be detached.
    ///
    /// A plan is kept when it has steps. One with only skips is dropped: a skip explains a rename
    /// that didn't happen, and with no rename beside it there is nothing to explain. The
    /// incoming-file path, which does want "no month in the name" for its one file, calls
    /// ``RenamePlanner`` directly.
    nonisolated static func planRenames(in tree: [FileNode], rootPath: String,
                                        profile: FolderProfile?) -> [RenamePlan] {
        var plans: [RenamePlan] = []
        func visit(_ nodes: [FileNode], folderPath: String, relativePath: String) {
            let files = nodes.filter { !$0.isDirectory }
                .map { FolderFile(path: $0.id, name: $0.name) }
            if !files.isEmpty, !relativePath.isEmpty {
                let plan = RenamePlanner.plan(
                    folderPath: folderPath, relativePath: relativePath, files: files,
                    entry: profile?.folders[relativePath])
                if !plan.isEmpty { plans.append(plan) }
            }
            for dir in nodes where dir.isDirectory {
                visit(dir.children ?? [], folderPath: dir.id,
                      relativePath: relativePath.isEmpty ? dir.name : relativePath + "/" + dir.name)
            }
        }
        visit(tree, folderPath: rootPath, relativePath: "")
        return plans
    }

    /// The one way to put plans on screen from outside the module, as with
    /// `publishFilingSuggestions`: `renamePlans` is `internal(set)` so the only producer is the
    /// planner over a fresh walk, and `FileExplorer`'s render tests still need a lens with results.
    public func publishRenamePlans(_ plans: [RenamePlan]) {
        renamePlans = plans
    }

    /// Clears the results. Called by ``clearLensResultsForProviderSwitch()`` with the other lens
    /// findings: a plan names absolute paths under one provider and means nothing under another.
    public func clearRenamePlans() {
        renamePlans = []
    }

    // MARK: Naming a file on the way in

    /// The name `fileName` would take once it lands in `folderPath`, or nil to keep the name it has.
    ///
    /// The same planner the backlog pass runs, handed the file as `incoming`, so the two can't
    /// disagree: a file renamed on the way in and then flagged by the backlog pass would be the app
    /// arguing with itself.
    nonisolated static func incomingName(for fileName: String, into folderPath: String,
                                         relativePath: String, folderFiles: [FolderFile],
                                         profile: FolderProfile?) -> String? {
        let incoming = FolderFile(path: folderPath + "/" + fileName, name: fileName)
        let plan = RenamePlanner.plan(folderPath: folderPath, relativePath: relativePath,
                                      files: folderFiles, entry: profile?.folders[relativePath],
                                      incoming: incoming)
        guard let step = plan.steps.first(where: { $0.currentPath == incoming.path }) else { return nil }
        // A name that only works if its neighbours move is not one this path may offer. Under
        // position numbering, a file arriving before the months already there takes slot 01 and
        // pushes the rest up, and the planner puts all those steps in one cohort. Taking only the
        // placement out of it is the half-applied cascade the cohort prevents: a February bill
        // filed into `01. Mar · 02. Apr · 03. May` would land as `01. Feb` beside `01. Mar`.
        //
        // Filing one file is not the moment to renumber a folder, so the file keeps its own name;
        // the backlog pass proposes the renumbering, reviewed as the folder-wide change it is.
        guard step.cohort == 0 else { return nil }
        return step.proposedName
    }

    /// Fills in ``FilingDestination/proposedName`` for every candidate of every suggestion, from
    /// the taxonomy tree the scan already walked. Every candidate, not just the best: "Try another"
    /// swaps the shown home without a rescan, and a card keeping the first home's name would offer
    /// a slot in a folder the file is no longer going to.
    nonisolated static func namingSuggestions(_ suggestions: [FilingSuggestion],
                                              taxonomy: [FileNode], rootPath: String,
                                              profile: FolderProfile?) -> [FilingSuggestion] {
        var filesByFolder: [String: [FolderFile]] = [:]
        // Folders the walk couldn't list. `buildTree` reports a permission-denied or depth-capped
        // directory as `children: []` with `isUnexplored`, which looks like an empty folder unless
        // the flag is carried, and reading it as empty proposes slot 01 for a folder holding twelve
        // months. The apply path re-derives from disk, so the harm is a card promising a name the
        // user won't get; this keeps the card silent instead.
        var unlisted: Set<String> = []
        func index(_ nodes: [FileNode], folderPath: String) {
            filesByFolder[folderPath] = nodes.filter { !$0.isDirectory }
                .map { FolderFile(path: $0.id, name: $0.name) }
            for dir in nodes where dir.isDirectory {
                if dir.isUnexplored == true { unlisted.insert(dir.id) }
                index(dir.children ?? [], folderPath: dir.id)
            }
        }
        index(taxonomy, folderPath: rootPath)

        return suggestions.map { suggestion in
            let named = suggestion.candidates.map { dest -> FilingDestination in
                // A destination whose folders don't exist yet has no files and no convention to
                // read, so it never proposes a rename.
                guard dest.newSegments.isEmpty, !unlisted.contains(dest.path),
                      let rel = FileSyncManager.relativePath(dest.path, under: rootPath)
                else { return dest }
                return dest.naming(incomingName(for: suggestion.fileName, into: dest.path,
                                                relativePath: rel,
                                                folderFiles: filesByFolder[dest.path] ?? [],
                                                profile: profile))
            }
            return suggestion.replacingCandidates(named)
        }
    }

    /// The name to file `suggestion` under in `destination`, re-derived against the disk now. The
    /// scan's proposal describes the folder as it was minutes ago, and the tree is edited while a
    /// queue is open: one directory read is the difference between taking slot 04 and taking a slot
    /// someone just filled. A folder that can't be listed falls back to the file's own name, never
    /// to a stale slot number.
    nonisolated static func liveIncomingName(for fileName: String, destination: String,
                                             providerRoot: String?, profile: FolderProfile?,
                                             fileManager fm: FileManaging) -> String? {
        guard let providerRoot,
              let rel = FileSyncManager.relativePath(destination, under: providerRoot),
              let live = liveFiles(in: URL(fileURLWithPath: destination), fileManager: fm)
        else { return nil }
        return incomingName(for: fileName, into: destination, relativePath: rel,
                            folderFiles: live, profile: profile)
    }

    // MARK: Apply

    /// What one pass over the plans did, as the queued closure hands it back. A struct because the
    /// counts aren't independent: an abandoned cohort's files are neither `failed` (only one threw)
    /// nor `stale` (the disk still described them), and `stranded` must reach the user loudest.
    struct RenameApplyOutcome: Sendable {
        var moves: [MoveItemState] = []
        var doneFolders: [String] = []
        /// Steps the fresh plan no longer proposes.
        var stale = 0
        /// Independent steps whose move threw. One file each, and nothing else is affected.
        var failed = 0
        /// Files in a renumbering that was rolled back: the whole cohort, not just the member that
        /// threw, because none of them ends up renamed.
        var abandoned = 0
        /// Files in an abandoned cohort that could not be put back. The dangerous residue: the only
        /// way a partly applied renumbering can still be on disk when this returns.
        var stranded = 0
    }

    /// Applies whole folder plans in one undoable pass.
    ///
    /// Every claim is re-derived against the disk before anything moves. A plan describes a folder
    /// as it was when the scan ran, and the tree is edited meanwhile (by the user, a sync, another
    /// session), so this re-lists each folder inside the operation queue and re-runs
    /// ``RenamePlanner``; a step survives only if the fresh plan proposes the same rename for the
    /// same file. A folder that changed underneath contributes fewer steps, and says so.
    ///
    /// The unit of apply is the cohort, not the plan. A padding fix is right on its own; a
    /// renumbering is not, so if one of its steps no longer describes the folder the whole cohort
    /// stands down, the rule `RenamePlanner/withoutCollisions(_:among:skips:)` applies at plan time.
    ///
    /// It holds while the moves run too: the re-derive can't promise four moves will all succeed,
    /// and a busy iCloud placeholder can make `safeMoveItem` throw mid-cohort. A cohort is applied
    /// into a buffer and rolled back the moment a member throws, so the folder ends at the full new
    /// numbering or the one it started with, never two files on one slot, and the banner and log
    /// say which.
    public func applyRenamePlans(_ plans: [RenamePlan]) async {
        // Verify All's write-exclusion guard, as in `normalizeNames`: a rename moves a file Verify
        // All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before renaming", log: .warn)
            return
        }
        guard !plans.isEmpty, !isApplyingRenames else { return }
        isApplyingRenames = true
        defer { isApplyingRenames = false }

        let fm = fileManager
        let profile = filingFolderProfile
        let logger = Logger.shared

        // Does this folder's volume distinguish names by case? Asked once per folder, here on the
        // main actor, because the queued closure needs a plain `Sendable` value, and through the
        // seam `syncAll` uses, so a test can drive both kinds of volume.
        //
        // The one answer feeds both the never-overwrite guard below and the `safeMoveItem` under
        // it. The guard runs first and can pre-empt the move, so a guard that folds case while the
        // move doesn't (or the reverse) would disagree about whether the destination is another file.
        let probeCaseSensitivity = destinationCaseSensitivity
        var caseSensitiveByFolder: [String: Bool] = [:]
        for plan in plans where caseSensitiveByFolder[plan.folderPath] == nil {
            caseSensitiveByFolder[plan.folderPath] =
                probeCaseSensitivity(URL(fileURLWithPath: plan.folderPath))
        }
        let caseSensitivity = caseSensitiveByFolder

        let result: RenameApplyOutcome = await enqueueFileOperation {
            var out = RenameApplyOutcome()

            for plan in plans {
                let dir = URL(fileURLWithPath: plan.folderPath)
                // Re-derive: what does this folder look like right now?
                guard let live = Self.liveFiles(in: dir, fileManager: fm) else {
                    out.stale += plan.steps.count
                    continue
                }
                let caseSensitive = caseSensitivity[plan.folderPath] ?? false
                let fresh = RenamePlanner.plan(folderPath: plan.folderPath,
                                               relativePath: plan.relativePath,
                                               files: live,
                                               entry: profile?.folders[plan.relativePath])
                // A step is applied only if the folder as it stands still asks for exactly it.
                let stillProposed = Set(fresh.steps.map { $0.currentPath + "\u{0}" + $0.proposedName })
                func survives(_ step: RenameStep) -> Bool {
                    stillProposed.contains(step.currentPath + "\u{0}" + step.proposedName)
                }
                // A renumbering is all-or-nothing, here as in the planner. If the folder moved in a
                // way that invalidates one step of a cascade, the survivors would collapse two
                // months onto one slot, so the whole cohort stands down.
                let brokenCohorts = Set(plan.steps.filter { $0.cohort != 0 && !survives($0) }
                                                  .map(\.cohort))
                let runnable = plan.steps.filter { survives($0) && !brokenCohorts.contains($0.cohort) }
                out.stale += plan.steps.count - runnable.count

                // The units of execution: a cohort-0 step stands alone (a padding fix is right
                // whatever its neighbours do), and steps sharing a non-zero cohort travel as one.
                // Cohorts are ordered by id so a folder with two (a `.csv` cascade and a `.pdf` one)
                // applies in the same order every run.
                var units: [(cohort: Int, steps: [RenameStep])] = []
                var byCohort: [Int: [RenameStep]] = [:]
                for step in runnable {
                    if step.cohort == 0 { units.append((0, [step])) }
                    else { byCohort[step.cohort, default: []].append(step) }
                }
                // All cohort-0 steps run before any cohort, whatever order `plan.steps` had. Safe for
                // the planner reason the rollback relies on: a cohort-0 step only widens an ordinal it
                // already holds, so it neither frees nor takes a name any cohort member targets.
                for id in byCohort.keys.sorted() { units.append((id, byCohort[id]!)) }

                var appliedHere = false
                for unit in units {
                    var applied: [MoveItemState] = []
                    var failure: (step: RenameStep, error: Error)?
                    for step in unit.steps {
                        let src = URL(fileURLWithPath: step.currentPath)
                        var dst = dir.appendingPathComponent(step.proposedName)
                        // Already there under exactly this name: nothing to move.
                        if src.standardizedFileURL.path == dst.standardizedFileURL.path { continue }
                        // Never overwrite. The planner already refuses a contended target, so
                        // reaching here means the disk changed between the re-derive and the move:
                        // keep both rather than lose one.
                        //
                        // Unless the occupant is the source itself. `07. jul 2016.pdf` →
                        // `07. Jul 2016.pdf` is a real rename, and on a case-insensitive volume
                        // `fileExists` finds the source under the folded name; treating that as a
                        // collision would land `07. Jul 2016 2.pdf`, a duplicate marker the next
                        // scan preserves forever. `safeMoveItem` does a case-only rename correctly,
                        // so this guard asks the same helper. When the probe can't answer it says
                        // "folds case", the safe direction: at worst this hands the move to
                        // `safeMoveItem`, which refuses a genuinely occupied destination.
                        if fm.fileExists(atPath: dst.path),
                           !Self.isCaseOnlyRenaming(source: src, destination: dst,
                                                    caseSensitiveVolume: caseSensitive) {
                            dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                        }
                        do {
                            let overwritten = try FileSyncManager.safeMoveItem(
                                at: src, to: dst, fileManager: fm, caseSensitiveVolume: caseSensitive)
                            applied.append((from: src, to: dst, overwritten: overwritten))
                        } catch {
                            failure = (step, error)
                            break
                        }
                    }

                    guard let failure else {
                        out.moves.append(contentsOf: applied)
                        if !applied.isEmpty { appliedHere = true }
                        continue
                    }
                    logger.warning("Rename pass: “\(failure.step.currentName)” → “\(failure.step.proposedName)” failed: \(failure.error.localizedDescription)")
                    guard unit.cohort != 0 else {
                        // An independent step: nothing else depended on it, so nothing else moves.
                        // Undoing the padding fixes that worked because a third failed would make
                        // the pass useless on most of the backlog.
                        out.failed += 1
                        continue
                    }

                    // Put back what this cohort already moved, newest first. Every name restored
                    // was vacated by this loop moments ago and no other member targets it, so the
                    // folder returns to exactly the numbering it had.
                    //
                    // That last clause is a planner property. `RenamePlanner.withoutCollisions`
                    // refuses two steps wanting one target, but says nothing about a step's target
                    // being another's source, which a cascade looks like (01→02 beside 02→03). What
                    // holds it: each member's name is `d.parsed.canonicalName(ordinal: target)`,
                    // keeping the file's own body or rebuilding a bare month-and-year body for its
                    // own `MonthKey` (`OrdinalMonthName.body(month:year:)`). Members carry different
                    // keys, so a cascade shifts ordinals while bodies stay put: `02. Jan 2025.pdf`
                    // and `02. Feb 2025.pdf` are different names. A non-month ordinal scheme, where
                    // two members could share a body, would break this, and the forward loop would
                    // start minting " 2" names through `generateUniqueURL`.
                    var putBack = 0
                    var stranded: [MoveItemState] = []
                    for move in applied.reversed() {
                        // Someone else took the old name meanwhile: putting the file back would
                        // replace theirs. Leave it and say so. A file stranded under a new name is
                        // plainly visible, while the stranger's recovery would be a `.rollback_`
                        // backup or a Trash item the user must know to look for (`safeMoveItem`
                        // replaces atomically with a backup, which `finalizeReplacementBackup`
                        // prefers to put in the Trash).
                        guard !Self.rollbackTargetIsOccupied(
                            movedTo: move.to, puttingBackTo: move.from,
                            fileManager: fm, caseSensitiveVolume: caseSensitive) else {
                            stranded.append(move)
                            logger.error("Rename pass: could not put “\(move.to.lastPathComponent)” back — “\(move.from.lastPathComponent)” is occupied again in \(plan.folderPath)")
                            continue
                        }
                        do {
                            _ = try FileSyncManager.safeMoveItem(
                                at: move.to, to: move.from, fileManager: fm,
                                caseSensitiveVolume: caseSensitive)
                            putBack += 1
                        } catch {
                            stranded.append(move)
                            logger.error("Rename pass: could not put “\(move.to.lastPathComponent)” back to “\(move.from.lastPathComponent)” in \(plan.folderPath): \(error.localizedDescription)")
                        }
                    }
                    // A file the rollback couldn't move stays under its new name, so it stays in
                    // the undo group: ⌘Z is the user's remaining way back.
                    out.moves.append(contentsOf: stranded)
                    if !stranded.isEmpty { appliedHere = true }
                    out.abandoned += unit.steps.count
                    out.stranded += stranded.count
                    let folder = plan.relativePath.isEmpty ? plan.folderPath : plan.relativePath
                    logger.warning("Rename pass: the renumbering of \(unit.steps.count) file(s) in \(folder) was abandoned after “\(failure.step.currentName)” failed — \(putBack) file(s) put back\(stranded.isEmpty ? "" : ", \(stranded.count) left under the new name")")
                }
                if appliedHere { out.doneFolders.append(plan.folderPath) }
            }
            return out
        }

        guard !result.moves.isEmpty else {
            if result.failed > 0 || result.stale > 0 || result.abandoned > 0 {
                banner = .warning(Self.renameOutcome(renamed: 0, stale: result.stale,
                                                     failed: result.failed,
                                                     abandoned: result.abandoned,
                                                     stranded: result.stranded), log: .warn)
            }
            return
        }

        // One grouped undo for the whole pass, as the name normalizer registers one.
        let n = result.moves.count
        registerMoveUndo(items: result.moves, actionName: "Rename \(CountedNoun.phrase(n, "File"))",
                         fileManager: fm)

        // Drop the folders that were fully or partly applied: their paths are stale either way,
        // and the next scan republishes whatever is left.
        let done = Set(result.doneFolders)
        renamePlans.removeAll { done.contains($0.folderPath) }

        Logger.shared.info("Rename pass: renamed \(n) file(s)\(result.stale > 0 ? ", \(result.stale) stale" : "")\(result.failed > 0 ? ", \(result.failed) failed" : "")\(result.abandoned > 0 ? ", \(result.abandoned) in a rolled-back renumbering" : "")")
        let message = Self.renameOutcome(renamed: n, stale: result.stale, failed: result.failed,
                                         abandoned: result.abandoned, stranded: result.stranded)
        // `undoable:` on both severities. Every outcome here renamed something and registered an
        // undo above, and the flag is what shows the banner's Undo button and what
        // `invalidateUndoableBanner` reads to retire it once the undo stack moves on; unflagged,
        // the banner would outlive its step and offer ⌘Z for a later operation. Severity and
        // undoability are separate: a pass that renamed some files and left others is a warning
        // and undoable. The `renamed: 0` branch above stays unflagged.
        banner = (result.failed > 0 || result.stale > 0 || result.abandoned > 0)
            ? .warning(message, undoable: true, log: .warn) : .success(message, undoable: true)
    }

    /// The banner sentence for a finished pass. Pure and static so the wording, including what it
    /// says about files it didn't touch, is testable without a filesystem.
    ///
    /// `abandoned` describes a group, so it isn't folded into `failed`: only one member of a
    /// rolled-back renumbering threw, and reporting four failures for one error is as wrong as
    /// reporting one. `stranded` must never be silent: a file the rollback couldn't put back is the
    /// only way a half-applied renumbering survives, so the sentence names it and sends the user
    /// to look.
    static func renameOutcome(renamed: Int, stale: Int, failed: Int,
                              abandoned: Int = 0, stranded: Int = 0) -> String {
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        var tail = ""
        if abandoned > 0 {
            tail = stranded > 0
                ? " A renumbering of \(files(abandoned)) failed part-way and \(files(stranded)) couldn’t be put back — check the folder."
                : " A renumbering of \(files(abandoned)) couldn’t be completed, so the folder was left as it was."
        }
        guard renamed > 0 else {
            if failed > 0 && stale > 0 {
                return "Couldn’t rename \(files(failed)); \(stale) had already changed." + tail
            }
            if failed > 0 { return "Couldn’t rename \(files(failed))." + tail }
            if stale > 0 { return "\(files(stale)) had already changed — nothing renamed." + tail }
            // Nothing renamed, stale or independently failed: the abandoned renumbering is the
            // whole story, and the leading space goes with the joining.
            return tail.isEmpty ? "Nothing renamed." : String(tail.dropFirst())
        }
        var s = "Renamed \(files(renamed))"
        if stale > 0 { s += "; \(stale) had already changed" }
        if failed > 0 { s += "; \(failed) couldn’t be renamed" }
        // No "Press ⌘Z to undo": the result message's Undo button wears the ⌘Z keycap. The opening
        // sentence ends without a period, like every banner's, so the renumbering clause brings one
        // or the two run together.
        return s + (tail.isEmpty ? "" : "." + tail)
    }

    /// The folder's direct files as they stand on disk, or nil when it can't be listed. Through
    /// ``FileManaging`` so the apply path can be driven by the in-memory test double, like every
    /// other write path in the engine.
    nonisolated static func liveFiles(in dir: URL, fileManager fm: FileManaging) -> [FolderFile]? {
        // Through `listing`, not a bare enumerator, which comes back non-nil yielding nothing for a
        // folder it can't read, so an unreadable folder would look empty and get a stale slot
        // number. Anything short of a complete listing is nil: a partial view of a numbered folder
        // is exactly what must not be renumbered against.
        let listing = fm.listing(of: dir, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        guard listing.isComplete else { return nil }
        var files: [FolderFile] = []
        for url in listing.urls {
            // The enumerator can hand back a resolved path; re-root every entry on `dir` so paths
            // compare equal to the ones the plan carries.
            let name = url.lastPathComponent
            let path = dir.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            files.append(FolderFile(path: path, name: name))
        }
        return files
    }
}

extension FileSyncManager {

    /// Whether the name a rolled-back cohort member is being restored to is held by something else.
    ///
    /// A bare `fileExists` folds case on a case-insensitive volume, every default macOS install:
    /// after a case-only move (`07. jul 2016.pdf` → `07. Jul 2016.pdf`) it answers true at the old
    /// spelling, so the member would be declared occupied by itself and stranded under its new name,
    /// with an error naming a stranger that doesn't exist. Asked through
    /// ``isCaseOnlyRenaming(source:destination:caseSensitiveVolume:)``, the helper and probed answer
    /// the forward never-overwrite guard uses, so the two can't disagree.
    ///
    /// Not reachable through today's planner, only by a planner property: a step whose ordinal
    /// doesn't move keeps cohort 0 and is never rolled back, and one whose ordinal moves isn't a
    /// case-only rename. The apply loop enforces none of that, and the rollback tests run on
    /// `MockFileManager`, whose disk is case-sensitive, so this is its own function, provable on
    /// the volume it ships on.
    nonisolated static func rollbackTargetIsOccupied(movedTo: URL, puttingBackTo: URL,
                                                     fileManager: FileManaging,
                                                     caseSensitiveVolume: Bool) -> Bool {
        guard fileManager.fileExists(atPath: puttingBackTo.path) else { return false }
        // The one false positive: what "occupies" the old name is the member itself, under a
        // spelling this volume doesn't distinguish.
        return !isCaseOnlyRenaming(source: movedTo, destination: puttingBackTo,
                                   caseSensitiveVolume: caseSensitiveVolume)
    }
}
