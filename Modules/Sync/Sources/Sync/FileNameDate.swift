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
        public let year: Int
        /// How it was found, for the row subtitle — the user is reviewing a proposed rename and
        /// "from `07182023` in the name" is the difference between trusting it and not.
        public let evidence: String

        public init(month: Int, year: Int, evidence: String) {
            self.month = month
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

        let stamped = datestamp(in: runs)
        let spelled = spelledMonth(in: runs)

        switch (stamped, spelled) {
        case let (s?, w?):
            return (s.month == w.month && s.year == w.year) ? s : nil
        case let (s?, nil): return s
        case let (nil, w?): return w
        case (nil, nil): return nil
        }
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
        var evidence = ""
        for run in runs where run.count == 8 && run.allSatisfy(\.isNumber) {
            let d = Array(run)
            let a = Int(String(d[0...3]))!, b = Int(String(d[4...5]))!, c = Int(String(d[6...7]))!
            let m1 = Int(String(d[0...1]))!, d1 = Int(String(d[2...3]))!, y1 = Int(String(d[4...7]))!
            if isYear(a), isMonth(b), isDay(c) {
                found.insert(b * 10000 + a); evidence = String(run)
            } else if isMonth(m1), isDay(d1), isYear(y1) {
                found.insert(m1 * 10000 + y1); evidence = String(run)
            }
        }
        guard found.count == 1, let packed = found.first else { return nil }
        return Mined(month: packed / 10000, year: packed % 10000,
                     evidence: "the datestamp \(evidence) in the name")
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
        return Mined(month: m, year: y, evidence: "“\(monthWord) \(y)” in the name")
    }

    /// 1–12 when a letter run is, or ends with, a month name.
    static func monthSuffix(_ run: String) -> Int? {
        let lower = run.lowercased()
        if let m = OrdinalMonthName.monthIndex(lower) { return m }
        // Longest candidate first, so `...September` is not read as the `Sep` inside it — same
        // month here, but the abbreviation would be the reported evidence for a spelled-out name.
        for name in OrdinalMonthName.monthFullNames.sorted(by: { $0.count > $1.count })
        where lower.hasSuffix(name) {
            return OrdinalMonthName.monthFullNames.firstIndex(of: name).map { $0 + 1 }
        }
        for (i, abbr) in OrdinalMonthName.monthAbbreviations.enumerated()
        where lower.hasSuffix(abbr.lowercased()) {
            return i + 1
        }
        return nil
    }
}
