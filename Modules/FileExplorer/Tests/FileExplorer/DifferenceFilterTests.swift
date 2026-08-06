import Testing
import Sync
@testable import FileExplorer

/// Coverage for DifferenceFilter.matches — the predicate driving what the differences list shows.
/// The two "changed" cases discriminate on BOTH type and action, a compound condition easy to break.
@Suite struct DifferenceFilterTests {

    private func diff(_ type: FileDifference.DifferenceType, _ action: FileDifference.SyncAction) -> FileDifference {
        FileDifference(relativePath: "x", leftItemPath: "/l/x", rightItemPath: "/r/x",
                       type: type, action: action, description: "d")
    }

    @Test func testAllAcceptsEveryDifference() {
        #expect(DifferenceFilter.all.matches(diff(.missingOnLeft, .copyToLeft), failedIDs: []))
        #expect(DifferenceFilter.all.matches(diff(.missingOnRight, .copyToRight), failedIDs: []))
        #expect(DifferenceFilter.all.matches(diff(.differentDates, .copyToRight), failedIDs: []))
    }

    @Test func testMissingFiltersBySide() {
        #expect(DifferenceFilter.missingOnLeft.matches(diff(.missingOnLeft, .copyToLeft), failedIDs: []))
        #expect(!DifferenceFilter.missingOnLeft.matches(diff(.missingOnRight, .copyToRight), failedIDs: []))

        #expect(DifferenceFilter.missingOnRight.matches(diff(.missingOnRight, .copyToRight), failedIDs: []))
        #expect(!DifferenceFilter.missingOnRight.matches(diff(.missingOnLeft, .copyToLeft), failedIDs: []))
    }

    @Test func testChangedFiltersOnTypeAndAction() {
        // changedCopyToRight requires differentDates AND copyToRight.
        #expect(DifferenceFilter.changedCopyToRight.matches(diff(.differentDates, .copyToRight), failedIDs: []))
        #expect(!DifferenceFilter.changedCopyToRight.matches(diff(.differentDates, .copyToLeft), failedIDs: []))   // wrong action
        #expect(!DifferenceFilter.changedCopyToRight.matches(diff(.missingOnRight, .copyToRight), failedIDs: []))  // wrong type

        // changedCopyToLeft requires differentDates AND copyToLeft.
        #expect(DifferenceFilter.changedCopyToLeft.matches(diff(.differentDates, .copyToLeft), failedIDs: []))
        #expect(!DifferenceFilter.changedCopyToLeft.matches(diff(.differentDates, .copyToRight), failedIDs: []))
    }

    @Test func testDisplayNameUsesProviderNames() {
        #expect(DifferenceFilter.all.displayName(leftName: "iCloud", rightName: "Dropbox") == "All")
        #expect(DifferenceFilter.missingOnLeft.displayName(leftName: "iCloud", rightName: "Dropbox") == "Missing on iCloud")
        #expect(DifferenceFilter.missingOnRight.displayName(leftName: "iCloud", rightName: "Dropbox") == "Missing on Dropbox")
        // The "changed" cases name the NEWER side: copyToRight means the left copy is newer.
        #expect(DifferenceFilter.changedCopyToRight.displayName(leftName: "iCloud", rightName: "Dropbox") == "Changed (iCloud newer)")
        #expect(DifferenceFilter.changedCopyToLeft.displayName(leftName: "iCloud", rightName: "Dropbox") == "Changed (Dropbox newer)")
        // The one label that names neither pane: it is about an event, not a side.
        #expect(DifferenceFilter.failed.displayName(leftName: "iCloud", rightName: "Dropbox") == "Failed to transfer")
    }

    /// `.failed` ignores every property the shape filters read, and answers only from the id set.
    /// Both fixtures use the SAME difference, so nothing but the set can be deciding.
    @Test func testFailedFiltersOnTheIDSetAndNothingElse() {
        let d = diff(.missingOnRight, .copyToRight)
        #expect(DifferenceFilter.failed.matches(d, failedIDs: [d.id]))
        #expect(!DifferenceFilter.failed.matches(d, failedIDs: []))
        // ...and a shape filter is deaf to the set, or a failed row would vanish from the
        // filter that describes what it IS the moment a transfer failed on it.
        #expect(DifferenceFilter.missingOnRight.matches(d, failedIDs: []))
        #expect(DifferenceFilter.missingOnRight.matches(d, failedIDs: [d.id]))
    }

    @Test func testDisplayNameWithSpatialFallbackMatchesOriginalLabels() {
        // With the Left/Right fallback names the labels must read exactly as they did
        // before the provider-name refactor.
        let names = PaneProviderNames.leftRight
        #expect(DifferenceFilter.missingOnLeft.displayName(leftName: names.left, rightName: names.right) == "Missing on Left")
        #expect(DifferenceFilter.missingOnRight.displayName(leftName: names.left, rightName: names.right) == "Missing on Right")
        #expect(DifferenceFilter.changedCopyToRight.displayName(leftName: names.left, rightName: names.right) == "Changed (Left newer)")
        #expect(DifferenceFilter.changedCopyToLeft.displayName(leftName: names.left, rightName: names.right) == "Changed (Right newer)")
    }

    @Test func testMatchingLogicIsIndependentOfDisplayName() {
        // Display is derived per-render from provider names; matching keys off case identity.
        for filter in DifferenceFilter.allCases {
            let renamed = filter.displayName(leftName: "A", rightName: "B")
            #expect(renamed.isEmpty == false)
        }
        #expect(DifferenceFilter.missingOnLeft.matches(diff(.missingOnLeft, .copyToLeft), failedIDs: []))
    }
}

/// Coverage for PaneProviderNames — pane display names with same-provider disambiguation.
@Suite struct PaneProviderNamesTests {

    @Test func testDistinctProvidersUsePlainNames() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Google Drive")
        #expect(names.left == "iCloud")
        #expect(names.right == "Google Drive")
    }

    @Test func testSameProviderIsDisambiguatedBySide() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "iCloud")
        #expect(names.left == "iCloud (left)")
        #expect(names.right == "iCloud (right)")
    }

    @Test func testMissingNamesFallBackToLeftRight() {
        let names = PaneProviderNames(leftName: nil, rightName: nil)
        #expect(names.left == "Left")
        #expect(names.right == "Right")

        // One-sided nil: the resolved side keeps its provider name.
        let partial = PaneProviderNames(leftName: "Dropbox", rightName: nil)
        #expect(partial.left == "Dropbox")
        #expect(partial.right == "Right")
    }

    @Test func testOtherReturnsOppositePane() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        #expect(names.other(isLeft: true) == "Dropbox")
        #expect(names.other(isLeft: false) == "iCloud")
    }
}
