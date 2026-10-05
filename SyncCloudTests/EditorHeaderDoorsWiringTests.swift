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
    /// **Offered always** — with no folder the file goes to Notes (`EditorNewFileFolderTests`), so
    /// there is no `nil` left to grey the ＋ on.
    @Test func theNewFileChordOpensTheRowAndTakesFocus() throws {
        let body = try Self.memberBody("var shortcutNewTextFile: () -> Void", in: Self.editor())
        #expect(body.contains("editorIsNaming = true"), "⌘N no longer opens the naming row")
        #expect(body.contains("editorNamingFocus &+= 1"), "⌘N no longer bumps the focus counter")
        #expect(!body.contains("return nil"), "⌘N is withheld again — a pane with no folder has Notes to go to")
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

    // MARK: Expand (TE48)

    /// **The header's Expand button and Text ▸ Expand run the one toggle, and are offered by the one
    /// rule.** The button is handed `toggleJustTheText` (the internal name it kept), the menu's value
    /// runs the same, and the value is gated on `EditorExpandSwitch.isOffered` with the window's
    /// workspace, document and bit. Mutations: hand the button `{}`, have the item flip
    /// `editorRailHidden` directly (skipping the pane's collapse), or drop the gate — each fails a line.
    /// **The two hand-made doors out of Expand reach its record** (2026-10-04). Opening Edit's
    /// pane from its spine ends Expand and spends what it owed; ⌃⌘S from the toolbar or View ▸
    /// Sidebar lifts Expand's hold on the sidebar rather than flipping a preference that is
    /// already on, and both doors tick on what is drawn. Mutations: drop the `paneOpenedByHand`
    /// call, drop `sidebarShownByHand`, or hand either door `browseSidebarVisible` back — each
    /// fails a line.
    @Test func theHandMadeDoorsOutOfExpandReachItsRecord() throws {
        let toggle = try Self.memberBody("func togglePanesForCurrentTab()", in: try Self.source("ContentView.swift"))
        #expect(toggle.contains("if selectedWorkspace == .editor && panesHiddenForCurrentTab {"),
                "opening Edit's pane by hand is not told apart from the other toggles")
        #expect(toggle.contains("expand.paneOpenedByHand()"),
                "opening the pane by hand leaves Expand owing a pane and a sidebar")
        let sidebar = try Self.source("ContentView+FolderSidebar.swift")
        let set = try Self.memberBody("func setFolderSidebarVisible(_ visible: Bool)", in: sidebar)
        #expect(set.contains("if visible && folderSidebarHeldByExpand {") && set.contains("expand.sidebarShownByHand()"),
                "⌃⌘S under Expand flips the preference and nothing appears")
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.contains("setFolderSidebarVisible(!showing)"), "the toolbar's Sidebar button bypasses the hold")
        #expect(toolbar.contains("let showing = folderSidebarIsShowing"), "the toolbar's button lights on the preference")
        #expect(!toolbar.contains("browseSidebarVisible.toggle()"))
        let menu = try Self.memberBody("var shortcutFolderSidebar: Binding<Bool>?", in: try Self.source("ShortcutCommands.swift"))
        #expect(menu.contains("Binding(get: { folderSidebarIsShowing }, set: { setFolderSidebarVisible($0) })"),
                "View ▸ Sidebar ticks on, or writes, something other than what is drawn")
    }

    @Test func expandAndTextExpandRunTheOneToggleByTheOneRule() throws {
        let source = try Self.editor()
        let workspace = try Self.memberBody("func editorWorkspace(showsRail: Bool)", in: source)
        #expect(try Self.call("EditorWorkspaceView(", in: workspace).passes("onToggleJustTheText", "{ toggleJustTheText() }"),
                "the header's Expand is not handed toggleJustTheText")
        #expect(try Self.call("EditorWorkspaceView(", in: workspace).passes("railIsHidden", "editorIsExpanded"),
                "the header's Expand does not light on what the toggle decides by")
        // "On" is the bit AND the pane folded — the bit alone survives the pane being reopened.
        let expanded = try Self.memberBody("var editorIsExpanded: Bool", in: source)
        #expect(expanded.contains("editorRailHidden && panesHiddenForCurrentTab"),
                "Expand reads as on without the pane being folded — lit Files beside an open pane")
        let item = try Self.memberBody("var shortcutEditorExpand: EditorExpandSwitch?", in: source)
        #expect(item.contains("EditorExpandSwitch.isOffered("), "Text ▸ Expand is offered without the button's rule")
        #expect(item.contains("workspace: selectedWorkspace"), "Text ▸ Expand is not gated on the workspace")
        #expect(item.contains("hasDocument: editorDocument.path != nil"), "Text ▸ Expand does not ask whether a document is open")
        #expect(item.contains("isOn: editorIsExpanded"), "Text ▸ Expand ticks on something other than the button's lit state")
        #expect(item.contains("{ toggleJustTheText() }"), "Text ▸ Expand does not run the button's toggle")
        #expect(!item.contains("editorRailHidden ="), "Text ▸ Expand flips the bit itself, skipping the pane's collapse")
        let publisher = try Self.source("ShortcutCommands.swift")
        #expect(try CallArguments(of: "ShortcutValuePublisher(", in: publisher)
                    .passes("editorExpand", "shortcutEditorExpand"),
                "the chord publisher is not handed shortcutEditorExpand")
        // Decided by the lit state, and logged both ways: three doors reach the toggle and none
        // leaves a trace on screen.
        let toggle = try Self.memberBody("func toggleJustTheText()", in: source)
        #expect(toggle.contains("if editorIsExpanded {"), "the toggle decides by the bit alone")
        // Whole literals, quotes included: the needle is lexed like the code, so a bare sentence
        // would be read as code and never match the same words inside a string.
        #expect(toggle.contains(#"Logger.shared.info("[edit] Expand on — ""#),
                "turning Expand on is not logged")
        #expect(toggle.contains(#"Logger.shared.info("[edit] Expand off — " + EditorExpand.moved(from: before, to: expand) + " back")"#),
                "turning Expand off is not logged")
        // Both ways go through the one rule, so neither writes a bit of its own.
        #expect(toggle.contains("expand.leave()") && toggle.contains("expand.enter(sidebarShowing: folderSidebarIsShowing)"),
                "the toggle moves the bits itself rather than through EditorExpand")
        #expect(!toggle.contains("editorRailHidden ="), "the toggle flips the rail bit directly")
        // The spine's Text Files rung is the third door, and runs the same toggle — so it is logged.
        let spine = try Self.source("ContentView+SplitLayout.swift")
        #expect(spine.contains("Button { toggleJustTheText() } label: {"),
                "the spine's rung turns Expand off by itself, unlogged")
        #expect(!spine.contains("editorRailHidden = false"), "the spine still clears the bit directly")
    }

    /// **Offered where the header draws the button**: in Edit, over any open document — a refused
    /// one too, whose header still draws it — and on the empty page only while it is lit, the way
    /// back to the files. Never outside Edit. Mutation: drop `isOn` from the rule and the lit empty
    /// page loses its way back; drop the workspace and Browse gains a ⌃⌘E.
    @Test func textExpandIsOfferedWhereTheHeaderDrawsTheButton() {
        #expect(EditorExpandSwitch.isOffered(workspace: .editor, hasDocument: true, isOn: false))
        #expect(EditorExpandSwitch.isOffered(workspace: .editor, hasDocument: true, isOn: true))
        #expect(EditorExpandSwitch.isOffered(workspace: .editor, hasDocument: false, isOn: true),
                "the lit empty page has no Text ▸ Expand — the button and the spine's rung are its only doors")
        #expect(!EditorExpandSwitch.isOffered(workspace: .editor, hasDocument: false, isOn: false),
                "Text ▸ Expand is live on the empty page with the files showing, where the button is not drawn")
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(!EditorExpandSwitch.isOffered(workspace: workspace, hasDocument: true, isOn: true),
                    "Text ▸ Expand is live in \(workspace)")
        }
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
