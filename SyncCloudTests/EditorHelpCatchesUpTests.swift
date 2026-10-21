import Foundation
import Testing
@testable import SyncCloud

/// **Help says what Edit does** (TE120, TE131): the file list is never "the rail", and the keys and
/// controls the article left out are in it. Each phrase is one the article must carry verbatim, so
/// rewording one is a decision this test makes visible.
@Suite struct EditorHelpCatchesUpTests {

    private static func editText() throws -> String {
        let topic = try #require(HelpBook.topic(id: "editor-workspace"))
        var out = [topic.title, topic.article.intro]
        for block in topic.article.blocks {
            switch block {
            case .paragraph(let text), .tip(let text): out.append(text)
            case .bullets(let items): out.append(contentsOf: items)
            case .legend(let items): out.append(contentsOf: items.flatMap { [$0.title, $0.detail] })
            }
        }
        return out.joined(separator: " ")
    }

    @Test func editsArticleNeverSaysRail() throws {
        let text = try Self.editText()
        let rail = try NSRegularExpression(pattern: #"\brails?\b"#, options: .caseInsensitive)
        let hits = rail.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
            .map { "…" + text[..<$0.upperBound].suffix(50) }
        #expect(hits.isEmpty, "\(hits)")
        #expect(text.contains("The file list shows the text files and PDFs"))
        #expect(text.contains("Show Outline in File List"), "the status line's menu item, by its new name")
    }

    @Test func editsArticleCatchesUp() throws {
        let text = try Self.editText()
        for phrase in [
            "press Delete to remove it — the arrow keys nudge it a point, ⇧ by ten —",
            "Text ▸ Find Previous (⇧⌘G)",
            "the Markup verbs and the find items are greyed",
            "The filter button, beside the ＋ at the end of the folder's row,",
            "Click the folder's name for a menu of the folders above it and inside it",
        ] {
            #expect(text.contains(phrase), "Help no longer says “\(phrase)”")
        }
        // TE144: the header's buttons by their words, and the rule they shed them by.
        for phrase in ["then Expand and Close;", "Close, at the right-hand end of that row, closes the file",
                       "New Text File, Find, Files and Close drop their words together",
                       "Find, beside the Source/Preview/Split buttons,"] {
            #expect(text.contains(phrase), "Help no longer says “\(phrase)”")
        }
        for gone in ["the two find items", "funnel", "The × at the right-hand end", "The magnifying glass beside"] {
            #expect(!text.contains(gone), "Help still says “\(gone)”")
        }
    }
}
