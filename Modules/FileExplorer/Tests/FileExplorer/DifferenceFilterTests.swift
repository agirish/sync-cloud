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
        #expect(DifferenceFilter.all.matches(diff(.missingOnLeft, .copyToLeft)))
        #expect(DifferenceFilter.all.matches(diff(.missingOnRight, .copyToRight)))
        #expect(DifferenceFilter.all.matches(diff(.differentDates, .copyToRight)))
    }

    @Test func testMissingFiltersBySide() {
        #expect(DifferenceFilter.missingOnLeft.matches(diff(.missingOnLeft, .copyToLeft)))
        #expect(!DifferenceFilter.missingOnLeft.matches(diff(.missingOnRight, .copyToRight)))

        #expect(DifferenceFilter.missingOnRight.matches(diff(.missingOnRight, .copyToRight)))
        #expect(!DifferenceFilter.missingOnRight.matches(diff(.missingOnLeft, .copyToLeft)))
    }

    @Test func testChangedFiltersOnTypeAndAction() {
        // changedCopyToRight requires differentDates AND copyToRight.
        #expect(DifferenceFilter.changedCopyToRight.matches(diff(.differentDates, .copyToRight)))
        #expect(!DifferenceFilter.changedCopyToRight.matches(diff(.differentDates, .copyToLeft)))   // wrong action
        #expect(!DifferenceFilter.changedCopyToRight.matches(diff(.missingOnRight, .copyToRight)))  // wrong type

        // changedCopyToLeft requires differentDates AND copyToLeft.
        #expect(DifferenceFilter.changedCopyToLeft.matches(diff(.differentDates, .copyToLeft)))
        #expect(!DifferenceFilter.changedCopyToLeft.matches(diff(.differentDates, .copyToRight)))
    }
}
