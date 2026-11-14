import Events
import Foundation

/// Copies of a statement into the other accounts it names (decision 11).
extension FileSyncManager {

    /// Copies `landed` into each of `copies`, under the name that account's statements take (" 2"
    /// on a clash), making the folder if it isn't there. A copy that fails is skipped and logged;
    /// the main filing stands. The set is marked as kept apart in Duplicates: copies on purpose.
    func performFilingCopies(of landed: URL, copies: [FilingCopy]) -> [CopyItemState] {
        guard !copies.isEmpty else { return [] }
        let fm = fileManager
        var done: [CopyItemState] = []
        for copy in copies {
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
        if !done.isEmpty {
            var keys = ignoredDuplicateKeys
            keys.insert(([landed.path] + done.map(\.destination.path)).sorted().joined(separator: "\n"))
            ignoredDuplicateKeys = keys
        }
        return done
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
                            forgetsLesson: Bool = false) {
        let grouped = undoManager != nil && (!copies.isEmpty || !createdFolders.isEmpty || priorFolderMove != nil || forgetsLesson)
        if grouped { undoManager?.beginUndoGrouping() }
        // The lesson this filing taught is forgotten by the same ⌘Z, once the files are back.
        if forgetsLesson { registerForgetUndoneLesson() }
        if let prior = priorFolderMove {
            registerRepointUndo(from: prior.new, to: prior.old)
            registerRemoveCreatedFolders(prior.createdParents)
            registerMoveUndo(items: [prior.move], landedIdentities: [prior.move.to: prior.identityBeforeFiling],
                             actionName: actionName, fileManager: fileManager)
        }
        registerRemoveCreatedFolders(createdFolders)
        registerMoveUndo(items: moves, actionName: actionName, fileManager: fileManager)
        if !copies.isEmpty { registerCopyUndo(items: copies, actionName: actionName, fileManager: fileManager) }
        if grouped { undoManager?.endUndoGrouping() }
    }

    /// Undo checks, once every move of the same step has run, whether a lesson's filing was
    /// undone, and forgets it (``forgetUndoneLearnedAccounts()``). Redo doesn't teach it again.
    func registerForgetUndoneLesson() {
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                let slot = target.claimFileOperationSlot()
                await target.enqueueFileOperation(slot: slot) {}
                target.forgetUndoneLearnedAccounts()
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
                    for f in folders.reversed() {
                        try? FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true)
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
