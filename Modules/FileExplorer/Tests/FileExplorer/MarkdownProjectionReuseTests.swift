import Testing
import Foundation
import AppKit
@testable import FileExplorer

/// **Re-reading part of a document must give exactly the whole re-read** (TE67 §3.7): every block,
/// segment, span and rendered character, attributes compared by shape. The random half throws
/// arbitrary source edits at it — the edits Source makes in Split, not only Preview's careful ones —
/// and chains them, so an error that a single step leaves behind is carried into the next.
///
/// `TE67_PROPERTY_ITERATIONS` raises the count and `TE67_PROPERTY_SEED` replays one, as for
/// `PreviewEditPropertyTests`.
@Suite struct MarkdownProjectionReuseTests {

    // MARK: Cases

    @Test func typingInAParagraphReReadsOnlyThatPart() throws {
        let source = "# Title\n\nOne **two** three.\n\n- a\n- b\n\nLast paragraph."
        let old = MarkdownProjection.project(source)
        let new = source.replacingOccurrences(of: "three", with: "threee")
        let reused = try #require(old.reprojected(new), "declined a plain keystroke")
        Self.expectSame(reused, MarkdownProjection.project(new), "typing")
    }

    /// **A table straight under a paragraph is still re-read in part** — "Here it is:" and the table
    /// on the next line is common, and the parser gives what is left of the paragraph no place in
    /// the file. Without the two read as one, every keystroke near it would re-read the whole note.
    ///
    /// Mutation: stop joining a block with no place to the next, and the overlap guard declines.
    @Test func aTableUnderAParagraphIsStillReReadInPart() throws {
        let source = "Intro.\n\nHere it is:\n| a | b |\n|---|---|\n| c | d |\n\nMiddle.\n\nEnd."
        let old = MarkdownProjection.project(source)
        #expect(old.blocks.contains { $0.line == nil }, "the parser no longer drops the paragraph's place — this test can go")
        for (target, replacement) in [("| c | d |", "| cc | d |"), ("Middle.", "Middle!"), ("Intro.", "Intro!")] {
            let new = source.replacingOccurrences(of: target, with: replacement)
            let reused = try #require(old.reprojected(new), "declined \(target)")
            Self.expectSame(reused, MarkdownProjection.project(new), target)
        }
    }

    /// Mutation: drop the right neighbour's check, and the fence that now swallows the rest is
    /// taken for a paragraph and kept.
    @Test(arguments: [
        // A fence typed open runs on through every block after it.
        ("A paragraph.\n\nNext.\n\nAnd more.\n\nEnd.", "A paragraph.", "```"),
        // A heading's marker deleted: it becomes the paragraph's lazy continuation above.
        ("Above\n# Heading\n\nAfter.\n\nEnd.", "# Heading", "Heading"),
        // A list marker deleted under a paragraph.
        ("Lead in\n- item\n\nAfter.\n\nEnd.", "- item", "item"),
        // A setext underline typed under a paragraph.
        ("One\n\nTwo\n\nThree", "Three", "Two\n---"),
        // An HTML block opened, which runs to its close.
        ("Para.\n\nNext.\n\nMore.\n\nEnd.", "Next.", "<pre>\nNext."),
        // Blocks joined, and split.
        ("First.\n\nSecond.\n\nThird.\n\nFourth.", "Second.\n\nThird.", "Second. Third."),
        ("First.\n\nSecond. Third.\n\nFourth.", "Second. Third.", "Second.\n\n- Third."),
        // A list renumbered by its first item.
        ("Intro.\n\n1. a\n2. b\n3. c\n\nEnd.", "1. a", "5. a"),
        // A table cell, and a table broken.
        ("Intro.\n\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "| c | d |", "| cc | d |"),
        ("Intro.\n\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "|---|---|", "|---"),
        // Front matter edited, opened, and the first line edited.
        ("---\ntitle: x\n---\n\nBody.\n\nMore.", "title: x", "title: y"),
        // The blank line after front matter taken away: the break before the body moves.
        ("---\ntitle: x\n---\n\nBody.\n\nMore.\n\nEnd.", "---\n\nBody", "---\nBody"),
        ("Intro\n\nBody.\n\n---\n\nMore.", "Intro", "---"),
        // A rule on the first line, and a closer typed far below it: all of it becomes front matter.
        ("---\nIntro\n\nA.\n\nB.\n\nC.", "C.", "---"),
        ("Intro words\n\nBody.", "Intro words", "Intro word"),
        // A reference definition added, changed or taken away, for a link three blocks off —
        // before it, and after.
        ("See [x][r].\n\nA.\n\nB.\n\nEnd.", "B.", "[r]: http://x.y"),
        ("[r]: /one\n\nA.\n\nB.\n\nSee [x][r].", "[r]: /one", "[r]: /two"),
        ("A.\n\nB.\n\n[r]: /one\n\nC.\n\nD.\n\nSee [x][r].", "[r]: /one", ""),
        // Everything deleted, and the last block.
        ("Only.", "Only.", ""),
        ("One.\n\nTwo.", "\n\nTwo.", ""),
        // A table straight under a paragraph takes its last line for a header, and the parser gives
        // what is left of the paragraph no place: the two are re-read together (2026-10-08).
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "| c | d |", "| cc | d |"),
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "Intro.", "Intro!"),
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "End.", "End!"),
        ("Intro.\n\nHere it is:\n| a | b |\n|---|---|\n| c | d |\n\nMiddle.\n\nEnd.", "Middle.", "Middle!"),
        // A quote, and nested lists.
        ("Intro.\n\n> a\n> b\n\nEnd.", "> b", "> bb\n>\n> c"),
        ("Intro.\n\n- a\n  - b\n- c\n\nEnd.", "  - b", "  - bb\n    - d"),
    ])
    func everyEditReadsAsTheWholeDocumentWould(source: String, target: String, replacement: String) {
        let old = MarkdownProjection.project(source)
        let new = source.replacingOccurrences(of: target, with: replacement)
        let full = MarkdownProjection.project(new)
        Self.expectSame(MarkdownProjection.project(new, after: old), full, "\(target) → \(replacement)")
    }

    /// A different style is a different layout: only a whole re-read has it.
    @Test func aNewStyleIsAWholeReRead() {
        let old = MarkdownProjection.project("A.\n\nB.")
        var style = old.style
        style.scale = 2
        let new = MarkdownProjection.project("A.\n\nBB.", style: style, after: old)
        #expect(new.style == style)
        Self.expectSame(new, MarkdownProjection.project("A.\n\nBB.", style: style), "scale")
    }

    // MARK: Random

    private static var iterations: Int {
        ProcessInfo.processInfo.environment["TE67_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 2_000
    }

    /// `TE67_PROPERTY_SEED=<n>` replays the one seed a failure names.
    static var seeds: [UInt64] {
        ProcessInfo.processInfo.environment["TE67_PROPERTY_SEED"].flatMap(UInt64.init).map { [$0] }
            ?? Array(1...UInt64(iterations))
    }

    static let inserts = ["a", " ", "\n", "\n\n", "#", "# ", "> ", "- ", "1. ", "2. ", "* ", "```", "~~~",
                                  "|", "| x |", "|---|", "---", "===", "    ", "\t", "*", "**", "_", "`", "[", "]",
                                  "](u)", "<div>", "<pre>", "<!--", "-->", "&amp;", "\\", "  \n", "é", "😀", "[ ] ",
                                  "![i](p.png)", "]:", "[r]: http://x", "[x][r]", "[r]\n\n"]

    @Test func randomEditsReadAsTheWholeDocumentWould() {
        var reused = 0
        var checked = 0
        for seed in Self.seeds {
            var random = SplitMix(seed: seed &+ 0xB10C)
            var source = (0..<random.int(1...3)).map { _ in PreviewEditPropertyTests.document(&random) }
                .joined(separator: "\n\n")
            var previous = MarkdownProjection.project(source)
            // A chain: each step starts from the last step's re-read, never from a fresh one.
            for step in 0..<random.int(1...4) {
                let length = (source as NSString).length
                let at = random.int(0...length)
                let cut = random.int(0...2) == 0 ? min(length - at, random.int(1...6)) : 0
                let text = random.int(0...3) == 0 ? "" : Self.inserts[random.int(0...Self.inserts.count - 1)]
                let new = (source as NSString).replacingCharacters(in: NSRange(location: at, length: cut), with: text)
                let partial = previous.reprojected(new)
                if partial != nil { reused += 1 }
                let next = partial ?? MarkdownProjection.project(new)
                let full = MarkdownProjection.project(new)
                checked += 1
                guard Self.expectSame(next, full, "seed \(seed) step \(step): \(String(reflecting: source)) → \(String(reflecting: new))")
                else { break }
                source = new
                previous = next
            }
        }
        print("[reuse] \(reused) of \(checked) re-reads were partial")
        // A re-read that always declines passes every check above. It must not.
        #expect(reused > checked / 3, "only \(reused) of \(checked) re-reads were partial")
    }

    /// `sameComparable` — which compares only what lies between the two strings' shared ends — always
    /// agrees with comparing them whole, through smart punctuation and with `structural` trimming.
    ///
    /// Mutation: cut anywhere, not only between two plain letters, and a `--` split across the cut
    /// or a space beside a break disagrees.
    @Test func comparingTheMiddleAgreesWithComparingTheWhole() {
        let pieces = ["a", "b", "1", " ", "\n", "\u{2028}", "-", "--", "–", "—", "...", "…", "'", "’", "\"", "“",
                      "é", "e\u{301}", "中", "😀", "\t"]
        var disagreements = 0
        for seed in 1...UInt64(20_000) {
            var r = SplitMix(seed: seed &+ 0xC0DE)
            func text() -> String { (0..<r.int(0...12)).map { _ in pieces[r.int(0...pieces.count - 1)] }.joined() }
            let shared = text(), tail = text()
            let a = shared + text() + tail, b = shared + text() + tail
            for structural in [false, true] {
                let whole = PreviewEditTranslator.comparable(a, structural: structural)
                    == PreviewEditTranslator.comparable(b, structural: structural)
                if PreviewEditTranslator.sameComparable(a, b, structural: structural) != whole {
                    disagreements += 1
                    if disagreements <= 3 {
                        Issue.record("disagree on \(String(reflecting: a)) and \(String(reflecting: b)), structural \(structural)")
                    }
                }
            }
        }
        #expect(disagreements == 0)
    }

    // MARK: The comparison

    @discardableResult
    static func expectSame(_ a: MarkdownProjection, _ b: MarkdownProjection, _ what: String,
                           sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let checks: [(String, Bool)] = [
            ("source", a.source == b.source),
            ("blocks", a.blocks == b.blocks),
            ("segments", a.segments == b.segments),
            ("spans", a.spans == b.spans),
            ("rendered", PreviewAttributeShape.same(a.rendered, b.rendered)),
            // A re-read keeps a list's NSTextList where it can: its items must still be one list.
            ("lists", sameLists(a.rendered, b.rendered)),
        ]
        for (name, same) in checks where !same {
            var detail = ""
            if name == "blocks" {
                let i = a.blocks.indices.first { $0 >= b.blocks.count || a.blocks[$0] != b.blocks[$0] }
                    ?? a.blocks.count
                detail = " — first at block \(i): \(i < a.blocks.count ? String(describing: a.blocks[i]) : "none") vs whole \(i < b.blocks.count ? String(describing: b.blocks[i]) : "none")"
            }
            Issue.record("\(name) differ from a whole re-read\(detail): \(what)", sourceLocation: sourceLocation)
            return false
        }
        return true
    }

    /// Whether the two group their characters into lists the same way — the identity TextKit
    /// numbers by, which a comparison by shape cannot see.
    static func sameLists(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard a.length == b.length else { return false }
        var forward: [ObjectIdentifier: ObjectIdentifier] = [:]
        var backward: [ObjectIdentifier: ObjectIdentifier] = [:]
        var same = true
        var at = 0
        while at < a.length, same {
            var left = NSRange(), right = NSRange()
            let x = (a.attribute(.paragraphStyle, at: at, effectiveRange: &left) as? NSParagraphStyle)?.textLists ?? []
            let y = (b.attribute(.paragraphStyle, at: at, effectiveRange: &right) as? NSParagraphStyle)?.textLists ?? []
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) {
                let i = ObjectIdentifier(p), j = ObjectIdentifier(q)
                if forward[i, default: j] != j || backward[j, default: i] != i { same = false }
                forward[i] = j
                backward[j] = i
            }
            at = min(NSMaxRange(left), NSMaxRange(right))
        }
        return same
    }
}
