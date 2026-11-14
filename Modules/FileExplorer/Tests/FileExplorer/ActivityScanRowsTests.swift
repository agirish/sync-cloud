import Foundation
import Testing
@testable import Sync
@testable import FileExplorer

/// The long scans in Activity's Running: listed with a Show and no Stop, since their controls stay
/// on their cards, and Read documents says when it is paused, and by whom.
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

    /// The row says who paused the reading, as the card does: paused by the Mac, it says so and
    /// that it goes on by itself; paused by the reader, only that it is paused.
    @Test func readDocumentsSaysWhoPausedIt() throws {
        let manager = FileSyncManager()
        for (pause, said) in [(DocumentSurveyPause.thermal, "Paused — the Mac is running hot. Resumes on its own."),
                              (.user, "Paused.")] {
            manager.documentSurveyProgress = DocumentSurveyProgress(
                completed: 40, total: 300, phase: .paused(pause),
                startedAt: Date(timeIntervalSince1970: 1_780_315_200), readingSeconds: 60)
            let row = try #require(ActivityScanRows.rows(manager) { _ in }.first)
            #expect(row.run.title == "Reading documents · paused at 40 of 300")
            #expect(row.run.detail == said, "paused by \(pause)")
        }
    }

    /// A source's own reading is shown on To File's strip, so its row's Show goes there rather
    /// than to Organize's card, which shows only the primary survey's reading.
    @Test func aSourcesReadingShowsToFile() {
        let manager = FileSyncManager()
        manager.documentSurveyProgress = DocumentSurveyProgress(completed: 1, total: 3, phase: .reading,
                                                                startedAt: Date(), readingSeconds: 1)
        var shown: [ActivityScan] = []
        ActivityScanRows.rows(manager) { shown.append($0) }.first?.onShow?()
        manager.documentSurveySourceRoot = "/g/My Drive/Documents"
        ActivityScanRows.rows(manager) { shown.append($0) }.first?.onShow?()
        #expect(shown == [.readDocuments, .readSourceDocuments])
    }
}
