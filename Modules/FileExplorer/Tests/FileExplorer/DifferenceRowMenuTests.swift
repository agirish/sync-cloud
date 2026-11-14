import Testing
import Foundation
import Sync
@testable import FileExplorer

/// `DifferenceRowMenu`, the pure logic behind the differences list's right-click menu: which sides
/// get Reveal, Quick Look, Copy Path and Open in Edit, which Copy to … directions a row offers, and
/// how the ignore toggle resolves against `FileSyncManager.ignoredPaths`.
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

    /// A missing side offers nothing; both sides come left first.
    @Test(arguments: [
        (FileDifference.DifferenceType.missingOnRight,
         [DifferenceRowMenu.Side(paneName: "iCloud", path: "/icloud/docs/report.txt")]),
        (.missingOnLeft, [.init(paneName: "Dropbox", path: "/dropbox/docs/report.txt")]),
        (.differentDates, [.init(paneName: "iCloud", path: "/icloud/docs/report.txt"),
                           .init(paneName: "Dropbox", path: "/dropbox/docs/report.txt")]),
    ])
    func testWhichSidesExist(_ type: FileDifference.DifferenceType, _ expected: [DifferenceRowMenu.Side]) {
        #expect(DifferenceRowMenu.existingSides(for: diff(type), paneNames: names) == expected)
    }

    @Test func testSameProviderOnBothSidesYieldsDistinctPaneNames() {
        // The menu's ForEach keys per-side items by paneName, so the two sides must never
        // collide, even when both panes show the same provider.
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

    /// A text file on both sides is offered on both, left first, like every other per-side group.
    @Test func aTextFileOnBothSidesOffersTheEditorOnBothLeftFirst() {
        #expect(DifferenceRowMenu.editableSides(for: textRow(.differentDates), paneNames: names) == [
            .init(paneName: "iCloud", path: "/icloud/docs/notes.md"),
            .init(paneName: "Dropbox", path: "/dropbox/docs/notes.md"),
        ])
    }

    /// A row missing on a side offers only the side that is there; the missing side's path would
    /// open a file that doesn't exist.
    @Test func aOneSidedTextRowOffersOnlyTheSideThatExists() {
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnRight), paneNames: names)
                == [.init(paneName: "iCloud", path: "/icloud/docs/notes.md")])
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnLeft), paneNames: names)
                == [.init(paneName: "Dropbox", path: "/dropbox/docs/notes.md")])
    }

    /// A file Edit doesn't open gets no editor: the predicate every other door asks refuses a
    /// `.docx`, so this list must too. A PDF has its own test below.
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

    /// A PDF row offers Open in Edit on each side that exists: Edit opens it read-only, routed by
    /// `EditorOpenRoute`.
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

    /// A folder is refused on the scan's folder fact, not its name. Named like a text file on
    /// purpose: `EditableText.isText` says yes to `notes.md`, so a fixture called `Notes` would be
    /// refused by its extension and pass with the folder rule deleted.
    @Test func aFolderRowOffersTheEditorOnNeitherSideEvenWhenNamedLikeText() {
        #expect(EditableText.isText(path: "/icloud/docs/notes.md"),
                "the premise: the fixture's name alone would be offered")
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnRight, enclosedItemCount: 3,
                                                             leftIsDirectory: true),
                                                paneNames: names).isEmpty,
                "a folder row offers Open in Edit")
        // An empty folder carries no count, so the count alone can't tell it is a folder.
        #expect(DifferenceRowMenu.editableSides(for: textRow(.missingOnLeft, rightIsDirectory: true),
                                                paneNames: names).isEmpty,
                "an empty folder row offers Open in Edit")
        #expect(DifferenceRowMenu.editableSides(for: textRow(.nameConflict, leftIsDirectory: true,
                                                             rightIsDirectory: true),
                                                paneNames: names).isEmpty,
                "a name-conflicted folder pair offers Open in Edit")
    }

    /// A folder against a file offers only the file side: each side is asked its own question. The
    /// row's count, set when the folder has contents, says nothing about which side is the folder.
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

    /// The same four shapes, built by the real engine, so the folder facts the menu reads are the
    /// ones a comparison records. A rule asking the row's count would get each of these wrong.
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

    /// A held row offers both directions where both files exist, including against its guess.
    /// Asked with the guess pointing each way, so an answer keyed on `action` can't pass.
    @Test func aHeldPairOffersBothDirectionsWhicheverWayItsGuessPoints() {
        for action in [FileDifference.SyncAction.copyToRight, .copyToLeft] {
            #expect(DifferenceRowMenu.copyDirections(
                for: held(.differentDates, .sizesDifferWithoutANewerSide, action: action)) == [.copyToRight, .copyToLeft])
        }
    }

    /// The engine's own folder-against-file row, which it holds back: both directions.
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

    /// Every row offers its directions, not only a held one: a pair offers both, whichever way its
    /// suggestion points, and a one-sided row the side that exists. A row copying from a link
    /// offers neither, since the copy would be a link too.
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

    /// The side the user picks is checked for a link when the item fires. The engine holds a row
    /// only when its suggestion copies from a link, so "Copy to iCloud" from a linked right file
    /// would write the link over the real left file. Real disk, through `syncFile`: refused before
    /// the prompt. The prompt answers No, so a regression writes nothing and trashes nothing.
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

    /// The rule is one revert from unused, so the wiring is read at source level: the row menu asks
    /// the rule, and its item copies the live row redirected the chosen way, its source side read
    /// for a link.
    @Test func theRowMenuOffersAndSendsTheRowDirections() throws {
        let source = try SourceText.fileExplorer("DifferencesView.swift")
        let menu = try SourceText.block(opening: "private func singleRowMenu(", in: source)
        #expect(menu.contains("DifferenceRowMenu.copyDirections(for: difference)"),
                "the row menu no longer asks which directions a row offers")
        #expect(menu.contains("rowCopyButton(id: id, direction: .copyToRight)")
                && menu.contains("rowCopyButton(id: id, direction: .copyToLeft)"))
        let fire = try SourceText.block(opening: "private func copyRowFromMenu(", in: source)
        #expect(fire.contains("DifferenceRowMenu.copyRefusal(for: found, direction: direction)"),
                "the item no longer re-checks the live row when it fires")
        // A refusal is logged and said, not a silent return.
        #expect(fire.contains("Logger.shared.info(\"Row copy from its menu did nothing: \\(refusal)\")")
                && fire.contains("syncManager.banner = .refusal(refusal, log: .warn)"),
                "a Copy to … item that finds nothing to do returns silently again")
        #expect(fire.contains("sendRowCopy(live, direction: direction)"), "the item no longer sends the checked row")
        let send = try SourceText.block(opening: "private func sendRowCopy(", in: source)
        #expect(send.contains("DifferenceRowMenu.row(live, copiedTo: direction)"),
                "the item no longer redirects the live row through the link check")
        #expect(send.contains("(try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink"),
                "the item no longer reads the source side for a link")
        // The prompts hear when this copy overwrites the newer file.
        #expect(send.contains("DifferenceRowMenu.newerDestinationNote(for: live, copiedTo: direction, paneNames: paneNames)")
                && send.contains("Task { await syncManager.syncFile(row, newerDestinationNote: note) }"),
                "the item no longer copies the checked row, with its newer-file note")
    }

    /// The Review table's menu has the Copy to … items its banner sends the user to ("right-click
    /// its row to choose which to keep"). At source level: an undecided row offers the rule's
    /// directions, and the item resolves the row when it fires, sends it as the Compare row does,
    /// and marks it copied only when the copy lands.
    @Test func theReviewTableMenuOffersAndSendsTheRowDirections() throws {
        let source = try SourceText.fileExplorer("DifferencesView.swift")
        let table = try SourceText.block(opening: "private func reviewTable(", in: source)
        let menu = try #require(table.range(of: ".contextMenu(forSelectionType: FileDifference.ID.self)")
            .map { String(table[$0.lowerBound...]) }, "the Review table has no row menu")
        #expect(menu.contains("session.outcome(for: id) == nil"), "a decided row offers Copy again")
        #expect(menu.contains("DifferenceRowMenu.copyDirections(for: difference)"))
        #expect(menu.contains("rowCopyButton(id: id, direction: .copyToRight, inReview: true)")
                && menu.contains("rowCopyButton(id: id, direction: .copyToLeft, inReview: true)"),
                "the Review table's menu has no Copy to … items")
        let button = try SourceText.block(opening: "private func rowCopyButton(", in: source)
        #expect(button.contains("copyReviewRowFromMenu(id: id, direction: direction)"))
        let fire = try SourceText.block(opening: "private func copyReviewRowFromMenu(", in: source)
        #expect(fire.contains("let found = session.pending.first { $0.id == id }"))
        #expect(fire.contains("DifferenceRowMenu.copyRefusal(for: found, direction: direction)")
                && fire.contains("syncManager.banner = .refusal(refusal, log: .warn)"))
        #expect(fire.contains("let copy = sendRowCopy(item, direction: direction)"),
                "the Review item no longer copies the way the Compare row's does")
        #expect(fire.contains("guard await copy.value else { return }")
                && fire.contains("reviewStore.apply(.copied, for: id, token: token)"),
                "a menu copy no longer marks the row copied only when it lands")
    }

    /// A fired Copy to … item that does nothing says why: the row is gone from the list, or no
    /// longer offers that way (a rescan found a link on its source side). A row that can go gets
    /// no sentence.
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

    /// A copy against the suggestion says it overwrites the newer file: an unheld pair suggests
    /// newer over older, so the other way replaces the newer one. The note names the pane it lands
    /// on; the suggested way, a held row and a folder side carry none.
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

    /// The toggle on `docs/report.txt`: it inserts the relative path, removes an exact entry, keeps
    /// unrelated ones, and on a row covered by an ancestor ("docs") removes the covering entry,
    /// since inserting the path would leave the row ignored with a dead menu item. Either way the
    /// row's state flips, by the predicate `applyFilters()` uses to drop differences too.
    @Test(arguments: [
        (.differentDates, [], ["docs/report.txt"]),
        (.differentDates, ["docs/report.txt", "other"], ["other"]),
        (.missingOnRight, ["keep/me"], ["keep/me", "docs/report.txt"]),
        (.differentDates, ["docs", "other"], ["other"]),
        (.differentDates, ["docs", "docs/report.txt"], []),
    ] as [(FileDifference.DifferenceType, Set<String>, Set<String>)])
    func testToggle(_ type: FileDifference.DifferenceType, _ before: Set<String>, _ expected: Set<String>) {
        let d = diff(type)
        let updated = DifferenceRowMenu.toggledIgnoredPaths(for: d, ignoredPaths: before)
        #expect(updated == expected)
        let ignored = DifferenceRowMenu.isIgnored(d, ignoredPaths: updated)
        #expect(ignored == !DifferenceRowMenu.isIgnored(d, ignoredPaths: before))
        #expect(FileSyncManager.isIgnoredPath(d.relativePath, ignored: updated) == ignored)
    }

    // MARK: Ignored state (drives the Ignore/Include label)

    @Test func testIsIgnoredMatchesExactPath() {
        let d = diff(.differentDates)
        #expect(DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs/report.txt"]))
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: ["docs/other.txt"]))
        #expect(!DifferenceRowMenu.isIgnored(d, ignoredPaths: []))
    }

    @Test func testIsIgnoredMatchesAncestorDirectoryButNotSiblingPrefix() {
        // As in the differences filter: an ignored ancestor folder covers the row, but
        // "docs/rep" must not cover "docs/report.txt".
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
