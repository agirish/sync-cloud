import Foundation
import Events

/// What "Undo Last Run" is about to reverse, assembled when the button is pressed so the
/// confirmation can list which operations will be undone. It exists only when the top of the
/// shared `UndoManager` stack is the last recorded sync run
/// (`FileSyncManager.lastSyncRunUndoPreview`); with any other action on top there is no preview and
/// the undo is refused.
///
/// The gate alone doesn't keep the preview honest. A run arms its pairing in the turn that
/// registers its undo, so nothing can slip in between, and the confirmation is modal, so a second
/// run can finish while it is up: `undoLastSyncRunAskingFirst` re-reads the preview after the modal
/// and refuses unless `runToken` still names the run it showed. ⌘Z bypasses both and reverses
/// whatever is on top.
public struct SyncRunUndoPreview: Sendable {
    /// The `UndoManager` action name of the run's group (e.g. "Sync run", "Move 3 Items"). Used
    /// both to gate the undo (it must still match the stack's top) and to title the log line.
    public let actionName: String
    /// Every record produced by the run, in the order it happened — the evidence shown to the user.
    public let records: [SyncHistoryRecord]
    /// Which arming of the pairing this preview describes — fresh for every run that arms it, so
    /// two runs under one action name are still two tokens.
    public let runToken: UUID

    public init(actionName: String, records: [SyncHistoryRecord], runToken: UUID = UUID()) {
        self.actionName = actionName
        self.records = records
        self.runToken = runToken
    }

    /// How many file operations the run performed (and this undo will reverse).
    public var operationCount: Int { records.count }

    /// Human count grouped by action, zero buckets omitted — e.g. "8 copies, 2 moves". Empty when
    /// there are no records.
    ///
    /// A `.delete` here is always a move to the Trash: a delete run is paired for Undo Last Run only
    /// when every item reached the Trash and the Trash said where each went (`deleteItems`), so the
    /// preview never holds a permanent delete.
    public var actionSummary: String {
        var counts: [SyncAction: Int] = [:]
        for r in records { counts[r.action, default: 0] += 1 }
        return SyncAction.allCases.compactMap { action -> String? in
            guard let n = counts[action], n > 0 else { return nil }
            let (singular, plural): (String, String)
            switch action {
            case .copy: (singular, plural) = ("copy", "copies")
            case .move: (singular, plural) = ("move", "moves")
            case .delete: (singular, plural) = ("move to the Trash", "moves to the Trash")
            case .matchDates: (singular, plural) = ("date match", "date matches")
            case .newFolder: (singular, plural) = ("new folder", "new folders")
            }
            return "\(n) \(n == 1 ? singular : plural)"        // "2 copies", "3 moves to the Trash", "1 date match"
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
                lines.append("  •  Put back “\(src)” from the Trash")
            case .matchDates:
                let dest = rec.destPath.map { ($0 as NSString).lastPathComponent } ?? src
                lines.append("  •  Put back the date of “\(dest)”")
            case .newFolder:
                lines.append("  •  Remove the folder “\(src)” if it’s empty")
            case .copy, .move:
                let destDir = rec.destPath.map { ((($0 as NSString).deletingLastPathComponent) as NSString).lastPathComponent } ?? ""
                let where_ = destDir.isEmpty ? "" : " → \(destDir)"
                lines.append("  •  \(rec.action.label) “\(src)”\(where_)")
            }
        }
        if n > maxLines { lines.append("  …  and \(n - maxLines) more") }
        lines.append("")
        lines.append(reversalNote + " You can redo this afterward.")
        return lines.joined(separator: "\n")
    }

    /// How the reversal behaves, one clause per kind of operation this run holds, in summary order.
    /// No fixed sentence fits every run: undoing a copy moves nothing back, it trashes the copies
    /// and puts back any file a copy replaced.
    var reversalNote: String {
        let present = Set(records.map(\.action))
        var clauses: [String] = []
        if present.contains(.copy) {
            clauses.append("the copies it made go to the Trash, and any file a copy replaced is put back")
        }
        if present.contains(.move) {
            clauses.append("moved files go back to where they were")
        }
        if present.contains(.delete) {
            clauses.append("items moved to the Trash are put back")
        }
        if present.contains(.matchDates) {
            clauses.append("files whose dates were matched get their own dates back, unless changed since")
        }
        if present.contains(.newFolder) {
            clauses.append("folders it made are removed if they’re empty")
        }
        guard let first = clauses.first else { return "" }
        clauses[0] = first.prefix(1).uppercased() + first.dropFirst()
        return clauses.joined(separator: "; ") + "."
    }
}
