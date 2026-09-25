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
        #expect(body.contains("onNewTextFile: shortcutNewTextFile,") || body.contains("onNewTextFile: shortcutNewTextFile)"),
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
        #expect(layout.components(separatedBy: "editorWorkspace(showsRail:").count - 1 == 2,
                "editorLayout no longer mounts the workspace through the one builder in both arms")
        #expect(source.components(separatedBy: "EditorWorkspaceView(").count - 1 == 1,
                "a second EditorWorkspaceView construction site appeared in ContentView+Editor")
    }

    // MARK: The × and File ▸ Close Document (TE46)

    /// **The × and the menu item reach the same close**, and the menu's is gated on the close's
    /// own rule. Mutations: `onCloseDocument: {}`, or `shortcutCloseDocument` returning `{}` or
    /// asking `EditorVerbs.isOffered` instead, each fail one line.
    @Test func bothDoorsReachTheOneClose() throws {
        let source = try Self.editor()
        let workspace = try Self.memberBody("func editorWorkspace(showsRail: Bool)", in: source)
        #expect(workspace.contains("onCloseDocument: { closeEditorDocument() }"),
                "the header's × is not wired to closeEditorDocument")
        let menu = try Self.memberBody("var shortcutCloseDocument: (() -> Void)?", in: source)
        #expect(menu.contains("EditorDocumentClose.isOffered("), "Close Document is offered without the close's rule")
        #expect(menu.contains("return { closeEditorDocument() }"), "File ▸ Close Document does not run closeEditorDocument")
        let publisher = try Self.source("ShortcutCommands.swift")
        #expect(publisher.contains("closeDocument: shortcutCloseDocument,"),
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
        #expect(body.contains("undoStore: editorUndoStore"), "the close puts the undo stack away in the wrong store")
        #expect(body.contains("settle: { settleEditorDocument() }"), "the close does not settle the buffer first")
        #expect(body.contains("paneSelection: { syncManager.selectedLeftPaths }"),
                "the close reads a selection other than the left pane's")
        #expect(body.contains("setPaneSelection: { syncManager.selectedLeftPaths = $0 }"),
                "the close writes a selection other than the left pane's — clicking the row will not reopen it")
        #expect(body.contains("log: { Logger.shared.info($0) }"), "the close no longer logs")
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
        let source = try Self.source("ShortcutCommands.swift")
        let start = try #require(source.range(of: "struct CloseDocumentCommand: View {"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}"))
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("Button(\"Close Document\") { close?() }"), "the item's title or act changed")
        #expect(body.contains(".disabled(close == nil)"), "Close Document no longer greys with nothing to close")
        #expect(!body.contains("keyboardShortcut"), "Close Document has acquired a key — ⌘W is Close Tab's, ⌥ is forbidden")
        let app = try Self.source("SyncCloudApp.swift")
        let group = try #require(app.range(of: "CommandGroup(replacing: .saveItem) {"))
        let groupEnd = try #require(app.range(of: "}", range: group.upperBound..<app.endIndex))
        let groupBody = app[group.upperBound..<groupEnd.lowerBound]
        let close = try #require(groupBody.range(of: "CloseDocumentCommand()"), "Close Document is not in the .saveItem group")
        let save = try #require(groupBody.range(of: "SaveDocumentCommand()"))
        #expect(close.lowerBound < save.lowerBound, "Close Document is declared after Save")
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
    /// scan for it.
    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8), "cannot read \(name)")
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// One member's body: its declaration to the first closing brace at member indentation.
    static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration), "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }
}
