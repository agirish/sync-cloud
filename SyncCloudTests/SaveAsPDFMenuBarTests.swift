@testable import SyncCloud
import AppKit
import FileExplorer
import SwiftUI
import Testing

/// **File ▸ Save as PDF and the window's wiring for it** (CV3).
///
/// The test host IS the app, so `NSApp.mainMenu` is what AppKit built from the `.commands`; with no
/// `ContentView` publishing a selection, that is the nothing-selected state. The item's body is a
/// view only a running menu bar builds, so it is drawn here through `NSHostingMenu`, and the
/// window's wiring is read off the source.
@MainActor
@Suite struct SaveAsPDFMenuBarTests {

    // MARK: As AppKit built it

    /// **At the end of File's print group, after Fill & Sign's Save Filled Copy — greyed with
    /// nothing selected, and with no chord.**
    @Test func saveAsPDFEndsThePrintGroupGreyedWithNoSelection() throws {
        let file = try TextMarkupMenuTests.menu("File")
        file.update()
        let titles = TextMarkupMenuTests.titles(file)
        let copy = try #require(titles.firstIndex(of: "Save Filled Copy"), "File ▸ Save Filled Copy is gone")
        let save = try #require(titles.firstIndex(of: "Save as PDF"), "File has no Save as PDF")
        #expect(save == copy + 1, "File reads \(titles[min(copy, save)...]) — Save as PDF belongs after Save Filled Copy")
        let item = try #require(file.items.first { $0.title == "Save as PDF" })
        #expect(!item.isEnabled, "File ▸ Save as PDF is live with nothing selected")
        #expect(item.keyEquivalent.isEmpty, "Save as PDF has acquired a chord: '\(item.keyEquivalent)'")
    }

    // MARK: Drawn for what the window publishes

    /// **The row's offer, under the row's title, running the row's act over the selection's paths**
    /// — chosen through AppKit, as a click in the menu bar chooses it.
    @Test func theItemRunsTheRowsOfferOverTheSelection() throws {
        final class Box { var ran: [[String]] = [] }
        let box = Box()
        let paths = ["/a/Lease.docx", "/a/Trip.md"]
        let menu = NSHostingMenu(rootView: SaveAsPDFMenuContent(
            selection: .init(offer: .several(paths: paths), run: { box.ran.append($0) })))
        menu.update()
        #expect(menu.items.map(\.title) == ["Save 2 as PDFs"])
        #expect(menu.items.first?.isEnabled == true)
        menu.performActionForItem(at: 0)
        #expect(box.ran == [paths])

        let one = NSHostingMenu(rootView: SaveAsPDFMenuContent(
            selection: .init(offer: .single(path: paths[0]), run: { box.ran.append($0) })))
        one.update()
        #expect(one.items.map(\.title) == ["Save as PDF"])
        one.performActionForItem(at: 0)
        #expect(box.ran.last == [paths[0]])

        let none = NSHostingMenu(rootView: SaveAsPDFMenuContent(selection: nil))
        none.update()
        #expect(none.items.map(\.title) == ["Save as PDF"])
        #expect(none.items.first?.isEnabled == false, "with nothing to save, the item is live")
    }

    // MARK: Wiring

    /// **File ▸ is the row menu's gate, question and act**, on the same pane's delegate — and the row
    /// menu still asks the question for both of its items.
    @Test func theMenuBarAsksTheRowsQuestion() throws {
        let commands = try macAppFile("ShortcutCommands.swift")
        let resolver = try declarationBody(of: "var shortcutPaneRowVerbs", in: commands)
        let offered = try #require(argumentLists(of: "PaneRowVerbs(", in: resolver).map(CallArguments.init)
            .first { $0.value("saveAsPDF") != "nil" }, "File ▸ Save as PDF is never handed a selection")
        let save = try #require(offered.value("saveAsPDF"))
        #expect(save.contains(normalizedCode("delegate.canSaveAsPDF ? SaveAsPDFOffer.forSelection(selection).map {")),
                "File ▸ Save as PDF does not ask the row's question: \(save)")
        #expect(save.contains(normalizedCode("run: { delegate.handleSaveAsPDF(paths: $0) }")),
                "File ▸ Save as PDF does not run the row's act: \(save)")

        let command = CodeText(try declarationBody(of: "struct SaveAsPDFCommand: View", in: commands))
        #expect(command.contains("@FocusedValue(\\.paneRowVerbs) private var rowVerbs"))
        #expect(command.contains("SaveAsPDFMenuContent(selection: rowVerbs?.saveAsPDF)"))
        let app = CodeText(try macAppFile("SyncCloudApp.swift"))
        #expect(app.contains("PDFFillSignCommand() SaveAsPDFCommand()"), "Save as PDF is not in File's print group")

        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/FileExplorer/Sources/FileExplorer/FileTreeView.swift"), encoding: .utf8)
        #expect(CodeText(pane).count(of: "SaveAsPDFOffer.forSelection(") == 2,
                "the row menu no longer asks forSelection for both its items")
    }

    /// **The pane delegate's act reaches the window's run**, and the window draws its banner.
    @Test func theRowsActReachesTheWindowsRun() throws {
        let delegate = CodeText(try declarationBody(of: "func handleSaveAsPDF(paths: [String])",
                                                    in: try macAppFile("PaneActionDelegate.swift")))
        #expect(delegate.contains("paths.allSatisfy({ SaveAsPDFKind.of(path: $0) != nil })"),
                "the handler takes kinds no engine converts")
        #expect(delegate.contains("onSaveAsPDF(paths)"))

        let view = CodeText(try macAppFile("ContentView.swift"))
        #expect(view.contains("onSaveAsPDF: { paths in startSaveAsPDF(paths) },"), "the row's act reaches nothing")
        #expect(view.contains("PanePDFToolsPresenter(model: panePDFTools, saveAsPDF: paneSaveAsPDF,"),
                "the run's banner is drawn nowhere")

        let start = CodeText(try declarationBody(of: "func startSaveAsPDF(_ paths: [String])",
                                                 in: try macAppFile("ContentView+Editor.swift")))
        #expect(start.contains("rereadPanesAfterEditorWrite(path, writer: writer)"), "a saved PDF is not listed")
        #expect(start.contains("open: { path in handOffToEditor(path) },"))
        #expect(start.contains("from: .saveAsPDFBanner)"))
        #expect(start.contains("let panel = NSSavePanel()"), "a read-only folder does not ask where")
        #expect(start.contains("paneSaveAsPDF.start(paths: paths, writer: writer)"))
    }
}
