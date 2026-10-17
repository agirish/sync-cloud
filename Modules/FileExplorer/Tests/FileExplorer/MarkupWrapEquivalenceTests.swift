import Testing
import Foundation
@testable import FileExplorer

/// **The inline verbs against the `wrap` they replaced, over every selection of a corpus** — which
/// is what makes "the refactor changed nothing but the one thing it meant to" a measurement.
///
/// TE52 split `wrap`'s "already wrapped?" test out into `wrapState`, so the format bar could light
/// a button by the very test its press uses, and then gave the non-nesting delimiters (Bold,
/// Strikethrough, Inline Code) one new rule: a run that holds the delimiter again is two spans,
/// not one, and is not unwrapped. `OldWrap` below is `wrap` as it stood on `main` before either,
/// copied verbatim. Every edit must match it — except exactly the runs the new rule names, where
/// the old code turned two spans inside out and the new one adds a pair instead.
///
/// `MarkupPrefixLinesEquivalenceTests` does the same for the line verbs.
@Suite struct MarkupWrapEquivalenceTests {

    /// `MarkdownEdits.wrap` as it was before TE52, verbatim but for its name.
    enum OldWrap {
        static func wrap(_ text: String, _ selection: NSRange, with delimiter: String,
                         guardingAgainst neighbour: String? = nil) -> MarkupEdit {
            let ns = text as NSString
            let width = (delimiter as NSString).length
            let selected = ns.substring(with: selection)
            if (selected as NSString).length >= width * 2,
               selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
                let inner = (selected as NSString).substring(
                    with: NSRange(location: width, length: (selected as NSString).length - width * 2))
                return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inner),
                                  selection: NSRange(location: selection.location,
                                                     length: (inner as NSString).length))
            }
            let before = NSRange(location: selection.location - width, length: width)
            let after = NSRange(location: NSMaxRange(selection), length: width)
            if selection.location >= width, NSMaxRange(after) <= ns.length,
               ns.substring(with: before) == delimiter, ns.substring(with: after) == delimiter,
               !isNeighboured(ns, before: before, after: after, by: neighbour) {
                let outer = NSRange(location: before.location, length: width * 2 + selection.length)
                return MarkupEdit(text: ns.replacingCharacters(in: outer, with: selected),
                                  selection: NSRange(location: before.location, length: selection.length))
            }
            let wrapped = delimiter + selected + delimiter
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: wrapped),
                              selection: NSRange(location: selection.location + width,
                                                 length: selection.length))
        }

        private static func isNeighboured(_ ns: NSString, before: NSRange, after: NSRange,
                                          by neighbour: String?) -> Bool {
            guard let neighbour else { return false }
            let width = (neighbour as NSString).length
            let outerBefore = NSRange(location: before.location - width, length: width)
            if outerBefore.location >= 0, ns.substring(with: outerBefore) == neighbour { return true }
            let outerAfter = NSRange(location: NSMaxRange(after), length: width)
            if NSMaxRange(outerAfter) <= ns.length, ns.substring(with: outerAfter) == neighbour {
                return true
            }
            return false
        }
    }

    /// The old delimiters, as `apply` passed them before TE52.
    static let oldMarks: [(MarkupVerb, String, String?)] = [
        (.bold, "**", nil), (.italic, "*", "*"), (.strikethrough, "~~", nil), (.inlineCode, "`", nil),
    ]

    static let corpus = [
        "", "a", "**bold**", "say **loud** now", "*it*", "a **b** c", "~~x~~", "`c`", "***x***",
        "a*b*c", "**Warning** read the **docs**", "`a` and `b`", "~~a~~ b ~~c~~", "*a **b** c*",
        "****", "**a**b**", "x ``y`` z", "é **ü** ñ", "line\n**two**\nthree", "~~~~", "**",
    ]

    @Test func everyInlineEditMatchesTheOldWrapButForTwoSpansTakenForOne() {
        var same = 0
        var changed = 0
        for text in Self.corpus {
            let ns = text as NSString
            for location in 0...ns.length {
                for length in 0...(ns.length - location) {
                    let selection = NSRange(location: location, length: length)
                    for (verb, delimiter, neighbour) in Self.oldMarks {
                        let old = OldWrap.wrap(text, selection, with: delimiter, guardingAgainst: neighbour)
                        guard let new = MarkdownEdits.apply(verb, to: text, selection: selection) else {
                            Issue.record("\(verb.title) over “\(text)” \(selection) answered nil")
                            continue
                        }
                        if new == old { same += 1; continue }
                        changed += 1
                        // **An inline verb wraps the words, line by line (FMT-10)**: spaces and line
                        // breaks at the selection's ends are left out, and a selection over lines is
                        // cut at each. One run is the old wrap of that run; several only add or take
                        // delimiters, never words.
                        let runs = MarkdownEdits.inlineRuns(selection, in: ns)
                        if runs != [selection] {
                            if runs.count == 1 {
                                let trimmed = OldWrap.wrap(text, runs[0], with: delimiter, guardingAgainst: neighbour)
                                #expect(new.text == trimmed.text || verb == .italic || verb == .inlineCode,
                                        "\(verb.title) over “\(text)” \(selection) is not the wrap of its words: “\(new.text)”")
                            } else {
                                let words = { (s: String) in s.filter { !"*~`".contains($0) } }
                                #expect(words(new.text) == words(text),
                                        "\(verb.title) over “\(text)” \(selection) changed words: “\(new.text)”")
                            }
                            continue
                        }
                        // **Italic reads runs of stars now (FMT-4, FMT-11)**, where the old code
                        // asked only whether one more star stood beside the selection. Its edits
                        // differ wherever a star belongs to a bold pair — `**loud**` selected whole
                        // was demoted to `*loud*`, `***x***` got an eighth star. Held to what the
                        // new reading promises instead: an Italic press that takes stars away keeps
                        // the words and every bold character; one that adds them destroys nothing.
                        // **Code reads spans as CommonMark pairs them (FMT-20)**: a run opens one
                        // and the next run of the same length closes it, and a wrap around
                        // backticks uses a longer run. Anywhere a backtick is on the line, the old
                        // one-backtick reading may differ; held to the same promise as Italic's.
                        if verb == .inlineCode, ns.substring(with: ns.lineRange(for: selection)).contains("`") {
                            if (new.text as NSString).length < ns.length {
                                #expect(Self.rendered(new.text).plain == Self.rendered(text).plain,
                                        "Code over “\(text)” \(selection) changed the words: “\(new.text)”")
                            }
                            continue
                        }
                        if verb == .italic {
                            if (new.text as NSString).length < ns.length {
                                let was = Self.rendered(text), now = Self.rendered(new.text)
                                #expect(now.plain == was.plain && now.bold == was.bold,
                                        "Italic over “\(text)” \(selection) took more than italic away: “\(new.text)”")
                            }
                            continue
                        }
                        // The one deliberate difference: a non-nesting delimiter, a run the old code
                        // unwrapped (its result was shorter), and the run holding the delimiter again.
                        let selected = ns.substring(with: selection)
                        let width = (delimiter as NSString).length
                        let inner = (selected as NSString).length >= 2 * width && selected.hasPrefix(delimiter) && selected.hasSuffix(delimiter)
                            ? String((selected as NSString).substring(with: NSRange(location: width, length: (selected as NSString).length - 2 * width)))
                            : selected
                        let oldUnwrapped = (old.text as NSString).length < ns.length
                        #expect(oldUnwrapped && inner.contains(delimiter),
                                "\(verb.title) over “\(text)” \(selection) changed: “\(old.text)” → “\(new.text)”")
                        // …and the new answer is a wrap, which destroys nothing.
                        #expect((new.text as NSString).length > ns.length,
                                "\(verb.title) over “\(text)” \(selection) neither matches the old edit nor adds a pair")
                    }
                }
            }
        }
        // 4,000, not the 5,000 it was: FMT-10 moved every selection with a space or a line break at
        // an end (about 650 of them) to the rule above.
        #expect(same > 4_000, "only \(same) edits matched — the sweep is near-vacuous")
        #expect(changed > 0, "nothing changed — the corpus no longer holds a run of two spans, so the rule is untested")
        print("[wrap-equivalence] \(same) edits match the old wrap · \(changed) are the two-span rule")
    }

    /// The words a buffer renders and how many of their characters are bold — what an Italic press
    /// that takes stars away must leave as it found them.
    static func rendered(_ text: String) -> (plain: String, bold: Int) {
        var plain = ""
        var bold = 0
        for block in MarkdownBlocks.blocks(from: text) {
            let runs: [MarkdownRun]
            switch block.kind {
            case .paragraph(let line), .heading(_, let line), .listItem(_, let line): runs = line.runs
            default: runs = []
            }
            for run in runs {
                plain += run.text
                if run.isBold { bold += run.text.count }
            }
            plain += "\n"
        }
        return (plain, bold)
    }

    /// **The two-span rule, by name** — the cases the equivalence sweep only counts. Bold over two
    /// bold spans and the text between adds a pair rather than turning them inside out, and the bar
    /// does not light for it; Italic around a bold word still unwraps, because italic nests.
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
        // starts with a backtick (FMT-20) — not one more backtick each side, which closed at once.
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
