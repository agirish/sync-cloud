import Foundation
import Testing
@testable import Sync

/// The request shapes Refine can use: today's request stays byte-for-byte what it was,
/// the 5.5 shape differs only where the API needs it, and the parsers read every tool call and a
/// number the model wrote loosely.
@Suite struct CloudFilingRequestShapeTests {

    private static let files = [
        FilingCandidateFile(filePath: "/a/Invoice.pdf", fileName: "Invoice.pdf", ext: "pdf", year: "2026", contentSnippet: "Invoice to Northwind"),
        FilingCandidateFile(filePath: "/a/IMG_1.jpg", fileName: "IMG_1.jpg", ext: "jpg", year: nil, contentSnippet: nil),
        FilingCandidateFile(filePath: "/a/notes", fileName: "notes", ext: "", year: "2025", contentSnippet: nil),
    ]
    private static let taxonomy = ["Work/Invoices/2026", "Photos/2026"]

    private static func body(_ shape: CloudFilingProtocol.RequestShape? = nil, model: String = "claude-opus-5-5") -> [String: Any] {
        shape.map { CloudFilingProtocol.requestBody(model: model, taxonomyFolders: taxonomy, files: files, shape: $0) }
            ?? CloudFilingProtocol.requestBody(model: model, taxonomyFolders: taxonomy, files: files)
    }

    private static func userText(_ body: [String: Any]) -> String {
        ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    }

    private static func tool(_ body: [String: Any]) -> [String: Any]? { (body["tools"] as? [[String: Any]])?.first }

    // MARK: Today's request

    /// A caller that names no shape gets the request it always got: one forced, strict tool, no
    /// streaming, no effort, no fallbacks, and the budget of 512 plus 80 a file.
    @Test func theDefaultShapeIsTodaysRequest() {
        let body = Self.body()
        let choice = body["tool_choice"] as? [String: String]
        #expect(choice == ["type": "tool", "name": CloudFilingProtocol.toolName])
        #expect(Self.tool(body)?["strict"] as? Bool == true)
        #expect(body["stream"] == nil && body["output_config"] == nil && body["fallbacks"] == nil)
        #expect(body["max_tokens"] as? Int == 512 + Self.files.count * 80)
        #expect(!Self.userText(body).contains("calling the"), "the forced shape never needed the tool named in the text")
        #expect(Self.body(.legacy).keys == body.keys)
    }

    // MARK: The 5.5 shape

    @Test func theCurrentShapeLeavesTheToolToTheModelAndAsksForLowEffortAndAStream() {
        let body = Self.body(.current(for: AskClaudeModels.opus))
        #expect(body["tool_choice"] == nil)
        #expect(Self.tool(body)?["strict"] == nil)
        #expect(body["stream"] as? Bool == true)
        #expect((body["output_config"] as? [String: String]) == ["effort": "low"])
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["max_tokens"] as? Int == 512 + Self.files.count * 80 + CloudFilingProtocol.RequestShape.thinkingAllowance,
                "thinking is billed as output, so it needs room beside the answer")
        #expect(Self.userText(body).contains("calling the \(CloudFilingProtocol.toolName) tool"))
    }

    /// Haiku 5.5 has no server-side fallback: `fallbacks` would leave a declined request declined.
    @Test func haikuSendsNoFallbacks() {
        let body = Self.body(.current(for: AskClaudeModels.haiku), model: AskClaudeModels.haiku.id)
        #expect(body["fallbacks"] == nil)
        #expect(Self.body(.current(for: AskClaudeModels.sonnet))["fallbacks"] as? String == "default")
    }

    @Test func theVariantsStartWithTheControlAndIncludeTheCurrentShape() {
        for model in AskClaudeModels.options {
            let variants = CloudFilingProtocol.RequestShape.variants(for: model)
            #expect(variants.first?.toolChoice == .forced, "the first variant is today's request, the control")
            #expect(variants.dropFirst().allSatisfy { $0.toolChoice != .forced })
            #expect(variants.contains(.current(for: model)), "the live check must try the shape the app will use")
            #expect(Set(variants.map(\.label)).count == variants.count, "labels tell the live check's lines apart")
        }
    }

    @Test func theToolChoiceShapesAreWhatTheyName() {
        var shape = CloudFilingProtocol.RequestShape.current(for: AskClaudeModels.sonnet)
        shape.toolChoice = .any
        #expect((Self.body(shape)["tool_choice"] as? [String: String]) == ["type": "any"])
        shape.strict = true
        #expect(Self.tool(Self.body(shape))?["strict"] as? Bool == true)
    }

    // MARK: Headers

    @Test func theHeadersFollowTheShape() throws {
        let legacy = try CloudFilingProtocol.urlRequest(body: ["model": "m"], key: "k", shape: .legacy)
        #expect(legacy.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(legacy.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(legacy.value(forHTTPHeaderField: "accept") == nil)
        #expect(legacy.value(forHTTPHeaderField: "x-api-key") == "k")

        let current = try CloudFilingProtocol.urlRequest(body: ["model": "m"], key: "k", shape: .current(for: AskClaudeModels.opus))
        #expect(current.value(forHTTPHeaderField: "anthropic-version") == AskClaudeRequest.apiVersion)
        #expect(current.value(forHTTPHeaderField: "anthropic-beta") == AskClaudeRequest.fallbackBeta)
        #expect(current.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(current.timeoutInterval == 90, "a streamed answer times out on silence, so 90 s runs from the last byte")
    }

    // MARK: Parsing

    private static func call(_ placements: [JSONFragment]) -> AskClaudeToolCall {
        AskClaudeToolCall(id: UUID().uuidString, name: CloudFilingProtocol.toolName,
                          input: .object(["placements": .array(placements)]))
    }

    private static func placement(_ index: JSONFragment, _ folder: String, confidence: JSONFragment = .integer(80),
                                  creates: JSONFragment = .bool(false)) -> JSONFragment {
        .object(["index": index, "folder": .string(folder), "confidence": confidence,
                 "reason": .string("because"), "createsNewFolder": creates])
    }

    /// The verdicts a streamed answer's tool calls give, read the way Refine reads them.
    private static func verdicts(_ calls: [AskClaudeToolCall]) -> [String: FilingVerdict] {
        CloudFilingProtocol.verdicts(fromPlacements: CloudFilingProtocol.placements(toolCalls: calls, unfinished: []),
                                     files: files)
    }

    /// A model that picks its tool can call it more than once. Every placement call counts, and the
    /// first call alone would drop the rest.
    @Test func everyPlacementCallIsRead() {
        let calls = [Self.call([Self.placement(.integer(0), "Work/Invoices/2026")]),
                     Self.call([Self.placement(.integer(1), "Photos/2026")])]
        let verdicts = Self.verdicts(calls)
        #expect(verdicts["/a/Invoice.pdf"]?.relativePath == "Work/Invoices/2026")
        #expect(verdicts["/a/IMG_1.jpg"]?.relativePath == "Photos/2026")
    }

    /// Without `strict` the schema isn't enforced, so a number can arrive as text or with a decimal.
    @Test func looselyWrittenNumbersAndBooleansStillRead() {
        let calls = [Self.call([
            Self.placement(.string("0"), "Work/Invoices/2026", confidence: .string("91"), creates: .string("false")),
            Self.placement(.number(1.0), "Photos/New", confidence: .number(72.6), creates: .string("True")),
        ])]
        let verdicts = Self.verdicts(calls)
        #expect(verdicts["/a/Invoice.pdf"] != nil)
        #expect(verdicts["/a/IMG_1.jpg"]?.proposesNewFolder == true)
        #expect(verdicts["/a/IMG_1.jpg"]?.confidence == FilingVerdict.confidence(fromScore: 73))
    }

    /// Placements in a call to another tool are not read.
    @Test func aCallToAnotherToolPlacesNothing() {
        let other = AskClaudeToolCall(id: "x", name: "something_else",
                                      input: .object(["placements": .array([Self.placement(.integer(0), "Work")])]))
        #expect(Self.verdicts([other]).isEmpty)
    }

    @Test func aPlacementOutsideTheListOrNamedNoneIsDropped() {
        let calls = [Self.call([Self.placement(.integer(7), "Work"), Self.placement(.integer(0), "none"),
                                Self.placement(.integer(-1), "Work"), Self.placement(.integer(2), "Photos/2026")])]
        let verdicts = Self.verdicts(calls)
        #expect(Set(verdicts.keys) == ["/a/notes"])
    }

    // MARK: Folder names

    @Test func theFolderNameRequestFollowsTheShapeToo() {
        let request = MappingRefineRequest(family: "Tax", members: ["2024"], rows: [.init(source: "Petition", target: nil)],
                                           candidateVocabularies: [["application"]])
        let legacy = MappingRefineProtocol.requestBody(request: request)
        #expect((legacy["tool_choice"] as? [String: String])?["name"] == MappingRefineProtocol.toolName)
        #expect(legacy["stream"] == nil)

        let current = MappingRefineProtocol.requestBody(model: "claude-sonnet-5-5", request: request,
                                                        shape: .current(for: AskClaudeModels.sonnet))
        #expect(current["tool_choice"] == nil && current["stream"] as? Bool == true)
        #expect(current["max_tokens"] as? Int == 512 + 80 + CloudFilingProtocol.RequestShape.thinkingAllowance)
        let tool = (current["tools"] as? [[String: Any]])?.first
        #expect(tool?["strict"] == nil)
    }

    @Test func everyProposalCallIsRead() throws {
        let rows: [RestructureMapping.Row] = [.init(source: "Petition", target: nil), .init(source: "Approval", target: nil)]
        func call(_ source: String) -> AskClaudeToolCall {
            AskClaudeToolCall(id: source, name: MappingRefineProtocol.toolName, input: .object(["proposals": .array([
                .object(["source": .string(source), "verdict": .string("keep"), "target": .string(""), "why": .string("fine")])])]))
        }
        let proposals = try #require(MappingRefineProtocol.parseProposals(toolCalls: [call("Petition"), call("Approval")], rows: rows))
        #expect(proposals.map(\.source) == ["Petition", "Approval"])
        #expect(MappingRefineProtocol.parseProposals(toolCalls: [], rows: rows) == nil)
    }
}
