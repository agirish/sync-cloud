import Foundation

/// The date a document is *for*, read from its page 1: `{travel-year}` and `{travel-month}` in a
/// rule's destination (TE286, decision HI). A ticket's page 1 carries several dates — when it was
/// issued, the flight out, the flight back, perhaps a passenger's birthday — and the trip is filed
/// under the month it starts. So: the **earliest** date on the page that isn't labelled as an issue,
/// booking, payment or birth date, and that isn't before the issue date.
///
/// Pure and local: the text is the lowercased page sample the scan already reads.
public enum AutomationTravelDate {

    public struct Day: Sendable, Equatable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public static func < (a: Day, b: Day) -> Bool {
            (a.year, a.month, a.day) < (b.year, b.month, b.day)
        }

        /// "Sep", the spelling a new month folder gets (decision HI).
        public var monthName: String { AutomationTravelDate.shortMonths[month - 1].capitalized }
    }

    /// The tokens, for the editor's insert menu and the evaluator.
    public static let yearToken = "{travel-year}"
    public static let monthToken = "{travel-month}"

    /// Whether a destination template needs page 1 to resolve.
    public static func isUsed(in template: String) -> Bool {
        template.contains(yearToken) || template.contains(monthToken)
    }

    static let shortMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let longMonths = ["january", "february", "march", "april", "may", "june", "july", "august",
                                     "september", "october", "november", "december"]

    /// The month a word names: "sep", "sept", "september"; nil for anything else.
    static func month(named word: String) -> Int? {
        let w = word.lowercased()
        if w == "sept" { return 9 }
        if let i = shortMonths.firstIndex(of: w) { return i + 1 }
        if let i = longMonths.firstIndex(of: w) { return i + 1 }
        return nil
    }

    /// Words just before a date that say it isn't the trip's.
    private static let notTravel = ["issue", "booking", "booked", "purchase", "payment", "paid", "printed",
                                    "birth", "dob", "born", "expir", "valid until", "invoice", "created",
                                    "reservation date", "ordered"]
    /// Of those, the ones that say the date is when the document was made: travel can't be before it.
    private static let issued = ["issue", "booking", "booked", "purchase", "payment", "paid", "invoice",
                                 "reservation date", "ordered", "created"]

    private struct Found {
        var year: Int?
        let month: Int
        let day: Int
        /// The year is four digits after only spaces, which a time reads as too: "23SEP 2015".
        var yearCouldBeATime = false
        var label = ""
        var isExcluded: Bool { AutomationTravelDate.notTravel.contains { label.contains($0) } }
        var isIssue: Bool { AutomationTravelDate.issued.contains { label.contains($0) } }
    }

    private static let monthAlternation = (longMonths + ["sept"] + shortMonths).joined(separator: "|")
    // 23 sep 2026 · 23-sep-26 · 23sep2026 · 23SEP (no year). Group 3 is what stands between the
    // month and the year, as in monthDay.
    private static let dayMonth = try! NSRegularExpression(
        pattern: "(?<![a-z0-9])(\\d{1,2})[\\s\\-/.]*(\(monthAlternation))(?![a-z])([\\s\\-/.,]*)(\\d{4}|\\d{2}(?!\\d))?", options: [])
    // sep 23, 2026 · september 23 (no year)
    private static let monthDay = try! NSRegularExpression(
        pattern: "(?<![a-z0-9])(\(monthAlternation))(?![a-z])\\.?\\s*(\\d{1,2})(?!\\d)(?:st|nd|rd|th)?(,?\\s*)(\\d{4})?", options: [])
    // 2026-09-23 · 2026/09/23
    private static let iso = try! NSRegularExpression(
        pattern: "(?<!\\d)(\\d{4})[\\-/.](\\d{1,2})[\\-/.](\\d{1,2})(?!\\d)", options: [])
    // 23/09/2026 or 09/23/2026, only when one side is over 12
    private static let numeric = try! NSRegularExpression(
        pattern: "(?<![\\d/])(\\d{1,2})[/.\\-](\\d{1,2})[/.\\-](\\d{4})(?![\\d/])", options: [])

    /// The first date of travel on page 1, or nil when there is none to go by.
    public static func first(in text: String) -> Day? { first(in: text, now: Date()) }

    /// `now` bounds the years read: no page names one more than five years on, so a ticket's
    /// "23SEP 2145" is a time.
    static func first(in text: String, now: Date) -> Day? {
        let latestYear = Calendar(identifier: .gregorian).component(.year, from: now) + 5
        let text = text.lowercased()
        let ns = text as NSString
        var found: [(range: NSRange, Found)] = []
        var taken: [NSRange] = []
        /// The words just before a date, back to the date before it: on its own line, or on the
        /// line above when the date starts its line.
        func label(before range: NSRange, after previousEnd: Int) -> String {
            let start = max(previousEnd, range.location - 40, 0)
            var prefix = ns.substring(with: NSRange(location: start, length: range.location - start))
            if let lineBreak = prefix.lastIndex(of: "\n") {
                let sameLine = prefix[prefix.index(after: lineBreak)...]
                prefix = sameLine.trimmingCharacters(in: .whitespaces).isEmpty ? prefix : String(sameLine)
            }
            return prefix
        }
        func add(_ regex: NSRegularExpression, _ make: (NSTextCheckingResult) -> (Int?, Int, Int)?,
                 yearCouldBeATime: (NSTextCheckingResult) -> Bool = { _ in false }) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      let (year, month, day) = make(match),
                      (1...12).contains(month), (1...31).contains(day) else { continue }
                taken.append(match.range)
                found.append((match.range, Found(year: year, month: month, day: day,
                                                 yearCouldBeATime: year != nil && yearCouldBeATime(match))))
            }
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func fullYear(_ s: String?) -> Int? {
            guard let s, let n = Int(s) else { return nil }
            let year = s.count == 2 ? 2000 + n : n
            // A ticket prints its times beside its dates: "14OCT 0930" is no year 930, nor
            // "23SEP 2145" the year 2145.
            return (1900...latestYear).contains(year) ? year : nil
        }
        /// A day-month or month-day date's year group, unless a time: the "21" of "23 SEP 21:45".
        func year(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let r = m.range(at: i)
            guard r.location != NSNotFound else { return nil }
            if NSMaxRange(r) < ns.length, [":", "h"].contains(ns.substring(with: NSRange(location: NSMaxRange(r), length: 1))) {
                return nil
            }
            return fullYear(ns.substring(with: r))
        }
        /// Four digits after only spaces, which read as a time (HHMM) as readily as a year:
        /// "23SEP 2015" is 20:15. Glued ("23SEP2015"), or after a comma or dash, they are a year.
        func couldBeATime(_ m: NSTextCheckingResult, separator: Int, year: Int) -> Bool {
            guard let sep = group(m, separator), !sep.isEmpty, sep.allSatisfy(\.isWhitespace),
                  let digits = group(m, year), digits.count == 4, let n = Int(digits) else { return false }
            return n / 100 <= 23 && n % 100 <= 59
        }
        add(iso) { m in
            guard let y = fullYear(group(m, 1)), let mo = group(m, 2).flatMap({ Int($0) }),
                  let d = group(m, 3).flatMap({ Int($0) }) else { return nil }
            return (y, mo, d)
        }
        add(dayMonth, { m in
            guard let d = group(m, 1).flatMap({ Int($0) }), let mo = group(m, 2).flatMap(month(named:)) else { return nil }
            return (year(m, 4), mo, d)
        }, yearCouldBeATime: { couldBeATime($0, separator: 3, year: 4) })
        add(monthDay, { m in
            guard let mo = group(m, 1).flatMap(month(named:)), let d = group(m, 2).flatMap({ Int($0) }) else { return nil }
            return (year(m, 4), mo, d)
        }, yearCouldBeATime: { couldBeATime($0, separator: 3, year: 4) })
        add(numeric) { m in
            guard let a = group(m, 1).flatMap({ Int($0) }), let b = group(m, 2).flatMap({ Int($0) }),
                  let y = fullYear(group(m, 3)) else { return nil }
            if a > 12, b <= 12 { return (y, b, a) }
            if b > 12, a <= 12 { return (y, a, b) }
            return nil   // 04/09/2026 could be April or September: no guess
        }
        found.sort { $0.range.location < $1.range.location }
        var previousEnd = 0
        var dates: [Found] = found.map { range, f in
            var f = f
            f.label = label(before: range, after: previousEnd)
            previousEnd = NSMaxRange(range)
            return f
        }
        // A year that could be a time is a year only near the page's sure ones (and its issue
        // date's): on a ticket issued in 2026, "23SEP 2015" departs at 20:15.
        let sureYears = dates.filter { !$0.yearCouldBeATime || $0.isIssue }.compactMap(\.year)
        if !sureYears.isEmpty {
            for i in dates.indices where dates[i].yearCouldBeATime && !dates[i].isIssue {
                if let y = dates[i].year, !sureYears.contains(where: { abs($0 - y) <= 1 }) { dates[i].year = nil }
            }
        }

        // A date with no year takes the year of the dates around it: the issue date's, else the
        // first full date's, moved on a year when it would fall before that date (05 JAN on a
        // ticket issued in December is next January).
        let reference = dates.first(where: { $0.isIssue && $0.year != nil }) ?? dates.first(where: { $0.year != nil })
        guard let reference, let refYear = reference.year else { return nil }
        let refDay = Day(year: refYear, month: reference.month, day: reference.day)
        let resolved: [(Day, Found)] = dates.map { f in
            if let y = f.year { return (Day(year: y, month: f.month, day: f.day), f) }
            var y = refYear
            if Day(year: y, month: f.month, day: f.day) < refDay { y += 1 }
            return (Day(year: y, month: f.month, day: f.day), f)
        }
        let issuedOn = resolved.filter { $0.1.isIssue }.map(\.0).max()
        let latest = resolved.map(\.0).max()
        let travel = resolved.filter { day, f in
            guard !f.isExcluded else { return false }
            if let issuedOn, day < issuedOn { return false }
            // An unlabelled date years before the rest (a birthday) isn't the trip's.
            if let latest, day.year < latest.year - 1 { return false }
            return true
        }
        return travel.map(\.0).min()
    }

    /// The month a folder name stands for: "Sep", "September", "09", "4", "9. Sep 2017"; nil for
    /// a name that names no month or more than one.
    static func month(ofFolder name: String) -> Int? {
        let lower = name.lowercased()
        if let n = Int(lower.trimmingCharacters(in: .whitespaces)), (1...12).contains(n) { return n }
        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let months = Set(words.compactMap(month(named:)))
        return months.count == 1 ? months.first : nil
    }

    /// The resolved destination with its `{travel-month}` segment spelled as the folder already
    /// there (decision HI): "April" when the template made "Apr" and the year holds "April".
    /// `children` lists a folder's subfolder names, relative path in; the path is unchanged when
    /// none matches, so a new month folder gets the short name.
    public static func adoptingExistingMonth(_ resolved: String, template: String,
                                             children: (String) -> [String]) -> String {
        let templateSegments = template.split(separator: "/").map(String.init)
        var segments = resolved.split(separator: "/").map(String.init)
        guard templateSegments.count == segments.count,
              let index = templateSegments.firstIndex(of: monthToken),
              let month = month(named: segments[index]) else { return resolved }
        let parent = segments[..<index].joined(separator: "/")
        let siblings = children(parent)
        guard !siblings.contains(segments[index]) else { return resolved }
        if let existing = siblings.sorted().first(where: { Self.month(ofFolder: $0) == month }) {
            segments[index] = existing
        }
        return segments.joined(separator: "/")
    }
}
