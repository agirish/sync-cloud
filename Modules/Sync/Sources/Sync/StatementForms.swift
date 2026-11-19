import Foundation

/// Two kinds of account paper that file by rules of their own, not as the month's statement.
///
/// - A **year-end summary** (`2016 Year-End Summary`, `2025 YEAR-END INVESTMENT REPORT`, or a
///   statement whose period is the whole year) is `0. Summary YYYY` in that year's folder: the `0.`
///   keeps it out of the statements' count (``StatementOrdinals``).
/// - A **trade confirmation** goes in the account's `Trade Confirms/<year>` folder, named for its
///   trade date: `19 Aug 2021.pdf`. Only where the account keeps a `Trade Confirms` folder.
enum StatementForms {

    enum Form: Equatable {
        case yearEndSummary(year: Int)
        case tradeConfirm(date: DocumentFacts.Period)
    }

    private static let compiled = RegexCache()
    private static let summaryRE = #"\b(\d{4})\s*year[\s-]*end\s+(?:summary|investment report|statement|account summary)"#
    private static let summaryWordsRE = #"\byear[\s-]*end\s+(?:summary|investment report)|\bannual (?:account )?summary\b"#
    private static let confirmRE = #"\b(?:trade|transaction) confirmation\b|\bconfirmation of (?:your )?(?:purchase|sale|trade)"#

    /// What page 1 says this paper is, when it is one of the two.
    static func form(of f: DocumentFacts) -> Form? {
        let header = f.header
        let ns = header as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = compiled.regex(summaryRE).firstMatch(in: header, range: all),
           let y = Int(ns.substring(with: m.range(at: 1))), (1990...2100).contains(y) {
            return .yearEndSummary(year: y)
        }
        if compiled.regex(summaryWordsRE).firstMatch(in: header, range: all) != nil, let p = f.period {
            // Printed in January for the year before, or dated its last day.
            return .yearEndSummary(year: p.month <= 2 ? p.year - 1 : p.year)
        }
        // A statement whose period is the whole year (`01/01/2020 to 12/31/2020`).
        if let s = f.periodStart, let e = f.period, s.year == e.year, s.month == 1, (s.day ?? 1) <= 2,
           e.month == 12, (e.day ?? 31) >= 30 {
            return .yearEndSummary(year: e.year)
        }
        if compiled.regex(confirmRE).firstMatch(in: header, range: all) != nil, let d = tradeDate(in: f.text) {
            return .tradeConfirm(date: d)
        }
        return nil
    }

    /// The trade date: the first date within a short way after a `trade date` label (a column
    /// heading, whose value sits under it), else the first full date on the page.
    static func tradeDate(in lower: String) -> DocumentFacts.Period? {
        let ns = lower as NSString
        let date = DocumentFacts.dateRE
        if let m = compiled.regex(#"trade date[\s\S]{0,160}?("# + date + ")").firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
           let p = DocumentFacts.parseDate(ns.substring(with: m.range(at: 1))), p.day != nil {
            return p
        }
        guard let m = compiled.regex(date).firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              let p = DocumentFacts.parseDate(ns.substring(with: m.range)), p.day != nil else { return nil }
        return p
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `0. Summary 2025.pdf`
    static func summaryName(year: Int, ext: String) -> String {
        "0. Summary \(year)" + (ext.isEmpty ? "" : "." + ext)
    }

    /// `04 May 2023.pdf`
    static func confirmName(_ d: DocumentFacts.Period, ext: String) -> String {
        String(format: "%02d", d.day ?? 1) + " \(monthNames[d.month - 1]) \(d.year)" + (ext.isEmpty ? "" : "." + ext)
    }

    /// The account's `Trade Confirms` folder, by name, any case.
    static func confirmsFolder(in account: FileNode) -> FileNode? {
        (account.children ?? []).first { $0.isDirectory && $0.name.compare("Trade Confirms", options: .caseInsensitive) == .orderedSame }
    }

    /// Where a confirm dated `d` goes inside `account`, and what is new on the way.
    static func confirmPlacement(_ d: DocumentFacts.Period, in account: FileNode, fileName: String) -> AccountPlacement.Placement? {
        guard let folder = confirmsFolder(in: account) else { return nil }
        let year = String(d.year)
        let hasYear = (folder.children ?? []).contains { $0.isDirectory && $0.name == year }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return AccountPlacement.Placement(folder: folder.name + "/" + year, newSegments: hasYear ? [] : [year],
                                          name: confirmName(d, ext: ext))
    }
}
