import Testing
import Foundation
import Events
@testable import Sync

/// Rows whose suggested direction is a guess (`FileDifference.heldBack`), and the places that must
/// not take the guess unattended: `syncAll` and, for a link, even a single `syncFile`. The CLI's
/// half is pinned in `CommandRunnerTests`. Each engine fixture pairs the held row with a neighbour
/// the rule must not hold: the held row's `action` is still `.copyToRight`, so an assertion on the
/// action alone would pass with or without the hold.
@Suite struct FileDiffEngineHeldRowTests {

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let mac = CloudProvider(id: "L", displayName: "Mac", imageName: "folder", rootPath: "/left", type: .iCloud)
    private let backup = CloudProvider(id: "R", displayName: "Backup", imageName: "folder", rootPath: "/right", type: .iCloud)

    private func info(_ path: String, size: Int?, date: Date?, isDir: Bool = false) -> FileDiffEngine.FileInfo {
        FileDiffEngine.FileInfo(url: URL(fileURLWithPath: path), modificationDate: date, fileSize: size, isDirectory: isDir)
    }

    private func diff(_ leftInfo: [String: FileDiffEngine.FileInfo], _ rightInfo: [String: FileDiffEngine.FileInfo],
                      tolerance: TimeInterval) -> [String: FileDifference] {
        let rows = FileDiffEngine.computeDifferences(
            left: mac, leftURL: URL(fileURLWithPath: "/left"),
            right: backup, rightURL: URL(fileURLWithPath: "/right"),
            leftFilesInfo: leftInfo, rightFilesInfo: rightInfo,
            dateToleranceSeconds: tolerance)
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
    }

    /// The cold scan branch over two real roots: the disk walk.
    private func cold(_ leftRoot: URL, _ rightRoot: URL, tolerance: TimeInterval = 1) throws -> [FileDifference] {
        FileDiffEngine.computeDifferences(
            left: mac, leftURL: leftRoot, right: backup, rightURL: rightRoot,
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(leftRoot),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(rightRoot),
            dateToleranceSeconds: tolerance)
    }

    /// The warm scan branch over two real roots: the pane trees, which carry the link fact.
    private func warm(_ leftRoot: URL, _ rightRoot: URL) async -> [FileDifference] {
        let leftTree = await FileSyncManager.buildTree(url: leftRoot, sortOption: .name)
        let rightTree = await FileSyncManager.buildTree(url: rightRoot, sortOption: .name)
        return FileDiffEngine.computeDifferences(
            left: mac, leftURL: leftRoot, right: backup, rightURL: rightRoot,
            leftFilesInfo: FileDiffEngine.filesInfo(fromTree: leftTree, basePath: leftRoot.path),
            rightFilesInfo: FileDiffEngine.filesInfo(fromTree: rightTree, basePath: rightRoot.path))
    }

    /// A manager listing `rows`, recording to `store`, that answers every collision with Replace.
    @MainActor
    private func makeManager(rows: [FileDifference], store: SyncHistoryStore,
                         fileManager: FileManaging = FileManager.default) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fileManager)
        manager.syncHistoryStore = store
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        manager.rawDifferences = rows
        manager.differences = rows
        return manager
    }

    // MARK: FR39 — different sizes, no newer side

    /// At the 5 s tolerance, a pair edited 3 s apart with different sizes is a question, and is
    /// held whichever side is 3 s later; neither may become a plain `.copyToRight` row a bulk run
    /// takes. A pair 10 s apart is past the tolerance and keeps its direction, unheld.
    @Test func sizesThatDifferInsideTheDateToleranceAreHeldEitherWayRound() throws {
        let rows = diff([
            "a-left-later.txt": info("/left/a-left-later.txt", size: 100, date: d1.addingTimeInterval(3)),
            "b-right-later.txt": info("/left/b-right-later.txt", size: 100, date: d1),
            "c-clearly-newer.txt": info("/left/c-clearly-newer.txt", size: 100, date: d1.addingTimeInterval(10)),
        ], [
            "a-left-later.txt": info("/right/a-left-later.txt", size: 200, date: d1),
            "b-right-later.txt": info("/right/b-right-later.txt", size: 200, date: d1.addingTimeInterval(3)),
            "c-clearly-newer.txt": info("/right/c-clearly-newer.txt", size: 200, date: d1),
        ], tolerance: 5)

        let note = "Sizes differ but the dates match within the 5 s tolerance — choose which to keep"
        for name in ["a-left-later.txt", "b-right-later.txt"] {
            let row = try #require(rows[name])
            #expect(row.heldBack == .sizesDifferWithoutANewerSide, "\(name) rides a bulk run on a guess")
            #expect(row.description == note)
        }
        let decided = try #require(rows["c-clearly-newer.txt"])
        #expect(decided.heldBack == nil, "a pair whose dates clearly differ must not be held")
        #expect(decided.action == .copyToRight)
        #expect(decided.description == "Mac file is newer")
    }

    /// A side with no date says nothing about which is newer either, whichever side lacks it; the
    /// left must not win by default.
    @Test func aPairWhereOneSideHasNoDateIsHeld() throws {
        let rows = diff([
            "left-dateless.txt": info("/left/left-dateless.txt", size: 100, date: nil),
            "right-dateless.txt": info("/left/right-dateless.txt", size: 100, date: d1),
        ], [
            "left-dateless.txt": info("/right/left-dateless.txt", size: 200, date: d1),
            "right-dateless.txt": info("/right/right-dateless.txt", size: 200, date: nil),
        ], tolerance: 1)

        let leftless = try #require(rows["left-dateless.txt"])
        #expect(leftless.heldBack == .sizesDifferWithoutANewerSide)
        #expect(leftless.description == "Sizes differ and the Mac file has no date — choose which to keep")
        let rightless = try #require(rows["right-dateless.txt"])
        #expect(rightless.heldBack == .sizesDifferWithoutANewerSide)
        #expect(rightless.description == "Sizes differ and the Backup file has no date — choose which to keep")
    }

    /// A name-conflict pair is the same question: names differing only invisibly, sizes different,
    /// dates 3 s apart at the 5 s tolerance (or one undated). Defaulting left → right would let
    /// "Sync all" overwrite the right spelling. Its neighbours are not held: a same-size pair has
    /// nothing to lose, and a pair 10 s apart has a newer side.
    @Test func aNameConflictPairWithDifferentSizesAndNoNewerSideIsHeld() throws {
        let rows = diff([
            "Report ": info("/left/Report ", size: 100, date: d1.addingTimeInterval(3)),
            "Undated ": info("/left/Undated ", size: 100, date: nil),
            "Same.": info("/left/Same.", size: 100, date: d1),
            "Clear ": info("/left/Clear ", size: 100, date: d1.addingTimeInterval(10)),
        ], [
            "Report": info("/right/Report", size: 200, date: d1),
            "Undated": info("/right/Undated", size: 200, date: d1),
            "Same": info("/right/Same", size: 100, date: d1.addingTimeInterval(3)),
            "Clear": info("/right/Clear", size: 200, date: d1),
        ], tolerance: 5)

        let tied = try #require(rows["Report "])
        #expect(tied.type == .nameConflict)
        #expect(tied.heldBack == .sizesDifferWithoutANewerSide, "Sync all overwrites the right spelling on a guess")
        #expect(tied.description == "Names differ by a trailing space: “Report ” (Mac) vs “Report” (Backup); sizes differ but the dates match within the 5 s tolerance — choose which to keep")
        let undated = try #require(rows["Undated "])
        #expect(undated.heldBack == .sizesDifferWithoutANewerSide, "a side with no date is no newer side")
        #expect(undated.description.hasSuffix("; sizes differ and the Mac file has no date — choose which to keep"))

        let same = try #require(rows["Same."])
        #expect(same.type == .nameConflict)
        #expect(same.heldBack == nil, "equal sizes inside the tolerance lose nothing either way")
        let clear = try #require(rows["Clear "])
        #expect(clear.type == .nameConflict)
        #expect(clear.heldBack == nil, "a pair whose dates clearly differ must not be held")
        #expect(clear.action == .copyToRight)
        #expect(!clear.description.contains("choose"))
    }

    // MARK: FR40 — a folder against a file

    /// A package edited yesterday inside still carries its 2024 folder date, so against a
    /// single-file `Report.pages` from last month it would read as the older side. The folder date
    /// is not the contents' age: the row is held, and its note claims no newer side.
    @Test func aPackageAgainstAFileIsHeldWhateverTheFolderDateSays() throws {
        let folderDate = Date(timeIntervalSince1970: 1_704_067_200)   // 2024-01-01
        let fileDate = Date(timeIntervalSince1970: 1_758_000_000)     // 2025-09
        let rows = diff([
            "Report.pages": info("/left/Report.pages", size: nil, date: folderDate, isDir: true),
            "Report.pages/Index.zip": info("/left/Report.pages/Index.zip", size: 900, date: Date()),
        ], [
            "Report.pages": info("/right/Report.pages", size: 400, date: fileDate),
        ], tolerance: 1)

        let row = try #require(rows["Report.pages"])
        #expect(row.heldBack == .folderVersusFile)
        #expect(row.description == "Folder in Mac, file in Backup — a folder’s date is not when its contents changed; choose which to keep")
        #expect(!row.description.contains("newer"))
        #expect(row.enclosedItemCount == 1, "the package's insides still fold into its one row")
    }

    // MARK: FR8 — a link as the source

    /// A folder linked in on one side is held, by both scan branches, and never copied as a link.
    /// Real disk: the trap lies between the walk (which follows the link and counts what it holds)
    /// and the copy (`COPYFILE_NOFOLLOW_SRC`, which writes the link). Unheld, Copy writes one link
    /// at `Right/Linked` pointing back at the original.
    @MainActor
    @Test func aLinkedFolderMissingOnOneSideIsHeldAndNeverCopiedAsALink() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldLinkRow")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let original = root.appendingPathComponent("Original")
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        for dir in [original, leftRoot, rightRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("one".utf8).write(to: original.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: original.appendingPathComponent("two.txt"))
        try fm.createSymbolicLink(at: leftRoot.appendingPathComponent("Linked"), withDestinationURL: original)

        let coldRows = try cold(leftRoot, rightRoot)
        let row = try #require(coldRows.first { $0.relativePath == "Linked" })
        #expect(coldRows.count == 1, "the link's contents collapse into its one row: \(coldRows.map(\.relativePath))")
        #expect(row.type == .missingOnRight)
        #expect(row.enclosedItemCount == 2)
        #expect(row.heldBack == .sourceIsSymbolicLink)
        #expect(row.description == "Folder missing on right (Backup) — it is a link, so a copy would be a link too, not what it points to")

        #expect(await warm(leftRoot, rightRoot).first { $0.relativePath == "Linked" }?.heldBack == .sourceIsSymbolicLink,
                "a warm scan must hold the same row a cold one does")

        let store = makeTempHistoryStore(prefix: "HeldLinkRow")
        defer { removeHistoryStoreFiles(store) }
        let manager = makeManager(rows: [row], store: store)
        let destination = rightRoot.appendingPathComponent("Linked")
        func destinationIsAbsent() -> Bool {
            (try? fm.attributesOfItem(atPath: destination.path)) == nil
                && (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil
        }

        // One row at a time: refused, with the reason on the banner.
        let copied = await manager.syncFile(row, confirmed: true)
        #expect(!copied)
        #expect(destinationIsAbsent(), "a single copy wrote something at \(destination.path)")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("is a link") == true, "\(manager.banner?.message ?? "no banner")")

        // In bulk: left out, and said so.
        manager.banner = nil
        await manager.syncAll(direction: .copyToRight, confirmed: true)
        #expect(destinationIsAbsent(), "a bulk run wrote something at \(destination.path)")
        // No path is named: nothing in the app copies a row FROM a link right, the row's menu included.
        #expect(manager.banner?.message == "Nothing was copied; 1 item is a link and was left out — a copy would be a link too")
        #expect(manager.differences.map(\.relativePath) == ["Linked"], "the held row must stay on the list")
        #expect(try fm.contentsOfDirectory(atPath: original.path).sorted() == ["one.txt", "two.txt"])
    }

    /// A link inside a folder missing on one side holds the folder's row, by both scan branches:
    /// the recursive copy would write `Project/lib -> Elsewhere` as a link, and the next scan would
    /// read the pair as in sync. `held(_:source:)` alone can't see it. The link sorts after a real
    /// file (`Project/a.txt`), so a hold keyed on the first collapsed entry would miss it.
    @MainActor
    @Test func aFolderMissingOnOneSideThatHoldsALinkIsHeldAndNamesIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldNestedLink")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let elsewhere = root.appendingPathComponent("Elsewhere")
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        let project = leftRoot.appendingPathComponent("Project")
        for dir in [elsewhere, project, rightRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("lib".utf8).write(to: elsewhere.appendingPathComponent("lib.c"))
        try Data("a".utf8).write(to: project.appendingPathComponent("a.txt"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("lib"), withDestinationURL: elsewhere)

        let coldRows = try cold(leftRoot, rightRoot)
        let row = try #require(coldRows.first { $0.relativePath == "Project" })
        #expect(coldRows.count == 1, "the folder's contents collapse into its one row: \(coldRows.map(\.relativePath))")
        #expect(row.type == .missingOnRight)
        #expect(row.enclosedItemCount == 3, "a.txt, lib and lib/lib.c")
        #expect(row.heldBack == .enclosesSymbolicLink(path: "Project/lib"))
        #expect(row.description == "Folder missing on right (Backup) — “Project/lib” inside it is a link, "
                + "so a copy would carry the link, not what it points to")
        #expect(row.mirrored().heldBack == row.heldBack, "a pane swap keeps the hold")

        #expect(await warm(leftRoot, rightRoot).first { $0.relativePath == "Project" }?.heldBack == .enclosesSymbolicLink(path: "Project/lib"),
                "a warm scan must hold the same row a cold one does")

        // The control: the same folder with no link in it is an ordinary, unheld row.
        try fm.removeItem(at: project.appendingPathComponent("lib"))
        let plainRow = try #require(try cold(leftRoot, rightRoot).first { $0.relativePath == "Project" })
        #expect(plainRow.heldBack == nil)
        #expect(plainRow.description == "Folder missing on right (Backup)")
    }

    /// A missing folder holding a link is not told to "choose which to keep": its menu offers the
    /// one copy, which goes ahead when asked for alone. Both kinds in one run, so a phrase that
    /// miscounts one kind into another can't pass.
    @MainActor
    @Test func aMissingFolderHoldingALinkHasItsOwnLeftOutPhrase() {
        func row(_ reason: FileDifference.HeldBack?) -> FileDifference {
            FileDifference(relativePath: "x", leftItemPath: "/l/x", rightItemPath: "/r/x", type: .missingOnRight,
                           action: .copyToRight, description: "d", heldBack: reason)
        }
        let folder = row(.enclosesSymbolicLink(path: "x/lib"))
        #expect(FileSyncManager.leftOutPhrases([folder, row(.sizesDifferWithoutANewerSide)]) == [
            "1 item needs your decision and was left out — right-click its row to choose which to keep",
            "1 folder holds a link to somewhere outside it and was left out — right-click its row to copy it on its own",
        ])
        #expect(FileSyncManager.leftOutPhrases([folder, folder]) == [
            "2 folders hold links to somewhere outside them and were left out — right-click each row to copy it on its own",
        ])
    }

    /// A link that stays inside the folder holds nothing; one that leads out holds the row. Copied
    /// as links, `Versions/Current -> A` and `docs/readme -> ../README.md` point inside the copy,
    /// which is right; holding them would leave app bundles, venvs and git checkouts with no bulk
    /// or CLI run that takes them. A relative target is followed from the link's own directory
    /// (from the root, `../README.md` is outside). Held: a relative link climbing out
    /// (`docs/zout`), and an absolute one even naming a file inside (`Versions/Zabs`), since the
    /// copy keeps the path back to the original. Each sorts after an inside link, so a hold naming
    /// the first link of all would name the wrong one.
    @MainActor
    @Test func aLinkThatStaysInsideAMissingFolderHoldsNothingAndOneLeadingOutHoldsIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldInsideLink")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        let elsewhere = root.appendingPathComponent("Elsewhere")
        let versions = leftRoot.appendingPathComponent("Foo.app/Contents/Frameworks/X.framework/Versions")
        let checkout = leftRoot.appendingPathComponent("Checkout")
        for dir in [versions.appendingPathComponent("A"), checkout.appendingPathComponent("docs"), rightRoot, elsewhere] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("bin".utf8).write(to: versions.appendingPathComponent("A/X"))
        try fm.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: versions.deletingLastPathComponent().appendingPathComponent("X").path,
                                  withDestinationPath: "Versions/Current/X")
        try Data("read me".utf8).write(to: checkout.appendingPathComponent("README.md"))
        try fm.createSymbolicLink(atPath: checkout.appendingPathComponent("docs/readme").path,
                                  withDestinationPath: "../README.md")
        try Data("e".utf8).write(to: elsewhere.appendingPathComponent("e.txt"))

        func rows() async throws -> (cold: [String: FileDifference], warm: [String: FileDifference]) {
            func byPath(_ rows: [FileDifference]) -> [String: FileDifference] {
                Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
            }
            return (byPath(try cold(leftRoot, rightRoot)), byPath(await warm(leftRoot, rightRoot)))
        }

        let inside = try await rows()
        for scan in [inside.cold, inside.warm] {
            #expect(scan.keys.sorted() == ["Checkout", "Foo.app"])
            let app = try #require(scan["Foo.app"])
            let repo = try #require(scan["Checkout"])
            #expect(app.heldBack == nil, "\(String(describing: app.heldBack))")
            #expect(app.description == "Folder missing on right (Backup)")
            #expect(repo.heldBack == nil, "\(String(describing: repo.heldBack))")
            #expect(repo.description == "Folder missing on right (Backup)")
            #expect((repo.enclosedItemCount ?? 0) == 3, "docs, docs/readme, README.md")
        }

        // Out: a relative link climbing out of the folder, and an absolute one naming a file in it.
        try fm.createSymbolicLink(atPath: checkout.appendingPathComponent("docs/zout").path,
                                  withDestinationPath: "../../../Elsewhere")
        try fm.createSymbolicLink(atPath: versions.appendingPathComponent("Zabs").path,
                                  withDestinationPath: versions.appendingPathComponent("A/X").path)
        let outside = try await rows()
        for scan in [outside.cold, outside.warm] {
            #expect(scan["Checkout"]?.heldBack == .enclosesSymbolicLink(path: "Checkout/docs/zout"))
            #expect(scan["Checkout"]?.description == "Folder missing on right (Backup) — “Checkout/docs/zout” "
                    + "inside it is a link, so a copy would carry the link, not what it points to",
                    "only the link leading out is counted, not docs/readme beside it")
            #expect(scan["Foo.app"]?.heldBack
                    == .enclosesSymbolicLink(path: "Foo.app/Contents/Frameworks/X.framework/Versions/Zabs"))
        }
    }

    // MARK: bulk runs leave held rows out

    /// A bulk run copies the decided rows and leaves the held one, on a real disk. The held row
    /// sorts first, so a run that stopped at it instead of stepping past it would also leave
    /// `b-missing.txt` uncopied and fail here.
    @MainActor
    @Test func syncAllCopiesTheDecidedRowsAndLeavesTheHeldOneUntouched() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldBulkRow")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        for dir in [leftRoot, rightRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let sameTime = d1
        try Data("left, longer".utf8).write(to: leftRoot.appendingPathComponent("a-held.txt"))
        try Data("right".utf8).write(to: rightRoot.appendingPathComponent("a-held.txt"))
        try Data("only on the left".utf8).write(to: leftRoot.appendingPathComponent("b-missing.txt"))
        for url in [leftRoot.appendingPathComponent("a-held.txt"), rightRoot.appendingPathComponent("a-held.txt")] {
            try fm.setAttributes([.modificationDate: sameTime], ofItemAtPath: url.path)
        }

        let rows = try cold(leftRoot, rightRoot, tolerance: 5)
        #expect(rows.map(\.relativePath) == ["a-held.txt", "b-missing.txt"])
        #expect(rows.first?.heldBack == .sizesDifferWithoutANewerSide)
        #expect(rows.allSatisfy { $0.action == .copyToRight }, "both rows point the same way, so only the hold tells them apart")

        let store = makeTempHistoryStore(prefix: "HeldBulkRow")
        defer { removeHistoryStoreFiles(store) }
        let manager = makeManager(rows: rows, store: store)

        await manager.syncAll(direction: .copyToRight, confirmed: true)

        #expect(try String(contentsOf: rightRoot.appendingPathComponent("b-missing.txt"), encoding: .utf8) == "only on the left")
        #expect(try String(contentsOf: rightRoot.appendingPathComponent("a-held.txt"), encoding: .utf8) == "right",
                "the held row's right file was overwritten by a bulk run")
        #expect(manager.banner?.message
                == "Copied 1 item; 1 item needs your decision and was left out — right-click its row to choose which to keep")
        #expect(manager.differences.map(\.relativePath) == ["a-held.txt"])
    }

    /// Review's Copy Remaining copies both ways and names the held rows it left. Both ways means
    /// two `syncAll`s with their banners off, so Copy Remaining reports the held rows itself. Two
    /// runs are two undo steps, so no Undo is offered.
    @MainActor
    @Test func copyRemainingCopiesBothWaysAndNamesTheHeldRowsItLeft() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldCopyRemaining")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        for dir in [leftRoot, rightRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for name in ["a-held.txt", "b-held.txt"] {
            try Data("left, longer".utf8).write(to: leftRoot.appendingPathComponent(name))
            try Data("right".utf8).write(to: rightRoot.appendingPathComponent(name))
            for url in [leftRoot.appendingPathComponent(name), rightRoot.appendingPathComponent(name)] {
                try fm.setAttributes([.modificationDate: d1], ofItemAtPath: url.path)
            }
        }
        try Data("only on the left".utf8).write(to: leftRoot.appendingPathComponent("c-to-right.txt"))
        try Data("only on the right".utf8).write(to: rightRoot.appendingPathComponent("d-to-left.txt"))

        let rows = try cold(leftRoot, rightRoot, tolerance: 5).sorted { $0.relativePath < $1.relativePath }
        try #require(rows.map(\.relativePath) == ["a-held.txt", "b-held.txt", "c-to-right.txt", "d-to-left.txt"])
        try #require(rows.map { $0.heldBack != nil } == [true, true, false, false])
        try #require(rows.map(\.action) == [.copyToRight, .copyToRight, .copyToRight, .copyToLeft])

        let store = makeTempHistoryStore(prefix: "HeldCopyRemaining")
        defer { removeHistoryStoreFiles(store) }
        let manager = makeManager(rows: rows, store: store)

        let resolved = await manager.copyRemaining(rows, isMove: false)

        #expect(resolved == Set(rows.suffix(2).map(\.id)))
        #expect(try String(contentsOf: rightRoot.appendingPathComponent("c-to-right.txt"), encoding: .utf8) == "only on the left")
        #expect(try String(contentsOf: leftRoot.appendingPathComponent("d-to-left.txt"), encoding: .utf8) == "only on the right")
        for name in ["a-held.txt", "b-held.txt"] {
            #expect(try String(contentsOf: rightRoot.appendingPathComponent(name), encoding: .utf8) == "right",
                    "\(name)'s right file was overwritten by Copy Remaining")
        }
        let banner = try #require(manager.banner, "Copy Remaining said nothing")
        #expect(banner.message
                == "Copied 2 items; 2 items need your decision and were left out — right-click each row to choose which to keep")
        #expect(banner.severity == .success)
        #expect(!banner.isUndoable, "one Undo would reverse only one of the two runs")
        #expect(manager.differences.map(\.relativePath) == ["a-held.txt", "b-held.txt"])
    }

    /// The row's menu decides a held row either way, even against the guess: ⌘←, the Review card
    /// and bulk runs can't keep the right file. `redirected(to:)` is what its Copy to … hands
    /// `syncFile`.
    @MainActor
    @Test func aHeldRowRedirectedAgainstItsGuessCopiesTheOtherWay() async throws {
        let root = try makeCanonicalTempRoot(prefix: "HeldRedirected")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let leftRoot = root.appendingPathComponent("Left")
        let rightRoot = root.appendingPathComponent("Right")
        for dir in [leftRoot, rightRoot] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("left, longer".utf8).write(to: leftRoot.appendingPathComponent("held.txt"))
        try Data("right".utf8).write(to: rightRoot.appendingPathComponent("held.txt"))
        for url in [leftRoot.appendingPathComponent("held.txt"), rightRoot.appendingPathComponent("held.txt")] {
            try fm.setAttributes([.modificationDate: d1], ofItemAtPath: url.path)
        }
        let row = try #require(try cold(leftRoot, rightRoot, tolerance: 5).first)
        try #require(row.heldBack == .sizesDifferWithoutANewerSide && row.action == .copyToRight,
                     "the premise: a held row whose guess is left → right")

        let store = makeTempHistoryStore(prefix: "HeldRedirected")
        defer { removeHistoryStoreFiles(store) }
        let manager = makeManager(rows: [row], store: store, fileManager: ScratchTrash(in: root))

        let redirected = row.redirected(to: .copyToLeft)
        #expect(redirected.id == row.id && redirected.leftItemPath == row.leftItemPath
                && redirected.heldBack == row.heldBack, "redirected traded more than the direction")
        let copied = await manager.syncFile(redirected, confirmed: true)

        #expect(copied)
        #expect(try String(contentsOf: leftRoot.appendingPathComponent("held.txt"), encoding: .utf8) == "right",
                "the right file was not copied over the left")
        #expect(try String(contentsOf: rightRoot.appendingPathComponent("held.txt"), encoding: .utf8) == "right")
        #expect(manager.differences.isEmpty, "the decided row is still on the list")
    }
}
