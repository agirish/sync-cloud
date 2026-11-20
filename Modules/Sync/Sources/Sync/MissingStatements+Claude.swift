import Foundation

/// What Ask Claude is told of the Missing lens's report: counts it may always have, and the
/// accounts themselves, whose names are the user's folder names and so may have to wait for them.
public extension MissingStatements {

    struct ClaudeAnswer: Sendable, Equatable {
        /// Counts and what they mean. No folder name is in it.
        public let counts: String
        /// One line an account: its path under the walked root, what is counted, what is listed
        /// and not counted. Empty when nothing is missing.
        public let rows: String
        /// The accounts in ``rows``, as absolute paths, so a held answer can be checked again
        /// when it is shared.
        public let paths: [String]
        /// How many accounts have something to say, including any ``rows`` left out for length.
        public let accounts: Int
    }

    /// The most accounts one answer lists. More than this is a list nobody reads in a chat.
    static let claudeAccountLimit = 60

    /// The report as Claude gets it. Accounts in folders hidden from Claude, and accounts hidden
    /// in the lens, are dropped before anything is counted, so no total says they exist.
    ///
    /// - Parameters:
    ///   - root: the absolute folder the report was walked from.
    ///   - year: only what one year lacks, or nil for the whole history.
    ///   - isHidden: whether an absolute path is hidden from Claude.
    static func forClaude(_ whole: Report, root: String, year: Int? = nil, isHidden: (String) -> Bool) -> ClaudeAnswer {
        func absolute(_ path: String) -> String { (root as NSString).appendingPathComponent(path) }
        let report = year.map(whole.restricted(toYear:)) ?? whole
        let accounts = report.visible.filter { !isHidden(absolute($0.path)) }
        let counted = accounts.reduce(0) { $0 + $1.counted }
        let countedAccounts = accounts.filter { $0.counted > 0 }.count
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

        // An account with a counted gap first, the newest gap first; then the ones only listed.
        func uncounted(_ account: Account) -> Bool {
            account.gaps.contains { $0.statements == 0 && $0.kind != .expectedNext && $0.kind != .waiting && $0.notExpected.isEmpty }
                || !account.missingSummaries.isEmpty
        }
        func newest(_ account: Account) -> Int { account.gaps.filter(\.isCounted).map(\.last.index).max() ?? 0 }
        let telling = accounts.filter { $0.counted > 0 || uncounted($0) || $0.gaps.contains { $0.kind == .waiting } }
            .sorted { ($0.counted > 0 ? 1 : 0, newest($0), $1.path) > ($1.counted > 0 ? 1 : 0, newest($1), $0.path) }

        var counts: [String] = []
        if let year {
            counts.append(counted == 0 ? "Nothing from \(year) is counted as missing."
                : "\(plural(counted, "statement")) from \(year) \(counted == 1 ? "is" : "are") missing, in \(plural(countedAccounts, "account")).")
        } else if accounts.isEmpty {
            counts.append("No folder holds statements named like 3. Mar 2026, so there is nothing to check.")
        } else if counted == 0 {
            counts.append("Nothing is counted as missing in \(plural(accounts.count, "account")).")
        } else {
            let split = [Gap.Age.recent, .sinceNewest, .older].map { age in accounts.reduce(0) { $0 + $1.counted(age) } }
            counts.append("\(plural(counted, "statement")) \(counted == 1 ? "is" : "are") missing from \(plural(countedAccounts, "account")): "
                + "\(split[0]) from the last two years, \(split[1]) in months since the last statement of an account "
                + "with no steady rhythm (often unused months, not lost statements), \(split[2]) older.")
        }
        let listedOnly = telling.filter { $0.counted == 0 }.count
        if listedOnly > 0 {
            counts.append("\(plural(listedOnly, "more account")) \(listedOnly == 1 ? "has" : "have") a silence or a gap beside unnamed files: listed, not counted.")
        }
        counts.append("Read from file names on their Mac, as of \(report.asOf.label); no file was opened. "
            + "The newest finished month is never counted. Accounts they hid in Organize ▸ Missing, and folders hidden from you, are left out.")

        let shown = telling.prefix(claudeAccountLimit)
        var rows = shown.map(line)
        if telling.count > shown.count { rows.append("\(plural(telling.count - shown.count, "more account")) not listed here.") }
        return ClaudeAnswer(counts: counts.joined(separator: " "), rows: rows.joined(separator: "\n"),
                            paths: shown.map { absolute($0.path) }, accounts: telling.count)
    }

    /// One account as a line of data: `Home/Utilities/Power: Mar 2025 (1); not counted: Jan–Dec 2024`.
    private static func line(_ account: Account) -> String {
        func months(_ gap: Gap) -> String {
            let list = gap.months
            if !gap.days.isEmpty, list.count == 1 {
                return "\(list[0].shortName) \(gap.days.map(String.init).joined(separator: ", ")) \(list[0].year)"
            }
            let contiguous = zip(list, list.dropFirst()).allSatisfy { $1.index - $0.index == 1 }
            var text: String
            if gap.kind != .silence, list.count == 1 {
                text = list[0].label
            } else if gap.kind != .silence, !contiguous, let first = list.first, let last = list.last {
                text = first.year == last.year ? list.map(\.shortName).joined(separator: ", ") + " \(first.year)"
                    : list.map(\.label).joined(separator: ", ")
            } else if gap.first == gap.last {
                text = gap.first.label
            } else {
                text = gap.first.year == gap.last.year ? "\(gap.first.shortName)–\(gap.last.label)" : "\(gap.first.label) – \(gap.last.label)"
            }
            if !gap.series.isEmpty { text += " \(gap.series)" }
            if gap.kind == .csvOnly { text += " (only the CSV is there)" }
            if gap.perMonth > 1 { text += gap.perMonth == 2 ? " (both)" : " (all \(gap.perMonth))" }
            return text
        }
        var counted: [String] = [], other: [String] = []
        for gap in account.gaps {
            switch gap.kind {
            case .expectedNext: continue
            case .waiting: counted.append("\(months(gap)) (waiting in their inbox folder)")
            default:
                if gap.isCounted { counted.append("\(months(gap)) (\(gap.statements))") }
                else if gap.unnamedFiles > 0 { other.append("\(months(gap)) (unnamed files beside it)") }
                else if !gap.notExpected.isEmpty { continue }
                else { other.append(months(gap) + (gap.estimate.map { " (about \($0))" } ?? "")) }
            }
        }
        other += account.missingSummaries.map { "year summary \($0)" }
        if !other.isEmpty { counted.append("not counted: " + other.joined(separator: ", ")) }
        return "\(account.path): " + counted.joined(separator: "; ")
    }
}
