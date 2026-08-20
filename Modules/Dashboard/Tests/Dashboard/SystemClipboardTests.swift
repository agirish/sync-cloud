import Testing
import Foundation
import AppKit
import Sync
import Settings
@testable import Dashboard

/// **Which clipboard a ⌘V means.**
///
/// The rule is the whole feature: there are two clipboards and the user believes in one. Every
/// branch below is a real sequence somebody performs, named as that sequence.
@Suite struct ClipboardSourceTests {

    /// ⌘C here, ⌘V here. The app still owns the pasteboard, so its own list answers — and only that
    /// list carries `isCut`, so this is the only branch that can move rather than copy.
    @Test func copyHereThenPasteHereUsesTheAppsOwnList() {
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: true) == .inApp)
    }

    /// ⌘C here, then ⌘C in Finder, then ⌘V here. The count moved, so Finder's files win — which is
    /// what a single-clipboard platform promises and what the user who just pressed ⌘C expects.
    @Test func aCopyMadeElsewhereAfterOursWins() {
        #expect(ClipboardSource.resolve(systemChangeCount: 9, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: true) == .system)
    }

    /// ⌘C in Finder with nothing ever copied here. Nothing to compare against, and files are there.
    @Test func aFreshLaunchPastesWhatFinderHas() {
        #expect(ClipboardSource.resolve(systemChangeCount: 3, ownChangeCount: nil,
                                        hasInAppItems: false, systemHasFiles: true) == .system)
    }

    /// **The branch that stops a surprise write.** Copy files here, copy some *text* somewhere else,
    /// press ⌘V here. The count has moved and the pasteboard holds no files — so the answer is
    /// nothing, not a fallback to the stale list. Falling back would copy files onto disk that
    /// nobody asked for, minutes after the copy that named them.
    @Test func textCopiedElsewherePastesNothingRatherThanOurStaleFiles() {
        #expect(ClipboardSource.resolve(systemChangeCount: 9, ownChangeCount: 7,
                                        hasInAppItems: true, systemHasFiles: false) == .none)
    }

    /// Nothing anywhere: the menu item and the row action withhold themselves.
    @Test func anEmptyPasteboardAndAnEmptyListMeanNothingToPaste() {
        #expect(ClipboardSource.resolve(systemChangeCount: 3, ownChangeCount: nil,
                                        hasInAppItems: false, systemHasFiles: false) == .none)
    }

    /// A count that matches but a list that has been emptied — every cut item moved — falls through
    /// rather than claiming an in-app paste of nothing.
    @Test func owningThePasteboardWithAnEmptiedListIsNotAnInAppPaste() {
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: false, systemHasFiles: true) == .system)
        #expect(ClipboardSource.resolve(systemChangeCount: 7, ownChangeCount: 7,
                                        hasInAppItems: false, systemHasFiles: false) == .none)
    }
}

/// **The pasteboard bridge itself.**
///
/// Every test here uses its **own named pasteboard**, never `NSPasteboard.general`: this suite runs
/// on the developer's machine and clobbering the real clipboard mid-session is not a cost a test
/// gets to impose.
@MainActor
@Suite struct SystemClipboardTests {

    private func pasteboard(_ label: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("SyncCloudTests.\(label)"))
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

    /// Directories and files are both pastable, and `isDirectory` is read from the **disk**: the
    /// copy engine branches on it, and a URL's own directory hint depends on how its sender built
    /// it.
    @Test func aDirectoryComesBackMarkedAsOne() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Invoices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)

        let board = pasteboard("kinds")
        // Written WITHOUT a trailing slash and without a directory hint — the shape a path-derived
        // URL takes, which is what makes reading the disk load-bearing rather than defensive.
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

    /// Writing nothing clears rather than leaving the previous copy standing — a ⌘C on an empty
    /// selection must not leave the last one pastable.
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

    /// The memo tracks the pasteboard rather than freezing the first answer — it is asked from view
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

    /// **The memo is keyed by name as well as count.** Two pasteboards keep independent counts, so
    /// a memo on the number alone answers one board's question with the other's reading whenever
    /// the two coincide — which two freshly-cleared boards make likely, not unlikely.
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

/// **Both directions, end to end.**
///
/// The rule above says which clipboard a paste means; these say the bridge is actually connected —
/// that ⌘C here puts something a *different app* can read, and that files copied in a different app
/// land on disk when pasted here. Neither is visible from the rule.
@MainActor
@Suite struct SystemClipboardHandoffTests {

    /// This suite's own board, never `.general` — see the handler's `pasteboard` parameter.
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("SyncCloudTests.handoff"))
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

    /// Polls for the **outcome**, then drains.
    ///
    /// Waiting on `activeFileOperationsCount == 0` alone returns instantly, before the paste's
    /// `Task` has started — which is the shape `FileActionHandlerOperationTests` documents and the
    /// first cut of these three tests walked straight into: every one of them read the destination
    /// while it was still legitimately empty.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func settle(_ manager: FileSyncManager) async {
        for _ in 0..<50 {
            if manager.activeFileOperationsCount == 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// **⌘C here, ⌘V in Finder.** The half that did not exist: every `NSPasteboard` use in the app
    /// before this wrote a path as *text*, which Finder pastes as a string.
    @Test func copyingHerePutsRealFileURLsWhereAnotherAppCanReadThem() throws {
        let dir = try tempDir("out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try Data("x".utf8).write(to: file)

        let pasteboard = board()
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "report.pdf", isDirectory: false)],
                                      isCut: false)

        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
        #expect(manager.clipboardPasteboardChangeCount == pasteboard.changeCount,
                "the token that decides who owns the pasteboard was not recorded")
    }

    /// A **cut** writes what a copy writes. The pasteboard has no move flag another app reads, so
    /// a cut here pasted there copies — the safe direction of being wrong, and the reason `isCut`
    /// stays in the in-app clipboard instead of being encoded onto the board.
    @Test func aCutIsStillACopyToEveryOtherApp() throws {
        let dir = try tempDir("cut")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("moved.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board()
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "moved.txt", isDirectory: false)],
                                      isCut: true)

        #expect(manager.clipboardIsCut, "the app's own clipboard is what remembers a cut")
        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
    }

    /// **⌘C in Finder, ⌘V here.** Nothing was ever copied in the app, so the in-app list is empty
    /// and the pasteboard is the only source — the case that used to paste nothing at all.
    @Test func filesCopiedInAnotherAppPasteIntoThePane() async throws {
        let source = try tempDir("in-src")
        let destination = try tempDir("in-dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let file = source.appendingPathComponent("from-finder.txt")
        try Data("hello".utf8).write(to: file)

        let pasteboard = board()
        // Written straight to the board, standing in for the other app — not through the handler,
        // which would also fill the in-app list and test the wrong branch.
        SystemClipboard.write(paths: [file.path], to: pasteboard)

        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        #expect(manager.clipboardNodes.isEmpty, "the fixture must exercise the system branch")

        handler.pasteClipboard(toPath: destination.path)
        let landed = destination.appendingPathComponent("from-finder.txt").path
        await waitUntil { FileManager.default.fileExists(atPath: landed) }
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

        let pasteboard = board()
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "cut-me.txt", isDirectory: false)],
                                      isCut: true)
        handler.pasteClipboard(toPath: destination.path)
        let landed = destination.appendingPathComponent("cut-me.txt").path
        await waitUntil { FileManager.default.fileExists(atPath: landed) }
        await settle(manager)

        #expect(FileManager.default.fileExists(atPath: landed))
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the cut was downgraded to a copy — the in-app branch is what carries isCut")
    }

    /// **A ⌘C that copies nothing must leave the clipboard alone.**
    ///
    /// Harmless while the app's list was the only clipboard — it emptied something only this app
    /// read. Not harmless once a copy writes to `NSPasteboard.general`: an empty write clears it,
    /// so a copy of nothing would throw away whatever the user had copied in another app.
    @Test func copyingAnEmptySelectionDoesNotClearWhatSomebodyElseCopied() throws {
        let dir = try tempDir("empty-copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theirs.txt")
        try Data("x".utf8).write(to: file)

        let pasteboard = board()
        SystemClipboard.write(paths: [file.path], to: pasteboard)
        let before = pasteboard.changeCount

        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([], isCut: false)

        #expect(pasteboard.changeCount == before, "an empty copy wrote to the pasteboard")
        #expect(SystemClipboard.fileURLs(from: pasteboard).map(\.path) == [file.path])
    }

    /// Text copied elsewhere after a copy here pastes **nothing**, rather than falling back to the
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

        let pasteboard = board()
        let manager = FileSyncManager()
        let handler = FileActionHandler(syncManager: manager, settings: settings(), pasteboard: pasteboard)
        handler.handleCopyToClipboard([FileNode(id: file.path, name: "not-this.txt", isDirectory: false)],
                                      isCut: false)
        // Somebody else copies text.
        pasteboard.clearContents()
        pasteboard.setString("just some words", forType: .string)

        handler.pasteClipboard(toPath: destination.path)
        // Nothing to wait FOR, so this waits for the whole budget the other two poll within —
        // an assertion that a write did not happen is only worth what it waited.
        await waitUntil { !((try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty ?? true) }
        await settle(manager)

        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(manager.banner == nil, "a paste that wrote nothing still announced something")
    }
}
