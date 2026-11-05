import Testing
import Foundation
import AppKit
import Sync
import Settings
@testable import Dashboard

/// Which clipboard a ⌘V means. There are two clipboards and the user believes in one. Each test is
/// a real sequence somebody performs, named as that sequence.
@Suite struct ClipboardSourceTests {

    /// ⌘C here, ⌘V here. The app still owns the pasteboard, so its own list answers; only that list
    /// carries `isCut`, so this is the only branch that can move rather than copy.
    @Test func copyHereThenPasteHereUsesTheAppsOwnList() {
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: true) == .inApp)
    }

    /// ⌘C here, then ⌘C in Finder, then ⌘V here. The count moved, so Finder's files win, as a
    /// single-clipboard platform promises.
    @Test func aCopyMadeElsewhereAfterOursWins() {
        #expect(ClipboardSource.resolve(systemChangeCount: 9, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: true) == .system)
    }

    /// ⌘C in Finder with nothing ever copied here. Nothing to compare against, and files are there.
    @Test func aFreshLaunchPastesWhatFinderHas() {
        #expect(ClipboardSource.resolve(systemChangeCount: 3, ownChangeCount: nil,
                                        hasInAppItems: false, systemHasFiles: true) == .system)
    }

    /// Copy files here, copy some text elsewhere, press ⌘V here. The count moved and the pasteboard
    /// holds no files, so the answer is nothing. Falling back to the stale list would write files to
    /// disk nobody asked for.
    @Test func textCopiedElsewherePastesNothingRatherThanOurStaleFiles() {
        #expect(ClipboardSource.resolve(systemChangeCount: 9, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: false) == .none)
    }

    /// Nothing anywhere: the menu item and the row action withhold themselves.
    @Test func anEmptyPasteboardAndAnEmptyListMeanNothingToPaste() {
        #expect(ClipboardSource.resolve(systemChangeCount: 3, ownChangeCount: nil,
                                        hasInAppItems: false, systemHasFiles: false) == .none)
    }

    /// A matching count with an emptied list (every cut item moved) falls through rather than
    /// claiming an in-app paste of nothing.
    @Test func owningThePasteboardWithAnEmptiedListIsNotAnInAppPaste() {
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: false, systemHasFiles: true) == .system)
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: false, systemHasFiles: false) == .none)
    }
}

/// The pasteboard bridge itself. Every test uses its own named pasteboard, never
/// `NSPasteboard.general`, so a run never clobbers the developer's real clipboard.
@MainActor
@Suite struct SystemClipboardTests {

    // The pid scopes the board to this process: named boards live in the machine-global
    // pasteboard server, so a concurrent test process would share an unsuffixed name (see
    // `board(_:)` in the handoff suite below).
    private func pasteboard(_ label: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name(
            "SyncCloudTests.\(label).\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        return board
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synccloud-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writtenFilesComeBackAsFileURLs() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)

        let board = pasteboard("roundtrip")
        let count = SystemClipboard.write(paths: [file.path], to: board)
        #expect(count == board.changeCount)
        #expect(SystemClipboard.fileURLs(from: board).map(\.path) == [file.path])
    }

    /// A web address on the pasteboard reads back as an `NSURL` unless the read is constrained to
    /// file URLs — and would then be handed to the copy engine as a file to copy.
    @Test func aWebAddressIsNotAFileToPaste() {
        let board = pasteboard("weburl")
        board.clearContents()
        board.writeObjects([NSURL(string: "https://example.com/report.pdf")!])
        #expect(SystemClipboard.fileURLs(from: board).isEmpty)
        #expect(SystemClipboard.nodes(from: board).isEmpty)
    }

    /// Directories and files are both pastable, and `isDirectory` is read from the disk: the copy
    /// engine branches on it, and a URL's own directory hint depends on how its sender built it.
    @Test func aDirectoryComesBackMarkedAsOne() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Invoices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)

        let board = pasteboard("kinds")
        // Written without a trailing slash or directory hint, as a path-derived URL is, so only
        // reading the disk can get `isDirectory` right.
        SystemClipboard.write(paths: [folder.path, file.path], to: board)
        let nodes = SystemClipboard.nodes(from: board)
        #expect(nodes.map(\.name) == ["Invoices", "note.txt"])
        #expect(nodes.map(\.isDirectory) == [true, false])
    }

    /// The pasteboard outlives the files on it. A paste that half-fails behind a banner claiming
    /// success is worse than one that pastes what is still there.
    @Test func aFileDeletedAfterItWasCopiedIsDropped() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = dir.appendingPathComponent("kept.txt")
        let gone = dir.appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: kept)
        try Data("x".utf8).write(to: gone)

        let board = pasteboard("vanished")
        SystemClipboard.write(paths: [kept.path, gone.path], to: board)
        try FileManager.default.removeItem(at: gone)
        #expect(SystemClipboard.nodes(from: board).map(\.name) == ["kept.txt"])
    }

    /// Writing nothing clears the board rather than leaving the previous copy pastable.
    @Test func writingNothingClearsWhatWasThere() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let board = pasteboard("cleared")
        SystemClipboard.write(paths: [file.path], to: board)
        #expect(!SystemClipboard.fileURLs(from: board).isEmpty)
        SystemClipboard.write(paths: [], to: board)
        #expect(SystemClipboard.fileURLs(from: board).isEmpty)
    }

    /// The memo tracks the pasteboard rather than freezing the first answer. It is asked from view
    /// bodies, so a stale `true` would leave Paste enabled over nothing for the rest of the session.
    @Test func theMemoFollowsTheChangeCount() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let board = pasteboard("memo")
        #expect(!SystemClipboard.hasFiles(in: board))
        SystemClipboard.write(paths: [file.path], to: board)
        #expect(SystemClipboard.hasFiles(in: board))
        board.clearContents()
        board.setString("just text", forType: .string)
        #expect(!SystemClipboard.hasFiles(in: board))
    }

    /// The memo is keyed by name as well as count. Two pasteboards keep independent counts, so a
    /// memo on the number alone would answer for the wrong board whenever the counts coincide,
    /// which two freshly cleared boards make likely.
    @Test func twoPasteboardsDoNotAnswerForEachOther() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let withFiles = pasteboard("memo.files")
        let withText = pasteboard("memo.text")
        SystemClipboard.write(paths: [file.path], to: withFiles)
        withText.clearContents()
        withText.setString("just text", forType: .string)

        // Interleaved, so a single-slot memo has to be wrong at least once.
        #expect(SystemClipboard.hasFiles(in: withFiles))
        #expect(!SystemClipboard.hasFiles(in: withText))
        #expect(SystemClipboard.hasFiles(in: withFiles))
    }
}

/// Both directions, end to end: ⌘C here puts something another app can read, and files copied in
/// another app land on disk when pasted here. The rule above can't show either.
@MainActor
@Suite struct SystemClipboardHandoffTests {

    /// A board of this test's own, never `.general` (see the handler's `pasteboard` parameter).
    ///
    /// Per test: these tests `await`, swift-testing may run a sibling while one is suspended, and
    /// `clearContents()` is no defence against a sibling writing. Per process too: a named
    /// `NSPasteboard` lives in the machine-global pasteboard server, so two test processes would
    /// share it (`docs/flaky-tests.md`, "A named NSPasteboard is machine-global, so two test
    /// PROCESSES share it"). A failure naming a temp path this process never created is the tell.
    private func board(_ label: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name(
            "SyncCloudTests.handoff.\(label).\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        return board
    }

    private func settings() -> SettingsManager {
        let settings = SettingsManager(autoDiscover: false,
                                       userDefaults: ScratchDefaults("SystemClipboardHandoffTests"),
                                       cloudStorageLister: { .read([]) },
                                       pathValidator: { _ in true })
        settings.availableProviders = []
        return settings
    }

    private func tempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-handoff-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The one wait here allowed to give up silently, for `textCopiedElsewhereWritesNothing`, which
    /// asserts a write never happens, so running out the budget is its success path. **Never**
    /// route an outcome through this; outcome waits use the shared `waitUntil`, which fails loudly.
    private func waitOutTheAbsenceBudget(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits for the operation bookkeeping to drain, then one settle; the same contract as
    /// `FileActionHandlerOperationTests.waitForOperationsToFinish`. Safe only because every caller
    /// waits for the operation's own outcome first. A fixed iteration count would give up silently
    /// under load.
    private func settle(_ manager: FileSyncManager,
                        sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("the file operations to drain", sourceLocation: sourceLocation) {
            manager.activeFileOperationsCount == 0
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    /// ⌘C here, ⌘V in Finder. The board must carry real file URLs; a path written as text pastes in
    /// Finder as a string.
    @Test func copyingHerePutsRealFileURLsWhereAnotherAppCanReadThem() throws {
        let dir = try tempDir("out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)

        let pasteboard = board("out")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "report.pdf", isDirectory: false)],
                                      isCut: false)

        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
        #expect(manager.clipboardPasteboardChangeCount == pasteboard.changeCount,
                "the token that decides who owns the pasteboard was not recorded")
    }

    /// A cut writes what a copy writes. The pasteboard has no move flag another app reads, so a cut
    /// here pasted there copies, the safe way to be wrong. `isCut` stays in the in-app clipboard.
    @Test func aCutIsStillACopyToEveryOtherApp() throws {
        let dir = try tempDir("cut")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("moved.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board("cut")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "moved.txt", isDirectory: false)],
                                      isCut: true)

        #expect(manager.clipboardIsCut, "the app's own clipboard is what remembers a cut")
        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
    }

    /// ⌘C in Finder, ⌘V here. Nothing was copied in the app, so the in-app list is empty and the
    /// pasteboard is the only source.
    @Test func filesCopiedInAnotherAppPasteIntoThePane() async throws {
        let source = try tempDir("in-src")
        let destination = try tempDir("in-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let file = source.appendingPathComponent("from-finder.txt")
        try Data("hello".utf8).write(to: file)

        let pasteboard = board("in-dst")
        // Written straight to the board, standing in for the other app; the handler would also fill
        // the in-app list and test the wrong branch.
        SystemClipboard.write(paths: [file.path], to: pasteboard)

        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        #expect(manager.clipboardNodes.isEmpty, "the fixture must exercise the system branch")

        handler.pasteClipboard(toPath: destination.path)
        let landed = destination.appendingPathComponent("from-finder.txt").path
        await waitUntil("the paste to land") { FileManager.default.fileExists(atPath: landed) }
        await settle(manager)

        #expect(FileManager.default.fileExists(atPath: landed))
        // A copy, never a move: the pasteboard carries no cut flag.
        #expect(FileManager.default.fileExists(atPath: file.path),
                "the source was removed — a paste from another app must never move")
    }

    /// The other side of that: while the app still owns the pasteboard, its own list wins, so a cut
    /// really moves rather than being downgraded to a copy by the bridge.
    @Test func owningThePasteboardKeepsTheMoveAMove() async throws {
        let source = try tempDir("own-src")
        let destination = try tempDir("own-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let file = source.appendingPathComponent("cut-me.txt")
        try Data("hello".utf8).write(to: file)

        let pasteboard = board("own-dst")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "cut-me.txt", isDirectory: false)],
                                      isCut: true)
        handler.pasteClipboard(toPath: destination.path)
        let landed = destination.appendingPathComponent("cut-me.txt").path
        await waitUntil("the paste to land") { FileManager.default.fileExists(atPath: landed) }
        await settle(manager)

        #expect(FileManager.default.fileExists(atPath: landed))
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the cut was downgraded to a copy — the in-app branch is what carries isCut")
    }

    /// A ⌘C that copies nothing must leave the clipboard alone. A copy writes to
    /// `NSPasteboard.general`, and an empty write clears it, throwing away whatever the user copied
    /// in another app.
    @Test func copyingAnEmptySelectionDoesNotClearWhatSomebodyElseCopied() throws {
        let dir = try tempDir("empty-copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theirs.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board("empty-copy")
        SystemClipboard.write(paths: [file.path], to: pasteboard)
        let before = pasteboard.changeCount

        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([], isCut: false)

        #expect(pasteboard.changeCount == before, "an empty copy wrote to the pasteboard")
        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
    }

    /// A second ⌘V after a cut has nothing to offer, and says so by being unavailable. After the
    /// move the cut's paths on the pasteboard name missing files, and `hasFiles` reads the board,
    /// not the disk (a `stat` per URL per render is too costly), so without clearing it ⌘V and
    /// "Paste here" would stay enabled over a paste that finds nothing.
    @Test func aCutThatCompletesLeavesNothingPastable() async throws {
        let source = try tempDir("stale-src")
        let destination = try tempDir("stale-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let file = source.appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board("stale-dst")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "gone.txt", isDirectory: false)],
                                      isCut: true)
        handler.pasteClipboard(toPath: destination.path)
        let landed = destination.appendingPathComponent("gone.txt").path
        await waitUntil("the paste to land") { FileManager.default.fileExists(atPath: landed) }
        await settle(manager)
        try #require(FileManager.default.fileExists(atPath: landed), "the move never happened")
        // The clear runs in the paste task once `moveItems` returns, after the operation count
        // `settle` waits on reaches zero, so it is waited for, never assumed by a fixed sleep.
        await waitUntil("the completed cut to clear the pasteboard") {
            SystemClipboard.fileURLs(from: pasteboard).isEmpty
        }

        #expect(SystemClipboard.fileURLs(from: pasteboard).isEmpty,
                "the pasteboard still names the file the cut moved away")
        #expect(ClipboardSource.current(pasteboard: pasteboard,
                                        hasInAppItems: !manager.clipboardNodes.isEmpty,
                                        ownChangeCount: manager.clipboardPasteboardChangeCount) == ClipboardSource.none,
                "Paste is still offered after the cut it would have pasted has completed")
    }

    /// And it clears only what it owns: a copy made elsewhere between the cut and its paste is
    /// somebody else's clipboard, and finishing our move must not take it.
    @Test func aCompletedCutDoesNotClearSomebodyElsesClipboard() async throws {
        let source = try tempDir("owned-src")
        let destination = try tempDir("owned-dst")
        let theirs = try tempDir("owned-theirs")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: theirs)
        }
        let file = source.appendingPathComponent("mine.txt")
        try Data("x".utf8).write(to: file)
        let theirFile = theirs.appendingPathComponent("theirs.txt")
        try Data("x".utf8).write(to: theirFile)

        let pasteboard = board("owned-theirs")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "mine.txt", isDirectory: false)],
                                      isCut: true)
        // Somebody else copies, so the app no longer owns the board, but the in-app list still
        // holds the cut, and pasting it still moves those files.
        SystemClipboard.write(paths: [theirFile.path], to: pasteboard)
        handler.pasteItems(manager.clipboardNodes, toPath: destination.path, isCut: true)
        await waitUntil("the cut's move to land") {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("mine.txt").path)
        }
        await settle(manager)

        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [theirFile.path],
                "finishing our move threw away a copy made in another app")
    }

    /// Text copied elsewhere after a copy here pastes nothing, rather than falling back to the
    /// stale list and writing files nobody asked for.
    @Test func textCopiedElsewhereWritesNothing() async throws {
        let source = try tempDir("text-src")
        let destination = try tempDir("text-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let file = source.appendingPathComponent("not-this.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board("text-dst")
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "not-this.txt", isDirectory: false)],
                                      isCut: false)
        // Somebody else copies text.
        pasteboard.clearContents()
        pasteboard.setString("just some words", forType: .string)

        handler.pasteClipboard(toPath: destination.path)
        // Nothing to wait for, so this waits out the whole budget: an assertion that a write didn't
        // happen is only worth what it waited.
        await waitOutTheAbsenceBudget { !((try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty ?? true) }
        await settle(manager)

        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(manager.banner == nil, "a paste that wrote nothing still announced something")
    }
}
