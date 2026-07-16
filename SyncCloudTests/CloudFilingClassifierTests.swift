import Foundation
import Testing
import Sync
@testable import SyncCloud

/// Exercises `CloudFilingClassifier.classify` end-to-end through its `Environment` seam: the
/// API-key gate, the monthly/total budget caps, the 150-file cost cap, request assembly (model
/// choice from defaults, headers, body), response mapping, and spend recording. The transport is
/// always a stub — the real Anthropic API is never called from tests.
@Suite struct CloudFilingClassifierTests {

    // MARK: Harness

    /// A scratch UserDefaults suite unique to one test (tests run in parallel), removed on teardown.
    private final class ScratchDefaults {
        let suiteName = "CloudFilingClassifierTests." + UUID().uuidString
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: suiteName)! }
        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }

    /// Thread-safe capture of the requests the classifier hands the transport.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func append(_ r: URLRequest) { lock.lock(); stored.append(r); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: CloudFilingProtocol.endpoint)!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// A canned Messages-API success envelope carrying the forced tool call.
    private static func successBody(placements: [[String: Any]],
                                    stopReason: String = "tool_use",
                                    inputTokens: Int = 1_000, outputTokens: Int = 100) -> Data {
        let root: [String: Any] = [
            "type": "message",
            "stop_reason": stopReason,
            "content": [[
                "type": "tool_use",
                "name": CloudFilingProtocol.toolName,
                "input": ["placements": placements],
            ]],
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private static func environment(defaults: UserDefaults,
                                    key: String? = "sk-test",
                                    box: RequestBox = RequestBox(),
                                    now: Date = Date(),
                                    status: Int = 200,
                                    body: Data = Data("{}".utf8)) -> CloudFilingClassifier.Environment {
        var env = CloudFilingClassifier.Environment()
        env.readAPIKey = { key }
        env.defaults = defaults
        env.now = { now }
        env.transport = { request in
            box.append(request)
            return (body, http(status))
        }
        return env
    }

    private static func candidate(_ name: String, snippet: String? = nil) -> FilingCandidateFile {
        FilingCandidateFile(filePath: "/tmp/loose/\(name)", fileName: name,
                            ext: (name as NSString).pathExtension, year: "2026", contentSnippet: snippet)
    }

    private static func bodyJSON(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Hard-failure contract (return nil so the caller falls back on-device)

    @Test func returnsNilWithoutAPIKeyAndNeverTouchesTheNetwork() async {
        let scratch = ScratchDefaults()
        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, key: nil, box: box)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
        #expect(box.requests.isEmpty)
    }

    @Test func emptyBatchReturnsEmptyWithoutANetworkCall() async {
        let scratch = ScratchDefaults()
        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box)
        let result = await CloudFilingClassifier.classify(taxonomyFolders: ["Documents"], files: [], environment: env)
        #expect(result == [:])
        #expect(box.requests.isEmpty)
    }

    @Test func non200ResponseReturnsNil() async {
        let scratch = ScratchDefaults()
        let errorBody = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#.utf8)
        let env = Self.environment(defaults: scratch.defaults, status: 400, body: errorBody)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
    }

    @Test func transportFailureReturnsNil() async {
        let scratch = ScratchDefaults()
        var env = Self.environment(defaults: scratch.defaults)
        env.transport = { _ in throw URLError(.notConnectedToInternet) }
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
    }

    @Test func unreadable200BodyReturnsNilAndRecordsNoSpend() async {
        let scratch = ScratchDefaults()
        let env = Self.environment(defaults: scratch.defaults, body: Data("not json".utf8))
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
        #expect(FilingSpendStore.entries(defaults: scratch.defaults).isEmpty)
    }

    // MARK: Budget caps (hard gate before any network call)

    @MainActor
    @Test func monthlyCapAlreadyReachedBlocksTheCall() async {
        let scratch = ScratchDefaults()
        let now = Date()
        scratch.defaults.set(1.0, forKey: FileSyncManager.monthlyBudgetCapKey)
        FilingSpendStore.record(FilingSpendEntry(
            timestamp: now, model: "claude-haiku-4-5", fileCount: 10, placedCount: 10,
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0,
            estimatedCostUSD: 1.0), defaults: scratch.defaults)

        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box, now: now)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
        #expect(box.requests.isEmpty)
    }

    @MainActor
    @Test func lastMonthsSpendDoesNotCountAgainstTheMonthlyCap() async {
        let scratch = ScratchDefaults()
        let now = Date()
        scratch.defaults.set(1.0, forKey: FileSyncManager.monthlyBudgetCapKey)
        // Same spend, but recorded ~40 days ago — outside the current calendar month.
        FilingSpendStore.record(FilingSpendEntry(
            timestamp: now.addingTimeInterval(-40 * 86_400), model: "claude-haiku-4-5",
            fileCount: 10, placedCount: 10, inputTokens: 1, outputTokens: 1,
            cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 1.0), defaults: scratch.defaults)

        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box, now: now,
                                   body: Self.successBody(placements: []))
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == [:])            // the call went through and placed nothing
        #expect(box.requests.count == 1)
    }

    @Test func totalCapDefaultsToFiveDollarsAndBlocksLifetimeSpendPastIt() async {
        let scratch = ScratchDefaults()
        // No cap keys set at all: monthly is off (0), total defaults to $5. Lifetime totals come
        // from the never-trimmed FilingSpendStore totals, regardless of entry age.
        FilingSpendStore.record(FilingSpendEntry(
            timestamp: Date(timeIntervalSince1970: 0), model: "claude-haiku-4-5",
            fileCount: 10, placedCount: 10, inputTokens: 1, outputTokens: 1,
            cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 5.0), defaults: scratch.defaults)

        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == nil)
        #expect(box.requests.isEmpty)
    }

    @Test func totalCapZeroMeansUnlimited() async {
        let scratch = ScratchDefaults()
        scratch.defaults.set(0.0, forKey: FileSyncManager.totalBudgetCapKey)   // explicit "off"
        FilingSpendStore.record(FilingSpendEntry(
            timestamp: Date(timeIntervalSince1970: 0), model: "claude-haiku-4-5",
            fileCount: 10, placedCount: 10, inputTokens: 1, outputTokens: 1,
            cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 100.0), defaults: scratch.defaults)

        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box,
                                   body: Self.successBody(placements: []))
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        #expect(result == [:])
        #expect(box.requests.count == 1)
    }

    // MARK: The 150-file cost cap

    @Test func capsABatchAtOneHundredFiftyFiles() async throws {
        let scratch = ScratchDefaults()
        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box,
                                   body: Self.successBody(placements: []))
        let files = (0..<151).map { Self.candidate("file-\($0).pdf") }
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: files, environment: env)
        #expect(result == [:])

        let body = try Self.bodyJSON(of: try #require(box.requests.first))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userText = try #require(messages.first?["content"] as? String)
        #expect(userText.contains("[149] name: file-149.pdf"))
        #expect(!userText.contains("[150]"))
        // The output-token budget is computed from the CAPPED count (512 + 150×80).
        #expect(body["max_tokens"] as? Int == 12_512)
    }

    // MARK: Request assembly

    @MainActor
    @Test func usesTheModelPickedInDefaultsAndTheStandardHeaders() async throws {
        let scratch = ScratchDefaults()
        scratch.defaults.set("claude-sonnet-4-5", forKey: FileSyncManager.cloudModelDefaultsKey)
        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box,
                                   body: Self.successBody(placements: []))
        _ = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)

        let request = try #require(box.requests.first)
        #expect(request.url?.absoluteString == CloudFilingProtocol.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == CloudFilingProtocol.apiVersion)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try Self.bodyJSON(of: request)["model"] as? String == "claude-sonnet-4-5")
    }

    @Test func fallsBackToTheDefaultModelWhenNoneIsPicked() async throws {
        let scratch = ScratchDefaults()
        let box = RequestBox()
        let env = Self.environment(defaults: scratch.defaults, box: box,
                                   body: Self.successBody(placements: []))
        _ = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: [Self.candidate("a.pdf")], environment: env)
        let request = try #require(box.requests.first)
        #expect(try Self.bodyJSON(of: request)["model"] as? String == CloudFilingProtocol.defaultModel)
    }

    // MARK: Response mapping + spend recording

    @Test func mapsPlacementsToVerdictsAndRecordsSpend() async throws {
        let scratch = ScratchDefaults()
        let now = Date()
        let files = [Self.candidate("w2-2025.pdf"), Self.candidate("mystery.bin")]
        let body = Self.successBody(placements: [
            ["index": 0, "folder": "Documents/Taxes/2025", "confidence": 92, "reason": "A W-2 tax form."],
            ["index": 1, "folder": "none", "confidence": 10, "reason": "Cannot tell."],
        ])
        let env = Self.environment(defaults: scratch.defaults, now: now, body: body)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents/Taxes/2025"], files: files, environment: env)

        let verdicts = try #require(result)
        #expect(verdicts.count == 1)
        let verdict = try #require(verdicts[files[0].filePath])
        #expect(verdict.relativePath == "Documents/Taxes/2025")
        #expect(verdict.confidence == .high)
        #expect(verdict.reason == "A W-2 tax form.")

        // The call's usage was recorded to the spend store (history + totals) in the seam's defaults.
        let entries = FilingSpendStore.entries(defaults: scratch.defaults)
        #expect(entries.count == 1)
        #expect(entries.first?.fileCount == 2)
        #expect(entries.first?.placedCount == 1)
        #expect(entries.first?.inputTokens == 1_000)
        #expect(entries.first?.outputTokens == 100)
        // JSON round-trips Date through a Double, so compare with a tolerance.
        #expect(abs((entries.first?.timestamp.timeIntervalSince(now)) ?? .infinity) < 0.001)
        let expectedCost = CloudFilingProtocol.estimatedCostUSD(
            model: CloudFilingProtocol.defaultModel,
            usage: .init(inputTokens: 1_000, outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0))
        #expect(entries.first?.estimatedCostUSD == expectedCost)
        #expect(FilingSpendStore.totals(defaults: scratch.defaults).scans == 1)
    }

    @Test func truncatedMaxTokensResponseStillReturnsTheVerdictsItGot() async throws {
        let scratch = ScratchDefaults()
        let files = [Self.candidate("a.pdf")]
        let body = Self.successBody(placements: [
            ["index": 0, "folder": "Documents", "confidence": 60, "reason": "Looks like a document."],
        ], stopReason: "max_tokens")
        let env = Self.environment(defaults: scratch.defaults, body: body)
        let result = await CloudFilingClassifier.classify(
            taxonomyFolders: ["Documents"], files: files, environment: env)
        let verdicts = try #require(result)
        #expect(verdicts[files[0].filePath]?.relativePath == "Documents")
        #expect(verdicts[files[0].filePath]?.confidence == .medium)
    }
}
