import Foundation
import Testing
@testable import Sync

/// The key the live check spends, from the environment and nowhere else.
private let liveKey = ProcessInfo.processInfo.environment["ASK_CLAUDE_LIVE_KEY"].flatMap { $0.isEmpty ? nil : $0 }

/// Which request shape each Ask Claude model accepts for Refine, asked for real (TE335, E1).
///
/// Refine's request forces one tool, which Opus 5.5 and Sonnet 5.5 refuse with a 400; the chat's
/// own 5.5 requests use API version 2026-10-21, low effort, server-side fallbacks and a streamed
/// reply. This sends one small Refine batch and one folder-name batch to each of the chat's three
/// models in each shape in `CloudFilingProtocol.RequestShape.variants`, and prints one line per
/// try: status, stop reason, placements read, tokens, estimated cost and seconds. The shape that
/// `RequestShape.current(for:)` returns must work on all three; the other shapes are reported, not
/// asserted, so a failing control (today's forced tool) shows what the API said.
///
/// **Off unless asked for.** It runs only when `ASK_CLAUDE_LIVE_KEY` holds an API key (never the
/// Keychain, which a test must never touch) and never on CI. It spends real money, a few cents in
/// all. A skipped run is a vacuous green: the gate quotes the printed table.
///
/// Run: `read -s "ASK_CLAUDE_LIVE_KEY?Key: " && export ASK_CLAUDE_LIVE_KEY`, then
/// `scripts/build-slot swift test --package-path Modules/Sync --filter CloudFilingLiveShapeTests`.
@Suite(.serialized, .enabled(if: liveKey != nil, "no ASK_CLAUDE_LIVE_KEY — the live check is skipped"))
struct CloudFilingLiveShapeTests {

    static let taxonomy = [
        "Finance", "Finance/Bank/2025", "Finance/Bank/2026", "Finance/Taxes/2025", "Finance/Taxes/2026",
        "Work", "Work/Invoices/2025", "Work/Invoices/2026", "Work/Contracts",
        "Receipts/2025", "Receipts/2026", "Travel/2025", "Travel/2026", "Health/Insurance", "Health/Labs",
        "Photos/2025", "Photos/2026", "Home/Lease", "Home/Utilities", "School/Transcripts",
    ]

    static let files: [FilingCandidateFile] = [
        file("Invoice 2026-04.pdf", "pdf", "2026", "Invoice to Northwind Ltd. Consulting, April 2026. Due 30 Apr."),
        file("Statement 2026-03.pdf", "pdf", "2026", "Checking account statement for March 2026. Opening balance 4,210.55."),
        file("Boarding OPO.pdf", "pdf", "2026", "Boarding pass. Lisbon to Porto, 12 Mar 2026. Seat 14C."),
        file("Form 1099-INT 2025.pdf", "pdf", "2025", nil),
        file("Scanned Receipt 4471.pdf", "pdf", "2026", "Hilton Garden Inn. Room 3 nights. Total 412.18."),
        file("IMG_2240.jpg", "jpg", "2026", nil),
    ]

    static func file(_ name: String, _ ext: String, _ year: String?, _ text: String?) -> FilingCandidateFile {
        FilingCandidateFile(filePath: "/live/\(name)", fileName: name, ext: ext, year: year, contentSnippet: text)
    }

    static let mapping = MappingRefineRequest(
        family: "Immigration/Authorization/H-4", members: ["2021-2024", "2024-2026"],
        rows: [.init(source: "Petition", target: "Application"), .init(source: "Approval", target: nil),
               .init(source: "Receipts", target: nil)],
        candidateVocabularies: [["application", "approval", "receipt"]])

    struct Outcome {
        var status = 0
        var stopReason = "-"
        var read = 0
        var expected = 0
        var tokens = ""
        var cost = 0.0
        var seconds = 0.0
        var served = "-"
        var error: String?
        var worked: Bool { status == 200 && error == nil && stopReason != "max_tokens" && read == expected }
    }

    /// Sends `body` in `shape` and reads the stream; `read` counts what the matching parser got.
    static func run(model: AskClaudeModels.Option, shape: CloudFilingProtocol.RequestShape, body: [String: Any],
                    expected: Int, read: ([AskClaudeToolCall]) -> Int) async -> Outcome {
        var outcome = Outcome()
        outcome.expected = expected
        let started = Date()
        do {
            let request = try CloudFilingProtocol.urlRequest(body: body, key: liveKey ?? "", shape: shape)
            let response = try await AskClaudeURLSessionTransport().send(request)
            outcome.status = response.status
            var accumulator = AskClaudeStreamAccumulator()
            var raw = ""
            for try await line in response.lines {
                raw += line + "\n"
                _ = accumulator.apply(line: line)
                if accumulator.finished { break }
            }
            if response.status != 200 {
                outcome.error = String(raw.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            } else if let failure = accumulator.failure {
                outcome.error = "\(failure.type): \(failure.message)"
            }
            accumulator.estimateUnreportedOutput()
            outcome.stopReason = accumulator.stopReason ?? "-"
            outcome.served = accumulator.model ?? "-"
            outcome.read = read(accumulator.toolCalls)
            let u = accumulator.usage
            outcome.tokens = "\(u.inputTokens + u.cacheReadTokens + u.cacheWrite5mTokens + u.cacheWrite1hTokens) in / \(u.outputTokens) out"
            outcome.cost = AskClaudeEngine.cost(of: accumulator, requested: model)
        } catch {
            outcome.error = "\(error)"
        }
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    static func line(_ what: String, _ model: AskClaudeModels.Option, _ shape: CloudFilingProtocol.RequestShape, _ o: Outcome) -> String {
        let verdict = o.worked ? "OK  " : "FAIL"
        return "\(verdict) \(what) · \(model.name) · \(shape.label) · HTTP \(o.status) · stop \(o.stopReason) · "
            + "read \(o.read)/\(o.expected) · \(o.tokens) · \(AskClaudeSpend.format(o.cost)) · "
            + String(format: "%.1f s", o.seconds) + (o.served != model.id && o.served != "-" ? " · served by \(o.served)" : "")
            + (o.error.map { " · \($0)" } ?? "")
    }

    @Test(arguments: AskClaudeModels.options) func theFilingBatch(_ model: AskClaudeModels.Option) async throws {
        var current: Outcome?
        for shape in CloudFilingProtocol.RequestShape.variants(for: model) {
            let body = CloudFilingProtocol.requestBody(model: model.id, taxonomyFolders: Self.taxonomy, files: Self.files, shape: shape)
            let outcome = await Self.run(model: model, shape: shape, body: body, expected: Self.files.count) { calls in
                CloudFilingProtocol.parseVerdicts(toolCalls: calls, files: Self.files)?.count ?? 0
            }
            print(Self.line("refine", model, shape, outcome))
            if shape == .current(for: model) { current = outcome }
        }
        let result = try #require(current)
        #expect(result.worked, "Refine's request in `RequestShape.current(for:)` did not work on \(model.name): \(result.error ?? "stop \(result.stopReason), read \(result.read) of \(result.expected)")")
    }

    @Test(arguments: AskClaudeModels.options) func theFolderNameBatch(_ model: AskClaudeModels.Option) async throws {
        var current: Outcome?
        for shape in CloudFilingProtocol.RequestShape.variants(for: model) {
            let body = MappingRefineProtocol.requestBody(model: model.id, request: Self.mapping, shape: shape)
            let outcome = await Self.run(model: model, shape: shape, body: body, expected: Self.mapping.rows.count) { calls in
                MappingRefineProtocol.parseProposals(toolCalls: calls, rows: Self.mapping.rows)?.count ?? 0
            }
            print(Self.line("names ", model, shape, outcome))
            if shape == .current(for: model) { current = outcome }
        }
        let result = try #require(current)
        #expect(result.worked, "Refine Names' request in `RequestShape.current(for:)` did not work on \(model.name): \(result.error ?? "stop \(result.stopReason), read \(result.read) of \(result.expected)")")
    }
}
