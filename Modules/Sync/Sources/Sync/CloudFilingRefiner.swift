import Events
import Foundation

/// What a Refine request came to (TE335, E2): the answers that arrived, how it ended, and whether
/// anything may have been billed. A pass that stops or fails midway keeps the answers that arrived
/// (LS), because they were paid for and are only suggestions until the person files them.
public struct FilingRefineResult: Sendable, Equatable {
    public enum Ending: Sendable, Equatable {
        /// Claude finished its answer.
        case answered
        /// The person stopped it.
        case stopped
        /// The request failed, or the answer was cut off; the text says why, ready to show.
        case failed(String)
    }

    public var ending: Ending
    /// A verdict for each file Claude placed in a folder.
    public var verdicts: [String: FilingVerdict]
    /// Files Claude answered for, in a folder or with “none”.
    public var answered: Int
    /// Files in the request: the batch, less any beyond the per-request cap.
    public var sent: Int
    /// Whether a request reached the API, so something may have been billed.
    public var started: Bool
    /// The estimated cost of what ran, 0 when nothing started.
    public var costUSD: Double

    public init(ending: Ending, verdicts: [String: FilingVerdict] = [:], answered: Int = 0, sent: Int = 0,
                started: Bool = false, costUSD: Double = 0) {
        self.ending = ending
        self.verdicts = verdicts
        self.answered = answered
        self.sent = sent
        self.started = started
        self.costUSD = costUSD
    }
}

/// The seam for a Refine request to Claude. Unlike ``FilingClassifier`` it says how it ended, so a
/// failure is shown as one and nothing stands in for Claude's answer. Runs off the main actor and
/// stops when its task is cancelled.
public typealias FilingRefineClassifier =
    @Sendable (_ context: FilingContext, _ files: [FilingCandidateFile]) async -> FilingRefineResult

/// Organize's requests to Claude, streamed: Refine, Try Another and Refine Names (TE335). They use
/// the chat's model, one key and Ask Claude's one monthly limit; what they cost goes in that
/// month's total and in Organize's share of it. The request and its parts are
/// ``CloudFilingProtocol``'s and ``MappingRefineProtocol``'s; this does the call and reads the answer
/// as it arrives, so a timeout runs from the last byte, a stop keeps what came, and any request that
/// started is recorded as spend, finished or not.
public enum CloudFilingRefiner {

    /// Files in one request. The output budget is sized for this many.
    public static let maxFiles = 150

    /// The injectable edges: the key, the defaults domain (model, limit, spend), the clock and the
    /// transport. `@unchecked Sendable`: UserDefaults is documented thread-safe.
    public struct Environment: @unchecked Sendable {
        public var readAPIKey: @Sendable () -> String?
        public var defaults: UserDefaults
        public var now: @Sendable () -> Date
        public var transport: AskClaudeTransport

        public init(readAPIKey: @escaping @Sendable () -> String? = { AnthropicKeychain.read() },
                    defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() },
                    transport: AskClaudeTransport = AskClaudeURLSessionTransport()) {
            self.readAPIKey = readAPIKey
            self.defaults = defaults
            self.now = now
            self.transport = transport
        }
    }

    /// The classifier the app installs.
    public static let live: FilingRefineClassifier = { context, files in
        await refine(taxonomyFolders: context.destinations, files: files, environment: Environment())
    }

    /// The Refine Names request the app installs.
    public static let liveNames: MappingRefiner = { request in
        await refineNames(request, environment: Environment())
    }

    static func notStarted(_ reason: String) -> FilingRefineResult {
        FilingRefineResult(ending: .failed(reason))
    }

    /// Why nothing was sent when Ask Claude's one limit is already reached, or nil. Hard, even if the
    /// pre-flight was bypassed.
    static func limitReason(_ env: Environment) -> String? {
        guard case .overLimit(_, let limit) = AskClaudeSpend.state(in: env.defaults, now: env.now()) else { return nil }
        Logger.shared.info("Cloud Filing paused — Ask Claude's monthly limit \(AskClaudeSpend.format(limit)) is reached")
        return "Ask Claude’s monthly limit of \(AskClaudeSpend.format(limit)) is reached. Raise it in Settings ▸ Ask Claude, or wait for the month to turn."
    }

    /// The chat's model, from the same setting its menu writes.
    static func model(_ env: Environment) -> AskClaudeModels.Option {
        AskClaudeModels.option(for: env.defaults.string(forKey: AskClaudeModels.defaultsKey))
    }

    // MARK: Refine

    public static func refine(taxonomyFolders: [String], files allFiles: [FilingCandidateFile],
                              environment env: Environment) async -> FilingRefineResult {
        guard !allFiles.isEmpty else { return FilingRefineResult(ending: .answered) }
        guard let key = env.readAPIKey() else { return notStarted("There is no Claude key to read.") }
        if let reason = limitReason(env) { return notStarted(reason) }

        // The same array feeds the request and the reading of the answer: indices.
        let files = Array(allFiles.prefix(maxFiles))
        let option = model(env)
        let shape = CloudFilingProtocol.RequestShape.current(for: option)
        let body = CloudFilingProtocol.requestBody(model: option.id, taxonomyFolders: taxonomyFolders, files: files, shape: shape)
        guard let request = try? CloudFilingProtocol.urlRequest(body: body, key: key, shape: shape) else {
            return notStarted("The request couldn’t be built.")
        }

        let excerptCount = files.filter { $0.contentSnippet?.isEmpty == false }.count
        let cappedNote = allFiles.count > files.count ? " (capped from \(allFiles.count))" : ""
        Logger.shared.info("Cloud Filing → \(option.name): \(files.count) file(s)\(cappedNote), \(excerptCount) with content excerpt")

        let start = Date()
        var run = await stream(request, transport: env.transport)

        // What arrived, from finished calls and the whole parts of one the stream didn't finish.
        let placements = CloudFilingProtocol.placements(toolCalls: run.accumulator.toolCalls, unfinished: run.accumulator.unfinishedToolInputs)
        let verdicts = CloudFilingProtocol.verdicts(fromPlacements: placements, files: files)
        let answered = CloudFilingProtocol.answeredCount(fromPlacements: placements, fileCount: files.count)
        // A reply that finished without an answer for every file (prose instead of the tool, or the
        // output cap) is not a whole answer: the card says how far it got and offers the rest again,
        // rather than counting the unanswered files as kept.
        if case .answered = run.ending, answered < files.count {
            let truncated = run.accumulator.stopReason == "max_tokens"
            Logger.shared.warning("Cloud Filing response " + (truncated ? "was truncated (max_tokens)" : "ended early")
                                  + " — \(files.count - answered) file(s) are unanswered.")
            run.ending = .failed(truncated ? "Claude’s answer was cut short." : "Claude stopped early.")
        }
        let cost = settle(&run, option: option, env: env)
        let how: String
        switch run.ending {
        case .answered: how = "done"
        case .stopped: how = "stopped"
        case .failed(let reason): how = "failed (\(reason))"
        }
        Logger.shared.info("Cloud Filing \(how): \(option.name) · \(files.count) files · answered \(answered), placed \(verdicts.count) · "
                           + "\(run.accumulator.usage.promptTokens) in / \(run.accumulator.usage.outputTokens) out tok · ~\(AskClaudeSpend.format(cost)) · "
                           + String(format: "%.1f", Date().timeIntervalSince(start)) + "s")
        return FilingRefineResult(ending: run.ending, verdicts: verdicts, answered: answered, sent: files.count,
                                  started: run.started, costUSD: cost)
    }

    // MARK: Refine Names

    /// Proposals for a mapping's folder names, or nil when none came (a failure, a Stop, or no
    /// answer). The same key, model and limit as Refine, streamed.
    public static func refineNames(_ request: MappingRefineRequest, environment env: Environment) async -> [MappingRefineProposal]? {
        guard !request.rows.isEmpty else { return [] }
        guard let key = env.readAPIKey() else { return nil }
        if limitReason(env) != nil { return nil }
        let option = model(env)
        let shape = CloudFilingProtocol.RequestShape.current(for: option)
        let body = MappingRefineProtocol.requestBody(model: option.id, request: request, shape: shape)
        guard let urlRequest = try? CloudFilingProtocol.urlRequest(body: body, key: key, shape: shape) else { return nil }
        Logger.shared.info("Mapping refine → \(option.name): \(request.family), \(request.rows.count) name(s), "
                           + "\(request.sampleFileNames.values.reduce(0) { $0 + $1.count }) sample file name(s)")
        let start = Date()
        var run = await stream(urlRequest, transport: env.transport)
        let cost = settle(&run, option: option, env: env)
        let proposals: [MappingRefineProposal]?
        if case .answered = run.ending {
            proposals = MappingRefineProtocol.parseProposals(toolCalls: run.accumulator.toolCalls, rows: request.rows)
        } else {
            proposals = nil
        }
        let how: String
        switch run.ending {
        case .answered: how = "done"
        case .stopped: how = "stopped"
        case .failed(let reason): how = "failed (\(reason))"
        }
        Logger.shared.info("Mapping refine \(how): \(option.name) · \(proposals?.count ?? 0)/\(request.rows.count) rows answered · "
                           + "~\(AskClaudeSpend.format(cost)) · " + String(format: "%.1f", Date().timeIntervalSince(start)) + "s")
        return proposals
    }

    // MARK: The stream

    /// A request read to its end, a stop, or a failure.
    struct Run {
        var accumulator = AskClaudeStreamAccumulator()
        /// Whether the API accepted the request: from then on it may have been billed.
        var started = false
        var ending = FilingRefineResult.Ending.answered
    }

    static func stream(_ request: URLRequest, transport: AskClaudeTransport) async -> Run {
        var run = Run()
        do {
            let response = try await transport.send(request)
            guard response.status == 200 else {
                var raw = ""
                for try await line in response.lines { raw += line }
                let problem = AskClaudeProblem.from(status: response.status, body: raw, retryAfter: response.retryAfter)
                Logger.shared.warning(AskClaudeProblem.httpLogLine(status: response.status, requestID: response.requestID, body: raw))
                run.ending = .failed(problem.message)
                return run
            }
            run.started = true
            for try await line in response.lines {
                try Task.checkCancellation()
                _ = run.accumulator.apply(line: line)
                if run.accumulator.finished { break }
            }
            try Task.checkCancellation()
            if let failure = run.accumulator.failure {
                run.ending = .failed(failure.type == "overloaded_error"
                                     ? "Claude is busy right now. Try again in a moment."
                                     : failure.message)
            } else if !run.accumulator.finished {
                run.ending = .failed("The connection ended before Claude finished.")
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                run.ending = .stopped
            } else {
                run.ending = .failed(AskClaudeProblem.from(error).message)
            }
        }
        return run
    }

    /// Records what a started request cost: in this month's total and in Organize's share of it.
    /// Anthropic bills a request it ran even when it didn't finish, and a stopped stream never
    /// reports its final output, so that is estimated. Priced from Ask Claude's table at the model
    /// that answered, each attempt at its own rate when a fallback re-ran it.
    static func settle(_ run: inout Run, option: AskClaudeModels.Option, env: Environment) -> Double {
        guard run.started else { return 0 }
        run.accumulator.estimateUnreportedOutput()
        let cost = AskClaudeEngine.cost(of: run.accumulator, requested: option)
        AskClaudeSpend.recordOrganize(cost, in: env.defaults, now: env.now())
        return cost
    }
}
