@testable import SyncCloud
import Sync
import Testing
import Foundation

/// That the incomplete-comparison warning reaches the screen. `PartialComparison` is a pure rule
/// with its own Sync suite, and a rule with no caller passes its own tests forever. The fact travels
/// manager → `bottomPaneView`, and every hop is defaulted or optional, so any one can be dropped with
/// nothing going red. Source-scanned because `ContentView` is a `View` with `@State` and can't be
/// built here.
@Suite struct PartialComparisonBannerTests {

    static func appSource() throws -> String { sourceCodeOnly(try macAppFile("ContentView.swift")) }

    /// The banner is mounted in the pane that holds the differences table, not somewhere the user has
    /// to go looking.
    @Test func theBannerIsMountedAboveTheDifferencesTable() throws {
        let code = try Self.appSource()
        #expect(code.contains("partialComparisonBanner(message)"),
                "the incomplete-comparison warning is never rendered — the only signal is a log line")
        #expect(code.contains("if selectedWorkspace == .compare, let message = partialComparisonMessage"),
                "the banner is not gated on Compare and a live message")
    }

    /// Named off the scan's own providers, not the panes: a pane navigated after the scan would
    /// rename the source, and the reader would check an account that was never compared.
    @Test func theMessageIsNamedOffTheScansOwnProviders() throws {
        let code = try Self.appSource()
        #expect(code.contains("syncManager.lastScanProviders"),
                "the banner names the panes' current sources rather than the ones that were scanned")
        #expect(code.contains("syncManager.lastScanCoverage.message(leftName:"),
                "the wording is re-spelled in the view instead of coming from PartialComparison")
    }

    /// The coverage is published under the same gate as the rows, so the two can't describe
    /// different scans. Scanned on the manager's source for the same reason as above.
    @Test func theCoverageIsPublishedWithTheRowsItDescribes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Sync/Sources/Sync/FileSyncManager+Scanning.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("self.lastScanCoverage = outcome.coverage"),
                "the coverage is not published, so the banner can never appear")
        #expect(code.contains("coverage: PartialComparison.of(left: leftFilesInfo, right: rightFilesInfo)"),
                "a scan branch computes no coverage — one of the two would warn and the other would not")
        #expect(code.components(separatedBy: "PartialComparison.of(").count == 3,
                "both compute branches — cached trees and cold disk walk — must report coverage, or the warning depends on cache state")
    }
}
