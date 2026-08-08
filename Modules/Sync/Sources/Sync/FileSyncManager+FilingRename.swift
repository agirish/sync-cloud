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
        // Only this file's own step. The plan may also propose padding for the folder's existing
        // names, and filing one file is not the moment to renumber its new neighbours.
        return plan.steps.first { $0.currentPath == incoming.path }?.proposedName
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
        func index(_ nodes: [FileNode], folderPath: String) {
            filesByFolder[folderPath] = nodes.filter { !$0.isDirectory }
                .map { FolderFile(path: $0.id, name: $0.name) }
            for dir in nodes where dir.isDirectory { index(dir.children ?? [], folderPath: dir.id) }
        }
        index(taxonomy, folderPath: rootPath)

        return suggestions.map { suggestion in
            let named = suggestion.candidates.map { dest -> FilingDestination in
                // A destination whose folders do not exist yet has no files and no convention to
                // read, so it never proposes a rename.
                guard dest.newSegments.isEmpty,
                      let rel = FileSyncManager.relativePath(dest.path, under: rootPath)
                else { return dest }
                return dest.naming(incomingName(for: suggestion.fileName, into: dest.path,
                                                relativePath: rel,
                                                folderFiles: filesByFolder[dest.path] ?? [],
                                                profile: profile))
            }
            return FilingSuggestion(filePath: suggestion.filePath, fileName: suggestion.fileName,
                                    size: suggestion.size,
                                    modificationDate: suggestion.modificationDate,
                                    candidates: named, providerRoot: suggestion.providerRoot)
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
    /// The unit of apply is the **folder**, matching the unit of review: a plan's steps are decided
    /// against each other, so applying an arbitrary subset of one is not a smaller version of the
    /// same change.
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

        let result: (moves: [MoveItemState], doneFolders: [String], stale: Int, failed: Int)
            = await enqueueFileOperation {
            var moves: [MoveItemState] = []
            var doneFolders: [String] = []
            var stale = 0
            var failed = 0

            for plan in plans {
                let dir = URL(fileURLWithPath: plan.folderPath)
                // Re-derive: what does this folder look like RIGHT NOW?
                guard let live = Self.liveFiles(in: dir, fileManager: fm) else {
                    stale += plan.steps.count
                    continue
                }
                let fresh = RenamePlanner.plan(folderPath: plan.folderPath,
                                               relativePath: plan.relativePath,
                                               files: live,
                                               entry: profile?.folders[plan.relativePath])
                // A step is applied only if the folder as it stands still asks for exactly it.
                let stillProposed = Set(fresh.steps.map { $0.currentPath + "\u{0}" + $0.proposedName })
                var appliedHere = false
                for step in plan.steps {
                    guard stillProposed.contains(step.currentPath + "\u{0}" + step.proposedName) else {
                        stale += 1
                        continue
                    }
                    let src = URL(fileURLWithPath: step.currentPath)
                    var dst = dir.appendingPathComponent(step.proposedName)
                    // NEVER overwrite. The planner already refuses a contended target, so reaching
                    // here means the disk changed under us between the re-derive and the move —
                    // keep both rather than lose one.
                    if fm.fileExists(atPath: dst.path),
                       src.standardizedFileURL.path != dst.standardizedFileURL.path {
                        dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                    }
                    if src.standardizedFileURL.path == dst.standardizedFileURL.path { continue }
                    do {
                        let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                        moves.append((from: src, to: dst, overwritten: overwritten))
                        appliedHere = true
                    } catch {
                        logger.warning("Rename pass: “\(step.currentName)” → “\(step.proposedName)” failed: \(error.localizedDescription)")
                        failed += 1
                    }
                }
                if appliedHere { doneFolders.append(plan.folderPath) }
            }
            return (moves, doneFolders, stale, failed)
        }

        guard !result.moves.isEmpty else {
            if result.failed > 0 || result.stale > 0 {
                banner = .warning(Self.renameOutcome(renamed: 0, stale: result.stale,
                                                     failed: result.failed))
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

        Logger.shared.info("Rename pass: renamed \(n) file(s)\(result.stale > 0 ? ", \(result.stale) stale" : "")\(result.failed > 0 ? ", \(result.failed) failed" : "")")
        let message = Self.renameOutcome(renamed: n, stale: result.stale, failed: result.failed)
        banner = (result.failed > 0 || result.stale > 0) ? .warning(message) : .success(message)
    }

    /// The banner sentence for a finished pass. Pure and static so the wording — including the part
    /// that has to stay honest about files it did **not** touch — is testable without a filesystem.
    static func renameOutcome(renamed: Int, stale: Int, failed: Int) -> String {
        guard renamed > 0 else {
            if failed > 0 && stale > 0 {
                return "Couldn't rename \(failed) file\(failed == 1 ? "" : "s"); \(stale) had already changed."
            }
            if failed > 0 { return "Couldn't rename \(failed) file\(failed == 1 ? "" : "s")." }
            return "\(stale) file\(stale == 1 ? "" : "s") had already changed — nothing renamed."
        }
        var s = "Renamed \(renamed) file\(renamed == 1 ? "" : "s")"
        if stale > 0 { s += "; \(stale) had already changed" }
        if failed > 0 { s += "; \(failed) couldn't be renamed" }
        return s + ". Press ⌘Z to undo"
    }

    /// The folder's direct files as they stand on disk, or nil when it cannot be listed.
    ///
    /// Goes through ``FileManaging`` rather than `FileManager` directly so the apply path can be
    /// driven by the in-memory test double, like every other write path in the engine.
    nonisolated static func liveFiles(in dir: URL, fileManager fm: FileManaging) -> [FolderFile]? {
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil
        ) else { return nil }
        var files: [FolderFile] = []
        for case let url as URL in enumerator {
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
