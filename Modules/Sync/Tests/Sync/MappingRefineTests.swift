import Foundation
import Testing
@testable import Sync

/// §5.6's wire shape and its two text rules — the payload is exactly what the sheet disclosed,
/// the parse never coerces a guess, and a reversal is labelled or a reviewer reads it as a bug.
@Suite struct MappingRefineTests {

    private static func request(samples: [String: [String]] = [:]) -> MappingRefineRequest {
        MappingRefineRequest(
            family: "Immigration/Authorization/H-4",
            members: ["2021-2024", "2024-2026"],
            rows: [.init(source: "Petition", target: "Application"),
                   .init(source: "Approval", target: nil)],
            candidateVocabularies: [["application", "approval", "receipt"]],
            sampleFileNames: samples)
    }

    // MARK: The payload

    /// The body carries what the disclosure names — paths, members, candidates, the user's rows —
    /// and the sample file names ONLY when the request carries them. There is no field for file
    /// contents at all, which is the strongest form of "never sent".
    @Test func theBodyCarriesExactlyTheDisclosedPayload() throws {
        let bare = MappingRefineProtocol.requestBody(request: Self.request())
        let bareText = try #require(
            ((bare["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        #expect(bareText.contains("Immigration/Authorization/H-4"))
        #expect(bareText.contains("2021-2024"))
        #expect(bareText.contains("Petition → Application"))
        #expect(bareText.contains("Approval → keep"))
        #expect(!bareText.contains("files:"), "no samples were requested, so none ride")

        let sampled = MappingRefineProtocol.requestBody(
            request: Self.request(samples: ["Petition": ["I-539.pdf", "receipt.pdf"]]))
        let sampledText = try #require(
            ((sampled["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        #expect(sampledText.contains("files: I-539.pdf, receipt.pdf"))

        // The tool is forced, so the answer can only arrive structured.
        #expect((bare["tool_choice"] as? [String: Any])?["name"] as? String
                == MappingRefineProtocol.toolName)
    }

    // MARK: The parse

    private static func response(_ proposals: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "tool_use", "input": ["proposals": proposals]]],
        ])
    }

    /// The three verdicts round-trip; a hallucinated source, an unknown verdict and a propose
    /// with no target are dropped rather than coerced — the parse never guesses.
    @Test func theParseKeepsTheAskedAndDropsTheInvented() throws {
        let rows = Self.request().rows
        let parsed = try #require(MappingRefineProtocol.parseProposals(
            responseData: Self.response([
                ["source": "Petition", "verdict": "propose", "target": "Application",
                 "why": "H-4 is filed on I-539, an application"],
                ["source": "Approval", "verdict": "declined", "target": "",
                 "why": "nothing given says what Approval holds"],
                ["source": "Ghost", "verdict": "propose", "target": "X", "why": "invented"],
                ["source": "Petition", "verdict": "shrug", "target": "", "why": "unknown verb"],
                ["source": "Approval", "verdict": "propose", "target": "  ", "why": "empty"],
            ]), rows: rows))
        #expect(parsed == [
            MappingRefineProposal(source: "Petition",
                                  verdict: .propose(target: "Application"),
                                  why: "H-4 is filed on I-539, an application"),
            MappingRefineProposal(source: "Approval", verdict: .declined,
                                  why: "nothing given says what Approval holds"),
        ])

        #expect(MappingRefineProtocol.parseProposals(
            responseData: Data("not json".utf8), rows: rows) == nil)
        #expect(MappingRefineProtocol.parseProposals(
            responseData: try JSONSerialization.data(withJSONObject: ["type": "error"]),
            rows: rows) == nil)
    }

    // MARK: The reversal rule

    /// A proposal that reverses another is labelled as a swap; one that reverses the user's own
    /// row says whose row it reverses; anything else carries no note.
    @Test func reversalsAreLabelledAndNothingElseIs() {
        let rows: [RestructureMapping.Row] = [.init(source: "Forms", target: "Docs")]
        let swapA = MappingRefineProposal(source: "Application",
                                          verdict: .propose(target: "Petition"), why: "w")
        let swapB = MappingRefineProposal(source: "Petition",
                                          verdict: .propose(target: "Application"), why: "w")
        let reversesUser = MappingRefineProposal(source: "Docs",
                                                 verdict: .propose(target: "Forms"), why: "w")
        let plain = MappingRefineProposal(source: "Payment",
                                          verdict: .propose(target: "Payments"), why: "w")
        let all = [swapA, swapB, reversesUser, plain]
        #expect(MappingRefineProtocol.reversalNote(for: swapA, among: all, rows: rows)?
            .contains("swaps places with Petition") == true)
        #expect(MappingRefineProtocol.reversalNote(for: reversesUser, among: all, rows: rows)
                == "reverses your Forms → Docs")
        #expect(MappingRefineProtocol.reversalNote(for: plain, among: all, rows: rows) == nil)
        #expect(MappingRefineProtocol.reversalNote(
            for: MappingRefineProposal(source: "X", verdict: .declined, why: "w"),
            among: all, rows: rows) == nil, "a declined row reverses nothing")
    }
}
