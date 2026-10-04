import Testing
import Foundation
@testable import FileExplorer
import FileExplorerTestSupport

/// **The ＋ and the naming row name where the file will go** — Notes, when the host says the pane's
/// folder is no place for one (the app's `EditorNewFileFolder`) — and **the rail's ＋ is ⌘N**, so it
/// takes the pane there first, as the header's does.
@MainActor
@Suite struct EditorNewFileDestinationTests {

    /// The label is the host's word when it gives one, the folder's otherwise; the folder's own name
    /// is unchanged, because the rail heading says what the list shows. Mutations:
    /// `newFileFolderLabel` returning `folderName` fails the first; ignoring an empty override fails
    /// the third; `folderName` reading the override fails the last.
    @Test func thePlusNamesNotesOverThePanesFolder() {
        #expect(EditorWorkspaceView.fixture(folder: "/", newFileFolderName: "Notes").newFileFolderLabel == "Notes")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads").newFileFolderLabel == "Downloads")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads", newFileFolderName: "").newFileFolderLabel == "Downloads")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads", newFileFolderName: "Notes").folderName == "Downloads")
    }

    /// Scanned: a SwiftUI `Button`'s action and tooltip can't be read from a hosted tree here (see
    /// `EditorHeaderDoorsTests`). Mutations: the rail's ＋ back on `isNaming = true`, the workspace
    /// not passing either value, or a site still naming `folderName` each fail a line.
    @Test func everyPlusAndNamingRowNamesTheDestination() throws {
        let workspace = try Self.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("onNewTextFile: onNewTextFile,\n                               newFileFolderName: newFileFolderName,"),
                "the rail is not handed ⌘N's closure and the destination's name")
        #expect(workspace.contains("onCreate: onCreate, folderName: newFileFolderLabel)"),
                "the document column's naming row names the pane's folder, not the destination")
        #expect(workspace.contains("Self.newTextFileTitle(folderName: newFileFolderLabel)"),
                "the header ＋'s tooltip names the pane's folder, not the destination")
        let rail = try Self.source("EditorFileRailView.swift")
        #expect(rail.contains("Button {\n                        onNewTextFile?()\n"),
                "the rail's ＋ opens the row itself — it skips ⌘N's move to Notes")
        #expect(!rail.contains("isNaming = true"), "the rail's ＋ sets isNaming directly again")
        #expect(rail.contains("let destination = newFileFolderName ?? folderName"))
        #expect(rail.contains("onCreate: onCreate, folderName: newFileFolderName)"))
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/FileExplorer")
            .appendingPathComponent(name)
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — this scan would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scan would be near-vacuous")
        return text
    }
}
