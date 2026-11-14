import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// Putting the open document away: the act both doors share, run against a real document, a real
/// undo store and a pane selection held the way `FileSyncManager` holds it.
///
/// Run, not scanned. `EditorDocumentClose.run` is the whole act and `ContentView` only supplies
/// its pieces, which `EditorHeaderDoorsWiringTests` scans. So a test here with its own `settle`
/// proves the order and the contract, and the scan proves the app passes the real
/// `settleEditorDocument()`.
///
/// A class, for its `deinit`: Swift Testing makes one instance per test, so each test's files live
/// in one folder the instance removes when it goes.
@MainActor
@Suite final class EditorDocumentCloseTests {

    /// This test's files; removed with the instance.
    let folder = NSTemporaryDirectory() + "close-" + UUID().uuidString

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    /// A pane selection and a log, as the window holds them.
    final class Window {
        var selection: Set<String> = []
        var lines: [String] = []
        var settles = 0
    }

    private func document(named name: String, text: String = "hello\n") throws -> (EditorDocument, String) {
        let doc = EditorDocument()
        let folder = (self.folder as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        _ = EditorFileStore.load(path: path, into: doc)
        return (doc, path)
    }

    @discardableResult
    private func close(_ doc: EditorDocument, _ store: EditorUndoStore, _ window: Window,
                       settle: Bool) -> Bool {
        EditorDocumentClose.run(
            document: doc, undoStore: store,
            settle: {
                window.settles += 1
                // Asked while the document is still there to ask about.
                #expect(doc.path != nil, "settle ran after the document was already unloaded")
                return settle
            },
            paneSelection: { window.selection },
            setPaneSelection: { window.selection = $0 },
            log: { window.lines.append($0) })
    }

    // MARK: When it is offered

    /// Edit on screen with a document, and a refused document counts, unlike for the Text and
    /// Markup menus: a refusal is still something on screen to put away.
    @Test func closeIsOfferedInEditWithAnyDocumentOpen() {
        #expect(EditorDocumentClose.isOffered(workspace: .editor, hasDocument: true))
        #expect(!EditorDocumentClose.isOffered(workspace: .editor, hasDocument: false),
                "Close Document is live with nothing open")
        for other in Workspace.allCases where other != .editor {
            #expect(!EditorDocumentClose.isOffered(workspace: other, hasDocument: true),
                    "Close Document is live from \(other), aimed at a document nobody is looking at")
        }
    }

    // MARK: What it does

    /// Settled first; Cancel means nothing happened. The document stays open with its typing, the
    /// pane selection is untouched, and the one log line says so.
    @Test func cancellingTheSettleLeavesTheDocumentOpen() throws {
        let (doc, path) = try document(named: "note.md")
        doc.text = "hello\ntyped\n"
        let window = Window()
        window.selection = [path]
        let closed = close(doc, EditorUndoStore(), window, settle: false)
        #expect(!closed)
        #expect(window.settles == 1)
        #expect(doc.path == path, "a cancelled close unloaded the document")
        #expect(doc.text == "hello\ntyped\n", "a cancelled close lost the typing")
        #expect(window.selection == [path], "a cancelled close cleared the pane selection")
        #expect(window.lines == ["Editor close of \(path) cancelled — the open document was kept"])
    }

    /// Closed: the empty state. No path, no text, no refusal (which draws "Choose a file…"), and
    /// one log line naming the file.
    @Test func closingUnloadsToTheEmptyState() throws {
        let (doc, path) = try document(named: "note.md")
        let window = Window()
        #expect(close(doc, EditorUndoStore(), window, settle: true))
        #expect(window.settles == 1)
        #expect(doc.path == nil && doc.text.isEmpty && doc.refusal == nil && !doc.isReadOnly)
        #expect(window.lines == ["Editor closed \(path)"])
    }

    /// A read-only document and a refused one close too; each still has a name in the header.
    @Test func readOnlyAndRefusedDocumentsClose() throws {
        // Valid text and one byte that is not UTF-8 (and not a NUL): a lossy decode, read-only, the
        // fixture `EditorFileStoreTests.aLossyDecodeOpensReadOnly` uses.
        let folder = (self.folder as NSString).appendingPathComponent("read-only")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let bad = (folder as NSString).appendingPathComponent("lossy.txt")
        var bytes = Data("caf".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Array("\n".utf8))
        try bytes.write(to: URL(fileURLWithPath: bad))
        let readOnly = EditorDocument()
        _ = EditorFileStore.load(path: bad, into: readOnly)
        try #require(readOnly.path == bad && readOnly.isReadOnly && readOnly.refusal == nil,
                     "the fixture did not open — it is not testing a read-only close")

        let refused = EditorDocument()
        let missing = (folder as NSString).appendingPathComponent("gone.md")
        _ = EditorFileStore.load(path: missing, into: refused)
        try #require(refused.refusal != nil && refused.path == missing,
                     "the fixture was not refused — it is not testing a refused close")

        for doc in [readOnly, refused] {
            let window = Window()
            #expect(close(doc, EditorUndoStore(), window, settle: true))
            #expect(doc.path == nil && doc.refusal == nil)
        }
    }

    // MARK: Clicking the same row opens it again

    /// The pane selection that named the closed file is cleared, which is what lets a click on the
    /// same row reopen it. A pane click opens on a change of `selectedLeftPaths`; left naming the
    /// file, the click would set the same set again and nothing would fire.
    ///
    /// Walked as the window walks it: close, then the click sets `[path]`, which must differ from
    /// what the close left; the one-click rule names the file; and `openInEditor`'s already-open
    /// guard (`path != editorDocument.path`) lets it through because the document is empty. Fails
    /// if `paneSelection(afterClosing:selection:)` returns `nil`.
    @Test func afterACloseClickingTheSamePaneRowOpensItAgain() throws {
        let (doc, path) = try document(named: "note.md")
        let window = Window()
        window.selection = [path]
        close(doc, EditorUndoStore(), window, settle: true)

        let clicked: Set<String> = [path]
        #expect(window.selection != clicked,
                "the pane still selects \(window.selection) — clicking that row changes nothing, so it cannot reopen")
        #expect(ContentView.paneSelectionOpens(workspace: .editor, paneHidden: false,
                                               paths: clicked, isDirectory: false) == path)
        #expect(path != doc.path, "the already-open guard would swallow the click")
        _ = EditorFileStore.load(path: path, into: doc)
        #expect(doc.path == path && doc.text == "hello\n", "the file did not reopen")
    }

    /// Only a selection of exactly the closed file is cleared. Anything else is the user's, and
    /// clicking the closed file's row from there is a change anyway.
    @Test func onlyTheClosedFilesOwnSelectionIsCleared() {
        let path = "/n/Notes/note.md"
        #expect(EditorDocumentClose.paneSelection(afterClosing: path, selection: [path]) == [])
        #expect(EditorDocumentClose.paneSelection(afterClosing: path, selection: ["/n/Notes//note.md"]) == [],
                "a doubled separator kept the selection standing")
        #expect(EditorDocumentClose.paneSelection(afterClosing: path, selection: ["/n/Notes/other.md"]) == nil)
        #expect(EditorDocumentClose.paneSelection(afterClosing: path, selection: [path, "/n/Notes/other.md"]) == nil)
        #expect(EditorDocumentClose.paneSelection(afterClosing: path, selection: []) == nil)
    }

    /// The run applies that rule, rather than clearing whatever is selected.
    @Test func aDifferentSelectionSurvivesTheClose() throws {
        let (doc, _) = try document(named: "note.md")
        let window = Window()
        window.selection = ["/elsewhere/folder"]
        close(doc, EditorUndoStore(), window, settle: true)
        #expect(window.selection == ["/elsewhere/folder"], "the close cleared a selection that was not the file")
    }

    // MARK: Undo

    /// The file's undo history is put away, not thrown away: a fresh stack for the empty editor,
    /// and the file's own back when it is reopened, as a file switch does.
    @Test func theUndoHistoryIsKeptForTheFileAndTheEmptyEditorStartsFresh() throws {
        let (doc, path) = try document(named: "note.md")
        let store = EditorUndoStore()
        store.activate(path: path, text: doc.text)
        let history = store.current
        history.registerUndo(withTarget: doc) { _ in }
        try #require(history.canUndo)

        let storage = store.source
        doc.buffer.follow(storage)
        close(doc, store, Window(), settle: true)
        #expect(store.current !== history && !store.current.canUndo,
                "the empty editor inherited the closed file's undo stack")
        // The storage goes with the stack: the empty editor follows a fresh, empty one, and the
        // file's own is left holding the file's text.
        #expect(doc.buffer.source === store.source && store.source !== storage,
                "the empty editor still follows the closed file's storage")
        #expect(store.source.textStorage.string.isEmpty)
        #expect(storage.textStorage.string == "hello\n", "closing wrote the empty buffer into the file's storage")

        _ = EditorFileStore.load(path: path, into: doc)
        store.activate(path: path, text: doc.text)
        #expect(store.current === history && store.current.canUndo,
                "reopening the file did not hand its history back")
    }

    // MARK: Closing the WINDOW, which leaves the document open (UND-6)

    /// "Don't Save" before the window closes reloads the file. The document outlives the window, so
    /// without a reload the discarded typing would stay in the buffer with its history gone, and
    /// reopening the window would bring it back with no ⌘Z. The app's reload is
    /// `reloadOverTheBuffer` (scanned below); here it is the same forget-and-load. Fails if
    /// `settleForWindowClose` drops `reload(path)`.
    @Test func discardingBeforeAWindowCloseReloadsTheFile() throws {
        let (doc, path) = try document(named: "note.md")
        let store = EditorUndoStore()
        store.activate(path: path, text: doc.text)
        doc.buffer.follow(store.source)
        doc.text = "hello\ntyped\n"
        try #require(doc.isDirty)
        var reloaded: [String] = []
        let closes = EditorDocumentClose.settleForWindowClose(
            document: doc,
            settle: { true },   // "Don't Save": nothing written, and the window may go
            reload: { path in
                reloaded.append(path)
                store.forget(path)
                EditorDocumentLoad.run(path: path, document: doc, undoStore: store, log: { _ in })
            })
        #expect(closes)
        #expect(reloaded == [path])
        #expect(doc.text == "hello\n", "the discarded typing is still in the document behind the window")
        #expect(!doc.isDirty)
    }

    /// A settle that wrote the document, or was cancelled, reloads nothing, and Cancel keeps the
    /// window.
    @Test func aWindowCloseThatSavesOrCancelsReloadsNothing() throws {
        let (doc, _) = try document(named: "note.md")
        doc.text = "hello\ntyped\n"
        var reloads = 0
        #expect(!EditorDocumentClose.settleForWindowClose(document: doc, settle: { false },
                                                           reload: { _ in reloads += 1 }))
        let saved = EditorDocumentClose.settleForWindowClose(
            document: doc,
            settle: { (try? EditorFileStore.write(doc)).map { doc.markSaved(stamp: $0) } != nil },
            reload: { _ in reloads += 1 })
        #expect(saved)
        #expect(reloads == 0)
        #expect(doc.text == "hello\ntyped\n")
    }

    /// The last tab's ⌘W hands the window-close settle the app's own reload.
    @Test func theLastTabsCloseReloadsOnADiscard() throws {
        let tabs = try macAppCode("ContentView+PaneTabs.swift")
        let call = try CallArguments(of: "EditorDocumentClose.settleForWindowClose(", in: normalizedCode(tabs))
        // The PDF outlives the window, so the last tab's close does not ask about its pending work.
        #expect(call.passes("settle", "{ settleEditorDocument(asksAboutPDFWork: false, asksAboutTheOnlyCopy: false) }"))
        #expect(call.passes("reload", "{ reloadOverTheBuffer(path: $0) }"),
                "a discard before the window closes no longer reloads the file")
        #expect(!CodeText(tabs).contains("guard settleEditorDocument() else"),
                "the last tab's close settles without the reload again")
    }
}
