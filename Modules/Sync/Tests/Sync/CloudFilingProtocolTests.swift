import Foundation
import Testing
@testable import Sync

@Suite struct CloudFilingProtocolTests {

    private func file(_ path: String, ext: String = "pdf", snippet: String? = nil) -> FilingCandidateFile {
        FilingCandidateFile(filePath: path, fileName: (path as NSString).lastPathComponent,
                            ext: ext, year: "2025", contentSnippet: snippet)
    }

    @Test func requestBodyForcesTheStructuredToolAndCachesTheTaxonomy() throws {
        let files = [file("/root/Downloads/Tesla Policy.pdf", snippet: "GEICO auto insurance"),
                     file("/root/Downloads/IMG_0007.pdf", snippet: "Pediatric visit summary for Divit")]
        let body = CloudFilingProtocol.requestBody(model: "claude-haiku-4-5",
                                                   taxonomyFolders: ["Documents", "Documents/Vehicles"], files: files)

        #expect(body["model"] as? String == "claude-haiku-4-5")   // honors the chosen model
        // Forces the single classification tool.
        let choice = try #require(body["tool_choice"] as? [String: Any])
        #expect(choice["name"] as? String == CloudFilingProtocol.toolName)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["strict"] as? Bool == true)
        // The folder taxonomy lives in a CACHED system block (stable across scans).
        let system = try #require(body["system"] as? [[String: Any]])
        let folderBlock = try #require(system.last)
        #expect((folderBlock["text"] as? String)?.contains("Documents/Vehicles") == true)
        #expect(folderBlock["cache_control"] as? [String: String] == ["type": "ephemeral"])
        // The user turn lists the files. A named file carries NO excerpt (cost); a nameless one does.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userText = try #require(messages.first?["content"] as? String)
        #expect(userText.contains("Tesla Policy.pdf"))
        #expect(!userText.contains("GEICO auto insurance"))              // named → excerpt skipped
        #expect(userText.contains("Pediatric visit summary for Divit"))  // nameless → excerpt kept
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func requestBodyListsAvoidFoldersForReasks() throws {
        let files = [FilingCandidateFile(filePath: "/r/a/tesla.pdf", fileName: "tesla.pdf", ext: "pdf",
                                         year: nil, contentSnippet: nil,
                                         excludedRelativePaths: ["Archive/Old", "Misc"])]
        let body = CloudFilingProtocol.requestBody(taxonomyFolders: ["Documents"], files: files)
        let userText = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(userText.contains("avoid: Archive/Old, Misc"))
    }

    @Test func parseVerdictsMapsIndicesBackToFilePaths() throws {
        let files = [file("/root/a/Geico.pdf"), file("/root/a/scan.pdf"), file("/root/a/junk.bin", ext: "bin")]
        let json = """
        {"type":"message","content":[
          {"type":"tool_use","name":"file_placements","input":{"placements":[
            {"index":0,"folder":"Finance/Insurance","confidence":92,"reason":"Auto insurance policy"},
            {"index":1,"folder":"none","confidence":10,"reason":"Unclear"},
            {"index":2,"folder":"  ","confidence":0,"reason":"x"}
          ]}}
        ]}
        """.data(using: .utf8)!

        let verdicts = try #require(CloudFilingProtocol.parseVerdicts(responseData: json, files: files))
        #expect(verdicts.count == 1)                                   // "none" and blank are dropped
        let geico = try #require(verdicts["/root/a/Geico.pdf"])
        #expect(geico.relativePath == "Finance/Insurance")
        #expect(geico.confidence == .high)                             // 92 → high
        #expect(geico.reason == "Auto insurance policy")
    }

    @Test func parseVerdictsReturnsNilOnErrorOrJunk() {
        let files = [file("/root/a/x.pdf")]
        let error = #"{"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#.data(using: .utf8)!
        #expect(CloudFilingProtocol.parseVerdicts(responseData: error, files: files) == nil)      // API error → fall back
        #expect(CloudFilingProtocol.parseVerdicts(responseData: Data("nonsense".utf8), files: files) == nil)
        // A message with no tool_use block is unreadable → nil (fall back), not an empty success.
        let noTool = #"{"type":"message","content":[{"type":"text","text":"hi"}]}"#.data(using: .utf8)!
        #expect(CloudFilingProtocol.parseVerdicts(responseData: noTool, files: files) == nil)
    }

    @Test func parseVerdictsIgnoresOutOfRangeIndices() throws {
        let files = [file("/root/a/x.pdf")]
        let json = #"{"type":"message","content":[{"type":"tool_use","name":"file_placements","input":{"placements":[{"index":5,"folder":"Documents","confidence":80,"reason":"x"}]}}]}"#.data(using: .utf8)!
        let verdicts = try #require(CloudFilingProtocol.parseVerdicts(responseData: json, files: files))
        #expect(verdicts.isEmpty)                                      // index 5 has no file → skipped
    }

    // MARK: Usage / cost logging

    @Test func parseUsageAndStopReason() throws {
        let json = #"{"type":"message","stop_reason":"tool_use","usage":{"input_tokens":800,"output_tokens":300,"cache_creation_input_tokens":100,"cache_read_input_tokens":2500},"content":[]}"#.data(using: .utf8)!
        let usage = try #require(CloudFilingProtocol.parseUsage(responseData: json))
        #expect(usage.inputTokens == 800)
        #expect(usage.outputTokens == 300)
        #expect(usage.cacheCreationTokens == 100)
        #expect(usage.cacheReadTokens == 2500)
        #expect(usage.totalInputTokens == 3400)
        #expect(CloudFilingProtocol.stopReason(responseData: json) == "tool_use")
    }

    // MARK: Model selection

    @Test func currentModelResolvesSupersededIDsAndLeavesEverythingElseAlone() {
        // The three offered models pass through untouched.
        for model in CloudFilingProtocol.selectableModels {
            #expect(CloudFilingProtocol.currentModel(for: model) == model)
        }
        // A model picked before a refresh still means its family's current model, so the Settings
        // picker keeps a selection and the scan doesn't stay pinned to the superseded one.
        #expect(CloudFilingProtocol.currentModel(for: "claude-opus-4-8") == "claude-opus-5")
        #expect(CloudFilingProtocol.currentModel(for: "claude-opus-4-1") == "claude-opus-5")
        #expect(CloudFilingProtocol.currentModel(for: "claude-sonnet-4-5") == "claude-sonnet-5")
        #expect(CloudFilingProtocol.currentModel(for: "claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        // Outside the three families it can only have been set by hand — honor it as written.
        #expect(CloudFilingProtocol.currentModel(for: "claude-fable-5") == "claude-fable-5")
        #expect(CloudFilingProtocol.currentModel(for: "gpt-9") == "gpt-9")
        // The default is one of the offered models (Settings' picker default matches it).
        #expect(CloudFilingProtocol.selectableModels.contains(CloudFilingProtocol.defaultModel))
    }

    @Test func estimatedCostAccountsForCacheRatesAndModel() throws {
        let usage = CloudFilingProtocol.Usage(inputTokens: 10_000, outputTokens: 2_000,
                                              cacheCreationTokens: 1_000, cacheReadTokens: 5_000)
        // Opus $5/$25: 0.05 (in) + 0.0025 (cache-read ×0.1) + 0.00625 (cache-write ×1.25) + 0.05 (out)
        let opus = try #require(CloudFilingProtocol.estimatedCostUSD(model: "claude-opus-5", usage: usage))
        #expect(abs(opus - 0.10875) < 1e-6)
        // Haiku $1/$5 is dramatically cheaper on the same usage.
        let haiku = try #require(CloudFilingProtocol.estimatedCostUSD(model: "claude-haiku-4-5", usage: usage))
        #expect(haiku < opus / 4)
        // Unknown model → no estimate rather than a wrong one.
        #expect(CloudFilingProtocol.estimatedCostUSD(model: "gpt-9", usage: usage) == nil)
    }

    // MARK: Pre-call estimate (spend guardrails)

    @Test func estimateTokensArePositiveAndGrowWithFileCount() {
        let taxonomy = ["Documents", "Documents/Vehicles", "Finance/Insurance"]
        let small = CloudFilingProtocol.estimateTokens(taxonomyFolders: taxonomy, files: [file("/r/a.pdf")])
        let large = CloudFilingProtocol.estimateTokens(
            taxonomyFolders: taxonomy,
            files: (0..<25).map { file("/r/file\($0).pdf") })

        #expect(small.input > 0)
        #expect(small.output > 0)
        // More files → more input text and more output budget.
        #expect(large.input > small.input)
        #expect(large.output > small.output)
        // Output mirrors the request body's own 512 + files*80 budget.
        #expect(small.output == 512 + 1 * 80)
        #expect(large.output == 512 + 25 * 80)
    }

    @Test func estimateOutputIsCappedAt16384() {
        // A batch far beyond the cap still tops out at the body's 16384 output ceiling.
        let files = (0..<1000).map { file("/r/file\($0).pdf") }
        let est = CloudFilingProtocol.estimateTokens(taxonomyFolders: ["Documents"], files: files)
        #expect(est.output == 16384)
    }

    @Test func preCallEstimatedCostIsPositiveForKnownModelAndNilForUnknown() throws {
        let taxonomy = ["Documents", "Finance/Insurance"]
        let files = [file("/r/a.pdf", snippet: "GEICO auto insurance policy"),
                     file("/r/IMG_0007.pdf", snippet: "Pediatric visit summary")]
        let haiku = try #require(CloudFilingProtocol.estimatedCostUSD(
            model: "claude-haiku-4-5", taxonomyFolders: taxonomy, files: files))
        #expect(haiku > 0)
        // Opus is pricier than Haiku for the same batch.
        let opus = try #require(CloudFilingProtocol.estimatedCostUSD(
            model: "claude-opus-5", taxonomyFolders: taxonomy, files: files))
        #expect(opus > haiku)
        // Unknown model → nil, so the UI shows "estimate unavailable" instead of a wrong number.
        #expect(CloudFilingProtocol.estimatedCostUSD(
            model: "gpt-9", taxonomyFolders: taxonomy, files: files) == nil)
    }
}
