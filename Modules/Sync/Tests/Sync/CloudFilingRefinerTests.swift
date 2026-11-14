import Foundation
import Testing
@testable import Sync

/// Refine's streamed request to Claude: how it ends is said, never covered by another
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
        private var askedPastTheLines = false
        init(status: Int = 200, lines: [String], tail: Tail = .end) { self.status = status; self.lines = lines; self.tail = tail }
        var requests: [URLRequest] { lock.withLock { seen } }
        /// The reader asked for the line after the last one, so it has applied every line.
        var allLinesRead: Bool { lock.withLock { askedPastTheLines } }

        func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
            lock.withLock { seen.append(request) }
            let (lines, tail) = (self.lines, self.tail)
            let next = LockedBox(0)
            // Lines are handed out on demand, in the reader's task, so a stop reaches the hang.
            let stream = AsyncThrowingStream<String, Error>(unfolding: { [self] in
                let index = next.withLock { index in defer { index += 1 }; return index }
                if index < lines.count { return lines[index] }
                lock.withLock { askedPastTheLines = true }
                switch tail {
                case .end: return nil
                case .fail(let error): throw error
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                    throw CancellationError()
                }
            })
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
        // Priced from Ask Claude's table (the chat's default model, Sonnet 5.5), in the month's total
        // and in Organize's share of it, and nowhere else.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(result.costUSD > 0)
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == result.costUSD)
        #expect(AskClaudeSpend.organizeSpent(in: defaults, now: now) == result.costUSD)
        #expect(FilingSpendStore.entries(defaults: defaults).isEmpty, "nothing new in the old spend history")
        let option = AskClaudeModels.defaultModel
        let expected = (1200 * option.price.input + 60 * option.price.output) / 1_000_000
        #expect(abs(result.costUSD - expected) < 1e-9, "the model's own price: \(result.costUSD) vs \(expected)")
    }

    /// The chat's model is Ask Claude's setting, and Refine sends the request that model accepts.
    @Test func theRequestIsTheChatsModelsShapeStreamed() async throws {
        let transport = Script(lines: Self.start() + Self.finish)
        _ = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport))
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AskClaudeRequest.apiVersion)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == AskClaudeRequest.fallbackBeta)
        #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == AskClaudeModels.defaultModel.id)
        #expect(body["stream"] as? Bool == true)
        #expect(body["tool_choice"] == nil, "a forced tool is a 400 on the 5.5 models")
        #expect((body["output_config"] as? [String: String]) == ["effort": "low"])
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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(result.costUSD > 0 && AskClaudeSpend.spent(in: defaults, now: now) == result.costUSD,
                "a request that started is recorded though it didn't finish, with the output it streamed estimated")
        #expect(AskClaudeSpend.organizeSpent(in: defaults, now: now) == result.costUSD)
    }

    @Test func aStreamThatEndsWithoutAnEndIsAFailureNotAnAnswer() async {
        let transport = Script(lines: Self.start() + [Self.piece("{\"placements\":[" + Self.placement(0, "Home") + ",")])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport))
        #expect(result.ending == .failed("The connection ended before Claude finished."))
        #expect(result.verdicts.count == 1)
    }

    /// A reply that finishes without answering every file (prose instead of the tool, or the output
    /// cap) is not a whole answer: it ends as a failure that keeps what came, so the card offers the
    /// rest again instead of calling the unanswered files kept.
    @Test func aFinishedReplyThatAnswersOnlySomeFilesIsNotAWholeAnswer() async {
        let body = "{\"placements\":[" + Self.placement(0, "Home") + "]}"
        let early = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(3),
                                                    environment: Self.environment(Script(lines: Self.start() + [Self.piece(body)] + Self.finish)))
        #expect(early.ending == .failed("Claude stopped early."))
        #expect(early.answered == 1 && early.verdicts.count == 1 && early.started)

        let capped = [
            Self.event(["type": "content_block_stop", "index": 0]),
            Self.event(["type": "message_delta", "delta": ["stop_reason": "max_tokens"], "usage": ["output_tokens": 60]]),
            Self.event(["type": "message_stop"]),
        ]
        let cut = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(3),
                                                  environment: Self.environment(Script(lines: Self.start() + [Self.piece(body)] + capped)))
        #expect(cut.ending == .failed("Claude’s answer was cut short."))

        let whole = "{\"placements\":[" + [Self.placement(0, "Home"), Self.placement(1, "none")].joined(separator: ",") + "]}"
        let all = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2),
                                                  environment: Self.environment(Script(lines: Self.start() + [Self.piece(whole)] + Self.finish)))
        #expect(all.ending == .answered, "every file answered, “none” included")
    }

    // MARK: Stop

    @MainActor
    @Test func stoppingKeepsWhatArrivedAndRecordsTheRequest() async throws {
        let transport = Script(lines: Self.start() + [Self.piece("{\"placements\":[" + Self.placement(0, "Work/2026") + ",")], tail: .hang)
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let env = Self.environment(transport, defaults: defaults)
        let files = Self.files(3)
        let run = Task { await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: files, environment: env) }
        await waitUntil("every line was read", timeout: 10) { transport.allLinesRead }
        run.cancel()
        let result = await run.value

        #expect(result.ending == .stopped && result.started)
        #expect(Set(result.verdicts.keys) == ["/x/f0.pdf"])
        #expect(AskClaudeSpend.spent(in: defaults, now: Date(timeIntervalSince1970: 1_800_000_000)) > 0,
                "a stopped stream never reports its output, so it is estimated and recorded")
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
        #expect(AskClaudeSpend.spent(in: defaults, now: Date(timeIntervalSince1970: 1_800_000_000)) == 0, "never billed, never recorded")
    }

    @Test func noKeyIsNotStartedAndSendsNothing() async {
        let transport = Script(lines: [])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2), environment: Self.environment(transport, key: nil))
        #expect(result.ending == .failed("There is no Claude key to read.") && !result.started)
        #expect(transport.requests.isEmpty)
    }

    @Test func aReachedLimitIsNotStartedAndSendsNothing() async {
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(1.0, forKey: AskClaudeSpend.limitDefaultsKey)
        AskClaudeSpend.record(2.0, in: defaults, now: now)
        let transport = Script(lines: [])
        let result = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(2),
                                                     environment: Self.environment(transport, defaults: defaults))
        guard case .failed(let why) = result.ending else { Issue.record("not failed"); return }
        #expect(why.contains("monthly limit") && !result.started)
        #expect(transport.requests.isEmpty)
    }

    /// The chat's chat spends toward the same limit: Ask Claude's own spend is what blocks it.
    @Test func theOneLimitIsSharedWithTheChat() async {
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(5.0, forKey: AskClaudeSpend.limitDefaultsKey)
        AskClaudeSpend.record(4.99, in: defaults, now: now)
        let body = "{\"placements\":[" + Self.placement(0, "Home") + "]}"
        let ok = Script(lines: Self.start() + [Self.piece(body)] + Self.finish)
        let first = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(1),
                                                    environment: Self.environment(ok, defaults: defaults))
        #expect(first.ending == .answered, "under the limit it runs")
        AskClaudeSpend.record(1.0, in: defaults, now: now)
        let blocked = await CloudFilingRefiner.refine(taxonomyFolders: Self.folders, files: Self.files(1),
                                                      environment: Self.environment(Script(lines: []), defaults: defaults))
        #expect(!blocked.started, "the chat's spend counts: now it is over")
    }

    // MARK: Refine Names

    private static let mapping = MappingRefineRequest(
        family: "Tax", members: ["2024"], rows: [.init(source: "Petition", target: nil), .init(source: "Approval", target: nil)],
        candidateVocabularies: [["application", "approval"]])

    private static func nameCall(_ sources: [String]) -> [String] {
        let list = sources.map { "{\"source\":\"\($0)\",\"verdict\":\"keep\",\"target\":\"\",\"why\":\"fine\"}" }.joined(separator: ",")
        return [
            event(["type": "message_start", "message": ["model": "claude-sonnet-5-5", "usage": ["input_tokens": 900, "output_tokens": 1]]]),
            event(["type": "content_block_start", "index": 0,
                   "content_block": ["type": "tool_use", "id": "toolu_n", "name": "mapping_proposals", "input": [:]]]),
            piece("{\"proposals\":[" + list + "]}"),
        ] + finish
    }

    /// Refine Names is the same request as Refine: the chat's model, streamed, no forced tool, the same
    /// limit, and its cost in the month's total and Organize's share.
    @Test func refineNamesStreamsOnTheChatsModelAndRecordsItsCost() async throws {
        let transport = Script(lines: Self.nameCall(["Petition", "Approval"]))
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let proposals = await CloudFilingRefiner.refineNames(Self.mapping, environment: Self.environment(transport, defaults: defaults))

        #expect(proposals?.map(\.source) == ["Petition", "Approval"])
        let request = try #require(transport.requests.first)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == AskClaudeModels.defaultModel.id && body["stream"] as? Bool == true)
        #expect(body["tool_choice"] == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AskClaudeSpend.spent(in: defaults, now: now) > 0)
        #expect(AskClaudeSpend.organizeSpent(in: defaults, now: now) == AskClaudeSpend.spent(in: defaults, now: now))
    }

    @Test func refineNamesStopsAtTheLimitAndAFailedOneStillRecordsWhatStarted() async {
        let defaults = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(1.0, forKey: AskClaudeSpend.limitDefaultsKey)
        AskClaudeSpend.record(2.0, in: defaults, now: now)
        let unsent = Script(lines: [])
        #expect(await CloudFilingRefiner.refineNames(Self.mapping, environment: Self.environment(unsent, defaults: defaults)) == nil)
        #expect(unsent.requests.isEmpty)

        let fresh = ScratchDefaults("CloudFilingRefinerTests-\(UUID().uuidString)")
        let cut = Script(lines: Array(Self.nameCall(["Petition"]).prefix(3)), tail: .fail(URLError(.networkConnectionLost)))
        #expect(await CloudFilingRefiner.refineNames(Self.mapping, environment: Self.environment(cut, defaults: fresh)) == nil,
                "no proposals from an answer that didn't finish")
        #expect(AskClaudeSpend.spent(in: fresh, now: now) > 0, "but the request that started is recorded")
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
