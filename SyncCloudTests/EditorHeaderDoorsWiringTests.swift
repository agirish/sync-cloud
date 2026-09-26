import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The app side of the header's ＋ (TE45) and × (TE46), and of File ▸ Close Document: what
/// `ContentView` actually hands the buttons and the menu item.
///
/// **The lesson of the TE27–TE30 review, applied.** `EditorHeaderDoorsTests` builds the view with
/// closures of its own, so nothing there can see what the APP passes — replacing the real closure
/// with `{}` would leave that suite green. `ContentView` cannot be built in a test (its memberwise
/// initializer is private; see `BrowseWorkspaceCallSiteTests`), so the call site is scanned, with
/// comments stripped and a positive control.
@Suite struct EditorHeaderDoorsWiringTests {

    /// **The ＋ is handed ⌘N's own closure** — not a copy of its body, and not a closure that only
    /// sets `editorIsNaming`, which would open the row without taking focus. Mutations: `{
    /// editorIsNaming = true }`, `nil`, or `{}` in its place each fail.
    @Test func theHeaderPlusIsHandedTheNewFileChordItself() throws {
        let body = try Self.memberBody("func editorWorkspace(showsRail: Bool)", in: Self.editor())
        #expect(try Self.call("EditorWorkspaceView(", in: body).passes("onNewTextFile", "shortcutNewTextFile"),
                "the header's ＋ is not handed ⌘N's closure — it can drift from what the chord does")
    }

    /// What that closure does, so "the same as ⌘N" is a claim about something: it opens the naming
    /// row AND bumps the focus counter, so a ＋ pressed with the row already open still takes focus.
    @Test func theNewFileChordOpensTheRowAndTakesFocus() throws {
        let body = try Self.memberBody("var shortcutNewTextFile: (() -> Void)?", in: Self.editor())
        #expect(body.contains("editorIsNaming = true"), "⌘N no longer opens the naming row")
        #expect(body.contains("editorNamingFocus &+= 1"), "⌘N no longer bumps the focus counter")
        #expect(body.contains("guard !editorFolder.isEmpty else { return nil }"),
                "⌘N is offered with no folder — the ＋ would not grey")
    }

    /// **Every Edit layout mounts the same workspace builder**, so the ＋ is in the header whether
    /// the pane is open, the rail is drawn, or "Just the text" is on. Both arms of `editorLayout`
    /// call `editorWorkspace(showsRail:)`; a third route to `EditorWorkspaceView` would be one that
    /// could forget the ＋.
    @Test func everyEditLayoutMountsTheOneBuilder() throws {
        let source = try Self.editor()
        let layout = try Self.memberBody("func editorLayout(collapsed: Bool, geo: GeometryProxy)", in: source)
        #expect(layout.count(of: "editorWorkspace(showsRail:") == 2,
                "editorLayout no longer mounts the workspace through the one builder in both arms")
        #expect(argumentLists(of: "EditorWorkspaceView(", in: source).count == 1,
                "a second EditorWorkspaceView construction site appeared in ContentView+Editor")
    }

    // MARK: The × and File ▸ Close Document (TE46)

    /// **The × and the menu item reach the same close**, and the menu's is gated on the close's
    /// own rule. Mutations: `onCloseDocument: {}`, or `shortcutCloseDocument` returning `{}` or
    /// asking `EditorVerbs.isOffered` instead, each fail one line.
    @Test func bothDoorsReachTheOneClose() throws {
        let source = try Self.editor()
        let workspace = try Self.memberBody("func editorWorkspace(showsRail: Bool)", in: source)
        #expect(try Self.call("EditorWorkspaceView(", in: workspace).passes("onCloseDocument", "{ closeEditorDocument() }"),
                "the header's × is not wired to closeEditorDocument")
        let menu = try Self.memberBody("var shortcutCloseDocument: (() -> Void)?", in: source)
        #expect(menu.contains("EditorDocumentClose.isOffered("), "Close Document is offered without the close's rule")
        #expect(menu.contains("return { closeEditorDocument() }"), "File ▸ Close Document does not run closeEditorDocument")
        let publisher = try Self.source("ShortcutCommands.swift")
        #expect(try CallArguments(of: "ShortcutValuePublisher(", in: publisher)
                    .passes("closeDocument", "shortcutCloseDocument"),
                "the chord publisher is not handed shortcutCloseDocument")
    }

    /// **The close is handed the window's REAL pieces.** `EditorDocumentCloseTests` runs the act
    /// with pieces of its own, which proves nothing about these: the settle must be
    /// `settleEditorDocument()` (the one place the unsaved-changes question is asked), the selection
    /// the LEFT pane's (the pane TE41 opens from), and the log the app's. Mutations: `settle: {
    /// true }`, `selectedRightPaths`, or `log: { _ in }` each fail.
    @Test func theCloseIsHandedTheWindowsRealSettleSelectionAndLog() throws {
        let body = try Self.memberBody("func closeEditorDocument()", in: Self.editor())
        #expect(body.contains("EditorDocumentClose.run("), "closeEditorDocument no longer runs the shared close")
        let close = try Self.call("EditorDocumentClose.run(", in: body)
        #expect(close.passes("undoStore", "editorUndoStore"), "the close puts the undo stack away in the wrong store")
        #expect(close.passes("settle", "{ settleEditorDocument() }"), "the close does not settle the buffer first")
        #expect(close.passes("paneSelection", "{ syncManager.selectedLeftPaths }"),
                "the close reads a selection other than the left pane's")
        #expect(close.passes("setPaneSelection", "{ syncManager.selectedLeftPaths = $0 }"),
                "the close writes a selection other than the left pane's — clicking the row will not reopen it")
        #expect(close.passes("log", "{ Logger.shared.info($0) }"), "the close no longer logs")
    }

    /// **A close moves nothing but the document.** Not the workspace, not the pane's folder, not
    /// the pane's collapse, not "Just the text". Named rather than inferred, so the list is the
    /// claim. Mutation: add `selectedWorkspace = .browse` to the body and it fails.
    @Test func theCloseMovesNothingButTheDocument() throws {
        let body = try Self.memberBody("func closeEditorDocument()", in: Self.editor())
        for forbidden in ["selectedWorkspace", "focusPaneOnFolder", "editorRailHidden",
                          "togglePanesForCurrentTab", "toggleJustTheText", "focusOn("] {
            #expect(!body.contains(forbidden), "closeEditorDocument touches \(forbidden)")
        }
        let act = try Self.source("EditorDocumentClose.swift")
        for forbidden in ["selectedWorkspace", "focusOn(", "editorRailHidden"] {
            #expect(!act.contains(forbidden), "EditorDocumentClose touches \(forbidden)")
        }
    }

    /// **The menu item has no key, and greys on `nil`.** Sliced to the command's own type body, so
    /// a neighbour's `.keyboardShortcut` cannot satisfy or trip it. The drawn half — where it sits
    /// and that no key reached AppKit — is `theFileMenuIsInTheRoadmapsOrder`.
    @Test func closeDocumentHasNoKeyAndGreysWithNothingToClose() throws {
        let body = try Self.memberBody("struct CloseDocumentCommand: View {", in: try Self.source("ShortcutCommands.swift"))
        #expect(body.contains("Button(\"Close Document\") { close?() }"), "the item's title or act changed")
        #expect(body.contains(".disabled(close == nil)"), "Close Document no longer greys with nothing to close")
        #expect(!body.contains("keyboardShortcut"), "Close Document has acquired a key — ⌘W is Close Tab's, ⌥ is forbidden")
        // The group's own braces — it was read to the first `}` after its opening, which a closure
        // or an `if` added to the group would have ended early.
        let groupBody = try Self.memberBody("CommandGroup(replacing: .saveItem) {", in: try Self.source("SyncCloudApp.swift"))
        let close = try #require(groupBody.range(of: "CloseDocumentCommand()"), "Close Document is not in the .saveItem group")
        let save = try #require(groupBody.range(of: "SaveDocumentCommand()"))
        #expect(close.lowerBound < save.lowerBound, "Close Document is declared after Save")
    }

    // MARK: The load

    /// **`loadIntoEditor` runs the shared load, and is handed the window's real pieces.**
    ///
    /// `EditorDocumentLoadTests` runs `EditorDocumentLoad.run` with a document and store of its own,
    /// so nothing there can see what the APP passes — the whole lesson this suite was built on.
    /// Swapping in a fresh `EditorUndoStore()` here would leave that suite green while every file
    /// switch silently lost its undo history.
    @Test func theLoadIsHandedTheWindowsRealDocumentAndUndoStore() throws {
        let body = try Self.memberBody("func loadIntoEditor(path: String)", in: Self.editor())
        #expect(body.contains("EditorDocumentLoad.run("),
                "loadIntoEditor no longer runs the shared load — the ordering is untested again")
        let call = try Self.call("EditorDocumentLoad.run(", in: body)
        #expect(call.passes("path", "path"), "the load is handed a path other than the one asked for")
        #expect(call.passes("document", "editorDocument"),
                "the load is handed a document other than the window's")
        #expect(call.passes("undoStore", "editorUndoStore"),
                "the load is handed an undo store other than the window's — undo would not survive a switch")
    }

    /// **And the load is the ONLY thing `loadIntoEditor` does to the stacks.** A `remember` or
    /// `activate` left behind here would be a second, unordered copy of the sequence the extraction
    /// exists to own.
    @Test func loadIntoEditorTouchesTheUndoStoreOnlyThroughTheSharedLoad() throws {
        let body = try Self.memberBody("func loadIntoEditor(path: String)", in: Self.editor())
        for forbidden in ["editorUndoStore.remember", "editorUndoStore.activate",
                          "editorUndoStore.forgetMissingFiles", "EditorFileStore.load("] {
            #expect(!body.contains(forbidden),
                    "loadIntoEditor still does \(forbidden) itself, beside the shared load")
        }
    }

    /// The positive control: the scans are reading the real file.
    @Test func theScanCanActuallyFail() throws {
        let source = try Self.editor()
        #expect(source.contains("func settleEditorDocument()"), "not reading ContentView+Editor.swift")
        #expect(!source.contains("thisStringIsNotInTheFile"))
    }

    // MARK: Source helpers

    static func editor() throws -> String { try source("ContentView+Editor.swift") }

    /// A MacApp file with its comments removed, so prose describing the wiring cannot satisfy a
    /// scan for it — by the shared lexer (``sourceCodeOnly(_:)``), where this cut every line at its
    /// first `//`, string or not: a `"https://…"` literal lost its tail.
    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8), "cannot read \(name)")
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return sourceCodeOnly(text)
    }

    /// One member's body, to its own closing brace — ``declarationBody(of:in:sourceLocation:)``,
    /// asked whitespace-insensitively. It was the first `"\n    }"` after the declaration, and
    /// the whole rest of the file when there was none; the type-level slices below were the first
    /// `"\n}"` and the first `}`.
    static func memberBody(_ declaration: String, in source: String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws -> CodeText {
        CodeText(try declarationBody(of: declaration, in: source, sourceLocation: sourceLocation))
    }

    /// The call of `callee` inside `body`, read by label.
    static func call(_ callee: String, in body: CodeText,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> CallArguments {
        try CallArguments(of: callee, in: body.normalized, sourceLocation: sourceLocation)
    }
}
