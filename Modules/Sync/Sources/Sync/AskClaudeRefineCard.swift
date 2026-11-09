import Foundation

/// Refine as a card in the Ask Claude chat (TE335, C2–C4): the plan that waits for Send, the request
/// running, and the answers that came back. One card moves through those phases, so the thread has
/// one place for one pass. Nothing is sent until its Send is clicked, and a card that comes back
/// from a saved chat can no longer send: the plan it was about is gone.
///
/// The words are here, not in the view, so each state's sentences are tested as text.
public struct AskClaudeRefineCard: Codable, Equatable, Sendable {

    /// What the plan said: the numbers on the card, copied from the open plan.
    public struct Plan: Codable, Equatable, Sendable {
        public var eligible = 0
        public var toSend = 0
        public var reused = 0
        public var hidden = 0
        public var downloads = 0
        public var folderNames = 0
        public var folderNamesLeftOut = 0
        public var pagesShared = 0
        public var pagesAskEachTime = 0
        public var pagesWaiting = 0
        public var waitingForPage = 0
        public var keptForNextPress = 0
        public var modelName = ""
        /// The quote; nil when the pass would not be billed.
        public var costUSD: Double?
        public var spentUSD = 0.0
        /// Ask Claude's monthly limit, 0 for none.
        public var limitUSD = 0.0
        public var exceedsLimit = false
        /// Files that would fit under the limit, when this pass would pass it.
        public var fits: Int?
        public var tickGainFiles: Int?
        public var tickGainCostUSD: Double?
        public var ticked = false
        /// Asked again about files answered before.
        public var askedAgain = false
        /// The model cannot take the request: the plan says which to switch to.
        public var blocked = false

        public init() {}

        /// Every field optional-with-default, like the neighbouring stores: a card saved before a
        /// field existed must still decode, not cost the chat its card.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try c.decodeIfPresent(Int.self, forKey: .eligible) ?? 0
            toSend = try c.decodeIfPresent(Int.self, forKey: .toSend) ?? 0
            reused = try c.decodeIfPresent(Int.self, forKey: .reused) ?? 0
            hidden = try c.decodeIfPresent(Int.self, forKey: .hidden) ?? 0
            downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
            folderNames = try c.decodeIfPresent(Int.self, forKey: .folderNames) ?? 0
            folderNamesLeftOut = try c.decodeIfPresent(Int.self, forKey: .folderNamesLeftOut) ?? 0
            pagesShared = try c.decodeIfPresent(Int.self, forKey: .pagesShared) ?? 0
            pagesAskEachTime = try c.decodeIfPresent(Int.self, forKey: .pagesAskEachTime) ?? 0
            pagesWaiting = try c.decodeIfPresent(Int.self, forKey: .pagesWaiting) ?? 0
            waitingForPage = try c.decodeIfPresent(Int.self, forKey: .waitingForPage) ?? 0
            keptForNextPress = try c.decodeIfPresent(Int.self, forKey: .keptForNextPress) ?? 0
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
            spentUSD = try c.decodeIfPresent(Double.self, forKey: .spentUSD) ?? 0
            limitUSD = try c.decodeIfPresent(Double.self, forKey: .limitUSD) ?? 0
            exceedsLimit = try c.decodeIfPresent(Bool.self, forKey: .exceedsLimit) ?? false
            fits = try c.decodeIfPresent(Int.self, forKey: .fits)
            tickGainFiles = try c.decodeIfPresent(Int.self, forKey: .tickGainFiles)
            tickGainCostUSD = try c.decodeIfPresent(Double.self, forKey: .tickGainCostUSD)
            ticked = try c.decodeIfPresent(Bool.self, forKey: .ticked) ?? false
            askedAgain = try c.decodeIfPresent(Bool.self, forKey: .askedAgain) ?? false
            blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        }

        public init(_ plan: FileSyncManager.FilingRefinePlan) {
            eligible = plan.eligible
            toSend = plan.toSend
            reused = plan.reused
            hidden = plan.hiddenFromClaude
            downloads = plan.downloads
            folderNames = plan.folderNames
            folderNamesLeftOut = plan.folderNamesLeftOut
            pagesShared = plan.pagesShared
            pagesAskEachTime = plan.pagesAskEachTime
            pagesWaiting = plan.pagesWaiting
            waitingForPage = plan.waitingForPage
            keptForNextPress = plan.keptForNextPress
            modelName = plan.modelName
            fits = plan.fits
            tickGainFiles = plan.tickGain?.files
            tickGainCostUSD = plan.tickGain?.costUSD
            ticked = plan.options.pagesFromAskEachTime
            askedAgain = plan.options.askAgain
            switch plan.billing {
            case .notBilled: costUSD = nil
            case .blocked: blocked = true
            case .quote(let q):
                costUSD = q.estCostUSD
                spentUSD = q.monthlySpentUSD
                limitUSD = q.monthlyCapUSD
                exceedsLimit = q.wouldExceedCap
            }
        }

        /// Every eligible file was answered before and nothing is left to ask.
        public var nothingNew: Bool { toSend == 0 && reused > 0 }
    }

    /// What came back, kept on the card.
    public struct Answers: Codable, Equatable, Sendable {
        public struct Row: Codable, Equatable, Sendable, Identifiable {
            public var id: String { path }
            public var path: String
            public var name: String
            public var before: String?
            public var after: String
            public var reason: String?

            public init(path: String, name: String, before: String?, after: String, reason: String?) {
                self.path = path; self.name = name; self.before = before; self.after = after; self.reason = reason
            }
        }
        public enum Ending: Codable, Equatable, Sendable {
            case answered
            case stopped
            case failed(String)
            /// The key could not be read, so Claude was never asked.
            case unreadableKey
            /// A pass that ended before it began (the plan changed, a limit was reached).
            case notSent(String)
        }
        public var rows: [Row] = []
        public var asked = 0
        public var reused = 0
        public var hidden = 0
        public var sent = 0
        public var answered = 0
        public var pagesSent = 0
        public var folderNames = 0
        public var requests = 0
        public var costUSD = 0.0
        public var modelName = ""
        public var kept = 0
        public var ending = Ending.answered
        /// Undo Refine put the on-device suggestions back.
        public var undone = false

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
            asked = try c.decodeIfPresent(Int.self, forKey: .asked) ?? 0
            reused = try c.decodeIfPresent(Int.self, forKey: .reused) ?? 0
            hidden = try c.decodeIfPresent(Int.self, forKey: .hidden) ?? 0
            sent = try c.decodeIfPresent(Int.self, forKey: .sent) ?? 0
            answered = try c.decodeIfPresent(Int.self, forKey: .answered) ?? 0
            pagesSent = try c.decodeIfPresent(Int.self, forKey: .pagesSent) ?? 0
            folderNames = try c.decodeIfPresent(Int.self, forKey: .folderNames) ?? 0
            requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
            costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
            modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
            kept = try c.decodeIfPresent(Int.self, forKey: .kept) ?? 0
            ending = try c.decodeIfPresent(Ending.self, forKey: .ending) ?? .answered
            undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
        }

        public init(_ report: FileSyncManager.FilingRefineReport) {
            rows = report.changes.map { .init(path: $0.filePath, name: $0.fileName, before: $0.before, after: $0.after, reason: $0.reason) }
            asked = report.asked
            reused = report.reused
            hidden = report.hiddenFromClaude
            sent = report.sent
            answered = report.answered
            pagesSent = report.pagesSent
            folderNames = report.folderNames
            requests = report.requests
            costUSD = report.costUSD
            modelName = report.modelName
            kept = report.keptForNextPress
            switch report.ending {
            case .answered: ending = .answered
            case .stopped: ending = .stopped
            case .failed(let why): ending = .failed(why)
            case .declined: ending = .notSent("The pass was not sent.")
            case .downgraded: ending = .unreadableKey
            }
        }
    }

    public enum Phase: Codable, Equatable, Sendable {
        /// The plan, waiting for Send.
        case planned
        /// Send was clicked. `answered` is how far the request has got, when it says.
        case sending(answered: Int?)
        /// It ended: `answers` says how.
        case done
        /// Cancel or Close.
        case closed
        /// A newer plan replaced this one, or the list it was about moved on.
        case replaced
        /// Restored from a saved chat: the plan is gone, so it cannot send.
        case expired
    }

    public var sourceName: String
    public var plan: Plan
    public var phase: Phase = .planned
    public var answers: Answers?
    /// The open plan this card controls; not saved (a plan does not outlive the app).
    public var planID: UUID?
    /// Said above the plan when it was quoted again: what changed, and that nothing was sent.
    public var notice: String?

    private enum CodingKeys: String, CodingKey { case sourceName, plan, phase, answers, notice }

    /// Rows the answers show before "Show all".
    public static let rowsShown = 6

    public init(sourceName: String, plan: FileSyncManager.FilingRefinePlan) {
        self.sourceName = sourceName
        self.plan = Plan(plan)
        self.planID = plan.id
    }

    public init(sourceName: String, plan: Plan, phase: Phase = .planned, answers: Answers? = nil) {
        self.sourceName = sourceName
        self.plan = plan
        self.phase = phase
        self.answers = answers
    }

    /// The same card after it has come back from a saved chat: a plan that was waiting or running is
    /// out of date, and says so.
    public var restored: AskClaudeRefineCard {
        var card = self
        card.planID = nil
        switch phase {
        case .planned, .sending: card.phase = .expired
        default: break
        }
        return card
    }

    // MARK: What a send did to the card

    /// Moves the card on after Send: to its answers, to a new plan to read again, or to a line that
    /// says why nothing was sent. `report` is the pass's report when it was sent; `replanned` is a
    /// plan made after the old one was refused for the limit.
    public mutating func finish(_ result: FileSyncManager.FilingRefineSendResult,
                                report: FileSyncManager.FilingRefineReport?,
                                replanned: FileSyncManager.FilingRefinePlan? = nil) {
        notice = nil
        switch result {
        case .sent:
            guard let report else { phase = .expired; planID = nil; return }
            phase = .done
            answers = Answers(report)
            planID = nil
        case .requoted(let fresh):
            phase = .planned
            plan = Plan(fresh)
            planID = fresh.id
            notice = "Something changed since this plan (the list, a folder hidden from Claude, or the price), so it was quoted again. Nothing was sent."
        case .blocked:
            let message = "Nothing was sent: this would pass your monthly limit, or the model has no known price."
            if let replanned {
                phase = .planned
                plan = Plan(replanned)
                planID = replanned.id
            } else {
                phase = .closed
                planID = nil
            }
            notice = message
        case .nothingToSend:
            phase = .closed
            planID = nil
            notice = "Nothing was sent: every file went hidden from Claude."
        case .stale, .unavailable:
            phase = .expired
            planID = nil
        }
    }

    // MARK: Words: the plan

    public var title: String {
        let files = plan.eligible == 1 ? "1 file" : "\(plan.eligible) files"
        return "Refine \(files) in \(sourceName)"
    }

    public static let promise = "Claude looks again at the on-device suggestions. Nothing moves until you File it in Organize."

    /// "150 of 212 this pass. The other 62 stay for the next Refine." when the request cuts it.
    public var cutNote: String? {
        guard plan.keptForNextPress > 0 else { return nil }
        return "\(plan.toSend) of \(plan.toSend + plan.keptForNextPress) this pass. The other \(plan.keptForNextPress) stay for the next Refine."
    }

    /// What goes to Claude, a line each. `tick` marks the one the person can switch.
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case goes, tick, notSent, reused }
        public var kind: Kind
        public var text: String
        public var detail: String?
    }

    public var lines: [Line] {
        var out: [Line] = []
        guard !plan.nothingNew else { return out }
        if plan.folderNames > 0 {
            out.append(.init(kind: .goes, text: "Your folder names (\(plan.folderNames)), so Claude can pick one",
                             detail: plan.folderNamesLeftOut > 0 ? "\(plan.folderNamesLeftOut) left out" : nil))
        }
        let files = plan.toSend
        out.append(.init(kind: .goes, text: "Names, types and years of \(files) \(files == 1 ? "file" : "files")"))
        if plan.pagesShared > 0 {
            out.append(.init(kind: .goes, text: "Page-1 text, up to 800 characters, from \(plan.pagesShared) \(plan.pagesShared == 1 ? "file" : "files") in folders shared without asking"))
        }
        if plan.ticked {
            if plan.pagesAskEachTime > 0 {
                out.append(.init(kind: .tick, text: "Also page-1 text from \(plan.pagesAskEachTime) \(plan.pagesAskEachTime == 1 ? "file" : "files") in folders that ask each time",
                                 detail: plan.downloads > 0 ? downloadsText : nil))
            } else {
                out.append(.init(kind: .tick, text: "Also page-1 text from files in folders that ask each time"))
            }
        } else if plan.pagesWaiting > 0 || plan.waitingForPage > 0 {
            var detail = "Unticked: those files go by name"
            if plan.waitingForPage > 0 {
                detail = "\(plan.waitingForPage) wait for their page text"
            }
            if let tick = tickBuys { detail += " · " + tick }
            out.append(.init(kind: .tick, text: "Also page-1 text from files in folders that ask each time", detail: detail))
        }
        if plan.downloads > 0 && !plan.ticked {
            out.append(.init(kind: .goes, text: downloadsText))
        }
        if plan.hidden > 0 {
            out.append(.init(kind: .notSent,
                             text: "\(plan.hidden) \(plan.hidden == 1 ? "file" : "files") in a folder hidden from Claude",
                             detail: "Not named anywhere"))
        }
        if plan.reused > 0 {
            out.append(.init(kind: .reused, text: "\(plan.reused) answered before · reused free",
                             detail: "Ask Again About the \(plan.reused)"))
        }
        return out
    }

    private var downloadsText: String {
        "\(plan.downloads) cloud-only \(plan.downloads == 1 ? "file" : "files") will download and stay downloaded"
    }

    /// What ticking buys, for the card: "+2 files, can name new folders, +1¢".
    public var tickBuys: String? {
        guard let files = plan.tickGainFiles else { return nil }
        var parts: [String] = []
        if files > 0 { parts.append("+\(files) \(files == 1 ? "file" : "files")") }
        parts.append("pages can name new folders")
        if let cost = plan.tickGainCostUSD, cost > 0 { parts.append("+" + AskClaudeSpend.format(cost)) }
        return "tick to include: " + parts.joined(separator: ", ")
    }

    /// The quote line: "Opus 5.5 · this chat's model ≈ 4¢".
    public var quoteLine: String {
        guard let cost = plan.costUSD else { return "\(plan.modelName) · this chat’s model · nothing is billed" }
        return "\(plan.modelName) · this chat’s model ≈ \(AskClaudeSpend.format(cost))"
    }

    /// "This month $3.12 of $25", or nil with no limit.
    public var monthLine: String? {
        guard plan.costUSD != nil else { return nil }
        if plan.limitUSD > 0 {
            return "This month \(AskClaudeSpend.format(plan.spentUSD)) of \(AskClaudeSpend.format(plan.limitUSD))"
        }
        return "This month \(AskClaudeSpend.format(plan.spentUSD)) · no limit"
    }

    /// Said when the pass would pass the limit.
    public var limitMessage: String? {
        guard plan.exceedsLimit, let cost = plan.costUSD else { return nil }
        let over = plan.spentUSD + cost - plan.limitUSD
        let by = over >= 0.01 ? "about \(AskClaudeSpend.format(over))" : "a cent or less"
        return "This pass would pass your \(AskClaudeSpend.format(plan.limitUSD)) limit by \(by). Raise the limit"
            + (plan.fits.map { $0 > 0 ? ", or send the smaller part that fits." : "." } ?? ".")
    }

    /// Why nothing can be sent: no price for the model.
    public var blockedMessage: String? {
        plan.blocked ? "Refine isn’t available on \(plan.modelName). Switch this chat to another model with the menu under the text box, then press Refine again." : nil
    }

    public var nothingNewTitle: String { "Nothing new to ask" }

    public var nothingNewMessage: String {
        let all = plan.reused == 1 ? "The file was" : "All \(plan.reused) files were"
        var text = "\(all) answered before and \(plan.reused == 1 ? "is" : "are") reused free."
        if plan.hidden > 0 {
            text += " \(plan.hidden) \(plan.hidden == 1 ? "file" : "files") in a folder hidden from Claude \(plan.hidden == 1 ? "is" : "are") left out."
        }
        return text
    }

    public var sendTitle: String {
        plan.toSend == 1 ? "Send 1 file" : "Send \(plan.toSend) files"
    }

    /// "Send the 3 that fit".
    public var sendFitTitle: String? {
        guard plan.exceedsLimit, let fits = plan.fits, fits > 0 else { return nil }
        return "Send the \(fits) that fit"
    }

    // MARK: Words: sending and after

    public var sendingTitle: String {
        "Asking \(plan.modelName) about \(plan.toSend) \(plan.toSend == 1 ? "file" : "files")"
    }

    public func progressLine(answered: Int?) -> String {
        let one = "One request · Organize keeps working"
        guard let answered else { return one }
        return "\(answered) of \(plan.toSend) answered · " + one
    }

    public var answersTitle: String {
        guard let a = answers else { return "" }
        let files = a.sent == 1 ? "1 file" : "\(a.sent) files"
        let homes = a.rows.count == 1 ? "1 home changed" : "\(a.rows.count) homes changed"
        return a.rows.isEmpty ? "Refined \(files) · no better homes found" : "Refined \(files) · \(homes)"
    }

    /// The line under the rows: what was reused, left out and kept.
    public var answersFootnote: String? {
        guard let a = answers else { return nil }
        var parts: [String] = []
        if a.reused > 0 { parts.append("\(a.reused) answered before \(a.reused == 1 ? "was" : "were") reused") }
        if a.hidden > 0 { parts.append("\(a.hidden) left out: hidden from Claude") }
        if a.kept > 0 { parts.append("\(a.kept) kept for the next Refine") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The receipt: what was sent, how many requests, the cost and the model.
    public var receiptLine: String? {
        guard let a = answers, a.requests > 0 else { return nil }
        var sent = "\(a.sent) file \(a.sent == 1 ? "name" : "names")"
        sent += a.pagesSent > 0 ? ", \(a.pagesSent) page-1 \(a.pagesSent == 1 ? "excerpt" : "excerpts")" : ""
        sent += a.folderNames > 0 ? " and your folder list (\(a.folderNames))" : ""
        let finished: String
        switch a.ending {
        case .answered: finished = "1 request"
        default: finished = "1 request, not finished"
        }
        return "Sent \(sent) · \(finished) · \(a.costUSD > 0 ? AskClaudeSpend.format(a.costUSD) : "no cost recorded") · \(a.modelName)"
    }

    /// What the card says when the pass ended without all of its answers, or without Claude.
    public var endingTitle: String? {
        guard let a = answers else { return nil }
        switch a.ending {
        case .answered: return nil
        case .stopped: return "Stopped after \(a.answered) of \(a.sent) answers"
        case .failed: return a.requests > 0 ? "Claude didn’t finish: \(a.answered) of \(a.sent) answers arrived" : "Couldn’t ask Claude"
        case .unreadableKey: return "Couldn’t reach Claude"
        case .notSent: return "Nothing was sent"
        }
    }

    public var endingMessage: String? {
        guard let a = answers else { return nil }
        switch a.ending {
        case .answered: return nil
        case .stopped:
            var text = a.answered > 0
                ? "The \(a.answered) \(a.answered == 1 ? "answer" : "answers") that arrived \(a.answered == 1 ? "is" : "are") kept and shown in Organize."
                : "Nothing came back, so the suggestions are unchanged."
            if a.costUSD > 0 { text += " About \(AskClaudeSpend.format(a.costUSD)) was billed for what ran." }
            return text
        case .failed(let why):
            var text = why
            if a.requests > 0 {
                text += a.answered > 0
                    ? " The \(a.answered) \(a.answered == 1 ? "answer" : "answers") that arrived \(a.answered == 1 ? "is" : "are") kept and shown in Organize. Nothing is called Claude’s that Claude did not answer."
                    : " Nothing came back, so the suggestions are unchanged."
                text += " A request had started, so up to about \(AskClaudeSpend.format(max(a.costUSD, 0.01))) may have been billed."
            } else {
                text += " Nothing was sent, and the suggestions are unchanged."
            }
            return text
        case .unreadableKey:
            return "Your saved API key couldn’t be read, so nothing was sent or billed. These are the on-device suggestions. Check the key in Settings ▸ Ask Claude."
        case .notSent(let why): return why
        }
    }

    // MARK: Refine Names' receipt

    /// What the chat shows after a Refine Names request: what was sent, the request, the cost and the
    /// model. The request lives in its sheet; the chat only keeps the receipt (TE335, JZ-A).
    public static func refineNamesReceipt(folderNames: Int, fileNames: Int, costUSD: Double, modelName: String,
                                          answered: Bool) -> String {
        var sent = "\(folderNames) folder \(folderNames == 1 ? "name" : "names")"
        sent += fileNames > 0 ? " and \(fileNames) file \(fileNames == 1 ? "name" : "names")" : ", no file names"
        return "Refine Names · sent \(sent) · 1 request" + (answered ? "" : ", not finished")
            + " · \(costUSD > 0 ? AskClaudeSpend.format(costUSD) : "no cost recorded") · \(modelName)"
    }

    // MARK: What Claude is told

    /// Changed answers named in the line the chat's Claude hears: the pass is a separate request, so
    /// it learns of it afterwards, from this line, with the next question. Each changed file names
    /// its folder, so a folder hidden since drops the line (`AskClaudeChat.withoutHidden`).
    public static let toldChanges = 20

    public var toldToClaude: String? {
        guard case .done = phase, let a = answers else { return nil }
        var line = "They ran Refine from Organize on \(a.sent) file\(a.sent == 1 ? "" : "s"); a separate request to \(a.modelName.isEmpty ? "you" : a.modelName) that you didn’t make. "
        switch a.ending {
        case .answered: break
        case .stopped: line += "They stopped it after \(a.answered) of \(a.sent) answers; "
        case .failed: line += "It failed after \(a.answered) of \(a.sent) answers; "
        case .unreadableKey, .notSent: return nil
        }
        guard !a.rows.isEmpty else { return line + "no suggestion changed." }
        let shown = a.rows.prefix(Self.toldChanges).map { row -> String in
            let reason = (row.reason ?? "").isEmpty ? "" : " (" + String(row.reason!.prefix(90)) + ")"
            return "“\(row.name)” → \(row.after)\(reason)"
        }
        line += "It changed \(a.rows.count) suggested home\(a.rows.count == 1 ? "" : "s"): " + shown.joined(separator: "; ")
        if a.rows.count > shown.count { line += "; and \(a.rows.count - shown.count) more" }
        return line + ". Nothing has moved: they still File it in Organize."
    }

    // MARK: Words: closed

    public var closedLine: String? {
        switch phase {
        case .closed: return notice ?? "Canceled. Nothing was sent."
        case .replaced: return "Replaced by a newer plan. Nothing was sent."
        case .expired: return "This plan is out of date, so it can’t send. Press Refine in Organize to make a new one."
        default: return nil
        }
    }

    /// The tick and Customize… work only while the plan is open to change.
    public var canTick: Bool {
        guard case .planned = phase else { return false }
        return planID != nil
    }

    /// Whether Send can be pressed on this card.
    public var canSend: Bool {
        guard case .planned = phase, planID != nil else { return false }
        return !plan.blocked && !plan.nothingNew && plan.toSend > 0 && !plan.exceedsLimit
    }
}

/// The running line Try Another keeps in the chat (TE335, LT-B): one line for the hour, updated in
/// place and moved to the bottom as it changes, so the chat shows what Try Another has used without a
/// card per click. Each card shows its own failure or refusal; this line only counts.
public struct AskClaudeTryAnotherLine: Codable, Equatable, Sendable {
    public var files: [String] = []
    public var requests = 0
    public var failed = 0
    public var costUSD = 0.0
    public var modelName = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
    }

    public mutating func add(_ report: FilingTryAnotherReport) {
        if !files.contains(report.fileName) { files.append(report.fileName) }
        requests += 1
        if report.outcome == .failed { failed += 1 }
        costUSD += report.costUSD
        if !report.modelName.isEmpty { modelName = report.modelName }
    }

    /// "Try Another · 3 files · 4 requests, 1 failed · 3¢ this hour · Opus 5.5".
    public var text: String {
        var parts = ["Try Another", "\(files.count) \(files.count == 1 ? "file" : "files")"]
        parts.append("\(requests) \(requests == 1 ? "request" : "requests")" + (failed > 0 ? ", \(failed) failed" : ""))
        parts.append("\(costUSD > 0 ? AskClaudeSpend.format(costUSD) : "no cost recorded") this hour")
        if !modelName.isEmpty { parts.append(modelName) }
        return parts.joined(separator: " · ")
    }
}
