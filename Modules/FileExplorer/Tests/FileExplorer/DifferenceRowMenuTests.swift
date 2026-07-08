import Testing
import Sync
@testable import FileExplorer

/// Coverage for DifferenceRowMenu — the pure logic behind the differences list's
/// right-click menu: which sides get Reveal/Quick Look/Copy Path items, and how the
/// ignore toggle resolves against `FileSyncManager.ignoredPaths`.
@Suite struct DifferenceRowMenuTests {

    private let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")

    private func diff(
        _ type: FileDifference.DifferenceType,
        relativePath: String = "docs/report.txt",
        left: String = "/icloud/docs/report.txt",
        right: String = "/dropbox/docs/report.txt"
    ) -> FileDifference {
        FileDifference(
            relativePath: relativePath, leftItemPath: left, rightItemPath: right,
            type: type,
            action: type == .missingOnLeft ? .copyToLeft : .copyToRight,
            description: "d"
        )
    }

    // MARK: Which sides exist

    @Test func testMissingOnRightOffersOnlyLeftSide() {
        let sides = DifferenceRowMenu.existingSides(for: diff(.missingOnRight), paneNames: names)
        #expect(sides == [.init(paneName: "iCloud", path: "/icloud/docs/report.txt")])
    }

    @Test func testMissingOnLeftOffersOnlyRightSide() {
        let sides = DifferenceRowMenu.existingSides(for: diff(.missingOnLeft), paneNames: names)
        #expect(sides == [.init(paneName: "Dropbox", path: "/dropbox/docs/report.txt")])
    }

    @Test func testDifferentDatesOffersBothSidesLeftFirst() {
        let sides = DifferenceRowMenu.existingSides(for: diff(.differentDates), paneNames: names)
        #expect(sides == [
            .init(paneName: "iCloud", path: "/icloud/docs/report.txt"),
            .init(paneName: "Dropbox", path: "/dropbox/docs/report.txt"),
        ])
    }

    @Test func testSameProviderOnBothSidesYieldsDistinctPaneNames() {
        // The menu ForEach keys per-side items by paneName, so the two sides must never
        // collide even when both panes show the same provider.
        let sameNames = PaneProviderNames(leftName: "iCloud", rightName: "iCloud")
        let sides = DifferenceRowMenu.existingSides(for: diff(.differentDates), paneNames: sameNames)
        #expect(sides.map(\.paneName) == ["iCloud (left)", "iCloud (right)"])
    }

    // MARK: Ignore toggle

    @Test func testToggleIgnoresUsingRelativePath() {
        let d = diff(.differentDates)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(for: d, ignoredPaths: [])
        #expect(updated == ["docs/report.txt"])
        // The inserted target must satisfy the exact predicate applyFilters() uses to drop
        // differences, so the row is guaranteed to leave the list.
        #expect(FileSyncManager.isIgnoredPath(d.relativePath, ignored: updated))
    }

    @Test func testToggleRemovesExistingIgnoreEntry() {
        let d = diff(.differentDates)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(for: d, ignoredPaths: ["docs/report.txt", "other"])
        #expect(updated == ["other"])
    }

    @Test func testTogglePreservesUnrelatedEntries() {
        let d = diff(.missingOnRight)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(for: d, ignoredPaths: ["keep/me"])
        #expect(updated == ["keep/me", "docs/report.txt"])
    }

    // MARK: Ignored state (drives the Ignore/Include label)

    @Test func testIsIgnoredMatchesExactPath() {
        let d = diff(.differentDates)
        #expect(DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs/report.txt"]))
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs/other.txt"]))
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: []))
    }

    @Test func testIsIgnoredMatchesAncestorDirectoryButNotSiblingPrefix() {
        // Same prefix semantics as the differences filter: an ignored ancestor folder
        // covers the row, but "docs/rep" must not cover "docs/report.txt".
        let d = diff(.differentDates)
        #expect(DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs"]))
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs/rep"]))
    }
}
