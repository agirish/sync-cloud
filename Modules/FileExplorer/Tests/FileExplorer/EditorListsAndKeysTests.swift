import Testing
import Foundation
@testable import FileExplorer

/// Edit's lists and keys: Esc back to the document, Space for Quick Look, the list's fold words,
/// the header name's tooltip, the outline following the reader, Show Outline, the Split divider's
/// double-click, the image import's notice and the folder menu's Show All. Keys are read from the
/// source because a SwiftUI list's focus and keys can't be driven from `swift test` (see
/// `EditorRailListPolishTests.bothListsTakeTheKeys`).
@MainActor
@Suite struct EditorListsAndKeysTests {

    // MARK: TE154 — Esc back to the document

    /// Each list hands Esc on: the Files list and the outline to the rail's door, a PDF's bookmarks
    /// and its Pages grid straight to the pages. Dropping any one handler fails its line.
    @Test func escInEachListGoesBackToTheDocument() throws {
        let files = try SourceText.fileExplorer("EditorFileRailView.swift")
        #expect(Self.escape(in: files).contains("onReturnKeys()"), "Esc in the Files list does not hand the keys back")
        #expect(files.contains("onSelect: onSelectHeading, onEscape: onReturnKeys)"),
                "Esc in a note's outline does not hand the keys back")
        let outline = try SourceText.fileExplorer("EditorRailOutlineList.swift")
        #expect(Self.escape(in: outline).contains("onEscape()"), "the outline list does not take Esc")
        let pdf = try SourceText.fileExplorer("EditorPDFRailViews.swift")
        #expect(pdf.contains("onEscape: { view.requestFocus() })"), "Esc in a PDF's outline does not go to the pages")
        #expect(Self.escape(in: pdf).contains(
                    "if tools.selection.pages.isEmpty { view.requestFocus() } else { tools.clearSelection() }"),
                "Esc in the Pages grid does not clear first, then go to the pages")
    }

    /// What the first `.onKeyPress(.escape)` handler in `source` does — its next few lines.
    private static func escape(in source: String) -> Substring {
        guard let handler = source.range(of: ".onKeyPress(.escape) {") else { return "" }
        return source[handler.upperBound...].prefix(160)
    }

    /// The workspace's door: the PDF's pages, else the text view the caret was last in, else the
    /// window, where the undo anchor takes the keys in read-only Preview. Offered only with a
    /// document open; on the empty page Esc is left alone.
    @Test func theWorkspaceGivesTheKeysToWhatIsOpen() throws {
        let workspace = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        #expect(workspace.contains("onReturnKeys: railReturnKeys,"))
        #expect(workspace.contains("guard pdf != nil || document.path != nil else { return nil }"))
        let door = try #require(workspace.range(of: "private func returnKeysToDocument() {"))
        let body = workspace[door.upperBound...].prefix(400)
        #expect(body.contains("pdf.view.requestFocus()"))
        #expect(body.contains("textViewHandle.target, let window = text.window") && body.contains("window.makeFirstResponder(text)"))
        #expect(body.contains("NSApp.keyWindow?.makeFirstResponder(nil)"))
    }

    // MARK: TE155 — Space for Quick Look

    /// Space previews the cursor's row through the row menu's own Quick Look, the host's one panel,
    /// which closes when asked for the file it shows. A chord is left alone.
    @Test func spaceQuickLooksTheCursorsRow() throws {
        let files = try SourceText.fileExplorer("EditorFileRailView.swift")
        let space = try #require(files.range(of: ".onKeyPress(keys: [.space], phases: .down) { press in"),
                                 "Space is not handled in the Files list")
        let body = files[space.upperBound...].prefix(300)
        #expect(body.contains("guard press.isPlainKeystroke, let path = keyedPath ?? selectedPath"))
        #expect(body.contains("rowActions.quickLook(path)"))
    }

    // MARK: TE156 — the fold words

    /// One phrase for what hides the whole list, on the chevron as on the strip's lit button.
    @Test func theFoldChevronSaysItHidesTheList() {
        #expect(EditorFileRailView.foldTitle == "Hide the file list")
        #expect(EditorFileRailView.foldTitle == EditorRailTab.hideListTitle)
    }

    // MARK: TE157 — the header name's tooltip

    /// The whole name, then the menu behind it in its own order. Both headers carry it, each only
    /// where it has a menu (a path).
    @Test func theHeaderNameSaysWhatRightClickOffers() throws {
        #expect(EditorRailRowMenu.nameTooltip("Plan for the long weekend.md")
                == "“Plan for the long weekend.md” — right-click to reveal or rename")
        let order = ["Reveal in Browse", "Rename"].map { EditorRailRowMenuTests.five.firstIndex(of: $0) ?? -1 }
        #expect(order == order.sorted() && !order.contains(-1), "the tooltip's verbs are not in the menu's order")
        #expect(try SourceText.fileExplorer("EditorWorkspaceView.swift")
            .contains(".help(document.path == nil ? \"\" : EditorRailRowMenu.nameTooltip(document.name))"))
        #expect(try SourceText.fileExplorer("EditorPDFCard.swift")
            .contains(".help(pdf.path == nil ? \"\" : EditorRailRowMenu.nameTooltip(pdf.name))"))
    }

    // MARK: TE179 — the outline follows the reader

    private static func outline(_ count: Int) -> [MarkdownOutlineEntry] {
        (1...count).map { MarkdownOutlineEntry(line: $0 * 2, level: 2, depth: 1, title: "Heading \($0)") }
    }

    /// Only a row out of view is scrolled to; one on screen, or no current row, leaves the list
    /// alone. Always answering `current` fails the first line.
    @Test func theOutlineFollowsOnlyARowOutOfView() {
        let rows = Self.outline(30)
        // Top at row 0, ten rows showing: rows 0–9 are in view.
        #expect(EditorOutlineScroll.followTarget(current: rows[4].id, top: rows[0].id, outline: rows, rowsThatFit: 10) == nil)
        #expect(EditorOutlineScroll.followTarget(current: rows[9].id, top: nil, outline: rows, rowsThatFit: 10) == nil)
        #expect(EditorOutlineScroll.followTarget(current: rows[10].id, top: rows[0].id, outline: rows, rowsThatFit: 10) == rows[10].id)
        // Scrolled down: a row above the top is out of view too.
        #expect(EditorOutlineScroll.followTarget(current: rows[3].id, top: rows[20].id, outline: rows, rowsThatFit: 10) == rows[3].id)
        #expect(EditorOutlineScroll.followTarget(current: nil, top: rows[20].id, outline: rows, rowsThatFit: 10) == nil)
        #expect(EditorOutlineScroll.followTarget(current: 999, top: nil, outline: rows, rowsThatFit: 10) == nil,
                "a row the outline does not have moved the list")
    }

    /// The list asks the rule whenever the current row changes, and scrolls as the Pages tab does.
    @Test func theOutlineListAsksTheRuleAsTheReaderMoves() throws {
        let list = try SourceText.fileExplorer("EditorRailOutlineList.swift")
        let change = try #require(list.range(of: ".onChange(of: currentIndex) { _, _ in"))
        let body = list[change.upperBound...].prefix(500)
        #expect(body.contains("EditorOutlineScroll.followTarget(current: currentRow, top: topRow,"))
        #expect(body.contains("proxy.scrollTo(target, anchor: .center)"))
    }

    // MARK: TE180 — Show Outline in File List from anywhere

    /// The workspace takes the host's door when it has one, and the status line's item uses it.
    @Test func showOutlineUsesTheHostsDoor() throws {
        let workspace = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        #expect(workspace.contains("onShowRailOutline: onShowRailOutline ?? { railTab = .outline })"))
    }

    // MARK: TE181 — the Split divider's double-click

    @Test func aDoubleClickPutsTheDividerBackInTheMiddle() throws {
        #expect(EditorLayoutMetrics.splitStart == 0.5)
        let workspace = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        let handle = try #require(workspace.range(of: "private func splitHandle(width: CGFloat) -> some View {"))
        let body = workspace[handle.upperBound...].prefix(2_500)
        #expect(body.contains(".simultaneously(with: TapGesture(count: 2).onEnded {"))
        #expect(body.contains("splitFraction = EditorLayoutMetrics.splitStart"))
    }

    // MARK: TE182 — what an image import saved

    /// The words for each case: one file by name, several by count, a folder made said so; an image
    /// only linked, or nothing written, says nothing.
    @Test func theImportNoticeSaysWhatWasSavedWhere() {
        let folder = "/n/Images"
        #expect(EditorImageImport.notice(for: .wrote(files: ["\(folder)/Plan-1.png"], madeFolder: nil,
                                                     linked: ["Images/Plan-1.png"])) == "Saved “Plan-1.png” in Images")
        #expect(EditorImageImport.notice(for: .wrote(files: ["\(folder)/Plan-1.png", "\(folder)/Plan-2.png"], madeFolder: nil,
                                                     linked: ["a", "b"])) == "Saved 2 images in Images")
        #expect(EditorImageImport.notice(for: .wrote(files: ["\(folder)/Plan-1.png", "\(folder)/Plan-2.png"], madeFolder: folder,
                                                     linked: ["a", "b"])) == "Made an Images folder for 2 images")
        #expect(EditorImageImport.notice(for: .wrote(files: ["\(folder)/Plan-1.png"], madeFolder: folder,
                                                     linked: ["a"])) == "Made an Images folder for “Plan-1.png”")
        // An image already there is linked, not counted.
        #expect(EditorImageImport.notice(for: .wrote(files: ["\(folder)/Plan-2.png"], madeFolder: nil,
                                                     linked: ["Images/Plan-1.png", "Images/Plan-2.png"])) == "Saved “Plan-2.png” in Images")
        #expect(EditorImageImport.notice(for: .wrote(files: [], madeFolder: nil, linked: ["Images/Plan-1.png"])) == nil)
        #expect(EditorImageImport.notice(for: .refused("Too large")) == nil)
        // The folder's own name, as Finder shows it.
        #expect(EditorImageImport.notice(for: .wrote(files: ["/n/images/x.png"], madeFolder: nil, linked: ["x"]))
                == "Saved “x.png” in images")
    }

    /// Said in the status line's one notice slot, through the disk watch, so a newer notice (the
    /// disk's or the import's) replaces the older rather than two competing.
    @Test func theImportNoticeTakesTheStatusLinesSlot() async throws {
        let watch = EditorDiskWatch(noticeDuration: .seconds(30))
        var heard: [String] = []
        watch.announce = { heard.append($0) }
        watch.noteImagesImported(.wrote(files: ["/n/Images/Plan-1.png"], madeFolder: nil, linked: ["a"]))
        #expect(watch.notice?.text == "Saved “Plan-1.png” in Images")
        #expect(heard == ["Saved “Plan-1.png” in Images"], "VoiceOver did not hear it")
        watch.noteImagesImported(.wrote(files: [], madeFolder: nil, linked: ["a"]))
        #expect(watch.notice?.text == "Saved “Plan-1.png” in Images", "an import that saved nothing cleared the line")
    }

    // MARK: TE183 — the folder menu's Show All

    @Test func theFolderMenuOffersShowAllWithTheTotal() throws {
        #expect(EditorFolderTrail.showAllTitle(count: 52) == "Show All 52 in the File Pane")
        let menu = try SourceText.fileExplorer("EditorRailFolderMenu.swift")
        #expect(menu.contains("if trail.subfolders.count > EditorFolderTrail.subfolderCap, let onShowAll {"))
        #expect(menu.contains("Button(EditorFolderTrail.showAllTitle(count: trail.subfolders.count), action: onShowAll)"))
        #expect(try SourceText.fileExplorer("EditorFileRailView.swift").contains("onGoTo: onGoToFolder, onShowAll: onOpenFilePane)"))
        #expect(try SourceText.fileExplorer("EditorWorkspaceView.swift").contains("onOpenFilePane: onOpenFilePane,"))
    }
}
