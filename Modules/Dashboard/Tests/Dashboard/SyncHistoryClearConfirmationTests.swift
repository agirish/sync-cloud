import AppKit
import Foundation
import Testing
@testable import Dashboard
import Events

/// Pins that clearing the durable sync history asks first, and honours the answer.
///
/// The trash button sat 34pt from the Export menu and wiped `~/sync-cloud-history.jsonl` on a
/// single click — no alert, no undo. Its own siblings all confirm ("Undo Last Run" in this very
/// toolbar, "Reset All Settings…" in Settings), and unlike the Activity Log, which rotates on its
/// own and forgets on quit, this file is the only copy of the record.
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

        let cleared = SyncHistoryView.clearIfConfirmed(store: store, confirm: { asked += 1; return false })

        #expect(cleared == false)
        #expect(asked == 1)
        #expect(store.records.count == 1)
    }

    @Test func confirmingClearsTheRecords() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(store.records.count == 1)

        let cleared = SyncHistoryView.clearIfConfirmed(store: store, confirm: { true })

        #expect(cleared)
        #expect(store.records.isEmpty)
    }

    @Test func theConfirmationIsAskedBeforeAnythingIsRemoved() {
        // Ordering, not just the outcome: a confirmer that inspects the store must still see the
        // record, so the wipe can never run ahead of the answer.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var recordsVisibleWhenAsked = -1

        SyncHistoryView.clearIfConfirmed(store: store, confirm: {
            recordsVisibleWhenAsked = store.records.count
            return true
        })

        #expect(recordsVisibleWhenAsked == 1)
        #expect(store.records.isEmpty)
    }

    @Test func theViewTakesTheConfirmerAsASeam() {
        // The initializer must keep accepting an injected answer — the property that makes the
        // two tests above cover what the shipping button does, rather than a parallel code path.
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let view = SyncHistoryView(store: store, onUndoLastSyncRun: {}, confirmClearHistory: { false })
        _ = view.body
        #expect(store.records.count == 1)
    }
}
