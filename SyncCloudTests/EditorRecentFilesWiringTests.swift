import Testing
import AppKit
import FileExplorer
@testable import SyncCloud

/// **The app side of Edit's recent files (TE58)**: where opens are recorded, the moved file
/// followed, and what the empty page and File ▸ Open Recent are handed.
///
/// `ContentView` cannot be built in a test, so its call sites are scanned with comments stripped
/// (`EditorHeaderDoorsWiringTests`' helpers). The rules themselves run for real in
/// `EditorOpenRouteTests` (what a load records) and FileExplorer's `EditorRecentFilesTests` (the
/// store and the page); the menu is read off the running app.
@MainActor
@Suite struct EditorRecentFilesWiringTests {

    /// **Every way into Edit records through the one load** — after it, and only where the caller
    /// asks. Mutations: drop the `if recordsRecent` guard, record before `EditorOpenRoute.load(`, or
    /// hand `recordOpen` a store other than the shared one — each fails a line.
    @Test func theOneLoadRecordsWhatItOpened() throws {
        let body = try EditorHeaderDoorsWiringTests.memberBody("func loadIntoEditor(path: String, recordsRecent: Bool = true)",
                                                              in: EditorHeaderDoorsWiringTests.editor())
        let load = try #require(body.range(of: "EditorOpenRoute.load(path: path,"), "the load no longer routes through EditorOpenRoute")
        let guarded = try #require(body.range(of: "if recordsRecent {"), "the record is not gated on recordsRecent")
        let record = try #require(body.range(of: "EditorOpenRoute.recordOpen(kind: kind, document: editorDocument, pdf: editorPDF,"),
                                  "the load records nothing")
        // `<=`: the normalized code drops the space after `{`, so the guard can end where the call begins.
        #expect(load.upperBound <= guarded.lowerBound && guarded.upperBound <= record.lowerBound,
                "the open is recorded before the load, or outside the guard")
        #expect(body.contains("in: EditorRecentFiles.shared)"), "the open is recorded in a store the page does not read")
    }

    /// **A reload is no new open**: `reloadOverTheBuffer` says so, and so does Try Again under a
    /// refusal (TE152), which reads the file already open once more — and no other caller.
    /// Mutation: drop `recordsRecent: false`, or add it to `createTextFile`.
    @Test func onlyTheReloadSkipsTheRecord() throws {
        let source = try EditorHeaderDoorsWiringTests.editor()
        let reload = try EditorHeaderDoorsWiringTests.memberBody("func reloadOverTheBuffer(path: String) -> Bool", in: source)
        #expect(reload.contains("loadIntoEditor(path: path, recordsRecent: false)"),
                "a reload over the buffer moves the file to the top of the recent files")
        #expect(source.contains("onTryAgain: { if let path = editorDocument.path, editorDocument.refusal != nil { loadIntoEditor(path: path, recordsRecent: false) } },"),
                "Try Again moves the file it re-reads to the top of the recent files")
        #expect(source.components(separatedBy: "recordsRecent: false").count - 1 == 2,
                "a third route skips the recent files")
    }

    /// **The moved file is followed, by this app or by Finder** — before the `byThisApp` return,
    /// which would otherwise skip the app's own renames.
    @Test func aMovedOpenFileIsFollowed() throws {
        let body = try EditorHeaderDoorsWiringTests.memberBody(
            "func editorDocumentDidMove(from old: String, to new: String, byThisApp: Bool)",
            in: EditorHeaderDoorsWiringTests.editor())
        let move = try #require(body.range(of: "EditorRecentFiles.shared.move(from: old, to: new)"),
                                "the recent files do not follow a moved file")
        let early = try #require(body.range(of: "guard !byThisApp else { return }"))
        #expect(move.upperBound < early.lowerBound, "a rename by this app is not followed")
    }

    /// **The page and the menu open through the hand-off**, so the pane follows the file — the
    /// page handed the shared store, and New Text File ⌘N's closure (`theHeaderPlusIsHandedTheNewFileChordItself`).
    @Test func thePageAndTheMenuOpenThroughTheHandOff() throws {
        let workspace = try EditorHeaderDoorsWiringTests.memberBody("func editorWorkspace(showsRail: Bool, railWidth: CGFloat",
                                                                   in: EditorHeaderDoorsWiringTests.editor())
        let call = try EditorHeaderDoorsWiringTests.call("EditorWorkspaceView(", in: workspace)
        #expect(call.passes("recentFiles", "EditorRecentFiles.shared"), "the empty page reads a store nothing records in")
        #expect(call.passes("onOpenRecent", "{ path in handOffToEditor(path) }"), "a recent row does not open through the hand-off")
        let publisher = try EditorHeaderDoorsWiringTests.memberBody("var shortcutValuePublisher: ShortcutValuePublisher",
                                                                   in: EditorHeaderDoorsWiringTests.source("ShortcutCommands.swift"))
        #expect(try EditorHeaderDoorsWiringTests.call("ShortcutValuePublisher(", in: publisher)
                    .passes("openRecent", "{ path in handOffToEditor(path) }"),
                "File ▸ Open Recent does not open through the hand-off")
    }

    /// **File ▸ Open Recent, read off the running app**: a submenu under New Text File, ending in
    /// Clear Menu, with no chord anywhere in it. Read only — the test host's store is his.
    @Test func openRecentIsASubmenuEndingInClearMenu() throws {
        let file = try #require(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu,
                                "the app has no File menu — this check would be vacuous")
        let item = try #require(file.items.first { $0.title == "Open Recent" }, "File ▸ Open Recent is gone")
        let submenu = try #require(item.submenu, "Open Recent is an item, not a submenu")
        #expect(submenu.items.last?.title == "Clear Menu", "Open Recent does not end in Clear Menu")
        #expect(submenu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "an Open Recent item has acquired a chord")
        let index = try #require(file.items.firstIndex(of: item))
        #expect(index > 0 && file.items[index - 1].title == "New Text File…", "Open Recent is not under New Text File")
    }
}
