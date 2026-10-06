import Testing
import Foundation
@testable import FileExplorer

/// The translator's property test (TE67 §6.1): random documents, random edits, and the four things
/// that must hold for every edit the translator accepts.
///
/// 1. **What the person typed is what renders** — the new rendering is the old one with the edit
///    made (through the parser's smart punctuation), for every edit checked against an expectation.
/// 2. **Nothing outside the edit moves** — the edits are in bounds and do not overlap, and the new
///    source is exactly the old one with them applied.
/// 3. **The caret lands after the typed text.**
/// 4. **Undo restores the source byte for byte.**
///
/// A refused edit changes nothing by construction: a refusal carries no edits.
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
        for seed in seeds {
            var random = SplitMix(seed: seed)
            let source = Self.document(&random)
            let p = MarkdownProjection.project(source)
            let edit = Self.edit(&random, in: p)
            let outcome = PreviewEditTranslator.translate(edit, in: p)
            guard case .apply(let result) = outcome else { refused += 1; continue }
            applied += 1
            let where_ = "seed \(seed), \(edit), source \(String(reflecting: source))"

            // 2. In bounds, not overlapping, and the whole change.
            let ordered = result.edits.sorted { $0.range.location < $1.range.location }
            #expect(ordered.allSatisfy { NSMaxRange($0.range) <= (source as NSString).length }, "\(where_)")
            #expect(zip(ordered, ordered.dropFirst()).allSatisfy { NSMaxRange($0.range) <= $1.range.location },
                    "overlapping edits: \(where_)")
            #expect(PreviewEditTranslator.applied(result.edits, to: source) == result.source, "\(where_)")

            // 4. Undo is exact.
            #expect(PreviewEditTranslatorTests.undo(result.edits, before: source, after: result.source)
                    == source, "undo did not restore: \(where_)")

            // 1 and 3, for the text edits checked against an expectation.
            guard [.typing, .delete].contains(edit.action) else { continue }
            let expected = (p.renderedString as NSString).replacingCharacters(in: edit.range, with: edit.text)
            #expect(PreviewEditTranslator.comparable(result.projection.renderedString, structural: false)
                    == PreviewEditTranslator.comparable(expected, structural: false),
                    "rendered \(String(reflecting: result.projection.renderedString)): \(where_)")
            if result.projection.renderedString == expected {
                #expect(result.renderedSelection.location
                        == edit.range.location + (edit.text as NSString).length,
                        "caret at \(result.renderedSelection.location): \(where_)")
            }
            // The two carets must agree: the source caret, mapped into the new rendering, may sit
            // no later than the rendered one — at most it is before markers that render nothing.
            let mapped = PreviewEditRules.renderedOffset(forSource: result.sourceSelection.location,
                                                         in: result.projection)
            #expect(abs(mapped - result.renderedSelection.location) <= 1,
                    "source caret maps to \(mapped), rendered caret \(result.renderedSelection.location): \(where_)")
        }
        print("[property] \(applied) of \(seeds.count) edits applied, \(refused) refused")
        // A harness that refuses everything passes every check above. It must not.
        #expect(applied > seeds.count / 4, "only \(applied) of \(seeds.count) edits applied (\(refused) refused)")
    }

    // MARK: Documents

    private static let words = ["salt", "the", "pasta", "Café", "naïve", "中文", "😀", "snake_case",
                                "a*b", "x", "plenty", "don't", "1.5", "&amp;", "\\*"]

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
            switch r.int(0...8) {
            case 0: blocks.append(String(repeating: "#", count: r.int(1...3)) + " " + inline(&r))
            case 1: blocks.append("- " + inline(&r) + "\n- [ ] " + inline(&r))
            case 2: blocks.append("1. " + inline(&r) + "\n2. " + inline(&r))
            case 3: blocks.append("> " + inline(&r) + "\n>   " + inline(&r))
            case 4: blocks.append("```\n" + inline(&r) + "\n\n" + inline(&r) + "\n```")
            case 5: blocks.append("| a | b |\n|---|:-:|\n| " + inline(&r).replacingOccurrences(of: "|", with: "")
                                  + " | x |")
            case 6: blocks.append(inline(&r) + "  \n" + inline(&r))
            case 7: blocks.append(inline(&r) + "\n   " + inline(&r))
            default: blocks.append(inline(&r))
            }
        }
        // LF only: a CRLF file is converted before Preview measures an edit (`EditorLineEndings`),
        // so the translator is never handed one. The projection's own CRLF handling is tested there.
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Edits

    private static let typed = ["a", "Z", " ", "*", "_", "`", "[", "]", "|", "\\", "'", "\"", "-",
                                "#", "&", "<", "!", "é", "中", "ab", "x*y", "~~"]

    static func edit(_ r: inout SplitMix, in p: MarkdownProjection) -> RenderedEdit {
        let length = (p.renderedString as NSString).length
        let at = r.int(0...max(0, length))
        let span = min(length - at, r.int(1...4))
        switch r.int(0...9) {
        case 0, 1, 2, 3:
            return RenderedEdit(range: NSRange(location: at, length: 0),
                                text: typed[r.int(0...typed.count - 1)], action: .typing)
        case 4, 5:
            return RenderedEdit(range: NSRange(location: at, length: max(0, span)), action: .delete)
        case 6:
            return RenderedEdit(range: NSRange(location: at, length: max(0, span)),
                                text: typed[r.int(0...typed.count - 1)], action: .typing)
        case 7:
            return RenderedEdit(range: NSRange(location: at, length: 0),
                                action: r.int(0...1) == 0 ? .returnKey : .lineBreak)
        case 8:
            return RenderedEdit(range: NSRange(location: at, length: 0),
                                action: r.int(0...1) == 0 ? .tab : .backtab)
        default:
            return RenderedEdit(range: NSRange(location: at, length: max(0, span)),
                                action: .format(r.int(0...1) == 0 ? .bold : .italic))
        }
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
