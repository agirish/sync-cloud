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
}
