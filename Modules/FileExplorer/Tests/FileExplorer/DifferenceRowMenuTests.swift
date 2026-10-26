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

    /// **A file Edit does not open, no editor**: the same predicate every other door asks refuses
    /// a `.docx`, so this list must too. It was a PDF until Edit read PDFs (Phase 2) — flipped on
    /// purpose, and a PDF has its own test below.
    @Test func aRowEditCannotOpenOffersTheEditorOnNeitherSide() {
        #expect(!EditableText.opensInEdit(path: "/icloud/docs/report.docx"), "the premise: Edit refuses a .docx")
        for type in [FileDifference.DifferenceType.differentDates, .missingOnRight, .missingOnLeft] {
            #expect(DifferenceRowMenu.editableSides(for: diff(type, relativePath: "docs/report.docx",
                                                              left: "/icloud/docs/report.docx",
                                                              right: "/dropbox/docs/report.docx"),
                                                    paneNames: names).isEmpty,
                    "a .docx row offers Open in Edit (\(type))")
        }
    }

    /// **A PDF row offers Open in Edit on each side that exists** — Edit opens it read-only, and
    /// the hand-off routes it there (`EditorOpenRoute`).
    @Test func aPDFRowOffersTheEditorOnEachSideThatExists() {
        func sides(_ type: FileDifference.DifferenceType) -> [DifferenceRowMenu.Side] {
            DifferenceRowMenu.editableSides(for: diff(type, relativePath: "docs/report.pdf",
                                                      left: "/icloud/docs/report.pdf",
                                                      right: "/dropbox/docs/report.pdf"),
                                            paneNames: names)
        }
        #expect(sides(.differentDates) == [.init(paneName: "iCloud", path: "/icloud/docs/report.pdf"),
                                           .init(paneName: "Dropbox", path: "/dropbox/docs/report.pdf")])
        #expect(sides(.missingOnRight) == [.init(paneName: "iCloud", path: "/icloud/docs/report.pdf")])
        #expect(sides(.missingOnLeft) == [.init(paneName: "Dropbox", path: "/dropbox/docs/report.pdf")])
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

    // MARK: A row's Copy to … items

    private func held(_ type: FileDifference.DifferenceType, _ reason: FileDifference.HeldBack?,
                      action: FileDifference.SyncAction = .copyToRight) -> FileDifference {
        FileDifference(relativePath: "docs/report.txt", leftItemPath: "/icloud/docs/report.txt",
                       rightItemPath: "/dropbox/docs/report.txt", type: type, action: action,
                       description: "d", heldBack: reason)
    }

    /// **A held row offers both directions where both files exist — the way against its guess
    /// included, which nothing else in Compare reached.** Asked of a row whose guess points left
    /// as well as one pointing right, so an answer keyed on `action` cannot pass.
    @Test func aHeldPairOffersBothDirectionsWhicheverWayItsGuessPoints() {
        for action in [FileDifference.SyncAction.copyToRight, .copyToLeft] {
            #expect(DifferenceRowMenu.copyDirections(
                for: held(.differentDates, .sizesDifferWithoutANewerSide, action: action)) == [.copyToRight, .copyToLeft])
        }
    }

    /// The engine's own folder-against-file row, held by FR40: both directions.
    @Test func aFolderAgainstAFileOffersBothDirections() throws {
        let row = try EngineRows().folderAgainstFile(folderHasContents: true)
        try #require(row.heldBack == .folderVersusFile, "the premise: the engine holds this row")
        #expect(DifferenceRowMenu.copyDirections(for: row) == [.copyToRight, .copyToLeft])
    }

    /// A folder missing on one side that holds a link has one side to copy from.
    @Test func aMissingFolderHoldingALinkOffersOnlyTheSideThatExists() {
        #expect(DifferenceRowMenu.copyDirections(
            for: held(.missingOnRight, .enclosesSymbolicLink(path: "docs/lib"))) == [.copyToRight])
        #expect(DifferenceRowMenu.copyDirections(
            for: held(.missingOnLeft, .enclosesSymbolicLink(path: "docs/lib"), action: .copyToLeft)) == [.copyToLeft])
    }

    /// **Every row offers its directions, not only a held one** (owner decision 2026-10-25): a pair
    /// on both sides offers both, whichever way its suggestion points, and a row missing on one side
    /// offers the side that exists. A row copying FROM a link still offers neither — the copy would
    /// be a link too, whichever way.
    @Test func everyRowOffersItsDirectionsAndALinkSourceRowNone() {
        for type in [FileDifference.DifferenceType.differentDates, .nameConflict] {
            for action in [FileDifference.SyncAction.copyToRight, .copyToLeft] {
                #expect(DifferenceRowMenu.copyDirections(for: held(type, nil, action: action)) == [.copyToRight, .copyToLeft],
                        "\(type) \(action)")
            }
        }
        #expect(DifferenceRowMenu.copyDirections(for: held(.missingOnRight, nil)) == [.copyToRight])
        #expect(DifferenceRowMenu.copyDirections(for: held(.missingOnLeft, nil, action: .copyToLeft)) == [.copyToLeft])
        #expect(DifferenceRowMenu.copyDirections(for: held(.differentDates, .sourceIsSymbolicLink)).isEmpty)
    }

    /// **The side the user picks is checked for a link when the item fires.** The engine holds a
    /// row only when the side its SUGGESTION copies from is a link; "Copy to iCloud" on a row whose
    /// right file is a link would copy FROM it and write the link over the real left file. Real
    /// disk, through `syncFile`, with the same `attributesOfItem` read the menu item makes: refused
    /// with the link reason before its prompt is even asked. The prompt answers No, so a regression
    /// writes nothing (and sends nothing to the real Trash); the control is the suggested
    /// direction, which is not held.
    @MainActor
    @Test func copyingFromALinkTheEngineDidNotHoldIsRefused() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RowCopyLink-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
        for dir in [left, right] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let target = root.appendingPathComponent("elsewhere.txt")
        try Data("elsewhere".utf8).write(to: target)
        try Data("real, newer".utf8).write(to: left.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: right.appendingPathComponent("notes.txt"), withDestinationURL: target)
        let row = FileDifference(relativePath: "notes.txt",
                                 leftItemPath: left.appendingPathComponent("notes.txt").path,
                                 rightItemPath: right.appendingPathComponent("notes.txt").path,
                                 type: .differentDates, action: .copyToRight, description: "Mac file is newer")
        let isLink: (String) -> Bool = { path in
            (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
        }

        let against = DifferenceRowMenu.row(row, copiedTo: .copyToLeft, isSymbolicLink: isLink)
        #expect(against.heldBack == .sourceIsSymbolicLink)
        #expect(against.action == .copyToLeft)
        #expect(against.id == row.id)
        let manager = FileSyncManager()
        var asked = false
        manager.transferConfirmer = { _ in asked = true; return false }
        manager.collisionResolver = { _ in .skip }
        let copied = await manager.syncFile(against)
        #expect(!copied)
        #expect(!asked, "the copy from a link reached its confirmation prompt")
        #expect(try String(contentsOf: left.appendingPathComponent("notes.txt"), encoding: .utf8) == "real, newer",
                "the link was copied over the real left file")
        #expect(manager.banner?.message == "“notes.txt” is a link, so a copy would be a link too, not what it points to — nothing was copied")

        let with = DifferenceRowMenu.row(row, copiedTo: .copyToRight, isSymbolicLink: isLink)
        #expect(with.heldBack == nil, "the suggested way copies from the real file and is not refused")
        #expect(with.action == .copyToRight)
    }

    /// The rule is one revert from unused, so the menu's wiring is read at source level: the row
    /// menu asks the rule, and the item it builds copies the LIVE row redirected the chosen way,
    /// with the side it copies from read for a link.
    @Test func theRowMenuOffersAndSendsTheRowDirections() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read DifferencesView.swift — every check below would be vacuous")
        let menu = try #require(source.range(of: "private func singleRowMenu(")
            .map { String(source[$0.lowerBound...].prefix(1_200)) }, "singleRowMenu is gone — this scan measures nothing")
        #expect(menu.contains("DifferenceRowMenu.copyDirections(for: difference)"),
                "the row menu no longer asks which directions a row offers")
        #expect(menu.contains("rowCopyButton(id: id, direction: .copyToRight)")
                && menu.contains("rowCopyButton(id: id, direction: .copyToLeft)"))
        let fire = try #require(source.range(of: "private func copyRowFromMenu(")
            .map { String(source[$0.lowerBound...].prefix(800)) }, "copyRowFromMenu is gone")
        #expect(fire.contains("DifferenceRowMenu.copyRefusal(for: found, direction: direction)"),
                "the item no longer re-checks the live row when it fires")
        // E10: a refusal is logged and said, not a silent return.
        #expect(fire.contains("Logger.shared.info(\"Row copy from its menu did nothing: \\(refusal)\")")
                && fire.contains("syncManager.banner = .warning(refusal)"),
                "a Copy to … item that finds nothing to do returns silently again")
        #expect(fire.contains("sendRowCopy(live, direction: direction)"), "the item no longer sends the checked row")
        let send = try #require(source.range(of: "private func sendRowCopy(")
            .map { String(source[$0.lowerBound...].prefix(900)) }, "sendRowCopy is gone")
        #expect(send.contains("DifferenceRowMenu.row(live, copiedTo: direction)"),
                "the item no longer redirects the live row through the link check")
        #expect(send.contains("(try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink"),
                "the item no longer reads the source side for a link")
        // E4: the prompts hear when this copy overwrites the newer file.
        #expect(send.contains("DifferenceRowMenu.newerDestinationNote(for: live, copiedTo: direction, paneNames: paneNames)")
                && send.contains("Task { await syncManager.syncFile(row, newerDestinationNote: note) }"),
                "the item no longer copies the checked row, with its newer-file note")
    }

    /// **The Review table's menu has the Copy to … items its banner sends the user to** (review
    /// E3). Review stays on held rows and says "right-click its row to choose which to keep"; the
    /// Review table's menu had only the inspection items. Read at source level, as above: an
    /// undecided row offers the rule's directions, and the item resolves the row when it fires,
    /// sends it the way the Compare row's does, and marks it copied only when the copy lands.
    @Test func theReviewTableMenuOffersAndSendsTheRowDirections() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read DifferencesView.swift — every check below would be vacuous")
        let table = try #require(source.range(of: "private func reviewTable(")
            .map { String(source[$0.lowerBound...].prefix(2_800)) }, "reviewTable is gone — this scan measures nothing")
        let menu = try #require(table.range(of: ".contextMenu(forSelectionType: FileDifference.ID.self)")
            .map { String(table[$0.lowerBound...]) }, "the Review table has no row menu")
        #expect(menu.contains("session.outcome(for: id) == nil"), "a decided row offers Copy again")
        #expect(menu.contains("DifferenceRowMenu.copyDirections(for: difference)"))
        #expect(menu.contains("rowCopyButton(id: id, direction: .copyToRight, inReview: true)")
                && menu.contains("rowCopyButton(id: id, direction: .copyToLeft, inReview: true)"),
                "the Review table's menu has no Copy to … items")
        let button = try #require(source.range(of: "private func rowCopyButton(")
            .map { String(source[$0.lowerBound...].prefix(500)) })
        #expect(button.contains("copyReviewRowFromMenu(id: id, direction: direction)"))
        let fire = try #require(source.range(of: "private func copyReviewRowFromMenu(")
            .map { String(source[$0.lowerBound...].prefix(1_100)) }, "copyReviewRowFromMenu is gone")
        #expect(fire.contains("let found = session.pending.first { $0.id == id }"))
        #expect(fire.contains("DifferenceRowMenu.copyRefusal(for: found, direction: direction)")
                && fire.contains("syncManager.banner = .warning(refusal)"))
        #expect(fire.contains("let copy = sendRowCopy(item, direction: direction)"),
                "the Review item no longer copies the way the Compare row's does")
        #expect(fire.contains("guard await copy.value else { return }")
                && fire.contains("reviewStore.apply(.copied, for: id, token: token)"),
                "a menu copy no longer marks the row copied only when it lands")
    }

    /// **Why a fired Copy to … item did nothing** (review E10): the row gone from the list, or no
    /// longer offering that way (a rescan found a link on the side it copies from). Both returned
    /// silently; each now has a sentence, and a row that can go has none.
    @Test func aCopyItemThatFindsNothingToDoSaysWhy() {
        #expect(DifferenceRowMenu.copyRefusal(for: nil, direction: .copyToRight)
                == "Nothing was copied — that row is no longer in the list")
        #expect(DifferenceRowMenu.copyRefusal(for: held(.differentDates, .sourceIsSymbolicLink), direction: .copyToRight)
                == "Nothing was copied — “report.txt” can no longer be copied that way")
        #expect(DifferenceRowMenu.copyRefusal(for: held(.missingOnRight, nil), direction: .copyToLeft)
                == "Nothing was copied — “report.txt” can no longer be copied that way",
                "a row missing on the left was copied from the left")
        #expect(DifferenceRowMenu.copyRefusal(for: held(.differentDates, nil), direction: .copyToLeft) == nil)
        #expect(DifferenceRowMenu.copyRefusal(for: held(.missingOnRight, nil), direction: .copyToRight) == nil)
    }

    /// **A copy against the suggestion says it overwrites the newer file** (review E4). An unheld
    /// pair of two files suggests newer over older, so the other way replaces the newer one — and
    /// its confirmation and collision prompt read like any replace. The note names the pane it
    /// lands on; the suggested way, a held row and a folder side carry none.
    @Test func aCopyAgainstTheSuggestionCarriesTheNewerFileNote() {
        let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")
        let toRight = held(.differentDates, nil, action: .copyToRight)
        #expect(DifferenceRowMenu.newerDestinationNote(for: toRight, copiedTo: .copyToLeft, paneNames: names)
                == "The file on iCloud is newer than the one you’re about to copy over it.")
        let toLeft = held(.differentDates, nil, action: .copyToLeft)
        #expect(DifferenceRowMenu.newerDestinationNote(for: toLeft, copiedTo: .copyToRight, paneNames: names)
                == "The file on Dropbox is newer than the one you’re about to copy over it.")
        #expect(DifferenceRowMenu.newerDestinationNote(for: toRight, copiedTo: .copyToRight, paneNames: names) == nil,
                "the suggested way overwrites the older file")
        #expect(DifferenceRowMenu.newerDestinationNote(
            for: held(.differentDates, .sizesDifferWithoutANewerSide), copiedTo: .copyToLeft, paneNames: names) == nil,
                "a held row has no newer side to name")
        let folderSide = FileDifference(relativePath: "a", leftItemPath: "/l/a", rightItemPath: "/r/a",
                                        type: .differentDates, action: .copyToRight, description: "d", leftIsDirectory: true)
        #expect(DifferenceRowMenu.newerDestinationNote(for: folderSide, copiedTo: .copyToLeft, paneNames: names) == nil)
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
