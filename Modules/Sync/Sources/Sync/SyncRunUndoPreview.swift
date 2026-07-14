import Foundation
import Events

/// What "Undo Last Run" is about to reverse, assembled the moment the button is pressed so the
/// confirmation can spell out — in as much detail as fits an alert — exactly which operations will
/// be undone. It exists ONLY when the top of the shared `UndoManager` stack really is the last
/// recorded sync run (see `FileSyncManager.lastSyncRunUndoPreview`); when a Filing move, a rename,
/// a "New Folder", or any other non-sync action sits on top instead, there is no preview and the
/// undo is refused — so this can never describe one run while a different action gets reversed.
public struct SyncRunUndoPreview: Sendable {
    /// The `UndoManager` action name of the run's group (e.g. "Sync run", "Move 3 Items"). Used
    /// both to gate the undo (it must still match the stack's top) and to title the log line.
    public let actionName: String
    /// Every record produced by the run, in the order it happened — the evidence shown to the user.
    public let records: [SyncHistoryRecord]

    public init(actionName: String, records: [SyncHistoryRecord]) {
        self.actionName = actionName
        self.records = records
    }

    /// How many file operations the run performed (and this undo will reverse).
    public var operationCount: Int { records.count }

    /// Human count grouped by action, zero buckets omitted — e.g. "8 copies, 2 moves". Empty when
    /// there are no records.
    public var actionSummary: String {
        var counts: [SyncAction: Int] = [:]
        for r in records { counts[r.action, default: 0] += 1 }
        return [SyncAction.copy, .move, .delete].compactMap { action -> String? in
            guard let n = counts[action], n > 0 else { return nil }
            let singular = action.label.lowercased()          // "copy" / "move" / "delete"
            let plural = singular.hasSuffix("y") ? String(singular.dropLast()) + "ies" : singular + "s"
            return "\(n) \(n == 1 ? singular : plural)"        // "2 copies", "1 move", "3 deletes"
        }.joined(separator: ", ")
    }

    /// The alert body: a headline counting the run, an itemized (capped) list of what reverses, and
    /// a plain-language note on how the reversal behaves. Pure and deterministic so the wording is
    /// unit-tested and can't drift from the gate that authorizes it.
    public func confirmationDetail(maxLines: Int = 8) -> String {
        let n = records.count
        var lines = ["This reverses \(n) operation\(n == 1 ? "" : "s") from the last run (\(actionSummary)):"]
        for rec in records.prefix(max(0, maxLines)) {
            let src = (rec.sourcePath as NSString).lastPathComponent
            switch rec.action {
            case .delete:
                lines.append("  •  Restore “\(src)” from the Trash")
            case .copy, .move:
                let destDir = rec.destPath.map { ((($0 as NSString).deletingLastPathComponent) as NSString).lastPathComponent } ?? ""
                let where_ = destDir.isEmpty ? "" : " → \(destDir)"
                lines.append("  •  \(rec.action.label) “\(src)”\(where_)")
            }
        }
        if n > maxLines { lines.append("  …  and \(n - maxLines) more") }
        lines.append("")
        lines.append("Files move back to where they were; deleted items are restored from the Trash. You can redo this afterward.")
        return lines.joined(separator: "\n")
    }
}
