import Testing
import Foundation
@testable import FileExplorer

/// The translator's property test (TE67 §6.1): random documents, random chains of edits, and the
/// things that must hold for every edit the translator accepts.
///
/// 1. **What the person did is what renders** — the new rendering is what a reader expects to see:
///    the old one with the edit made, read by Markdown's own rules (``reading(after:in:)``) — for
///    typing, deleting and pasting; Return and ⇧Return add their break; Tab, a style, a tick and a
///    Replace All are checked for the characters they keep or change.
/// 2. **Nothing outside the edit moves** — the edits are in bounds and do not overlap, and the new
///    source is exactly the old one with them applied.
/// 3. **The caret lands after the typed text**, or where a deletion was.
/// 4. **Undo restores the source byte for byte.**
///
/// A refused edit changes nothing by construction: a refusal carries no edits. **What must NOT be
/// refused is not this test's to see** — it counts refusals, and an edit refused every time it is
/// tried passes it forever. `PreviewEditMustAcceptTests` holds the natural edits that must be
/// written, with the source each must leave.
///
/// Seeded, and the failing seed is in the message: `TE67_PROPERTY_SEED=<n>` replays one document.
/// `TE67_PROPERTY_ITERATIONS` raises the count (§6.1: 50,000 locally); the default is CI's.
@Suite struct PreviewEditPropertyTests {

    private static var iterations: Int {
        ProcessInfo.processInfo.environment["TE67_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 2_000
    }

    @Test func everyAcceptedEditKeepsItsPromises() {
        let seeds: [UInt64] = ProcessInfo.processInfo.environment["TE67_PROPERTY_SEED"]
            .flatMap(UInt64.init).map { [$0] } ?? Array(1...UInt64(Self.iterations))
        var applied = 0
        var refused = 0
        var kinds: [String: Int] = [:]
        for seed in seeds {
            var random = SplitMix(seed: seed)
            var source = Self.document(&random)
            // A chain: each edit made on the projection the one before left, as a person types on.
            for step in 0..<random.int(1...3) {
                let p = MarkdownProjection.project(source)
                let (edit, context) = Self.edit(&random, in: p)
                let all = random.int(0...14) == 0 ? Self.replaceAll(&random, in: p) : nil
                let outcome = all.map { PreviewEditTranslator.translateAll($0, in: p) }
                    ?? PreviewEditTranslator.translate(edit, in: p, context: context)
                guard case .apply(let result) = outcome else { refused += 1; continue }
                applied += 1
                kinds[all == nil ? Self.name(edit.action) : "replaceAll", default: 0] += 1
                let where_ = "seed \(seed) step \(step), \(all.map { "Replace All \($0)" } ?? "\(edit) \(context)"), source \(String(reflecting: source))"
                Self.check(result, of: all.map { _ in nil } ?? edit, all: all, context: context, in: p, where_)
                source = result.source
            }
        }
        print("[property] \(applied) of \(applied + refused) edits applied, \(refused) refused: \(kinds.sorted { $0.key < $1.key })")
        // A harness that refuses everything passes every check above. It must not.
        #expect(applied > (applied + refused) / 4, "only \(applied) edits applied (\(refused) refused)")
    }

    private static func check(_ result: PreviewEditApplication, of edit: RenderedEdit?, all: [RenderedEdit]?,
                              context: PreviewEditContext, in p: MarkdownProjection, _ where_: String) {
        let source = p.source
        // 2. In bounds, not overlapping, and the whole change.
        let ordered = result.edits.sorted { $0.range.location < $1.range.location }
        #expect(ordered.allSatisfy { NSMaxRange($0.range) <= (source as NSString).length }, "\(where_)")
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location },
                "overlapping edits: \(where_)")
        #expect(PreviewEditTranslator.applied(result.edits, to: source) == result.source, "\(where_)")

        // 5. **Nothing outside the edited block changes** — the check that catches an edit which
        // renders right and means something else elsewhere. A table's edit may re-pad the table;
        // a deletion at a block's edge may take the break beside it, and an opened paragraph is
        // written after the block it opened after.
        // Not Tab's: it moves the item's own lines with it — its sub-lists and its code (TE54).
        if let edit, ![.tab, .backtab].contains(edit.action) {
            let reach = edit.action == .delete
                ? NSRange(location: max(0, edit.range.location - 1), length: edit.range.length + 2) : edit.range
            var touched = p.blocks.indices.filter {
                NSIntersectionRange(p.blocks[$0].rendered, reach).length > 0
                    || (p.blocks[$0].rendered.location <= reach.location && reach.location <= NSMaxRange(p.blocks[$0].rendered))
            }
            if let phantom = context.phantomAfterBlock { touched.append(phantom) }
            if !touched.isEmpty {
                // From its line's start: a list item's indent is before its source, and Tab moves it.
                let lo = touched.map { p.index.line(p.index.lineNumber(containing: p.blocks[$0].source.location))!.start }.min()!
                // The next block's start, which a whole block's removal runs up to.
                let hi = touched.map { $0 + 1 < p.blocks.count ? p.blocks[$0 + 1].source.location : NSMaxRange(p.blocks[$0].source) }.max()!
                for change in result.edits {
                    #expect(change.range.location >= lo - 1 && NSMaxRange(change.range) <= hi + 1,
                            "edit \(change) reaches outside the block(s) \(lo)..<\(hi): \(where_)")
                }
            }
        }

        // 6. Nothing typed becomes something Preview cannot edit — HTML, an unalignable block.
        func readOnly(_ q: MarkdownProjection) -> Int {
            q.blocks.filter { $0.readOnly != nil }.count
                + q.segments.filter { if case .readOnly = $0.kind { true } else { false } }.count
        }
        #expect(readOnly(result.projection) <= readOnly(p), "the edit made read-only text: \(where_)")

        // 4. Undo is exact.
        #expect(PreviewEditTranslatorTests.undo(result.edits, before: source, after: result.source)
                == source, "undo did not restore: \(where_)")

        // 1 and 3: what renders.
        let rendered = p.renderedString as NSString
        let after = result.projection.renderedString
        func same(_ a: String, _ b: String, structural: Bool = false) -> Bool {
            PreviewEditTranslator.comparable(a, structural: structural)
                == PreviewEditTranslator.comparable(b, structural: structural)
        }
        if let all {
            // Replace All: every match made, as each would be — an empty one reads as a deletion.
            var expected = rendered as String
            for match in all.sorted(by: { $0.range.location > $1.range.location }) {
                expected = (expected as NSString).replacingCharacters(in: match.range, with: match.text)
            }
            if all.allSatisfy({ !$0.text.isEmpty }) {
                #expect(same(after, expected), "rendered \(String(reflecting: after)): \(where_)")
            }
            return
        }
        guard var edit else { return }
        // One line pasted with its line break is that line.
        if edit.action == .paste, edit.text.last?.isNewline == true, !edit.text.dropLast().contains(where: \.isNewline) {
            edit.text.removeLast()
        }
        switch edit.action {
        case .typing, .paste, .delete:
            if context.phantomAfterBlock != nil {
                let at = context.phantomAfterBlock.map { NSMaxRange(p.blocks[$0].rendered) } ?? 0
                #expect(same(after, rendered.replacingCharacters(in: NSRange(location: at, length: 0), with: "\n" + edit.text)),
                        "rendered \(String(reflecting: after)): \(where_)")
                return
            }
            if edit.text.contains(where: \.isNewline) {
                // Several lines pasted into code: verbatim.
                #expect(same(after, rendered.replacingCharacters(in: edit.range, with: edit.text.replacingOccurrences(of: "\r\n", with: "\n"))),
                        "rendered \(String(reflecting: after)): \(where_)")
                return
            }
            let reading = Self.reading(after: edit, in: p)
            #expect(same(after, reading.text),
                    "rendered \(String(reflecting: after)), a reader expects \(String(reflecting: reading.text)): \(where_)")
            if after == reading.text {
                #expect(result.renderedSelection.location == reading.caret,
                        "caret at \(result.renderedSelection.location), not \(reading.caret): \(where_)")
            }
            // The two carets must agree: the source caret, mapped into the new rendering, may sit
            // no later than the rendered one — at most it is before markers that render nothing.
            let mapped = PreviewEditRules.renderedOffset(forSource: result.sourceSelection.location,
                                                         in: result.projection)
            #expect(abs(mapped - result.renderedSelection.location) <= 1,
                    "source caret maps to \(mapped), rendered caret \(result.renderedSelection.location): \(where_)")
        case .returnKey:
            // A split, a code line, or a list item carried on: one break where the caret was — or,
            // ending a list, the empty item's line gone.
            let broken = ["\n", "\n\u{FFFC}"].map { rendered.replacingCharacters(in: edit.range, with: $0) }
            #expect(broken.contains { same(after, $0, structural: true) } || after.count < rendered.length,
                    "rendered \(String(reflecting: after)): \(where_)")
        case .lineBreak:
            #expect(same(after, rendered.replacingCharacters(in: edit.range, with: "\u{2028}"), structural: true),
                    "rendered \(String(reflecting: after)): \(where_)")
        case .tab, .backtab, .format, .tickTask:
            // Indents, styles and boxes change how the text looks, never what it says — but a tab
            // typed in code, and a heading, list or quote verb's marker, are characters.
            let isCodeTab = edit.action == .tab && PreviewEditRules.block(at: edit.range.location, in: p)
                .map { p.blocks[$0].kind.isCode } == true
            if case .format(let verb) = edit.action, ![.bold, .italic, .strikethrough, .inlineCode].contains(verb) { return }
            if !isCodeTab {
                #expect(same(after, rendered as String, structural: true), "rendered \(String(reflecting: after)): \(where_)")
            }
        }
    }

    // MARK: The reader's expectation

    /// What a reader expects to see after a typed, pasted or deleted `edit`, and where the caret
    /// is: the rendering with the edit made, **read by Markdown's rules — derived here from the
    /// rendering itself, never from the translator's**, which this test exists to check.
    ///
    /// - A selection ending on a block's line break leaves the break; one that is exactly a block
    ///   and its break takes the block away.
    /// - Spaces at a line's edge — beside a break of any kind, a task's box, or either end — are
    ///   drawn as nothing. **Spaces in code are text**, and are kept; **so are spaces the rendering
    ///   already drew at an edge**, which Markdown keeps there — a link's text, `[ a](u)`
    ///   (2026-10-12, seed 49198: a deletion two lines away was read as taking one).
    /// - A line emptied in a paragraph leaves two breaks side by side, which would split it: one goes.
    /// - A paragraph emptied is gone: Markdown has none that is empty. Its heading, item and cell
    ///   neighbours stay, empty.
    static func reading(after edit: RenderedEdit, in p: MarkdownProjection) -> (text: String, caret: Int) {
        let rendered = p.renderedString as NSString
        var range = edit.range
        func kind(_ offset: Int) -> PreviewSegment.Kind? {
            p.segments.first { $0.rendered.location <= offset && offset < NSMaxRange($0.rendered) }?.kind
        }
        if range.length > 1, kind(NSMaxRange(range) - 1) == .blockBreak {
            let whole = p.blocks.indices.contains { b in
                guard p.blocks[b].rendered.location == range.location, b + 1 < p.blocks.count,
                      p.blocks[b + 1].rendered.location == NSMaxRange(range), p.blocks[b].readOnly == nil
                else { return false }
                switch p.blocks[b].kind {
                case .paragraph, .heading, .listItem: return true
                default: return false
                }
            }
            // A whole block taken away is exactly that: nothing is left at its edges to read.
            if edit.text.isEmpty && whole {
                return (rendered.replacingCharacters(in: range, with: ""), range.location)
            }
            range.length -= 1
        }
        let text = rendered.replacingCharacters(in: range, with: edit.text) as NSString
        let typed = (edit.text as NSString).length
        guard edit.text.isEmpty else { return (text as String, range.location + typed) }

        // What each character of the new text is, from where it came from.
        enum Class: Equatable { case looseSpace, text, lineBreak, edge, blockBreak(block: Int) }
        func old(_ i: Int) -> Int { i < range.location ? i : i + range.length }
        func classOf(_ j: Int) -> Class {
            guard let segment = p.segments.first(where: { $0.rendered.location <= j && j < NSMaxRange($0.rendered) })
            else { return .text }
            switch segment.kind {
            case .content:
                let code = p.blocks[segment.block].kind.isCode || segment.spans.contains { p.spans[$0].kind == .code }
                return rendered.character(at: j) == 0x20 && !code ? .looseSpace : .text
            case .softBreak, .hardBreak: return .lineBreak
            case .blockBreak: return .blockBreak(block: segment.block)
            case .codeNewline, .cellBreak, .rowBreak: return .edge
            case .decoration: return p.index.units[segment.source.location] == 0x5B ? .edge : .text   // a box
            case .readOnly: return .text
            }
        }
        func isEdge(_ c: Class) -> Bool { if case .text = c { false } else if case .looseSpace = c { false } else { true } }
        /// The positions in `classes` of the loose spaces touching an edge.
        func atEdges(_ classes: [Class]) -> Set<Int> {
            var found = Set<Int>()
            var i = 0
            while i < classes.count {
                guard classes[i] == .looseSpace else { i += 1; continue }
                var j = i
                while j < classes.count, classes[j] == .looseSpace { j += 1 }
                if i == 0 || isEdge(classes[i - 1]) || j == classes.count || isEdge(classes[j]) { found.formUnion(i..<j) }
                i = j
            }
            return found
        }
        let drawnAtEdges = atEdges((0..<rendered.length).map(classOf))
        let classes: [Class] = (0..<text.length).map { i in
            drawnAtEdges.contains(old(i)) ? .text : classOf(old(i))
        }
        // Loose spaces touching an edge.
        let drop = atEdges(classes)
        var kept = (0..<text.length).filter { !drop.contains($0) }
        // A line break beside another, or at a paragraph's edge: the earlier goes.
        func isBlockBreak(_ c: Class) -> Bool { if case .blockBreak = c { true } else { false } }
        kept = kept.enumerated().filter { n, index in
            guard classes[index] == .lineBreak else { return true }
            let next = n + 1 < kept.count ? classes[kept[n + 1]] : nil
            let previous = n > 0 ? classes[kept[n - 1]] : nil
            return !(next == nil || next == .lineBreak || next.map(isBlockBreak) == true
                     || previous == nil || previous.map(isBlockBreak) == true)
        }.map(\.element)
        // An emptied paragraph — one with text that this deletion took, all but spaces: the break
        // before it goes, or, for the first, the one after.
        func emptiedParagraph(_ b: Int) -> Bool {
            guard p.blocks.indices.contains(b), p.blocks[b].kind == .paragraph, p.blocks[b].rendered.length > 0
            else { return false }
            let block = p.blocks[b].rendered
            return (block.location..<NSMaxRange(block)).allSatisfy {
                NSLocationInRange($0, range) || rendered.character(at: $0) == 0x20
            }
        }
        kept = kept.enumerated().filter { n, index in
            guard case .blockBreak(let block) = classes[index] else { return true }
            let next = n + 1 < kept.count ? classes[kept[n + 1]] : nil
            let last = next == nil || next.map(isBlockBreak) == true
            return !(last && emptiedParagraph(block) || n == 0 && emptiedParagraph(block - 1))
        }.map(\.element)
        let units = kept.map { text.character(at: $0) }
        let reading = String(utf16CodeUnits: units, count: units.count)
        return (reading, kept.filter { $0 < range.location }.count)
    }

    // MARK: Documents

    private static let words = ["salt", "the", "pasta", "Café", "naïve", "中文", "😀", "snake_case",
                                "a*b", "x", "plenty", "don't", "1.5", "&amp;", "\\*", "Vec<T", "a > b",
                                "f(x)", "2.", "#tag", "a  b", "<b>", "![i](a)"]

    private static func inline(_ r: inout SplitMix) -> String {
        var parts: [String] = []
        for _ in 0..<r.int(1...5) {
            let word = words[r.int(0...words.count - 1)]
            switch r.int(0...9) {
            case 0: parts.append("**\(word)**")
            case 1: parts.append("*\(word)*")
            case 2: parts.append("`\(word.replacingOccurrences(of: "`", with: ""))`")
            case 3: parts.append("[\(word)](http://x.y)")
            case 4: parts.append("~~\(word)~~")
            default: parts.append(word)
            }
        }
        return parts.joined(separator: " ")
    }

    static func document(_ r: inout SplitMix) -> String {
        var blocks: [String] = []
        if r.int(0...5) == 0 { blocks.append("---\ntitle: x\n---") }
        for _ in 0..<r.int(1...4) {
            switch r.int(0...15) {
            case 0: blocks.append(String(repeating: "#", count: r.int(1...3)) + " " + inline(&r))
            case 1: blocks.append("- " + inline(&r) + "\n- [ ] " + inline(&r))
            case 2: blocks.append("1. " + inline(&r) + "\n2. " + inline(&r))
            case 3: blocks.append("> " + inline(&r) + "\n>   " + inline(&r))
            case 4: blocks.append("```\n" + inline(&r) + "\n\n" + inline(&r) + "\n```")
            case 5: blocks.append("| a | b |\n|---|:-:|\n| " + inline(&r).replacingOccurrences(of: "|", with: "")
                                  + " | x |")
            case 6: blocks.append(inline(&r) + "  \n" + inline(&r))
            case 7: blocks.append(inline(&r) + "\n   " + inline(&r))
            // Nested lists, lists in quotes, code in a list, a setext heading, HTML, a picture, tabs.
            case 8: blocks.append("- " + inline(&r) + "\n  - " + inline(&r) + "\n- " + inline(&r))
            case 9: blocks.append("> - " + inline(&r) + "\n> - " + inline(&r))
            case 10: blocks.append("- " + inline(&r) + "\n\n  ```\n  " + inline(&r) + "\n  ```")
            case 11: blocks.append(inline(&r) + "\n" + (r.int(0...1) == 0 ? "===" : "---"))
            case 12: blocks.append("<div>\n" + inline(&r) + "\n</div>")
            case 13: blocks.append("![i](a)")
            case 14: blocks.append("- " + inline(&r) + "\n\t- " + inline(&r))
            default: blocks.append(inline(&r))
            }
        }
        // LF only: a CRLF file is converted before Preview measures an edit (`EditorLineEndings`),
        // so the translator is never handed one. The projection's own CRLF handling is tested there.
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Edits

    private static let typed = ["a", "Z", " ", "*", "_", "`", "[", "]", "|", "\\", "'", "\"", "-",
                                "#", "&", "<", "!", "é", "中", "ab", "x*y", "~~", ">", "(", ")", "1",
                                "1.", "<b>", "&gt;", "](u)", "Don't *x*, e.g.", "a\r\n"]

    private static func name(_ action: RenderedEdit.Action) -> String {
        if case .format = action { return "format" }
        return "\(action)"
    }

    /// One edit a person could make on `p`, and what the view would know beside it.
    static func edit(_ r: inout SplitMix, in p: MarkdownProjection) -> (RenderedEdit, PreviewEditContext) {
        let length = (p.renderedString as NSString).length
        let at = r.int(0...max(0, length))
        let span = min(length - at, r.int(1...4))
        var context = PreviewEditContext()
        let edit: RenderedEdit
        switch r.int(0...15) {
        case 0, 1, 2, 3:
            edit = RenderedEdit(range: NSRange(location: at, length: 0),
                                text: typed[r.int(0...typed.count - 1)], action: .typing)
        case 4, 5:
            edit = RenderedEdit(range: NSRange(location: at, length: max(0, span)), action: .delete)
        case 6:
            edit = RenderedEdit(range: NSRange(location: at, length: max(0, span)),
                                text: typed[r.int(0...typed.count - 1)], action: .typing)
        case 7:
            edit = RenderedEdit(range: NSRange(location: at, length: 0),
                                action: r.int(0...1) == 0 ? .returnKey : .lineBreak)
        case 8:
            edit = RenderedEdit(range: NSRange(location: at, length: 0),
                                action: r.int(0...1) == 0 ? .tab : .backtab)
        case 9:
            edit = RenderedEdit(range: NSRange(location: at, length: max(0, span)),
                                action: .format(r.int(0...1) == 0 ? .bold : .italic))
        case 10:
            // A paste: a line, a line with its break, or several lines.
            let text = ["salt", "a*b c", "x\n", "one\ntwo", " more\r\n"][r.int(0...4)]
            edit = RenderedEdit(range: NSRange(location: at, length: r.int(0...1) == 0 ? 0 : max(0, span)),
                                text: text, action: .paste)
        case 11:
            // A tick on a box, when there is one.
            let boxes = p.segments.filter { $0.kind == .decoration && $0.source.length == 3 }
            edit = boxes.isEmpty ? RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing)
                : RenderedEdit(range: boxes[r.int(0...boxes.count - 1)].rendered, action: .tickTask)
        case 12:
            // Typing with a style pending — ⌘B or ⌘I just pressed.
            context.pending = [[.bold], [.italic], [.bold, .italic], [.strikethrough]][r.int(0...3)]
            edit = RenderedEdit(range: NSRange(location: at, length: 0),
                                text: typed[r.int(0...typed.count - 1)], action: .typing)
        case 13:
            // Typing into a paragraph Return opened, after a block the caret could end.
            let ends = p.blocks.indices.filter { p.blocks[$0].readOnly == nil }
            if let block = ends.isEmpty ? nil : ends[r.int(0...ends.count - 1)] {
                context.phantomAfterBlock = block
                if r.int(0...2) == 0 { context.pending = .bold }
                edit = RenderedEdit(range: NSRange(location: NSMaxRange(p.blocks[block].rendered), length: 0),
                                    text: typed[r.int(0...typed.count - 1)].replacingOccurrences(of: "\r\n", with: ""),
                                    action: .typing)
            } else {
                edit = RenderedEdit(range: NSRange(location: at, length: 0), text: "x", action: .typing)
            }
        default:
            // Deleting a whole block's text, or a block and its break — a triple-click.
            let b = p.blocks.isEmpty ? nil : r.int(0...p.blocks.count - 1)
            if let b, p.blocks[b].rendered.length > 0 {
                let block = p.blocks[b].rendered
                let withBreak = r.int(0...1) == 0 && b + 1 < p.blocks.count
                edit = RenderedEdit(range: withBreak ? NSRange(location: block.location,
                                                               length: p.blocks[b + 1].rendered.location - block.location) : block,
                                    action: .delete)
            } else {
                edit = RenderedEdit(range: NSRange(location: at, length: max(0, span)), action: .delete)
            }
        }
        return (edit, context)
    }

    /// Replace All of one word the rendering holds, with another or with nothing.
    static func replaceAll(_ r: inout SplitMix, in p: MarkdownProjection) -> [RenderedEdit]? {
        let rendered = p.renderedString as NSString
        let word = ["salt", "the", "x", "pasta", "a"][r.int(0...4)]
        let with = ["", "y", "pepper", "*"][r.int(0...3)]
        var edits: [RenderedEdit] = []
        var search = NSRange(location: 0, length: rendered.length)
        while case let found = rendered.range(of: word, range: search), found.location != NSNotFound {
            edits.append(RenderedEdit(range: found, text: with, action: with.isEmpty ? .delete : .typing))
            search = NSRange(location: NSMaxRange(found), length: rendered.length - NSMaxRange(found))
        }
        return edits.isEmpty ? nil : edits
    }
}

/// A small seeded generator, so a failure names a seed that reproduces it.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        return range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
