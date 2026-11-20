import Foundation
import Sync

/// Which accounts the Missing lens lists.
///
/// Sentence case, like the Duplicates filters: these are labels on a segmented choice, not
/// buttons.
enum MissingFilter: String, CaseIterable, Identifiable {
    /// Every account with something to say, the default.
    case missing
    /// Accounts whose newest finished month has no statement yet. Not late, so never counted.
    case expectedNext
    /// Accounts nothing is expected from: quiet at the first check, or stopped by the user.
    case notTracked
    /// Accounts the user hid, and accounts with a gap marked Not Expected.
    case hidden
    /// Every account checked, the complete ones included.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missing: return "Missing"
        case .expectedNext: return "Expected next"
        case .notTracked: return "Not tracked"
        case .hidden: return "Hidden"
        case .all: return "All accounts"
        }
    }
}

/// What the Missing lens draws, as a pure function of the finder's report, the scope, the search
/// and the filter: which accounts, in which groups, with which month cells and which words.
///
/// Kept apart from the view so the grouping and the wording can be asserted directly; the view
/// only lays this out.
struct MissingLensModel {

    typealias Account = MissingStatements.Account
    typealias Gap = MissingStatements.Gap
    typealias Month = MissingStatements.Month

    /// A group in the list. An account appears in exactly one, the first it qualifies for, so the
    /// same folder is never read twice down the list.
    enum Section: String, CaseIterable {
        case recent, sinceNewest, older, silences, cardSilences, summaries
        case expectedNext, notTracked, hiddenAccounts, notExpected, all

        var title: String {
            switch self {
            case .recent: return "Recent"
            case .sinceNewest: return "Since the last statement"
            case .older: return "Older than two years"
            case .silences: return "Long silences"
            case .cardSilences: return "Cards with a silence"
            case .summaries: return "Year summaries"
            case .expectedNext: return "Expected next"
            case .notTracked: return "Not tracked"
            case .hiddenAccounts: return "Hidden accounts"
            case .notExpected: return "Gaps marked Not Expected"
            case .all: return "Every checked account"
            }
        }

        /// What the group's heading adds, or nil.
        var note: String? {
            switch self {
            case .recent: return "gaps from the last two years"
            case .sinceNewest: return "no steady rhythm, so every month counts until its next statement"
            case .older: return nil
            case .silences: return "accounts that normally keep sending; not counted"
            case .cardSilences: return "may be months they were not used; not counted"
            case .summaries: return "not counted"
            case .expectedNext: return "the newest finished month is never counted"
            case .notTracked: return "nothing is expected after the newest statement"
            case .hiddenAccounts: return "left out of every list and count"
            case .notExpected: return "off the count"
            case .all: return nil
            }
        }
    }

    struct Group: Identifiable {
        let section: Section
        let accounts: [Account]
        var id: String { section.rawValue }
    }

    /// One month on an account's strip.
    enum Cell: Equatable {
        case filed, missing, uncounted, waiting, expectedNext, noneExpected, blank
        /// Some of the month's dated documents are here and some are not: one payslip of two.
        case partial
    }

    /// The report the lens draws from: the whole one, or its cut to ``year``.
    let report: MissingStatements.Report
    /// The one year the lens is narrowed to, for closing a year's books; nil for the whole history.
    let year: Int?
    /// The years with something counted, newest first, each with its count: the year check's
    /// choices. Taken before the cut, so the list does not shrink to the year picked.
    let years: [(year: Int, counted: Int)]
    /// Accounts hidden by the user that a year check therefore leaves out.
    let hiddenCount: Int
    /// The accounts in scope and matching the search, hidden ones included.
    let accounts: [Account]
    let filter: MissingFilter

    /// - Parameters:
    ///   - inScope: whether an account's path, relative to the walked root, is inside Organize's
    ///     scope.
    ///   - query: free text matched against the account's path and the months of its gaps.
    init(report whole: MissingStatements.Report, filter: MissingFilter = .missing, query: String = "",
         year: Int? = nil, inScope: (String) -> Bool = { _ in true }) {
        let report = year.map(whole.restricted(toYear:)) ?? whole
        self.report = report
        self.year = year
        self.filter = filter
        var byYear: [Int: Int] = [:]
        for account in whole.accounts where !account.isHidden && inScope(account.path) {
            for gap in account.gaps { for month in gap.countedMonths { byYear[month.year, default: 0] += gap.perMonth } }
        }
        self.years = byYear.sorted { $0.key > $1.key }.map { (year: $0.key, counted: $0.value) }
        self.hiddenCount = whole.accounts.filter { $0.isHidden && inScope($0.path) }.count
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        self.accounts = report.accounts.filter { account in
            guard inScope(account.path) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = (account.path + " " + account.gaps.map { Self.text($0) }.joined(separator: " ")).lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    // MARK: Counts

    var visible: [Account] { accounts.filter { !$0.isHidden } }
    var counted: Int { visible.reduce(0) { $0 + $1.counted } }
    var countedAccounts: Int { visible.filter { $0.counted > 0 }.count }
    func counted(_ age: Gap.Age) -> Int { visible.reduce(0) { $0 + $1.counted(age) } }

    /// The lens's one-line answer.
    var summary: String {
        if let year {
            // A year check is read at tax time, so it says what it left out.
            let left = hiddenCount == 0 ? "" : " \(Self.count(hiddenCount, "hidden account")) \(hiddenCount == 1 ? "is" : "are") left out."
            guard counted > 0 else { return "Nothing from \(year) is missing." + left }
            return "\(Self.count(counted, "statement")) from \(year) \(counted == 1 ? "is" : "are") missing, in \(Self.count(countedAccounts, "account"))." + left
        }
        guard !accounts.isEmpty else { return "No folder here holds statements named like 3. Mar 2026." }
        guard counted > 0 else { return "Nothing is missing. \(Self.count(visible.count, "account")) checked." }
        return "\(Self.count(counted, "statement")) missing from \(Self.count(countedAccounts, "account")): "
            + "\(counted(.recent)) recent, \(counted(.sinceNewest)) since a last statement, "
            + "\(counted(.older)) older than two years."
    }

    /// Folders the walk could not list, said in a sentence, or nil. Their statements are unknown,
    /// never missing, so the lens names them instead of counting anything in them.
    var notCheckedNote: String? {
        let folders = report.notChecked
        guard let first = folders.first else { return nil }
        let named = folders.count == 1 ? first : "\(first) and \(folders.count - 1) more"
        return "\(Self.count(folders.count, "folder")) could not be listed and \(folders.count == 1 ? "was" : "were") not checked: \(named)."
    }

    /// How many accounts a filter would list, for its chip.
    func count(for filter: MissingFilter) -> Int {
        groups(for: filter).reduce(0) { $0 + $1.accounts.count }
    }

    // MARK: Groups

    var groups: [Group] { groups(for: filter) }

    /// The group an account belongs to under the default filter, by its most serious finding; nil
    /// when it has nothing to say.
    static func section(of account: Account) -> Section? {
        if account.counted(.recent) > 0 { return .recent }
        if account.counted(.sinceNewest) > 0 { return .sinceNewest }
        if account.counted > 0 { return .older }
        if account.gaps.contains(where: isUncountedFinding) { return account.isCard ? .cardSilences : .silences }
        if !account.missingSummaries.isEmpty { return .summaries }
        return nil
    }

    /// A gap that is on the list and off the count: a silence, or a gap beside unnamed files.
    static func isUncountedFinding(_ gap: Gap) -> Bool {
        gap.statements == 0 && gap.notExpected.isEmpty && gap.kind != .expectedNext && gap.kind != .waiting
    }

    private func groups(for filter: MissingFilter) -> [Group] {
        func group(_ section: Section, _ accounts: [Account]) -> Group? {
            accounts.isEmpty ? nil : Group(section: section, accounts: accounts)
        }
        func newestCounted(_ account: Account) -> Int {
            account.gaps.filter(\.isCounted).map(\.last.index).max() ?? 0
        }
        switch filter {
        case .missing:
            let placed = Dictionary(grouping: visible.filter { Self.section(of: $0) != nil }) { Self.section(of: $0)! }
            return Section.allCases.compactMap { section in
                guard var rows = placed[section] else { return nil }
                switch section {
                case .sinceNewest: rows.sort { ($0.counted, $1.path) > ($1.counted, $0.path) }
                case .recent, .older: rows.sort { (newestCounted($0), $1.path) > (newestCounted($1), $0.path) }
                default: rows.sort { $0.path < $1.path }
                }
                return group(section, rows)
            }
        case .expectedNext:
            return [group(.expectedNext, visible.filter { $0.gaps.contains { $0.kind == .expectedNext } })].compactMap { $0 }
        case .notTracked:
            // Newest silence first: the account that most recently went quiet is the one most
            // likely to be a mistake.
            return [group(.notTracked, visible.filter { $0.tracking != .tracked }.sorted { ($0.newest, $1.path) > ($1.newest, $0.path) })]
                .compactMap { $0 }
        case .hidden:
            return [group(.hiddenAccounts, accounts.filter(\.isHidden)),
                    group(.notExpected, visible.filter { $0.gaps.contains { !$0.notExpected.isEmpty } })].compactMap { $0 }
        case .all:
            return [group(.all, visible)].compactMap { $0 }
        }
    }

    // MARK: Words

    /// An account's name on its row: the last two folders that say which account it is.
    /// `Finance/US/Investments/Schwab/Roth IRA 8260/Statements` reads `Schwab · Roth IRA 8260`.
    static func title(_ account: Account) -> String {
        let parts = account.path.split(separator: "/").map(String.init).filter { $0.lowercased() != "statements" }
        return parts.suffix(2).joined(separator: " · ")
    }

    /// The months a gap names: `Sep 2026`, `Aug–Dec 2025`, `Dec 2019 – May 2020`, and
    /// `Aug, Oct, Dec 2025` for an account not billed every month.
    static func months(_ gap: Gap) -> String {
        let months = gap.months
        // A dated document reads as its name would: `Jun 30 2023`.
        if !gap.days.isEmpty, months.count == 1 {
            return "\(months[0].shortName) \(gap.days.map(String.init).joined(separator: ", ")) \(months[0].year)"
        }
        let contiguous = zip(months, months.dropFirst()).allSatisfy { $1.index - $0.index == 1 }
        if gap.kind != .silence, months.count == 1 { return months[0].label }
        if gap.kind != .silence, !contiguous, let first = months.first, let last = months.last {
            return first.year == last.year
                ? months.map(\.shortName).joined(separator: ", ") + " \(first.year)"
                : months.map(\.label).joined(separator: ", ")
        }
        if gap.first == gap.last { return gap.first.label }
        return gap.first.year == gap.last.year
            ? "\(gap.first.shortName)–\(gap.last.label)" : "\(gap.first.label) – \(gap.last.label)"
    }

    /// A gap's months with what marks it out: its series, and that only the CSV is here.
    static func text(_ gap: Gap) -> String {
        months(gap) + (gap.series.isEmpty ? "" : " \(gap.series)") + (gap.kind == .csvOnly ? " (CSV only)" : "")
            + (gap.perMonth == 1 ? "" : gap.perMonth == 2 ? " (both)" : " (all \(gap.perMonth))")
    }

    /// What a gap's line says on its right.
    static func status(_ gap: Gap) -> String {
        switch gap.kind {
        case .waiting: return "in To File"
        case .expectedNext: return "expected next"
        default: break
        }
        if gap.unnamedFiles > 0 { return "name files first" }
        if gap.isCounted {
            return gap.kind == .silence ? count(gap.statements, "month") : "\(gap.statements)"
        }
        if !gap.notExpected.isEmpty { return "not expected" }
        if let estimate = gap.estimate { return "about \(estimate)" }
        return count(gap.months.count, "month")
    }

    /// The row's second line under a section: what is counted, then what else is known.
    static func subtitle(_ account: Account, in section: Section) -> String {
        switch section {
        case .expectedNext: return "Newest statement \(account.newest.label)"
        case .notTracked:
            let why = account.tracking == .stopped ? "Stopped by you" : "Quiet"
            return "\(why) since \(account.newest.label) · \(count(account.statements, "statement"))"
        case .hiddenAccounts: return "Hidden by you"
        case .notExpected:
            return account.gaps.filter { !$0.notExpected.isEmpty }.map(text).joined(separator: ", ")
        default: break
        }
        var bits: [String] = []
        let countedGaps = account.gaps.filter(\.isCounted)
        if !countedGaps.isEmpty { bits.append(countedGaps.map(text).joined(separator: ", ")) }
        let waiting = account.gaps.filter { $0.kind == .waiting }
        if !waiting.isEmpty { bits.append(waiting.map(text).joined(separator: ", ") + " in To File") }
        let silences = account.gaps.filter { isUncountedFinding($0) && $0.unnamedFiles == 0 }
        if !silences.isEmpty {
            bits.append(countedGaps.isEmpty ? silences.map(text).joined(separator: ", ")
                                            : "\(count(silences.count, "silence")) not counted")
        }
        let doubted = account.gaps.filter { $0.unnamedFiles > 0 }
        if !doubted.isEmpty { bits.append("\(doubted.count) to name first") }
        if !account.missingSummaries.isEmpty {
            bits.append("0. Summary " + account.missingSummaries.map(String.init).joined(separator: ", "))
        }
        if bits.isEmpty { bits.append(account.tracking == .tracked ? "Nothing missing" : "Not tracked") }
        return bits.joined(separator: " · ")
    }

    /// The row as one sentence, for VoiceOver.
    static func spoken(_ account: Account) -> String {
        var parts = [title(account)]
        if account.counted > 0 {
            parts.append("\(account.counted) missing: " + account.gaps.filter(\.isCounted).map(text).joined(separator: ", "))
        } else {
            parts.append("nothing counted")
        }
        for gap in account.gaps where gap.kind == .waiting { parts.append("\(text(gap)) is waiting in To File") }
        return parts.joined(separator: ". ") + "."
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    // MARK: The strip

    /// The three calendar years the strip draws, ending with the report's year.
    var stripYears: [Int] { [report.asOf.year - 2, report.asOf.year - 1, report.asOf.year] }

    /// One cell per month of ``stripYears``, in order.
    func cells(for account: Account) -> [Cell] {
        var marks: [Int: Cell] = [:]
        for gap in account.gaps {
            let cell: Cell
            switch gap.kind {
            case .waiting: cell = .waiting
            case .expectedNext: cell = .expectedNext
            default: cell = gap.isCounted ? .missing : .uncounted
            }
            // A silence spans every month between its ends; the others only the months due.
            let months = gap.kind == .silence ? Array(gap.first.index...gap.last.index) : gap.months.map(\.index)
            let off = Set(gap.notExpected.map(\.index))
            for month in months where marks[month] == nil || cell == .waiting {
                marks[month] = off.contains(month) ? .uncounted : cell
            }
        }
        let filed = Set(account.filed.map(\.index))
        let partly = Set(account.partlyFiled.map(\.index))
        let summaryOnly = Set(account.summaryOnlyYears)
        return stripYears.flatMap { year in
            (0..<12).map { m -> Cell in
                let month = year * 12 + m
                if filed.contains(month) || summaryOnly.contains(year) { return .filed }
                // Before the gap's own mark: the month is half here whether or not it is counted.
                if partly.contains(month), month < report.asOf.index - 1 { return .partial }
                if let mark = marks[month] { return mark }
                if month < account.first.index || month >= report.asOf.index { return .blank }
                return .noneExpected
            }
        }
    }

    /// The years before the strip in which this account has a finding, as the row's tag:
    /// `2015`, or `2017–21`.
    func earlierTag(for account: Account) -> String? {
        guard let floor = stripYears.first else { return nil }
        let years = Set(account.gaps.filter { $0.kind != .expectedNext && $0.kind != .waiting }.flatMap { gap in
            gap.first.year < floor ? Array(gap.first.year...min(gap.last.year, floor - 1)) : []
        }).sorted()
        guard let first = years.first, let last = years.last else { return nil }
        return first == last ? "\(first)" : "\(first)–\(String(last).suffix(2))"
    }

    /// Months filed in each year the account spans, newest last, for the detail's bars.
    func filedByYear(_ account: Account) -> [(year: Int, filed: Int, missing: Int, summaryOnly: Bool)] {
        let filed = Dictionary(grouping: account.filed, by: \.year).mapValues(\.count)
        var missing: [Int: Int] = [:]
        for gap in account.gaps where gap.isCounted && gap.kind != .silence {
            for month in gap.months where !gap.notExpected.contains(month) { missing[month.year, default: 0] += 1 }
        }
        return (account.first.year...max(account.first.year, report.asOf.year)).map {
            (year: $0, filed: filed[$0] ?? 0, missing: missing[$0] ?? 0, summaryOnly: account.summaryOnlyYears.contains($0))
        }
    }

    // MARK: To File

    /// What a file bound for `home` (an absolute folder) under `name` would close, as the To File
    /// card's sentence: `Utilities · Power lacks Sep 2026.` nil when it fills nothing, or when the
    /// folder is outside the tree Missing walked.
    static func gapSentence(report: MissingStatements.Report, root: String, home: String, name: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard home.hasPrefix(prefix) else { return nil }
        guard let fill = report.gapFilled(byFileNamed: name, in: String(home.dropFirst(prefix.count))),
              let first = fill.months.first, let last = fill.months.last else { return nil }
        let months = first == last ? first.label
            : (first.year == last.year ? "\(first.shortName)–\(last.label)" : "\(first.label) – \(last.label)")
        return "\(title(fill.account)) lacks \(months)."
    }

    // MARK: Copy List

    /// One account's line: what is counted, then what is waiting, then what is listed and not
    /// counted.
    static func line(_ account: Account) -> String {
        var counted: [String] = [], other: [String] = []
        for gap in account.gaps {
            switch gap.kind {
            case .expectedNext: continue
            case .waiting: counted.append("\(text(gap)) (in To File)")
            default:
                if gap.isCounted { counted.append("\(text(gap)) (\(gap.statements))") }
                else if gap.unnamedFiles > 0 { other.append("\(text(gap)) (name files first)") }
                else if !gap.notExpected.isEmpty { continue }
                else { other.append(text(gap) + (gap.estimate.map { " (about \($0))" } ?? "")) }
            }
        }
        other += account.missingSummaries.map { "0. Summary \($0)" }
        if !other.isEmpty { counted.append("not counted: " + other.joined(separator: ", ")) }
        return "\(account.path): " + counted.joined(separator: "; ")
    }

    /// The whole list as plain text, in the order the default filter shows it. Hidden accounts and
    /// gaps marked Not Expected are left out.
    func copyText(rootName: String) -> String {
        var lines = ["Missing statements, \(rootName), \(report.asOf.label)" + (year.map { ", for \($0) only" } ?? ""), summary]
        for group in groups(for: .missing) {
            lines.append("")
            lines.append(group.section.title + ":")
            lines += group.accounts.map { "  " + Self.line($0) }
        }
        return lines.joined(separator: "\n")
    }
}
