import CryptoKit
import Events
import Foundation

/// Sends a request and hands back the response’s status and its lines as they arrive.
public protocol AskClaudeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse
}

public struct AskClaudeTransportResponse: Sendable {
    public let status: Int
    public let retryAfter: String?
    public let lines: AsyncThrowingStream<String, Error>
    /// The API's `request-id`, for finding a failed request in the Console.
    public let requestID: String?

    public init(status: Int, retryAfter: String?, lines: AsyncThrowingStream<String, Error>, requestID: String? = nil) {
        self.status = status
        self.retryAfter = retryAfter
        self.lines = lines
        self.requestID = requestID
    }
}

/// The real transport: URLSession’s byte stream, read line by line.
public struct AskClaudeURLSessionTransport: AskClaudeTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AskClaudeTransportResponse(status: http?.statusCode ?? 0,
                                          retryAfter: http?.value(forHTTPHeaderField: "retry-after"),
                                          lines: lines, requestID: http?.value(forHTTPHeaderField: "request-id"))
    }
}

/// What a tool call came to.
public struct AskClaudeToolOutcome: Equatable, Sendable {
    /// What goes back to Claude.
    public let result: String
    public let isError: Bool
    /// What the panel shows as the step, e.g. "Listed Documents/Taxes · 14 items".
    public let step: String
    /// Set when the tool moved the person’s view: "Moved you to Taxes".
    public let movedView: String?
    /// A passage the person may choose to send to Claude, shown as a button.
    public let passage: AskClaudePassage?
    /// A cloud-only file the person may choose to download, shown as a card.
    public let download: AskClaudeDownload?
    /// Filing help's answer, shown as a card with Go to Folder.
    public let filing: AskClaudeFilingCard?
    /// A card of changes to review.
    public let plan: AskClaudePlan?
    /// Buttons that answer Claude's question.
    public let choices: [AskClaudeChoice]?
    /// A rule offered from a correction.
    public let rule: AskClaudeRuleCard?
    /// A card of settings with their real controls.
    public let settings: AskClaudeSettingCard?
    /// A card that runs one of the PDF tools on their click.
    public let pdf: AskClaudePDFCard?
    /// Names a content search found, held for their click.
    public let found: AskClaudeFoundNames?
    /// A change Claude made to its notes, for the ✎ line and its Undo (TE307).
    public let noted: AskClaudeNoted?
    /// The step as the log writes it, when the panel's `step` carries words from the question
    /// (a search's terms, an argument that matched nothing). Nil logs `step` itself.
    public let logStep: String?

    public init(result: String, isError: Bool = false, step: String, logStep: String? = nil, movedView: String? = nil,
                passage: AskClaudePassage? = nil, download: AskClaudeDownload? = nil,
                filing: AskClaudeFilingCard? = nil, plan: AskClaudePlan? = nil, choices: [AskClaudeChoice]? = nil,
                rule: AskClaudeRuleCard? = nil, settings: AskClaudeSettingCard? = nil, pdf: AskClaudePDFCard? = nil,
                found: AskClaudeFoundNames? = nil, noted: AskClaudeNoted? = nil) {
        self.result = result
        self.isError = isError
        self.step = step
        self.logStep = logStep
        self.movedView = movedView
        self.passage = passage
        self.download = download
        self.filing = filing
        self.plan = plan
        self.choices = choices
        self.rule = rule
        self.settings = settings
        self.pdf = pdf
        self.found = found
        self.noted = noted
    }
}

/// A button under Claude's question that answers it: it sends `sends`, the same
/// words they could type, or with nil puts the caret in the text box for them to say.
public struct AskClaudeChoice: Codable, Equatable, Sendable {
    public let label: String
    public let sends: String?

    public init(_ label: String, sends: String?) {
        self.label = label
        self.sends = sends
    }
}

/// Runs Ask Claude’s tools against the app. The app implements it; tests use a stub.
@MainActor
public protocol AskClaudeToolRunning: AnyObject {
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome
}

/// Why a question stopped, in words the panel shows: what’s wrong, and the fix.
public struct AskClaudeProblem: Error, Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case noKey, keyRejected, creditUsedUp, limitReached, rateLimited, busy, offline, declined, failed

        /// The level a problem of this kind is logged at. ERROR: the question failed and nothing on
        /// the user's side explains it. WARN: it didn't go through, for a reason the user can act on
        /// or wait out (the app doesn't retry on its own). INFO: a state the user chose or set up.
        public var logLevel: LogLevel {
            switch self {
            case .failed: return .error
            case .keyRejected, .creditUsedUp, .rateLimited, .busy, .offline: return .warning
            case .noKey, .limitReached, .declined: return .info
            }
        }
    }
    public let kind: Kind
    public let message: String
    /// Whether opening Settings ▸ Ask Claude would fix it.
    public var opensSettings: Bool { kind == .noKey || kind == .keyRejected || kind == .limitReached }

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// Reads an HTTP error status and body.
    public static func from(status: Int, body: String, retryAfter: String?) -> AskClaudeProblem {
        let data = body.data(using: .utf8) ?? Data()
        let parsed = try? JSONFragment.decode(data)
        let type = parsed?["error"]?["type"]?.stringValue ?? ""
        let detail = parsed?["error"]?["message"]?.stringValue ?? ""
        // A chat the API can no longer continue (a turn it now refuses, or one grown too long):
        // only a new chat gets past it, so the message says so.
        let lowered = detail.lowercased()
        if status == 400, ["messages.", "tool_use", "tool_result", "thinking", "prompt is too long"].contains(where: lowered.contains) {
            return AskClaudeProblem(.failed, "Claude can’t continue this chat: \(detail) Start a new chat with the + button to go on.")
        }
        if status == 402 || detail.lowercased().contains("credit balance") {
            return AskClaudeProblem(.creditUsedUp, "Your API credit is used up. It refills with your plan’s next billing cycle, or you can add credit in the Claude Console.")
        }
        switch status {
        case 401:
            return AskClaudeProblem(.keyRejected, "Claude didn’t accept the API key. Check it in Settings ▸ Ask Claude.")
        case 403:
            // A permission error, not a bad key: the key's workspace or region can't use this.
            let what = detail.isEmpty ? "" : " (\(detail))"
            return AskClaudeProblem(.failed, "This API key isn’t allowed to make this request\(what). Check its workspace in the Claude Console, or pick another model in the menu under the text box.")
        case 429:
            let wait = retryAfter.flatMap(Int.init).map { " Try again in \($0) seconds." } ?? " Try again in a moment."
            return AskClaudeProblem(.rateLimited, "Claude is limiting how fast requests can come in." + wait)
        case 529:
            return AskClaudeProblem(.busy, "Claude is busy right now. Try again in a moment.")
        case 500...599:
            return AskClaudeProblem(.busy, "Claude had a problem on its side (\(status)). Try again in a moment.")
        default:
            let what = detail.isEmpty ? (type.isEmpty ? "status \(status)" : type) : detail
            return AskClaudeProblem(.failed, "Claude couldn’t take this question: \(what)")
        }
    }

    /// The log line for an HTTP error reply: status, request ID, and Anthropic's own error type
    /// and message, capped at 300 characters. Anthropic's message names a field, a limit or a
    /// model, never the question. A reply that isn't Anthropic's JSON (a proxy or a portal page)
    /// is logged by size only.
    public static func httpLogLine(status: Int, requestID: String?, body: String) -> String {
        let head = "Ask Claude HTTP \(status) · request \(requestID ?? "unknown")"
        guard let parsed = try? JSONFragment.decode(body.data(using: .utf8) ?? Data()),
              let error = parsed["error"] else {
            return head + " · \(body.utf8.count) bytes, not JSON"
        }
        let type = error["type"]?.stringValue ?? "no type"
        let message = error["message"]?.stringValue ?? ""
        return head + " · \(type)" + (message.isEmpty ? "" : ": \(message.prefix(300))")
    }

    /// Reads a transport error.
    public static func from(_ error: Error) -> AskClaudeProblem {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost:
                return AskClaudeProblem(.offline, "This Mac can’t reach Claude. Check the internet connection and try again.")
            case .timedOut:
                return AskClaudeProblem(.busy, "Claude took too long to answer. Try again.")
            default:
                break
            }
        }
        return AskClaudeProblem(.failed, "The question didn’t go through: \(error.localizedDescription)")
    }
}

/// The model and answer style a question was asked with, by id and raw value.
public struct AskClaudeKeptSetting: Codable, Equatable, Sendable {
    public let model: String
    public let detail: String

    public init(model: String, detail: String) {
        self.model = model
        self.detail = detail
    }
}

/// What the panel hears while a question runs.
public enum AskClaudeEvent: Equatable, Sendable {
    case text(String)
    case thinking
    case step(String, isError: Bool)
    case movedView(String)
    case offer(AskClaudePassage)
    /// Names a content search found, held for their click.
    case found(AskClaudeFoundNames)
    /// A cloud-only file offered for download.
    case offerDownload(AskClaudeDownload)
    /// Filing help's card.
    case filing(AskClaudeFilingCard)
    /// A card of changes.
    case plan(AskClaudePlan)
    /// Buttons answering Claude's question.
    case choices([AskClaudeChoice])
    /// A rule offered from a correction.
    case rule(AskClaudeRuleCard)
    /// A card of settings.
    case settings(AskClaudeSettingCard)
    /// A card that runs a PDF tool on their click.
    case pdf(AskClaudePDFCard)
    /// Claude changed its notes (TE307).
    case noted(AskClaudeNoted)
    /// The question joined carrying their notes (TE307): sent once a chat, and again when they
    /// change them.
    case notesSent(AskClaudeNotesSent)
    /// The question joined the transcript with this model and style; `previous` is the
    /// last question's, nil in a new chat.
    case kept(previous: AskClaudeKeptSetting?, now: AskClaudeKeptSetting)
    /// One round trip finished: its usage and estimated cost.
    case round(AskClaudeUsage, costUSD: Double, model: String)
    case finished(stopReason: String?)
    case problem(AskClaudeProblem)
    /// The answer streamed so far in this round is withdrawn (a refusal mid-answer).
    case retractAnswer
}

/// The conversation, and the loop that runs one question to its answer.
///
/// The transcript is append-only. Earlier turns are **never** edited: that would break the cache
/// and invalidate the thinking blocks the model signed. A user turn joins only once the request
/// carrying it succeeds, so a failed request leaves nothing half-sent. Edit and Retry only cut it
/// back to where a question began (`rewind`): what stays is byte for byte what was sent before,
/// thinking blocks and all, as the API allows.
@MainActor
public final class AskClaudeEngine {

    /// Tool rounds per question. After the last one, the tools answer that the budget
    /// is spent, and Claude answers with what it has.
    public static let maxToolRounds = 8

    public private(set) var transcript: [JSONFragment] = []
    public var handles = AskClaudeHandles()
    /// The last screen card sent, so an unchanged screen goes as one line.
    private var lastCard: String?
    /// A digest of the notes Claude has (TE307), so they go once a chat and again only when they
    /// change: nil while Claude has none. A digest, so the chat's file holds no second copy.
    private var notesKnown: String?
    /// Tool results owed to the transcript’s last assistant turn when a question stopped before
    /// sending them (stopped by the person, or past the tool limit). The API needs every tool call
    /// answered before anything else, so they lead the next question’s turn.
    private var owedResults: [JSONFragment] = []
    /// The digest of the system text and tools this transcript was started with
    /// (`AskClaudeRequest.fixedDigest`). The API holds replayed thinking to the system text and
    /// tool list it was made under: an account it checks strictly refuses a changed one, and one
    /// it doesn't uses thinking made for other instructions. So a chat a new build changed them
    /// under starts over. An older saved chat holds `model|style|digest`; `isCurrent(setting:)`
    /// reads either.
    public private(set) var setting: String?

    /// Whether a chat started under `setting` can carry on in this build. The model and style don't
    /// count: every question says which in its own `<setting>` block.
    public static func isCurrent(setting: String) -> Bool {
        setting.split(separator: "|").last.map(String.init) == AskClaudeRequest.fixedDigest
    }

    /// The model and style of the last question that joined the transcript, so a switch is noted
    /// once, at the question that made it. Nil in a new chat and in an older saved one.
    public private(set) var lastKept: AskClaudeKeptSetting?
    /// The size of the chat as of the last round that joined: what that round sent plus what it
    /// answered, which the next request resends. A switch's catch-up cost is estimated from it.
    /// Nil until a round joins.
    public private(set) var contextTokens: Int?

    /// Where a question that joined the transcript begins, with what the chat was just before it,
    /// so `rewind` can take the chat back there.
    public struct Turn: Codable, Equatable, Sendable {
        /// Its user message's index in the transcript.
        public let start: Int
        public let lastKept: AskClaudeKeptSetting?
        public let contextTokens: Int?
        /// The notes Claude had before it (TE307); nil in an older saved chat, which then sends
        /// them again after a rewind, as harmless as it is rare.
        public var notesKnown: String?
    }

    /// One per question that joined, in order. Empty in an older saved chat, which can't be
    /// rewound past.
    public private(set) var turns: [Turn] = []

    private let transport: AskClaudeTransport
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Their notes as the file holds them now, read at each question.
    private let notes: () -> String

    /// Everything a chat needs to carry on after the app quits.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var transcript: [JSONFragment]
        public var handles: AskClaudeHandles
        public var lastCard: String?
        public var owedResults: [JSONFragment]
        public var setting: String?
        /// Optional, so an older saved chat without them still decodes.
        public var lastKept: AskClaudeKeptSetting?
        public var contextTokens: Int?
        public var turns: [Turn]?
        public var notesKnown: String?
    }

    public var snapshot: Snapshot {
        Snapshot(transcript: transcript, handles: handles, lastCard: lastCard, owedResults: owedResults, setting: setting,
                 lastKept: lastKept, contextTokens: contextTokens, turns: turns.isEmpty ? nil : turns,
                 notesKnown: notesKnown)
    }

    public func restore(_ snapshot: Snapshot) {
        transcript = snapshot.transcript
        handles = snapshot.handles
        lastCard = snapshot.lastCard
        owedResults = snapshot.owedResults
        setting = snapshot.setting
        lastKept = snapshot.lastKept
        contextTokens = snapshot.contextTokens
        turns = snapshot.turns ?? []
        notesKnown = snapshot.notesKnown
    }

    /// Takes the chat back to just before question `turn`, for Edit on a question or Retry on the
    /// last answer. Only a run at the end goes, never one from the middle, so every thinking block
    /// left is where the API signed it. Tool results that question carried for the turn before
    /// are owed again, and the next question sends the whole screen, since the last one Claude saw
    /// may be gone. The handles stay: one minted in what went still means the same file.
    /// - Returns: false, changing nothing, when there's no such question.
    @discardableResult
    public func rewind(toTurn turn: Int) -> Bool {
        guard turns.indices.contains(turn), transcript.indices.contains(turns[turn].start) else { return false }
        let mark = turns[turn]
        let content = transcript[mark.start]["content"]?.arrayValue ?? []
        owedResults = Array(content.prefix { $0["type"]?.stringValue == "tool_result" })
        transcript.removeSubrange(mark.start...)
        turns.removeSubrange(turn...)
        lastKept = mark.lastKept
        contextTokens = mark.contextTokens
        notesKnown = mark.notesKnown
        lastCard = nil
        return true
    }

    public init(transport: AskClaudeTransport = AskClaudeURLSessionTransport(),
                defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
                notes: @escaping () -> String = { AskClaudeNotes().read() }) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
        self.notes = notes
    }

    /// The text of the screen block for this question: the full card, or one line when nothing
    /// changed since the last question.
    public func screenBlock(for card: String) -> String {
        card == lastCard ? "<screen unchanged/>" : card
    }

    /// Their notes for this question (TE307): the block to send and what Claude has once it joins,
    /// or nil when Claude already has them as they are.
    func notesBlock(for text: String) -> (block: JSONFragment, sent: AskClaudeNotesSent, known: String?)? {
        let now = Self.notesDigest(text)
        guard now != notesKnown else { return nil }
        guard let now else { return (AskClaudeRequest.notesBlock(""), .cleared, nil) }
        return (AskClaudeRequest.notesBlock(text), notesKnown == nil ? .first : .changed, now)
    }

    /// What Claude has when its notes changed under it mid-question: matches no file, so the next
    /// question sends them again, as changed.
    static let notesStale = "stale"

    /// Nil for no notes, so an empty file and a missing one read the same. Blank lines and empty
    /// headings don't count: a Retry that takes Claude's note back may leave the layout tidier,
    /// and that is no change of theirs to report.
    static func notesDigest(_ text: String) -> String? {
        let body = AskClaudeNotes.substance(text)
        guard !body.isEmpty else { return nil }
        return SHA256.hash(data: Data(body.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs one question. `card` is the rendered screen; `onEvent` hears progress on the main actor.
    /// Returns whether the question joined the transcript, which is whether Claude has it. Not read
    /// from how it ended: a stop or an empty first turn ends quietly with nothing kept, and a
    /// problem after the first round comes once the question is in.
    @discardableResult
    public func ask(_ question: String, card: String, key: String?, model: AskClaudeModels.Option,
                    detail chosenDetail: AskClaudeDetail? = nil,
                    tools: AskClaudeToolRunning, onEvent: (AskClaudeEvent) -> Void) async -> Bool {
        // Every problem and the way the question ended go in the log as well as the panel, so a
        // failed question's summary line never reads like a success.
        var ended = "none"
        // Set when a problem came back from a non-200 HTTP reply, whose line (`stream`) already carries
        // Anthropic's own message: the problem line then names the kind alone, so it's written once.
        var fromHTTPReply = false
        func emit(_ event: AskClaudeEvent) {
            switch event {
            case .problem(let problem):
                ended = problem.kind.rawValue
                let line = "Ask Claude problem (\(problem.kind.rawValue))"
                    + (fromHTTPReply ? ", from the HTTP reply above" : ": \(problem.message)")
                switch problem.kind.logLevel {
                case .error: Logger.shared.error(line)
                case .warning: Logger.shared.warning(line)
                default: Logger.shared.info(line)
                }
            case .finished(let reason):
                ended = reason ?? "end"
            default:
                break
            }
            onEvent(event)
        }
        guard let key, !key.isEmpty else {
            emit(.problem(AskClaudeProblem(.noKey, "Add your Claude API key in Settings ▸ Ask Claude to ask questions.")))
            return false
        }
        if case .overLimit(let spent, let limit) = AskClaudeSpend.state(in: defaults, now: now()) {
            let reset = AskClaudeSpend.resetDate(after: now()).formatted(.dateTime.month(.wide).day())
            emit(.problem(AskClaudeProblem(.limitReached,
                "Ask Claude has used \(AskClaudeSpend.format(spent)) of its \(AskClaudeSpend.format(limit)) monthly limit. It resets on \(reset), or you can raise the limit in Settings ▸ Ask Claude.")))
            return false
        }

        let screen = screenBlock(for: card)
        // Read once per question, so its rounds all go out with one style.
        let detail = chosenDetail ?? AskClaudeDetail.stored(in: defaults)
        let kept = AskClaudeKeptSetting(model: model.id, detail: detail.rawValue)
        if transcript.isEmpty { setting = AskClaudeRequest.fixedDigest }
        // Their notes go once a chat and again when they change: read now, so every round agrees.
        let notesNow = notesBlock(for: notes())
        // Tool results owed to the last turn must lead (the API answers every call first); then
        // which model and style this question is for, the screen, and the question.
        var pending: JSONFragment = .object([
            "role": .string("user"),
            "content": .array(owedResults + [
                AskClaudeRequest.settingBlock(model: model, detail: detail),
            ] + (notesNow.map { [$0.block] } ?? []) + [
                .object(["type": .string("text"), "text": .string(screen)]),
                .object(["type": .string("text"), "text": .string(AskClaudeRequest.defused(question))]),
            ]),
        ])
        var round = 0
        // What Claude's own notes change leaves the notes as, applied once its result joins.
        var notesAfterTools: String??
        var joined = false
        let askedAt = Date()
        var spent = 0.0
        var used = AskClaudeUsage()
        var toolNames: [String] = []
        // One summary line per question, however it ends.
        defer {
            Logger.shared.info("Ask Claude question done: \(model.id) \(detail.rawValue) · \(round) round(s) · \(Self.describe(used)) · \(AskClaudeSpend.format(spent)) · "
                + "tools: \(toolNames.isEmpty ? "none" : toolNames.joined(separator: ", ")) · \(Self.seconds(since: askedAt))"
                + (screen == card ? " · screen \(card.count) chars" : " · screen unchanged") + " · ended \(ended)")
        }
        while true {
            round += 1
            let body = AskClaudeRequest.body(model: model, messages: transcript + [pending])
            let roundAt = Date()
            var firstWordAt: Date?
            var accumulator = AskClaudeStreamAccumulator()
            do {
                let request = try AskClaudeRequest.urlRequest(body: body, key: key, model: model)
                try await stream(request, into: &accumulator) { event in
                    if firstWordAt == nil, case .text = event { firstWordAt = Date() }
                    emit(event)
                }
            } catch {
                // After the first round, `pending` holds tool results the transcript’s last turn is
                // waiting on; they lead the next question. The first round’s pending turn is the
                // question itself, which simply never happened.
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                // A round the API started is billed even when it doesn't finish: what it reported
                // so far counts toward the limit.
                if accumulator.model != nil {
                    accumulator.estimateUnreportedOutput()
                    let cost = Self.cost(of: accumulator, requested: model)
                    AskClaudeSpend.record(cost, in: defaults, now: now())
                    spent += cost
                    used = used + accumulator.usage
                    emit(.round(accumulator.usage, costUSD: cost, model: accumulator.model ?? model.id))
                }
                // Stopping ends the stream quietly or with a cancellation; either way it's a stop.
                if Task.isCancelled || error is CancellationError {
                    emit(.finished(stopReason: "canceled"))
                } else if let refused = error as? RefusedReply {
                    fromHTTPReply = true
                    emit(.problem(refused.problem))
                } else if let problem = error as? AskClaudeProblem {
                    emit(.problem(problem))
                } else {
                    emit(.problem(AskClaudeProblem.from(error)))
                }
                return joined
            }

            let served = AskClaudeModels.price(forServedModel: accumulator.model, requested: model)
            let cost = Self.cost(of: accumulator, requested: model)
            AskClaudeSpend.record(cost, in: defaults, now: now())
            spent += cost
            used = used + accumulator.usage
            toolNames += accumulator.toolCalls.map(\.name)
            // One line per round trip: enough to see where a question's tokens and time went.
            Logger.shared.info("Ask Claude round \(round): \(accumulator.model ?? model.id) · \(Self.describe(accumulator.usage)) · "
                + "\(AskClaudeSpend.format(cost)) · stop \(accumulator.stopReason ?? "none")"
                + (accumulator.toolCalls.isEmpty ? "" : " · calls \(accumulator.toolCalls.map(\.name).joined(separator: ", "))")
                + " · first word \(firstWordAt.map { Self.seconds($0.timeIntervalSince(roundAt)) } ?? "none") · \(Self.seconds(since: roundAt))")
            if !served.known {
                Logger.shared.warning("Ask Claude: no price for \(accumulator.model ?? "?"); estimated at \(model.id)’s rates")
            }
            emit(.round(accumulator.usage, costUSD: cost, model: accumulator.model ?? model.id))

            if accumulator.stopReason == "refusal" {
                // The refused turn doesn't join the transcript, and what it streamed is withdrawn.
                // Results a tool round produced are still owed to the turn before it.
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                emit(.retractAnswer)
                // Haiku has no fallback model to answer instead, so the menu is the way on.
                emit(.problem(AskClaudeProblem(.declined, model.sendsFallbacks
                    ? "Claude declined to answer this one. Try asking it another way."
                    : "\(model.displayName) declined to answer this one. Try asking it another way, or pick another model in the menu under the text box.")))
                return joined
            }
            // An empty turn can't be sent back (the API refuses empty content and empty text), so it
            // doesn't join the transcript: an empty text block is dropped, and a turn left with only
            // its thinking counts as empty. Checked before the first round's bookkeeping, so results
            // still owed stay owed and the screen Claude never got isn't taken as sent.
            let content = accumulator.content.filter { !($0["type"]?.stringValue == "text" && ($0["text"]?.stringValue ?? "").isEmpty) }
            guard content.contains(where: { !["thinking", "redacted_thinking"].contains($0["type"]?.stringValue ?? "") }) else {
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                emit(.finished(stopReason: accumulator.stopReason))
                return joined
            }
            if round == 1 {
                lastCard = card
                owedResults = []
                turns.append(Turn(start: transcript.count, lastKept: lastKept, contextTokens: contextTokens,
                                  notesKnown: notesKnown))
                if let notesNow {
                    notesKnown = notesNow.known
                    emit(.notesSent(notesNow.sent))
                }
            } else if let known = notesAfterTools {
                // Claude has its own change now: the results that carry it joined.
                notesKnown = known
                notesAfterTools = nil
            }
            transcript.append(pending)
            joined = true
            transcript.append(.object(["role": .string("assistant"), "content": .array(content)]))
            contextTokens = accumulator.usage.promptTokens + accumulator.usage.outputTokens
            if round == 1 {
                // The question has joined the chat, its setting with it: the one moment a switch
                // is known to have reached Claude.
                let previous = lastKept
                lastKept = kept
                if let previous, previous != kept {
                    Logger.shared.info("Ask Claude switched: \(previous.model) \(previous.detail) → \(kept.model) \(kept.detail)")
                }
                emit(.kept(previous: previous, now: kept))
            }

            let calls = accumulator.toolCalls
            guard accumulator.stopReason == "tool_use", !calls.isEmpty else {
                // A turn cut off mid-call (max_tokens) still holds its tool_use blocks, and the
                // API wants each answered before anything else.
                owedResults = calls.map { Self.result(for: $0, text: "Not run: the answer was cut off before this call finished.", isError: true) }
                emit(.finished(stopReason: accumulator.stopReason))
                return joined
            }
            // The budget answer went back once and Claude still wants tools: stop here rather than
            // pay for more rounds that can only be refused.
            if round > Self.maxToolRounds + 1 {
                owedResults = calls.map { Self.result(for: $0, text: "Stopped: the tool limit for that question was reached.", isError: true) }
                emit(.problem(AskClaudeProblem(.failed, "Claude kept looking past the tool limit for one question. Try a narrower question.")))
                return joined
            }
            // Every result goes back in one user turn, as the API expects for parallel calls.
            var results: [JSONFragment] = []
            for call in calls {
                let outcome: AskClaudeToolOutcome
                // The notes as Claude last had them, before its change: if they changed in between
                // (Settings, another editor), Claude has its change but not theirs.
                let notesBefore = call.name == AskClaudeToolCatalog.Name.notes.rawValue ? Self.notesDigest(notes()) : nil
                if Task.isCancelled {
                    // Stopped: the calls not yet run are answered without running them, so the
                    // view doesn't move after the person pressed Stop.
                    outcome = AskClaudeToolOutcome(result: "Not run: they stopped the question.", isError: true,
                                                   step: "Stopped before \(call.name)")
                    Logger.shared.info("Ask Claude tool \(call.name): not run, the question was stopped")
                    emit(.step(outcome.step, isError: true))
                    results.append(Self.result(for: call, text: outcome.result, isError: true))
                    continue
                } else if round > Self.maxToolRounds {
                    outcome = AskClaudeToolOutcome(result: "The tool budget for this question is used up. Answer with what you have.",
                                                   isError: true, step: "Stopped looking: tool limit reached")
                } else {
                    // A local copy: a stored property can’t be held `inout` across a suspension.
                    var working = handles
                    outcome = await tools.run(call, handles: &working)
                    handles = working
                }
                // One line per tool call: what it did, or why not, and whether it moved their view.
                // `logStep` where the panel's words include the question's own (a search's terms).
                Logger.shared.info("Ask Claude tool \(call.name): \(outcome.logStep ?? outcome.step)" + (outcome.isError ? " (refused)" : "")
                    + (outcome.movedView.map { " · \($0)" } ?? ""))
                emit(.step(outcome.step, isError: outcome.isError))
                if let moved = outcome.movedView { emit(.movedView(moved)) }
                if let passage = outcome.passage { emit(.offer(passage)) }
                if let found = outcome.found { emit(.found(found)) }
                if let download = outcome.download { emit(.offerDownload(download)) }
                if let filing = outcome.filing { emit(.filing(filing)) }
                if let plan = outcome.plan { emit(.plan(plan)) }
                if let choices = outcome.choices { emit(.choices(choices)) }
                if let rule = outcome.rule { emit(.rule(rule)) }
                if let settings = outcome.settings { emit(.settings(settings)) }
                if let pdf = outcome.pdf { emit(.pdf(pdf)) }
                if let noted = outcome.noted {
                    let had = notesAfterTools ?? notesKnown
                    notesAfterTools = notesBefore == had ? Self.notesDigest(notes()) : Self.notesStale
                    emit(.noted(noted))
                }
                results.append(Self.result(for: call, text: outcome.result, isError: outcome.isError))
            }
            if Task.isCancelled {
                owedResults = results
                // The owed results lead the next question, so Claude will have its own change.
                if let known = notesAfterTools { notesKnown = known }
                emit(.finished(stopReason: "canceled"))
                return joined
            }
            pending = .object(["role": .string("user"), "content": .array(results)])
        }
    }

    /// "300 new + 4.5K cached + 0 written in, 700 out".
    static func describe(_ u: AskClaudeUsage) -> String {
        func n(_ v: Int) -> String { v.formatted(.number.notation(.compactName)) }
        return "\(n(u.inputTokens)) new + \(n(u.cacheReadTokens)) cached + \(n(u.cacheWrite5mTokens + u.cacheWrite1hTokens)) written in, \(n(u.outputTokens)) out"
    }

    static func seconds(since start: Date) -> String { seconds(Date().timeIntervalSince(start)) }
    static func seconds(_ interval: TimeInterval) -> String { String(format: "%.1f s", interval) }

    /// Every tool result goes through here, so nothing a tool read (a file's name or text, the
    /// on-device answer) can pass for the app's `<setting>` block.
    static func result(for call: AskClaudeToolCall, text: String, isError: Bool) -> JSONFragment {
        var result: [String: JSONFragment] = [
            "type": .string("tool_result"),
            "tool_use_id": .string(call.id),
            // A key in a file a tool read — a .env, a shell profile — never reaches Claude.
            "content": .string(AskClaudeRequest.defused(AskClaudeKeyCatch.masked(text, joiningLines: false))),
        ]
        if isError { result["is_error"] = .bool(true) }
        return .object(result)
    }

    /// A round's cost: per attempt when a fallback re-ran it (`usage.iterations`), each at the
    /// rates of the model that ran it; otherwise the top-level usage at the served model's rates.
    nonisolated static func cost(of accumulator: AskClaudeStreamAccumulator, requested: AskClaudeModels.Option) -> Double {
        let served = AskClaudeModels.price(forServedModel: accumulator.model, requested: requested).price
        let attempts = accumulator.iterations.compactMap { iteration -> Double? in
            var usage = AskClaudeUsage()
            usage.merge(iteration)
            guard usage.promptTokens + usage.outputTokens > 0 else { return nil }
            // An attempt that doesn't name its model: a fallback's is the served one's, any other
            // is the declined attempt on the model that was asked.
            let named = iteration["model"]?.stringValue
                ?? (iteration["type"]?.stringValue == "fallback_message" ? accumulator.model : requested.id)
            let price = named.map { AskClaudeModels.price(forServedModel: $0, requested: requested).price } ?? served
            return AskClaudeModels.cost(of: usage, at: price)
        }
        return attempts.count > 1 ? attempts.reduce(0, +) : AskClaudeModels.cost(of: accumulator.usage, at: served)
    }

    /// A problem from a non-200 reply, whose log line `stream` has already written. Problems after
    /// a 200 (an error event mid-answer, a stream cut off) are thrown bare and log their own words.
    private struct RefusedReply: Error {
        let problem: AskClaudeProblem
    }

    private func stream(_ request: URLRequest, into accumulator: inout AskClaudeStreamAccumulator,
                        onEvent: (AskClaudeEvent) -> Void) async throws {
        let response = try await transport.send(request)
        if response.status != 200 {
            var body = ""
            for try await line in response.lines { body += line }
            // The one line with Anthropic's own words for it; the problem line that follows names
            // the kind. At the kind's level, so a rejected request is an ERROR, a busy server a WARN.
            let problem = AskClaudeProblem.from(status: response.status, body: body, retryAfter: response.retryAfter)
            let line = AskClaudeProblem.httpLogLine(status: response.status, requestID: response.requestID, body: body)
            switch problem.kind.logLevel {
            case .error: Logger.shared.error(line)
            case .warning: Logger.shared.warning(line)
            default: Logger.shared.info(line)
            }
            throw RefusedReply(problem: problem)
        }
        for try await line in response.lines {
            try Task.checkCancellation()
            switch accumulator.apply(line: line) {
            case .text(let piece): onEvent(.text(piece))
            case .thinking: onEvent(.thinking)
            case .toolStarted, nil: break
            }
            if accumulator.finished { break }
        }
        // A cancelled stream can simply end, which would otherwise read as "cut off".
        try Task.checkCancellation()
        if let failure = accumulator.failure {
            throw failure.type == "overloaded_error"
                ? AskClaudeProblem(.busy, "Claude is busy right now. Try again in a moment.")
                : AskClaudeProblem(.failed, "Claude stopped partway: \(failure.message)")
        }
        guard accumulator.finished else {
            throw AskClaudeProblem(.failed, "The answer was cut off before it finished. Try again.")
        }
    }
}
