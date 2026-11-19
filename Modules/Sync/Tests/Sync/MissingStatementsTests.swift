import Foundation
import Testing
@testable import Sync

/// The missing-statement finder on made-up trees: one test per shape of account, each with the
/// literal months it must report, and a control where the rule under test must answer differently.
/// Today is 19 Nov 2026 throughout unless a test says otherwise, so October 2026 is the newest
/// finished month.
@Suite struct MissingStatementsTests {

    typealias Month = MissingStatements.Month
    typealias Gap = MissingStatements.Gap

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func day(_ year: Int, _ month: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: 19))!
    }

    static let now = day(2026, 11)

    static func m(_ year: Int, _ month: Int) -> Month { Month(year: year, month: month) }

    /// `account/2025/3. Mar 2025.pdf` for every month from `from` to `to`, but for `except`.
    static func monthly(_ account: String, _ from: Month, _ to: Month, except: Set<Month> = [],
                        ext: String = "pdf") -> [String] {
        (from.index...to.index).map(Month.init(index:)).filter { !except.contains($0) }.map {
            "\(account)/\($0.year)/\($0.month). \($0.label).\(ext)"
        }
    }

    /// One statement every `step` months ending `from`, `from + step`, …; `length` above 1 names
    /// each as a range (`3. Jul-Sep 2026`).
    static func every(_ step: Int, _ account: String, _ from: Month, _ to: Month, length: Int = 1,
                      except: Set<Month> = []) -> [String] {
        stride(from: from.index, through: to.index, by: step).map(Month.init(index:)).filter { !except.contains($0) }.map {
            let start = Month(index: $0.index - length + 1)
            let body = length == 1 ? $0.label : "\(start.shortName)-\($0.label)"
            return "\(account)/\($0.year)/\($0.month). \(body).pdf"
        }
    }

    static func report(_ paths: [String], now: Date = now,
                       choices: MissingStatements.Choices = .init()) -> MissingStatements.Report {
        MissingStatements.find(paths: paths, now: now, calendar: utc, choices: choices)
    }

    static func account(_ paths: [String], _ path: String, now: Date = now,
                        choices: MissingStatements.Choices = .init()) throws -> MissingStatements.Account {
        try #require(report(paths, now: now, choices: choices).accounts.first { $0.path == path },
                     "no account at \(path)")
    }

    /// `kind first–last [months] ×statements`, one per gap, so an assertion reads as the row would.
    static func lines(_ account: MissingStatements.Account) -> [String] {
        account.gaps.map { gap in
            let months = gap.months.count <= 4 ? gap.months.map(\.iso).joined(separator: ",") : "\(gap.months.count) months"
            return "\(gap.kind.rawValue) \(gap.first.iso)..\(gap.last.iso) [\(months)] x\(gap.statements)"
                + (gap.estimate.map { " ~\($0)" } ?? "")
        }
    }

    /// The account's gap at `index`, failing the test instead of trapping when there are fewer.
    static func gap(_ account: MissingStatements.Account, _ index: Int) throws -> Gap {
        try #require(account.gaps.indices.contains(index) ? account.gaps[index] : nil,
                     "no gap \(index) among \(lines(account))")
    }

    static let power = "Home/Utilities/Power"

    // MARK: Reading a name

    @Test func aNameGivesTheMonthsItCovers() {
        typealias Named = MissingStatements.Named
        func period(_ body: String) -> Named? { MissingStatements.period(ofBody: body) }
        let mar = 2026 * 12 + 2
        #expect(period("Mar 2026") == .statement(start: mar, end: mar, suffix: ""))
        #expect(period("Apr-Jun 2026") == .statement(start: mar + 1, end: mar + 3, suffix: ""))
        #expect(period("Nov 2023-Feb 2024") == .statement(start: 2023 * 12 + 10, end: 2024 * 12 + 1, suffix: ""))
        #expect(period("Apr 2007 to Aug 2007") == .statement(start: 2007 * 12 + 3, end: 2007 * 12 + 7, suffix: ""))
        // A same-year range that runs backward began the year before.
        #expect(period("Nov-Feb 2024") == .statement(start: 2023 * 12 + 10, end: 2024 * 12 + 1, suffix: ""))
        // Spellings the tree really has.
        #expect(period("July 2016") == .statement(start: 2016 * 12 + 6, end: 2016 * 12 + 6, suffix: ""))
        #expect(period("Jan -Mar 2021") == .statement(start: 2021 * 12, end: 2021 * 12 + 2, suffix: ""))
        #expect(period("jun 2014 NRE") == .statement(start: 2014 * 12 + 5, end: 2014 * 12 + 5, suffix: "NRE"))
        #expect(period("Apr 2022 (NRO)") == .statement(start: 2022 * 12 + 3, end: 2022 * 12 + 3, suffix: "(NRO)"))
        #expect(period("Jan 15 2026") == .dayDated)
        #expect(period("Summary 2022") == nil)
        #expect(period("Feb 2024-Nov 2023") == nil)
    }

    @Test func aFileNameIsAStatementASummaryOrNeither() {
        #expect(MissingStatements.read("07. July 2016.pdf") == .statement(start: 2016 * 12 + 6, end: 2016 * 12 + 6, suffix: ""))
        #expect(MissingStatements.read("0. Summary 2022.pdf") == .summary(year: 2022))
        #expect(MissingStatements.read("0. Spend 2019.pdf") == .summary(year: 2019))
        #expect(MissingStatements.read("05. Jan 15 2026.pdf") == .dayDated)
        #expect(MissingStatements.read("Statement_2026-07.pdf") == nil)
        #expect(MissingStatements.read("3. Receipt.pdf") == nil)
    }

    // MARK: Holes

    @Test func oneMissingMonthInASteadyAccountIsCounted() throws {
        let a = try Self.account(Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)]), Self.power)
        #expect(Self.lines(a) == ["missing 2025-03..2025-03 [2025-03] x1"])
        #expect(try Self.gap(a, 0).age == .recent)
        #expect(a.tracking == .tracked)
        #expect(a.statements == 33)
    }

    /// The fault the second review found: a rule that needs four statements after a break cannot
    /// see a hole next to the newest one, which is the hole worth fetching.
    @Test func aHoleNextToTheNewestStatementShows() throws {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2026, 9)])
        #expect(Self.lines(try Self.account(paths, Self.power)) == ["missing 2026-09..2026-09 [2026-09] x1"])
        // And next to the oldest: three statements before the hole are enough.
        let early = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2024, 4)])
        #expect(Self.lines(try Self.account(early, Self.power)) == ["missing 2024-04..2024-04 [2024-04] x1"])
    }

    @Test func twoHolesCloseTogetherDoNotHideEachOther() throws {
        let paths = Self.monthly(Self.power, Self.m(2023, 1), Self.m(2026, 10), except: [Self.m(2025, 3), Self.m(2025, 6), Self.m(2025, 7)])
        #expect(Self.lines(try Self.account(paths, Self.power)) == [
            "missing 2025-03..2025-03 [2025-03] x1",
            "missing 2025-06..2025-07 [2025-06,2025-07] x2",
        ])
    }

    @Test func aWholeYearIsTwelveAndALongerGapIsASilenceWithAnEstimate() throws {
        let year = Set((1...12).map { Self.m(2025, $0) })
        let twelve = try Self.account(Self.monthly(Self.power, Self.m(2023, 1), Self.m(2026, 10), except: year), Self.power)
        #expect(Self.lines(twelve) == ["missing 2025-01..2025-12 [12 months] x12"])
        #expect(twelve.counted == 12)

        let longer = year.union([Self.m(2024, 12)])
        let thirteen = try Self.account(Self.monthly(Self.power, Self.m(2022, 1), Self.m(2026, 10), except: longer), Self.power)
        #expect(Self.lines(thirteen) == ["silence 2024-12..2025-12 [13 months] x0 ~13"])
        #expect(thirteen.counted == 0)
    }

    @Test func anAccountBilledEveryTwoMonthsOwesOnlyItsOwnMonths() throws {
        let water = "Home/Utilities/Water"
        let paths = Self.every(2, water, Self.m(2024, 2), Self.m(2026, 10), except: [Self.m(2025, 8), Self.m(2025, 10), Self.m(2025, 12)])
        let a = try Self.account(paths, water)
        // The gap runs Jul 2025 to Jan 2026, but only the even months were ever due.
        #expect(Self.lines(a) == ["missing 2025-07..2026-01 [2025-08,2025-10,2025-12] x3"])
    }

    @Test func aQuarterlyAccountNamedByItsLastMonth() throws {
        let futures = "Finance/Brokerage/Futures 0001"
        let a = try Self.account(Self.every(3, futures, Self.m(2022, 3), Self.m(2026, 9), except: [Self.m(2023, 6)]), futures)
        #expect(Self.lines(a) == ["missing 2023-04..2023-08 [2023-06] x1"])
        #expect(try Self.gap(a, 0).age == .older)
    }

    @Test func quarterToDateNamesCountForTheirLastMonth() throws {
        let savings = "Finance/Bank/Savings 0002"
        func quarter(_ year: Int, _ first: Int) -> [String] {
            let names = ["\(first). \(Self.m(year, first).label)",
                         "\(first + 1). \(Self.m(year, first).shortName)-\(Self.m(year, first + 1).label)",
                         "\(first + 2). \(Self.m(year, first).shortName)-\(Self.m(year, first + 2).label)"]
            return names.map { "\(savings)/\(year)/\($0).pdf" }
        }
        var paths: [String] = []
        for year in 2024...2026 { for first in [1, 4, 7, 10] where year < 2026 || first <= 7 { paths += quarter(year, first) } }
        paths.append("\(savings)/2026/10. Oct 2026.pdf")
        // 34 files, each read as one month: nothing is missing.
        #expect(Self.lines(try Self.account(paths, savings)).isEmpty)
        // A whole quarter gone is three statements.
        let without = paths.filter { !quarter(2025, 4).contains($0) }
        #expect(Self.lines(try Self.account(without, savings)) == ["missing 2025-04..2025-06 [2025-04,2025-05,2025-06] x3"])
    }

    // MARK: The end

    @Test func theNewestFinishedMonthIsNeverCounted() throws {
        let behind = try Self.account(Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 1)), Self.power)
        #expect(Self.lines(behind) == ["behind 2026-02..2026-09 [8 months] x8", "expectedNext 2026-10..2026-10 [2026-10] x0"])
        let current = try Self.account(Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 9)), Self.power)
        #expect(Self.lines(current) == ["expectedNext 2026-10..2026-10 [2026-10] x0"])
        let ahead = try Self.account(Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10)), Self.power)
        #expect(Self.lines(ahead).isEmpty)
    }

    @Test func aQuarterNamedAsARangeOwesNothingUntilItIsOver() throws {
        let plan = "Finance/Savings Plan"
        let paths = Self.every(3, plan, Self.m(2023, 3), Self.m(2026, 9), length: 3)
        // Jul-Sep 2026 is filed; Oct-Dec cannot exist in November, December or January.
        #expect(Self.lines(try Self.account(paths, plan)).isEmpty)
        #expect(Self.lines(try Self.account(paths, plan, now: Self.day(2026, 12))).isEmpty)
        #expect(Self.lines(try Self.account(paths, plan, now: Self.day(2027, 1))) == ["expectedNext 2026-12..2026-12 [2026-12] x0"])
        #expect(Self.lines(try Self.account(paths, plan, now: Self.day(2027, 2))) == ["behind 2026-10..2026-12 [2026-12] x1"])
    }

    // MARK: Accounts with no steady rhythm, and cards

    static let card = "Finance/Credit Accounts/Bank/Credit 1234"
    /// A card used now and then: statements in scattered months, newest Jan 2026.
    static let occasional: [Month] = [m(2023, 2), m(2023, 6), m(2023, 7), m(2024, 1), m(2024, 3), m(2024, 12), m(2025, 5), m(2025, 6), m(2026, 1)]

    static func scattered(_ months: [Month], in account: String = card) -> [String] {
        months.map { "\(account)/\($0.year)/\($0.month). \($0.label).pdf" }
    }

    @Test func everyMonthAfterTheNewestStatementOfALooseAccountCounts() throws {
        let a = try Self.account(Self.scattered(Self.occasional), Self.card)
        #expect(a.isCard)
        #expect(Self.lines(a) == [
            "silence 2024-04..2024-11 [8 months] x0",
            "open 2026-02..2026-09 [8 months] x8",
            "expectedNext 2026-10..2026-10 [2026-10] x0",
        ])
        #expect(try Self.gap(a, 1).age == .sinceNewest)
        // Six months between Jun 2025 and Jan 2026 is this card's ordinary pause, not a silence.
        #expect(!a.gaps.contains { $0.first == Self.m(2025, 7) })
    }

    /// Decision PF: a new statement ends the count of the months before it.
    @Test func aNewStatementStopsCountingTheMonthsBeforeIt() throws {
        let before = try Self.account(Self.scattered(Self.occasional), Self.card)
        #expect(before.counted == 8)
        let after = try Self.account(Self.scattered(Self.occasional + [Self.m(2026, 6)]), Self.card)
        #expect(after.counted == 3)
        #expect(after.gaps.filter(\.isCounted).map(\.first) == [Self.m(2026, 7)])
    }

    @Test func aCardsGapCountsOnlyInAnUnbrokenRun() throws {
        // One hole in three unbroken years: counted.
        let one = try Self.account(Self.monthly(Self.card, Self.m(2023, 1), Self.m(2026, 10), except: [Self.m(2025, 3)]), Self.card)
        #expect(Self.lines(one) == ["missing 2025-03..2025-03 [2025-03] x1"])
        // Two holes near each other: a card that skips months. Neither is counted or shown.
        let skips: Set<Month> = [Self.m(2025, 3), Self.m(2025, 8)]
        let two = try Self.account(Self.monthly(Self.card, Self.m(2023, 1), Self.m(2026, 10), except: skips), Self.card)
        #expect(Self.lines(two).isEmpty)
        // The control: the same months in an account that is not a card are two missing statements.
        let bank = try Self.account(Self.monthly(Self.power, Self.m(2023, 1), Self.m(2026, 10), except: skips), Self.power)
        #expect(bank.counted == 2)
        #expect(!bank.isCard)
    }

    @Test func aCardsLongGapIsASilenceNeverACount() throws {
        let year = Set((1...12).map { Self.m(2025, $0) })
        let a = try Self.account(Self.monthly(Self.card, Self.m(2023, 1), Self.m(2026, 10), except: year), Self.card)
        #expect(Self.lines(a) == ["silence 2025-01..2025-12 [12 months] x0 ~12"])
    }

    // MARK: Summaries

    @Test func aYearHoldingOnlyItsSummaryIsCutOutOfTheTimeline() throws {
        let broker = "Finance/Brokerage/Account 0003"
        let statements = Self.monthly(broker, Self.m(2022, 1), Self.m(2023, 12)) + Self.monthly(broker, Self.m(2025, 2), Self.m(2026, 10))
        let withSummary = statements + ["\(broker)/2024/0. Summary 2024.pdf"]
        // January 2025 is one missing statement, not thirteen months.
        #expect(Self.lines(try Self.account(withSummary, broker)) == ["missing 2025-01..2025-01 [2025-01] x1"])
        // The control: without the summary file the same year is a gap too long to count.
        #expect(Self.lines(try Self.account(statements, broker)) == ["silence 2024-01..2025-01 [13 months] x0 ~13"])
    }

    @Test func aSummaryIsExpectedWhereTheTwoYearsBeforeHaveOne() throws {
        let paths = Self.monthly(Self.card, Self.m(2022, 1), Self.m(2026, 10))
            + ["\(Self.card)/2022/0. Summary 2022.pdf", "\(Self.card)/2023/0. Summary 2023.pdf"]
        #expect(try Self.account(paths, Self.card).missingSummaries == [2024])
        // 2026 is not over, and 2025 has no two summaries before it.
        #expect(try Self.account(paths + ["\(Self.card)/2024/0. Summary 2024.pdf"], Self.card).missingSummaries == [2025])
        #expect(try Self.account(Self.monthly(Self.card, Self.m(2022, 1), Self.m(2026, 10)), Self.card).missingSummaries.isEmpty)
    }

    // MARK: Files beside a gap

    @Test func aMonthWithOnlyItsCSVIsMissingWhereThePDFIsTheHabit() throws {
        let pdfs = Self.monthly(Self.card, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 5)])
        let csvs = Self.monthly(Self.card, Self.m(2024, 1), Self.m(2026, 10), ext: "csv")
        let a = try Self.account(pdfs + csvs, Self.card)
        #expect(Self.lines(a) == ["csvOnly 2025-05..2025-05 [2025-05] x1"])
        // A PDF and its CSV are one statement.
        #expect(a.statements == 34)
        // The control: an account kept only as CSVs lacks nothing.
        #expect(Self.lines(try Self.account(csvs, Self.card)).isEmpty)
    }

    @Test func aGapBesideUnnamedFilesIsShownAndNeverCounted() throws {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)])
        let beside = try Self.account(paths + ["\(Self.power)/2025/Statement_download.pdf"], Self.power)
        #expect(Self.lines(beside) == ["missing 2025-03..2025-03 [2025-03] x0"])
        #expect(try Self.gap(beside, 0).unnamedFiles == 1)
        #expect(try Self.gap(beside, 0).age == nil)
        // An unnamed file in another year says nothing about this gap, nor does a spreadsheet.
        let elsewhere = try Self.account(paths + ["\(Self.power)/2024/Statement_download.pdf", "\(Self.power)/2025/notes.xlsx"], Self.power)
        #expect(elsewhere.counted == 1)
        // Two loose PDFs in the account folder are a letter and a notice; three are a backlog.
        let loose = (1...3).map { "\(Self.power)/bill-\($0).pdf" }
        #expect(try Self.account(paths + loose.prefix(2), Self.power).counted == 1)
        let doubted = try Self.account(paths + loose, Self.power)
        #expect(doubted.counted == 0)
        #expect(try Self.gap(doubted, 0).unnamedFiles == 3)
    }

    @Test func aNamedStatementInAnInboxFolderIsWaiting() throws {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2026, 9), Self.m(2025, 3)])
            + ["TODO/Finance/Power/2026/09. Sep 2026.pdf"]
        let a = try Self.account(paths, Self.power)
        #expect(Self.lines(a) == ["missing 2025-03..2025-03 [2025-03] x1", "waiting 2026-09..2026-09 [2026-09] x0"])
        #expect(try Self.gap(a, 1).waitingFile == "TODO/Finance/Power/2026/09. Sep 2026.pdf")
        // Another account's statement for the same month does not fill it.
        let other = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2026, 9)])
            + ["TODO/Finance/Water/2026/09. Sep 2026.pdf"]
        #expect(try Self.account(other, Self.power).counted == 1)
    }

    // MARK: What is checked

    @Test func archiveDeletedInboxAndHiddenFoldersAreNeverAccounts() {
        let months = (Self.m(2024, 1), Self.m(2026, 10))
        let paths = Self.monthly("Finance/Archive/Old Bank", months.0, months.1)
            + Self.monthly("Home/Deleted/Utilities/Power", months.0, months.1)
            + Self.monthly("TODO/Finance/Power", months.0, months.1)
            + Self.monthly(".Trash/Power", months.0, months.1)
            + Self.monthly("Finance/Closed", months.0, months.1)
            + Self.monthly(Self.power, months.0, months.1)
        let report = MissingStatements.find(paths: paths, notChecked: ["Work/Slow", "Cloud/B"], now: Self.now, calendar: Self.utc,
                                            isArchived: { $0 == "Finance/Closed" })
        #expect(report.accounts.map(\.path) == [Self.power])
        #expect(report.notChecked == ["Cloud/B", "Work/Slow"])
        #expect(report.asOf == Self.m(2026, 11))
    }

    @Test func aFolderNeedsFourStatementsToBeAnAccount() {
        let three = Self.monthly("Finance/New", Self.m(2026, 8), Self.m(2026, 10))
        #expect(Self.report(three).accounts.isEmpty)
        #expect(Self.report(three + Self.monthly("Finance/New", Self.m(2026, 7), Self.m(2026, 7))).accounts.map(\.path) == ["Finance/New"])
        // Statements kept without year folders are an account too.
        let flat = (7...10).map { "Finance/Flat/\($0). \(Self.m(2026, $0).label).pdf" }
        #expect(Self.report(flat).accounts.map(\.path) == ["Finance/Flat"])
    }

    @Test func aRecurringSuffixIsItsOwnSeries() throws {
        let bank = "Finance/Bank/Savings 0004"
        let plain = Self.monthly(bank, Self.m(2024, 1), Self.m(2026, 10))
        func marked(_ months: [Month]) -> [String] { months.map { "\(bank)/\($0.year)/\($0.month). \($0.label) (NRO).pdf" } }
        let all = (Self.m(2024, 1).index...Self.m(2026, 10).index).map(Month.init(index:))
        // The marked series lacks March 2025 although the plain one has it.
        let a = try Self.account(plain + marked(all.filter { $0 != Self.m(2025, 3) }), bank)
        #expect(Self.lines(a) == ["missing 2025-03..2025-03 [2025-03] x1"])
        #expect(try Self.gap(a, 0).series == "(NRO)")
        #expect(a.statements == 67)
        // One stray marked file is not a series; it is March's statement.
        let stray = try Self.account(Self.monthly(bank, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)]) + marked([Self.m(2025, 3)]), bank)
        #expect(Self.lines(stray).isEmpty)
    }

    // MARK: What the user decided

    @Test func choicesTakeGapsOffTheCountAndPutSilencesOnIt() throws {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3), Self.m(2025, 6), Self.m(2025, 7)])
        var choices = MissingStatements.Choices()
        choices.notExpected[Self.power] = [Self.m(2025, 6)]
        let a = try Self.account(paths, Self.power, choices: choices)
        #expect(a.counted == 2)
        #expect(try Self.gap(a, 1).notExpected == [Self.m(2025, 6)])
        #expect(try Self.gap(a, 1).statements == 1)

        var count = MissingStatements.Choices()
        count.counted[Self.card] = [Self.m(2024, 4), Self.m(2024, 5)]
        let silent = try Self.account(Self.scattered(Self.occasional), Self.card, choices: count)
        #expect(try Self.gap(silent, 0).statements == 2)
        // Its last month, Nov 2024, is exactly two years back: still recent.
        #expect(try Self.gap(silent, 0).age == .recent)
        #expect(silent.counted == 10)
    }

    @Test func aHiddenAccountIsListedAndLeftOutOfEveryCount() {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2025, 3)])
            + Self.monthly("Home/Utilities/Phone", Self.m(2024, 1), Self.m(2026, 10), except: [Self.m(2024, 6)])
        let open = Self.report(paths)
        #expect(open.counted == 2)
        #expect(open.countedAccounts == 2)
        #expect(open.counted(.recent) == 1)
        #expect(open.counted(.older) == 1)
        let hidden = Self.report(paths, choices: .init(hidden: [Self.power]))
        #expect(hidden.counted == 1)
        #expect(hidden.countedAccounts == 1)
        #expect(hidden.accounts.map { "\($0.path) \($0.isHidden)" } == ["Home/Utilities/Phone false", "Home/Utilities/Power true"])
    }

    @Test func stopTrackingLastsUntilTheNextStatement() throws {
        let paths = Self.monthly(Self.power, Self.m(2024, 1), Self.m(2026, 1), except: [Self.m(2025, 3)])
        let stopped = MissingStatements.Choices(stopped: [Self.power: Self.m(2026, 1)])
        let a = try Self.account(paths, Self.power, choices: stopped)
        #expect(a.tracking == .stopped)
        // The months after its newest statement are gone; its earlier gap stays.
        #expect(Self.lines(a) == ["missing 2025-03..2025-03 [2025-03] x1"])
        // A newer statement starts tracking again, with the same saved choice.
        let again = try Self.account(paths + Self.monthly(Self.power, Self.m(2026, 4), Self.m(2026, 4)), Self.power, choices: stopped)
        #expect(again.tracking == .tracked)
        #expect(again.counted == 1 + 2 + 5)
    }

    @Test func anAccountAlreadySilentAtTheFirstCheckIsQuietAndATrackedOneNeverGoesQuiet() throws {
        let paths = Self.monthly(Self.power, Self.m(2022, 1), Self.m(2025, 3))
        // First checked today, nineteen months after its newest statement: quiet, nothing owed.
        let quiet = try Self.account(paths, Self.power)
        #expect(quiet.tracking == .quiet)
        #expect(Self.lines(quiet).isEmpty)
        // First checked in January 2026, ten months after: tracked then, so still counting now.
        let tracked = try Self.account(paths, Self.power, choices: .init(firstChecked: Self.m(2026, 1)))
        #expect(tracked.tracking == .tracked)
        #expect(Self.lines(tracked) == ["behind 2025-04..2026-09 [18 months] x18", "expectedNext 2026-10..2026-10 [2026-10] x0"])
        // A quiet account the user started in August 2026 owes from then on.
        let started = try Self.account(paths, Self.power, choices: .init(started: [Self.power: Self.m(2026, 8)]))
        #expect(started.tracking == .tracked)
        #expect(Self.lines(started) == ["open 2026-08..2026-09 [2026-08,2026-09] x2", "expectedNext 2026-10..2026-10 [2026-10] x0"])
    }

    @Test func choicesSurviveTheirOwnJSONAndReadAPartialOne() throws {
        let choices = MissingStatements.Choices(hidden: ["A/B"], stopped: ["C": Self.m(2026, 1)], started: ["D": Self.m(2026, 8)],
                                                notExpected: ["E": [Self.m(2025, 6)]], counted: ["F": [Self.m(2024, 4)]],
                                                firstChecked: Self.m(2026, 11))
        let data = try JSONEncoder().encode(choices)
        #expect(try JSONDecoder().decode(MissingStatements.Choices.self, from: data) == choices)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""firstChecked":"2026-11""#))
        // Sections a later build adds, or an older file lacks, never fail the read.
        let partial = try JSONDecoder().decode(MissingStatements.Choices.self, from: Data(#"{"hidden":["A/B"],"later":1}"#.utf8))
        #expect(partial == MissingStatements.Choices(hidden: ["A/B"]))
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(MissingStatements.Choices.self, from: Data(#"{"firstChecked":"Nov 2026"}"#.utf8))
        }
    }

    // MARK: Remove one statement, anywhere

    /// The second review's tests as properties: take one statement out of a steady account, at
    /// every position but the two ends, and the rule must name exactly that statement.
    @Test(arguments: [1, 2, 3])
    func removingAnyOneStatementIsCaught(step: Int) {
        let from = Self.m(2022, 3), to = Self.m(2026, 9)
        let ends = stride(from: from.index, through: to.index, by: step).map(Month.init(index:))
        var missed: [String] = []
        for removed in ends.dropFirst().dropLast() {
            let paths = Self.every(step, "Finance/Bank/Checking 0005", from, to, except: [removed])
            let gaps = Self.report(paths).accounts.first?.gaps.filter { $0.kind == .missing } ?? []
            if gaps.map(\.months) != [[removed]] { missed.append(removed.iso) }
        }
        #expect(missed.isEmpty, "every \(step) month(s): not caught, or caught as something else")
        #expect(ends.count >= 19)
    }
}
