import Foundation

/// Where inside an account folder a statement goes, copied from the account's own newest
/// statements (design §4), and what it is called there: his `NN. Mon YYYY` name (decision OR).
/// `Traditional IRA 7863` keeps 2025's statements loose in the account folder, so October 2026's
/// goes there as `10. Oct 2026.PDF`; `Trust Brokerage 2 - 3494` files by `Statements/<year>`, so it
/// goes to a new `Statements/2026`.
public enum AccountPlacement {

    public struct Placement: Sendable, Equatable {
        /// Relative to the account root: "" for the root itself.
        public let folder: String
        /// Trailing segments of `folder` that don't exist yet.
        public let newSegments: [String]
        /// His `NN. Mon YYYY` name for it, or nil to keep the incoming name (no period known).
        public let name: String?
        /// The statement's year wasn't known, so a year folder couldn't be chosen: the account is
        /// sure, the folder inside it isn't.
        public var yearUnknown: Bool = false
    }

    /// `node` is the account root as walked. `period` is the statement's, or nil when page 1 named
    /// none. `taxForm` sends a tax form to the account's own tax folder when it has one. `bank` is
    /// the bank's folder, whose other statement folders say whether an empty one files by year.
    public static func place(in node: FileNode, period: DocumentFacts.Period?, taxForm: Bool,
                             fileName: String, bank: FileNode? = nil,
                             periodStart: DocumentFacts.Period? = nil) -> Placement {
        let ext = (fileName as NSString).pathExtension
        if taxForm {
            // A child whose name says tax (`Tax`, `Tax Forms`), else the root: the root counts as
            // the tax home of an account that keeps its 1099s beside its statements.
            let tax = (node.children ?? []).first { $0.isDirectory && AccountIndex.words($0.name).contains { $0.hasPrefix("tax") } }
            guard let tax else { return Placement(folder: "", newSegments: [], name: nil) }
            let years = (tax.children ?? []).filter { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name) }
            if !years.isEmpty, let year = period?.year {
                return resolve(tax.name + "/" + String(year), in: node, name: nil)
            }
            return Placement(folder: tax.name, newSegments: [], name: nil)
        }
        // Statements filed in a tax folder (`Roth IRA 4657/Tax` holds 2022's) were his misfiles,
        // never the account's layout.
        let families = StatementFamily.families(below: node)
            .mapValues { $0.filter { !isTaxFolder($0.folder) } }
            .filter { StatementFamily.isRegular($0.value) }
        // The account's own `Statements` folder, still empty: his word for where they go now.
        if let statements = emptyStatementsFolder(in: node) {
            let byYear = bank.map(filesStatementsByYear) ?? false
            let members = families.values.flatMap { $0 }
            let name = period.map { houseName($0, members: members, ext: ext) }
            guard byYear else { return resolve(statements.name, in: node, name: name) }
            guard let period else {
                return Placement(folder: statements.name, newSegments: [], name: nil, yearUnknown: true)
            }
            return resolve(statements.name + "/" + String(period.year), in: node, name: name)
        }
        // The statement family: among families of the incoming file's type (PDFs for a PDF, never a
        // CSV export), the one whose newest member is newest.
        func newestPeriod(_ m: [StatementFamily.Member]) -> DocumentFacts.Period { m.map(\.period).max() ?? .init(year: 0, month: 0) }
        let sameType = families.filter { $0.value.contains { ($0.name as NSString).pathExtension.lowercased() == ext.lowercased() } }
        let pool = sameType.isEmpty ? families : sameType
        guard let (_, members) = pool.max(by: { newestPeriod($0.value) < newestPeriod($1.value) })
        else { return Placement(folder: "", newSegments: [], name: nil) }
        let newest = members.max { $0.period < $1.period }!
        // Its folder, with a year segment standing for the statement's own year and a month folder
        // for its month. With no period known, the account is still right but no year folder can
        // be chosen: it stops above the first year level.
        var segments: [String] = []
        for seg in newest.folder.split(separator: "/").map(String.init) {
            // A financial year (`2017-2018`, Apr–Mar in India): the span the statement falls in,
            // starting in the month the account's own files start their spans with.
            if let span = fiscalSpan(seg) {
                guard let period else {
                    return Placement(folder: segments.joined(separator: "/"),
                                     newSegments: resolve(segments.joined(separator: "/"), in: node, name: nil).newSegments,
                                     name: nil, yearUnknown: true)
                }
                let start = fiscalStartMonth(members)
                let first = period.month >= start ? period.year : period.year - 1
                segments.append(span.name(first))
                continue
            }
            // A year inside a longer name (`Statements 2025`, `Tax Year 2025`) moves with it too.
            if seg.count > 4, FilingPeriod.monthSlot(ofFolderNamed: seg) == nil,
               let r = seg.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) {
                // No period known: the account is right, but not which year's folder.
                guard let period else {
                    return Placement(folder: segments.joined(separator: "/"),
                                     newSegments: resolve(segments.joined(separator: "/"), in: node, name: nil).newSegments,
                                     name: nil, yearUnknown: true)
                }
                segments.append(seg.replacingCharacters(in: r, with: String(period.year)))
                continue
            }
            let isYear = seg.count == 4 && FolderProfileEntry.looksLikeYear(seg)
            let isMonth = FilingPeriod.monthSlot(ofFolderNamed: seg) != nil
            guard isYear || isMonth else { segments.append(seg); continue }
            guard let period else {
                return Placement(folder: segments.joined(separator: "/"), newSegments: resolve(segments.joined(separator: "/"), in: node, name: nil).newSegments,
                                 name: nil, yearUnknown: true)
            }
            if isYear { segments.append(String(period.year)); continue }
            // `10. Oct 2025` → `10. Oct 2026`; a month folder whose name can't be re-dated ends the path.
            guard let parsed = parse(seg + ".x"),
                  let renamed = Template(prefix: parsed.prefix, form: parsed.form, suffix: parsed.suffix,
                                         originalExtension: "",
                                         padOrdinal: parsed.ordinalDigits >= 2).fill(period, ext: "") else {
                // A month folder whose name can't be re-dated (`July`): the folder inside the
                // account isn't sure, so neither is the card.
                let here = segments.joined(separator: "/")
                return Placement(folder: here, newSegments: resolve(here, in: node, name: nil).newSegments,
                                 name: nil, yearUnknown: true)
            }
            segments.append(renamed)
        }
        let folder = segments.joined(separator: "/")
        let sameTypeMembers = members.filter { ($0.name as NSString).pathExtension.lowercased() == ext.lowercased() }
        let name = period.map { houseName($0, start: periodStart, members: sameTypeMembers.isEmpty ? members : sameTypeMembers, ext: ext) }
        return resolve(folder, in: node, name: name)
    }

    /// His name for a statement, whatever the bank or the account's older files call it
    /// (decision OR, 2026-11-14): `01. Jan 2026.pdf`. One digit for a quarterly or sparser account
    /// (`1. Mar 2026.pdf`) unless its own names use two. The extension as the account's files
    /// spell it (`.PDF`).
    ///
    /// In a folder ``StatementOrdinals`` governs (his `Finance/US`), the number here is only a
    /// placeholder: the naming pass renumbers it as the statement's position by date there
    /// (``FileSyncManager/named(_:fileName:rootPath:folderFiles:profile:)``), and File Here renames
    /// the statements it displaces.
    ///
    /// A statement covering two months or more is named for them (`03. Jan-Mar 2026`): a start on
    /// or after the 20th counts from the next month, an end on or before the 5th as the month
    /// before, and a cycle under 45 days stays one month, the end's. A range across a new year
    /// keeps the end's month alone.
    static func houseName(_ p: DocumentFacts.Period, start: DocumentFacts.Period? = nil,
                          members: [StatementFamily.Member], ext: String) -> String {
        let monthly = OrdinalMonthName.isQuarterlyOrSparser(Set(members.map { $0.period.year * 12 + $0.period.month })) != true
        let widths = members.compactMap { parse($0.name) }.filter { $0.form == .ordinalMonthYear }.map(\.ordinalDigits)
        let pad = monthly || widths.filter { $0 >= 2 }.count * 2 > widths.count
        let own = members.max { $0.period < $1.period }.map { ($0.name as NSString).pathExtension } ?? ""
        let e = own.lowercased() == ext.lowercased() ? own : ext
        let months = coveredMonths(start: start, end: p)
        let label = months.map { Template.monthNames[$0.first - 1] + "-" + Template.monthNames[$0.last - 1] }
            ?? Template.monthNames[p.month - 1]
        return (pad ? String(format: "%02d", p.month) : String(p.month)) + ". "
            + label + " \(p.year)" + (e.isEmpty ? "" : "." + e)
    }

    /// The first and last month a statement covers, when it covers two or more of one year; nil
    /// for a single month (see ``houseName(_:start:members:ext:)``).
    static func coveredMonths(start: DocumentFacts.Period?, end: DocumentFacts.Period) -> (first: Int, last: Int)? {
        guard let start, start < end else { return nil }
        func dayNumber(_ p: DocumentFacts.Period, _ fallback: Int) -> Int {
            var c = DateComponents(); c.year = p.year; c.month = p.month; c.day = p.day ?? fallback
            return Calendar(identifier: .gregorian).date(from: c).map { Int($0.timeIntervalSince1970 / 86_400) } ?? 0
        }
        guard dayNumber(end, 28) - dayNumber(start, 1) >= 45 else { return nil }
        var first = start.year * 12 + start.month - 1
        var last = end.year * 12 + end.month - 1
        if (start.day ?? 1) >= 20 { first += 1 }
        if let d = end.day, d <= 5 { last -= 1 }
        guard last > first, first / 12 == last / 12, last / 12 == end.year else { return nil }
        return (first % 12 + 1, last % 12 + 1)
    }

    /// A folder named for a span of two consecutive years (`2017-2018`, `2017-18`): a financial
    /// year. `name` spells another span the same way.
    struct FiscalSpan { let name: (Int) -> String }
    static func fiscalSpan(_ seg: String) -> FiscalSpan? {
        guard let m = seg.range(of: #"^(19|20)\d\d\s*[-–]\s*(\d{2}|\d{4})$"#, options: .regularExpression) else { return nil }
        let s = String(seg[m])
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "–" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let y1 = Int(parts[0]), let y2 = Int(parts[1]) else { return nil }
        let short = parts[1].count == 2
        guard (short ? y2 == (y1 + 1) % 100 : y2 == y1 + 1) else { return nil }
        let sep = s.contains("–") ? "–" : "-"
        let spaced = s.contains(" ")
        return FiscalSpan { first in
            let second = short ? String(format: "%02d", (first + 1) % 100) : String(first + 1)
            return "\(first)" + (spaced ? " \(sep) " : sep) + second
        }
    }

    /// The month an account's financial years start: the earliest month its files in a span
    /// folder carry in that span's first year. April, India's, when none says.
    static func fiscalStartMonth(_ members: [StatementFamily.Member]) -> Int {
        var months: [Int] = []
        for m in members {
            for seg in m.folder.split(separator: "/").map(String.init) where fiscalSpan(seg) != nil {
                if let y1 = Int(seg.prefix(4)), m.period.year == y1 { months.append(m.period.month) }
            }
        }
        return months.min() ?? 4
    }

    /// A folder path, relative to the account, running through a tax folder (`Tax`, `Tax Forms`).
    static func isTaxFolder(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { seg in AccountIndex.words(String(seg)).contains { $0.hasPrefix("tax") } }
    }

    /// The account's own `Statements` folder when it holds no file yet.
    static func emptyStatementsFolder(in node: FileNode) -> FileNode? {
        func holdsFiles(_ n: FileNode) -> Bool {
            (n.children ?? []).contains { $0.isDirectory ? holdsFiles($0) : !$0.name.hasPrefix(".") }
        }
        return (node.children ?? []).first { c in
            c.isDirectory && AccountIndex.words(c.name).contains { $0 == "statements" || $0 == "statement" } && !holdsFiles(c)
        }
    }

    /// The bank keeps statements by year somewhere outside an archive: a `Statements` folder of its
    /// own (`Fidelity/Statements/2026`) or an account's.
    static func filesStatementsByYear(_ bank: FileNode) -> Bool {
        func visit(_ n: FileNode, depth: Int) -> Bool {
            guard depth < 4, n.isDirectory, !AccountIndex.isArchiveName(n.name) else { return false }
            let kids = n.children ?? []
            if AccountIndex.words(n.name).contains(where: { $0 == "statements" || $0 == "statement" }),
               kids.contains(where: { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name)
                   && ($0.children ?? []).contains { !$0.isDirectory } }) { return true }
            return kids.contains { visit($0, depth: depth + 1) }
        }
        return visit(bank, depth: 0)
    }

    /// `relative` under `node`, with the segments that don't exist yet.
    static func resolve(_ relative: String, in node: FileNode, name: String?) -> Placement {
        var current: FileNode? = node
        var missing: [String] = []
        for seg in relative.split(separator: "/").map(String.init) {
            if let c = current, missing.isEmpty,
               let child = (c.children ?? []).first(where: { $0.isDirectory && $0.name.compare(seg, options: .caseInsensitive) == .orderedSame }) {
                current = child
            } else {
                missing.append(seg)
                current = nil
            }
        }
        return Placement(folder: relative, newSegments: missing, name: name)
    }

    // MARK: Name templates

    /// A file name with its date as a field: `Brokerage Statement_{yyyy}-{mm}-{dd}_863`.
    struct Template: Equatable {
        enum DateForm: Equatable { case ymdDash(String), mdyCompact, ymdCompact, ordinalMonthYear, monthYear, ymDash(String) }
        let prefix: String
        let form: DateForm
        let suffix: String
        let originalExtension: String
        /// `01.` rather than `1.`: two digits for an account filing more than ten statements a year
        /// (monthly), else the width its own names use (`1. Mar 2026` for a quarterly one).
        var padOrdinal: Bool = true

        func fill(_ p: DocumentFacts.Period, ext: String) -> String? {
            func two(_ n: Int) -> String { String(format: "%02d", n) }
            let day = p.day
            let date: String
            switch form {
            case .ymdDash(let sep):
                guard let day else { return nil }
                date = "\(p.year)\(sep)\(two(p.month))\(sep)\(two(day))"
            case .mdyCompact:
                guard let day else { return nil }
                date = "\(two(p.month))\(two(day))\(p.year)"
            case .ymdCompact:
                guard let day else { return nil }
                date = "\(p.year)\(two(p.month))\(two(day))"
            case .ordinalMonthYear:
                date = "\(padOrdinal ? two(p.month) : String(p.month)). \(Self.monthNames[p.month - 1]) \(p.year)"
            case .monthYear:
                date = "\(Self.monthNames[p.month - 1]) \(p.year)"
            case .ymDash(let sep):
                date = "\(p.year)\(sep)\(two(p.month))"
            }
            // The extension as the account's files spell it (`.PDF`), when it is the same type.
            let e = originalExtension.lowercased() == ext.lowercased() ? originalExtension : ext
            return prefix + date + suffix + (e.isEmpty ? "" : "." + e)
        }

        static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    }

    struct Parsed {
        let prefix: String; let form: Template.DateForm; let suffix: String
        var ordinalDigits: Int = 2
    }

    static func parse(_ name: String) -> Parsed? {
        let stem = (name as NSString).deletingPathExtension
        func split(_ pattern: String) -> (String, String, String)? {
            guard let r = stem.range(of: pattern, options: .regularExpression) else { return nil }
            return (String(stem[..<r.lowerBound]), String(stem[r]), String(stem[r.upperBound...]))
        }
        if let (p, d, s) = split(#"(?<!\d)(19|20)\d\d([-_.])\d\d\2\d\d(?!\d)"#) {
            let sep = String(d[d.index(d.startIndex, offsetBy: 4)])
            return Parsed(prefix: p, form: .ymdDash(sep), suffix: s)
        }
        if let (p, _, s) = split(#"(?<!\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(19|20)\d\d(?!\d)"#) {
            return Parsed(prefix: p, form: .mdyCompact, suffix: s)
        }
        if let (p, _, s) = split(#"(?<!\d)(19|20)\d\d(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#) {
            return Parsed(prefix: p, form: .ymdCompact, suffix: s)
        }
        // `01. Jan 2026` or `1. Jan 2026`: the ordinal is the month's number, written one or two
        // digits wide (``Template/padOrdinal``), never a fixed prefix.
        if let (p, d, s) = split(#"(?<!\d)\d{1,2}\. (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (19|20)\d\d"#) {
            return Parsed(prefix: p, form: .ordinalMonthYear, suffix: s,
                          ordinalDigits: d.prefix { $0.isNumber }.count)
        }
        if let (p, _, s) = split(#"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (19|20)\d\d"#) {
            return Parsed(prefix: p, form: .monthYear, suffix: s)
        }
        if let (p, d, s) = split(#"(?<!\d)(19|20)\d\d([-_.])\d\d(?!\d)"#) {
            let sep = String(d[d.index(d.startIndex, offsetBy: 4)])
            return Parsed(prefix: p, form: .ymDash(sep), suffix: s)
        }
        return nil
    }
}
