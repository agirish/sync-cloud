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
        let reused = try #require(try? old.reread(new).get(), "declined a plain keystroke")
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
            let reused = try #require(try? old.reread(new).get(), "declined \(target)")
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
        // A definition wherever a paragraph can start: in a list, in a quote, indented, nested,
        // with a label over two lines, a label that looks like a time — and one made by an edit.
        ("See [x][r].\n\nA.\n\nB.\n\n- [r]: /one", "/one", "/two"),
        ("See [x][r].\n\nA.\n\nB.\n\n> [r]: /one", "/one", "/two"),
        ("See [x][r].\n\nA.\n\nB.\n\n   [r]: /one", "/one", "/two"),
        ("See [x][r].\n\nA.\n\nB.\n\n1. > * [r]: /one", "/one", "/two"),
        ("See [x][r s].\n\nA.\n\nB.\n\n[r\ns]: /one", "/one", "/two"),
        ("See [x][r s].\n\nA.\n\nB.\n\n> [r\n> s]: /one", "/one", "/two"),
        ("See [x][10:30].\n\nA.\n\nB.\n\n[10:30]: /one", "/one", "/two"),
        ("See [x][r].\n\nA.\n\nB.\n\nr]: /one", "r]:", "[r]:"),
        ("See [x][r].\n\nA.\n\nB.\n\n[[r]: /one", "[[r]", "[r]"),
        ("See [x][r\\]].\n\nA.\n\nB.\n\n[r\\]]: /one", "/one", "/two"),
        // Everything deleted, and the last block.
        ("Only.", "Only.", ""),
        ("One.\n\nTwo.", "\n\nTwo.", ""),
        // A table straight under a paragraph takes its last line for a header, and the parser gives
        // what is left of the paragraph no place: the two are re-read together (2026-10-08).
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "| c | d |", "| cc | d |"),
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "Intro.", "Intro!"),
        ("Intro.\n\nHere it is:\nand more\n| a | b |\n|---|---|\n| c | d |\n\nEnd.", "End.", "End!"),
        ("Intro.\n\nHere it is:\n| a | b |\n|---|---|\n| c | d |\n\nMiddle.\n\nEnd.", "Middle.", "Middle!"),
        // A list whose item has a heading the parser gives no place: the list waits for the block
        // after it, and the two are re-read from the list's first line, not the next block's (seed
        // 1619 of the wider documents, 2026-10-09: the list was dropped).
        ("***\n1. #\n\n*1)** **&amp;**\n   1. &amp;\n2. #tag **1)** **&amp;**", "1. &amp;", "1| x |;"),
        ("Intro.\n\n- #\n\nPara.\n\nMore.\n\nEnd.", "More.", "More!"),
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

    /// **A `]:` that cannot define anything is re-read in part** (review, 2026-10-09) — any `]:` at
    /// all used to send every keystroke the whole way: code in a fence, an Obsidian `[[Page]]:`, a
    /// subscript in a sentence. A definition starts a line, with a label free of brackets.
    ///
    /// Mutation: go back to any `]:`, and each of these declines.
    @Test(arguments: ["```python\nif row[0]:\n    pass\n```", "[[Page]]: status", "Take a[1]: b, then c.",
                      "Host [::1]:8080 is local.", "- [ ] task: soon", "    if a[0]: pass"])
    func aBracketColonThatCannotDefineIsReReadInPart(block: String) throws {
        let source = "Intro.\n\n\(block)\n\nMiddle words.\n\nEnd."
        let old = MarkdownProjection.project(source)
        let new = source.replacingOccurrences(of: "Middle", with: "Middle!")
        let reused = try #require(try? old.reread(new).get(), "declined a keystroke beside \(String(reflecting: block))")
        Self.expectSame(reused, MarkdownProjection.project(new), block)
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
                                  "![i](p.png)", "]:", "[r]: http://x", "[x][r]", "[r]\n\n",
                                  "\n- ", "\n> ", "  - ", "\n```\n", "\n|---|---|\n", "\n===\n", "<div>\n",
                                  "\n</div>\n", "\n---\n"]

    /// **Every path a re-read can take is taken, and each is held to the whole re-read** (review,
    /// 2026-10-09): `reused > checked / 3` alone passed with any one path never taken — the block
    /// after the edit always declining, say. And the documents are wider than the translator's:
    /// half the seeds nest lists, put lists in quotes, set blocks straight under one another, open
    /// HTML, leave a fence open for an edit to close, underline headings, and lose a table's
    /// delimiter row.
    @Test func randomEditsReadAsTheWholeDocumentWould() {
        var paths: [String: Int] = [:]
        var checked = 0
        var byHand = 0
        for seed in Self.seeds {
            var random = SplitMix(seed: seed &+ 0xB10C)
            var source = seed % 2 == 0
                ? (0..<random.int(1...3)).map { _ in PreviewEditPropertyTests.document(&random) }.joined(separator: "\n\n")
                : Self.document(&random)
            var previous = MarkdownProjection.project(source)
            // A chain: each step starts from the last step's re-read, never from a fresh one.
            for step in 0..<random.int(1...4) {
                let length = (source as NSString).length
                let at = random.int(0...length)
                let cut = random.int(0...2) == 0 ? min(length - at, random.int(1...6)) : 0
                let text = random.int(0...3) == 0 ? "" : Self.inserts[random.int(0...Self.inserts.count - 1)]
                let new = (source as NSString).replacingCharacters(in: NSRange(location: at, length: cut), with: text)
                // As the session makes it: in part where it can be, else whole with each list kept.
                let next = MarkdownProjection.project(new, after: previous)
                paths[Self.path(next.reuse), default: 0] += 1
                let full = MarkdownProjection.project(new)
                checked += 1
                let what = "seed \(seed) step \(step): \(String(reflecting: source)) → \(String(reflecting: new))"
                guard Self.expectSame(next, full, what) else { break }
                if full.rendered.length <= Self.byHandLimit { byHand += 1 }
                source = new
                previous = next
            }
        }
        let partial = paths.filter { $0.key.hasPrefix("partial") }.values.reduce(0, +)
        print("[reuse] \(partial) of \(checked) re-reads were partial, \(byHand) also compared by hand: \(paths.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "; "))")
        guard Self.seeds.count > 1 else { return }
        // A re-read that always declines passes every check above. It must not.
        #expect(partial > checked / 3, "only \(partial) of \(checked) re-reads were partial")
        for path in ["unchanged", "partial", "partial, first", "partial, last", "partial, after front matter",
                     "whole(the edit reached the block after it)", "whole(definition)", "whole(may open front matter)"] {
            #expect(paths[path, default: 0] > 0, "no re-read took the path \(path)")
        }
        #expect(byHand > checked / 2, "only \(byHand) of \(checked) compared by hand")
    }

    /// The comparison by hand can tell a difference — a check that cannot fail checks nothing.
    @Test func theComparisonByHandSeesEachKindOfDifference() {
        let base = MarkdownProjection.project("# Title\n\n- a\n- b\n\nWords [link](u).").rendered
        #expect(Self.differenceByHand(base, base) == nil)
        #expect(Self.differenceByHand(base, MarkdownProjection.project("# Title\n\n- a\n- b\n\nWords [link](u).").rendered) == nil,
                "two projections of one text are the same")
        func changed(_ body: (NSMutableAttributedString) -> Void) -> String? {
            let copy = NSMutableAttributedString(attributedString: base)
            body(copy)
            return Self.differenceByHand(base, copy)
        }
        let at = (base.string as NSString).range(of: "a\n")
        #expect(changed { text in
            let style = (text.attribute(.paragraphStyle, at: at.location, effectiveRange: nil) as! NSParagraphStyle)
                .mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing += 1
            text.addAttribute(.paragraphStyle, value: style, range: at)
        } != nil, "paragraph spacing")
        #expect(changed { text in
            let style = (text.attribute(.paragraphStyle, at: at.location, effectiveRange: nil) as! NSParagraphStyle)
                .mutableCopy() as! NSMutableParagraphStyle
            style.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
            text.addAttribute(.paragraphStyle, value: style, range: at)
        } != nil, "a list's marker")
        #expect(changed { $0.addAttribute(.font, value: NSFont.systemFont(ofSize: 31), range: NSRange(location: 0, length: 1)) } != nil,
                "a font's size")
        #expect(changed { $0.removeAttribute(.link, range: NSRange(location: base.length - 3, length: 1)) } != nil,
                "a link taken away")
    }

    /// A re-read's path, for counting.
    static func path(_ reuse: MarkdownProjection.Reuse) -> String {
        switch reuse {
        case .unchanged: return "unchanged"
        case .whole(let why): return "whole(\(why))"
        case .partial(let left, let right, let frontMatter):
            return "partial" + (left ? "" : ", first") + (right ? "" : ", last") + (frontMatter ? ", after front matter" : "")
        }
    }

    // MARK: Wider documents

    private static let words = ["salt", "the", "Café", "中文", "😀", "a*b", "x", "don't", "&amp;", "\\*", "f(x)",
                                "2.", "#tag", "1)", "a > b"]

    private static func inline(_ r: inout SplitMix) -> String {
        (0..<r.int(1...4)).map { _ in
            let word = words[r.int(0...words.count - 1)]
            switch r.int(0...6) {
            case 0: return "**\(word)**"
            case 1: return "*\(word)*"
            case 2: return "[\(word)](u)"
            case 3: return "`\(word)`"
            default: return word
            }
        }.joined(separator: " ")
    }

    /// A document of the shapes the translator's generator leaves out.
    static func document(_ r: inout SplitMix) -> String {
        var blocks: [String] = []
        if r.int(0...4) == 0 { blocks.append("---\ntitle: x\n---") }
        for _ in 0..<r.int(2...8) {
            let a = inline(&r), b = inline(&r)
            switch r.int(0...19) {
            case 0: blocks.append(String(repeating: "#", count: r.int(1...3)) + " " + a)
            case 1: blocks.append("- \(a)\n  - \(b)\n    - \(a)\n- \(b)")
            case 2: blocks.append("1. \(a)\n   1. \(b)\n2. \(a)")
            case 3: blocks.append("> - \(a)\n> - \(b)\n>\n> \(a)")
            case 4: blocks.append("- \(a)\n\n  > \(b)\n- \(a)")
            case 5: blocks.append("> \(a)\n> > \(b)")
            case 6: blocks.append("<div>\n\(a)\n</div>")
            case 7: blocks.append("<!-- \(a) -->")
            case 8: blocks.append("```\n\(a)\n```")
            // A fence on its own: it opens, and runs on to the next — or an edit closes it.
            case 9: blocks.append("```")
            case 10: blocks.append("\(a)\n===")
            case 11: blocks.append("\(a)\n---")
            case 12: blocks.append("| a | b |\n|---|---|\n| \(a) | x |")
            // No delimiter row: a paragraph, until an edit gives it one.
            case 13: blocks.append("| a | b |\n| \(a) | x |")
            case 14: blocks.append("[r]: /u")
            case 15: blocks.append("    code \(a)")
            case 16: blocks.append("***")
            case 17: blocks.append("- [ ] \(a)\n- [x] \(b)")
            case 18: blocks.append("![i](p.png)")
            default: blocks.append("\(a)\n\(b)")
            }
        }
        // Most blocks apart, some straight under the one before: a list or a table under a
        // paragraph, a heading's lazy line, a fence closing on the next block.
        var text = blocks[0]
        for block in blocks.dropFirst() { text += (r.int(0...2) == 0 ? "\n" : "\n\n") + block }
        return text
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
        var checks: [(String, Bool)] = [
            ("source", a.source == b.source),
            ("blocks", a.blocks == b.blocks),
            ("segments", a.segments == b.segments),
            ("spans", a.spans == b.spans),
            ("rendered", PreviewAttributeShape.same(a.rendered, b.rendered)),
            // A re-read keeps a list's NSTextList where it can: its items must still be one list.
            ("lists", sameLists(a.rendered, b.rendered)),
        ]
        // And by hand, on a short one: character by character, every attribute read as it stands —
        // no runs, no memo — so a fault in the comparison the production code uses shows here.
        if a.rendered.length <= byHandLimit, b.rendered.length <= byHandLimit,
           let why = differenceByHand(a.rendered, b.rendered) {
            checks.append(("rendered by hand (\(why))", false))
        }
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

    /// The longest rendering compared character by character.
    static let byHandLimit = 1_200

    /// Where `a` and `b` differ, read character by character with the plainest rules: the same
    /// keys; a paragraph style property by property, its lists by what they draw; a font by name
    /// and size; an attachment by being there; anything else `isEqual`. `nil` where they agree.
    static func differenceByHand(_ a: NSAttributedString, _ b: NSAttributedString) -> String? {
        guard a.string == b.string else { return "text" }
        for at in 0..<a.length {
            let x = a.attributes(at: at, effectiveRange: nil), y = b.attributes(at: at, effectiveRange: nil)
            guard Set(x.keys) == Set(y.keys) else {
                return "keys at \(at): \(x.keys.map(\.rawValue).sorted()) against \(y.keys.map(\.rawValue).sorted())"
            }
            for (key, value) in x {
                let other = y[key]!
                let same: Bool
                switch key {
                case .attachment: same = true
                case .paragraphStyle: same = sameStyle(value as! NSParagraphStyle, other as! NSParagraphStyle)
                case .font:
                    let f = value as! NSFont, g = other as! NSFont
                    same = f.fontName == g.fontName && f.pointSize == g.pointSize
                default: same = (value as AnyObject).isEqual(other)
                }
                if !same { return "\(key.rawValue) at \(at)" }
            }
        }
        return nil
    }

    private static func sameStyle(_ a: NSParagraphStyle, _ b: NSParagraphStyle) -> Bool {
        a.alignment == b.alignment && a.lineSpacing == b.lineSpacing && a.paragraphSpacing == b.paragraphSpacing
            && a.paragraphSpacingBefore == b.paragraphSpacingBefore && a.headIndent == b.headIndent
            && a.firstLineHeadIndent == b.firstLineHeadIndent && a.tailIndent == b.tailIndent
            && a.minimumLineHeight == b.minimumLineHeight && a.maximumLineHeight == b.maximumLineHeight
            && a.lineHeightMultiple == b.lineHeightMultiple && a.defaultTabInterval == b.defaultTabInterval
            && a.lineBreakMode == b.lineBreakMode && a.baseWritingDirection == b.baseWritingDirection
            && a.tabStops.map { "\($0.location) \($0.alignment.rawValue)" } == b.tabStops.map { "\($0.location) \($0.alignment.rawValue)" }
            && a.textLists.map { "\($0.markerFormat.rawValue) \($0.startingItemNumber) \($0.listOptions.rawValue)" }
                == b.textLists.map { "\($0.markerFormat.rawValue) \($0.startingItemNumber) \($0.listOptions.rawValue)" }
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
