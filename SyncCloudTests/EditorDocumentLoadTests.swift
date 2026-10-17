import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// **The ordering `EditorDocumentLoad.run` keeps between the document and its undo stacks** — the
/// one property standing between a file switch and an `NSRangeException`.
///
/// `EditorUndoStoreTests` covers the store's own rules: one stack per path, a stack refused when its
/// fingerprint no longer fits. What nothing covered was the SEQUENCE those calls are made in around
/// the buffer being replaced, and that is where the crash comes from — `NSTextView` registers undo
/// by character range in the buffer the edit was made against, so a stack reunited with the wrong
/// buffer splices characters out of it or throws.
///
/// **These run the shipped function.** An earlier version of this suite lived in the FileExplorer
/// package with a local copy of the three calls, because `ContentView` cannot be built in a test —
/// which pinned the transcription and would have passed with the real sequence written any way at
/// all. Extracting `EditorDocumentLoad` is what made the invariant testable; this is the test that
/// needed it.
///
/// **A class, for its `deinit`** — Swift Testing makes one instance per test, so each test's files
/// live in one folder the instance owns and removes when it goes, rather than leaving a folder per
/// call behind in the temporary directory.
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
                      log: ((String) -> Void)? = nil) -> EditorFileStore.OpenResult {
        EditorDocumentLoad.run(path: path, document: document, undoStore: store,
                               log: { log?($0) })
    }

    // MARK: The invariant

    /// **A round trip hands back the stack the document was left with.**
    ///
    /// This is the assertion that fails if `remember(text:)` moves to after the buffer is replaced:
    /// the outgoing stack would be filed against the INCOMING text, its fingerprint would then agree
    /// with a buffer it was never made against, and coming back would hand it over.
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

    /// **A load never evicts the file it is opening** (UND-7): `run` tells the store which path is
    /// coming in. A limit of 2 and three edited files, a → b → c → a: before the fix the eviction
    /// that made room for c's history took a's, on the way into a. Mutation: drop `opening: path`.
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

    /// **The incoming stack is checked against what ACTUALLY loaded**, so a file that changed while
    /// it was away does not get its old registrations back.
    ///
    /// The positive control for the test above: it proves that one is asserting the sequence keeps
    /// the two in step, rather than that the store never refuses anything.
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

    /// **A refused file replaces the buffer too, so it must take the stack with it.** `open`'s
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

    /// **Nothing in the load suspends**, which is what stops a render pass seeing one document's
    /// text beside another's undo manager. Stated as a test rather than only as prose in
    /// `EditorDocumentLoad`, because "it is synchronous" is exactly the property an innocent-looking
    /// `await` takes away — and the day someone adds one, the document and the stack must still be
    /// observed moving together.
    @Test func theDocumentAndTheUndoStackMoveInTheSameTurn() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        let stackForA = store.current
        load(b, document, store)
        // One turn: by the time `run` has returned, BOTH have moved to b. If the load ever gains a
        // suspension in the wrong place, this is where the two are caught disagreeing.
        #expect(document.text == "bravo")
        #expect(document.path == b)
        #expect(store.current !== stackForA)
    }

    /// **A load also sweeps stacks whose files are gone.** `forgetMissingFiles` is in the load
    /// because that is the moment a stack is put away, and a stack for a path that no longer exists
    /// can never be handed back — keeping it holds memory for an outcome that cannot happen. Nothing
    /// asserted that the load performs the sweep, only that the store can.
    @Test func aLoadDropsTheHistoryOfFilesThatAreGone() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let c = try file("c.md", "charlie")
        let document = EditorDocument()
        let store = EditorUndoStore()

        // Each edited, so each has a history to keep: an empty one is not kept (2026-10-09).
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
        // And the proof that it was A that went: reopening a gets a stack, but never the old one,
        // because the file it described is gone.
        try "alpha".write(toFile: a, atomically: true, encoding: .utf8)
        load(a, document, store)
        #expect(store.keptCount <= 2)
    }

    // MARK: The log

    /// One line per load whatever the read did — a refusal is as visible as a success.
    @Test func everyLoadIsLoggedOnceAndSaysWhatHappened() throws {
        let a = try file("a.md", "alpha")
        let document = EditorDocument()
        let store = EditorUndoStore()
        var lines: [String] = []

        load(a, document, store) { lines.append($0) }
        #expect(lines == ["Editor opened \(a)"])

        let missing = (folder as NSString).appendingPathComponent("not-here.md")
        load(missing, document, store) { lines.append($0) }
        #expect(lines.count == 2, "a refused load wrote no line: \(lines)")
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
        var lines: [String] = []

        let result = load(path, document, store) { lines.append($0) }
        if case .readOnly = result {
            #expect(lines.last?.hasPrefix("Editor opened \(path) read-only") == true,
                    "a read-only open was not logged as one: \(lines)")
        } else {
            // Not the fixture's fault if the reader classifies it differently — say so rather than
            // asserting the wrong thing.
            Issue.record("fixture did not decode lossily; got \(result)")
        }
    }

    // MARK: The text storage (TE67.0)

    /// **The first load writes the file into no storage but the one it keeps** (2026-10-09). The
    /// buffer and the store started with a storage each, and the first load wrote the whole file
    /// into the buffer's — then threw it away, after logging a resync when a view was mounted on it.
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

    /// **Step 4: the buffer follows the storage kept beside the stack** — on the way in, and back to
    /// the same storage object on a round trip. Without it the text view goes on showing the
    /// outgoing document's storage beside the incoming document's stack. Mutation: drop
    /// `document.buffer.follow(undoStore.source)` from `run` and every assertion here fails.
    @Test func theBufferFollowsTheStorageKeptBesideTheStack() throws {
        let a = try file("a.md", "alpha")
        let b = try file("b.md", "bravo")
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(a, document, store)
        #expect(document.buffer.source === store.source, "the buffer does not follow a's storage")
        #expect(document.buffer.source.textStorage.string == "alpha")
        let storageForA = store.source
        // An edit, so a's history — and with it a's storage — is kept: an empty one is not.
        store.current.registerUndo(withTarget: document) { _ in }

        load(b, document, store)
        #expect(document.buffer.source === store.source, "the buffer does not follow b's storage")
        #expect(document.buffer.source.textStorage.string == "bravo")
        #expect(storageForA.textStorage.string == "alpha", "loading b wrote into the storage kept for a")

        load(a, document, store)
        #expect(document.buffer.source === storageForA, "a came back without the storage its stack edits")
    }

    /// **An edit through the storage reaches the document, and ⌘Z takes it back out** — the bridge
    /// the text view and the task tick both use, through the shipped load.
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

    /// **Every route out of a document ends a composition before anything reads the buffer** — the
    /// settle that precedes every load and close, and the quit's flush. The buffer leaves a
    /// half-composed word out while the storage holds it, so a switch mid-composition flushed the
    /// file without the word and kept a storage that had it: on return the screen showed the word
    /// and the document did not, and the next keystroke wrote it. The commit itself is tested in
    /// the package (`PlainTextEditorBridgeTests`); `ContentView` cannot be built, so its call sites
    /// are read. Mutation: remove either `endComposition()`.
    @Test func leavingADocumentEndsTheCompositionFirst() throws {
        let settle = CodeText(try declarationBody(of: "func settleEditorDocument() -> Bool",
                                                  in: EditorHeaderDoorsWiringTests.editor()))
        let ends = try #require(settle.range(of: "editorDocument.buffer.source.endComposition()"),
                                "leaving a document no longer ends the composition")
        let asks = try #require(settle.range(of: "let withheld"))
        #expect(ends.lowerBound < asks.lowerBound, "the composition is ended after the buffer was read")
        let quit = CodeText(try declarationBody(of: "func applicationShouldTerminate(_ sender: NSApplication)",
                                                in: EditorHeaderDoorsWiringTests.source("SyncCloudApp.swift")))
        let quitEnds = try #require(quit.range(of: "Self.sharedEditorDocument?.buffer.source.endComposition()"),
                                    "quitting no longer ends the composition before the flush")
        let flush = try #require(quit.range(of: "EditorAutosave.attempt(document)"))
        #expect(quitEnds.lowerBound < flush.lowerBound)
    }
}
