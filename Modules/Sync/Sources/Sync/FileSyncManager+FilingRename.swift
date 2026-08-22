import Events
import Foundation

/// The rename pass (ROADMAP 19) — Organize's answer to *what is this called once it lands*.
///
/// The house convention `NN. Mon YYYY.pdf` is applied by hand, so it decays where the volume is.
/// This finds every folder that has drifted from its own convention and offers to bring it back, on
/// the walk the Filing scan is already doing. Mirrors ``FileSyncManager`` +NameNormalize: a pure
/// detector over a tree that is already in memory, and an apply path routed through the serial
/// `enqueueFileOperation` queue as ONE grouped undo.
extension FileSyncManager {

    // MARK: Scan

    /// Builds a rename plan for every folder under a tree the caller has **already walked**.
    ///
    /// No second walk and no second button, for the same reason the names check folded in here: the
    /// Filing scan already reads the whole provider to learn its folder taxonomy, and
    /// ``RenamePlanner`` is pure, so the backlog comes back on that pass for free.
    ///
    /// Detached, like the names detector — planning 3,032 folders is a real amount of work and it
    /// blocked the main actor for the length of the pass when it ran inline.
    func detectRenamePlans(in tree: [FileNode], root: URL,
                           isCancelled: @Sendable () -> Bool = { Task.isCancelled }) async {
        // The same wall the names detector puts up: an unreadable root walks back as a single
        // marker carrying the root's own path, and planning renames for a folder we cannot list is
        // the worst thing this feature could do with it.
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

    /// Every non-empty folder plan under a walked tree. Pure and nonisolated — the whole reason the
    /// detector can be detached.
    ///
    /// A plan is kept when it has steps to propose. A plan with only *skips* is dropped: a skip is
    /// the explanation for a rename that did not happen, and with no rename beside it there is
    /// nothing to explain. The one exception is the incoming-file path, which asks about a single
    /// named file and therefore does want to hear "no month in the name" — that path calls
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

    /// The one way to put plans on screen from outside the module.
    ///
    /// Exposed for the same reason `publishFilingSuggestions` is: `renamePlans` is `internal(set)`
    /// so the only producer is the planner over a freshly walked tree, and the render tests in
    /// `FileExplorer` still need a lens showing results.
    public func publishRenamePlans(_ plans: [RenamePlan]) {
        renamePlans = plans
    }

    /// Clears the results. Called by ``clearLensResultsForProviderSwitch()`` alongside the other
    /// lens findings — a plan names absolute paths under one provider and means nothing under
    /// another.
    public func clearRenamePlans() {
        renamePlans = []
    }

    // MARK: Naming a file on the way in

    /// The name `fileName` would take once it lands in `folderPath`, or nil to keep the name it has.
    ///
    /// The **same planner** the backlog pass runs, handed the file as `incoming`. Two answers that
    /// could disagree is the failure mode this avoids: a file renamed on the way in and then flagged
    /// by the backlog pass the moment it arrives would be the app arguing with itself.
    nonisolated static func incomingName(for fileName: String, into folderPath: String,
                                         relativePath: String, folderFiles: [FolderFile],
                                         profile: FolderProfile?) -> String? {
        let incoming = FolderFile(path: folderPath + "/" + fileName, name: fileName)
        let plan = RenamePlanner.plan(folderPath: folderPath, relativePath: relativePath,
                                      files: folderFiles, entry: profile?.folders[relativePath],
                                      incoming: incoming)
        guard let step = plan.steps.first(where: { $0.currentPath == incoming.path }) else { return nil }
        // **A name that only works if its neighbours move is not a name this path may offer.**
        //
        // Under position numbering a file arriving before the months already there takes slot 01
        // and pushes every one of them up — the planner says so by putting all four steps in one
        // cohort. Taking the placement out of that cohort and dropping the rest is exactly the
        // half-applied cascade the cohort exists to prevent: measured, filing a February bill into
        // `01. Mar · 02. Apr · 03. May` returned `01. Feb 2021.pdf` and would have left TWO files
        // on slot 01.
        //
        // Filing one file is not the moment to renumber a folder, so this declines and the file
        // keeps its own name. The backlog pass proposes the renumbering separately, where it is
        // reviewed as the folder-wide change it is.
        guard step.cohort == 0 else { return nil }
        return step.proposedName
    }

    /// Fills in ``FilingDestination/proposedName`` for every candidate of every suggestion, using
    /// the taxonomy tree the scan already walked.
    ///
    /// Every candidate, not just the best one: "Try another" swaps the shown home without a rescan,
    /// and a card that kept the first home's proposed name would offer a slot in a folder the file
    /// is no longer going to.
    nonisolated static func namingSuggestions(_ suggestions: [FilingSuggestion],
                                              taxonomy: [FileNode], rootPath: String,
                                              profile: FolderProfile?) -> [FilingSuggestion] {
        var filesByFolder: [String: [FolderFile]] = [:]
        // Folders the walk could not list. `buildTree` reports a permission-denied or depth-capped
        // directory as `children: []` with `isUnexplored`, which is indistinguishable from a
        // genuinely empty folder unless the flag is carried — and reading one as empty proposes
        // slot 01 for a folder that already holds twelve months. The apply path re-derives from the
        // disk and would land the file correctly, so the damage is a card promising a name the user
        // does not get; this keeps the card silent instead.
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
                // A destination whose folders do not exist yet has no files and no convention to
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

    /// The name to file `suggestion` under in `destination`, **re-derived against the disk now**.
    ///
    /// The scan's proposal is a claim about a folder as it was minutes ago, and this tree is edited
    /// while a queue is open. Re-listing costs one directory read on a path already being written
    /// to, and it is the difference between taking slot 04 and taking a slot somebody else just
    /// filled. A folder that cannot be listed falls back to the file's own name — never to a stale
    /// slot number.
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

    /// What one pass over the plans actually did — the value the queued closure hands back.
    ///
    /// A struct rather than a six-element tuple because the counts are no longer independent: an
    /// abandoned cohort's files are neither `failed` (only one of them threw) nor `stale` (the disk
    /// still described them), and `stranded` is the one that has to reach the user loudest.
    struct RenameApplyOutcome: Sendable {
        var moves: [MoveItemState] = []
        var doneFolders: [String] = []
        /// Steps the fresh plan no longer proposes.
        var stale = 0
        /// Independent steps whose move threw. One file each, and nothing else is affected.
        var failed = 0
        /// Files belonging to a renumbering that was rolled back — the whole cohort, not the one
        /// member that threw, because none of them ends up renamed.
        var abandoned = 0
        /// Files inside an abandoned cohort that could NOT be put back. The dangerous residue: the
        /// only way a partially-applied renumbering can still be on disk when this returns.
        var stranded = 0
    }

    /// Applies whole folder plans in one undoable pass.
    ///
    /// **Every claim is re-derived against the disk before anything moves.** A plan is a statement
    /// about a folder as it was when the scan ran, and this tree is edited while a plan is open —
    /// by the user, by a sync, by another session. So rather than trusting the stored steps, this
    /// re-lists each folder inside the operation queue and re-runs ``RenamePlanner`` on what is
    /// actually there; a step survives only if the fresh plan proposes exactly the same rename for
    /// exactly the same file. A folder that changed underneath simply contributes fewer steps, and
    /// says so.
    ///
    /// The unit of apply is the **cohort**, not the whole plan. A padding fix is right on its own,
    /// so a folder that moved under one of them still gets the rest; a renumbering is not, so if any
    /// one of its steps no longer describes the folder the whole cohort stands down. That is the
    /// same rule RenamePlanner/withoutCollisions(_:among:skips:) applies at plan time, enforced
    /// again here because the disk gets its own chance to invalidate a step.
    ///
    /// **And enforced a third time while the moves are RUNNING**, which is where it used to stop.
    /// The re-derive can only refuse a cohort it can see is broken; it cannot promise that four
    /// moves will all succeed. A `safeMoveItem` that throws mid-cohort — a busy iCloud placeholder
    /// is routine on this tree — used to count one failure and carry on with the rest, so inserting
    /// February into `01. Mar · 02. Apr · 03. May` with April's move failing left `02. Mar` and
    /// `02. Apr` both on slot 02: the exact state the cohort exists to prevent, reported as a
    /// partial success. A cohort is now applied into a buffer and **rolled back** the moment one of
    /// its members throws, so the folder ends at the full new numbering or at the one it started
    /// with — never between the two — and the banner and the log say which.
    public func applyRenamePlans(_ plans: [RenamePlan]) async {
        // Verify All's write-exclusion guard, mirrored from `normalizeNames` for the same reason: a
        // rename moves a file Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before renaming")
            return
        }
        guard !plans.isEmpty, !isApplyingRenames else { return }
        isApplyingRenames = true
        defer { isApplyingRenames = false }

        let fm = fileManager
        let profile = filingFolderProfile
        let logger = Logger.shared

        // **Does this folder's volume distinguish names by case?** Asked once per folder, here on
        // the main actor, because the answer has to be a plain `Sendable` value inside the queued
        // closure — and asked through the same seam `syncAll` uses, so a test can drive both kinds
        // of volume on a machine that only has one.
        //
        // The answer feeds BOTH the never-overwrite guard below and the `safeMoveItem` beneath it.
        // One probe rather than two is the point: the guard runs first and can pre-empt the move
        // entirely, so a guard that folds case while the move does not (or the reverse) is two
        // functions disagreeing about whether the destination is a different file.
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
                // Re-derive: what does this folder look like RIGHT NOW?
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
                // A renumbering is all-or-nothing, here as well as in the planner. If the folder
                // moved under us in a way that invalidates ONE step of a cascade, the survivors
                // would collapse two months onto one slot — so the whole cohort stands down.
                let brokenCohorts = Set(plan.steps.filter { $0.cohort != 0 && !survives($0) }
                                                  .map(\.cohort))
                let runnable = plan.steps.filter { survives($0) && !brokenCohorts.contains($0.cohort) }
                out.stale += plan.steps.count - runnable.count

                // The units of execution: a cohort-0 step stands alone (a padding fix is right
                // whatever its neighbours do), and every step sharing a non-zero cohort travels as
                // one. Cohorts are ordered by id so a folder with two of them — a `.csv` cascade
                // and a `.pdf` one — applies in the same order every run.
                var units: [(cohort: Int, steps: [RenameStep])] = []
                var byCohort: [Int: [RenameStep]] = [:]
                for step in runnable {
                    if step.cohort == 0 { units.append((0, [step])) }
                    else { byCohort[step.cohort, default: []].append(step) }
                }
                for id in byCohort.keys.sorted() { units.append((id, byCohort[id]!)) }

                var appliedHere = false
                for unit in units {
                    var applied: [MoveItemState] = []
                    var failure: (step: RenameStep, error: Error)?
                    for step in unit.steps {
                        let src = URL(fileURLWithPath: step.currentPath)
                        var dst = dir.appendingPathComponent(step.proposedName)
                        // Already there under exactly this name — nothing to move.
                        if src.standardizedFileURL.path == dst.standardizedFileURL.path { continue }
                        // NEVER overwrite. The planner already refuses a contended target, so
                        // reaching here means the disk changed under us between the re-derive and
                        // the move — keep both rather than lose one.
                        //
                        // **Unless the "occupant" is the source itself.** `07. jul 2016.pdf` →
                        // `07. Jul 2016.pdf` is a rename this pass proposes for real, and on a
                        // case-INSENSITIVE volume `fileExists` finds the source under the collapsed
                        // name. The old spelling compared `standardizedFileURL` paths, which resolve
                        // `..` and trailing slashes but never CASE, so the two read as different
                        // files: the guard "resolved" a collision that did not exist and the file
                        // landed as `07. Jul 2016 2.pdf` — a duplicate marker invented out of
                        // nothing, which the next scan then preserves verbatim forever.
                        // `safeMoveItem` performs a case-only rename correctly; this guard sits
                        // above it and was pre-empting it, so it now asks that same question of the
                        // same helper. When the probe cannot answer it says "folds case", and that
                        // is the safe direction here: at worst this declines to uniquify and hands
                        // the move to `safeMoveItem`, which refuses a genuinely occupied
                        // destination rather than overwriting it.
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
                        // An independent step. Nothing else depended on it, so nothing else moves —
                        // undoing the padding fixes that worked because a third one failed would
                        // make the pass useless on the bulk of the backlog.
                        out.failed += 1
                        continue
                    }

                    // Put back what this cohort already moved, newest first. Every name it restores
                    // to was vacated by this same loop moments ago and no other member of the cohort
                    // targets it (two files in one folder cannot share a name, so no step's target
                    // is another step's source), so the folder returns to exactly the numbering it
                    // had.
                    var putBack = 0
                    var stranded: [MoveItemState] = []
                    for move in applied.reversed() {
                        // Somebody else took the old name in the meantime: putting the file back
                        // would overwrite them. Leave it where it is and say so — a file stranded
                        // under a new name is recoverable, a clobbered stranger is not.
                        guard !fm.fileExists(atPath: move.from.path) else {
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
                    // A file the rollback could not move stays under its new name, so it stays in
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
                                                     stranded: result.stranded))
            }
            return
        }

        // ONE grouped undo for the whole pass, exactly as the name normalizer registers one.
        let n = result.moves.count
        registerMoveUndo(items: result.moves, actionName: "Rename \(n) File\(n == 1 ? "" : "s")",
                         fileManager: fm)

        // Drop the folders that were fully or partly applied; their paths are stale either way, and
        // the next scan republishes whatever is left.
        let done = Set(result.doneFolders)
        renamePlans.removeAll { done.contains($0.folderPath) }

        Logger.shared.info("Rename pass: renamed \(n) file(s)\(result.stale > 0 ? ", \(result.stale) stale" : "")\(result.failed > 0 ? ", \(result.failed) failed" : "")\(result.abandoned > 0 ? ", \(result.abandoned) in a rolled-back renumbering" : "")")
        let message = Self.renameOutcome(renamed: n, stale: result.stale, failed: result.failed,
                                         abandoned: result.abandoned, stranded: result.stranded)
        banner = (result.failed > 0 || result.stale > 0 || result.abandoned > 0)
            ? .warning(message) : .success(message)
    }

    /// The banner sentence for a finished pass. Pure and static so the wording — including the part
    /// that has to stay honest about files it did **not** touch — is testable without a filesystem.
    ///
    /// `abandoned` is a statement about a GROUP, which is why it is not folded into `failed`: only
    /// one member of a rolled-back renumbering actually threw, and reporting four failures for one
    /// error is as dishonest as reporting one. `stranded` is the half that must never be silent —
    /// a file the rollback could not put back is the only way a half-applied renumbering survives
    /// this pass, so the sentence names it and sends the user to look.
    static func renameOutcome(renamed: Int, stale: Int, failed: Int,
                              abandoned: Int = 0, stranded: Int = 0) -> String {
        func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
        var tail = ""
        if abandoned > 0 {
            tail = stranded > 0
                ? " A renumbering of \(files(abandoned)) failed part-way and \(files(stranded)) couldn't be put back — check the folder."
                : " A renumbering of \(files(abandoned)) couldn't be completed, so the folder was left as it was."
        }
        guard renamed > 0 else {
            if failed > 0 && stale > 0 {
                return "Couldn't rename \(files(failed)); \(stale) had already changed." + tail
            }
            if failed > 0 { return "Couldn't rename \(files(failed))." + tail }
            if stale > 0 { return "\(files(stale)) had already changed — nothing renamed." + tail }
            // Nothing renamed, nothing stale, nothing independently failed: the abandoned
            // renumbering IS the whole story, and the leading space goes with the joining.
            return tail.isEmpty ? "Nothing renamed." : String(tail.dropFirst())
        }
        var s = "Renamed \(files(renamed))"
        if stale > 0 { s += "; \(stale) had already changed" }
        if failed > 0 { s += "; \(failed) couldn't be renamed" }
        // The ⌘Z clause is the one sentence here that does not end in a period, so the renumbering
        // clause has to bring one or the two run together into nonsense.
        return s + ". Press ⌘Z to undo" + (tail.isEmpty ? "" : "." + tail)
    }

    /// The folder's direct files as they stand on disk, or nil when it cannot be listed.
    ///
    /// Goes through ``FileManaging`` rather than `FileManager` directly so the apply path can be
    /// driven by the in-memory test double, like every other write path in the engine.
    nonisolated static func liveFiles(in dir: URL, fileManager fm: FileManaging) -> [FolderFile]? {
        // Through `listing` rather than a bare enumerator: the enumerator comes back non-nil
        // yielding nothing for a folder it cannot read, so "cannot be listed" used to arrive here
        // as an empty folder and this function's documented promise — never a stale slot number —
        // could not be kept. Anything short of a complete listing is a nil: a shallow listing
        // cannot report `.listedWithUnreadableDescendants`, and if it ever could, a partial view
        // of a numbered folder is exactly what must not be renumbered against.
        let listing = fm.listing(of: dir, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        guard listing.isComplete else { return nil }
        var files: [FolderFile] = []
        for url in listing.urls {
            // The enumerator can hand back a resolved path; re-root every entry on `dir` so the
            // paths compare equal to the ones the plan carries.
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
