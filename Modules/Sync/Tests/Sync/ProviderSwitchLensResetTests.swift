import Testing
import Foundation
@testable import Sync

/// Every lens's findings belong to the provider they were found in, and a provider switch drops all
/// of them. The risky-name finding is easy to miss: the Filing scan publishes it, but it has its own
/// `ScanLifecycle`, root and results, so `clearFiling()` doesn't cover it. Left behind, Organize
/// would show the old provider's finding, and "Fix all" would rename files under the old provider's
/// rules and root. An omission from a list is what no test of the individual clears can catch.
@MainActor
@Suite struct ProviderSwitchLensResetTests {

    /// Populates every lens's published results, so a clear that misses one is visible.
    private func manager(withEveryLensPopulated: Bool = true) -> FileSyncManager {
        let m = FileSyncManager()
        m.duplicateGroups = [
            DuplicateGroup(matchType: .identical, name: "dup.pdf", isDirectory: false,
                           copies: [], reclaimableBytes: 1000)
        ]
        m.hasFoundDuplicates = true
        m.duplicateScanRoot = "/old"

        m.hasSuggestedFiling = true

        m.automationDryRun = nil
        m.automationDryRunLifecycle.hasCompleted = true

        m.riskyNames = [
            RiskyName(id: "/old/Q3: final.pdf", relativePath: "Q3: final.pdf",
                      currentName: "Q3: final.pdf", sanitizedName: "Q3- final.pdf",
                      reason: "OneDrive doesn't allow \":\" in names", isDirectory: false)
        ]
        m.nameScanRoot = URL(fileURLWithPath: "/old")
        m.hasScannedNames = true
        return m
    }

    /// Each lens is checked separately, so a failure names the lens that was forgotten rather than
    /// just "something survived".
    @Test func everyLensResultIsClearedByAProviderSwitch() {
        let m = manager()

        // Not vacuous: all four really are populated before the switch.
        #expect(!m.duplicateGroups.isEmpty)
        #expect(m.hasSuggestedFiling)
        #expect(m.automationDryRunLifecycle.hasCompleted)
        #expect(!m.riskyNames.isEmpty)

        m.clearLensResultsForProviderSwitch()

        #expect(m.duplicateGroups.isEmpty, "duplicates outlived the provider switch")
        #expect(m.hasFoundDuplicates == false, "the duplicates lens still reports a completed scan")
        #expect(m.hasSuggestedFiling == false, "filing outlived the provider switch")
        #expect(m.automationDryRunLifecycle.hasCompleted == false, "the automation dry-run outlived the provider switch")
        // The one that is easy to forget, and dangerous, not merely wrong: its rows carry absolute
        // paths under the provider no longer selected, and the fix path renames by those paths.
        #expect(m.riskyNames.isEmpty, "the risky-name finding outlived the provider switch")
        #expect(m.hasScannedNames == false,
                "Organize still reports a completed name scan, so its chip stays up on the new provider")
        #expect(m.nameScanRoot == nil,
                "the finding is still labelled with the old provider's root")
    }

    // MARK: - The filing collections `clearFiling()` left standing

    /// The same rule one level down, for `clearFiling()`'s own list. `filingOCRInFlight` is a latch
    /// like `filingTryAnotherInFlight`: `readScan` releases it in a `defer`, and
    /// `filingOCRExtractor` has no timeout, so a Vision render that never returns leaves every later
    /// "Read scan" on the file a silent no-op, and nothing else clears it. The other two are stale
    /// and only grow: both are keyed by absolute path under the old provider.
    @Test func clearFilingClearsTheCollectionsKeyedToTheOldProvider() {
        let m = FileSyncManager()
        m.filingOCRInFlight = ["/old/Scan 1.pdf"]
        m.filingUnreadableScans = ["/old/Scan 1.pdf", "/old/Scan 2.pdf"]
        m.filingPageSamples = ["/old/Scan 1.pdf": "eOCI Card | Government of India"]

        // Not vacuous: all three really are populated before the clear.
        #expect(!m.filingOCRInFlight.isEmpty)
        #expect(!m.filingUnreadableScans.isEmpty)
        #expect(!m.filingPageSamples.isEmpty)

        m.clearFiling()

        #expect(m.filingOCRInFlight.isEmpty,
                "the OCR latch outlived the provider switch — a render that never returned leaves that file's Read scan a permanent no-op")
        #expect(m.filingUnreadableScans.isEmpty,
                "the old provider's unreadable scans still drive the Read scan offer")
        #expect(m.filingPageSamples.isEmpty,
                "page-1 text for the old provider's files is still held, and only grows per switch")
    }

    /// The same through the path a provider switch takes: testing only `clearFiling()` would pass on
    /// a build where nothing calls it.
    @Test func aProviderSwitchClearsThemToo() {
        let m = FileSyncManager()
        m.filingOCRInFlight = ["/old/Scan 1.pdf"]
        m.filingUnreadableScans = ["/old/Scan 1.pdf"]
        m.filingPageSamples = ["/old/Scan 1.pdf": "some page one text"]

        m.clearLensResultsForProviderSwitch()

        #expect(m.filingOCRInFlight.isEmpty)
        #expect(m.filingUnreadableScans.isEmpty)
        #expect(m.filingPageSamples.isEmpty)
    }
}
