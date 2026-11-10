import Foundation
import Testing

/// Events shows a run's Undo… refusal itself, in its own alert.
///
/// The reason comes from `FileSyncManager.undoLastSyncRunAskingFirst`, tested in the Sync package.
/// This covers the view's half: the button keeping that reason, and an alert that shows it. Drop
/// either and a refused click looks dead. SwiftUI can't be driven from a unit test, so this reads
/// the source with comments stripped, so a comment quoting the call can't satisfy the scan.
@Suite struct SyncHistoryUndoRefusalWiringTests {

    private static func code() throws -> String {
        try DashboardSource.read("ActivityEventsView.swift", codeOnly: true)
    }

    /// A run's Undo… keeps what the click answers, rather than discarding it.
    @Test func theButtonKeepsTheRefusal() throws {
        let code = try Self.code()
        let label = try #require(code.range(of: "Label(\"Undo…\""),
                                 "no Undo… button — this test names something that no longer exists")
        let button = try #require(code[..<label.lowerBound].range(of: "Button {", options: .backwards))
        let action = code[button.upperBound..<label.lowerBound]
        #expect(action.contains("undoRefusal = onUndoRun()"),
                "a run's Undo… no longer keeps the refusal — a refused click shows nothing")
    }

    /// An alert in the window's body is up while there is a refusal, and says it.
    @Test func theBodyShowsTheRefusalInAnAlert() throws {
        let code = try Self.code()
        let body = try #require(code.range(of: "public var body: some View {"))
        let end = try #require(code[body.upperBound...].range(of: "\n    }\n"), "cannot find the end of body")
        let bodyText = code[body.upperBound..<end.lowerBound]
        let alert = try #require(bodyText.range(of: ".alert(Self.undoRefusalTitle"),
                                 "the window's body no longer presents the refusal alert")
        let presenting = bodyText[alert.upperBound...]
        #expect(presenting.contains("get: { undoRefusal != nil }"), "the alert is not tied to the refusal")
        #expect(presenting.contains("Text(undoRefusal ?? \"\")"), "the alert does not say the reason")
    }
}
