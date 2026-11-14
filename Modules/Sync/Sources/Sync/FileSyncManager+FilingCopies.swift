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

    /// The move-undo for a filing, and the copy-undo for its copies, as one ⌘Z: copies go first,
    /// then the file moves back. No `await` inside, so nothing else registers into the step.
    ///
    /// With `priorFolderMove` (an account moved out of its archive first), the step also moves the
    /// folder back and points what referred to it back, after the files are out: registered first,
    /// so undone last.
    func registerFilingUndo(moves: [MoveItemState], copies: [CopyItemState], actionName: String,
                            priorFolderMove: (move: MoveItemState, old: String, new: String)? = nil) {
        let grouped = undoManager != nil && (!copies.isEmpty || priorFolderMove != nil)
        if grouped { undoManager?.beginUndoGrouping() }
        if let prior = priorFolderMove {
            registerRepointUndo(from: prior.new, to: prior.old)
            registerMoveUndo(items: [prior.move], actionName: actionName, fileManager: fileManager)
        }
        registerMoveUndo(items: moves, actionName: actionName, fileManager: fileManager)
        if !copies.isEmpty { registerCopyUndo(items: copies, actionName: actionName, fileManager: fileManager) }
        if grouped { undoManager?.endUndoGrouping() }
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
