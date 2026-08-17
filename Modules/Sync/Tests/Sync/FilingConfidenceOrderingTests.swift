import Foundation
import Testing
@testable import Sync

/// `FilingConfidence`'s ordering, and the shape that keeps it answering for a case not yet written.
///
/// The enum's own header says to APPEND new cases, because the raw values are persisted in
/// `FilingVerdictCache`. `rank` was a ternary chain — `high ? 2 : (medium ? 1 : 0)` — which has no
/// arm for a case it does not name: a fourth confidence would have ranked 0, indistinguishable from
/// `.low`, and every comparison built on it would have read the surest new answer as the least sure.
@Suite struct FilingConfidenceOrderingTests {

    @Test func theOrderingIsLowThenMediumThenHigh() {
        #expect(FilingConfidence.low < FilingConfidence.medium)
        #expect(FilingConfidence.medium < FilingConfidence.high)
        #expect(FilingConfidence.low < FilingConfidence.high)
        // Not merely "some order": the ranks are distinct, which is what `.low` and a new case
        // sharing 0 would have broken while leaving `<` looking correct for the three that exist.
        #expect(Set([FilingConfidence.low, .medium, .high].map(\.rank)).count == 3)
    }

    /// The shape, not just the values: no `default:` and no trailing `else`, so the next case has
    /// to be answered here rather than defaulting to the least-sure rank.
    @Test func rankIsExhaustiveSoANewCaseCannotDefaultToLow() throws {
        // Sources/Sync/<file> — this test file is at Tests/Sync/<file>.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Sync/FilingEngine.swift"),
                                encoding: .utf8)
        try #require(source.count > 500, "FilingEngine.swift is implausibly short — this scan would be vacuous")

        let start = try #require(source.range(of: "var rank: Int {"),
                                 "rank is gone from FilingEngine — this scan checks nothing")
        var depth = 0
        var index = start.lowerBound
        var body = ""
        while index < source.endIndex {
            let c = source[index]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { break } }
            body.append(c)
            index = source.index(after: index)
        }
        #expect(body.contains("case .low"), "the slice is not rank's body")
        #expect(!body.contains("default:"),
                "rank has a default arm again — a new confidence would rank 0, the same as .low:\n\(body)")
        #expect(!body.contains(" : ("),
                "rank is a ternary chain again, which has no arm for a case it does not name:\n\(body)")
    }
}
