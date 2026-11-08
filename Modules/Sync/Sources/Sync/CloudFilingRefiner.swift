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

/// Refine's request to Claude, streamed. The request and its parts are ``CloudFilingProtocol``'s;
/// this does the call and reads the answer as it arrives, so a timeout runs from the last byte, a
/// stop keeps what came, and any request that started is recorded as spend, finished or not.
public enum CloudFilingRefiner {

    /// Files in one request. The output budget is sized for this many.
    public static let maxFiles = 150

    /// The injectable edges: the key, the defaults domain (model, caps, spend record), the clock and
    /// the transport. `@unchecked Sendable`: UserDefaults is documented thread-safe.
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

    static func notStarted(_ reason: String) -> FilingRefineResult {
        FilingRefineResult(ending: .failed(reason))
    }

    public static func refine(taxonomyFolders: [String], files allFiles: [FilingCandidateFile],
                              environment env: Environment) async -> FilingRefineResult {
        guard !allFiles.isEmpty else { return FilingRefineResult(ending: .answered) }
        guard let key = env.readAPIKey() else { return notStarted("There is no Claude key to read.") }

        // The budget caps hold even if the pre-flight was bypassed. A cap enforced against a spend
        // record that can't be read would start again from zero, so nothing is sent then.
        if FilingSpendStore.isUnreadable(defaults: env.defaults) {
            Logger.shared.warning("Cloud Filing paused — the recorded spend could not be read, so neither budget cap "
                                  + "can be enforced. The unreadable values are kept under their \".unreadable\" keys; "
                                  + "clear or repair them in Settings to resume.")
            return notStarted("The recorded spend couldn’t be read, so the budget caps can’t be checked.")
        }
        let monthlyCap = env.defaults.double(forKey: FileSyncManager.monthlyBudgetCapKey)
        let totalCap = FileSyncManager.totalBudgetCap(in: env.defaults)
        let monthlySpent = FilingSpendBudget.monthlySpend(entries: FilingSpendStore.entries(defaults: env.defaults), now: env.now())
        let totalSpent = FilingSpendStore.totals(defaults: env.defaults).costUSD
        if FilingSpendBudget.isOverCap(spent: monthlySpent, capUSD: monthlyCap) {
            Logger.shared.info("Cloud Filing paused — monthly budget cap \(FilingSpendFormat.cost(monthlyCap)) reached "
                               + "(\(FilingSpendFormat.cost(monthlySpent)) spent this month)")
            return notStarted("Your monthly budget cap of \(FilingSpendFormat.cost(monthlyCap)) is reached.")
        }
        if FilingSpendBudget.isOverCap(spent: totalSpent, capUSD: totalCap) {
            Logger.shared.info("Cloud Filing paused — total budget cap \(FilingSpendFormat.cost(totalCap)) reached "
                               + "(\(FilingSpendFormat.cost(totalSpent)) spent lifetime)")
            return notStarted("Your total budget cap of \(FilingSpendFormat.cost(totalCap)) is reached.")
        }

        // The same array feeds the request and the reading of the answer: indices.
        let files = Array(allFiles.prefix(maxFiles))
        let model = CloudFilingProtocol.currentModel(
            for: env.defaults.string(forKey: FileSyncManager.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel)
        // Today's request, streamed. The shape the 5.5 models need arrives with the move to the chat's
        // model (E4); the older models Refine runs on until then take this one.
        var shape = CloudFilingProtocol.RequestShape.legacy
        shape.stream = true
        let body = CloudFilingProtocol.requestBody(model: model, taxonomyFolders: taxonomyFolders, files: files, shape: shape)
        guard let request = try? CloudFilingProtocol.urlRequest(body: body, key: key, shape: shape) else {
            return notStarted("The request couldn’t be built.")
        }

        let excerptCount = files.filter { $0.contentSnippet?.isEmpty == false }.count
        let cappedNote = allFiles.count > files.count ? " (capped from \(allFiles.count))" : ""
        Logger.shared.info("Cloud Filing → \(model): \(files.count) file(s)\(cappedNote), \(excerptCount) with content excerpt")

        let start = Date()
        var accumulator = AskClaudeStreamAccumulator()
        var started = false
        var ending = FilingRefineResult.Ending.answered
        do {
            let response = try await env.transport.send(request)
            guard response.status == 200 else {
                var raw = ""
                for try await line in response.lines { raw += line }
                let problem = AskClaudeProblem.from(status: response.status, body: raw, retryAfter: response.retryAfter)
                Logger.shared.warning(AskClaudeProblem.httpLogLine(status: response.status, requestID: response.requestID, body: raw))
                return notStarted(problem.message)
            }
            started = true
            for try await line in response.lines {
                try Task.checkCancellation()
                _ = accumulator.apply(line: line)
                if accumulator.finished { break }
            }
            try Task.checkCancellation()
            if let failure = accumulator.failure {
                ending = .failed(failure.type == "overloaded_error"
                                 ? "Claude is busy right now. Try again in a moment."
                                 : failure.message)
            } else if !accumulator.finished {
                ending = .failed("The connection ended before Claude finished.")
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                ending = .stopped
            } else {
                ending = .failed(AskClaudeProblem.from(error).message)
            }
        }

        // What arrived, from finished calls and the whole parts of one the stream didn't finish.
        let placements = CloudFilingProtocol.placements(toolCalls: accumulator.toolCalls, unfinished: accumulator.unfinishedToolInputs)
        let verdicts = CloudFilingProtocol.verdicts(fromPlacements: placements, files: files)
        let answered = CloudFilingProtocol.answeredCount(fromPlacements: placements, fileCount: files.count)
        if case .answered = ending, accumulator.stopReason == "max_tokens" {
            Logger.shared.warning("Cloud Filing response was truncated (max_tokens) — \(files.count - answered) file(s) are unanswered.")
        }

        // Any request that started is recorded: Anthropic bills a request it ran even when it didn't
        // finish, and a stopped stream never reports its final output, so that is estimated.
        var cost = 0.0
        if started {
            accumulator.estimateUnreportedOutput()
            let u = accumulator.usage
            let usage = CloudFilingProtocol.Usage(inputTokens: u.inputTokens, outputTokens: u.outputTokens,
                                                  cacheCreationTokens: u.cacheWrite5mTokens + u.cacheWrite1hTokens,
                                                  cacheReadTokens: u.cacheReadTokens)
            let priced = CloudFilingProtocol.estimatedCostUSD(model: model, usage: usage)
            if priced == nil {
                Logger.shared.warning("Cloud Filing: no price table for model “\(model)”, so this request's cost is unknown "
                                      + "and is recorded as $0.00; both budget caps under-count by whatever it cost.")
            }
            cost = priced ?? 0
            FilingSpendStore.record(FilingSpendEntry(
                timestamp: env.now(), model: model, fileCount: files.count, placedCount: verdicts.count,
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens, cacheCreationTokens: usage.cacheCreationTokens,
                estimatedCostUSD: cost, costUnpriced: priced == nil), defaults: env.defaults)
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
        let how: String
        switch ending {
        case .answered: how = "done"
        case .stopped: how = "stopped"
        case .failed(let reason): how = "failed (\(reason))"
        }
        Logger.shared.info("Cloud Filing \(how): \(model) · \(files.count) files · answered \(answered), placed \(verdicts.count) · "
                           + "\(accumulator.usage.promptTokens) in / \(accumulator.usage.outputTokens) out tok · ~\(FilingSpendFormat.cost(cost)) · \(elapsed)s")
        return FilingRefineResult(ending: ending, verdicts: verdicts, answered: answered, sent: files.count,
                                  started: started, costUSD: cost)
    }
}
