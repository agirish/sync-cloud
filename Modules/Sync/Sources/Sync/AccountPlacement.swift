import Foundation

/// Where inside an account folder a statement goes, and what it is called there, copied from the
/// account's own newest statements (design §4). `Traditional IRA 7863` keeps 2025's statements
/// loose in the account folder as `Brokerage Statement_2025-07-31_863.PDF`, so October 2026's goes
/// there as `Brokerage Statement_2026-10-31_863.PDF`; `Trust Brokerage 2 - 3494` files by
/// `Statements/<year>`, so it goes to a new `Statements/2026`.
public enum AccountPlacement {

    public struct Placement: Sendable, Equatable {
        /// Relative to the account root: "" for the root itself.
        public let folder: String
        /// Trailing segments of `folder` that don't exist yet.
        public let newSegments: [String]
        /// The name copied from the account's newest files, or nil to keep the incoming name.
        public let name: String?
        /// The statement's year wasn't known, so a year folder couldn't be chosen: the account is
        /// sure, the folder inside it isn't.
        public var yearUnknown: Bool = false
    }

    /// `node` is the account root as walked. `period` is the statement's, or nil when page 1 named
    /// none. `taxForm` sends a tax form to the account's own tax folder when it has one.
    public static func place(in node: FileNode, period: DocumentFacts.Period?, taxForm: Bool,
                             fileName: String) -> Placement {
        let ext = (fileName as NSString).pathExtension
        if taxForm {
            // A child whose name says tax (`Tax`, `Tax Forms`), else the root: the root counts as
            // the tax home of an account that keeps its 1099s beside its statements.
            let tax = (node.children ?? []).first { $0.isDirectory && AccountIndex.words($0.name).contains("tax") }
            guard let tax else { return Placement(folder: "", newSegments: [], name: nil) }
            let years = (tax.children ?? []).filter { $0.isDirectory && FolderProfileEntry.looksLikeYear($0.name) }
            if !years.isEmpty, let year = period?.year {
                return resolve(tax.name + "/" + String(year), in: node, name: nil)
            }
            return Placement(folder: tax.name, newSegments: [], name: nil)
        }
        let families = StatementFamily.families(below: node).filter { StatementFamily.isRegular($0.value) }
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
            // A year inside a longer name (`Statements 2025`, `Tax Year 2025`) moves with it too.
            if seg.count > 4, FilingPeriod.monthSlot(ofFolderNamed: seg) == nil, let period, let r = seg.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) {
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
                                         dayOffsetFromMonthEnd: nil, originalExtension: "").fill(period, ext: "") else {
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
        let name = period.flatMap { p in
            template(from: sameTypeMembers.isEmpty ? members : sameTypeMembers,
                     accountDigits: AccountIndex.accountDigits(inFolderNamed: node.name))?.fill(p, ext: ext)
        }
        return resolve(folder, in: node, name: name)
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
        /// Days after (or, negative, before) the period's last day the account names its files by:
        /// `Statement01302026` for a January ending on the 31st is −1. nil when the day follows the
        /// statement's own date.
        let dayOffsetFromMonthEnd: Int?
        let originalExtension: String

        func fill(_ p: DocumentFacts.Period, ext: String) -> String? {
            func two(_ n: Int) -> String { String(format: "%02d", n) }
            let day: Int?
            if let off = dayOffsetFromMonthEnd { day = monthEnd(p.year, p.month) + off } else { day = p.day }
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
                date = "\(two(p.month)). \(Self.monthNames[p.month - 1]) \(p.year)"
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

    static func monthEnd(_ y: Int, _ m: Int) -> Int {
        var c = DateComponents(); c.year = y; c.month = m + 1; c.day = 0
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: c).map { cal.component(.day, from: $0) } ?? 28
    }

    /// The template the family's newest three names share, or nil when they don't share one, or
    /// when a number left in the name is another account's (a family mixing `_863` and `_260`).
    static func template(from members: [StatementFamily.Member], accountDigits: [String]) -> Template? {
        let newest = members.sorted { $0.period > $1.period }.prefix(3)
        let parsed = newest.compactMap { parse($0.name) }
        guard parsed.count == newest.count, let first = parsed.first,
              parsed.allSatisfy({ $0.prefix == first.prefix && $0.suffix == first.suffix && $0.form == first.form })
        else { return nil }
        // A number in the fixed part must belong to this account (`_863` of `Traditional IRA 7863`).
        let literals = (first.prefix + first.suffix).split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        for lit in literals where !accountDigits.contains(where: { $0.hasSuffix(lit) || lit.hasSuffix($0) }) {
            return nil
        }
        // The day, against the month's last day, when every newest name agrees on it.
        let offsets = zip(newest, parsed).compactMap { m, t -> Int? in
            guard let d = t.day else { return nil }
            return d - monthEnd(m.period.year, m.period.month)
        }
        let offset = offsets.count == parsed.count && Set(offsets).count == 1 && abs(offsets[0]) <= 3 ? offsets[0] : nil
        return Template(prefix: first.prefix, form: first.form, suffix: first.suffix,
                        dayOffsetFromMonthEnd: offset, originalExtension: first.ext)
    }

    struct Parsed { let prefix: String; let form: Template.DateForm; let suffix: String; let day: Int?; let ext: String }

    static func parse(_ name: String) -> Parsed? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        func split(_ pattern: String) -> (String, String, String)? {
            guard let r = stem.range(of: pattern, options: .regularExpression) else { return nil }
            return (String(stem[..<r.lowerBound]), String(stem[r]), String(stem[r.upperBound...]))
        }
        if let (p, d, s) = split(#"(?<!\d)(19|20)\d\d([-_.])\d\d\2\d\d(?!\d)"#) {
            let sep = String(d[d.index(d.startIndex, offsetBy: 4)])
            return Parsed(prefix: p, form: .ymdDash(sep), suffix: s, day: Int(d.suffix(2)), ext: ext)
        }
        if let (p, d, s) = split(#"(?<!\d)(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(19|20)\d\d(?!\d)"#) {
            return Parsed(prefix: p, form: .mdyCompact, suffix: s, day: Int(d.dropFirst(2).prefix(2)), ext: ext)
        }
        if let (p, d, s) = split(#"(?<!\d)(19|20)\d\d(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#) {
            return Parsed(prefix: p, form: .ymdCompact, suffix: s, day: Int(d.suffix(2)), ext: ext)
        }
        if let (p, _, s) = split(#"(?<!\d)\d{2}\. (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (19|20)\d\d"#) {
            return Parsed(prefix: p, form: .ordinalMonthYear, suffix: s, day: nil, ext: ext)
        }
        if let (p, _, s) = split(#"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (19|20)\d\d"#) {
            return Parsed(prefix: p, form: .monthYear, suffix: s, day: nil, ext: ext)
        }
        if let (p, d, s) = split(#"(?<!\d)(19|20)\d\d([-_.])\d\d(?!\d)"#) {
            let sep = String(d[d.index(d.startIndex, offsetBy: 4)])
            return Parsed(prefix: p, form: .ymDash(sep), suffix: s, day: nil, ext: ext)
        }
        return nil
    }
}
