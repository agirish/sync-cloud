import Events
import Foundation

/// Copies of a statement into the other accounts it names (decision 11).
extension FileSyncManager {

    /// Copies `landed` into each of `copies`, under the name that account's statements take (" 2"
    /// on a clash), making the folder if it isn't there. A copy that fails is skipped and logged;
    /// the main filing stands. The set is marked as kept apart in Duplicates: copies on purpose.
    func performFilingCopies(of landed: URL, copies: [FilingCopy]) async -> [CopyItemState] {
        guard !copies.isEmpty else { return [] }
        // In the file-operation queue, like the move it follows.
        let done: [CopyItemState] = await enqueueFileOperation {
            let fm = FileManager.default
            var done: [CopyItemState] = []
            for copy in copies {
                // The account must still be there: renamed or moved in Finder since the scan, the
                // copy would make its old folder again.
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: copy.account.root, isDirectory: &isDir), isDir.boolValue else {
                    Logger.shared.warning("Filing: no copy to \(copy.account.root): the folder isn’t there any more")
                    continue
                }
                let folder = URL(fileURLWithPath: copy.path)
                let name = copy.proposedName ?? landed.lastPathComponent
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
                    var target = folder.appendingPathComponent(name)
                    var n = 2
                    let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                    while fm.fileExists(atPath: target.path) {
                        target = folder.appendingPathComponent(stem + " \(n)" + (ext.isEmpty ? "" : "." + ext))
                        n += 1
                    }
                    try fm.copyItem(at: landed, to: target)
                    done.append((source: landed, destination: target, overwritten: nil))
                } catch {
                    Logger.shared.warning("Filing: couldn’t copy “\(landed.lastPathComponent)” to \(copy.path): \(error.localizedDescription)")
                }
            }
            return done
        }
        if !done.isEmpty {
            var keys = ignoredDuplicateKeys
            keys.insert(Self.copySetKey(landed: landed, copies: done))
            ignoredDuplicateKeys = keys
        }
        return done
    }

    /// The Duplicates "kept separate" key for a statement and its copies.
    nonisolated static func copySetKey(landed: URL, copies: [CopyItemState]) -> String {
        ([landed.path] + copies.map(\.destination.path)).sorted().joined(separator: "\n")
    }

    /// What ⌘Z of a filing does to the lesson it taught (``registerLessonUndo(taught:previous:batch:)``).
    struct LessonUndo {
        let taught: LearnedAccount
        let previous: LearnedAccount?
        let batch: [LearnedAccount.Teaching]
    }

    /// An account folder moved out of its archive just before a filing (`moveOutOfArchiveThenFile`):
    /// the move, its snapshot from before anything was filed into it, the folders made above it,
    /// and the paths learned accounts and cards were pointed from and to.
    struct PriorFolderMove {
        let move: MoveItemState
        let identityBeforeFiling: ItemIdentity
        let createdParents: [String]
        let old: String
        let new: String
        /// The tree learned accounts are relative to, as it was at the move.
        let root: String
    }

    /// The folders filing into `folders` would make: each one, and each of its ancestors, not on
    /// disk now. Deepest first.
    func missingFolders(for folders: [String]) -> [String] {
        var out: [String] = []
        for folder in Set(folders) {
            var f = folder
            while !f.isEmpty, f != "/", !fileManager.fileExists(atPath: f), !out.contains(f) {
                out.append(f)
                f = (f as NSString).deletingLastPathComponent
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    /// The move-undo for a filing, the copy-undo for its copies, and the removal of the folders it
    /// made, as one ⌘Z. In the order it runs: copies go, the files move back, the folders filing
    /// made go if empty, then (`priorFolderMove`) the account moves back into its archive, the
    /// folders made for it go, and what referred to it is pointed back. No `await` inside, so
    /// nothing else registers into the step.
    func registerFilingUndo(moves: [MoveItemState], copies: [CopyItemState], actionName: String,
                            createdFolders: [String] = [], priorFolderMove: PriorFolderMove? = nil,
                            lesson: LessonUndo? = nil) {
        let grouped = undoManager != nil && (!copies.isEmpty || !createdFolders.isEmpty || priorFolderMove != nil || lesson != nil)
        if grouped { undoManager?.beginUndoGrouping() }
        // The lesson this filing taught goes back to what it was, by the same ⌘Z, once the files are.
        if let lesson { registerLessonUndo(taught: lesson.taught, previous: lesson.previous, batch: lesson.batch) }
        if let prior = priorFolderMove {
            registerRepointUndo(from: prior.new, to: prior.old, root: prior.root, intoArchive: true)
            registerRemoveCreatedFolders(prior.createdParents)
            registerMoveUndo(items: [prior.move], landedIdentities: [prior.move.to: prior.identityBeforeFiling],
                             actionName: actionName, fileManager: fileManager)
        }
        registerRemoveCreatedFolders(createdFolders)
        registerMoveUndo(items: moves, actionName: actionName, fileManager: fileManager)
        if !copies.isEmpty {
            registerCopyUndo(items: copies, actionName: actionName, fileManager: fileManager)
            registerForgetCopySets(copies)
        }
        if grouped { undoManager?.endUndoGrouping() }
    }

    /// Undo drops the Duplicates "kept separate" keys of copies it takes away; redo puts them back.
    func registerForgetCopySets(_ copies: [CopyItemState]) {
        let keys = Set(Dictionary(grouping: copies, by: \.source).map { Self.copySetKey(landed: $0.key, copies: $0.value) })
        undoManager?.registerUndo(withTarget: self) { target in
            target.ignoredDuplicateKeys.subtract(keys)
            target.undoManager?.registerUndo(withTarget: target) { t in
                t.ignoredDuplicateKeys.formUnion(keys)
                t.registerForgetCopySets(copies)
            }
        }
    }

    /// Undo removes `folders` (deepest first), each only if nothing but Finder's `.DS_Store` is in
    /// it, in the file-operation queue behind the moves the same ⌘Z queued first. Redo makes them
    /// again, ahead of the moves it redoes.
    func registerRemoveCreatedFolders(_ folders: [String]) {
        guard !folders.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerRecreateFolders(folders)
            let slot = target.claimFileOperationSlot()
            Task { await target.enqueueFileOperation(slot: slot) { Self.removeIfEmpty(folders) } }
        }
    }

    private func registerRecreateFolders(_ folders: [String]) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerRemoveCreatedFolders(folders)
            let slot = target.claimFileOperationSlot()
            Task {
                await target.enqueueFileOperation(slot: slot) {
                    // Shallowest first, each only under a parent that is there: a folder whose own
                    // move refused to redo is not made empty beside where it should be.
                    for f in folders.sorted(by: { $0.count < $1.count }) {
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: (f as NSString).deletingLastPathComponent, isDirectory: &isDir),
                              isDir.boolValue else { continue }
                        try? FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: false)
                    }
                }
            }
        }
    }

    nonisolated static func removeIfEmpty(_ folders: [String]) {
        let fm = FileManager.default
        for f in folders.sorted(by: { $0.count > $1.count }) {
            guard let items = try? fm.contentsOfDirectory(atPath: f) else { continue }
            guard items.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? fm.removeItem(atPath: f)
        }
    }

    /// " · copied to Roth IRA 4657" for a banner.
    static func copiedPhrase(_ copies: [CopyItemState]) -> String {
        guard !copies.isEmpty else { return "" }
        let folders = Array(Set(copies.map { accountName(of: $0.destination.deletingLastPathComponent()) })).sorted()
        return "; copied to " + folders.joined(separator: ", ")
    }

    /// The account folder above a year: `Roth IRA 4657` for `…/Roth IRA 4657/2026`.
    static func accountName(of folder: URL) -> String {
        var f = folder
        while FolderProfileEntry.looksLikeYear(f.lastPathComponent) || FilingPeriod.monthSlot(ofFolderNamed: f.lastPathComponent) != nil {
            f = f.deletingLastPathComponent()
        }
        return f.lastPathComponent
    }
}
