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
        /// The pass reaches Claude and is billed; false when it runs on this Mac.
        public var routesToClaude = true
        /// The files not answered before, and what the pass does with each ("Which files").
        public var files: [File] = []

        public struct File: Codable, Equatable, Sendable, Identifiable {
            public var id: String { name }
            public var name: String
            public var status: FileSyncManager.FilingRefinePlanFile.Status
            public init(name: String, status: FileSyncManager.FilingRefinePlanFile.Status) { self.name = name; self.status = status }
        }

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
            files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
            routesToClaude = try c.decodeIfPresent(Bool.self, forKey: .routesToClaude) ?? true
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
            files = plan.files.map { .init(name: $0.name, status: $0.status) }
            routesToClaude = plan.routesToClaude
            spentUSD = plan.monthSpentUSD
            limitUSD = plan.monthLimitUSD
            switch plan.billing {
            case .notBilled: costUSD = nil
            case .blocked: blocked = true
            case .quote(let q):
                costUSD = q.estCostUSD
                exceedsLimit = q.wouldExceedCap
            }
        }

        /// Every eligible file was answered before and nothing is left to ask.
        public var nothingNew: Bool { toSend == 0 && waitingForPage == 0 && reused > 0 }
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
        /// Files whose home stood while Claude picked another folder, next under Try Another Folder.
        public var offered = 0
        /// Files still waiting for the tick after this pass.
        public var waitingForPage = 0
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
            offered = try c.decodeIfPresent(Int.self, forKey: .offered) ?? 0
            waitingForPage = try c.decodeIfPresent(Int.self, forKey: .waitingForPage) ?? 0
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
            offered = report.offered
            waitingForPage = report.waitingForPage
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
    /// When Send was clicked; not saved.
    public var startedAt: Date?
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

    public static let promise = "A second look at the suggested folders. Nothing moves until you File them."
    public static let promiseInfo = "Claude re-checks the folders suggested for these files. The answers appear here and on the cards in Organize. Nothing moves until you click File in Organize."

    public var title: String {
        let files = plan.eligible == 1 ? "1 file" : "\(plan.eligible) files"
        return "Refine \(files) in \(sourceName)"
    }

    /// "150 of 212 this pass. The other 62 stay for the next Refine." when the request cuts it.
    public var cutNote: String? {
        guard plan.keptForNextPress > 0 else { return nil }
        return "\(plan.toSend) of \(plan.toSend + plan.keptForNextPress) this pass. The other \(plan.keptForNextPress) stay for the next Refine."
    }

    /// Which of the card's shapes this plan is.
    public enum Layout: Equatable, Sendable {
        /// Files go, perhaps with a tick for more.
        case normal
        /// Nothing can go until the tick: every file waits for its first page.
        case needsFirstPages
        /// Every file was answered before.
        case nothingNew
        /// Sending the plan would pass the monthly limit.
        case overLimit
        /// The model has no known price.
        case blocked
    }

    public var layout: Layout {
        if plan.blocked { return .blocked }
        if plan.nothingNew { return .nothingNew }
        if plan.toSend == 0 && plan.waitingForPage > 0 { return .needsFirstPages }
        if plan.exceedsLimit { return .overLimit }
        return .normal
    }

    /// One counted line: a number, a few words, and the reason behind its ⓘ.
    public struct CountLine: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case whichFiles, customize, askAgain }
        public var count: String
        public var text: String
        public var info: String?
        public var action: Action?
        public init(count: String, text: String, info: String?, action: Action?) {
            self.count = count; self.text = text; self.info = info; self.action = action
        }
    }

    private static func files(_ n: Int) -> String { n == 1 ? "file" : "files" }

    /// What goes to Claude.
    public var goesLines: [CountLine] {
        var out: [CountLine] = []
        guard plan.toSend > 0 else { return out }
        out.append(.init(count: "\(plan.toSend)", text: "\(Self.files(plan.toSend)): name, type, year", info: nil, action: .whichFiles))
        let pages = plan.pagesShared + plan.pagesAskEachTime
        if pages > 0 {
            out.append(.init(count: "\(pages)", text: pages == 1 ? "first page" : "first pages",
                             info: "Up to 800 characters of text from the first page of each file.", action: nil))
        }
        if plan.downloads > 0 {
            out.append(.init(count: "\(plan.downloads)", text: "cloud-only \(Self.files(plan.downloads)) download first",
                             info: "They stay downloaded, so their first pages can be read.", action: nil))
        }
        if plan.folderNames > 0 {
            out.append(.init(count: "\(plan.folderNames)",
                             text: "folder names" + (plan.folderNamesLeftOut > 0 ? " (\(plan.folderNamesLeftOut) left out)" : ""),
                             info: "So Claude can pick a home for each file. Customize leaves folders out until you quit, for Refine, Try Another and Refine Names.",
                             action: .customize))
        }
        return out
    }

    /// What is left out of this pass.
    public var notSentLines: [CountLine] {
        var out: [CountLine] = []
        if plan.hidden > 0 {
            out.append(.init(count: "\(plan.hidden)", text: "hidden from Claude",
                             info: "Files in folders you hid from Claude are never sent or named, not even their folder names.", action: nil))
        }
        if plan.reused > 0 && !plan.nothingNew {
            out.append(.init(count: "\(plan.reused)", text: "answered before, free", info: nil, action: .askAgain))
        }
        if plan.keptForNextPress > 0 {
            out.append(.init(count: "\(plan.keptForNextPress)", text: "wait for the next Refine",
                             info: "One request carries at most \(CloudFilingRefiner.maxFiles) files.", action: nil))
        }
        return out
    }

    /// The one decision on the plan: the tick that sends first pages from folders Claude isn't shared.
    public struct OKBlock: Equatable, Sendable {
        public var title: String
        public var detail: String?
        public var info: String
        public var checked: Bool
    }

    public var ok: OKBlock? {
        guard plan.pagesWaiting > 0 || plan.waitingForPage > 0 || plan.ticked else { return nil }
        let gain = plan.tickGainCostUSD.flatMap { $0 > 0 ? ($0 < 0.01 ? "under 1¢ more" : "about +" + AskClaudeSpend.format($0)) : nil }
        if layout == .needsFirstPages {
            let one = plan.waitingForPage == 1
            return .init(title: one ? "Send its first page" : "Send their first pages",
                         detail: plan.tickGainCostUSD.map { Self.priceWords($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() },
                         info: "Up to 800 characters of text from each first page, once, for this pass only.", checked: plan.ticked)
        }
        let n = plan.ticked ? plan.pagesAskEachTime : plan.pagesWaiting
        guard n > 0 else { return nil }
        var detail: String?
        if plan.ticked {
            detail = "Included in the price below"
        } else if let files = plan.tickGainFiles, files > 0 {
            detail = "Improves \(files) more \(Self.files(files))" + (gain.map { " · " + $0 } ?? "")
        } else {
            detail = gain.map { "Adds first pages · " + $0 } ?? "Adds first pages"
        }
        return .init(title: "Send first pages for \(n) more \(Self.files(n))", detail: detail,
                     info: "Their folders aren’t shared with Claude, so a first page goes only if you tick this. It counts for this pass only.",
                     checked: plan.ticked)
    }

    /// When nothing can go until the tick: what is wrong, in a few words, and why behind its ⓘ.
    public var needsFirstPagesNote: (text: String, info: String)? {
        guard layout == .needsFirstPages else { return nil }
        if plan.waitingForPage == 1 {
            return ("A name alone can’t improve this file.",
                    "Its suggested folder came from reading its first page, and its folder isn’t shared with Claude, so Claude hasn’t seen that page.")
        }
        return ("A name alone can’t improve these files.",
                "Their suggested folders came from reading their first pages, and their folders aren’t shared with Claude, so Claude hasn’t seen those pages.")
    }

    /// The files that wait, by name, for the zero-send card (the first few).
    public var waitingNames: [String] {
        plan.files.filter { $0.status == .needsOK }.prefix(3).map(\.name)
    }

    /// "Tick the box to send this file." under a Send that is off for want of the tick.
    public var tickHint: String? {
        guard layout == .needsFirstPages, !plan.ticked else { return nil }
        return plan.waitingForPage == 1 ? "Tick the box to send this file." : "Tick the box to send these files."
    }

    /// The price in a few words: "about 4¢", or "under 1¢".
    public static func priceWords(_ usd: Double) -> String {
        usd > 0 && usd < 0.01 ? "under 1¢" : "about " + AskClaudeSpend.format(usd)
    }

    /// "Sonnet 5.5 · $3.12 of $25 this month"; "Runs on this Mac · nothing is billed" off the Claude route.
    public var monthLine: String {
        guard plan.routesToClaude else { return "Runs on this Mac · nothing is billed" }
        let month = plan.limitUSD > 0
            ? "\(AskClaudeSpend.format(plan.spentUSD)) of \(AskClaudeSpend.format(plan.limitUSD)) this month"
            : "\(AskClaudeSpend.format(plan.spentUSD)) this month, no limit"
        return "\(plan.modelName) · \(month)"
    }
    public static let monthInfo = "The chat’s model. One monthly limit covers the chat, Refine, Try Another and Refine Names."

    /// How full the month is, 0...1; nil with no limit.
    public var monthFraction: Double? {
        guard plan.limitUSD > 0 else { return nil }
        return min(1, max(0, (plan.spentUSD + (plan.exceedsLimit ? 0 : (plan.costUSD ?? 0))) / plan.limitUSD))
    }

    /// "Over your $25 limit by about 1¢. You’ve used $24.97."
    public var limitMessage: String? {
        guard plan.exceedsLimit, let cost = plan.costUSD else { return nil }
        let over = plan.spentUSD + cost - plan.limitUSD
        let by = over >= 0.01 ? "about \(AskClaudeSpend.format(over))" : "a cent or less"
        return "Over your \(AskClaudeSpend.format(plan.limitUSD)) limit by \(by). You’ve used \(AskClaudeSpend.format(plan.spentUSD))."
    }
    public static let limitInfo = "One monthly limit covers the chat, Refine, Try Another and Refine Names. Change it in Settings, Ask Claude, Key & Spending."

    /// The whole plan, and the part that fits, for the over-limit card.
    public var wholePlanLine: CountLine {
        .init(count: "\(plan.toSend)", text: "\(Self.files(plan.toSend)) in the plan" + (plan.costUSD.map { " · " + Self.priceWords($0) } ?? ""),
              info: nil, action: .whichFiles)
    }
    public var fitLine: CountLine? {
        guard plan.exceedsLimit, let fits = plan.fits, fits > 0, let cost = plan.costUSD, plan.toSend > 0 else { return nil }
        let part = cost * Double(fits) / Double(plan.toSend)
        return .init(count: "\(fits)", text: "fit under the limit · \(Self.priceWords(part))", info: nil, action: nil)
    }

    /// Why nothing can be sent: no price for the model.
    public var blockedMessage: String? {
        plan.blocked ? "Refine isn’t available on \(plan.modelName). Switch this chat to another model with the menu under the text box, then press Refine again." : nil
    }

    public var nothingNewTitle: String { "Nothing new to ask" }
    public var nothingNewMessage: String {
        plan.reused == 1 ? "The file was answered before. Nothing to send, nothing billed."
                         : "All \(plan.reused) were answered before. Nothing to send, nothing billed."
    }
    public var nothingNewInfo: String {
        "Their suggested folders are already on the cards in Organize. Asking again sends \(plan.reused == 1 ? "it" : "all \(plan.reused)") to Claude and bills the usual price."
    }

    /// "Send 4 files · about 4¢"; "Send 0 files" when nothing can go yet.
    public var sendTitle: String {
        let n = plan.toSend
        guard n > 0 else { return "Send 0 files" }
        return "Send \(n) \(Self.files(n))" + (plan.costUSD.map { " · " + Self.priceWords($0) } ?? "")
    }

    /// "Send 3 Files · about 3¢" for the part that fits under the limit.
    public var sendFitTitle: String? {
        guard let line = fitLine, let fits = plan.fits else { return nil }
        let price = line.text.components(separatedBy: " · ").last.map { " · " + $0 } ?? ""
        return "Send \(fits) \(Self.files(fits))" + price
    }

    // MARK: Words: sending and after

    public var sendingTitle: String {
        "Asking \(plan.modelName) about \(plan.toSend) \(plan.toSend == 1 ? "file" : "files")"
    }
    public static let sendingInfo = "The answers appear here and on the cards in Organize. Stop keeps any answers that already arrived."

    /// "12 s · keep working in Organize".
    public func progressLine(elapsed seconds: Int?) -> String {
        guard let seconds else { return "Keep working in Organize" }
        return "\(seconds) s · keep working in Organize"
    }

    public var answersTitle: String {
        guard let a = answers else { return "" }
        if a.rows.isEmpty { return a.offered > 0 ? "No home changed" : "No better homes found" }
        return a.rows.count == 1 ? "1 home changed" : "\(a.rows.count) homes changed"
    }

    /// "4 files checked · about 4¢ · nothing has moved yet".
    public var answersSub: String? {
        guard let a = answers else { return nil }
        var parts = ["\(a.sent) \(Self.files(a.sent)) checked"]
        if a.costUSD > 0 { parts.append(Self.priceWords(a.costUSD)) }
        parts.append("nothing has moved yet")
        return parts.joined(separator: " · ")
    }

    /// "1 kept · 2 reused · 1 hidden from Claude".
    public var answersFootnote: String? {
        guard let a = answers else { return nil }
        var parts: [String] = []
        if a.offered > 0 {
            parts.append(a.offered == 1 ? "Claude picked another folder for 1 file: Try Another Folder shows it"
                                        : "Claude picked another folder for \(a.offered) files: Try Another Folder shows each")
        }
        let keptAsWas = a.ending == .answered ? max(0, a.sent - a.rows.count) : 0
        if keptAsWas > 0 { parts.append("\(keptAsWas) kept") }
        if a.reused > 0 { parts.append("\(a.reused) reused") }
        if a.hidden > 0 { parts.append("\(a.hidden) hidden from Claude") }
        if a.kept > 0 { parts.append("\(a.kept) wait for the next Refine") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 files still need a first page."
    public var answersWaitingNote: String? {
        guard let a = answers, a.waitingForPage > 0, a.ending == .answered else { return nil }
        return "\(a.waitingForPage) \(Self.files(a.waitingForPage)) still need\(a.waitingForPage == 1 ? "s" : "") a first page."
    }
    public static let answersWaitingInfo = "Refine again and tick the box to include them."

    /// The receipt, behind its ⓘ.
    public var receiptInfo: String? {
        guard let a = answers, a.requests > 0 else { return nil }
        var sent = "\(a.sent) \(a.sent == 1 ? "name" : "names")"
        if a.pagesSent > 0 { sent += ", \(a.pagesSent) first \(a.pagesSent == 1 ? "page" : "pages")" }
        if a.folderNames > 0 { sent += " and \(a.folderNames) folder names" }
        let finished = a.ending == .answered ? "1 request" : "1 request, not finished"
        return "\(finished) · \(sent) sent · \(a.modelName) · \(a.costUSD > 0 ? Self.priceWords(a.costUSD) : "no cost recorded")."
    }

    /// What the card says when the pass ended without all of its answers, or without Claude.
    public var endingTitle: String? {
        guard let a = answers else { return nil }
        switch a.ending {
        case .answered: return nil
        case .stopped: return "Stopped after \(a.answered) of \(a.sent) answers"
        case .failed(let why):
            guard a.requests > 0 else { return "Couldn’t ask Claude" }
            guard a.answered > 0 else { return "Claude didn’t answer" }
            let reason = why.hasSuffix(".") ? String(why.dropLast()) : why
            return "\(reason) after \(a.answered) of \(a.sent) answers"
        case .unreadableKey: return "Couldn’t reach Claude"
        case .notSent: return "Nothing was sent"
        }
    }

    /// The sentence under that title.
    public var endingMessage: String? {
        guard let a = answers else { return nil }
        let left = max(0, a.sent - a.answered)
        let kept = a.answered > 0
            ? "The \(a.answered) \(a.answered == 1 ? "answer is" : "answers are") kept in Organize. \(left) \(Self.files(left)) \(left == 1 ? "wasn’t" : "weren’t") answered."
            : "Nothing came back, so the suggestions are unchanged."
        switch a.ending {
        case .answered: return nil
        case .stopped: return kept
        case .failed(let why):
            guard a.requests > 0 else { return "\(why) Nothing was sent, and the suggestions are unchanged." }
            return a.answered > 0 ? kept : "\(why) \(kept)"
        case .unreadableKey:
            return "Your saved API key couldn’t be read, so nothing was sent or billed. These are the on-device suggestions. Check the key in Settings, Ask Claude."
        case .notSent(let why): return why
        }
    }

    /// Why the ending may have cost something, behind its ⓘ.
    public var endingInfo: String? {
        guard let a = answers, a.requests > 0 else { return nil }
        switch a.ending {
        case .failed:
            return "A request had started, so up to about \(AskClaudeSpend.format(max(a.costUSD, 0.01))) may have been billed even though it didn’t finish. Nothing is called Claude’s that Claude didn’t answer."
        case .stopped:
            return a.costUSD > 0 ? "About \(AskClaudeSpend.format(a.costUSD)) was billed for what ran." : nil
        default: return nil
        }
    }

    /// "Try Again for the 1": a new plan; what Claude already answered is reused, not asked again.
    public var retryTitle: String? {
        guard let a = answers, a.requests > 0 else { return nil }
        switch a.ending {
        case .stopped, .failed:
            let left = max(0, a.sent - a.answered)
            return left > 0 ? "Try Again for the \(left)" : nil
        default: return nil
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
        let offered = a.offered == 0 ? "" : " For \(a.offered) file\(a.offered == 1 ? "" : "s") you picked another folder, kept as the next choice under Try Another Folder."
        guard !a.rows.isEmpty else { return line + "no suggestion changed." + offered }
        let shown = a.rows.prefix(Self.toldChanges).map { row -> String in
            let reason = (row.reason ?? "").isEmpty ? "" : " (" + String(row.reason!.prefix(90)) + ")"
            return "“\(row.name)” → \(row.after)\(reason)"
        }
        line += "It changed \(a.rows.count) suggested home\(a.rows.count == 1 ? "" : "s"): " + shown.joined(separator: "; ")
        if a.rows.count > shown.count { line += "; and \(a.rows.count - shown.count) more" }
        return line + "." + offered + " Nothing has moved: they still File it in Organize."
    }

    // MARK: Words: closed

    /// The one muted line a closed plan shrinks to; nil while the card is a card.
    public var closedLine: String? {
        switch phase {
        case .closed: return notice ?? "Refine plan canceled. Nothing was sent."
        case .replaced: return "Replaced by a newer plan. Nothing was sent."
        case .expired: return "This Refine plan is out of date, so it can’t send. Press Refine in Organize to make a new one."
        default: return nil
        }
    }

    /// When Send was clicked, for the running time. Not saved: a request does not outlive the app.
    public var startedAtForDisplay: Date? { startedAt }

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
