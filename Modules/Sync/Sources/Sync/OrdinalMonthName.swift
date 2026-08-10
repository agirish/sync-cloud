import Foundation

/// The house convention `NN. Mon YYYY.ext` — parsing it, rendering it, and nothing else.
///
/// This is the one grammar the rename pass reads and writes. It is deliberately narrow: it does not
/// know where a file should go, which slot it should take, or whether renaming it is a good idea.
/// Those are ``RenamePlanner``'s questions, and keeping them out of here is what lets the grammar be
/// tested exhaustively against real names from the tree.
///
/// ## What counts as conforming
///
/// `04. Apr 2025.pdf` is the target shape. The parser is wider than the renderer on purpose, because
/// it has to recognise the tree's existing near-misses in order to fix them:
///
/// | On disk | Parsed | Why it is not already right |
/// |---|---|---|
/// | `04. Apr 2025.pdf` | ordinal 4, Apr 2025 | — it is right |
/// | `4. Apr 2025.pdf` | ordinal 4, Apr 2025 | one digit; misorders past September |
/// | `10.Oct 2011.pdf` | ordinal 10, Oct 2011 | no space after the dot |
/// | `04. April 2025.pdf` | ordinal 4, Apr 2025 | month spelled out |
///
/// **567 of the tree's 2,761 conforming files carry a one-digit ordinal**, which is the single
/// largest mechanical item in the backlog and the reason `ordinalDigits` is recorded rather than
/// discarded: a file that parses is not necessarily a file that is already named correctly.
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
        /// 1–31 when the body spells a day **between** its month and its year (`Jan 15 2026`), else
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
        /// Kept because ``isCanonical`` cannot be answered from the decomposed parts alone: the
        /// parser tolerates a missing space after the dot, so `10.Oct 2011.pdf` decomposes to
        /// ordinal 10 and body `Oct 2011` — **identical to the decomposition of the correctly
        /// spelled name.** Comparing parts said it was already canonical and the pass skipped the
        /// one file in the tree with that defect. The only sound test is against the original text.
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

        /// True when this is the summary slot — ordinal 0, whatever its body says.
        ///
        /// The tree writes it four ways (`0. Summary 2022`, `00. 2014-2015 (1)`, `0. 2022 Summary`,
        /// `0. Spend 2019`), so the slot is identified by its NUMBER and never by its wording.
        public var isSummarySlot: Bool { ordinal == 0 }

        /// The name this file should have — **its own body preserved unless the body is nothing but
        /// a month and a year.**
        ///
        /// The narrow rule is the whole point. A first cut rendered every dated name as
        /// `NN. Mon YYYY.ext` from the parsed parts, which silently *deleted* everything the body
        /// carried beyond the date. Run against the real tree it proposed:
        ///
        /// | On disk | Rendered from parts | What that loses |
        /// |---|---|---|
        /// | `1. Jun 2014 NRE.pdf` | `01. Jun 2014.pdf` | which of two accounts it is |
        /// | `01. Jan 2016 (Credit).pdf` | `01. Jan 2016.pdf` | that it is the credit, not the bill |
        /// | `11. Nov 2014 -2.pdf` | `11. Nov 2014.pdf` | the duplicate marker — and it lands on the
        /// original, which is the one collision this pass exists to avoid |
        ///
        /// Those three were caught by the collision guard only because the plain name happened to
        /// exist alongside; where it did not, the rename would have gone through and taken the
        /// distinction with it. So the month and year are only respelled when they are the *entire*
        /// body (`07. July 2016.pdf` → `07. Jul 2016.pdf`); anything else keeps its body verbatim and
        /// gets nothing but the two-digit ordinal it was missing.
        public var canonicalName: String { canonicalName(ordinal: ordinal) }

        /// The same name at a **different slot** — what a renumbering writes.
        ///
        /// The body rule above is unchanged and matters more here, not less: a renumber touches
        /// files that were already correct, so `1. Jun 2014 NRE.pdf` moving to slot 2 must become
        /// `02. Jun 2014 NRE.pdf` and not `02. Jun 2014.pdf`.
        public func canonicalName(ordinal newOrdinal: Int) -> String {
            guard let month, let year, bodyIsBareDate else {
                return OrdinalMonthName.render(ordinal: newOrdinal, body: body, ext: ext)
            }
            return OrdinalMonthName.render(ordinal: newOrdinal, month: month, year: year, ext: ext)
        }

        /// True when the body is a month word and a four-digit year and **nothing else**.
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

    /// Full month names, lowercased, index 0 = January. Used only for RECOGNISING a spelled-out
    /// month; the renderer always emits the three-letter abbreviation.
    static let monthFullNames = ["january", "february", "march", "april", "may", "june",
                                 "july", "august", "september", "october", "november", "december"]

    // MARK: Parse

    /// Decompose `name` when it matches the ordinal grammar, else nil.
    ///
    /// Requires a leading 1- or 2-digit number followed by a dot. The space after the dot is
    /// optional — `10.Oct 2011.pdf` really is in the tree and is a name this pass exists to fix, so
    /// refusing to parse it would make it invisible rather than fixed.
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
        // A THIRD digit means this is not an ordinal. `077. Jul 2020.pdf` is in the tree and is a
        // typo, but reading it as ordinal 7 with a stray leading zero would have the pass silently
        // "fix" a name whose real problem it cannot see. Refusing to parse reports it as unplaced
        // instead, which is the honest answer.
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

    /// The day a `Mon DD YYYY` body names — **only when the number sits between the month and the
    /// year**, and only when the body names exactly one of each.
    ///
    /// **Measured over the 3,681 parseable names in the tree**, against a reader that takes any
    /// 1–2-digit number in the body: 378 names to this one's 366, and the twelve it refuses are the
    /// six `N. Form I-20 - Mon YYYY.pdf` files, each of which would be filed as *the 20th* of its
    /// month because of the form number.
    ///
    /// Two things this rule is **not** doing, recorded because measuring said so and reasoning had
    /// said otherwise:
    ///
    /// - It is not what saves the duplicate markers. `11. Nov 2014 -2.pdf` and
    ///   `01. Jan 2016 (2).pdf` are refused because nothing follows the marker that could be the
    ///   year — the loop below needs a token on each side — not by either clause in the guard.
    /// - Neither clause is separable on this corpus. Removing *either* the month-before or the
    ///   year-after half alone changes no answer in 3,681 names; only removing both does. They are
    ///   kept as a pair because together they spell `Mon DD YYYY`, which is the convention itself,
    ///   and because dropping one widens the rule to "a small number next to a year" — a widening
    ///   whose correctness nothing here has measured.
    ///
    /// What it accepts is every shape the 24 `ordinal-day` folders write — `Jan 15 2026`,
    /// `Jun 6 2019`, `Dec 01 2018`, `Jan 01 2019 (Labs)`, `Jun 21 2019 Sev`.
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
    /// month, and `Apr 2009 - Mar 2010` gives NEITHER — a body naming two months is a range, and a
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

    /// `Apr 2025` — the canonical body for a month and year.
    public static func body(month: Int, year: Int) -> String {
        "\(monthAbbreviations[month - 1]) \(year)"
    }

    /// `Apr 15 2025` — the canonical body for a day-keyed folder.
    ///
    /// **The day is padded to two digits**, which is what 9 of the 12 single-digit days in the
    /// tree's `ordinal-day` folders already do. That is thin evidence and it is deliberately not
    /// leaned on: an existing name keeps its own body verbatim (a body carrying a day is never a
    /// `bodyIsBareDate`, so ``Parsed/canonicalName`` only ever widens its ordinal), so this spelling
    /// reaches nothing but a raw file being *placed* for the first time.
    public static func body(month: Int, day: Int, year: Int) -> String {
        String(format: "%@ %02d %d", monthAbbreviations[month - 1], day, year)
    }

    /// `09. May 15 2026.pdf` — the canonical name for a slot in a day-keyed folder.
    public static func render(ordinal: Int, month: Int, day: Int, year: Int, ext: String) -> String {
        render(ordinal: ordinal, body: body(month: month, day: day, year: year), ext: ext)
    }

    /// `04. Apr 2025.pdf` — the canonical name for a slot.
    ///
    /// **Always two digits.** The tree contains both widths and a one-digit ordinal misorders past
    /// September (`10.` sorts before `9.`), which is the entire point of the convention.
    public static func render(ordinal: Int, month: Int, year: Int, ext: String) -> String {
        render(ordinal: ordinal, body: body(month: month, year: year), ext: ext)
    }

    /// `NN. <body>.ext`, for a body this grammar does not generate — a summary slot's wording, or a
    /// re-numbering that must leave the tail exactly as the user wrote it.
    public static func render(ordinal: Int, body: String, ext: String) -> String {
        let stem = String(format: "%02d. %@", ordinal, body)
        return ext.isEmpty ? stem : stem + "." + ext
    }
}
