import Testing
import Foundation
@testable import Sync

/// Every lens's findings belong to the provider they were found in, and a provider switch drops
/// all of them.
///
/// **The rule was real and the list was incomplete.** Both provider-switch handlers in
/// `ContentView` cleared duplicates, filing and the automation dry-run inline, under the comment
/// "stale Tidy results must not outlive their provider". The risky-name finding — which became a
/// Tidy result when Rename folded into Organize, and is now published by the Filing scan rather
/// than by a lens of its own — was in neither list. `clearFiling()` does not cover it: the name
/// scan has its own `ScanLifecycle`, its own root and its own results.
///
/// So it outlived its provider. Switch accounts and Organize kept showing the previous one's
/// finding, with `hasScannedNames` still true so the chip stayed up; "Fix all" would then have
/// renamed those files under the OLD provider's ruleset, at absolute paths under the OLD
/// provider's root, while the window said you were somewhere else.
///
/// This suite exists because the defect was an *omission from a list*, which is the one kind of
/// defect no test of the individual clears can catch — each of them worked perfectly.
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

    /// The one assertion the shipped code failed. Each lens is checked separately so a failure
    /// names the lens that was forgotten rather than just "something survived".
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
        // The one that shipped broken.
        #expect(m.riskyNames.isEmpty, "the risky-name finding outlived the provider switch")
        #expect(m.hasScannedNames == false,
                "Organize still reports a completed name scan, so its chip stays up on the new provider")
        #expect(m.nameScanRoot == nil,
                "the finding is still labelled with the old provider's root")
    }

    /// The finding's *root* is what makes a stale list dangerous rather than merely wrong: the
    /// rows carry absolute paths under the provider that is no longer selected, and the fix path
    /// renames by those paths.
    @Test func aStaleFindingWouldHaveCarriedTheOldProvidersAbsolutePaths() {
        let m = manager()
        let staleRoot = try! #require(m.nameScanRoot).path
        #expect(m.riskyNames.allSatisfy { $0.id.hasPrefix(staleRoot) },
                "fixture is not representative — the rows must be rooted under the old provider")

        m.clearLensResultsForProviderSwitch()
        #expect(m.riskyNames.isEmpty)
    }
}
