import Testing
import Foundation
@testable import SyncCloudCLICore
@testable import Sync

/// `synccloud missing`'s core on a made-up tree on disk: the walk, the surveyed folder as the
/// default, the app's saved choices, and both renderings. Today is 19 Nov 2026.
@Suite struct MissingReportingTests {

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 19))!
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// A scratch folder, removed when the test ends.
    final class Scratch {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cli-missing-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func touch(_ relative: String) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }

        /// A statement a month in `account` from Jan 2024 to Oct 2026, but for `except` (`2025-03`).
        func monthly(_ account: String, except: Set<String> = []) throws {
            for year in 2024...2026 {
                for month in 1...(year == 2026 ? 10 : 12) where !except.contains(String(format: "%04d-%02d", year, month)) {
                    try touch("\(account)/\(year)/\(month). \(MissingReportingTests.months[month - 1]) \(year).pdf")
                }
            }
        }
    }

    /// Documents with a power bill lacking Mar 2025 and Sep 2026 (September waits in TODO), a
    /// phone bill lacking Jun 2024, a complete bank account, and a card with a silent year.
    private func makeTree() throws -> Scratch {
        let tree = try Scratch()
        try tree.monthly("Home/Utilities/Power", except: ["2025-03", "2026-09"])
        try tree.touch("TODO/Finance/Power/2026/09. Sep 2026.pdf")
        try tree.monthly("Home/Utilities/Phone", except: ["2024-06"])
        try tree.monthly("Finance/Bank/Checking 0001")
        try tree.monthly("Finance/Credit Accounts/Bank/Credit 1234", except: Set((1...12).map { String(format: "2025-%02d", $0) }))
        try tree.touch("Home/Utilities/Power/.DS_Store")
        try tree.touch("Home/Utilities/Power/2025/.hidden.pdf")
        return tree
    }

    /// A profiles directory whose active survey is of `root`, with the app's choices beside it.
    private func makeProfiles(root: String, ledger: String? = nil) throws -> Scratch {
        let profiles = try Scratch()
        try Data(#"{ "schemaVersion": 1, "activeProfileId": "t" }"#.utf8).write(to: profiles.url.appendingPathComponent("profiles.json"))
        try FileManager.default.createDirectory(at: profiles.url.appendingPathComponent("t"), withIntermediateDirectories: true)
        try Data(#"{ "schemaVersion": 1, "profileId": "t", "root": "\#(root)", "folders": [] }"#.utf8)
            .write(to: profiles.url.appendingPathComponent("t/folder-profile.json"))
        if let ledger { try Data(ledger.utf8).write(to: profiles.url.appendingPathComponent("t/restructure.json")) }
        return profiles
    }

    private func report(_ tree: Scratch, profiles: Scratch? = nil, named: Bool = true) throws -> MissingReporting.Output {
        let empty = try Scratch()
        return try MissingReporting.report(folder: named ? tree.url : nil, profilesDirectory: (profiles ?? empty).url,
                                           now: Self.now, calendar: Self.utc)
    }

    @Test func aNamedFolderIsWalkedAndCounted() throws {
        let tree = try makeTree()
        let output = try report(tree)
        #expect(output.root == tree.url.path)
        #expect(output.asOf == "2026-11")
        #expect(output.accounts.map(\.path) == ["Finance/Bank/Checking 0001", "Finance/Credit Accounts/Bank/Credit 1234",
                                                "Home/Utilities/Phone", "Home/Utilities/Power"])
        #expect(output.counted == 2)
        #expect(output.countedAccounts == 2)
        #expect(output.recent == 1)
        #expect(output.older == 1)
        #expect(output.sinceNewest == 0)
        #expect(output.notChecked.isEmpty)

        let power = try #require(output.accounts.last)
        #expect(power.statements == 32)
        #expect(power.gaps.map(\.kind) == ["missing", "waiting"])
        #expect(power.gaps[0].months == ["2025-03"])
        #expect(power.gaps[0].age == "recent")
        #expect(power.gaps[1].waitingFile == "TODO/Finance/Power/2026/09. Sep 2026.pdf")
        // The hidden PDF in the 2025 folder is not an unnamed file beside the gap.
        #expect(power.gaps[0].unnamedFiles == nil)

        let card = output.accounts[1]
        #expect(card.card)
        #expect(card.gaps.map(\.kind) == ["silence"])
        #expect(card.gaps[0].estimate == 12)
        #expect(card.counted == 0)
    }

    @Test func withNoFolderNamedItChecksTheSurveyedOne() throws {
        let tree = try makeTree()
        let profiles = try makeProfiles(root: tree.url.path)
        #expect(try report(tree, profiles: profiles, named: false).root == tree.url.path)
        // No survey and no folder: a sentence that says what to type, not an empty report.
        #expect(throws: MissingReporting.Failure.noFolder) { _ = try report(tree, named: false) }
        let file = tree.url.appendingPathComponent("Home/Utilities/Phone/2024/1. Jan 2024.pdf")
        #expect(throws: MissingReporting.Failure.notAFolder(path: file.path)) {
            _ = try MissingReporting.report(folder: file, profilesDirectory: tree.url, now: Self.now, calendar: Self.utc)
        }
    }

    /// The app keeps the user's choices as the `missing` section of the survey's ledger, keyed by
    /// paths inside the surveyed folder. They apply there and nowhere else.
    @Test func theAppsChoicesApplyToTheSurveyedFolderOnly() throws {
        let tree = try makeTree()
        let ledger = #"{ "schemaVersion": 1, "suppressed": [], "missing": { "hidden": ["Home/Utilities/Phone"], "notExpected": { "Home/Utilities/Power": ["2025-03"] } } }"#
        let output = try report(tree, profiles: try makeProfiles(root: tree.url.path, ledger: ledger))
        #expect(output.counted == 0)
        #expect(output.accounts.filter(\.hidden).map(\.path) == ["Home/Utilities/Phone"])
        #expect(output.accounts.last?.gaps[0].notExpected == ["2025-03"])
        // The control: the same ledger under a survey of another folder changes nothing here.
        let elsewhere = try report(tree, profiles: try makeProfiles(root: "/nowhere/else", ledger: ledger))
        #expect(elsewhere.counted == 2)
        #expect(elsewhere.accounts.filter(\.hidden).isEmpty)
        // A ledger with no such section, or one that does not read, is no choices at all.
        #expect(try report(tree, profiles: try makeProfiles(root: tree.url.path, ledger: #"{ "schemaVersion": 1 }"#)).counted == 2)
        #expect(try report(tree, profiles: try makeProfiles(root: tree.url.path, ledger: "not json")).counted == 2)
    }

    /// The text is what a person reads and pastes: the tool's own words in ASCII, one account a
    /// line, the ones worth fetching first.
    @Test func theTextNamesEachAccountOnce() throws {
        let tree = try makeTree()
        let text = MissingReporting.renderText(try report(tree))
        #expect(text == """
            Missing statements in \(tree.url.path), Nov 2026
            2 statements missing from 2 accounts: 1 recent, 0 since a last statement, 1 older than two years.

            Recent:
              Home/Utilities/Power: Mar 2025 (1); Sep 2026 (waiting in TODO/Finance/Power/2026/09. Sep 2026.pdf)

            Older than two years:
              Home/Utilities/Phone: Jun 2024 (1)

            Not counted - cards with a silence:
              Finance/Credit Accounts/Bank/Credit 1234: not counted: Jan-Dec 2025 (about 12)
            """)
        #expect(!text.unicodeScalars.contains { "‘’“”…–—".unicodeScalars.contains($0) })
    }

    @Test func theTextSaysSoWhenThereIsNothingToSay() throws {
        let empty = try Scratch()
        try empty.touch("Notes/readme.txt")
        #expect(MissingReporting.renderText(try report(empty)).hasSuffix("No folder here holds statements named like \"3. Mar 2026.pdf\"."))
        let complete = try Scratch()
        try complete.monthly("Finance/Bank/Checking 0001")
        #expect(MissingReporting.renderText(try report(complete)).hasSuffix("Nothing is missing. 1 account checked."))
    }

    /// Payslips on the 15th and the last day: a month short of two names the one absent, and a
    /// month with neither says both.
    @Test func aScheduleOfDatedDocumentsIsReportedByDay() throws {
        let tree = try Scratch()
        var n = 0
        for year in 2024...2026 {
            for month in 1...(year == 2026 ? 10 : 12) {
                let last = Self.utc.range(of: .day, in: .month, for: Self.utc.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
                for day in [15, last] where !["2024-6-30", "2025-9-15", "2025-9-30"].contains("\(year)-\(month)-\(day)") {
                    n += 1
                    try tree.touch("Work/Pay/\(year)/\(n). \(Self.months[month - 1]) \(day) \(year).pdf")
                }
            }
        }
        let output = try report(tree)
        let pay = try #require(output.accounts.first)
        #expect(pay.perMonth == 2)
        #expect(pay.gaps.map(\.days) == [[30], nil])
        #expect(pay.gaps.map(\.perMonth) == [nil, 2])
        #expect(output.counted == 3)
        #expect(MissingReporting.renderText(output).contains("  Work/Pay: Sep 2025 (both) (2); Jun 30 2024 (1)")
                || MissingReporting.renderText(output).contains("  Work/Pay: Jun 30 2024 (1); Sep 2025 (both) (2)"))
    }

    /// `--year` cuts the report to one year: its accounts, its months, its count.
    @Test func aYearCutsTheReportToThatYear() throws {
        let tree = try makeTree()
        let empty = try Scratch()
        let cut = try MissingReporting.report(folder: tree.url, profilesDirectory: empty.url, year: 2025, now: Self.now, calendar: Self.utc)
        #expect(cut.year == 2025)
        #expect(cut.counted == 1)
        #expect(cut.accounts.map(\.path) == ["Finance/Credit Accounts/Bank/Credit 1234", "Home/Utilities/Power"])
        let text = MissingReporting.renderText(cut)
        #expect(text.hasPrefix("Missing statements in \(tree.url.path), Nov 2026, for 2025 only\n1 statement missing from 1 account"))
        #expect(!text.contains("Phone"))
        #expect(try MissingReporting.renderJSON(cut).contains("\"year\" : 2025"))
        // The whole history carries no year key at all.
        #expect(!(try MissingReporting.renderJSON(try report(tree))).contains("\"year\""))
        let none = try MissingReporting.report(folder: tree.url, profilesDirectory: empty.url, year: 2019, now: Self.now, calendar: Self.utc)
        #expect(MissingReporting.renderText(none).hasSuffix("Nothing from 2019 is missing."))
    }

    @Test func monthsReadAsAPersonWouldWriteThem() {
        func gap(_ kind: String, _ months: [String]) -> MissingReporting.Output.Gap {
            .init(kind: kind, first: months.first ?? "", last: months.last ?? "", months: months, statements: 0)
        }
        #expect(MissingReporting.monthsText(gap("missing", ["2026-09"])) == "Sep 2026")
        #expect(MissingReporting.monthsText(gap("missing", ["2025-08", "2025-09", "2025-10"])) == "Aug-Oct 2025")
        #expect(MissingReporting.monthsText(gap("behind", ["2025-12", "2026-01"])) == "Dec 2025 - Jan 2026")
        #expect(MissingReporting.monthsText(gap("missing", ["2025-08", "2025-10", "2025-12"])) == "Aug, Oct, Dec 2025")
        #expect(MissingReporting.monthsText(gap("missing", ["2025-12", "2026-02"])) == "Dec 2025, Feb 2026")
        #expect(MissingReporting.monthsText(gap("silence", ["2022-02", "2024-12"])) == "Feb 2022 - Dec 2024")
        var dated = gap("missing", ["2023-06"])
        dated.days = [30]
        #expect(MissingReporting.monthsText(dated) == "Jun 30 2023")
    }

    /// The JSON format is a public surface: the statement fetch parses it, so this test is the
    /// format. A key that disappears from here disappeared from a script.
    @Test func theJSONFormatIsStableAndSorted() throws {
        let tree = try makeTree()
        let json = try MissingReporting.renderJSON(try report(tree))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object.keys.sorted() == ["accounts", "asOf", "counted", "countedAccounts", "notChecked", "older",
                                         "recent", "root", "schemaVersion", "sinceNewest"])
        #expect(object["schemaVersion"] as? Int == 1)
        let accounts = try #require(object["accounts"] as? [[String: Any]])
        let power = try #require(accounts.last)
        #expect(power.keys.sorted() == ["card", "counted", "first", "gaps", "hidden", "missingSummaries", "newest", "path",
                                        "statements", "tracking"])
        let gaps = try #require(power["gaps"] as? [[String: Any]])
        #expect(gaps[0].keys.sorted() == ["age", "first", "kind", "last", "months", "statements"])
        #expect(gaps[1].keys.sorted() == ["first", "kind", "last", "months", "statements", "waitingFile"])
        #expect(json.contains(#""waitingFile" : "TODO/Finance/Power/2026/09. Sep 2026.pdf""#))
        #expect(try JSONDecoder().decode(MissingReporting.Output.self, from: Data(json.utf8)) == (try report(tree)))
    }

    @Test func theCommandBodyWritesOnceAndTurnsAFailureIntoAUsageError() throws {
        let tree = try makeTree()
        var written: [String] = []
        try MissingReporting.run(folder: tree.url, profilesDirectory: tree.url, json: false, now: Self.now, calendar: Self.utc) {
            written.append($0)
        }
        #expect(written.count == 1)
        #expect(written.first?.contains("Home/Utilities/Phone: Jun 2024 (1)") == true)
        #expect(throws: CLIValidationError.self) {
            try MissingReporting.run(folder: nil, profilesDirectory: tree.url, json: true) { _ in }
        }
    }
}
