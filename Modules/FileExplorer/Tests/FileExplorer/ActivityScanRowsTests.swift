import Foundation
import Testing
import Sync
@testable import FileExplorer

/// **The long scans in Activity's Running** (Run Room TE228, CO, R21): listed with a Show and no
/// Stop — their controls stay on their cards — and Read documents says when it is paused, by whom.
@MainActor
@Suite struct ActivityScanRowsTests {

    @Test func aRestructureApplyIsListedWithShowAndNoStop() {
        let manager = FileSyncManager()
        #expect(ActivityScanRows.rows(manager) { _ in }.isEmpty, "a row with nothing running")
        manager.restructureApplyProgress = RestructureApplyProgress(stage: .operations, opsDone: 12, opsTotal: 40)
        var shown: [ActivityScan] = []
        let rows = ActivityScanRows.rows(manager) { shown.append($0) }
        let row = try! #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.onCancel == nil, "a scan's Stop belongs to its card")
        #expect(row.run.completed == 12 && row.run.total == 40)
        #expect(row.run.detail == "Running the operations, re-probing each one — 12 of 40")
        row.onShow?()
        #expect(shown == [.restructure])
    }

    /// The card and the row read the same state: paused by the Mac, it says so and that it goes on
    /// by itself; paused by the reader, only that it is paused.
    @Test func readDocumentsSaysWhoPausedIt() {
        let started = Date(timeIntervalSince1970: 1_780_315_200)
        let hot = DocumentSurveyProgress(completed: 40, total: 300, phase: .paused(.thermal),
                                         startedAt: started, readingSeconds: 60)
        #expect(DocumentSurveyCardText.title(for: .live(hot)) == "Reading documents · paused at 40 of 300")
        let reading = DocumentSurveyProgress(completed: 40, total: 300, phase: .reading, currentFolder: "Taxes",
                                             startedAt: started, readingSeconds: 60)
        #expect(DocumentSurveyCardText.title(for: .live(reading)) == "Reading documents · 40 of 300")
        let finishing = DocumentSurveyProgress(completed: 300, total: 300, phase: .finishing,
                                               startedAt: started, readingSeconds: 60)
        #expect(DocumentSurveyCardState.live(finishing) == .finishing(done: 300))
    }
}
