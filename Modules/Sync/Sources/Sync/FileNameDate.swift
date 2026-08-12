import Foundation

/// The month and year a raw filename already carries, when it carries exactly one of each.
///
/// Most of the rename backlog needs no model call, because the provider put the date in the name on
/// the way out: `9829custbill07182023.pdf`, `20240128-statements-8857.pdf`,
/// `STMTCMB100_20201101_5203_Girish.PDF`, `ATTBill_1897_Feb2022.pdf`, `DetailedBillApr2025.pdf`.
/// This mines it, purely, with no disk and no clock.
///
/// ## It says no far more often than it says yes, and that is the design
///
/// Of the 76 raw files sitting in the tree's `ordinal-month` folders, **only seven name a single
/// month**. The rest are year-end summaries (`Year End Summary 2016.pdf`), fiscal ranges
/// (`Apr 2009 - Mar 2010.pdf`), account paperwork (`Interest Certificate.pdf`, `Tags.pdf`), UUID
/// exports and digit soup (`16106593108981703151004183789428.pdf`). **None of those belong in a
/// monthly slot**, and a miner that guessed a month for them would propose 69 wrong renames to win
/// seven right ones.
///
/// So every rule here is a *multiplicity* rule: a name naming two distinct months is a range and has
/// no slot; a name naming two distinct years has no year. `Jan-Dec 2019.pdf` and
/// `01 JUL 2020 TO 30 SEP 2020.pdf` are rejected by that alone, while
/// `01 FEB 2020 TO 29 FEB 2020.pdf` — two month tokens naming the *same* month — is accepted. That
/// is why the rule counts DISTINCT values rather than tokens.
public enum FileNameDate {

    /// A month and year mined from a name, with the evidence that produced it.
    public struct Mined: Sendable, Equatable {
        public let month: Int
        /// The day, when the name pinned one. **Only day-keyed folders read it** — a month-keyed
        /// folder's slot is the month, so a day it happens to know changes nothing there.
        public let day: Int?
        public let year: Int
        /// How it was found, for the row subtitle — the user is reviewing a proposed rename and
        /// "from `07182023` in the name" is the difference between trusting it and not.
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
    /// Two independent readings are taken — a compact 8-digit datestamp, and a spelled month beside
    /// a 4-digit year — and **when both fire they must agree**. A name carrying a datestamp for one
    /// month and a word for another is not a name this pass understands.
    public static func mine(_ fileName: String) -> Mined? {
        let stem = (fileName as NSString).deletingPathExtension
        let runs = tokenRuns(stem)

        // Three independent readings, and **every one that fires must agree on the month and the
        // year**. Kept as a unanimity rule over a list rather than the pairwise `switch` this used
        // to be: a third reading would have needed a nine-arm switch, and the arm that matters —
        // "two readings disagree, so this name is not one this pass understands" — is easy to get
        // subtly wrong when it is spelled nine times.
        let readings = [datestamp(in: runs), delimitedDate(in: runs), spelledMonth(in: runs)]
            .compactMap { $0 }
        guard let first = readings.first,
              readings.allSatisfy({ $0.month == first.month && $0.year == first.year })
        else { return nil }

        // A day is reported only when the readings that found one agree about it. A reading that
        // found no day abstains rather than vetoing — `Jun 2019` beside `06152019` is a name whose
        // day is known once, not a contradiction.
        let days = Set(readings.compactMap(\.day))
        return Mined(month: first.month, day: days.count == 1 ? days.first : nil,
                     year: first.year, evidence: first.evidence)
    }

    // MARK: Tokenising

    /// `stem` split into maximal runs of letters and of digits, discarding everything else.
    ///
    /// The letter/digit boundary is a separator in its own right, which is what makes `Feb2022` and
    /// `DetailedBillApr2025` reachable — neither has a delimiter in it, and splitting only on
    /// punctuation would hand the month-and-year reader a single opaque token.
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

    /// The month and year from a **delimited 8-digit run**, read as `YYYYMMDD` or `MMDDYYYY`.
    ///
    /// The two readings can never both be valid, which is what makes this unambiguous rather than a
    /// coin flip: `YYYYMMDD` requires the first two digits to be `19`, `20` or `21`, and `MMDDYYYY`
    /// requires them to be a month, `01`–`12`. The ranges are disjoint. A `DDMMYYYY` name like
    /// `18072023` therefore matches neither and is refused outright — the conservative answer, and
    /// the right one, because nothing in the surveyed tree writes that form.
    ///
    /// The run must be **exactly** 8 digits. `8666160540530062020.pdf` and
    /// `16106593108981703151004183789428.pdf` are account references and export ids that happen to
    /// contain digit sequences reading as dates; requiring a whole delimited run keeps them out.
    static func datestamp(in runs: [Substring]) -> Mined? {
        var found: Set<Int> = []      // month * 10000 + year, so a repeat of the SAME date is one value
        // Days are counted separately, and deliberately do NOT join the key above. Two stamps for
        // one month — `20240115` and `20240120` — collapse to a single month-and-year answer today,
        // and folding the day into `found` would turn that into a refusal. The day is the thing
        // that is unknown there, not the month.
        var days: Set<Int> = []
        var evidence = ""
        for run in runs where run.count == 8 && run.allSatisfy(\.isNumber) {
            let d = Array(run)
            let a = Int(String(d[0...3]))!, b = Int(String(d[4...5]))!, c = Int(String(d[6...7]))!
            let m1 = Int(String(d[0...1]))!, d1 = Int(String(d[2...3]))!, y1 = Int(String(d[4...7]))!
            if isYear(a), isMonth(b), isDay(c) {
                found.insert(b * 10000 + a); days.insert(c); evidence = String(run)
            } else if isMonth(m1), isDay(d1), isYear(y1) {
                found.insert(m1 * 10000 + y1); days.insert(d1); evidence = String(run)
            }
        }
        guard found.count == 1, let packed = found.first else { return nil }
        return Mined(month: packed / 10000, day: days.count == 1 ? days.first : nil,
                     year: packed % 10000, evidence: "the datestamp \(evidence) in the name")
    }

    // MARK: Reading 3 — a delimited date

    /// The date from **three adjacent numeric runs** shaped `YYYY MM DD` or `MM DD YYYY`.
    ///
    /// This is what reaches `Payslip_2026-06-15.pdf`, and without it the file the whole day-keyed
    /// convention exists for names no month at all: its runs are `Payslip · 2026 · 06 · 15`, which
    /// carries no 8-digit stamp and no spelled month, so ``mine`` returned nil for it.
    ///
    /// **Shape-disjoint, exactly as ``datestamp`` is.** A `(4,2,2)` window can only be read
    /// year-first and a `(2,2,4)` window only year-last, so the two never compete for one window and
    /// there is no coin flip. `DD MM YYYY` is refused for the same reason it is refused there:
    /// nothing in the surveyed tree writes it, and `15 06 2026` is indistinguishable from a June
    /// 15th written the American way.
    ///
    /// Requiring the runs to be *adjacent* and *exactly* those widths is what keeps account numbers
    /// out: `STMTCMB100_20201101_5203` runs as `100 · 20201101 · 5203`, whose widths are 3, 8 and 4.
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

    // MARK: Reading 2 — a spelled month beside a year

    /// The month and year from a spelled month token and a 4-digit year token.
    ///
    /// A letter run counts as a month when it *is* a month word (`Feb`, `February`) or **ends with
    /// one** (`DetailedBillApr`). The suffix rule is what reaches the glued provider names, and it is
    /// held in check by requiring a plausible year elsewhere in the name and by the distinct-value
    /// rules below — a stray suffix match on its own proposes nothing.
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
        // Exactly one distinct month AND one distinct year. Two months is a range (`Jan-Dec 2019`),
        // two years is a fiscal span (`Apr 2009 - Mar 2010`), and neither has a monthly slot.
        guard months.count == 1, years.count == 1,
              let m = months.first, let y = years.first else { return nil }
        return Mined(month: m, day: dayBetweenMonthAndYear(in: runs, year: y), year: y,
                     evidence: "“\(monthWord) \(y)” in the name")
    }

    /// The day in a `Mon DD YYYY` run sequence — **positional, for the same reason
    /// ``OrdinalMonthName/day(in:month:year:)`` is.** A small number elsewhere in a name is a
    /// duplicate marker or an account fragment far more often than it is a day.
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

    /// 1–12 when a letter run **is** a month name, or ends with one *at a word boundary*.
    ///
    /// The suffix rule exists to reach glued provider names — `DetailedBillApr` — and it read any
    /// letter run ending in those three letters, which ordinary words do: `Kumar` was March,
    /// `Rajan` was January, `codec` was December. That is not hypothetical in this household's
    /// tree; `Sanjay Kumar 2023.pdf` has a lone plausible year beside it, which is all
    /// ``spelledMonth`` needs to mine a whole date and propose renaming the file `03. Mar 2023`.
    /// The "held in check by requiring a plausible year" the comment above claims is exactly the
    /// check a `<Name> <Year>.pdf` satisfies.
    ///
    /// So the suffix must begin where a word begins, and inside a single letter run the only thing
    /// that marks a word boundary is a change of case. Two shapes qualify:
    ///
    /// - a **title-cased month** — `…Bill|Apr`, `HDFC|Apr`, `IRS|Mar`. The month's own casing is
    ///   the boundary, so an acronym in front of it does not hide one.
    /// - an **all-caps month** preceded by a lowercase character. `KU|MAR` has no such character
    ///   and is a surname; nothing in an all-caps run separates a word from a month.
    ///
    /// The deliberate cost is the fully caseless run: `detailedbillapr` and `BILLAPR` are no longer
    /// read as months. Provider names carry their casing one way or the other; family names are the
    /// population being protected.
    static func monthSuffix(_ run: String) -> Int? {
        let lower = run.lowercased()
        if let m = OrdinalMonthName.monthIndex(lower) { return m }

        /// Whether `name` ends `run` at a word boundary, or is the whole run.
        ///
        /// The first draft asked only that the month start with a capital, which is unconditionally
        /// true inside an ALL-CAPS run — so `KUMAR` was still March, `RAJAN` still January, `MAPR`
        /// still April: every example the rule was written to stop, surviving in upper case. (1,749
        /// files on the real tree carry an all-caps run of four or more characters, three of them
        /// the token `MAPR`.) The second asked for a lowercase character *before* the month, which
        /// fixed those and took `HDFCApr`, `AMEXApr` and `IRSMar` with them — an acronym in front of
        /// a title-cased month is a boundary a reader has no trouble seeing.
        ///
        /// So: a title-cased month carries its own boundary; an all-caps month needs a lowercase
        /// character in front of it.
        func endsAtAWordBoundary(_ name: String) -> Bool {
            guard lower.hasSuffix(name) else { return false }
            guard name.count < run.count else { return true }
            let start = run.index(run.endIndex, offsetBy: -name.count)
            guard run[start].isUppercase else { return false }
            let titleCased = !run[run.index(after: start)...].contains { $0.isUppercase }
            return titleCased || run[run.index(before: start)].isLowercase
        }

        // Longest candidate first, so `...September` is not read as the `Sep` inside it — same
        // month here, but the abbreviation would be the reported evidence for a spelled-out name.
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
