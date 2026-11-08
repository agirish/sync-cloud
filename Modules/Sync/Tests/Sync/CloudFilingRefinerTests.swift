import Foundation
import Testing
@testable import Sync

/// Refine's streamed request to Claude (TE335, E2): how it ends is said, never covered by another
/// backend, what arrived is kept, and a request that started is recorded as spend, finished or not.
@Suite struct CloudFilingRefinerTests {

    // MARK: A scripted stream

    /// One stream: its lines, then either a clean end, an error, or a wait that only a stop ends.
    private enum Tail { case end, fail(Error), hang }

    private final class Script: AskClaudeTransport, @unchecked Sendable {
        let status: Int
        let lines: [String]
        let tail: Tail
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        init(status: Int = 200, lines: [String], tail: Tail = .end) { self.status = status; self.lines = lines; self.tail = tail }
        var requests: [URLRequest] { lock.withLock { seen } }

        func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
            lock.withLock { seen.append(request) }
            let (lines, tail) = (self.lines, self.tail)
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    for line in lines { continuation.yield(line) }
                    switch tail {
                    case .end: continuation.finish()
                    case .fail(let error): continuation.finish(throwing: error)
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                        continuation.finish(throwing: CancellationError())
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return AskClaudeTransportResponse(status: status, retryAfter: nil, lines: stream, requestID: "req_test")
        }
    }

    private static func event(_ object: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func start(model: String = "claude-haiku-4-5") -> [String] {
        [event(["type": "message_start", "message": ["model": model, "usage": ["input_tokens": 1200, "output_tokens": 1]]]),
         event(["type": "content_block_start", "index": 0,
                "content_block": ["type": "tool_use", "id": "toolu_1", "name": "file_placements", "input": [:]]])]
    }

    private static func piece(_ text: String) -> String {
        event(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": text]])
    }

    private static func placement(_ index: Int, _ folder: String) -> String {
        "{\"index\":\(index),\"folder\":\"\(folder)\",\"confidence\":90,\"reason\":\"because\",\"createsNewFolder\":false}"
    }

    private static let finish = [
        event(["type": "content_block_stop", "index": 0]),
        event(["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 60]]),
        event(["type": "message_stop"]),
    ]

    private static func files(_ count: Int) -> [FilingCandidateFile] {
        (0..<count).map { FilingCandidateFile(filePath: "/x/f\($0).pdf", fileName: "f\($0).pdf", ext: "pdf", year: "2026", contentSnippet: nil) }
    }

    private static func environment(_ transport: AskClaudeTransport, key: String? = "sk-test",
                                    defaults: UserDefaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)"))
    -> CloudFilingRefiner.Environment {
        CloudFilingRefiner.Environment(readAPIKey: { key }, defaults: defaults,
                                       now: { Date(timeIntervalSince1970: 1_800_000_000) }, transport: transport)
    }

    private static let folders = ["Work/2026", "Home"]

    // MARK: Answered

    @Test func aFinishedAnswerGivesEveryVerdictAndRecordsTheSpend() async throws {
        let body = "{\"placements\":[" + [Self.placement(0, "Work/2026"), Self.placement(1, "Home"), Self.placement(2, "none")].joined(separator: ",") + "]}"
        let transport = Script(lines: Self.start() + [Self.piece(body)] + Self.finish)
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(3),
                                                     environment: Self.environment(transport, defaults: defaults))

        #expect(result.ending == .answered && result.started && result.sent == 3)
        #expect(result.answered == 3, "“none” is an answer")
        #expect(Set(result.verdicts.keys) == ["/x/f0.pdf", "/x/f1.pdf"])
        let entries = FilingSpendStore.entries(defaults: defaults)
        #expect(entries.count == 1 && entries[0].inputTokens == 1200 && entries[0].outputTokens == 60)
        #expect(entries[0].estimatedCostUSD > 0 && result.costUSD == entries[0].estimatedCostUSD)
    }

    @Test func theRequestIsTodaysShapeStreamed() async throws {
        let transport = Script(lines: Self.start() + Self.finish)
        _ = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport))
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect((body["tool_choice"] as? [String: String])?["name"] == "file_placements")
    }

    @Test func aBatchOverTheCapSendsOnlyTheCap() async {
        let transport = Script(lines: Self.start() + Self.finish)
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(160), environment: Self.environment(transport))
        #expect(result.sent == CloudFilingRefiner.maxFiles)
    }

    // MARK: Cut off: what arrived is kept

    /// A dropped connection partway through the answer: the whole placements that came are kept, the
    /// one cut off is not, the request is recorded, and no other backend answers.
    @Test func aDroppedConnectionKeepsTheAnswersThatArrived() async throws {
        let first = Self.placement(0, "Work/2026") + "," + Self.placement(1, "Home") + ","
        let transport = Script(lines: Self.start() + [Self.piece("{\"placements\":[" + first), Self.piece("{\"index\":2,\"fol")],
                               tail: .fail(URLError(.networkConnectionLost)))
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(4),
                                                     environment: Self.environment(transport, defaults: defaults))

        guard case .failed(let why) = result.ending else { Issue.record("not failed: \(result.ending)"); return }
        #expect(!why.isEmpty)
        #expect(result.started && result.sent == 4)
        #expect(Set(result.verdicts.keys) == ["/x/f0.pdf", "/x/f1.pdf"], "the two whole placements; the third was cut off")
        #expect(result.answered == 2)
        let entries = FilingSpendStore.entries(defaults: defaults)
        #expect(entries.count == 1, "a request that started is recorded though it didn't finish")
        #expect(entries[0].inputTokens == 1200 && entries[0].outputTokens > 0, "the output it streamed is estimated")
        #expect(entries[0].placedCount == 2)
    }

    @Test func aStreamThatEndsWithoutAnEndIsAFailureNotAnAnswer() async {
        let transport = Script(lines: Self.start() + [Self.piece("{\"placements\":[" + Self.placement(0, "Home") + ",")])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport))
        #expect(result.ending == .failed("The connection ended before Claude finished."))
        #expect(result.verdicts.count == 1)
    }

    // MARK: Stop

    @MainActor
    @Test func stoppingKeepsWhatArrivedAndRecordsTheRequest() async throws {
        let transport = Script(lines: Self.start() + [Self.piece("{\"placements\":[" + Self.placement(0, "Work/2026") + ",")], tail: .hang)
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let env = Self.environment(transport, defaults: defaults)
        let files = Self.files(3)
        let run = Task { await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: files, environment: env) }
        await waitUntil("the request went out", timeout: 10) { !transport.requests.isEmpty }
        try await Task.sleep(for: .milliseconds(300))   // the lines have been read
        run.cancel()
        let result = await run.value

        #expect(result.ending == .stopped && result.started)
        #expect(Set(result.verdicts.keys) == ["/x/f0.pdf"])
        let entries = FilingSpendStore.entries(defaults: defaults)
        #expect(entries.count == 1 && entries[0].outputTokens > 0, "a stopped stream never reports its output, so it is estimated")
    }

    // MARK: Not started

    @Test func aRejectedRequestIsAFailureThatWasNeverBilled() async {
        let error = #"{"type":"error","error":{"type":"invalid_request_error","message":"nope"}}"#
        let transport = Script(status: 400, lines: [error])
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2),
                                                     environment: Self.environment(transport, defaults: defaults))
        guard case .failed(let why) = result.ending else { Issue.record("not failed"); return }
        #expect(!why.isEmpty && !result.started && result.verdicts.isEmpty)
        #expect(FilingSpendStore.entries(defaults: defaults).isEmpty)
    }

    @Test func noKeyIsNotStartedAndSendsNothing() async {
        let transport = Script(lines: [])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport, key: nil))
        #expect(result.ending == .failed("There is no Claude key to read.") && !result.started)
        #expect(transport.requests.isEmpty)
    }

    @Test func aReachedBudgetCapIsNotStartedAndSendsNothing() async {
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        defaults.set(1.0, forKey: FileSyncManager.monthlyBudgetCapKey)
        FilingSpendStore.record(FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_800_000_000), model: "claude-haiku-4-5",
                                                 fileCount: 1, placedCount: 1, inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                                 cacheCreationTokens: 0, estimatedCostUSD: 2, costUnpriced: false), defaults: defaults)
        let transport = Script(lines: [])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2),
                                                     environment: Self.environment(transport, defaults: defaults))
        guard case .failed(let why) = result.ending else { Issue.record("not failed"); return }
        #expect(why.contains("monthly budget cap") && !result.started)
        #expect(transport.requests.isEmpty)
    }

    // MARK: Reading what was cut off

    @Test func onlyWholeObjectsAreReadFromCutOffJSON() {
        let text = "{\"placements\":[" + Self.placement(0, "A") + "," + Self.placement(1, "B") + ",{\"index\":2,\"fol"
        let objects = CloudFilingProtocol.completeObjects(inPartialJSON: text, arrayKey: "placements")
        #expect(objects.compactMap { $0["index"] as? Int } == [0, 1])
    }

    @Test func bracesAndQuotesInsideStringsDoNotEndAnObject() {
        let tricky = "{\"index\":0,\"folder\":\"A\",\"reason\":\"a } and a \\\" quote and ]\"}"
        let objects = CloudFilingProtocol.completeObjects(inPartialJSON: "{\"placements\":[" + tricky + ",{\"index\":1", arrayKey: "placements")
        #expect(objects.count == 1 && objects[0]["reason"] as? String == "a } and a \" quote and ]")
    }

    @Test func nothingIsReadBeforeTheArrayOrFromAnEmptyOne() {
        #expect(CloudFilingProtocol.completeObjects(inPartialJSON: "{\"placem", arrayKey: "placements").isEmpty)
        #expect(CloudFilingProtocol.completeObjects(inPartialJSON: "{\"placements\":[", arrayKey: "placements").isEmpty)
        #expect(CloudFilingProtocol.completeObjects(inPartialJSON: "{\"placements\":[]}", arrayKey: "placements").isEmpty)
    }

    @Test func aFinishedArrayReadsEveryObjectAndStopsAtTheClosingBracket() {
        let text = "{\"placements\":[" + Self.placement(0, "A") + "," + Self.placement(1, "B") + "],\"other\":[{\"index\":9}]}"
        #expect(CloudFilingProtocol.completeObjects(inPartialJSON: text, arrayKey: "placements").count == 2)
    }
}
