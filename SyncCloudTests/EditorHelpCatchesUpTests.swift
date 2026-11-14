import Foundation
import Testing
@testable import SyncCloud

/// Help says what Edit does: the file list is never "the rail", and Edit's keys and controls are
/// in the article. Each phrase must appear verbatim, so rewording one is a visible decision.
@Suite struct EditorHelpCatchesUpTests {
    /// Edit's article, or with `pdf` the PDF's, which carries the PDF lines.
    private static func editText(pdf: Bool = false) throws -> String {
        let topic = try #require(HelpBook.topic(id: pdf ? "pdf-workspace" : "editor-workspace"))
        return HelpBookTests.copy(of: topic).joined(separator: " ")
    }

    @Test func editsArticleNeverSaysRail() throws {
        let text = try Self.editText() + " " + Self.editText(pdf: true)
        let rail = try NSRegularExpression(pattern: #"\brails?\b"#, options: .caseInsensitive)
        let hits = rail.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
            .map { "…" + text[..<$0.upperBound].suffix(50) }
        #expect(hits.isEmpty, "\(hits)")
        #expect(text.contains("The file list shows the text files and PDFs"))
        #expect(text.contains("Show Outline in File List"), "the status line's menu item, by its new name")
    }

    @MainActor
    @Test func editsArticleCatchesUp() throws {
        let text = try Self.editText()
        let pdf = try Self.editText(pdf: true)
        #expect(pdf.contains("press Delete to remove it — the arrow keys nudge it a point, ⇧ by ten —"),
                "the PDF's article no longer says how to move a placed item")
        // The menu phrase is read off the menu bar the app built, title and chord.
        let findPrevious = try #require(try appMenu("Text").items.first { $0.title == "Find Previous" },
                                        "Text ▸ Find Previous is not in the menu bar")
        #expect(text.contains("Text ▸ \(findPrevious.title) (\(chordGlyphs(findPrevious)))"),
                "Help does not name Text ▸ Find Previous by its menu title and chord")
        for phrase in [
            "the Markup verbs and the find items are grayed",
            "The filter button, beside the ＋ at the end of the folder’s row,",
            "Click the folder’s name for a menu of the folders above it and inside it",
        ] {
            #expect(text.contains(phrase), "Help no longer says “\(phrase)”")
        }
        // The header's buttons by their words, and the rule they shed them by.
        #expect(pdf.contains("then Expand and Close;"), "the PDF's article no longer names its header's buttons")
        for phrase in ["Close, at the right-hand end of that row, closes the file",
                       "New Text File, Find, Files and Close drop their words together",
                       "Find, beside the Source/Preview/Split buttons,"] {
            #expect(text.contains(phrase), "Help no longer says “\(phrase)”")
        }
        for gone in ["the two find items", "funnel", "The × at the right-hand end", "The magnifying glass beside"] {
            #expect(!text.contains(gone), "Help still says “\(gone)”")
        }
    }
}
