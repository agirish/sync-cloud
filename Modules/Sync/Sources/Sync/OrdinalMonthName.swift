import Foundation

/// The house convention `NN. Mon YYYY.ext`: parsing it, rendering it, and nothing else.
///
/// The one grammar the rename pass reads and writes. Deliberately narrow: where a file goes, which
/// slot it takes and whether to rename it are ``RenamePlanner``'s questions, which keeps the
/// grammar testable on its own against real names.
///
/// ## What counts as conforming
///
/// `04. Apr 2025.pdf` is the target shape. The parser is wider than the renderer on purpose, so it
/// recognises the near-misses it has to fix:
///
/// | On disk | Parsed | Why it is not already right |
/// |---|---|---|
/// | `04. Apr 2025.pdf` | ordinal 4, Apr 2025 | — it is right |
/// | `4. Apr 2025.pdf` | ordinal 4, Apr 2025 | one digit; misorders past September |
/// | `10.Oct 2011.pdf` | ordinal 10, Oct 2011 | no space after the dot |
/// | `04. April 2025.pdf` | ordinal 4, Apr 2025 | month spelled out |
///
/// A file that parses is not necessarily named correctly (a one-digit ordinal is the commonest
/// fix), so `ordinalDigits` is recorded rather than discarded.
public enum OrdinalMonthName {

    /// A name that matched the grammar, decomposed.
    public struct Parsed: Sendable, Equatable {
        /// The leading number, as an integer. `0` is the summary slot (`0. Summary 2022.pdf`).
        public let ordinal: Int
        /// How many digits the ordinal was written with — 1 for `4. Apr`, 2 for `04. Apr`. The
        /// padding fix keys on this, so it must survive parsing.
        public let ordinalDigits: Int
        /// 1–12, or nil for a slot that carries no month (the summary slot).
        public let month: Int?
        /// 1–31 when the body spells a day between its month and its year (`Jan 15 2026`), else
        /// nil. See ``OrdinalMonthName/day(in:month:year:)`` for why the position is required.
        public let day: Int?
        public let year: Int?
        /// Everything between the ordinal and the extension, verbatim — `Apr 2025`, `Summary 2022`.
        /// Kept so a pure re-numbering can rewrite the ordinal without touching the rest of a name
        /// whose tail this grammar does not model.
        public let body: String
        /// The extension WITHOUT the dot, in its original case (`pdf`, `PDF`, `csv`).
        public let ext: String
        /// The name this was parsed from, verbatim.
        ///
        /// ``isCanonical`` needs it: the parser tolerates a missing space after the dot, so
        /// `10.Oct 2011.pdf` decomposes exactly like the correctly spelled name, and comparing parts
        /// would call it canonical. Only the original text can tell.
        public let name: String

        public init(ordinal: Int, ordinalDigits: Int, month: Int?, day: Int? = nil, year: Int?,
                    body: String, ext: String, name: String) {
            self.ordinal = ordinal
            self.ordinalDigits = ordinalDigits
            self.month = month
            self.day = day
            self.year = year
            self.body = body
            self.ext = ext
            self.name = name
        }

        /// True for the summary slot: ordinal 0, whatever its body says. Its wording varies
        /// (`0. Summary 2022`, `00. 2014-2015 (1)`, `0. Spend 2019`), so the slot is told by its
        /// number, never its wording.
        public var isSummarySlot: Bool { ordinal == 0 }

        /// The name this file should have: its own body kept unless the body is only a month and
        /// a year.
        ///
        /// Rendering every dated name from its parts would delete what the body carries beyond the
        /// date:
        ///
        /// | On disk | Rendered from parts | What that loses |
        /// |---|---|---|
        /// | `1. Jun 2014 NRE.pdf` | `01. Jun 2014.pdf` | which of two accounts it is |
        /// | `01. Jan 2016 (Credit).pdf` | `01. Jan 2016.pdf` | that it is the credit, not the bill |
        /// | `11. Nov 2014 -2.pdf` | `11. Nov 2014.pdf` | the duplicate marker, landing on the original |
        ///
        /// So the month and year are respelled only when they are the entire body
        /// (`07. July 2016.pdf` → `07. Jul 2016.pdf`); anything else keeps its body verbatim and
        /// gets only the two-digit ordinal it was missing.
        public var canonicalName: String { canonicalName(ordinal: ordinal) }

        /// The same name at a different slot: what a renumbering writes. The body rule above
        /// matters more here, since a renumber touches files already correct:
        /// `1. Jun 2014 NRE.pdf` at slot 2 becomes `02. Jun 2014 NRE.pdf`, not `02. Jun 2014.pdf`.
        public func canonicalName(ordinal newOrdinal: Int) -> String {
            guard let month, let year, bodyIsBareDate else {
                return OrdinalMonthName.render(ordinal: newOrdinal, body: body, ext: ext)
            }
            return OrdinalMonthName.render(ordinal: newOrdinal, month: month, year: year, ext: ext)
        }

        /// True when the body is a month word and a four-digit year and nothing else.
        var bodyIsBareDate: Bool {
            let tokens = body.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            guard tokens.count == 2 else { return false }
            return OrdinalMonthName.monthIndex(tokens[0].lowercased()) != nil
                && tokens[1].count == 4 && tokens[1].allSatisfy(\.isNumber)
        }

        /// True when the name is already exactly what this pass would write.
        public var isCanonical: Bool { name == canonicalName }
    }

    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Full month names, lowercased, index 0 = January. Only for recognising a spelled-out month;
    /// the renderer always writes the three-letter abbreviation.
    static let monthFullNames = ["january", "february", "march", "april", "may", "june",
                                 "july", "august", "september", "october", "november", "december"]

    // MARK: Parse

    /// Decomposes `name` when it matches the ordinal grammar, else nil.
    ///
    /// Requires a leading 1- or 2-digit number followed by a dot. The space after the dot is
    /// optional, so a name like `10.Oct 2011.pdf` is parsed and fixed rather than left invisible.
    public static func parse(_ name: String) -> Parsed? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }

        var digits = ""
        var rest = Substring(stem)
        while let c = rest.first, c.isNumber, digits.count < 2 {
            digits.append(c)
            rest = rest.dropFirst()
        }
        // A third digit means this is not an ordinal: reading the typo `077. Jul 2020.pdf` as
        // ordinal 7 would silently "fix" a name whose real problem the pass can't see. Refusing to
        // parse reports it as unplaced instead.
        guard !digits.isEmpty, rest.first?.isNumber != true else { return nil }
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        // Optional single space (or any run of spaces) after the dot.
        let body = rest.drop(while: { $0 == " " })
        guard let ordinal = Int(digits) else { return nil }

        let (month, year) = monthAndYear(in: String(body))
        return Parsed(ordinal: ordinal, ordinalDigits: digits.count, month: month,
                      day: day(in: String(body), month: month, year: year), year: year,
                      body: String(body), ext: ext, name: name)
    }

    /// The day a `Mon DD YYYY` body names: only when the number sits between the month and the
    /// year, and only when the body names exactly one of each.
    ///
    /// The position rule keeps a form number from reading as a day: `N. Form I-20 - Mon YYYY.pdf`
    /// would otherwise be filed as the 20th of its month. Duplicate markers (`11. Nov 2014 -2.pdf`,
    /// `01. Jan 2016 (2).pdf`) are refused because nothing after the marker can be the year, not by
    /// either clause. Month-before and year-after are kept as a pair because together they spell
    /// the convention; one alone would widen the rule to "a small number next to a year", which
    /// nothing has checked.
    ///
    /// Accepts every shape the `ordinal-day` folders write: `Jan 15 2026`, `Jun 6 2019`,
    /// `Dec 01 2018`, `Jan 01 2019 (Labs)`, `Jun 21 2019 Sev`.
    ///
    /// Month-keyed folders never consult this; see ``SlotGranularity``.
    static func day(in body: String, month: Int?, year: Int?) -> Int? {
        guard month != nil, let year else { return nil }
        let tokens = body.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for (i, token) in tokens.enumerated() where i > 0 && i + 1 < tokens.count {
            guard monthIndex(String(tokens[i - 1]).lowercased()) != nil,
                  Int(tokens[i + 1]) == year, tokens[i + 1].count == 4,
                  (1...2).contains(token.count), token.allSatisfy(\.isNumber),
                  let d = Int(token), (1...31).contains(d)
            else { continue }
            return d
        }
        return nil
    }

    /// The month and year a conforming body names, when it names exactly one of each.
    ///
    /// `Apr 2025` and `April 2025` answer; `2014-2015 (1)` and `Summary 2022` give a year but no
    /// month, and `Apr 2009 - Mar 2010` gives neither: a body naming two months is a range, and a
    /// range has no single slot. That last case is why this counts matches instead of taking the
    /// first one.
    static func monthAndYear(in body: String) -> (month: Int?, year: Int?) {
        var months: [Int] = []
        var years: [Int] = []
        for token in body.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let lower = token.lowercased()
            if let m = monthIndex(lower) { months.append(m) }
            if token.count == 4, token.allSatisfy(\.isNumber), let y = Int(token),
               (1900...2199).contains(y) { years.append(y) }
        }
        let month = months.count == 1 ? months[0] : nil
        // A body may legitimately carry two years (`2014-2015`); that is a fiscal-year summary, and
        // it has no single year either.
        let year = years.count == 1 ? years[0] : nil
        return (month, year)
    }

    /// 1–12 for a lowercased month word, else nil. Accepts the three-letter abbreviation and the
    /// full name; `sept` is accepted because the tree uses it.
    static func monthIndex(_ lowercasedWord: String) -> Int? {
        if lowercasedWord == "sept" { return 9 }
        if let i = monthFullNames.firstIndex(of: lowercasedWord) { return i + 1 }
        guard lowercasedWord.count == 3 else { return nil }
        return monthAbbreviations.firstIndex { $0.lowercased() == lowercasedWord }.map { $0 + 1 }
    }

    // MARK: Render

    /// `Apr 2025`: the canonical body for a month and year.
    public static func body(month: Int, year: Int) -> String {
        "\(monthAbbreviations[month - 1]) \(year)"
    }

    /// `Apr 15 2025`: the canonical body for a day-keyed folder.
    ///
    /// The day is padded to two digits, as most single-digit days in the `ordinal-day` folders
    /// already are. Only a raw file placed for the first time gets this spelling: an existing name
    /// with a day is never `bodyIsBareDate`, so ``Parsed/canonicalName`` only widens its ordinal.
    public static func body(month: Int, day: Int, year: Int) -> String {
        String(format: "%@ %02d %d", monthAbbreviations[month - 1], day, year)
    }

    /// `09. May 15 2026.pdf`: the canonical name for a slot in a day-keyed folder.
    public static func render(ordinal: Int, month: Int, day: Int, year: Int, ext: String) -> String {
        render(ordinal: ordinal, body: body(month: month, day: day, year: year), ext: ext)
    }

    /// `04. Apr 2025.pdf`: the canonical name for a slot. Always two digits: a one-digit ordinal
    /// misorders past September (`10.` sorts before `9.`), which the convention exists to prevent.
    public static func render(ordinal: Int, month: Int, year: Int, ext: String) -> String {
        render(ordinal: ordinal, body: body(month: month, year: year), ext: ext)
    }

    /// `NN. <body>.ext`, for a body this grammar does not generate: a summary slot's wording, or a
    /// renumbering that must leave the tail exactly as the user wrote it.
    public static func render(ordinal: Int, body: String, ext: String) -> String {
        let stem = String(format: "%02d. %@", ordinal, body)
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
