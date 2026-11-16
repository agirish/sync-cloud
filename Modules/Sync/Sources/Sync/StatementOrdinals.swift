import Foundation

/// His statement numbering, as he restated it on 2026-11-15, for the folders he applies it to.
///
/// In a statement folder the ordinal of `N. Mon YYYY.pdf` (or `N. Jan-Mar YYYY.pdf`) is the file's
/// **position by statement date**, not its month number: Amex with January, June and October runs
/// `1. Jan 2025`, `2. Jun 2025`, `3. Oct 2025`. Fewer than 12 statements are numbered `1.` … `11.`;
/// 12 or more `01.` … `12.`, so the eleventh-to-twelfth arrival rewrites every name. A range sorts by
/// its end month. A CSV with the same name as its PDF shares the PDF's number. `0. Summary YYYY` and
/// `0. Spend YYYY` stand outside the count.
///
/// Two statements dated alike are two positions, in the order their numbers already give them
/// (`1. Jul 2016.pdf`, `2. Jul 2016.pdf`; `11. Nov 2014 -1.pdf`, `12. Nov 2014 -2.pdf`). A new one
/// goes after them.
///
/// Pure and total, like ``OrdinalMonthName``: names in, names out.
public enum StatementOrdinals {

    /// The folders, relative to the tree's root, whose statements follow this rule: the ones he
    /// renamed to it. Every other numbered folder keeps its own convention (his call, 2026-11-15),
    /// and ``RenamePlanner`` numbers it as before.
    public static let ruledRoots = ["Finance/US", "Vehicles/Tesla/Lease Statements"]

    /// Whether `relativePath` (from the tree's root) is at or below one of ``ruledRoots``. Compared
    /// component by component, ignoring case as his volume does: `Finance/USA` is not `Finance/US`.
    public static func governs(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map { $0.lowercased() }
        return ruledRoots.contains { root in
            let r = root.split(separator: "/").map { $0.lowercased() }
            return parts.count >= r.count && Array(parts.prefix(r.count)) == r
        }
    }

    // MARK: Reading a statement's date

    /// The date a statement's body starts with: the end of its period, with the day when it names
    /// one. nil when the body doesn't start with a month (`Transunion - Aug 2019`,
    /// `Donors Choose Donation Receipt - 2025`), which is not a statement name.
    ///
    /// | Body | Date |
    /// |---|---|
    /// | `Oct 2026`, `October 2026`, `Oct  2026` | Oct 2026 |
    /// | `Nov 2014 -2`, `Nov 2018 (RC)` | Nov 2014, Nov 2018: what follows the date is the file's own |
    /// | `Jan-Mar 2021`, `May - Jun 2020`, `July-Aug 2021` | Mar 2021, Jun 2020, Aug 2021 |
    /// | `Apr 2009 - Mar 2010`, `Apr 2007 to Aug 2007` | Mar 2010, Aug 2007 |
    /// | `Feb 28 2019` | Feb 28 2019 |
    public struct Dated: Sendable, Equatable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int?

        public static func < (a: Dated, b: Dated) -> Bool {
            (a.year, a.month, a.day ?? 0) < (b.year, b.month, b.day ?? 0)
        }
    }

    public static func date(ofBody body: String) -> Dated? {
        let tokens = body.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        func month(_ i: Int) -> Int? {
            i < tokens.count ? OrdinalMonthName.monthIndex(tokens[i].lowercased()) : nil
        }
        func year(_ i: Int) -> Int? {
            guard i < tokens.count, tokens[i].count == 4, let y = Int(tokens[i]), (1900...2199).contains(y)
            else { return nil }
            return y
        }
        guard let first = month(0) else { return nil }
        // `Jan-Mar 2021`: two months, then the year.
        if let end = month(1), let y = year(2) { return Dated(year: y, month: end, day: nil) }
        // `Feb 28 2019`: a day between the month and the year.
        if tokens.count > 2, tokens[1].count <= 2, let d = Int(tokens[1]), (1...31).contains(d), let y = year(2) {
            return Dated(year: y, month: first, day: d)
        }
        guard let y = year(1) else { return nil }
        // `Apr 2009 - Mar 2010` or `Apr 2007 to Aug 2007`: the period's end.
        let next = tokens.count > 2 && tokens[2].lowercased() == "to" ? 3 : 2
        if let end = month(next), let y2 = year(next + 1) { return Dated(year: y2, month: end, day: nil) }
        return Dated(year: y, month: first, day: nil)
    }

    // MARK: Numbering a folder

    /// One file the folder holds, or is about to.
    public struct Entry: Sendable, Equatable {
        /// What identifies it to the caller: its path, for a file on disk.
        public let id: String
        /// The name to number. For a file arriving, the name it would take with any ordinal
        /// (`10. Oct 2026.PDF`); only the ordinal is decided here.
        public let name: String
        /// Arriving rather than already here: it goes after the statements already dated alike.
        public let arriving: Bool

        public init(id: String, name: String, arriving: Bool = false) {
            self.id = id
            self.name = name
            self.arriving = arriving
        }
    }

    /// What the rule says each file is called. `names` holds every statement, renamed or not, by
    /// ``Entry/id``; files that aren't statements (`0. Summary 2025.pdf`, a raw bank name) are
    /// absent and keep theirs.
    public struct Numbering: Sendable, Equatable {
        public let names: [String: String]
        /// How many statements the folder counts, so whether it is padded.
        public let count: Int
    }

    /// The folder numbered by the rule, or nil when the folder doesn't number by it: some numbered
    /// file in it (not the `0.` slot) isn't a statement name, so its numbers mean something else
    /// (`Credit Reports/2019/Archive` numbers `01. Equifax - Aug 2019.pdf` by bureau).
    public static func number(_ entries: [Entry]) -> Numbering? {
        struct Member { let entry: Entry; let parsed: OrdinalMonthName.Parsed }
        var byBody: [String: [Member]] = [:]
        var dates: [String: Dated] = [:]
        for e in entries {
            guard let p = OrdinalMonthName.parse(e.name), !p.isSummarySlot else { continue }
            guard let d = date(ofBody: p.body) else { return nil }
            let key = twinKey(p)
            byBody[key, default: []].append(Member(entry: e, parsed: p))
            dates[key] = d
        }
        // One statement per position: a PDF and the CSV of the same name share one, and two PDFs
        // of the same name (two July statements) are two, paired with their CSVs in number order.
        struct Statement { let date: Dated; let arriving: Bool; let ordinal: Int; let key: String; let members: [Member] }
        var statements: [Statement] = []
        for (key, members) in byBody {
            var byExt: [String: [Member]] = [:]
            for m in members { byExt[m.parsed.ext.lowercased(), default: []].append(m) }
            for k in byExt.keys {
                byExt[k]!.sort { ($0.entry.arriving ? 1 : 0, $0.parsed.ordinal) < ($1.entry.arriving ? 1 : 0, $1.parsed.ordinal) }
            }
            let depth = byExt.values.map(\.count).max() ?? 0
            for j in 0..<depth {
                let group = byExt.keys.sorted().compactMap { j < byExt[$0]!.count ? byExt[$0]![j] : nil }
                // Arriving only when nothing in it is already here: a CSV filed after its PDF
                // takes the PDF's place, not one after it.
                let here = group.filter { !$0.entry.arriving }
                statements.append(Statement(date: dates[key]!, arriving: here.isEmpty,
                                            ordinal: (here.isEmpty ? group : here).map(\.parsed.ordinal).min() ?? 0,
                                            key: key, members: group))
            }
        }
        statements.sort {
            ($0.date.year, $0.date.month, $0.date.day ?? 0, $0.arriving ? 1 : 0, $0.ordinal, $0.key)
                < ($1.date.year, $1.date.month, $1.date.day ?? 0, $1.arriving ? 1 : 0, $1.ordinal, $1.key)
        }
        let padded = statements.count >= 12
        var names: [String: String] = [:]
        for (i, s) in statements.enumerated() {
            for m in s.members { names[m.entry.id] = m.parsed.canonicalName(ordinal: i + 1, padded: padded) }
        }
        return Numbering(names: names, count: statements.count)
    }

    /// What makes two files one statement: the same name but for the number and the extension,
    /// compared as the renderer would write it (`July 2019` is `Jul 2019`) and ignoring case.
    static func twinKey(_ p: OrdinalMonthName.Parsed) -> String {
        guard let month = p.month, let year = p.year, p.bodyIsBareDate else { return p.body.lowercased() }
        return OrdinalMonthName.body(month: month, year: year).lowercased()
    }
}
