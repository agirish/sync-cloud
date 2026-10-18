@testable import SyncCloud
import AppKit
import Design
import FileExplorer
import SwiftUI
import Testing

/// **The menu bar over a PDF open in Edit** — File ▸ PDF Tools, Text's page controls on the modes'
/// slots, and the rules that offer them.
///
/// The test host IS the app, so `NSApp.mainMenu` is what AppKit built from the `.commands`; nothing
/// is published into it here (no `ContentView`), which is the no-PDF state. The items' bodies are
/// views only a running menu bar builds, so their wiring to the rules is read off the source.
@MainActor
@Suite struct PDFMenuBarTests {

    private static func file() throws -> NSMenu {
        try TextMarkupMenuTests.menu("File")
    }

    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    // MARK: File ▸ PDF Tools, as AppKit built it

    /// **Below Print…, after a divider**, and with exactly the header's lines — drawn from the same
    /// entries, here for tools attached to nothing.
    @Test func pdfToolsFollowPrintAndListTheHeadersLines() throws {
        let file = try Self.file()
        let titles = Self.titles(file)
        let print = try #require(titles.firstIndex(of: "Print…"), "File ▸ Print… is gone")
        let tools = try #require(titles.firstIndex(of: "PDF Tools"), "File has no PDF Tools submenu")
        #expect(tools == print + 2 && titles[print + 1] == "—",
                "PDF Tools does not follow Print… after a divider: \(titles[print...])")

        let submenu = try #require(file.items[tools].submenu, "PDF Tools is an item, not a submenu")
        let entries = EditorPDFToolsMenuEntry.entries(PDFToolsCommand.idle)
        // The header's lines, grouped as `EditorPDFToolsMenuItems` groups them.
        let expected = EditorPDFToolsMenuItems.groups(entries).flatMap { group -> [String] in
            if let name = group.submenu { return [name] }
            return group.items.flatMap { $0.dividerBefore ? ["—", $0.title] : [$0.title] }
        }
        #expect(Self.titles(submenu) == expected, "File ▸ PDF Tools reads \(Self.titles(submenu)), the header \(expected)")
        #expect(Self.titles(submenu).contains("Compress…"), "the idle entries are empty — this check is vacuous")
    }

    /// **Greyed line by line with no PDF open, and no chords anywhere in it** — a disabled `Menu`
    /// in the menu bar leaves its items live, so each line has to grey on its own.
    @Test func pdfToolsAreGreyedWithNoPDFAndCarryNoChords() throws {
        let file = try Self.file()
        let item = try #require(file.items.first { $0.title == "PDF Tools" })
        func walk(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(walk) ?? []) }
        }
        let lines = walk(try #require(item.submenu)).filter { !$0.isSeparatorItem && $0.submenu == nil }
        #expect(lines.count >= 8, "found \(lines.count) lines — this check would be vacuous")
        for line in lines {
            #expect(!line.isEnabled, "File ▸ PDF Tools ▸ \(line.title) is live with no PDF open")
            #expect(line.keyEquivalent.isEmpty, "File ▸ PDF Tools ▸ \(line.title) carries a chord")
        }
    }

    // MARK: The rules

    /// **Where the header draws its Tools menu**: Edit, a PDF, open or locked.
    @Test func pdfToolsAreOfferedWhereTheHeaderDrawsThem() {
        #expect(PDFToolsMenu.isOffered(workspace: .editor, hasPDF: true, phase: .open))
        #expect(PDFToolsMenu.isOffered(workspace: .editor, hasPDF: true, phase: .locked),
                "a locked PDF withholds Remove Password…, the one tool it takes")
        #expect(!PDFToolsMenu.isOffered(workspace: .editor, hasPDF: true, phase: .loading))
        #expect(!PDFToolsMenu.isOffered(workspace: .editor, hasPDF: true, phase: .refused("gone")))
        #expect(!PDFToolsMenu.isOffered(workspace: .editor, hasPDF: false, phase: .open))
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(!PDFToolsMenu.isOffered(workspace: workspace, hasPDF: true, phase: .open),
                    "offered from \(workspace), where no header can show a tool's sheet")
        }
    }

    /// **The PDF on screen first, then the pane's selection** — and nothing greys the menu.
    @Test func pdfToolsTakeTheOpenPDFFirstThenTheSelection() {
        let batch = PanePDFToolOffer.several(paths: ["/a/One.pdf", "/a/Two.pdf"])
        #expect(PDFToolsMenu.source(openPDF: true, selection: batch) == .openPDF,
                "a selection outranked the PDF open in Edit — its page tools would be out of reach")
        #expect(PDFToolsMenu.source(openPDF: true, selection: nil) == .openPDF)
        #expect(PDFToolsMenu.source(openPDF: false, selection: batch) == .selection(batch))
        #expect(PDFToolsMenu.source(openPDF: false, selection: nil) == nil)
    }

    // MARK: File ▸ PDF Tools, drawn for what the window publishes

    /// One line of a menu AppKit built — a submenu with its lines after `▸`, a line nothing can
    /// choose in brackets.
    private static func lines(_ menu: NSMenu) -> [String] {
        menu.update()
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if let submenu = item.submenu { return "\(item.title) ▸ \(lines(submenu).joined(separator: ", "))" }
            return item.isEnabled ? item.title : "(\(item.title))"
        }
    }

    private static func drawn(tools: EditorPDFTools?, selection: PaneRowVerbs.SelectionPDFTools?) -> NSMenu {
        NSHostingMenu(rootView: PDFToolsMenuContent(tools: tools, selection: selection))
    }

    /// **Outside a PDF open in Edit, File ▸ PDF Tools is the row's submenu for the selection** — its
    /// title, its lines, live — as `NSHostingMenu` builds it, which is how the menu bar turns a
    /// SwiftUI menu into an `NSMenu`. The test host's own menu bar is never handed a selection.
    @Test func pdfToolsDrawTheSelectionsSubmenu() throws {
        let paths = ["/a/One.pdf", "/a/Two.pdf"]
        let offer = PanePDFToolOffer.several(paths: paths)
        let menu = Self.drawn(tools: nil, selection: .init(offer: offer, run: { _, _ in }))
        let row = Self.lines(NSHostingMenu(rootView: PanePDFToolsMenuItems(offer: offer) { _, _ in }))
        #expect(row.contains("Compress 2 Files…"), "the row's lines are empty — this check is vacuous: \(row)")
        #expect(Self.lines(menu) == ["PDF Tools · 2 files ▸ " + row.joined(separator: ", ")],
                "File ▸ PDF Tools reads \(Self.lines(menu)), the row \(row)")
        let single = Self.drawn(tools: nil, selection: .init(offer: .single(path: paths[0], encryption: .lockedToOpen),
                                                             run: { _, _ in }))
        #expect(Self.lines(single) == ["PDF Tools ▸ (\(EditorPDFTools.lockedReason)), —, Remove Password…"],
                "a file locked to open is not offered the one tool it takes: \(Self.lines(single))")
    }

    /// **Each line runs the row's request over the selection's paths** — chosen through AppKit, as a
    /// click in the menu bar chooses it; the test host is the app, so its items fire.
    @Test func pdfToolsRunTheRowsRequestsOverTheSelection() throws {
        final class Box { var ran: [String] = [] }
        func choose(_ titles: [String], in offer: PanePDFToolOffer) throws -> [String] {
            let box = Box()
            let menu = Self.drawn(tools: nil, selection: .init(offer: offer, run: { box.ran.append("\($0) \($1)") }))
            for title in titles {
                // The one submenu, then down through any submenu a line sits in — Rotate's three.
                var level = try #require(menu.items.first?.submenu, "File ▸ PDF Tools has no submenu")
                for step in title.split(separator: "▸").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    level.update()
                    let at = try #require(level.items.firstIndex { $0.title == step }, "no line \(step) in \(Self.lines(level))")
                    if let next = level.items[at].submenu { level = next } else { level.performActionForItem(at: at) }
                }
            }
            return box.ran
        }
        let paths = ["/a/One.pdf", "/a/Two.pdf"]
        #expect(try choose(["Rotate All Pages ▸ Rotate Left", "Rotate All Pages ▸ Rotate 180°", "Compress 2 Files…",
                            "Clean Metadata of 2 Files…"], in: .several(paths: paths))
                == ["rotateAll(quarterTurns: -1) \(paths)", "rotateAll(quarterTurns: 2) \(paths)",
                    "compress \(paths)", "cleanMetadata \(paths)"])
        let one = ["/a/One.pdf"]
        #expect(try choose(["Rotate All Pages ▸ Rotate Right", "Protect with Password…"],
                           in: .single(path: one[0], encryption: .none))
                == ["rotateAll(quarterTurns: 1) \(one)", "protect \(one)"])
        #expect(try choose(["Remove Password…"], in: .single(path: one[0], encryption: .restrictedOnly))
                == ["removePassword \(one)"])
    }

    /// **The open PDF wins, and nothing to act on greys every line** — the header's lines both times.
    @Test func pdfToolsDrawTheOpenPDFsLinesOverASelection() throws {
        let header = { (tools: EditorPDFTools) in
            Self.lines(NSHostingMenu(rootView: EditorPDFToolsMenuItems(tools: tools))).joined(separator: ", ")
        }
        let open = EditorPDFTools()
        let selection = PaneRowVerbs.SelectionPDFTools(offer: .several(paths: ["/a/One.pdf", "/a/Two.pdf"]),
                                                       run: { _, _ in })
        #expect(Self.lines(Self.drawn(tools: open, selection: selection)) == ["PDF Tools ▸ " + header(open)],
                "a selection took File ▸ PDF Tools from the PDF open in Edit")
        let idle = Self.lines(Self.drawn(tools: nil, selection: nil))
        #expect(idle == ["PDF Tools ▸ " + header(PDFToolsCommand.idle)])
        #expect(idle[0].contains("(Compress…)") && !idle[0].contains(", Compress…"),
                "with nothing to act on, a line is live: \(idle)")
    }

    /// **The page controls: Edit and the PDF open** — not locked, where the header draws none.
    @Test func thePageControlsAreOfferedForAnOpenPDFInEdit() {
        #expect(PDFPageVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .open))
        #expect(!PDFPageVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .locked))
        #expect(!PDFPageVerbs.isOffered(workspace: .editor, hasPDF: true, phase: .loading))
        #expect(!PDFPageVerbs.isOffered(workspace: .editor, hasPDF: false, phase: .open))
        #expect(!PDFPageVerbs.isOffered(workspace: .browse, hasPDF: true, phase: .open))
    }

    /// **Each mode's slot is the capsule's same place** — Source's ⌃⌘1 is Fit Page, the capsule's
    /// first — and every fit has a slot.
    @Test func theFitsTakeTheModesSlotsInTheCapsulesOrder() {
        #expect(EditorMode.allCases.map(PDFPageVerbs.fit(for:)) == EditorPDFFit.allCases)
        #expect(EditorMode.allCases.map { PDFPageVerbs.fit(for: $0).title }
                == ["Fit Page", "Fit Width", "Actual Size"])
        #expect(PDFPageVerbs.goToTitle(nil) == "Go to Line…")
        #expect(PDFPageVerbs.goToTitle(PDFPageVerbs(view: EditorPDFViewState(), goToPage: nil)) == "Go to Page…")
    }

    /// **⌘A outside a text field: the Pages grid's pages while it has focus, else the pane's rows** —
    /// and never both.
    @Test func selectAllTakesThePagesGridFirst() {
        var ran: [String] = []
        SelectAllScope.selectAll(pages: { ran.append("pages") }, pane: { ran.append("pane") })
        #expect(ran == ["pages"])
        SelectAllScope.selectAll(pages: nil, pane: { ran.append("pane") })
        #expect(ran == ["pages", "pane"])
        SelectAllScope.selectAll(pages: nil, pane: nil)
        #expect(ran.count == 2)
    }

    // MARK: Wiring

    private static func commands() throws -> String { try macAppFile("ShortcutCommands.swift") }

    @Test func thePDFToolsAreResolvedThroughTheRule() throws {
        let editor = try macAppFile("ContentView+Editor.swift")
        let body = CodeText(try declarationBody(of: "var shortcutPDFTools: EditorPDFTools?", in: editor))
        #expect(body.contains("PDFToolsMenu.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil, phase: editorPDF.phase)"))
        #expect(body.contains("return editorPDF.tools"))

        let commands = try Self.commands()
        let item = CodeText(try declarationBody(of: "struct PDFToolsCommand: View", in: commands))
        #expect(item.contains("@FocusedValue(\\.pdfTools) private var tools"))
        #expect(item.contains("@FocusedValue(\\.paneRowVerbs) private var rowVerbs"))
        #expect(item.contains("PDFToolsMenuContent(tools: tools, selection: rowVerbs?.pdfTools)"),
                "File ▸ PDF Tools is not drawn from both values the window publishes")
        let content = CodeText(try declarationBody(of: "struct PDFToolsMenuContent: View", in: commands))
        #expect(content.contains("PDFToolsMenu.source(openPDF: tools != nil, selection: selection?.offer)"))
        #expect(content.contains("PanePDFToolsMenuItems(offer: offer, run: selection.run)"),
                "File ▸ PDF Tools no longer draws the row's own items for a selection")
        #expect(content.contains("EditorPDFToolsMenuItems(tools: tools ?? PDFToolsCommand.idle)"),
                "File ▸ PDF Tools no longer draws the header's own items")
        #expect(content.contains(".disabled(tools == nil)"))
        #expect(CodeText(commands).contains("pdfTools: shortcutPDFTools,"))

        let app = CodeText(try macAppFile("SyncCloudApp.swift"))
        #expect(app.contains("PrintDocumentCommand() PDFToolsCommand()"), "PDF Tools is not in File's print group")
    }

    /// **The selection's tools are the row menu's: its gate, its question, its act.** The row
    /// shows the submenu where `canRunPDFTools` and `forSelection` say so and runs it through
    /// `handlePDFTool`; File ▸ is built from the same three on the same pane's delegate.
    @Test func theSelectionsToolsAreTheRowMenus() throws {
        let resolver = try declarationBody(of: "var shortcutPaneRowVerbs", in: try Self.commands())
        let offered = try #require(argumentLists(of: "PaneRowVerbs(", in: resolver).map(CallArguments.init)
            .first { $0.value("pdfTools") != "nil" }, "File ▸ PDF Tools is never handed a selection")
        let pdfTools = try #require(offered.value("pdfTools"))
        #expect(pdfTools.contains(normalizedCode("delegate.canRunPDFTools ? PanePDFToolOffer.forSelection(selection).map {")),
                "the selection's tools are not asked the row menu's question: \(pdfTools)")
        #expect(pdfTools.contains(normalizedCode("run: { delegate.handlePDFTool($0, paths: $1) }")),
                "the selection's tools do not run through the row menu's handler: \(pdfTools)")

        // …and the row menu still asks it, both times.
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift"), encoding: .utf8)
        #expect(CodeText(pane).count(of: "PanePDFToolOffer.forSelection(") == 2,
                "the row menu no longer asks forSelection for both its submenus")
    }

    @Test func thePageVerbsAreResolvedThroughTheRule() throws {
        let editor = try macAppFile("ContentView+Editor.swift")
        let body = CodeText(try declarationBody(of: "var shortcutPDFPage: PDFPageVerbs?", in: editor))
        #expect(body.contains("PDFPageVerbs.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil, phase: editorPDF.phase)"))
        #expect(body.contains("(editorPDF.facts?.pageCount ?? 0) > 0 ? { view.requestPageField() } : nil"),
                "Go to Page… is not the header's page field, or is offered where none is drawn")
        #expect(CodeText(try Self.commands()).contains("pdfPage: shortcutPDFPage,"))
    }

    /// **The modes' items become the fits, on the modes' own chords** — and Go to Line becomes Go
    /// to Page, calling the PDF's request rather than the text's.
    @Test func theTextMenuItemsHandAPDFItsOwnControls() throws {
        let commands = try Self.commands()
        let modes = CodeText(try declarationBody(of: "struct EditorModeCommands: View", in: commands))
        #expect(modes.contains("if let pdfPage { PDFFitCommands(state: pdfPage.view) } else { textModes }"))

        let fits = CodeText(try declarationBody(of: "struct PDFFitCommands: View", in: commands))
        #expect(fits.contains("let fit = PDFPageVerbs.fit(for: mode)"))
        #expect(fits.contains("Toggle(fit.title, isOn: Binding("), "the fits are not titled as the zoom menu titles them")
        #expect(fits.contains("set: { isOn in if isOn { state.fit = fit } }"))
        #expect(fits.contains(".keyboardShortcut(mode.chord.key, modifiers: mode.chord.modifiers)"),
                "the fits are not on the modes' chords")
        #expect(fits.contains("Button(\"Zoom In\") { state.zoom(in: true) } .disabled(!state.canZoom(in: true))"))
        #expect(fits.contains("Button(\"Zoom Out\") { state.zoom(in: false) } .disabled(!state.canZoom(in: false))"))
        #expect(!fits.contains("AppChord.textBigger") && !fits.contains("AppChord.textSmaller"),
                "a zoom item took View ▸ Text Size's chord")

        let goTo = CodeText(try declarationBody(of: "struct GoToLineCommand: View", in: commands))
        #expect(goTo.contains("Button(PDFPageVerbs.goToTitle(pdfPage))"))
        #expect(goTo.contains("if let pdfPage { pdfPage.goToPage?() } else { verbs?.goToLine?() }"))
        #expect(goTo.contains(".disabled(pdfPage.map { $0.goToPage == nil } ?? (verbs?.goToLine == nil))"))
    }

    /// **⌘C and ⌘A hand a PDF reader its own copy and select-all**, and ⌘A in the Pages grid its
    /// pages. Cut and Paste do not — nothing on a read-only page can be cut or pasted.
    @Test func copyAndSelectAllReachTheReader() throws {
        let commands = try Self.commands()
        let copy = CodeText(try declarationBody(of: "struct CopyCommand: View", in: commands))
        #expect(copy.contains("readerAction: { $0.copy(nil) }"), "⌘C over a PDF copies the file, not its text")
        let selectAll = CodeText(try declarationBody(of: "struct SelectAllCommand: View", in: commands))
        #expect(selectAll.contains("readerAction: { $0.selectAll(nil) }"))
        #expect(selectAll.contains("@FocusedValue(\\.pdfPagesSelectAll) private var pages"))
        #expect(selectAll.contains("fileAction: { SelectAllScope.selectAll(pages: pages?.run, pane: selectAll) }"))
        for item in ["struct CutCommand: View", "struct PasteCommand: View"] {
            #expect(!CodeText(try declarationBody(of: item, in: commands)).contains("readerAction"),
                    "\(item) hands a read-only page a verb it has no meaning for")
        }
    }
}
