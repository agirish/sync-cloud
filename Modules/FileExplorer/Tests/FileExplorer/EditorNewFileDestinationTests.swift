import Testing
import Foundation
@testable import FileExplorer
import FileExplorerTestSupport

/// The ＋ and the naming row name where the file will go (Notes, when the app's
/// `EditorNewFileFolder` says the pane's folder is no place for one), and the rail's ＋ is ⌘N, so it
/// takes the pane there first, as the header's does.
@MainActor
@Suite struct EditorNewFileDestinationTests {

    /// The label is the host's word when it gives one, the folder's otherwise; `folderName` is
    /// unchanged, because the rail heading says what the list shows. Fails if the label returns
    /// `folderName`, an empty override is honoured, or `folderName` reads the override.
    @Test func thePlusNamesNotesOverThePanesFolder() {
        #expect(EditorWorkspaceView.fixture(folder: "/", newFileFolderName: "Notes").newFileFolderLabel == "Notes")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads").newFileFolderLabel == "Downloads")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads", newFileFolderName: "").newFileFolderLabel == "Downloads")
        #expect(EditorWorkspaceView.fixture(folder: "/n/Downloads", newFileFolderName: "Notes").folderName == "Downloads")
    }

    /// A source scan, since a SwiftUI `Button`'s action and tooltip can't be read from a hosted
    /// tree (see `EditorHeaderDoorsTests`). Comments are dropped and whitespace collapsed, so prose
    /// can't satisfy a check and a reflow can't fail one. Fails if the rail's ＋ sets
    /// `isNaming = true`, the workspace drops either value, or a site still names `folderName`.
    @Test func everyPlusAndNamingRowNamesTheDestination() throws {
        let workspace = try Self.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("onNewTextFile: onNewTextFile, newFileFolderName: newFileFolderName,"),
                "the rail is not handed ⌘N's closure and the destination's name")
        #expect(workspace.contains("onCreate: onCreate, folderName: newFileFolderLabel)"),
                "the document column's naming row names the pane's folder, not the destination")
        #expect(workspace.contains("Self.newTextFileTitle(folderName: newFileFolderLabel)"),
                "the header ＋'s tooltip names the pane's folder, not the destination")
        let rail = try Self.source("EditorFileRailView.swift")
        #expect(rail.contains("Button { onNewTextFile?() } label:"),
                "the rail's ＋ opens the row itself — it skips ⌘N's move to Notes")
        #expect(!rail.contains("isNaming = true"), "the rail's ＋ sets isNaming directly again")
        #expect(rail.contains("EditorWorkspaceView.newTextFileTitle(folderName: newFileFolderName ?? folderName)"))
        #expect(rail.contains("onCreate: onCreate, folderName: newFileFolderName)"))
    }

    private static func source(_ name: String) throws -> String {
        // Whole-line comments out (these files keep no `//` inside a string literal), then every
        // run of whitespace as one space.
        let code = SourceText.codeOnly(try SourceText.fileExplorer(name))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: " // ").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: " ")
        return code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
