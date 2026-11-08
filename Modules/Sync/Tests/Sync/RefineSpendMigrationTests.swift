import Foundation
import Testing
@testable import Sync

/// Refine's own caps and spend history give way to Ask Claude's one limit (TE335, E5): this month's
/// spend is carried into the total once, the old keys go, and one notice says what the old limits were.
@Suite struct RefineSpendMigrationTests {

    /// Mid-month, so the entries below sit inside or outside "this month" in any time zone.
    private let now = Date(timeIntervalSince1970: 1_794_000_000)           // 2026-11-07
    private var thisMonth: Date { now.addingTimeInterval(-3 * 86_400) }
    private var lastMonth: Date { now.addingTimeInterval(-40 * 86_400) }

    private func entry(_ cost: Double, at date: Date) -> FilingSpendEntry {
        FilingSpendEntry(timestamp: date, model: "claude-opus-5-5", fileCount: 5, placedCount: 5,
                         inputTokens: 1000, outputTokens: 100, cacheReadTokens: 0, cacheCreationTokens: 0,
                         estimatedCostUSD: cost)
    }

    /// The record the old store left, written under its keys.
    private func writeOldRecord(_ defaults: UserDefaults, entries: [FilingSpendEntry], totalCost: Double? = nil) throws {
        defaults.set(try JSONEncoder().encode(entries), forKey: FilingSpendStore.historyKey)
        let total = totalCost ?? entries.reduce(0) { $0 + $1.estimatedCostUSD }
        defaults.set(try JSONEncoder().encode(FilingSpendTotals(costUSD: total, tokens: 1100 * entries.count, scans: entries.count)),
                     forKey: FilingSpendStore.totalsKey)
        if let last = entries.last { defaults.set(try JSONEncoder().encode(last), forKey: FilingSpendStore.lastKey) }
    }

    private func oldKeysLeft(_ defaults: UserDefaults) -> [String] {
        [FilingSpendStore.historyKey, FilingSpendStore.totalsKey, FilingSpendStore.lastKey,
         RefineSpendMigration.monthlyCapKey, RefineSpendMigration.totalCapKey,
         RefineSpendMigration.modelKey, RefineSpendMigration.switchKey].filter { defaults.object(forKey: $0) != nil }
    }

    // MARK: The carry-over

    @Test func thisMonthsRefineSpendJoinsAskClaudesTotalAndOrganizesShare() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        AskClaudeSpend.record(1.00, in: defaults, now: now)                       // the chat's, already counted
        try writeOldRecord(defaults, entries: [entry(0.40, at: lastMonth), entry(0.25, at: thisMonth), entry(0.10, at: thisMonth)])

        let line = RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)

        #expect(line != nil)
        #expect(abs(AskClaudeSpend.spent(in: defaults, now: now) - 1.35) < 1e-9, "the chat's $1.00 and Refine's $0.35 of this month")
        #expect(abs(AskClaudeSpend.organizeSpent(in: defaults, now: now) - 0.35) < 1e-9, "Organize's share is the carried part only")
        #expect(oldKeysLeft(defaults).isEmpty, "the old record, caps, model and switch are deleted: \(oldKeysLeft(defaults))")
        #expect(defaults.bool(forKey: RefineSpendMigration.doneKey))
    }

    @Test func itRunsOnceSoASecondLaunchCountsNothingTwice() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        try writeOldRecord(defaults, entries: [entry(0.25, at: thisMonth)])
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        let first = AskClaudeSpend.spent(in: defaults, now: now)

        // A record turning up again (a restored backup, say) is not carried a second time.
        try writeOldRecord(defaults, entries: [entry(0.25, at: thisMonth)])
        #expect(RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now) == nil)
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == first)
        #expect(abs(first - 0.25) < 1e-9)
    }

    /// Nothing recorded and no cap chosen: nothing to carry and nothing to say, but it still stamps,
    /// so it never looks again.
    @Test func aMachineThatNeverUsedRefineGetsNoNoticeAndIsStamped() {
        let defaults = ScratchDefaults("RefineSpendMigration")
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        #expect(RefineSpendMigration.pendingNotice(in: defaults) == nil)
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == 0 && AskClaudeSpend.organizeSpent(in: defaults, now: now) == 0)
        #expect(defaults.bool(forKey: RefineSpendMigration.doneKey))
    }

    // MARK: The notice

    @Test func theNoticeNamesBothOldCapsAndWhatRefineHadCost() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        defaults.set(5.0, forKey: RefineSpendMigration.monthlyCapKey)
        defaults.set(25.0, forKey: RefineSpendMigration.totalCapKey)
        try writeOldRecord(defaults, entries: [entry(0.40, at: lastMonth), entry(0.25, at: thisMonth)])

        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)

        let notice = try #require(RefineSpendMigration.pendingNotice(in: defaults))
        #expect(notice.monthlyCapUSD == 5 && notice.totalCapUSD == 25 && notice.requests == 2)
        #expect(abs(notice.spentThisMonthUSD - 0.25) < 1e-9 && abs(notice.spentTotalUSD - 0.65) < 1e-9)
        #expect(notice.since == lastMonth)
        let text = notice.text
        #expect(text.contains("\(AskClaudeSpend.format(5)) a month") && text.contains("\(AskClaudeSpend.format(25)) in total"), "\(text)")
        #expect(text.contains("They are gone."))
        #expect(text.contains("which now counts toward the limit."), "this month's carried spend is named")
    }

    /// With no total cap chosen the default $5 applied, and the notice says $5, not "no limit".
    @Test func anUnsetTotalCapIsReportedAsTheFiveDollarDefaultItWas() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        try writeOldRecord(defaults, entries: [entry(0.25, at: thisMonth)])
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        let notice = try #require(RefineSpendMigration.pendingNotice(in: defaults))
        #expect(notice.totalCapUSD == 5 && notice.monthlyCapUSD == 0)
        #expect(notice.text.contains("\(AskClaudeSpend.format(5)) in total"))
        #expect(!notice.text.contains("a month"), "no monthly cap was set, so none is named")
    }

    /// Someone who chose a cap but never used Refine still learns it is gone.
    @Test func aChosenCapWithNoSpendStillGetsTheNoticeWithoutACostClause() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        defaults.set(2.0, forKey: RefineSpendMigration.monthlyCapKey)
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        let notice = try #require(RefineSpendMigration.pendingNotice(in: defaults))
        #expect(notice.requests == 0 && notice.spentTotalUSD == 0)
        #expect(!notice.text.contains("had cost"))
        #expect(notice.text.contains("\(AskClaudeSpend.format(2)) a month"))
    }

    @Test func lastMonthsSpendIsInTheNoticeButNotInThisMonthsTotal() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        try writeOldRecord(defaults, entries: [entry(0.80, at: lastMonth)])
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == 0)
        let notice = try #require(RefineSpendMigration.pendingNotice(in: defaults))
        #expect(abs(notice.spentTotalUSD - 0.80) < 1e-9 && notice.spentThisMonthUSD == 0)
        #expect(!notice.text.contains("which now counts toward the limit."), "nothing of last month counts")
    }

    @Test func dismissingTheNoticeKeepsTheStamp() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        try writeOldRecord(defaults, entries: [entry(0.25, at: thisMonth)])
        RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)
        #expect(RefineSpendMigration.pendingNotice(in: defaults) != nil)

        RefineSpendMigration.dismissNotice(in: defaults)

        #expect(RefineSpendMigration.pendingNotice(in: defaults) == nil)
        #expect(defaults.bool(forKey: RefineSpendMigration.doneKey), "dismissing is not un-migrating")
        #expect(RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now) == nil, "and the notice does not come back")
    }

    // MARK: A record that cannot be read

    /// Carrying a month of spend from nothing would under-count it, so an unreadable record is left
    /// alone and unstamped, and the next launch tries again.
    @Test func anUnreadableRecordIsLeftAloneAndTriedAgainNextLaunch() throws {
        let defaults = ScratchDefaults("RefineSpendMigration")
        defaults.set(Data("[{\"model\":\"claude".utf8), forKey: FilingSpendStore.historyKey)   // a truncated write
        defaults.set(2.0, forKey: RefineSpendMigration.monthlyCapKey)

        let line = RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now)

        #expect(line?.contains("couldn’t be read") == true)
        #expect(!defaults.bool(forKey: RefineSpendMigration.doneKey), "not stamped, so it is tried again")
        #expect(defaults.data(forKey: FilingSpendStore.historyKey) != nil, "the record is still there")
        #expect(defaults.object(forKey: RefineSpendMigration.monthlyCapKey) != nil, "and so is the cap the notice will name")
        #expect(AskClaudeSpend.spent(in: defaults, now: now) == 0 && AskClaudeSpend.organizeSpent(in: defaults, now: now) == 0)
        #expect(RefineSpendMigration.pendingNotice(in: defaults) == nil)

        // The record is repaired (restored from the `.unreadable` copy, say): the next launch carries it.
        try writeOldRecord(defaults, entries: [entry(0.30, at: thisMonth)])
        #expect(RefineSpendMigration.applyAtLaunch(defaults: defaults, now: now) != nil)
        #expect(abs(AskClaudeSpend.spent(in: defaults, now: now) - 0.30) < 1e-9)
        #expect(defaults.bool(forKey: RefineSpendMigration.doneKey))
    }
}
