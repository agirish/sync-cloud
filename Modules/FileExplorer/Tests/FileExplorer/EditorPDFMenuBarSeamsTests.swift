import Testing
import Foundation
import SwiftUI
@testable import FileExplorer

/// **What the menu bar reaches in the PDF reader** — the seams Text ▸ Go to Page… and Edit ▸ Select
/// All call. (Zoom In and Zoom Out call `canZoom` and `zoom(in:)`, which `EditorPDFLayoutTests`
/// holds.) The items are the app's and are pinned there; these are the reader's halves, which a
/// revert here would leave the items calling into nothing.
@MainActor
@Suite struct EditorPDFMenuBarSeamsTests {

    /// **Go to Page… asks again on every press** — a count, so a second ⌃⌘L with the field already
    /// up still puts the caret in it.
    /// **File ▸ PDF Tools greys under a tool's own sheet**, as it does while a tool runs — Rotate
    /// chosen there ran underneath an open Compress sheet.
    @Test func theToolsMenuGreysUnderASheet() {
        let tools = EditorPDFTools()
        tools.attach(path: "/a/plain.pdf", pageCount: 3, encryption: .none)
        #expect(EditorPDFToolsMenuEntry.entries(tools).contains { $0.enabled }, "nothing was live to begin with")
        tools.sheet = .compress
        let live = EditorPDFToolsMenuEntry.entries(tools).filter(\.enabled).map(\.title)
        #expect(live.isEmpty, "live under a sheet: \(live)")
    }

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

    /// **The capsule's page field answers Go to Page…** — the request is what the menu item sends.
    @Test func thePageFieldTakesTheCaretWhenAsked() throws {
        let card = try source("EditorPDFCapsule.swift")
        #expect(card.contains(".onChange(of: state.pageFieldRequest) { _, _ in pageFieldFocused = true }"),
                "nothing answers Text ▸ Go to Page… — the item would do nothing")
    }

    /// **⌘A in the Pages grid is Edit ▸ Select All's**, which reads what the grid publishes while it
    /// has focus. The `.onKeyPress` that stood here never ran — the menu takes ⌘A first — so one
    /// coming back would be a handler that reads as working and is not.
    @Test func thePagesGridHandsSelectAllToTheMenu() throws {
        let rail = try source("EditorPDFRailViews.swift")
        #expect(rail.contains(".focusedValue(\\.pdfPagesSelectAll, EditorPDFPagesSelectAll { tools.selectAll() })"),
                "the Pages grid no longer tells Select All what ⌘A means there")
        #expect(!rail.contains(#".onKeyPress(characters: ["a"]"#),
                "an ⌘A key handler is back in the Pages grid — the menu's Select All takes the key first")
    }
}
