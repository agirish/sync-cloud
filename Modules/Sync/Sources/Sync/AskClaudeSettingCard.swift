import Foundation

/// A card of SyncCloud settings in Ask Claude's chat (TE290 step 4a): each row is one setting,
/// drawn with its real control at its live value, and a click on the control changes it.
///
/// **It holds ids and words, never values read from the settings.** The value on screen is read
/// live when the card is drawn, so a card restored from a saved chat can't show a stale one, and
/// nothing here is a key, a path or a hidden name. What a row remembers is only what the card
/// itself did: the value it found before its first change, so it can say "was X".
public struct AskClaudeSettingCard: Codable, Equatable, Sendable {

    public struct Row: Codable, Equatable, Sendable {
        /// The catalog id (`SettingsCatalog`), stable across label changes.
        public let id: String
        /// The source or person it belongs to, by stable id; nil for an app-wide setting.
        public let target: String?
        /// Claude's suggested value, as stored; nil when the card only shows the control.
        public let pick: String?
        /// The value before this card first changed it, as stored; nil until then.
        public var changedFrom: String?
        /// Why the last click didn't change it, shown under the control; nil when it did.
        public var refusal: String?
        /// Claude changed it itself, with set (TE290 step 4c); nil once their own click changes it.
        public var byClaude: Bool?

        public init(id: String, target: String? = nil, pick: String? = nil, changedFrom: String? = nil,
                    refusal: String? = nil, byClaude: Bool? = nil) {
            self.id = id
            self.target = target
            self.pick = pick
            self.changedFrom = changedFrom
            self.refusal = refusal
            self.byClaude = byClaude
        }
    }

    /// A short title for a card of several settings; nil for one.
    public let title: String?
    public var rows: [Row]
    /// The panel's own words above the rows, for a card the panel put up itself rather than
    /// Claude: the at-limit card (TE290 step 6). Nothing was sent for it.
    public let notice: String?
    /// The question the limit stopped, for Ask Again once the limit is raised; nil after it is
    /// asked, and on every card Claude showed.
    public var askAgain: String?

    public init(title: String? = nil, rows: [Row], notice: String? = nil, askAgain: String? = nil) {
        self.title = title
        self.rows = rows
        self.notice = notice
        self.askAgain = askAgain
    }

    /// The card the panel shows in place of the at-limit problem: Monthly limit, with the stopped
    /// question kept for Ask Again.
    public static func atLimit(spent: Double, limit: Double, resets: Date, question: String?) -> AskClaudeSettingCard {
        let day = resets.formatted(.dateTime.month(.wide).day())
        return AskClaudeSettingCard(
            rows: [Row(id: "intelligence.monthlyLimit")],
            notice: "You’ve used \(AskClaudeSpend.format(spent)) of this month’s \(AskClaudeSpend.format(limit)), so this wasn’t sent. Questions start again on \(day), or raise the limit.",
            askAgain: question)
    }
}
