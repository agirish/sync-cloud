import Foundation
import Testing
import Sync
@testable import FileExplorer

/// What the Missing lens draws, on a made-up tree: which group each account lands in, the order,
/// the month cells, and the words. Today is 19 Nov 2026.
@Suite struct MissingLensModelTests {

    typealias Month = MissingStatements.Month

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 19))!
    static func m(_ year: Int, _ month: Int) -> Month { Month(year: year, month: month) }

    static func monthly(_ account: String, _ from: Month, _ to: Month, except: Set<Month> = []) -> [String] {
        (from.index...to.index).map(Month.init(index:)).filter { !except.contains($0) }.map {
            "\(account)/\($0.year)/\($0.month). \($0.label).pdf"
        }
    }

    static let power = "Home/Utilities/Power"
    static let phone = "Home/Utilities/Phone"
    static let bank = "Finance/Bank/Checking 0001/Statements"
    static let card = "Finance/Credit Accounts/Bank/Credit 1234"
    static let loose = "Finance/Credit Accounts/Bank/Credit 9999"
    static let old = "Finance/Closed/Savings 0002"

    /// Power lacks Mar 2025 and Sep 2026 (September waits in TODO); Phone lacks Jun 2024 and has
    /// run dry since Jan 2026; the bank is complete; one card has a silent 2025; another is used
    /// now and then; an old account went quiet in 2023 with one month missing.
    static var paths: [String] {
        monthly(power, m(2024, 1), m(2026, 10), except: [m(2025, 3), m(2026, 9)])
            + ["TODO/Finance/Power/2026/09. Sep 2026.pdf"]
            + monthly(phone, m(2023, 1), m(2026, 1), except: [m(2024, 6)])
            + monthly(bank, m(2024, 1), m(2026, 10))
            + monthly(card, m(2023, 1), m(2026, 10), except: Set((1...12).map { m(2025, $0) }))
            + [m(2023, 2), m(2023, 6), m(2023, 7), m(2024, 1), m(2024, 3), m(2024, 12), m(2025, 5), m(2025, 6), m(2026, 1)]
                .map { "\(loose)/\($0.year)/\($0.month). \($0.label).pdf" }
            + monthly(old, m(2020, 1), m(2023, 6), except: [m(2022, 2)])
    }

    static func model(_ filter: MissingFilter = .missing, query: String = "",
                      choices: MissingStatements.Choices = .init(),
                      inScope: @escaping (String) -> Bool = { _ in true }) -> MissingLensModel {
        MissingLensModel(report: MissingStatements.find(paths: paths, now: now, calendar: utc, choices: choices),
                         filter: filter, query: query, inScope: inScope)
    }

    static func rows(_ model: MissingLensModel) -> [String] {
        model.groups.map { "\($0.section.rawValue): " + $0.accounts.map { MissingLensModel.title($0) }.joined(separator: ", ") }
    }

    // MARK: Groups

    @Test func anAccountSitsInOneGroupByItsMostSeriousFinding() {
        let model = Self.model()
        #expect(Self.rows(model) == [
            // Newest gap first: Phone is behind through September, Power's newest gap is 2025.
            "recent: Utilities · Phone, Utilities · Power",
            "sinceNewest: Bank · Credit 9999",
            "older: Closed · Savings 0002",
            "cardSilences: Bank · Credit 1234",
        ])
        // Phone has an older gap too, and is listed once.
        #expect(model.groups.flatMap(\.accounts).filter { $0.path == Self.phone }.count == 1)
        #expect(model.counted == 1 + 9 + 8 + 1)
        #expect(model.counted(.recent) == 1 + 8)
        #expect(model.counted(.sinceNewest) == 8)
        #expect(model.counted(.older) == 1 + 1)
        #expect(model.countedAccounts == 4)
        #expect(model.summary == "19 statements missing from 4 accounts: 9 recent, 8 since a last statement, 2 older than two years.")
    }

    @Test func eachFilterListsWhatItsNameSays() {
        let model = Self.model()
        #expect(MissingFilter.allCases.map { model.count(for: $0) } == [5, 2, 1, 0, 6])
        #expect(Self.rows(Self.model(.expectedNext)) == ["expectedNext: Bank · Credit 9999, Utilities · Phone"])
        #expect(Self.rows(Self.model(.notTracked)) == ["notTracked: Closed · Savings 0002"])
        #expect(Self.rows(Self.model(.hidden)).isEmpty)
        #expect(Self.model(.all).groups.first?.accounts.map(\.path) == [Self.bank, Self.card, Self.loose, Self.old, Self.phone, Self.power].sorted())
    }

    @Test func hiddenAccountsAndDismissedGapsAreListedUnderHidden() {
        var choices = MissingStatements.Choices(hidden: [Self.phone])
        choices.notExpected[Self.power] = [Self.m(2025, 3)]
        let model = Self.model(.hidden, choices: choices)
        #expect(Self.rows(model) == ["hiddenAccounts: Utilities · Phone", "notExpected: Utilities · Power"])
        #expect(model.counted == 8 + 1)
        // A hidden account is in no other list, and a dismissed gap no longer places its account.
        #expect(Self.rows(Self.model(choices: choices)) == [
            "sinceNewest: Bank · Credit 9999", "older: Closed · Savings 0002", "cardSilences: Bank · Credit 1234"])
    }

    @Test func scopeAndSearchNarrowTheAccountsAndTheCount() {
        let utilities = Self.model(inScope: { $0.hasPrefix("Home/") })
        #expect(utilities.accounts.map(\.path) == [Self.phone, Self.power])
        #expect(utilities.counted == 10)
        #expect(Self.model(query: "credit 9999").accounts.map(\.path) == [Self.loose])
        // A month finds the accounts lacking it; every word must match.
        #expect(Self.model(query: "mar 2025").accounts.map(\.path) == [Self.power])
        #expect(Self.model(query: "power 2099").accounts.isEmpty)
        #expect(Self.model(query: "power 2099").summary == "No folder here holds statements named like 3. Mar 2026.")
    }

    @Test func foldersThatWouldNotListAreNamedNotCounted() {
        func note(_ folders: [String]) -> String? {
            MissingLensModel(report: MissingStatements.find(paths: Self.paths, notChecked: folders, now: Self.now, calendar: Self.utc)).notCheckedNote
        }
        #expect(note([]) == nil)
        #expect(note(["Work/Slow"]) == "1 folder could not be listed and was not checked: Work/Slow.")
        #expect(note(["Work/Slow", "Cloud/B", "Cloud/A"]) == "3 folders could not be listed and were not checked: Cloud/A and 2 more.")
    }

    // MARK: Words

    @Test func monthsReadAsAPersonWouldWriteThem() throws {
        let report = MissingStatements.find(paths: Self.paths, now: Self.now, calendar: Self.utc)
        func gaps(_ path: String) -> [String] {
            (report.accounts.first { $0.path == path }?.gaps ?? []).map { "\(MissingLensModel.text($0)) | \(MissingLensModel.status($0))" }
        }
        #expect(gaps(Self.power) == ["Mar 2025 | 1", "Sep 2026 | in To File"])
        #expect(gaps(Self.phone) == ["Jun 2024 | 1", "Feb–Sep 2026 | 8", "Oct 2026 | expected next"])
        #expect(gaps(Self.card) == ["Jan–Dec 2025 | about 12"])
        #expect(gaps(Self.loose) == ["Apr–Nov 2024 | 8 months", "Feb–Sep 2026 | 8", "Oct 2026 | expected next"])
    }

    @Test func aRowSaysWhatIsCountedThenWhatElseIsKnown() throws {
        let model = Self.model()
        func account(_ path: String) throws -> MissingStatements.Account {
            try #require(model.accounts.first { $0.path == path })
        }
        #expect(MissingLensModel.title(try account(Self.bank)) == "Bank · Checking 0001")
        #expect(MissingLensModel.subtitle(try account(Self.power), in: .recent) == "Mar 2025 · Sep 2026 in To File")
        #expect(MissingLensModel.subtitle(try account(Self.loose), in: .sinceNewest) == "Feb–Sep 2026 · 1 silence not counted")
        #expect(MissingLensModel.subtitle(try account(Self.card), in: .cardSilences) == "Jan–Dec 2025")
        #expect(MissingLensModel.subtitle(try account(Self.bank), in: .all) == "Nothing missing")
        #expect(MissingLensModel.subtitle(try account(Self.old), in: .notTracked) == "Quiet since Jun 2023 · 41 statements")
        #expect(MissingLensModel.spoken(try account(Self.power))
                == "Utilities · Power. 1 missing: Mar 2025. Sep 2026 is waiting in To File.")
    }

    @Test func copyListIsOneLineAnAccountNewestFirst() {
        var choices = MissingStatements.Choices(hidden: [Self.old])
        choices.notExpected[Self.phone] = [Self.m(2024, 6)]
        #expect(Self.model(choices: choices).copyText(rootName: "Documents") == """
            Missing statements, Documents, Nov 2026
            17 statements missing from 3 accounts: 9 recent, 8 since a last statement, 0 older than two years.

            Recent:
              Home/Utilities/Phone: Feb–Sep 2026 (8)
              Home/Utilities/Power: Mar 2025 (1); Sep 2026 (in To File)

            Since the last statement:
              Finance/Credit Accounts/Bank/Credit 9999: Feb–Sep 2026 (8); not counted: Apr–Nov 2024

            Cards with a silence:
              Finance/Credit Accounts/Bank/Credit 1234: not counted: Jan–Dec 2025 (about 12)
            """)
    }

    // MARK: The strip

    @Test func theStripDrawsThreeYearsOfMonths() throws {
        let model = Self.model()
        func strip(_ path: String) throws -> String {
            let account = try #require(model.accounts.first { $0.path == path })
            return model.cells(for: account).map { cell -> String in
                switch cell {
                case .filed: return "F"
                case .missing: return "M"
                case .uncounted: return "s"
                case .waiting: return "W"
                case .expectedNext: return "n"
                case .noneExpected: return "-"
                case .blank: return " "
                }
            }.joined()
        }
        #expect(model.stripYears == [2024, 2025, 2026])
        #expect(try strip(Self.power) == "FFFFFFFFFFFF" + "FFMFFFFFFFFF" + "FFFFFFFFWF  ")
        #expect(try strip(Self.phone) == "FFFFFMFFFFFF" + "FFFFFFFFFFFF" + "FMMMMMMMMn  ")
        #expect(try strip(Self.card) == "FFFFFFFFFFFF" + "ssssssssssss" + "FFFFFFFFFF  ")
        #expect(try strip(Self.loose) == "F-Fssssssss" + "F" + "----FF------" + "FMMMMMMMMn  ")
        // Quiet since 2023: nothing is expected, and nothing is drawn as missing.
        #expect(try strip(Self.old) == String(repeating: "-", count: 34) + "  ")
        // A finding before the strip's years is a tag, so it is not lost.
        #expect(model.earlierTag(for: try #require(model.accounts.first { $0.path == Self.old })) == "2022")
        #expect(model.earlierTag(for: try #require(model.accounts.first { $0.path == Self.power })) == nil)
    }

    @Test func aDismissedMonthIsDrawnUncounted() throws {
        var choices = MissingStatements.Choices()
        choices.notExpected[Self.phone] = [Self.m(2026, 2), Self.m(2026, 3)]
        let model = Self.model(choices: choices)
        let phone = try #require(model.accounts.first { $0.path == Self.phone })
        #expect(Array(model.cells(for: phone).suffix(12)) == [.filed, .uncounted, .uncounted] + Array(repeating: .missing, count: 6) + [.expectedNext, .blank, .blank])
        let years = model.filedByYear(phone)
        #expect(years.map(\.year) == [2023, 2024, 2025, 2026])
        #expect(years.map(\.filed) == [12, 11, 12, 1])
        #expect(years.map(\.missing) == [0, 1, 0, 6])
    }
}
