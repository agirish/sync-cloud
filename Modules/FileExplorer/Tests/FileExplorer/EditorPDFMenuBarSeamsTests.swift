import Design
import Testing
import Foundation
import SwiftUI
import Combine
@testable import FileExplorer

/// The reader's halves of the menu bar's PDF items: the seams File ▸ PDF Tools, Text ▸ Go to Page…
/// and Edit ▸ Select All call (`EditorPDFLayoutTests` covers Zoom In and Zoom Out). The items are
/// the app's and are pinned there; without these halves they would call into nothing.
@MainActor
@Suite struct EditorPDFMenuBarSeamsTests {

    /// File ▸ PDF Tools greys under a tool's own sheet, as it does while a tool runs, so no tool
    /// runs underneath an open sheet.
    @Test func theToolsMenuGreysUnderASheet() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/plain.pdf", pageCount: 3, encryption: .none)
        #expect(EditorPDFToolsMenuEntry.entries(tools).contains { $0.enabled }, "nothing was live to begin with")
        tools.sheet = .compress
        let live = EditorPDFToolsMenuEntry.entries(tools).filter(\.enabled).map(\.title)
        #expect(live.isEmpty, "live under a sheet: \(live)")
        // Fill & Sign's Add Signature sheet is a sheet like a tool's.
        tools.sheet = nil
        let fill = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: ScratchDefaults("EditorPDFMenuBarSeams")))
        tools.fill = fill
        fill.tools = tools      // as `EditorPDFDocument` wires them
        #expect(EditorPDFToolsMenuEntry.entries(tools).contains { $0.enabled })
        // The menu bar's items observe the tools alone, so the tools must announce the sheet
        // coming and going, or the items keep the live list they drew before it.
        var told = 0
        let heard = tools.objectWillChange.sink { told += 1 }
        fill.addingSignature = .signature
        let underSignature = EditorPDFToolsMenuEntry.entries(tools).filter(\.enabled).map(\.title)
        #expect(underSignature.isEmpty, "live under Add Signature: \(underSignature)")
        fill.addingSignature = nil
        heard.cancel()
        #expect(told == 2, "the tools heard Add Signature come and go \(told) times, not 2")
    }

    /// Go to Page… asks again on every press: a count, so a second ⌃⌘L with the field already up
    /// still puts the caret in it.
    @Test func everyGoToPageIsANewAsk() {
        let state = EditorPDFViewState()
        let before = state.pageFieldRequest
        state.requestPageField()
        state.requestPageField()
        #expect(state.pageFieldRequest == before &+ 2)
    }

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(text.count > 2_000, "\(file) read as \(text.count) characters — this scan would be vacuous")
        // Code only: a comment naming a call is not the call.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The capsule's page field answers Go to Page…, whose request is what the menu item sends.
    @Test func thePageFieldTakesTheCaretWhenAsked() throws {
        let card = try source("EditorPDFCapsule.swift")
        #expect(card.contains(".onChange(of: state.pageFieldRequest) { _, _ in pageFieldFocused = true }"),
                "nothing answers Text ▸ Go to Page… — the item would do nothing")
    }

    /// ⌘A in the Pages grid is Edit ▸ Select All's, which reads what the grid publishes while it has
    /// focus. An `.onKeyPress` for ⌘A would never run, since the menu takes the key first.
    @Test func thePagesGridHandsSelectAllToTheMenu() throws {
        let rail = try source("EditorPDFRailViews.swift")
        #expect(rail.contains(".focusedValue(\\.pdfPagesSelectAll, EditorPDFPagesSelectAll { tools.selectAll() })"),
                "the Pages grid no longer tells Select All what ⌘A means there")
        #expect(!rail.contains(#".onKeyPress(characters: ["a"]"#),
                "an ⌘A key handler is back in the Pages grid — the menu's Select All takes the key first")
    }
}
