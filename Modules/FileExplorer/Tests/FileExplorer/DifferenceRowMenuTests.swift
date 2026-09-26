import Testing
import Foundation
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

    private func textRow(_ type: FileDifference.DifferenceType, enclosedItemCount: Int? = nil,
                         leftIsDirectory: Bool = false, rightIsDirectory: Bool = false) -> FileDifference {
        FileDifference(
            relativePath: "docs/notes.md", leftItemPath: "/icloud/docs/notes.md",
            rightItemPath: "/dropbox/docs/notes.md", type: type,
            action: type == .missingOnLeft ? .copyToLeft : .copyToRight, description: "d",
            enclosedItemCount: enclosedItemCount,
            leftIsDirectory: leftIsDirectory, rightIsDirectory: rightIsDirectory
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

    /// **A folder is refused on the scan's folder fact, not on its name.** Named like a text file
    /// on purpose: `EditableText.isText` answers true for a directory called `notes.md`, so a
    /// fixture called `Notes` would be refused by the extension and never reach the folder rule —
    /// the test would pass with the rule deleted.
    @Test func aFolderRowOffersTheEditorOnNeitherSideEvenWhenNamedLikeText() {
        #expect(EditableText.isText(path: "/icloud/docs/notes.md"),
                "the premise: the fixture's name alone would be offered")
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnRight, enclosedItemCount: 3,
                                                             leftIsDirectory: true),
                                                paneNames: names).isEmpty,
                "a folder row offers Open in Edit")
        // An EMPTY folder carries no count — the case the count could not see.
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnLeft, rightIsDirectory: true),
                                                paneNames: names).isEmpty,
                "an empty folder row offers Open in Edit")
        #expect(DifferenceRowMenu.editableSides(for: textRow(.nameConflict, leftIsDirectory: true,
                                                             rightIsDirectory: true),
                                                paneNames: names).isEmpty,
                "a name-conflicted folder pair offers Open in Edit")
    }

    /// **A folder against a file offers the FILE side, and only that side** — each side is asked
    /// its own question. The row's count (set when the folder has contents) says nothing about
    /// which side is the folder.
    @Test func aFolderAgainstAFileOffersOnlyTheFile() {
        #expect(DifferenceRowMenu.editableSides(for: textRow(.differentDates, enclosedItemCount: 2,
                                                             leftIsDirectory: true),
                                                paneNames: names)
                == [.init(paneName: "Dropbox", path: "/dropbox/docs/notes.md")])
        #expect(DifferenceRowMenu.editableSides(for: textRow(.differentDates, rightIsDirectory: true),
                                                paneNames: names)
                == [.init(paneName: "iCloud", path: "/icloud/docs/notes.md")])
    }

    // MARK: Rows as the scan builds them

    /// **The same four shapes, built by the real engine rather than by hand** — so the folder
    /// facts the menu reads are the ones a comparison actually records. Each of these was wrong on
    /// the count the menu used to ask (2026-09-25): the empty folder and the name-conflicted pair
    /// carry no count and were offered; the non-empty folder against a file carries one and its
    /// file side was withheld; the empty folder against a file offered the folder.
    @Test func rowsTheEngineBuildsOfferOnlyTheirTextFiles() throws {
        let rows = EngineRows()
        #expect(DifferenceRowMenu.editableSides(for: try rows.emptyFolderMissingOnRight(), paneNames: names)
                .isEmpty, "an empty folder named notes.md is offered to Edit")
        #expect(DifferenceRowMenu.editableSides(for: try rows.nameConflictedFolders(), paneNames: names)
                .isEmpty, "a name-conflicted folder pair is offered to Edit")
        #expect(DifferenceRowMenu.editableSides(for: try rows.folderAgainstFile(folderHasContents: true),
                                                paneNames: names).map(\.path) == ["/R/docs/notes.md"],
                "a non-empty folder against a text file does not offer the text file")
        #expect(DifferenceRowMenu.editableSides(for: try rows.folderAgainstFile(folderHasContents: false),
                                                paneNames: names).map(\.path) == ["/R/docs/notes.md"],
                "an empty folder against a text file offers the folder")
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

/// Differences built by `FileDiffEngine.computeDifferences` from hand-made scan maps: a left root
/// `/L` and a right root `/R`, each holding `docs`, and a `notes.md` inside it shaped per case.
struct EngineRows {
    private let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/L", type: .iCloud)
    private let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/R", type: .iCloud)

    private func info(_ path: String, directory: Bool) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: path, isDirectory: directory),
                                modificationDate: Date(timeIntervalSince1970: 1_000),
                                fileSize: directory ? nil : 10, isDirectory: directory)
    }

    private func row(left l: [String: Bool], right r: [String: Bool]) throws -> FileDifference {
        var leftInfo = ["docs": info("/L/docs", directory: true)]
        var rightInfo = ["docs": info("/R/docs", directory: true)]
        for (key, isDir) in l { leftInfo[key] = info("/L/\(key)", directory: isDir) }
        for (key, isDir) in r { rightInfo[key] = info("/R/\(key)", directory: isDir) }
        let rows = FileDiffEngine.computeDifferences(
            left: left, leftURL: URL(fileURLWithPath: "/L"), right: right, rightURL: URL(fileURLWithPath: "/R"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo)
        return try #require(rows.count == 1 ? rows.first : nil, "expected one row, got \(rows.map(\.relativePath))")
    }

    /// An empty folder `docs/notes.md` on the left, nothing on the right: no count.
    func emptyFolderMissingOnRight() throws -> FileDifference {
        try row(left: ["docs/notes.md": true], right: [:])
    }

    /// Two empty folders whose names differ by a trailing space: one `.nameConflict` row, no count.
    func nameConflictedFolders() throws -> FileDifference {
        let d = try row(left: ["docs/notes.md": true], right: ["docs/notes.md ": true])
        #expect(d.type == .nameConflict, "the fixture is not a name conflict")
        return d
    }

    /// A folder `docs/notes.md` on the left against a FILE of that name on the right.
    func folderAgainstFile(folderHasContents: Bool) throws -> FileDifference {
        var l = ["docs/notes.md": true]
        if folderHasContents { l["docs/notes.md/inner.txt"] = false }
        let d = try row(left: l, right: ["docs/notes.md": false])
        #expect((d.enclosedItemCount != nil) == folderHasContents, "the fixture's count is not what it claims")
        return d
    }
}
