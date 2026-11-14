import Testing
import Foundation
@testable import FileExplorer

/// The line-prefix verbs splice the covered lines in once, as one covering range.
@Suite struct MarkupPrefixLinesTests {

    private static let prefixes: [(name: String, prefix: MarkdownEdits.LinePrefix)] = [
        ("heading 1", .heading(1)), ("heading 3", .heading(3)), ("body", .heading(0)),
        ("bullet", .bullet), ("numbered", .numbered), ("task", .task), ("quote", .quote),
    ]

    /// Nothing outside the lines the selection touches may change: `prefixLines` splices one
    /// covering range, so a verb reaching past the last covered line fails here.
    @Test func nothingOutsideTheTouchedLinesIsRewritten() {
        let text = "alpha\nbravo\ncharlie\ndelta\necho\n"
        // A selection sitting entirely inside "bravo" and "charlie".
        let selection = NSRange(location: 8, length: 6)
        var checked = 0
        for (name, prefix) in Self.prefixes {
            guard let edit = MarkdownEdits.prefixLines(text, selection, prefix) else { continue }
            checked += 1
            #expect(edit.text.hasPrefix("alpha\n"), "\(name) rewrote the line above the selection")
            #expect(edit.text.hasSuffix("delta\necho\n"),
                    "\(name) rewrote the lines below the selection")
        }
        #expect(checked >= 6, "only \(checked) of \(Self.prefixes.count) prefixes applied, so the rest checked nothing")
    }
}
