import Foundation
import Testing
@testable import Sync

/// The questions an empty chat offers: fitted to the screen, and never an item's name.
@Suite struct AskClaudeStartersTests {

    private func screen(_ workspace: String, folder: String = "Documents/Taxes", items: Int? = 12, hidden: Bool = false,
                        open: String? = nil) -> AskClaudeStarters.Screen {
        AskClaudeStarters.Screen(workspace: workspace, source: "iCloud", folder: folder, itemCount: items,
                                 folderHidden: hidden, openFile: open)
    }

    @Test func browseAsksAboutTheFolderAndDownloadsAboutPuttingThingsAway() {
        #expect(AskClaudeStarters.questions(for: screen("Browse"))
                == ["What’s in this folder?", "What’s newest here?", "Which are the biggest?"])
        #expect(AskClaudeStarters.questions(for: screen("Browse", folder: "downloads"))
                == ["Where should these files go?", "What came in this week?", "Which are the biggest?"])
    }

    /// Nothing to look at: an empty folder, one still loading, or one hidden from Claude.
    @Test func aFolderClaudeCantLookAtGetsTheQuestionsForAnywhere() {
        for blind in [screen("Browse", items: 0), screen("Browse", items: nil), screen("Browse", hidden: true),
                      screen("Organize", hidden: true), screen("Edit", hidden: true)] {
            #expect(AskClaudeStarters.questions(for: blind) == AskClaudeStarters.anywhere)
        }
    }

    @Test func compareNamesTheSourceOnlyWhileItsFolderIsShown() {
        #expect(AskClaudeStarters.questions(for: screen("Compare"))
                == ["What’s only in iCloud, by folder?", "Show the name conflicts", "What changed, and which side is newer?"])
        let hidden = AskClaudeStarters.questions(for: screen("Compare", hidden: true))
        #expect(hidden == ["Show the name conflicts", "What changed, and which side is newer?", "What can you do in SyncCloud?"])
    }

    @Test func editAsksAboutTheOpenFileWithoutNamingIt() {
        let pdf = AskClaudeStarters.questions(for: screen("Edit", open: "Lease 2026.PDF"))
        #expect(pdf == ["Summarize this PDF", "What dates and amounts does it mention?", "Make it smaller to email",
                        "Where should this file go?"])
        let text = AskClaudeStarters.questions(for: screen("Edit", open: "Notes.md"))
        #expect(text == ["Summarize this file", "What dates and amounts does it mention?", "Where should this file go?"])
        // Nothing open: the folder's questions.
        #expect(AskClaudeStarters.questions(for: screen("Edit")) == AskClaudeStarters.questions(for: screen("Browse")))
    }

    /// Every row of the table: three or four, no folder or file name in any, curly apostrophes only.
    @Test func everyQuestionIsShortAndNamesNoItem() {
        let screens = ["Browse", "Compare", "Organize", "Edit", "Settings"].flatMap { workspace in
            [screen(workspace), screen(workspace, folder: "Downloads"), screen(workspace, items: 0),
             screen(workspace, hidden: true), screen(workspace, open: "Lease 2026.pdf"), screen(workspace, open: "Notes.md")]
        }
        for screen in screens {
            let questions = AskClaudeStarters.questions(for: screen)
            #expect((3...4).contains(questions.count), "\(screen)")
            for question in questions {
                #expect(!question.contains("Taxes") && !question.contains("Lease") && !question.contains("Notes"), "\(question)")
                #expect(!question.contains("'"), "\(question)")
                #expect(question.count <= 48, "\(question)")
            }
        }
    }

    // MARK: What the screen says (TE347b)

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ name: String, folder: Bool = false, daysOld: Double = 30) -> AskClaudeScreen.Row {
        AskClaudeScreen.Row(path: "/x/" + name, name: name, isDirectory: folder, kind: folder ? "Folder" : "File",
                            size: 1, modified: Self.now.addingTimeInterval(-daysOld * 86_400), tags: [])
    }

    private func browse(_ rows: [AskClaudeScreen.Row], selected: Set<String> = [], suggested: String? = nil) -> [String] {
        var signals = AskClaudeStarters.signals(rows: rows, selection: selected, now: Self.now)
        signals.suggested = suggested
        let screen = AskClaudeStarters.Screen(workspace: "Browse", source: "OneDrive", folder: "2026/Approval",
                                              itemCount: rows.count, folderHidden: false, signals: signals)
        return AskClaudeStarters.questions(for: screen)
    }

    @Test func signalsCountKindsCopiesScreenshotsAndTheWeek() {
        let rows = [row("Lease.pdf", daysOld: 2), row("Lease (1).pdf"), row("Notes copy 2.txt"), row("Photo.heic", daysOld: 1),
                    row("Screenshot 2026-11-01 at 9.41.png"), row("Taxes", folder: true, daysOld: 1)]
        let signals = AskClaudeStarters.signals(rows: rows, selection: ["/x/Lease.pdf", "/x/Taxes"], now: Self.now)
        #expect(signals.files == 5 && signals.readable == 3 && signals.pdfs == 2)
        #expect(signals.copies == 2 && signals.screenshots == 1)
        #expect(signals.changedThisWeek == 2, "folders don't count")
        #expect(signals.selected == 2 && signals.selectedReadable == 1)
    }

    /// B1: two PDFs, both new this week.
    @Test func twoNewPDFsAreSummarizedAndAskedAboutTheWeek() {
        #expect(browse([row("A.pdf", daysOld: 1), row("B.pdf", daysOld: 2)])
                == ["Summarize both PDFs", "What changed here this week?", "What’s in this folder?"])
    }

    @Test func aSelectionSpeaksForItself() {
        let rows = [row("A.pdf"), row("B.docx"), row("C.heic"), row("D.pdf")]
        #expect(browse(rows, selected: ["/x/A.pdf", "/x/B.docx"])
                == ["Summarize the 2 selected files", "Where should these 2 go?", "Rename these 2 like their neighbors"])
        // A picture can't be read, so a selection holding one isn't summarized.
        #expect(browse(rows, selected: ["/x/A.pdf", "/x/C.heic"]).first == "Where should these 2 go?")
        #expect(browse(rows, selected: ["/x/C.heic"])
                == ["Where should the selected item go?", "What’s in this folder?", "What’s newest here?"])
    }

    @Test func copiesAndScreenshotsLeadInABusyFolder() {
        let rows = (1...6).map { row("Shot \($0) copy.png") } + (1...5).map { row("Screenshot \($0).png") } + [row("Big.mov")]
        #expect(browse(rows) == ["Which of the 6 copies can I trash?", "Move the 5 screenshots into a folder",
                                 "What’s in this folder?"])
    }

    /// TE309's suggestion leads while the chat is empty, and isn't repeated (B-R8).
    @Test func theSuggestionLeads() {
        let asked = browse([row("A.pdf", daysOld: 1), row("B.pdf")], suggested: "File the new files in iCloud › Downloads")
        #expect(asked == ["File the new files in iCloud › Downloads", "Summarize both PDFs", "What changed here this week?"])
    }

    /// A hidden folder gives no signals, and Edit with a file open keeps its own questions.
    @Test func hiddenFoldersAndOpenFilesKeepTheTable() {
        var signals = AskClaudeStarters.signals(rows: [row("A.pdf", daysOld: 1)], selection: [], now: Self.now)
        signals.copies = 9
        let hidden = AskClaudeStarters.Screen(workspace: "Browse", source: "iCloud", folder: "Private", itemCount: 1,
                                              folderHidden: true, signals: signals)
        #expect(AskClaudeStarters.questions(for: hidden) == AskClaudeStarters.anywhere)
        let editing = AskClaudeStarters.Screen(workspace: "Edit", source: "iCloud", folder: "Leases", itemCount: 1,
                                               folderHidden: false, openFile: "Lease.pdf", signals: signals)
        #expect(AskClaudeStarters.questions(for: editing).first == "Summarize this PDF")
    }

    /// Every rule's wording fits one line and names nothing, at any count (V10, B-R2).
    @Test func everyRuleQuestionIsShort() {
        var signals = AskClaudeStarters.Signals()
        for n in [1, 2, 5, 99, 1234] {
            signals.selected = n; signals.selectedReadable = n
            signals.copies = n; signals.screenshots = n
            let asked = AskClaudeStarters.fromSignals(signals)
                + AskClaudeStarters.fromSignals({ var s = signals; s.selected = 0; s.files = min(n, 5); s.readable = min(n, 5); s.changedThisWeek = 1; return s }())
            for question in asked {
                #expect(question.count <= AskClaudeStarters.longest, "\(question)")
                #expect(!question.contains("'"), "\(question)")
            }
        }
    }

    @Test func theModelsQuestionIsCheckedBeforeItShows() {
        let shown = ["Summarize both PDFs", "What changed here this week?"]
        let names = ["Brokerage statement.pdf", "Lease 2026.pdf", "form.pdf"]
        #expect(AskClaudeStarters.modelQuestion("Does either still need a signature?", beside: shown, names: names)
                == "Does either still need a signature?")
        #expect(AskClaudeStarters.modelQuestion("\"Which one is due first\"", beside: shown, names: names)
                == "Which one is due first?")
        #expect(AskClaudeStarters.modelQuestion("Which form isn't signed?", beside: shown, names: names)
                == "Which form isn’t signed?", "a short common word from a name is the question's own")
        #expect(AskClaudeStarters.modelQuestion("Summarize the brokerage one", beside: shown, names: names) == nil, "a long name word")
        #expect(AskClaudeStarters.modelQuestion("What does Lease 2026 say?", beside: shown, names: names) == nil, "a whole stem")
        #expect(AskClaudeStarters.modelQuestion("Summarize both of the PDFs", beside: shown, names: names) == nil, "a near-copy")
        #expect(AskClaudeStarters.modelQuestion("Tell me a joke about taxes", beside: shown, names: names) == nil, "not a file ask")
        #expect(AskClaudeStarters.modelQuestion("Which of these files were signed by both parties and dated?", beside: shown,
                                                names: names) == nil, "too long for one line")
        #expect(AskClaudeStarters.modelQuestion("Which?\nAnd why", beside: shown, names: names) == nil)
    }
}
