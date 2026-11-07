import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Dashboard

/// A folder whose siblings can't be listed is reported at WARN once per launch, then Debug: the
/// listing re-runs on every navigation, so a WARN per step into any child of one unreadable folder
/// would repeat without bound, and Debug alone left no trace at the shipped level.
@MainActor
@Suite struct FolderJumpFailureReportTests {
    @Test func theFirstFailureUnderAParentIsAWarningAndTheRestAreDebug() async {
        let root = "/FolderJumpFailureReportTests-\(UUID().uuidString)"
        let log = LogCapture()
        FolderJump.reportSiblingFailure("jump probe a \(root)", rootPath: root, relativePath: "Locked/A", logger: .shared)
        FolderJump.reportSiblingFailure("jump probe b \(root)", rootPath: root, relativePath: "Locked/B", logger: .shared)
        FolderJump.reportSiblingFailure("jump probe c \(root)", rootPath: root, relativePath: "Other/C", logger: .shared)
        let lines = await log.entries.filter { $0.message.contains(root) }

        #expect(lines.map(\.level) == [.warning, .debug, .warning],
                "\(lines.map(\.level)) — one WARN per unreadable parent folder per launch, not one per child stepped into")
    }
}
