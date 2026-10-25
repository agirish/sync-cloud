import Foundation
import Testing
import Events
@testable import Dashboard

/// **Sync History calls a move to the Trash "Move to Trash"** (FD2) — its Action filter and its
/// rows. The rule that tells a trash move from a permanent delete is `SyncHistoryRecord.actionLabel`
/// (pinned in Events); this pins that the window uses it.
@Suite struct SyncHistoryTrashLabelTests {

    @Test func theActionFilterNamesTrashMoves() {
        #expect(SyncHistoryView.actionOptions.map(\.label)
                == ["All Actions", "Copies", "Moves", "Moves to Trash", "Date Matches"])
        #expect(SyncHistoryView.actionOptions.first { $0.label == "Moves to Trash" }?.action == .delete)
    }

    /// The row's pill reads the record's label, not the action's, so a permanent delete still
    /// says "Delete". A row's body never runs offscreen in a test, so this reads the code.
    @Test func aRowsPillUsesTheRecordsOwnLabel() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/SyncHistoryView.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(url.path) — the scan would pass vacuously")
        #expect(code.contains("Pill(.mini, tint: actionColor, text: record.actionLabel)"))
        #expect(!code.contains("record.action.label"), "a row labels by the action, so a permanent delete reads Move to Trash")
    }
}
