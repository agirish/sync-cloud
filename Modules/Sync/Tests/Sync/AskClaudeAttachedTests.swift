import Foundation
import Testing
@testable import Sync

/// What they right-clicked to ask about, on the screen card (TE263).
@Suite struct AskClaudeAttachedTests {

    private func row(_ path: String, folder: Bool = false) -> AskClaudeScreen.Row {
        AskClaudeScreen.Row(path: path, name: (path as NSString).lastPathComponent, isDirectory: folder,
                            kind: folder ? "Folder" : "PDF document", size: folder ? nil : 2_000, modified: nil, tags: [])
    }

    @Test func attachedRowsGoWithHandlesAndWhereTheyLive() throws {
        var screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "Documents", sort: "Name",
                                     rows: [row("/c/Documents/Notes.txt")], selection: [], toolsAvailable: true)
        screen.attached = [AskClaudeScreen.Attached(row: row("/d/Work/Lease.pdf"), place: "Dropbox › Work"),
                           AskClaudeScreen.Attached(row: row("/c/Taxes", folder: true), place: "iCloud")]
        var handles = AskClaudeHandles()
        let text = AskClaudeScreenCard.render(screen, handles: &handles).text
        let lines = text.split(separator: "\n").map(String.init)
        let header = try #require(lines.firstIndex { $0.hasPrefix("attached by them") })
        let lease = lines[header + 1]
        #expect(lease.hasSuffix("|Dropbox › Work"))
        #expect(handles.path(for: String(lease.split(separator: "|")[0])) == "/d/Work/Lease.pdf")
        #expect(lines[header + 2].hasSuffix("|iCloud"))
        // Paths never leave the Mac: only the handle, the name and where.
        #expect(!text.contains("/d/Work"))
    }

    @Test func theyGoEvenWhenTheFolderOnScreenIsHidden() {
        var screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "Private", sort: "Name",
                                     rows: [], selection: [], toolsAvailable: true)
        screen.folderHidden = true
        screen.attached = [AskClaudeScreen.Attached(row: row("/d/Work/Lease.pdf"), place: "Dropbox › Work")]
        var handles = AskClaudeHandles()
        let text = AskClaudeScreenCard.render(screen, handles: &handles).text
        #expect(text.contains("Lease.pdf") && text.contains("Hidden from Claude list"))
    }
}
