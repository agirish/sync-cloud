import Testing
import Foundation
@testable import FileExplorer

/// Front matter: what it is, what it is not, and the line numbers it shifts.
@Suite struct MarkdownFrontMatterTests {

    @Test func aBlockAtTheTopIsSplitOff() {
        let split = MarkdownFrontMatter.split("---\ntitle: Plan\ntags: [a]\n---\n\n# Body\n")
        #expect(split.frontMatter == "title: Plan\ntags: [a]")
        #expect(split.body == "\n# Body\n")
        #expect(split.bodyStartLine == 5)
    }

    /// A file that opens with a horizontal rule is a real file, and reading the rest of it as
    /// unterminated front matter would make its whole text vanish from the preview.
    @Test func anUnclosedOpenerIsJustAThematicBreak() {
        let split = MarkdownFrontMatter.split("---\njust prose, no closing fence\n")
        #expect(split.frontMatter == nil)
        #expect(split.bodyStartLine == 1)
    }

    @Test func aRuleInTheMiddleIsNotFrontMatter() {
        let split = MarkdownFrontMatter.split("# Title\n\n---\n\nmore\n")
        #expect(split.frontMatter == nil)
    }

    /// Splitting on `"\n"` leaves the `\r` on every line of a Windows file, so front matter in one
    /// went entirely unrecognised until the comparison trimmed it.
    @Test func aWindowsFileIsRecognisedToo() {
        let split = MarkdownFrontMatter.split("---\r\ntitle: Plan\r\n---\r\n\r\n# Body\r\n")
        #expect(split.frontMatter == "title: Plan\r")
        #expect(split.bodyStartLine == 4)
    }

    @Test func yamlsOtherCloserIsAccepted() {
        #expect(MarkdownFrontMatter.split("---\na: 1\n...\nbody\n").frontMatter == "a: 1")
    }

    @Test func keysAreCountedButValuesAreNot() {
        let matter = "title: Plan\ntags:\n  - one\n  - two\n# a comment\n\nauthor: A"
        #expect(MarkdownFrontMatter.keyCount(in: matter) == 3,
                "counted \(MarkdownFrontMatter.keyCount(in: matter))")
    }

    // MARK: What it does to the blocks

    /// The defect this feature exists for: a paragraph followed by a line of dashes is a setext
    /// heading, so the closing fence turned the last YAML key into an H2 — and the outline listed
    /// it as a section of the document.
    @Test func aYamlKeyIsNoLongerParsedAsAHeading() {
        let blocks = MarkdownBlocks.blocks(from: "---\ntitle: Plan\n---\n\n# Real\n")
        let headings = MarkdownOutline.entries(from: blocks)
        #expect(headings.map(\.title) == ["Real"],
                "the outline listed \(headings.map(\.title))")
    }

    @Test func theBlockIsCarriedRatherThanDropped() {
        let blocks = MarkdownBlocks.blocks(from: "---\ntitle: Plan\n---\n\n# Real\n")
        guard case .frontMatter(let matter)? = blocks.first?.kind else {
            Issue.record("the front matter did not come back as a block: \(blocks)")
            return
        }
        #expect(matter == "title: Plan")
        #expect(blocks.first?.line == 1)
    }

    /// Every line below the block has to be reported in the FILE's numbering, or the outline, the
    /// task toggle and the split sync all land the same distance too high.
    @Test func linesBelowTheBlockAreInTheFilesOwnNumbering() {
        let source = "---\ntitle: Plan\nauthor: A\n---\n\n# Real\n\n- [ ] task\n"
        let blocks = MarkdownBlocks.blocks(from: source)
        let heading = blocks.first { if case .heading = $0.kind { return true } else { return false } }
        #expect(heading?.line == 6, "the heading landed on line \(heading?.line as Int?)")

        // And the toggle, which reads the buffer by that line, finds the checkbox there.
        let task = blocks.first { if case .listItem(.task, _) = $0.kind { return true } else { return false } }
        #expect(task?.line == 8)
        #expect(MarkdownEdits.toggleTask(onLine: task?.line ?? 0, in: source)?.hasSuffix("- [x] task\n") == true)
    }
}
