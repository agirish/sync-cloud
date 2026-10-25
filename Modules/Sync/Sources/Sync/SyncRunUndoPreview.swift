import Foundation
import Events

/// What "Undo Last Run" is about to reverse, assembled the moment the button is pressed so the
/// confirmation can spell out — in as much detail as fits an alert — exactly which operations will
/// be undone. It exists ONLY when the top of the shared `UndoManager` stack really is the last
/// recorded sync run (see `FileSyncManager.lastSyncRunUndoPreview`); when a Filing move, a rename,
/// a "New Folder", or any other non-sync action sits on top instead, there is no preview and the
/// undo is refused.
///
/// **What that gate does not cover, and what does** (FR26). This used to say the preview "can
/// never describe one run while a different action gets reversed", and two paths did exactly that:
/// a run armed its pairing only after awaiting its identity walks, so a rename or ⌘Z made during
/// that tail was paired with the run's records; and the confirmation is modal, so a second "Sync
/// run" finishing while it was up re-armed the pairing under the same name, and Undo reversed the
/// run the alert never listed. Runs now arm in the turn that registers them, and the confirmation
/// (`undoLastSyncRunAskingFirst`) re-reads the preview after the modal and refuses unless its
/// `runToken` still names the run it showed. A path that bypasses both — ⌘Z itself — reverses whatever is on top.
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
    /// **A `.delete` here is always a move to the Trash** (FD2): a delete run is paired for Undo
    /// Last Run only when every item reached the Trash (`deleteItems`), so the preview never holds
    /// a permanent delete, and says "moves to the Trash" rather than "deletes".
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

    /// How the reversal behaves, said only for the kinds of operation this run holds (FR29).
    ///
    /// **One fixed sentence was wrong for the commonest run there is.** It always read "Files move
    /// back to where they were; deleted items are restored from the Trash", and undoing a COPY run
    /// moves nothing back and restores nothing from the Trash: the copies it made go TO the Trash,
    /// and a file a copy replaced is put back in its place. Someone who pressed Undo on a sync that
    /// had only copied was told their files would be moved. Each kind now says what its own undo
    /// does, in the order the summary lists them.
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
        guard let first = clauses.first else { return "" }
        clauses[0] = first.prefix(1).uppercased() + first.dropFirst()
        return clauses.joined(separator: "; ") + "."
    }
}
