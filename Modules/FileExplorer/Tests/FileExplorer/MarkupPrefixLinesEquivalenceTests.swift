import Testing
import Foundation
@testable import FileExplorer

/// **The line-prefix verbs, held against the algorithm they replaced.**
///
/// `prefixLines` used to rebuild the whole buffer once per selected line —
/// `result = result.replacingCharacters(in:with:)` inside the loop — which is O(n) per line and so
/// O(n · lines) for one press. Quoting a 500-line section of a 200 KB note copied about 100 MB. The
/// rewrite assembles the covered lines once and splices them in, which is two copies of the buffer
/// however many lines are selected.
///
/// That is a performance change with no behaviour attached to it, and "no behaviour attached" is a
/// claim rather than an observation — so the old algorithm is written out below, verbatim, and both
/// are run over every combination of a corpus and the five line verbs. It shares the helpers with
/// the real one (`stripping`, `applying`, `selectionAfter`), so what is being compared is the loop
/// and nothing else, which is the only thing that changed.
@Suite struct MarkupPrefixLinesEquivalenceTests {

    /// The loop as it stood before the rewrite.
    private static func oldPrefixLines(_ text: String, _ selection: NSRange,
                                       _ prefix: MarkdownEdits.LinePrefix) -> MarkupEdit? {
        let ns = text as NSString
        let lines = MarkdownEdits.lineRanges(covering: selection, in: ns)
        guard !lines.isEmpty else { return nil }

        let isRemoval: Bool
        if case .heading(let level) = prefix, level <= 0 {
            isRemoval = true
        } else {
            isRemoval = lines.allSatisfy { range in
                let line = ns.substring(with: range)
                return line.trimmingCharacters(in: .whitespaces).isEmpty
                    || (try? NSRegularExpression(pattern: prefix.appliedPattern))
                        .flatMap { regex in
                            regex.firstMatch(in: line,
                                             range: NSRange(location: 0,
                                                            length: (line as NSString).length))?.range
                        } != nil
            }
        }

        var result = text
        var delta = 0
        var numbered = 0
        for range in lines {
            let shifted = NSRange(location: range.location + delta, length: range.length)
            let line = (result as NSString).substring(with: shifted)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rewritten = isRemoval ? MarkdownEdits.stripping(prefix, from: line)
                                      : MarkdownEdits.applying(prefix, to: line, at: numbered)
            numbered += 1
            result = (result as NSString).replacingCharacters(in: shifted, with: rewritten)
            delta += (rewritten as NSString).length - shifted.length
        }
        guard result != text else { return nil }
        return MarkupEdit(text: result,
                          selection: MarkdownEdits.selectionAfter(selection, delta: delta,
                                                                  in: result))
    }

    /// Documents chosen for the shapes that make the two loops differ if anything does: blank lines
    /// inside a selection (skipped, so the numbering and the delta both step oddly), prefixes that
    /// already exist (a removal), mixed prefixes (a completion), lines of different lengths (the
    /// delta accumulates), CRLF terminators, and a last line with no terminator at all.
    private static let corpus: [String] = [
        "",
        "one",
        "one\n",
        "one\ntwo\nthree\n",
        "one\ntwo\nthree",
        "- one\n- two\n- three\n",
        "- one\nplain\n- three\n",
        "# Heading\nbody text\n## Second\n",
        "> quoted\n> also quoted\n",
        "- [ ] task\n- [x] done\n- plain bullet\n",
        "1. first\n2. second\n10. tenth\n",
        "a\n\nb\n\n\nc\n",
        "   \nindented\n\t\nlast",
        "one\r\ntwo\r\nthree\r\n",
        "one\r\n\r\ntwo",
        "😀 emoji line\nplain\n😀\n",
        "café\u{0301}\nnaïve\n",
        String(repeating: "a line of prose here\n", count: 40),
    ]

    private static let prefixes: [(name: String, prefix: MarkdownEdits.LinePrefix)] = [
        ("heading 1", .heading(1)), ("heading 3", .heading(3)), ("body", .heading(0)),
        ("bullet", .bullet), ("numbered", .numbered), ("task", .task), ("quote", .quote),
    ]

    /// Every corpus document, every verb, and a spread of selections over each — including the
    /// empty ones at the very start and the very end, which is where a covering-range rewrite is
    /// most likely to be off by one.
    @Test func theRewriteAgreesWithTheAlgorithmItReplaced() {
        var compared = 0
        var changed = 0
        for text in Self.corpus {
            let length = (text as NSString).length
            var selections: [NSRange] = [NSRange(location: 0, length: 0),
                                         NSRange(location: length, length: 0),
                                         NSRange(location: 0, length: length)]
            // A caret at every offset, and a run from every offset to the end — enough to land
            // inside terminators, inside surrogate pairs and across blank lines.
            for start in stride(from: 0, through: length, by: max(1, length / 12)) {
                selections.append(NSRange(location: start, length: 0))
                selections.append(NSRange(location: start, length: length - start))
                if start + 3 <= length { selections.append(NSRange(location: start, length: 3)) }
            }
            for (name, prefix) in Self.prefixes {
                for selection in selections {
                    let old = Self.oldPrefixLines(text, selection, prefix)
                    let new = MarkdownEdits.prefixLines(text, selection, prefix)
                    compared += 1
                    if new != nil { changed += 1 }
                    let report = "\(name) over \(text.debugDescription) at \(selection):"
                        + " was \(String(describing: old)), now \(String(describing: new))"
                    #expect(old == new, "\(report)")
                }
            }
        }
        // **The positive control.** Two functions that both returned `nil` for everything would
        // agree perfectly, so the comparison only means something if the verbs really did work.
        #expect(compared > 2000, "the corpus barely exercised anything: \(compared) comparisons")
        #expect(changed > compared / 4,
                "almost nothing was rewritten — \(changed) of \(compared) produced an edit")
    }

    /// The one property the rewrite depends on and the old loop got for free: **nothing outside the
    /// lines the selection touches may change.** The new implementation splices a single covering
    /// range, so if a verb could ever reach past the last covered line this would be the failure.
    @Test func nothingOutsideTheTouchedLinesIsRewritten() {
        let text = "alpha\nbravo\ncharlie\ndelta\necho\n"
        let ns = text as NSString
        // A selection sitting entirely inside "bravo" and "charlie".
        let selection = NSRange(location: 8, length: 6)
        for (name, prefix) in Self.prefixes {
            guard let edit = MarkdownEdits.prefixLines(text, selection, prefix) else { continue }
            #expect(edit.text.hasPrefix("alpha\n"), "\(name) rewrote the line above the selection")
            #expect(edit.text.hasSuffix("delta\necho\n"),
                    "\(name) rewrote the lines below the selection")
            #expect(ns.length > 0)
        }
    }
}
