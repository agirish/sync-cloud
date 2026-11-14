import AppKit
import Foundation
import Testing
import FileExplorer
@testable import Dashboard
import Events

/// Pins that clearing the durable sync history asks first, and honours the answer.
///
/// The trash button sits near the Export menu, and `~/sync-cloud-history.jsonl` is the only copy of
/// the record (the Activity Log rotates and forgets on quit), so one click must not wipe it with
/// no alert and no undo. Its siblings confirm too: "Undo Last Run" here, "Reset All Settings…" in
/// Settings.
@MainActor
@Suite(.serialized) struct SyncHistoryClearConfirmationTests {

    /// A store backed by a scratch file, holding one record on disk and in memory.
    private func makeStore() -> (SyncHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).jsonl")
        let store = SyncHistoryStore(fileURL: url)
        store.append(SyncHistoryRecord(
            runId: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            action: .copy,
            sourcePath: "/a/f.txt", destPath: "/b/f.txt", sizeBytes: 10, direction: "Left → Right"))
        return (store, url)
    }

    @Test func decliningTheConfirmationKeepsEveryRecord() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.records.count == 1)
        var asked = 0

        let cleared = ActivityEventsView.clearIfConfirmed(store: store, confirm: { asked += 1; return false })

        #expect(cleared == false)
        #expect(asked == 1)
        #expect(store.records.count == 1)
    }

    @Test func theConfirmationIsAskedBeforeAnythingIsRemoved() {
        // Ordering, not just the outcome: a confirmer that inspects the store must still see the
        // record, so the wipe can never run ahead of the answer.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var recordsVisibleWhenAsked = -1

        let cleared = ActivityEventsView.clearIfConfirmed(store: store, confirm: {
            recordsVisibleWhenAsked = store.records.count
            return true
        })

        #expect(cleared)
        #expect(recordsVisibleWhenAsked == 1)
        #expect(store.records.isEmpty)
    }

    /// The button goes through `clearIfConfirmed` with the view's injected confirmer, so the tests
    /// above cover what it does. SwiftUI can't tap the menu item, so this reads the source.
    @Test func theClearButtonAsksThroughTheConfirmer() throws {
        let view = try DashboardSource.read("ActivityEventsView.swift", codeOnly: true)
        #expect(view.contains("Self.clearIfConfirmed(store: store, confirm: confirmClearHistory)"))
        #expect(view.components(separatedBy: "store.clear()").count == 2,
                "the only `store.clear()` must be the one inside `clearIfConfirmed`")
    }
}
