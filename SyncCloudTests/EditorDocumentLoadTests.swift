import Testing
import Foundation
import Events
import FileExplorer
@testable import SyncCloud

/// The order `EditorDocumentLoad.run` keeps between the document and its undo stacks, which
/// stands between a file switch and an `NSRangeException`: `NSTextView` registers undo by
/// character range, so a stack reunited with the wrong buffer splices characters out or throws.
/// The store's own rules are `EditorUndoStoreTests`. A class for its `deinit`: Swift Testing makes
/// one instance per test, which removes its own folder.
@MainActor
@Suite final class EditorDocumentLoadTests {
    /// This test's files; removed with the instance.
    let folder = NSTemporaryDirectory() + "load-order-" + UUID().uuidString

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func file(_ name: String, _ body: String) throws -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func load(_ path: String, _ document: EditorDocument, _ store: EditorUndoStore,
                      log: ((EditorLogLine) -> Void)? = nil) -> EditorFileStore.OpenResult {
        EditorDocumentLoad.run(path: path, document: document, undoStore: store,
                               log: { log?($0) })
    }

    // MARK: The invariant

    /// A round trip hands back the stack the document was left with. Fails if `remember(text:)`
    /// moves after the buffer is replaced, which files the outgoing stack against the incoming text.
    @Test func aRoundTripReturnsTheStackTheDocumentWasLeftWith() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        let stackForA = store.current
        // A real registration, so "the same stack came back" means something replayable came back.
        stackForA.registerUndo(withTarget: document) { _ in }
        try #require(stackForA.canUndo)

        load(b, document, store)
        #expect(store.current !== stackForA, "b was handed a's undo stack")
        #expect(!store.current.canUndo, "b's fresh stack arrived with a's registrations in it")

        load(a, document, store)
        #expect(store.current === stackForA, "a's history was lost across a round trip")
        #expect(store.current.canUndo, "a's stack came back empty")
    }

    /// A load never evicts the file it is opening: `run` tells the store which path is coming in.
    /// A limit of 2 and three edited files, a → b → c → a. Fails if `opening: path` is dropped, when
    /// the eviction making room for c's history would take a's on the way into a.
    @Test func aLoadNeverEvictsTheFileItIsOpening() throws {
        let paths = try ["a.md", "b.md", "c.md"].map { try file($0, String($0.prefix(1))) }
        let document = EditorDocument()
        let store = EditorUndoStore(limit: 2)
        var stacks: [UndoManager] = []
        for path in paths {
            load(path, document, store)
            stacks.append(store.current)
            store.current.registerUndo(withTarget: document) { _ in }
        }
        load(paths[0], document, store)
        #expect(store.current === stacks[0], "a's history was evicted on the way into a")
        #expect(store.current.canUndo)
    }

    /// A file that changed while it was away doesn't get its old registrations back. The control for
    /// ``aRoundTripReturnsTheStackTheDocumentWasLeftWith``: the store does refuse a stack.
    @Test func aStackIsRefusedWhenTheFileChangedWhileItWasAway() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        let stackForA = store.current
        load(b, document, store)
        try "alpha, edited elsewhere".write(toFile: a, atomically: true, encoding: .utf8)
        load(a, document, store)
        #expect(store.current !== stackForA,
                "a stack was replayed into a buffer that changed while it was away")
    }

    /// A refused file replaces the buffer too, so it must take the stack with it. `open`'s
    /// `.refused` arm empties the text and clears the stamp; leaving the previous document's manager
    /// current would leave ⌘Z live over an empty buffer with another file's ranges in it.
    @Test func aRefusedOpenAlsoMovesTheUndoStack() throws {
        let a = try file("a.md", "alpha")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        let stackForA = store.current
        stackForA.registerUndo(withTarget: document) { _ in }

        let missing = (folder as NSString).appendingPathComponent("not-here.md")
        let result = load(missing, document, store)
        #expect(result != .opened, "fixture: the missing file was expected to be refused")
        #expect(document.text.isEmpty)
        #expect(store.current !== stackForA,
                "a refused open left the previous document's undo stack live over an empty buffer")
        #expect(!store.current.canUndo)
    }

    /// A load also sweeps stacks whose files are gone. `forgetMissingFiles` is in the load because
    /// that is when a stack is put away, and a stack for a path that no longer exists can never be
    /// handed back. This checks the load performs the sweep, not just that the store can.
    @Test func aLoadDropsTheHistoryOfFilesThatAreGone() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let c = try file("c.md", "charlie")
        let document = EditorDocument()
        let store = EditorUndoStore()

        // Each edited, so each has a history to keep: an empty one is not kept.
        load(a, document, store)
        store.current.registerUndo(withTarget: document) { _ in }
        load(b, document, store)
        let stackForB = store.current
        stackForB.registerUndo(withTarget: document) { _ in }
        try #require(store.keptCount == 1, "fixture: a's stack should be the one kept")

        // a is filed away and then deleted out from under the store.
        try FileManager.default.removeItem(atPath: a)
        load(c, document, store)
        // b's stack is now kept and a's is not: the sweep ran during this load.
        #expect(store.keptCount == 1, "the sweep did not run, or took too much: \(store.keptCount)")
        load(b, document, store)
        #expect(store.current === stackForB, "b came back without its own history")
        // And it was a's that went: reopening a gets a stack, but never the old one, because the
        // file it described is gone.
        try "alpha".write(toFile: a, atomically: true, encoding: .utf8)
        load(a, document, store)
        #expect(store.keptCount <= 2)
    }

    // MARK: The log

    /// One line per load whatever the read did: a refusal is as visible as a success.
    @Test func everyLoadIsLoggedOnceAndSaysWhatHappened() throws {
        let a = try file("a.md", "alpha")
        let document = EditorDocument()
        let store = EditorUndoStore()
        var logged: [EditorLogLine] = []
        var lines: [String] { logged.map(\.text) }

        load(a, document, store) { logged.append($0) }
        #expect(logged == [.info("Editor opened \(a)")])

        let missing = (folder as NSString).appendingPathComponent("not-here.md")
        load(missing, document, store) { logged.append($0) }
        #expect(lines.count == 2, "a refused load wrote no line: \(lines)")
        #expect(logged.last?.level == .warning, "a file that couldn’t be read was not logged as a warning")
        #expect(lines.last?.hasPrefix("Editor could not open \(missing)") == true,
                "a refusal was not logged as one: \(lines)")
        #expect(lines.last?.contains("opened") == false,
                "a refused file was logged as opened: \(lines)")
    }

    /// The read-only wording, which no other test reaches: a file that decodes lossily is shown and
    /// refused for saving, and the line has to say which of the three happened.
    @Test func aLossyDecodeIsLoggedAsReadOnly() throws {
        // Valid UTF-8 for the NUL sniff to pass, then a byte that is not.
        let path = (folder as NSString).appendingPathComponent("lossy.md")
        try (Data("notes ".utf8) + Data([0xFF]) + Data(" more\n".utf8))
            .write(to: URL(fileURLWithPath: path))
        let document = EditorDocument()
        let store = EditorUndoStore()
        var logged: [EditorLogLine] = []
        var lines: [String] { logged.map(\.text) }

        let result = load(path, document, store) { logged.append($0) }
        if case .readOnly = result {
            #expect(logged.last?.level == .info)
            #expect(lines.last?.hasPrefix("Editor opened \(path) read-only") == true,
                    "a read-only open was not logged as one: \(lines)")
        } else {
            // If the reader classifies it differently, say so rather than assert the wrong thing.
            Issue.record("fixture did not decode lossily; got \(result)")
        }
    }

    // MARK: The text storage (TE67.0)

    /// The first load writes the file into no storage but the one it keeps. The buffer and the
    /// store start with a storage each, and writing into the buffer's would be thrown away, with a
    /// resync logged if a view was mounted on it.
    @Test func theFirstLoadWritesIntoNoThrowawayStorage() throws {
        let a = try file("a.md", "alpha")
        let document = EditorDocument()
        let initial = document.buffer.source
        let store = EditorUndoStore()
        load(a, document, store)
        #expect(initial.textStorage.length == 0, "the first load wrote into the buffer's first storage")
        #expect(document.buffer.source === store.source)
        #expect(document.buffer.source.textStorage.string == "alpha")
    }

    /// The buffer follows the storage kept beside the stack, back to the same object on a round
    /// trip, or the text view shows the outgoing storage beside the incoming stack. Fails if `run`
    /// drops `document.buffer.follow(undoStore.source)`.
    @Test func theBufferFollowsTheStorageKeptBesideTheStack() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        #expect(document.buffer.source === store.source, "the buffer does not follow a's storage")
        #expect(document.buffer.source.textStorage.string == "alpha")
        let storageForA = store.source
        // An edit, so a's history, and with it a's storage, is kept: an empty one is not.
        store.current.registerUndo(withTarget: document) { _ in }

        load(b, document, store)
        #expect(document.buffer.source === store.source, "the buffer does not follow b's storage")
        #expect(document.buffer.source.textStorage.string == "bravo")
        #expect(storageForA.textStorage.string == "alpha", "loading b wrote into the storage kept for a")

        load(a, document, store)
        #expect(document.buffer.source === storageForA, "a came back without the storage its stack edits")
    }

    /// An edit through the storage reaches the document, and ⌘Z takes it back out: the bridge the
    /// text view and the task tick both use, through the shipped load.
    @Test func anEditToTheFollowedStorageReachesTheDocument() throws {
        let a = try file("a.md", "- [ ] one\n")
        let document = EditorDocument()
        let store = EditorUndoStore()
        load(a, document, store)

        document.buffer.source.replace(NSRange(location: 3, length: 1), with: "x", undoManager: store.current)
        #expect(document.text == "- [x] one\n", "an edit to the storage did not reach the document")
        #expect(document.isDirty)
        store.current.undo()
        #expect(document.text == "- [ ] one\n", "⌘Z did not reach the document")
        #expect(!document.isDirty, "an undo back to the file's text still reads as dirty")
    }

    // MARK: A word being composed (UND-5)

    /// The settle and the quit's flush end a composition before reading the buffer, which leaves a
    /// half-composed word out while the storage holds it: the file would be saved without the word.
    /// Fails if either `endComposition()` is removed (the commit itself: `PlainTextEditorBridgeTests`).
    @Test func leavingADocumentEndsTheCompositionFirst() throws {
        let settle = CodeText(try declarationBody(of: "func settleEditorDocument(asksAboutPDFWork: Bool = true, asksAboutTheOnlyCopy: Bool = true, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool",
                                                  in: macAppCode("ContentView+Editor.swift")))
        let ends = try #require(settle.range(of: "editorDocument.buffer.source.endComposition()"),
                                "leaving a document no longer ends the composition")
        let asks = try #require(settle.range(of: "let withheld"))
        #expect(ends.lowerBound < asks.lowerBound, "the composition is ended after the buffer was read")
        let quit = CodeText(try declarationBody(of: "func applicationShouldTerminate(_ sender: NSApplication)",
                                                in: macAppCode("SyncCloudApp.swift")))
        let quitEnds = try #require(quit.range(of: "Self.sharedEditorDocument?.buffer.source.endComposition()"),
                                    "quitting no longer ends the composition before the flush")
        let flush = try #require(quit.range(of: "EditorAutosave.attempt(document)"))
        #expect(quitEnds.lowerBound < flush.lowerBound)
    }
}
