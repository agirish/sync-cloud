import Foundation
import Testing
@testable import Sync

/// The words a spoken question is listened for: only what the screen card shows Claude.
@Suite struct AskClaudeVoiceHintsTests {

    private func row(_ path: String, folder: Bool = false) -> AskClaudeScreen.Row {
        AskClaudeScreen.Row(path: path, name: (path as NSString).lastPathComponent, isDirectory: folder,
                            kind: folder ? "Folder" : "PDF document", size: nil, modified: nil, tags: [])
    }

    @Test func attachedThenSelectedThenTheRestThenFoldersAndSources() {
        var screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "Documents/Taxes", sort: "Name",
                                     rows: [row("/c/Documents/Taxes/1099-INT Ally.pdf"),
                                            row("/c/Documents/Taxes/W-2 2025.pdf"),
                                            row("/c/Documents/Taxes/v2.0", folder: true)],
                                     selection: ["/c/Documents/Taxes/W-2 2025.pdf"], toolsAvailable: true,
                                     sources: ["iCloud", "Dropbox"])
        screen.openFile = row("/c/Documents/I-797A Notice.pdf")
        let words = AskClaudeVoiceHints.words(on: screen, attached: [("H-1B Approval.pdf", false), ("Receipts", true)])
        #expect(words == ["H-1B", "Approval", "Receipts", "W-2", "2025", "I-797A", "Notice", "1099-INT", "Ally", "v2.0",
                          "Documents", "Taxes", "iCloud", "Dropbox"])
    }

    @Test func aNameIsSplitIntoTheWordsSaid() {
        #expect(AskClaudeVoiceHints.words(of: "Statement_from_Ally (copy) – Oct, 2025") == ["Statement", "Ally", "Oct", "2025"])
        #expect(AskClaudeVoiceHints.words(of: "Abhishek's H-1B v2.0 - final") == ["Abhishek's", "H-1B", "v2.0"])
        #expect(AskClaudeVoiceHints.words(of: "a 1 & the") == [])
    }

    /// A hidden folder's rows never reach the screen; its own name stays off the hints as well.
    @Test func aHiddenFolderOnScreenGivesNoName() {
        var screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "Private/Medical", sort: "Name",
                                     rows: [], selection: [], toolsAvailable: true, sources: ["iCloud"])
        screen.folderHidden = true
        #expect(AskClaudeVoiceHints.words(on: screen, attached: []) == ["iCloud"])
    }

    @Test func repeatsAreDroppedWhateverTheirCaseAndTheListIsCapped() {
        let rows = (0..<250).map { row("/c/Scans/Invoice \($0 % 150).pdf") }
        let screen = AskClaudeScreen(workspace: "Browse", source: "iCloud", folder: "invoices", sort: "Name",
                                     rows: rows, selection: [], toolsAvailable: true, sources: ["INVOICE"])
        let words = AskClaudeVoiceHints.words(on: screen, attached: [("invoice 10.pdf", false)])
        #expect(words.count == AskClaudeVoiceHints.limit)
        #expect(Array(words.prefix(2)) == ["invoice", "10"])
        #expect(!words.contains("Invoice") && !words.contains("INVOICE"))
        // Numbers of one digit are too short to be worth a hint; 10 to 108 fill the rest.
        #expect(words.last == "108")
    }
}
