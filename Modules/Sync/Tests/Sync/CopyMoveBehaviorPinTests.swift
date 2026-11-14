import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins how the four copy/move entry points (`copyItems(fromLeft:)`, `moveItems(fromLeft:)`,
/// `copyItems(toPath:)`, `moveItems(toPath:)`) differ, over their shared implementation:
/// - same-URL handling: copies keep both via `generateUniqueURL`, moves skip,
/// - which undo registrar runs (Copy vs Move action names),
/// - the final debug log per variant, including the "N of M" partial-count form,
/// - the error title per family ("Copy Failed" vs "Move Failed"),
/// - the order and content of the returned nodes.
/// Each test mocks the collision seams to the resolution it exercises; the unwired defaults fail
/// safe (skip, don't delete), which `UnwiredManagerSafeDefaultsTests` pins.
@Suite struct CopyMoveBehaviorPinTests {

    /// True when `log` captured an entry that is exactly `message`, or exactly `message` followed
    /// by an operation's elapsed time (" (12.3 ms)", " (1.23 s)"), which the finish lines carry.
    /// Anchored at both ends, so a reworded or lengthened line still fails. A capture, not the
    /// shared buffer, which other suites can evict.
    @MainActor
    private func loggerContains(_ log: LogCapture, _ message: String) async -> Bool {
        await log.entries.contains { Self.isLine($0.message, message) }
    }

    nonisolated static func isLine(_ line: String, _ message: String) -> Bool {
        if line == message { return true }
        guard line.hasPrefix(message + " (") else { return false }
        let tail = line.dropFirst(message.count)
        return tail.range(of: #"^ \([0-9]+(\.[0-9]+)? (ms|s)( \+ [0-9]+(\.[0-9]+)? (ms|s) asleep)?\)$"#,
                          options: .regularExpression) != nil
    }

    /// The helper itself: the line, bare or timed, matches; a longer one doesn't.
    @Test func theLineMatcherAcceptsOnlyTheMessageAndItsTime() {
        #expect(Self.isLine("Copied 1 item(s) to /src (12.3 ms)", "Copied 1 item(s) to /src"))
        #expect(Self.isLine("Copied 1 item(s) to /src (1.23 s)", "Copied 1 item(s) to /src"))
        #expect(Self.isLine("Copied 1 item(s) to /src", "Copied 1 item(s) to /src"))
        #expect(!Self.isLine("Copied 1 item(s) to /src/x (12.3 ms)", "Copied 1 item(s) to /src"))
        #expect(!Self.isLine("Copied 1 item(s) to /src (12.3 ms) extra", "Copied 1 item(s) to /src"))
    }

    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, true))
    }

    // MARK: - Where a pane transfer lands (FR37, FR38)

    /// Dropbox opens at `Documents`, Google Drive at `My Drive/Documents`. Dropbox
    /// `Documents/Tax.pdf` lands in the folder the other pane shows, not at the Drive account root
    /// outside My Drive, and the same both ways.
    @Test func aPaneTransferLandsUnderTheOtherPanesLandingFolder() throws {
        let target = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/GoogleDrive-x",
                                                   leftOpenAt: "Documents", rightOpenAt: "My Drive/Documents", links: [:])
        let tax = FileNode(id: "/r/Dropbox/Documents/Taxes/Tax.pdf", name: "Tax.pdf", isDirectory: false)
        #expect(try target(tax).path == "/r/GoogleDrive-x/My Drive/Documents/Taxes/Tax.pdf")

        let back = FileSyncManager.paneTargetURL(fromLeft: false, leftRoot: "/r/Dropbox", rightRoot: "/r/GoogleDrive-x",
                                                 leftOpenAt: "Documents", rightOpenAt: "My Drive/Documents", links: [:])
        let deck = FileNode(id: "/r/GoogleDrive-x/My Drive/Documents/Deck.key", name: "Deck.key", isDirectory: true)
        #expect(try back(deck).path == "/r/Dropbox/Documents/Deck.key")
        // Two panes rooted alike are unaffected.
        let same = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/src", rightRoot: "/dst", links: [:])
        #expect(try same(FileNode(id: "/src/a/b.txt", name: "b.txt", isDirectory: false)).path == "/dst/a/b.txt")
    }

    /// The landing folder itself goes where its contents go. Dropbox opens at `Documents`, iCloud
    /// at its root; picking Dropbox's `Documents` maps it onto iCloud's root, as
    /// `Documents/Tax.pdf` maps to `Tax.pdf`, not to an iCloud `Documents` beside its contents. A
    /// deeper landing folder maps onto the other's too. It is offered as Merge only (below), so the
    /// root is never replaced.
    @Test func theLandingFolderItselfMapsOntoTheOtherLandingFolder() throws {
        let toICloud = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/iCloud",
                                                     leftOpenAt: "Documents", rightOpenAt: "", links: [:])
        let documents = FileNode(id: "/r/Dropbox/Documents", name: "Documents", isDirectory: true)
        #expect(try toICloud(documents).path == "/r/iCloud")
        #expect(try toICloud(FileNode(id: "/r/Dropbox/Documents/Tax.pdf", name: "Tax.pdf", isDirectory: false)).path
                == "/r/iCloud/Tax.pdf", "premise: its contents go to the root")

        let toDropbox = FileSyncManager.paneTargetURL(fromLeft: false, leftRoot: "/r/Dropbox", rightRoot: "/r/GD",
                                                      leftOpenAt: "Documents", rightOpenAt: "My Drive/Work", links: [:])
        let work = FileNode(id: "/r/GD/My Drive/Work", name: "Work", isDirectory: true)
        #expect(try toDropbox(work).path == "/r/Dropbox/Documents")

        let isLanding = FileSyncManager.paneLandingFolderRow(fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/iCloud",
                                                             leftOpenAt: "Documents", rightOpenAt: "", links: [:])
        #expect(isLanding(documents))
        #expect(!isLanding(FileNode(id: "/r/Dropbox/Documents/Tax.pdf", name: "Tax.pdf", isDirectory: false)))
        #expect(!isLanding(FileNode(id: "/r/Dropbox/Photos", name: "Photos", isDirectory: true)))
    }

    /// A row above the landing folder lands at the other source's matching level: Dropbox
    /// `Photos/a.jpg` (beside `Documents`) lands beside Drive's `Documents`, not at the account
    /// root, and back again. A row branching higher than the other source has levels for is
    /// refused, not grafted at its root.
    @Test func aRowAboveTheLandingFolderLandsAtTheMatchingLevel() throws {
        let toDrive = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/GD",
                                                    leftOpenAt: "Documents", rightOpenAt: "My Drive/Documents", links: [:])
        let photo = FileNode(id: "/r/Dropbox/Photos/a.jpg", name: "a.jpg", isDirectory: false)
        #expect(try toDrive(photo).path == "/r/GD/My Drive/Photos/a.jpg")

        let toDropbox = FileSyncManager.paneTargetURL(fromLeft: false, leftRoot: "/r/Dropbox", rightRoot: "/r/GD",
                                                      leftOpenAt: "Documents", rightOpenAt: "My Drive/Documents", links: [:])
        let drivePhoto = FileNode(id: "/r/GD/My Drive/Photos/a.jpg", name: "a.jpg", isDirectory: false)
        #expect(try toDropbox(drivePhoto).path == "/r/Dropbox/Photos/a.jpg")
        #expect(throws: FileSyncManager.FileOperationError.itemAboveOpeningFolder(itemName: "s.pdf")) {
            try toDropbox(FileNode(id: "/r/GD/Shared drives/Team/s.pdf", name: "s.pdf", isDirectory: false))
        }
        // A destination that opens at its root takes every level there.
        let toICloud = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/iCloud",
                                                     leftOpenAt: "Documents", rightOpenAt: "", links: [:])
        #expect(try toICloud(photo).path == "/r/iCloud/Photos/a.jpg")
    }

    /// The call site: the landing folder copied to a pane that opens at its root is offered as
    /// Merge only. Replace or Keep Both is refused with a sentence and the root keeps what it
    /// holds; Merge puts the contents where they go.
    @MainActor
    @Test(arguments: [CollisionResolution.replace, .keepBoth, .merge])
    func copyingTheLandingFolderOnlyMergesIntoTheOtherPanesRoot(answer: CollisionResolution) async throws {
        let manager = makeManager()
        manager.paneOpenAt = { $0 ? "Documents" : "" }
        var asked: [FileCollision] = []
        manager.collisionResolver = { asked.append($0); return answer }
        let mockFM = MockFileManager()
        for dir in ["/r", "/r/Dropbox", "/r/Dropbox/Documents", "/r/iC"] {
            try mockFM.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        mockFM.virtualDisk["/r/Dropbox/Documents/Tax.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/r/iC/keep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/r/Dropbox/Documents", name: "Documents", isDirectory: true)

        _ = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/iC", fileManager: mockFM)

        #expect(asked.map(\.destinationPath) == ["/r/iC"])
        #expect(asked.first?.mergeOnly == true)
        #expect(mockFM.virtualDisk["/r/iC/keep.txt"] != nil, "the copy replaced the other pane's root")
        #expect(mockFM.virtualDisk["/r/iC/Documents"] == nil, "it landed beside the contents it holds")
        if answer == .merge {
            #expect(mockFM.virtualDisk["/r/iC/Tax.pdf"] != nil, "error: \(String(describing: manager.currentError))")
        } else {
            #expect(mockFM.virtualDisk.keys.filter { $0.hasPrefix("/r/iC/") }.sorted() == ["/r/iC/keep.txt"])
            #expect(manager.currentError?.reason?.contains("can only be merged") == true,
                    "\(String(describing: manager.currentError))")
        }
    }

    /// Rows under iCloud's `Documents` link carry the folder's real path, which a bare prefix test
    /// puts outside the pane; the link table maps it back through the link's name.
    @Test func aRowUnderICloudsDocumentsLinkTransfers() throws {
        let links: PathBoundary.LinkedFolders = ["/r/CloudDocs": ["Documents": "/r/home/Documents"]]
        let target = FileSyncManager.paneTargetURL(fromLeft: true, leftRoot: "/r/CloudDocs", rightRoot: "/r/OneDrive",
                                                   leftOpenAt: "Documents", rightOpenAt: "Documents", links: links)
        let row = FileNode(id: "/r/home/Documents/Family/x.pdf", name: "x.pdf", isDirectory: false)
        #expect(try target(row).path == "/r/OneDrive/Documents/Family/x.pdf")
        // Something genuinely elsewhere is still refused.
        #expect(throws: FileSyncManager.FileOperationError.itemOutsideSourceRoot(itemName: "y.pdf")) {
            try target(FileNode(id: "/r/elsewhere/y.pdf", name: "y.pdf", isDirectory: false))
        }
    }

    /// The call site: `copyItems(fromLeft:)` asks the panes where they land.
    @MainActor
    @Test func copyBetweenPanesUsesThePanesLandingFolders() async throws {
        let manager = makeManager()
        manager.paneOpenAt = { $0 ? "Documents" : "My Drive/Documents" }
        let mockFM = MockFileManager()
        for dir in ["/r", "/r/Dropbox", "/r/Dropbox/Documents", "/r/GD", "/r/GD/My Drive", "/r/GD/My Drive/Documents"] {
            try mockFM.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        mockFM.virtualDisk["/r/Dropbox/Documents/Tax.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/r/Dropbox/Documents/Tax.pdf", name: "Tax.pdf", isDirectory: false)

        _ = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/r/Dropbox", rightRoot: "/r/GD", fileManager: mockFM)

        #expect(mockFM.virtualDisk["/r/GD/My Drive/Documents/Tax.pdf"] != nil)
        #expect(mockFM.virtualDisk["/r/GD/Documents/Tax.pdf"] == nil, "landed at the account root, outside My Drive")
    }

    // MARK: - Same-URL handling (source == derived target)

    /// Which entry point a same-URL transfer goes through.
    enum Route: Sendable { case pane, path }

    /// Copying onto itself (both panes rooted at the same directory, or copy-to-path onto the
    /// source directory) keeps both: the copy lands under a uniquified name, is undoable as a
    /// Copy, and counts as fully copied.
    @MainActor
    @Test(arguments: [Route.pane, .path])
    func testCopyItemsOntoItselfKeepsBoth(route: Route) async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let name = route == .pane ? "pinSameCopyPane" : "pinSameCopyPath"
        mockFM.virtualDisk["/src/\(name).txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/\(name).txt", name: "\(name).txt", isDirectory: false)

        let copied = route == .pane
            ? await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/src", fileManager: mockFM)
            : await manager.copyItems(nodes: [node], toPath: "/src", fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/\(name).txt"] != nil)
        #expect(mockFM.virtualDisk["/src/\(name) 2.txt"] != nil)
        #expect(copied.map(\.id) == ["/src/\(name).txt"])
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == true)
        #expect(manager.undoManager?.undoActionName == "Copy 1 Item")
        #expect(await loggerContains(log, route == .pane ? "Copied 1 item(s) between panes" : "Copied 1 item(s) to /src"))
    }

    /// Moving onto itself is skipped: nothing moves, it returns no moved nodes, and registers no
    /// undo. The pane variant leaves a debug trace, and its final log reports the partial count
    /// 0 of 1.
    @MainActor
    @Test(arguments: [Route.pane, .path])
    func testMoveItemsOntoItselfSkips(route: Route) async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let name = route == .pane ? "pinSameMovePane" : "pinSameMovePath"
        mockFM.virtualDisk["/src/\(name).txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/\(name).txt", name: "\(name).txt", isDirectory: false)

        let moved = route == .pane
            ? await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/src", fileManager: mockFM)
            : await manager.moveItems(nodes: [node], toPath: "/src", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(mockFM.virtualDisk["/src/\(name).txt"] != nil)
        #expect(mockFM.virtualDisk["/src/\(name) 2.txt"] == nil)
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == false)
        if route == .pane {
            #expect(await loggerContains(log, "Skipping move of \"\(name).txt\": source and destination are the same location."))
            #expect(await loggerContains(log, "Moved 0 of 1 item(s) between panes"))
        }
    }

    // MARK: - Partial counts, returned order, and undo registrars

    /// One of three copies is skipped via the collision dialog: the returned nodes keep source
    /// order, the log uses the "N of M" form, and the undo action counts only real copies.
    @MainActor
    @Test func testCopyItemsFromLeftPartialSkipReportsPartialCount() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Strictly increasing id lengths so the length-sorted prune order equals input order.
        for name in ["pcA.txt", "pcBB.txt", "pcCCC.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/pcBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["pcA.txt", "pcBB.txt", "pcCCC.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _ in .skip }

        let copied = await manager.copyItems(nodes: nodes, fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["pcA.txt", "pcCCC.txt"])
        #expect(mockFM.virtualDisk["/dst/pcA.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/pcCCC.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/pcBB 2.txt"] == nil)
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.undoActionName == "Copy 2 Items")
        #expect(await loggerContains(log, "Copied 2 of 3 item(s) between panes"))
    }

    /// Same shape for the pane move: partial log, Move undo registrar, and undo restores the
    /// moved file to its source.
    @MainActor
    @Test func testMoveItemsFromLeftPartialSkipReportsPartialCountAndUndoes() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in ["pmA.txt", "pmBB.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/pmBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["pmA.txt", "pmBB.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _ in .skip }

        let moved = await manager.moveItems(nodes: nodes, fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(moved.map(\.name) == ["pmA.txt"])
        #expect(mockFM.virtualDisk["/dst/pmA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pmA.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/pmBB.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Move 1 Item")
        #expect(await loggerContains(log, "Moved 1 of 2 item(s) between panes"))

        // The Move registrar really is wired: undo brings the file back to its source.
        manager.undoManager?.undo()
        await waitUntil("the undo brought the file back") { mockFM.virtualDisk["/src/pmA.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/pmA.txt"] == nil)
    }

    /// The to-path siblings of the partial-count pin: `copyItems(toPath:)` and `moveItems(toPath:)`
    /// log the transferred count, not the selection count, in the "N of M" form: a partial
    /// transfer logs "1 of 2".
    @MainActor
    @Test(arguments: [false, true])
    func testTransferItemsToPathPartialSkipReportsPartialCount(isMove: Bool) async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        let names = isMove ? ["pdA.txt", "pdBB.txt"] : ["ptA.txt", "ptBB.txt"]
        for name in names {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/\(names[1])"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = names.map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _ in .skip }

        let landed = isMove
            ? await manager.moveItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)
            : await manager.copyItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(landed.map(\.name) == [names[0]])
        #expect(mockFM.virtualDisk["/dst/\(names[0])"] != nil)
        if isMove { #expect(mockFM.virtualDisk["/src/\(names[1])"] != nil) }
        #expect(manager.undoManager?.undoActionName == (isMove ? "Move 1 Item" : "Copy 1 Item"))
        #expect(await loggerContains(log, isMove ? "Moved 1 of 2 item(s) to /dst" : "Copied 1 of 2 item(s) to /dst"))
    }

    /// Full-count happy-path logs for the two move variants (the copy ones are pinned above).
    @MainActor
    @Test func testMoveItemsFullCountLogsPerVariant() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dstPane"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dstPath"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/fullPane.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/fullPath.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let paneNode = FileNode(id: "/src/fullPane.txt", name: "fullPane.txt", isDirectory: false)
        let pathNode = FileNode(id: "/src/fullPath.txt", name: "fullPath.txt", isDirectory: false)

        await manager.moveItems(nodes: [paneNode], fromLeft: true, leftRoot: "/src", rightRoot: "/dstPane", fileManager: mockFM)
        await manager.moveItems(nodes: [pathNode], toPath: "/dstPath", fileManager: mockFM)

        #expect(await loggerContains(log, "Moved 1 item(s) between panes"))
        #expect(await loggerContains(log, "Moved 1 item(s) to /dstPath"))
    }

    // MARK: - Error messages per family

    /// A nesting violation surfaces as "Copy Failed" for the copy family and as "Move Failed" for
    /// the move family.
    @MainActor
    @Test(arguments: [false, true])
    func testTransferItemsErrorMessageUsesItsFamilysWording(isMove: Bool) async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        let dir = isMove ? "/src/errMoveDir" : "/src/errCopyDir"
        mockFM.virtualDisk[dir] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        let node = FileNode(id: dir, name: (dir as NSString).lastPathComponent, isDirectory: true)

        let landed = isMove
            ? await manager.moveItems(nodes: [node], toPath: dir, fileManager: mockFM)
            : await manager.copyItems(nodes: [node], toPath: dir, fileManager: mockFM)

        #expect(landed.isEmpty)
        #expect(manager.currentError?.title == (isMove ? "Move Failed" : "Copy Failed"))
        #expect(manager.currentError?.reason == "Cannot move or copy a directory into itself or its subdirectories.")
    }

    // MARK: - Pane-root hardening (empty roots, prefix aliasing, vanished destination)

    /// An empty destination root (the pane's provider vanished from settings) aborts the operation
    /// before any I/O. "" would give a relative target that `URL(fileURLWithPath:)` resolves
    /// against the process's working directory, and a move would relocate files there.
    @MainActor
    @Test func testMoveItemsEmptyDestinationRootAbortsWithoutWrites() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardEmptyDst.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardEmptyDst.txt", name: "hardEmptyDst.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/src/hardEmptyDst.txt"] != nil)
        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
        #expect(manager.undoManager?.canUndo == false)
    }

    /// An empty source root fails too: "" prefix-matches every node, which would graft the node's
    /// near-absolute path under the destination as its "relative" part.
    @MainActor
    @Test func testCopyItemsEmptySourceRootFailsInsteadOfGrafting() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardEmptySrc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardEmptySrc.txt", name: "hardEmptySrc.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "The source pane’s folder is no longer available. Rescan before copying or moving items.")
        #expect(mockFM.calledCopyItem == false)
        #expect(!mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/") })
    }

    /// A node outside the source root fails per item rather than grafting its absolute path under
    /// the destination (a misdirected `<newRoot>/Users/…/<oldRoot>/…` copy, as during a pane
    /// swap). A sibling under the root still transfers in the same call.
    @MainActor
    @Test func testCopyItemsNodeOutsideSourceRootFailsPerItem() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/outside"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardIn.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/outside/hardOutBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // Strictly increasing id lengths so the length-sorted prune order equals input order.
        let inNode = FileNode(id: "/src/hardIn.txt", name: "hardIn.txt", isDirectory: false)
        let outNode = FileNode(id: "/outside/hardOutBB.txt", name: "hardOutBB.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [inNode, outNode], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["hardIn.txt"])
        #expect(mockFM.virtualDisk["/dst/hardIn.txt"] != nil)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "“hardOutBB.txt” is not inside the source pane’s folder. Rescan and try again.")
        // No grafted path: the outside node landed nowhere under /dst, and its original is intact.
        #expect(!mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/outside") })
        #expect(mockFM.virtualDisk["/outside/hardOutBB.txt"] != nil)
    }

    /// Root "/data/foo" must not claim "/data/foobar/…" by a bare prefix match, or the remainder
    /// ("bar/…") becomes the relative path and the file silently goes to "<toRoot>/bar/…".
    @MainActor
    @Test func testMoveItemsPrefixAliasedRootFailsInsteadOfMisdirecting() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/data/foo"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/data/foobar"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/data/foobar/hardAlias.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/data/foobar/hardAlias.txt", name: "hardAlias.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/data/foo", rightRoot: "/dst", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/dst/bar/hardAlias.txt"] == nil)
        #expect(mockFM.virtualDisk["/data/foobar/hardAlias.txt"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
    }

    /// A destination pane root gone from disk (provider unmounted, say the Google Drive app quit)
    /// fails the operation rather than being recreated as a local folder the FileProvider never
    /// syncs.
    @MainActor
    @Test func testCopyItemsMissingDestinationRootIsNotRecreated() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardGone.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardGone.txt", name: "hardGone.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "The destination folder is no longer available. Rescan before copying or moving items.")
        #expect(mockFM.virtualDisk["/dst"] == nil)
        #expect(mockFM.calledCopyItem == false)
    }

    /// Same guard on the toPath route (drag and drop, paste): a vanished drop target is an error,
    /// not a directory to recreate, and a move leaves the originals in place.
    @MainActor
    @Test func testMoveItemsToPathMissingDestinationFailsWithoutWrites() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardDrop.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardDrop.txt", name: "hardDrop.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], toPath: "/gone", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/gone"] == nil)
        #expect(mockFM.virtualDisk["/src/hardDrop.txt"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
    }

    /// Missing intermediate folders under an existing destination root are still created (bulk
    /// sync of nested files relies on it); only the root itself is never auto-created.
    @MainActor
    @Test func testCopyItemsCreatesMissingIntermediatesUnderExistingRoot() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/sub/hardDeep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/sub/hardDeep.txt", name: "hardDeep.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["hardDeep.txt"])
        #expect(mockFM.virtualDisk["/dst/sub"]?.isDirectory == true)
        #expect(mockFM.virtualDisk["/dst/sub/hardDeep.txt"] != nil)
        #expect(manager.currentError == nil)
    }
}
