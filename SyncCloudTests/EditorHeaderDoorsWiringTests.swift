import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The app side of the header's ＋ and ×, and of File ▸ Close Document: what `ContentView` actually
/// hands the buttons and the menu item.
///
/// `EditorHeaderDoorsTests` builds the view with closures of its own, so it can't see what the app
/// passes: replacing the real closure with `{}` would leave that suite green. `ContentView` can't
/// be built in a test (its memberwise initializer is private; see `BrowseWorkspaceCallSiteTests`),
/// so the call site is scanned, with comments stripped and a positive control.
@Suite struct EditorHeaderDoorsWiringTests {

    /// The ＋ is handed ⌘N's own closure, not a copy of its body, and not a closure that only sets
    /// `editorIsNaming`, which would open the row without taking focus. Fails with `{
    /// editorIsNaming = true }`, `nil`, or `{}` in its place.
    @Test func theHeaderPlusIsHandedTheNewFileChordItself() throws {
        let body = try memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat", inFile: "ContentView+Editor.swift")
        #expect(try call("EditorWorkspaceView(", in: body).passes("onNewTextFile", "shortcutNewTextFile"),
                "the header's ＋ is not handed ⌘N's closure — it can drift from what the chord does")
    }

    /// What that closure does, so "the same as ⌘N" means something: it opens the naming row and
    /// bumps the focus counter, so a ＋ pressed with the row already open still takes focus. Always
    /// offered: with no folder the file goes to Notes (`EditorNewFileFolderTests`), so there is no
    /// `nil` to grey the ＋ on.
    @Test func theNewFileChordOpensTheRowAndTakesFocus() throws {
        let body = try memberBody("var shortcutNewTextFile: () -> Void", inFile: "ContentView+Editor.swift")
        #expect(body.contains("editorIsNaming = true"), "⌘N no longer opens the naming row")
        #expect(body.contains("editorNamingFocus &+= 1"), "⌘N no longer bumps the focus counter")
        #expect(!body.contains("return nil"), "⌘N is withheld again — a pane with no folder has Notes to go to")
    }

    /// Every Edit layout mounts the same workspace builder, so the ＋ is in the header whether the
    /// pane is open, the rail is drawn, or "Just the text" is on. `editorLayout` calls
    /// `editorWorkspace(showsRail:)` once, in the row both states share: a second call would give
    /// the workspace a second identity for a fold to rebuild, and a second route to
    /// `EditorWorkspaceView` could forget the ＋.
    @Test func everyEditLayoutMountsTheOneBuilder() throws {
        let source = try macAppCode("ContentView+Editor.swift")
        let layout = try memberBody("func editorLayout(collapsed: Bool, geo: GeometryProxy)", in: source)
        #expect(layout.count(of: "editorWorkspace(showsRail:") == 1,
                "editorLayout mounts the workspace other than once, through the one builder")
        #expect(argumentLists(of: "EditorWorkspaceView(", in: source).count == 1,
                "a second EditorWorkspaceView construction site appeared in ContentView+Editor")
    }

    // MARK: The × and File ▸ Close Document (TE46)

    /// The × and the menu item reach the same close, and the menu's is gated on the close's own
    /// rule. Fails with `onCloseDocument: {}`, or `shortcutCloseDocument` returning `{}` or asking
    /// `EditorVerbs.isOffered` instead.
    @Test func bothDoorsReachTheOneClose() throws {
        let source = try macAppCode("ContentView+Editor.swift")
        let workspace = try memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat", in: source)
        #expect(try call("EditorWorkspaceView(", in: workspace).passes("onCloseDocument", "{ closeEditorDocument() }"),
                "the header's × is not wired to closeEditorDocument")
        let menu = try memberBody("var shortcutCloseDocument: (() -> Void)?", in: source)
        #expect(menu.contains("EditorDocumentClose.isOffered("), "Close Document is offered without the close's rule")
        #expect(menu.contains("return { closeEditorDocument() }"), "File ▸ Close Document does not run closeEditorDocument")
        let publisher = try macAppCode("ShortcutCommands.swift")
        #expect(try CallArguments(of: "ShortcutValuePublisher(", in: publisher)
                    .passes("closeDocument", "shortcutCloseDocument"),
                "the chord publisher is not handed shortcutCloseDocument")
    }

    /// The close is handed the window's real pieces. `EditorDocumentCloseTests` runs the act with
    /// pieces of its own, which proves nothing about these: the settle must be
    /// `settleEditorDocument()` (the one place the unsaved-changes question is asked), the
    /// selection the left pane's (the pane a click opens from), and the log the app's. Fails with
    /// `settle: { true }`, `selectedRightPaths`, or `log: { _ in }`.
    @Test func theCloseIsHandedTheWindowsRealSettleSelectionAndLog() throws {
        let body = try memberBody("func closeEditorDocument()", inFile: "ContentView+Editor.swift")
        let close = try call("EditorDocumentClose.run(", in: body)
        #expect(close.passes("undoStore", "editorUndoStore"), "the close puts the undo stack away in the wrong store")
        #expect(close.passes("settle", "{ settleEditorDocument() }"), "the close does not settle the buffer first")
        #expect(close.passes("paneSelection", "{ syncManager.selectedLeftPaths }"),
                "the close reads a selection other than the left pane's")
        #expect(close.passes("setPaneSelection", "{ syncManager.selectedLeftPaths = $0 }"),
                "the close writes a selection other than the left pane's — clicking the row will not reopen it")
        #expect(close.passes("log", "{ Logger.shared.info($0) }"), "the close no longer logs")
    }

    /// A close moves nothing but the document: not the workspace, the pane's folder, the pane's
    /// collapse, or "Just the text". Named rather than inferred, so the list is the claim. Fails if
    /// the body gains `selectedWorkspace = .browse`.
    @Test func theCloseMovesNothingButTheDocument() throws {
        let body = try memberBody("func closeEditorDocument()", inFile: "ContentView+Editor.swift")
        for forbidden in ["selectedWorkspace", "focusPaneOnFolder", "editorRailHidden",
                          "togglePanesForCurrentTab", "toggleJustTheText", "focusOn("] {
            #expect(!body.contains(forbidden), "closeEditorDocument touches \(forbidden)")
        }
        let act = try macAppCode("EditorDocumentClose.swift")
        for forbidden in ["selectedWorkspace", "focusOn(", "editorRailHidden"] {
            #expect(!act.contains(forbidden), "EditorDocumentClose touches \(forbidden)")
        }
    }

    /// The menu item has no key, and greys on `nil`. Sliced to the command's own type body, so a
    /// neighbour's `.keyboardShortcut` can't satisfy or trip it. The drawn half (where it sits, and
    /// that no key reached AppKit) is `theFileMenuIsInTheRoadmapsOrder`.
    @Test func closeDocumentHasNoKeyAndGreysWithNothingToClose() throws {
        let body = try memberBody("struct CloseDocumentCommand: View {", in: try macAppCode("ShortcutCommands.swift"))
        #expect(body.contains("Button(\"Close Document\") { close?() }"), "the item's title or act changed")
        #expect(body.contains(".disabled(close == nil)"), "Close Document no longer greys with nothing to close")
        #expect(!body.contains("keyboardShortcut"), "Close Document has acquired a key — ⌘W is Close Tab's, ⌥ is forbidden")
        // The group's own braces, not the first `}` after its opening, which a closure or an `if`
        // in the group would end early.
        let groupBody = try memberBody("CommandGroup(replacing: .saveItem) {", in: try macAppCode("SyncCloudApp.swift"))
        let close = try #require(groupBody.range(of: "CloseDocumentCommand()"), "Close Document is not in the .saveItem group")
        let save = try #require(groupBody.range(of: "SaveDocumentCommand()"))
        #expect(close.lowerBound < save.lowerBound, "Close Document is declared after Save")
    }

    // MARK: Expand (TE48)

    /// The two hand-made doors out of Expand reach its record. Opening Edit's pane from its spine
    /// ends Expand and spends what it owed; ⌃⌘S from the toolbar or View ▸ Sidebar lifts Expand's
    /// hold on the sidebar rather than flipping a preference that is already on, and both doors
    /// tick on what is drawn. Fails if the `paneOpenedByHand` or `sidebarShownByHand` call is
    /// dropped, or either door is handed `browseSidebarVisible`.
    @Test func theHandMadeDoorsOutOfExpandReachItsRecord() throws {
        let toggle = try memberBody("func togglePanesForCurrentTab()", in: try macAppCode("ContentView.swift"))
        // The stored fold, not the drawn one: the pin's fold is released first and never reaches Expand.
        #expect(toggle.contains("if selectedWorkspace == .editor && panesStoredHiddenForCurrentTab {"),
                "opening Edit's pane by hand is not told apart from the other toggles")
        #expect(toggle.contains("expand.paneOpenedByHand()"),
                "opening the pane by hand leaves Expand owing a pane and a sidebar")
        let sidebar = try macAppCode("ContentView+FolderSidebar.swift")
        let set = try memberBody("func setFolderSidebarVisible(_ visible: Bool)", in: sidebar)
        #expect(set.contains("if visible && folderSidebarHeldByExpand {") && set.contains("expand.sidebarShownByHand()"),
                "⌃⌘S under Expand flips the preference and nothing appears")
        let toolbar = try macAppCode("ContentView+Toolbar.swift")
        #expect(toolbar.contains("setFolderSidebarVisible(!showing)"), "the toolbar's Sidebar button bypasses the hold")
        #expect(toolbar.contains("let showing = folderSidebarIsShowing"), "the toolbar's button lights on the preference")
        #expect(!toolbar.contains("browseSidebarVisible.toggle()"))
        let menu = try memberBody("var shortcutFolderSidebar: Binding<Bool>?", in: try macAppCode("ShortcutCommands.swift"))
        #expect(menu.contains("Binding(get: { folderSidebarIsShowing }, set: { setFolderSidebarVisible($0) })"),
                "View ▸ Sidebar ticks on, or writes, something other than what is drawn")
    }

    /// The header's Expand button and Text ▸ Expand run the one toggle, offered by the one rule.
    /// The button is handed `toggleJustTheText` (the internal name it kept), the menu's value runs
    /// the same, and the value is gated on `EditorExpandSwitch.isOffered` with the window's
    /// workspace, document and bit. Fails if the button is handed `{}`, the item flips
    /// `editorRailHidden` directly (skipping the pane's collapse), or the gate is dropped.
    @Test func expandAndTextExpandRunTheOneToggleByTheOneRule() throws {
        let source = try macAppCode("ContentView+Editor.swift")
        let workspace = try memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat", in: source)
        #expect(try call("EditorWorkspaceView(", in: workspace).passes("onToggleJustTheText", "{ toggleJustTheText() }"),
                "the header's Expand is not handed toggleJustTheText")
        #expect(try call("EditorWorkspaceView(", in: workspace).passes("railIsHidden", "editorIsExpanded"),
                "the header's Expand does not light on what the toggle decides by")
        // Text ▸ Go to Line…'s counter reaches the workspace that opens the field.
        #expect(try call("EditorWorkspaceView(", in: workspace).passes("goToLineRequest", "editorGoToLineRequest"),
                "Text ▸ Go to Line… bumps a counter the workspace is never handed")
        // "On" is the bit and the pane folded: a bit stored by an older build can sit beside an
        // open pane, and must not light Files there.
        let expanded = try memberBody("var editorIsExpanded: Bool", in: source)
        #expect(expanded.contains("editorRailHidden && panesHiddenForCurrentTab"),
                "Expand reads as on without the pane being folded — lit Files beside an open pane")
        let item = try memberBody("var shortcutEditorExpand: EditorExpandSwitch?", in: source)
        #expect(item.contains("EditorExpandSwitch.isOffered("), "Text ▸ Expand is offered without the button's rule")
        #expect(item.contains("workspace: selectedWorkspace"), "Text ▸ Expand is not gated on the workspace")
        #expect(item.contains("hasDocument: editorOpenPath != nil"), "Text ▸ Expand does not ask whether a document — text or PDF — is open")
        #expect(item.contains("isOn: editorIsExpanded"), "Text ▸ Expand ticks on something other than the button's lit state")
        #expect(item.contains("{ toggleJustTheText() }"), "Text ▸ Expand does not run the button's toggle")
        #expect(!item.contains("editorRailHidden ="), "Text ▸ Expand flips the bit itself, skipping the pane's collapse")
        let publisher = try macAppCode("ShortcutCommands.swift")
        #expect(try CallArguments(of: "ShortcutValuePublisher(", in: publisher)
                    .passes("editorExpand", "shortcutEditorExpand"),
                "the chord publisher is not handed shortcutEditorExpand")
        // Decided by the lit state, and logged both ways: three doors reach the toggle and none
        // leaves a trace on screen.
        let toggle = try memberBody("func toggleJustTheText()", in: source)
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
        // The spine's list buttons are doors of their own: the list back, the pane left folded,
        // through `EditorExpand` when Expand had it, and logged. The toggle's way out would reopen
        // a pane Expand folded, and an open pane draws no list.
        let spine = try macAppCode("ContentView+SplitLayout.swift")
        #expect(spine.contains("Button { runEditorRailRung(tab) } label: {"),
                "the spine's list buttons do not run runEditorRailRung")
        // The strip reads the tab as drawn: a remembered Pages is drawn as Files while a note is
        // open, and a strip reading the stored tab would light no button then.
        #expect(spine.contains("rungIsLit(tab, railDrawn: drawn, currentTab: editorRailShownTab)")
                    && spine.contains("rungTitle(tab, railDrawn: drawn, currentTab: editorRailShownTab)"),
                "the strip lights or names its buttons by the stored tab, not the drawn one")
        #expect(spine.contains("Self.spineRungs(workspace: selectedWorkspace, pdfIsOpen: editorPDF.path != nil,")
                    && spine.contains("pdfHasOutline: editorPDFHasOutline,")
                    && spine.contains("markdownIsOpen: EditorWorkspaceView.markdownIsOpen(editorDocument))"),
                "the strip is not told a PDF is open, whether it has a contents, or whether a note is — its buttons and the rail's tabs disagree")
        #expect(try memberBody("func runEditorRailRung(_ tab: EditorRailTab)", in: source)
                    .contains("currentTab: editorRailShownTab"),
                "a strip click decides by the stored tab, not the drawn one")
        #expect(!spine.contains("Button { toggleJustTheText() } label: {"),
                "the spine's rung runs the header's toggle, which reopens a pane Expand folded")
        #expect(!spine.contains("editorRailHidden = false") && !spine.contains("editorRailFolded ="),
                "the spine writes a rail bit directly")
        let rung = try memberBody("func showEditorRail(tab: EditorRailTab, from door: EditorRailDoor)", in: source)
        #expect(rung.contains("expand.textFilesShown()"), "the rung moves the bits itself rather than through EditorExpand")
        #expect(rung.contains(#"Logger.shared.info("[edit] Expand off from \(door.rawValue) — ""#), "ending Expand from the strip is not logged")
        #expect(rung.contains(#"Logger.shared.info("[edit] Files list shown from \(door.rawValue)")"#), "showing the list is not logged")
        let fold = try memberBody("func foldEditorRail(from door: EditorRailDoor)", in: source)
        #expect(fold.contains("editorRailFolded = true") && !fold.contains("editorRailHidden"),
                "the hand fold writes Expand's bit — folding would light Files")
        #expect(fold.contains(#"Logger.shared.info("[edit] Files list folded from \(door.rawValue)")"#), "folding is not logged")
        // The strip is the one place the columns open and fold from: the list is handed no fold
        // button of its own, and the strip's cloud runs the pane's rule.
        #expect(try call("EditorWorkspaceView(", in: workspace).value("onFoldRail") == nil,
                "the list draws its own fold button again — a second control beside the strip's")
        #expect(spine.contains("Button { runEditorPaneRung() } label: {"), "the strip's cloud does not run runEditorPaneRung")
        let paneRung = try memberBody("func runEditorPaneRung()", in: source)
        #expect(paneRung.contains("if !editorRailFolded { editorRailFolded = true }"),
                "opening the pane does not take the list's place — folding it again would bring back a list nobody asked for")
        #expect(paneRung.contains("togglePanesForCurrentTab()"), "the cloud moves the pane some way other than the one toggle")
        #expect(rung.contains("if !editorPaneIsFolded {") && rung.contains("expand.paneFolded = true"),
                "a list button beside an open pane does not fold the pane for the list")
        #expect(try call("EditorWorkspaceView(", in: workspace)
                    .passes("onShowTextFiles", "(panesHiddenForCurrentTab && !showsRail) ? { showEditorRail(tab: .files, from: .emptyPage) } : nil"),
                "the empty page's Show Text Files is not handed showEditorRail, or is offered beside an open pane")
        #expect(try CallArguments(of: "ShortcutValuePublisher(", in: publisher)
                    .passes("editorTextFiles", "shortcutEditorTextFiles"),
                "the chord publisher is not handed shortcutEditorTextFiles")
        let menuItem = try memberBody("var shortcutEditorTextFiles: Binding<Bool>?", in: source)
        #expect(menuItem.contains("guard selectedWorkspace == .editor else { return nil }"),
                "View ▸ Files is offered outside Edit, or withheld beside an open pane it can now fold")
        #expect(menuItem.contains("get: { editorRailIsDrawn }"), "View ▸ Text Files ticks on something other than the list as drawn")
        #expect(try macAppCode("ShortcutCommands.swift").contains(#"Toggle("File List", isOn: textFiles ?? .constant(false))"#),
                "View ▸ File List is titled otherwise — \"Files\" is Expand's button, which does more")
        let app = try macAppCode("SyncCloudApp.swift")
        #expect(app.contains("ColumnCommands()"), "View ▸ Text Files is not in the View menu")
        #expect(!rung.contains("expand.leave()"), "the rung leaves Expand the header's way, reopening the pane")
    }

    /// Offered where the header draws the button: in Edit, over any open document (a refused one
    /// too, whose header still draws it), and on the empty page only while lit, as the way back to
    /// the files. Never outside Edit. Without `isOn` the lit empty page loses its way back; without
    /// the workspace Browse gains a ⌃⌘E.
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

    /// `loadIntoEditor` runs the shared load, and is handed the window's real pieces.
    ///
    /// `EditorDocumentLoadTests` runs `EditorDocumentLoad.run` with a document and store of its
    /// own, so it can't see what the app passes. A fresh `EditorUndoStore()` here would leave that
    /// suite green while every file switch silently lost its undo history.
    @Test func theLoadIsHandedTheWindowsRealDocumentAndUndoStore() throws {
        let body = try memberBody("func loadIntoEditor(path: String, recordsRecent: Bool = true)", inFile: "ContentView+Editor.swift")
        // Through `EditorOpenRoute`, which sends a PDF to its own model and text to the shared load.
        let args = try call("EditorOpenRoute.load(", in: body)
        #expect(args.passes("path", "path"), "the load is handed a path other than the one asked for")
        #expect(args.passes("document", "editorDocument"),
                "the load is handed a document other than the window's")
        #expect(args.passes("undoStore", "editorUndoStore"),
                "the load is handed an undo store other than the window's — undo would not survive a switch")
        #expect(args.passes("pdf", "editorPDF"), "the load is handed a PDF model other than the window's")
        // …and the route's text arm runs the shared load with exactly what it was handed.
        let route = try memberBody("static func load(path: String", inFile: "EditorOpenRoute.swift")
        let text = try call("EditorDocumentLoad.run(", in: route)
        #expect(text.passes("path", "path") && text.passes("document", "document") && text.passes("undoStore", "undoStore"),
                "the route's text arm does not run the shared load with the window's pieces")
    }

    /// The load is the only thing `loadIntoEditor` does to the stacks. A `remember` or `activate`
    /// here would be a second, unordered copy of the sequence `EditorDocumentLoad` owns.
    @Test func loadIntoEditorTouchesTheUndoStoreOnlyThroughTheSharedLoad() throws {
        let body = try memberBody("func loadIntoEditor(path: String, recordsRecent: Bool = true)", inFile: "ContentView+Editor.swift")
        for forbidden in ["editorUndoStore.remember", "editorUndoStore.activate",
                          "editorUndoStore.forgetMissingFiles", "EditorFileStore.load("] {
            #expect(!body.contains(forbidden),
                    "loadIntoEditor still does \(forbidden) itself, beside the shared load")
        }
    }

    // MARK: Source helpers
}
