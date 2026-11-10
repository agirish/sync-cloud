import Foundation
import Testing
import Events
@testable import Dashboard

/// Events calls a move to the Trash "Move to Trash", in its Action filter and its file rows. The
/// rule that tells a trash move from a permanent delete is `SyncHistoryRecord.actionLabel` (pinned
/// in Events); this pins that the window uses it.
@Suite struct SyncHistoryTrashLabelTests {

    @Test func theActionFilterNamesTrashMoves() {
        #expect(ActivityEventsView.actionOptions.map(\.label)
                == ["All Events", "Copies", "Moves", "Moves to Trash & Deletes", "Date Matches", "New Folders"])
        #expect(ActivityEventsView.actionOptions.first { $0.label == "Moves to Trash & Deletes" }?.action == .action(.delete))
    }

    /// The row's pill reads the record's label, not the action's, so a permanent delete still
    /// says "Delete". A row's body never runs offscreen in a test, so this reads the code.
    @Test func aRowsPillUsesTheRecordsOwnLabel() throws {
        let code = try DashboardSource.read("ActivityEventsView.swift")
        #expect(code.contains("Pill(.mini, tint: actionColor, text: record.actionLabel)"))
        #expect(!code.contains("record.action.label"), "a row labels by the action, so a permanent delete reads Move to Trash")
    }
}
