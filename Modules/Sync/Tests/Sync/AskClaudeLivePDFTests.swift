import Foundation
import Testing
@testable import Sync

/// The key the live check spends, from the environment and nowhere else.
private let askClaudeLiveKey = ProcessInfo.processInfo.environment["ASK_CLAUDE_LIVE_KEY"].flatMap { $0.isEmpty ? nil : $0 }

/// **What Claude actually does with the `pdf` tool, asked for real** (TE294 step 4, decision IG).
///
/// Every other Ask Claude test scripts the model's answer; this one sends real questions to the
/// Messages API and checks the tool calls that come back, and the answer's words where they matter:
/// never "done" before their click, and no "nothing" in a refusal (Haiku once said "I can only copy
/// nothing, edit nothing"). Only the tools are stubbed — nothing on disk is read or changed.
///
/// **Off unless asked for.** It runs only when `ASK_CLAUDE_LIVE_KEY` holds an API key — never the
/// Keychain, which a test must never touch — and never on CI. It spends real money: each question
/// is short and most of each request is cached, and the run prints what it cost. A skipped run is
/// a vacuous green: the gate quotes the count line, 18 prompts × 2 models × 3 runs.
@Suite(.serialized, .enabled(if: askClaudeLiveKey != nil, "no ASK_CLAUDE_LIVE_KEY — the live check is skipped"))
struct AskClaudeLivePDFTests {
    static let key = askClaudeLiveKey
    static let runs = ProcessInfo.processInfo.environment["ASK_CLAUDE_LIVE_RUNS"].flatMap(Int.init) ?? 3

    /// One folder's screen, as the panel would send it.
    static let screen = """
    <screen>
    workspace: Browse · source: iCloud Drive · folder: Documents/Housing
    sources: iCloud Drive, Dropbox
    sort: name · 9 items (0 folders) · 31.4 MB in files
    rows: handle|name|kind|size|modified|tags
    r1|Lease 2026.docx|Word document|61 KB|2026-10-03|
    r2|Tax Scan 2025.pdf|PDF document|18.2 MB|2026-04-11|
    r3|2025 Return.pdf|PDF document|1.4 MB|2026-04-14|
    r4|Chase Statement Oct.pdf|PDF document|1.2 MB|2026-11-01|
    r5|Receipt Hilton Sep 3.pdf|PDF document|210 KB|2026-09-03|
    r6|Receipt Hyatt Sep 5.pdf|PDF document|180 KB|2026-09-05|
    r7|Receipt Marriott Sep 8.pdf|PDF document|195 KB|2026-09-08|
    r8|W-9 Agency.pdf|PDF document|96 KB|2026-10-20|
    r9|Locked Notice.pdf|PDF document|88 KB|2026-08-02|
    </screen>
    """

    /// Records every call and answers as the app's tools would, without touching anything.
    final class Recorder: AskClaudeToolRunning {
        var calls: [AskClaudeToolCall] = []
        func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome {
            calls.append(call)
            guard call.name == "pdf" else {
                return AskClaudeToolOutcome(result: "This check answers only the pdf tool. Answer from the screen.", step: "Stubbed")
            }
            switch call.string("action") {
            case "info":
                return AskClaudeToolOutcome(result: "“Chase Statement Oct.pdf”: 8 pages, 1.2 MB, no form fields.", step: "Read")
            case "fill":
                return AskClaudeToolOutcome(result: "Opened W-9 Agency.pdf in Edit with Fill & Sign on. It has 11 form fields. They type and sign there; Save Filled Copy writes a copy next to it, and you’re told when they save. Say so in a line and stop.", step: "Opened")
            default:
                return AskClaudeToolOutcome(result: "Offered them a card. Nothing has happened: they click its button or Not Now. The card reads the files, says what the copy loses, and makes a new file next to each original; the original stays as it was.\nSay in one line what the card will make, and stop. Never say it’s done.", step: "Offered")
            }
        }

        var pdfCalls: [AskClaudeToolCall] { calls.filter { $0.name == "pdf" } }
        func actions() -> [String] { pdfCalls.compactMap { $0.string("action") } }
    }

    struct Prompt: CustomTestStringConvertible, Sendable {
        let question: String
        /// Checks the calls and the answer; nil when they pass, else what's wrong.
        let check: @Sendable (_ calls: [AskClaudeToolCall], _ answer: String) -> String?
        var testDescription: String { question }
    }

    static func handles(_ call: AskClaudeToolCall) -> [String] { call.strings("handles") ?? [] }

    /// A card was offered for `action` on `handles`, and the answer didn't say it was done.
    static func offered(_ action: String, _ expected: [String], also: (@Sendable (AskClaudeToolCall) -> String?)? = nil)
    -> @Sendable ([AskClaudeToolCall], String) -> String? {
        { calls, answer in
            let pdf = calls.filter { $0.name == "pdf" }
            guard let call = pdf.last(where: { $0.string("action") == action }) else {
                return "no pdf \(action) call; calls: \(calls.map { "\($0.name) \($0.input)" })"
            }
            if Set(handles(call)) != Set(expected) { return "handles \(handles(call)), not \(expected)" }
            if calls.contains(where: { $0.name == "propose_changes" }) { return "it proposed changes instead of a PDF card" }
            if let problem = also?(call) { return problem }
            return saysDone(answer)
        }
    }

    /// "I've saved it", "it's done": said before their click.
    static func saysDone(_ answer: String) -> String? {
        let said = answer.lowercased()
        let done = ["saved", "compressed", "protected", "combined", "rotated", "split", "deleted", "removed", "extracted", "cleaned"]
        let claims = ["has been saved", "it’s done", "it's done", "is done"]
            + done.flatMap { ["i’ve \($0)", "i've \($0)", "i \($0)", "i have \($0)"] }
        for claim in claims
        where said.contains(claim) {
            return "said “\(claim)” before their click: \(answer)"
        }
        return nil
    }

    /// No card, and a refusal that doesn't garble its negation.
    static func refuses(_ calls: [AskClaudeToolCall], _ answer: String) -> String? {
        if calls.contains(where: { $0.name == "pdf" && $0.string("action") != "info" }) {
            return "offered a PDF card: \(calls.filter { $0.name == "pdf" }.map(\.input))"
        }
        if calls.contains(where: { $0.name == "propose_changes" }) { return "proposed changes" }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "said nothing" }
        let said = answer.lowercased()
        for garble in ["copy nothing", "edit nothing", "can only copy", "can only edit"] where said.contains(garble) {
            return "garbled the refusal: \(answer)"
        }
        return nil
    }

    static let prompts: [Prompt] = [
        Prompt(question: "save the lease as a PDF", check: offered("save_as_pdf", ["r1"])),
        Prompt(question: "make the tax scan smaller", check: offered("compress", ["r2"], also: { call in
            call.input["under_mb"].map { "made up a size: \($0)" } })),
        Prompt(question: "get the tax scan under 5 MB so I can email it", check: offered("compress", ["r2"], also: { call in
            AskClaudeLivePDFTests.number(call.input["under_mb"]) == 5 ? nil : "under_mb is \(String(describing: call.input["under_mb"]))" })),
        Prompt(question: "put a password on the 2025 return", check: offered("protect", ["r3"], also: { call in
            call.input.objectValue?.keys.contains { $0.lowercased().contains("password") } == true ? "sent a password field" : nil })),
        Prompt(question: "take pages 3 to 5 out of the Chase statement as their own file", check: offered("extract", ["r4"], also: { call in
            let pages = (call.string("pages") ?? "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "–", with: "-")
            return pages == "3-5" ? nil : "pages \(pages)" })),
        Prompt(question: "delete the first page of the Chase statement", check: offered("delete_pages", ["r4"], also: { call in
            call.string("pages")?.trimmingCharacters(in: .whitespaces) == "1" ? nil : "pages \(String(describing: call.string("pages")))" })),
        Prompt(question: "split the Chase statement into two files, the second starting at page 4", check: offered("split", ["r4"], also: { call in
            call.input["split_at"]?.arrayValue?.compactMap(\.intValue) == [4] ? nil : "split_at \(String(describing: call.input["split_at"]))" })),
        Prompt(question: "combine the three hotel receipts into one PDF, in date order", check: offered("combine", ["r5", "r6", "r7"], also: { call in
            AskClaudeLivePDFTests.handles(call) == ["r5", "r6", "r7"] ? nil : "order \(AskClaudeLivePDFTests.handles(call))" })),
        Prompt(question: "rotate the tax scan to the right", check: offered("rotate", ["r2"], also: { call in
            (call.string("turn") ?? "right") == "right" ? nil : "turn \(String(describing: call.string("turn")))" })),
        // No direction: the card has the choice, so it's offered at once rather than asked about.
        Prompt(question: "rotate the tax scan", check: offered("rotate", ["r2"], also: { call in
            (call.string("turn") ?? "right") == "right" ? nil : "turn \(String(describing: call.string("turn")))" })),
        Prompt(question: "remove the password from Locked Notice", check: offered("remove_password", ["r9"])),
        Prompt(question: "clean the metadata off the Chase statement", check: offered("clean_metadata", ["r4"])),
        Prompt(question: "I need to fill in the W-9", check: { calls, answer in
            guard calls.contains(where: { $0.name == "pdf" && $0.string("action") == "fill" && handles($0) == ["r8"] }) else {
                return "no pdf fill on r8: \(calls.map(\.input))"
            }
            return nil
        }),
        Prompt(question: "how many pages does the Chase statement have?", check: { calls, answer in
            calls.contains(where: { $0.name == "pdf" && $0.string("action") == "info" }) && answer.contains("8")
                ? nil : "didn’t read it with info, or didn’t say 8: \(answer)"
        }),
        Prompt(question: "copy this whole folder to Dropbox", check: refuses),
        // Fill opens Edit with no card: never unless they asked to fill or sign.
        Prompt(question: "what is the W-9 for?", check: { calls, answer in
            calls.contains(where: { $0.name == "pdf" && $0.string("action") == "fill" }) ? "opened the form for fill unasked" : nil
        }),
        Prompt(question: "change the year in the lease to 2027", check: refuses),
        Prompt(question: "move the last page of the Chase statement to the front", check: { calls, answer in
            let actions = calls.filter { $0.name == "pdf" }.compactMap { $0.string("action") }
            if actions.contains("reorder") {
                guard let pages = calls.last(where: { $0.string("action") == "reorder" })?.string("pages"),
                      pages.replacingOccurrences(of: " ", with: "").hasPrefix("8,") else {
                    return "reorder didn’t start with page 8: \(calls.map(\.input))"
                }
                return saysDone(answer)
            }
            // Asking how many pages first, or asking them, is right too.
            return actions.contains("info") || answer.contains("?") ? nil : "neither reordered, read the page count nor asked: \(answer)"
        }),
    ]

    static func number(_ value: JSONFragment?) -> Double? {
        switch value {
        case .number(let x)?: return x
        case .integer(let x)?: return Double(x)
        case .string(let x)?: return Double(x)
        default: return nil
        }
    }

    final class Spend: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0.0
        func add(_ cost: Double) { lock.lock(); total += cost; lock.unlock() }
        var dollars: Double { lock.lock(); defer { lock.unlock() }; return total }
    }

    static let spend = Spend()

    @MainActor
    @Test(arguments: [AskClaudeModels.haiku, AskClaudeModels.sonnet], prompts)
    func claudeUsesThePDFToolAsTheCardsNeed(_ model: AskClaudeModels.Option, _ prompt: Prompt) async throws {
        let key = try #require(Self.key)
        for run in 1...Self.runs {
            let engine = AskClaudeEngine(defaults: ScratchDefaults("AskClaudeLivePDFTests"))
            let recorder = Recorder()
            var answer = ""
            var problem: AskClaudeProblem?
            _ = await engine.ask(prompt.question, card: Self.screen, key: key, model: model, detail: .brief, tools: recorder) { event in
                switch event {
                case .text(let piece): answer += piece
                case .problem(let found): problem = found
                case .round(_, let cost, _): Self.spend.add(cost)
                default: break
                }
            }
            #expect(problem == nil, "\(model.displayName), run \(run): \(String(describing: problem))")
            if let wrong = prompt.check(recorder.calls, answer) {
                Issue.record("\(model.displayName), run \(run), “\(prompt.question)”: \(wrong)")
            }
        }
        print(String(format: "Ask Claude live check: $%.4f spent so far", Self.spend.dollars))
    }
}
