import Testing
import Foundation
@testable import FileExplorer

/// The non-nesting delimiters (Bold, Strikethrough, Inline Code) read a run that holds the
/// delimiter again as two spans, not one, and do not unwrap it.
@Suite struct MarkupTwoSpanTests {

    /// Bold over two bold spans and the text between adds a pair rather than turning them inside
    /// out, and the bar does not light for it; Italic around a bold word still unwraps, because
    /// italic nests.
    @Test func twoSpansAreNotTakenForOne() throws {
        let text = "**Warning** read the **docs**"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let bold = try #require(MarkdownEdits.apply(.bold, to: text, selection: all))
        #expect(bold.text == "****Warning** read the **docs****", "Bold over two spans gave “\(bold.text)”")
        #expect(!MarkdownEdits.isApplied(.bold, in: text, selection: all), "Bold lights over two bold spans")
        // Between the outer pairs: still two spans.
        let between = NSRange(location: 2, length: all.length - 4)
        #expect(!MarkdownEdits.isApplied(.bold, in: text, selection: between))
        let code = "`a` and `b`"
        // Two code spans selected whole get a run longer than theirs, padded because the text
        // starts with a backtick; one more backtick each side would close at once.
        #expect(MarkdownEdits.apply(.inlineCode, to: code, selection: NSRange(location: 0, length: 11))?.text
                == "`` `a` and `b` ``")
        // Italic nests: one italic span holding a bold word comes off whole, as before.
        let italic = "*a **b** c*"
        let whole = NSRange(location: 0, length: (italic as NSString).length)
        #expect(MarkdownEdits.apply(.italic, to: italic, selection: whole)?.text == "a **b** c")
        #expect(MarkdownEdits.isApplied(.italic, in: italic, selection: whole))
        // One span still comes off.
        #expect(MarkdownEdits.apply(.bold, to: "**docs**", selection: NSRange(location: 0, length: 8))?.text == "docs")
    }
}
