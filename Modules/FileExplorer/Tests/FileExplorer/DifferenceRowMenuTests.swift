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

    // MARK: Which sides offer Open in Edit (TE31)

    private func textRow(_ type: FileDifference.DifferenceType, enclosedItemCount: Int? = nil) -> FileDifference {
        FileDifference(
            relativePath: "docs/notes.md", leftItemPath: "/icloud/docs/notes.md",
            rightItemPath: "/dropbox/docs/notes.md", type: type,
            action: type == .missingOnLeft ? .copyToLeft : .copyToRight, description: "d",
            enclosedItemCount: enclosedItemCount
        )
    }

    /// A text file on both sides is offered on both, left first — the order every other per-side
    /// group in the menu uses.
    @Test func aTextFileOnBothSidesOffersTheEditorOnBothLeftFirst() {
        #expect(DifferenceRowMenu.editableSides(for: textRow(.differentDates), paneNames: names) == [
            .init(paneName: "iCloud", path: "/icloud/docs/notes.md"),
            .init(paneName: "Dropbox", path: "/dropbox/docs/notes.md"),
        ])
    }

    /// **A row missing on a side offers only the side that is there.** Handing the editor the
    /// missing side's path would open a file that does not exist.
    @Test func aOneSidedTextRowOffersOnlyTheSideThatExists() {
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnRight), paneNames: names)
                == [.init(paneName: "iCloud", path: "/icloud/docs/notes.md")])
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnLeft), paneNames: names)
                == [.init(paneName: "Dropbox", path: "/dropbox/docs/notes.md")])
    }

    /// Not a text file, no editor: the same predicate every other door asks refuses a PDF, so this
    /// list must too.
    @Test func aRowThatIsNotTextOffersTheEditorOnNeitherSide() {
        for type in [FileDifference.DifferenceType.differentDates, .missingOnRight, .missingOnLeft] {
            #expect(DifferenceRowMenu.editableSides(for: diff(type, relativePath: "docs/report.pdf",
                                                              left: "/icloud/docs/report.pdf",
                                                              right: "/dropbox/docs/report.pdf"),
                                                    paneNames: names).isEmpty,
                    "a PDF row offers Open in Edit (\(type))")
        }
    }

    /// **A folder is refused on the scan's folder marker, not on its name.** Named like a text
    /// file on purpose: `EditableText.isText` answers true for a directory called `notes.md`, so
    /// a fixture called `Notes` would be refused by the extension and never reach the folder
    /// rule — the test would pass with the rule deleted.
    @Test func aFolderRowOffersTheEditorOnNeitherSideEvenWhenNamedLikeText() {
        #expect(EditableText.isText(path: "/icloud/docs/notes.md"),
                "the premise: the fixture's name alone would be offered")
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnRight, enclosedItemCount: 3),
                                                paneNames: names).isEmpty,
                "a folder row offers Open in Edit")
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

    @Test func testToggleOnAncestorCoveredRowUnignoresByRemovingAncestor() {
        // The row is effectively ignored via the "docs" folder entry, so isIgnored (and the
        // menu label) says "Include". The toggle must agree: remove the covering entry, not
        // insert "docs/report.txt" — which would leave the row ignored with a dead menu item.
        let d = diff(.differentDates)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(for: d, ignoredPaths: ["docs", "other"])
        #expect(updated == ["other"])
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: updated))
    }

    @Test func testToggleRemovesExactEntryAndCoveringAncestorTogether() {
        let d = diff(.differentDates)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(
            for: d, ignoredPaths: ["docs", "docs/report.txt"])
        #expect(updated.isEmpty)
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
