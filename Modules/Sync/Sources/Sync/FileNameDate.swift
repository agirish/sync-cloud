import Foundation

/// The month and year a raw filename already carries, when it carries exactly one of each.
///
/// Providers often put the date in the name (`9829custbill07182023.pdf`,
/// `20240128-statements-8857.pdf`, `ATTBill_1897_Feb2022.pdf`), so many renames need no model call.
/// This mines it, purely, with no disk and no clock.
///
/// It says no far more often than yes, by design: most raw files in month folders are year-end
/// summaries, fiscal ranges, paperwork or digit soup, and a guessed month would be a wrong rename.
/// So every rule counts distinct values: two distinct months is a range, two distinct years has no
/// year. `Jan-Dec 2019.pdf` is rejected, while `01 FEB 2020 TO 29 FEB 2020.pdf` (one month, twice)
/// is accepted.
public enum FileNameDate {

    /// A month and year mined from a name, with the evidence that produced it.
    public struct Mined: Sendable, Equatable {
        public let month: Int
        /// The day, when the name pinned one. Only day-keyed folders read it; a month-keyed folder's
        /// slot is the month.
        public let day: Int?
        public let year: Int
        /// How it was found, for the row subtitle, so the user reviewing a proposed rename can see
        /// why ("from `07182023` in the name").
        public let evidence: String

        public init(month: Int, day: Int? = nil, year: Int, evidence: String) {
            self.month = month
            self.day = day
            self.year = year
            self.evidence = evidence
        }
    }

    /// The single month and year `fileName` names, or nil.
    ///
    /// Three independent readings are taken (an 8-digit datestamp, a delimited date, and a spelled
    /// month beside a 4-digit year), and every one that fires must agree. A name whose readings
    /// disagree is not one this pass understands.
    public static func mine(_ fileName: String) -> Mined? {
        let stem = (fileName as NSString).deletingPathExtension
        let runs = tokenRuns(stem)

        // A unanimity rule over a list, so a new reading can't get the "they disagree" case wrong.
        let readings = [datestamp(in: runs), delimitedDate(in: runs), spelledMonth(in: runs)]
            .compactMap { $0 }
        guard let first = readings.first,
              readings.allSatisfy({ $0.month == first.month && $0.year == first.year })
        else { return nil }

        // A day is reported only when the readings that found one agree. A reading with no day
        // abstains rather than vetoes: `Jun 2019` beside `06152019` is not a contradiction.
        let days = Set(readings.compactMap(\.day))
        return Mined(month: first.month, day: days.count == 1 ? days.first : nil,
                     year: first.year, evidence: first.evidence)
    }

    /// A date the name carries that both conventions could have written: the two readings
    /// ``mine(_:)`` refused to choose between.
    public struct Ambiguity: Sendable, Equatable {
        /// The stamp as it appears in the name — `05062023`, `05-06-2023`.
        public let evidence: String
        /// Read month-first: `05062023` is May 6.
        public let monthFirst: Mined
        /// Read day-first: `05062023` is 5 June.
        public let dayFirst: Mined
    }

    /// The first year-last stamp in `fileName` whose two leading pairs could be read either way
    /// round, or nil, so a skip can say "ambiguous" with both dates rather than "no month and
    /// year". The same shapes ``datestamp(in:)`` and ``delimitedDate(in:)`` abstain on.
    public static func ambiguity(_ fileName: String) -> Ambiguity? {
        let runs = tokenRuns((fileName as NSString).deletingPathExtension)
        func reading(_ first: Int, _ second: Int, _ year: Int, _ evidence: String) -> Ambiguity? {
            guard isAmbiguousDayMonth(first, second), isYear(year) else { return nil }
            return Ambiguity(evidence: evidence,
                             monthFirst: Mined(month: first, day: second, year: year, evidence: evidence),
                             dayFirst: Mined(month: second, day: first, year: year, evidence: evidence))
        }
        for (i, run) in runs.enumerated() {
            if run.count == 8, run.allSatisfy(\.isNumber) {
                let d = Array(run)
                if let found = reading(Int(String(d[0...1]))!, Int(String(d[2...3]))!,
                                       Int(String(d[4...7]))!, String(run)) { return found }
            }
            guard i + 2 < runs.count else { continue }
            let w = [run, runs[i + 1], runs[i + 2]]
            guard w.map(\.count) == [2, 2, 4], w.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let a = Int(w[0]), let b = Int(w[1]), let c = Int(w[2]) else { continue }
            if let found = reading(a, b, c, w.joined(separator: "-")) { return found }
        }
        return nil
    }

    // MARK: Tokenising

    /// `stem` split into maximal runs of letters and of digits, discarding everything else.
    ///
    /// The letter/digit boundary is a separator too, so glued names like `Feb2022` and
    /// `DetailedBillApr2025` split into a month and a year.
    static func tokenRuns(_ stem: String) -> [Substring] {
        var runs: [Substring] = []
        var start: String.Index? = nil
        var startIsDigit = false
        for i in stem.indices {
            let c = stem[i]
            let isAlnum = c.isLetter || c.isNumber
            if isAlnum {
                if let s = start, c.isNumber != startIsDigit {
                    runs.append(stem[s..<i])
                    start = i
                    startIsDigit = c.isNumber
                } else if start == nil {
                    start = i
                    startIsDigit = c.isNumber
                }
            } else if let s = start {
                runs.append(stem[s..<i])
                start = nil
            }
        }
        if let s = start { runs.append(stem[s...]) }
        return runs
    }

    // MARK: Reading 1 — a compact datestamp

    /// The month and year from a delimited 8-digit run, read as `YYYYMMDD` or `MMDDYYYY`.
    ///
    /// `YYYYMMDD` and `MMDDYYYY` never both fit: the first two digits are `19`–`21` for one and a
    /// month for the other. `MMDDYYYY` and `DDMMYYYY` can both fit (`05062023`), and nothing in the
    /// name says which wrote it, so when both leading pairs are 12 or less and differ this abstains
    /// rather than guess. `05052023` reads the same either way and is kept. A day over 12
    /// (`18072023`) matches no reading. The run must be exactly 8 digits, so account numbers and
    /// export ids that contain date-like digits stay out.
    static func datestamp(in runs: [Substring]) -> Mined? {
        var found: Set<Int> = []      // month * 10000 + year, so a repeat of the SAME date is one value
        // Days are kept out of the key above: two stamps in one month (`20240115`, `20240120`) still
        // name one month, and only the day is unknown.
        var days: Set<Int> = []
        var evidence = ""
        for run in runs where run.count == 8 && run.allSatisfy(\.isNumber) {
            let d = Array(run)
            let a = Int(String(d[0...3]))!, b = Int(String(d[4...5]))!, c = Int(String(d[6...7]))!
            let m1 = Int(String(d[0...1]))!, d1 = Int(String(d[2...3]))!, y1 = Int(String(d[4...7]))!
            if isYear(a), isMonth(b), isDay(c) {
                found.insert(b * 10000 + a); days.insert(c); evidence = String(run)
            } else if isMonth(m1), isDay(d1), isYear(y1) {
                // Day-first could have written it too — abstain, whatever the other runs say.
                if isAmbiguousDayMonth(m1, d1) { return nil }
                found.insert(m1 * 10000 + y1); days.insert(d1); evidence = String(run)
            }
        }
        guard found.count == 1, let packed = found.first else { return nil }
        return Mined(month: packed / 10000, day: days.count == 1 ? days.first : nil,
                     year: packed % 10000, evidence: "the datestamp \(evidence) in the name")
    }

    // MARK: Reading 3 — a delimited date

    /// The date from three adjacent numeric runs shaped `YYYY MM DD` or `MM DD YYYY`.
    ///
    /// Reaches names like `Payslip_2026-06-15.pdf`, which carry no 8-digit stamp and no spelled
    /// month. Shape-disjoint like ``datestamp``: `(4,2,2)` reads year-first, `(2,2,4)` year-last.
    /// `15 06 2026` matches no reading, and an ambiguous `05-06-2023` makes it abstain, as there.
    /// Adjacent runs of exactly those widths keep account numbers out
    /// (`STMTCMB100_20201101_5203` runs 3, 8 and 4 wide).
    static func delimitedDate(in runs: [Substring]) -> Mined? {
        var found: Set<Int> = []      // month * 10000 + year, matching `datestamp`'s key
        var days: Set<Int> = []
        var evidence = ""
        for i in runs.indices.dropLast(2) {
            let w = [runs[i], runs[i + 1], runs[i + 2]]
            guard w.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let a = Int(w[0]), let b = Int(w[1]), let c = Int(w[2]) else { continue }
            let widths = w.map(\.count)
            if widths == [4, 2, 2], isYear(a), isMonth(b), isDay(c) {
                found.insert(b * 10000 + a); days.insert(c)
                evidence = w.joined(separator: "-")
            } else if widths == [2, 2, 4], isMonth(a), isDay(b), isYear(c) {
                if isAmbiguousDayMonth(a, b) { return nil }
                found.insert(a * 10000 + c); days.insert(b)
                evidence = w.joined(separator: "-")
            }
        }
        guard found.count == 1, let packed = found.first else { return nil }
        return Mined(month: packed / 10000, day: days.count == 1 ? days.first : nil,
                     year: packed % 10000, evidence: "the date \(evidence) in the name")
    }

    static func isYear(_ y: Int) -> Bool { (1900...2199).contains(y) }
    static func isMonth(_ m: Int) -> Bool { (1...12).contains(m) }
    static func isDay(_ d: Int) -> Bool { (1...31).contains(d) }

    /// Whether a year-last stamp's leading pair could be read either way round: both are months
    /// and they differ, so month-first and day-first name two different dates.
    static func isAmbiguousDayMonth(_ first: Int, _ second: Int) -> Bool {
        isMonth(first) && isMonth(second) && first != second
    }

    // MARK: Reading 2 — a spelled month beside a year

    /// The month and year from a spelled month token and a 4-digit year token.
    ///
    /// A letter run counts as a month when it is a month word (`Feb`, `February`) or ends with one
    /// at a word boundary (`DetailedBillApr`; see ``monthSuffix(_:)``). A plausible year and the
    /// distinct-value rule below must hold too.
    static func spelledMonth(in runs: [Substring]) -> Mined? {
        var months: Set<Int> = []
        var years: Set<Int> = []
        var monthWord = ""
        for run in runs {
            if run.allSatisfy(\.isNumber) {
                if run.count == 4, let y = Int(run), isYear(y) { years.insert(y) }
            } else if let m = monthSuffix(String(run)) {
                months.insert(m)
                monthWord = String(run)
            }
        }
        // Exactly one distinct month and one distinct year. Two months is a range (`Jan-Dec 2019`),
        // two years is a fiscal span (`Apr 2009 - Mar 2010`), and neither has a monthly slot.
        guard months.count == 1, years.count == 1,
              let m = months.first, let y = years.first else { return nil }
        return Mined(month: m, day: dayBetweenMonthAndYear(in: runs, year: y), year: y,
                     evidence: "“\(monthWord) \(y)” in the name")
    }

    /// The day in a `Mon DD YYYY` run sequence. Positional, like
    /// ``OrdinalMonthName/day(in:month:year:)``: a small number elsewhere in a name is more often a
    /// duplicate marker or an account fragment than a day.
    static func dayBetweenMonthAndYear(in runs: [Substring], year: Int) -> Int? {
        var days: Set<Int> = []
        for i in runs.indices.dropFirst().dropLast() {
            let token = runs[i]
            guard (1...2).contains(token.count), token.allSatisfy(\.isNumber),
                  let d = Int(token), isDay(d),
                  monthSuffix(String(runs[i - 1])) != nil,
                  runs[i + 1].count == 4, Int(runs[i + 1]) == year
            else { continue }
            days.insert(d)
        }
        return days.count == 1 ? days.first : nil
    }

    /// 1–12 when a letter run is a month name, or ends with one at a word boundary.
    ///
    /// The suffix reaches glued provider names (`DetailedBillApr`), but ordinary words end in
    /// month letters too: `Kumar`, `Rajan`, `codec`. `Sanjay Kumar 2023.pdf` has a year beside it,
    /// so a bare suffix would rename it `03. Mar 2023`. Inside one letter run only a change of case
    /// marks a word boundary, so two shapes qualify:
    ///
    /// - a title-cased month (`…Bill|Apr`, `HDFC|Apr`, `IRS|Mar`): its own casing is the boundary.
    /// - an all-caps month after a lowercase character. `KU|MAR` has none and is a surname.
    ///
    /// The cost is caseless runs: `detailedbillapr` and `BILLAPR` aren't read as months. Protecting
    /// family names is worth it.
    static func monthSuffix(_ run: String) -> Int? {
        let lower = run.lowercased()
        if let m = OrdinalMonthName.monthIndex(lower) { return m }

        /// Whether `name` ends `run` at a word boundary, or is the whole run. A title-cased month
        /// carries its own boundary; an all-caps month needs a lowercase character in front of it.
        /// A capital alone isn't enough (`KUMAR` would be March), and requiring lowercase before
        /// every month would lose `HDFCApr` and `IRSMar`.
        func endsAtAWordBoundary(_ name: String) -> Bool {
            guard lower.hasSuffix(name) else { return false }
            guard name.count < run.count else { return true }
            // Offsets from `lower` index `run`, sound only while lowercasing keeps the character
            // count. That holds today but isn't guaranteed, and a misalignment would mine a date from
            // the wrong characters, so refuse: a month not read is only a rename not proposed.
            guard lower.count == run.count else { return false }
            let start = run.index(run.endIndex, offsetBy: -name.count)
            guard run[start].isUppercase else { return false }
            let titleCased = !run[run.index(after: start)...].contains { $0.isUppercase }
            return titleCased || run[run.index(before: start)].isLowercase
        }

        // Longest first, so `...September` isn't reported as the `Sep` inside it.
        for name in OrdinalMonthName.monthFullNames.sorted(by: { $0.count > $1.count })
        where endsAtAWordBoundary(name) {
            return OrdinalMonthName.monthFullNames.firstIndex(of: name).map { $0 + 1 }
        }
        for (i, abbr) in OrdinalMonthName.monthAbbreviations.enumerated()
        where endsAtAWordBoundary(abbr.lowercased()) {
            return i + 1
        }
        return nil
    }
}
