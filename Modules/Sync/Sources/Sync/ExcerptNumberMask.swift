import Foundation

/// Cuts the long numbers in page text to their endings, before the text leaves this Mac.
///
/// Refine with Claude sends the start of a file's first page so the model can tell what the
/// document is. A statement prints its account number there, and a tax form a taxpayer number. The
/// model needs a number's ending, since account folders are named by it (`Checking 9312`), and
/// never the rest. So a number goes as the app shows one: `••` and its last four digits.
///
/// Three kinds of number are cut:
/// - one the page labels as its account, loan, card, policy, member or contract number
///   (``DocumentFacts/ownNumbers(in:)``), when it has more than four digits;
/// - any run of ``longRun`` or more digits, hyphens inside it counted through
///   (`4829173650`, `123-45-6789`, `Z26-221746`), wherever it is and whatever it is called;
/// - a card number printed in groups (`4829 1736 5012 3456`), and a taxpayer number printed with
///   spaces (`123 45 6789`).
///
/// Left as printed: a date (`2026-03-31`, `03-31-2026`, `20260331`), a span of years (`2024-2026`),
/// an amount (`$1234567`, `Rs. 2500000`, `1234567.89`), a tax form's name beside its year
/// (`1099-2025`), and a number the page already masks (`XXXX XXXX XXXX 1833`). Anything shorter
/// than ``longRun`` digits with no label is left too: a year, a ZIP code, a form number, a page
/// count. So is a number mixed with letters whose digit runs are all short (`AB12CD34EF56`).
///
/// Erring toward a cut is the point. A phone number or a ZIP+4 loses its start, which costs a
/// folder choice nothing; a number left whole cannot be taken back.
enum ExcerptNumberMask {
    /// What stands for the digits cut from a number, as on a card: `••9312`.
    static let bullets = "••"
    /// The fewest digits an unlabelled run has before it is cut.
    static let longRun = 7

    /// A run of digits, hyphens joining its parts: `4829173650`, `3841-9312`, `2026-03-31`.
    private static let hyphenRun = try! NSRegularExpression(pattern: #"\d+(?:-\d+)*"#)
    /// A card number in groups of four, the last of them possibly shorter; American Express's
    /// four, six and five; a taxpayer number's three, two and four. One space or two between.
    private static let groupedNumber = try! NSRegularExpression(pattern:
        #"(?<![\d\-.,/])(?:\d{4} {1,2}\d{4} {1,2}\d{4}(?: {1,2}\d{1,4})?|\d{4} {1,2}\d{6} {1,2}\d{5}|\d{3} {1,2}\d{2} {1,2}\d{4})(?![\d\-/]|[.,]\d)"#)
    /// A currency's sign or letters just before a number: `$`, `Rs.`, `USD`.
    private static let currencyBefore = try! NSRegularExpression(pattern:
        #"(?:[$€£₹¥]|\b(?:usd|inr|eur|gbp|rs\.?)) ?$"#, options: [.caseInsensitive])
    /// The forms the tax pass names (`TaxLane`), which read as four digits beside a year.
    private static let taxForms: Set<String> = ["1040", "1095", "1098", "1099", "5498"]

    static func masked(_ text: String) -> String {
        // Matched on a copy where every Unicode dash reads as a hyphen, as `DocumentFacts` reads
        // them, and a tab or a no-break space as a space, which is how a PDF may print the gaps in
        // a card number. Each is one UTF-16 unit, so a range found there is the same range in `text`.
        let page = text.replacingOccurrences(of: "[\u{2010}-\u{2015}\u{2212}\u{FE58}\u{FE63}\u{FF0D}]", with: "-",
                                             options: .regularExpression)
            .replacingOccurrences(of: "[\t\u{00A0}\u{2007}\u{2009}\u{202F}]", with: " ", options: .regularExpression)
        let ns = page as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var cuts: [NSRange] = []

        // The numbers the page labels as its account's, however short and however spaced
        // (`Account Number 3841 9312`). Found by their digits, so the ending sent is the ending
        // filing matches on.
        for number in DocumentFacts.ownNumbers(in: page) where !number.masked && number.digits.count > 4 {
            let pattern = #"(?<!\d)"#
                + number.digits.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"[ \-]{0,3}"#)
                + #"(?!\d)"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            cuts += re.matches(in: page, range: whole).map(\.range)
        }
        for m in hyphenRun.matches(in: page, range: whole) where isLongNumber(ns, m.range) {
            cuts.append(m.range)
        }
        for m in groupedNumber.matches(in: page, range: whole) {
            let groups = ns.substring(with: m.range).split(separator: " ").map(String.init)
            if !groups.allSatisfy(isYearOrForm) { cuts.append(m.range) }
        }
        guard !cuts.isEmpty else { return text }

        // Overlapping cuts become one, then each is replaced from the end so earlier ranges hold.
        var merged: [NSRange] = []
        for range in cuts.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        let out = NSMutableString(string: text)
        for range in merged.reversed() {
            let digits = ns.substring(with: range).filter(\.isNumber)
            out.replaceCharacters(in: range, with: bullets + String(digits.suffix(4)))
        }
        return out as String
    }

    /// Whether the hyphen-joined run at `range` is a number to cut: long, and not a date, a span of
    /// years, a form beside its year, or an amount.
    private static func isLongNumber(_ ns: NSString, _ range: NSRange) -> Bool {
        let parts = ns.substring(with: range).split(separator: "-").map(String.init)
        guard parts.reduce(0, { $0 + $1.count }) >= longRun else { return false }
        if parts.allSatisfy(isYearOrForm) || isDates(parts) { return false }
        if parts.count == 1 {
            if parts[0].count == 8, isDate(year: String(parts[0].prefix(4)), month: String(parts[0].dropFirst(4).prefix(2)),
                                           day: String(parts[0].suffix(2))) { return false }
            if isAmount(ns, range) { return false }
        }
        return true
    }

    private static func isYearOrForm(_ part: String) -> Bool {
        DocumentFacts.isYear(part) || taxForms.contains(part)
    }

    /// One date or several on end (`2026-03-01-2026-03-31`): year first, or day and month first.
    private static func isDates(_ parts: [String]) -> Bool {
        guard !parts.isEmpty, parts.count % 3 == 0 else { return false }
        return stride(from: 0, to: parts.count, by: 3).allSatisfy { i in
            let (a, b, c) = (parts[i], parts[i + 1], parts[i + 2])
            if a.count == 4 { return b.count <= 2 && c.count <= 2 && isDate(year: a, month: b, day: c) }
            // `03-31-2026` or `31-03-2026`: which is the month is the reader's to know.
            guard a.count <= 2, b.count <= 2, c.count == 2 || DocumentFacts.isYear(c) else { return false }
            return isDate(year: c, month: a, day: b) || isDate(year: c, month: b, day: a)
        }
    }

    private static func isDate(year: String, month: String, day: String) -> Bool {
        guard year.count == 2 || DocumentFacts.isYear(year), let m = Int(month), let d = Int(day) else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }

    /// A run with a currency before it (`$1234567`, `Rs. 2500000`) or cents after it
    /// (`1234567.89`, `1234567,89`). A comma or a full stop with anything else after it ends a
    /// number: `4829173650,4829173651` is two. Digits after a decimal point get no pass, since an
    /// account printed in dotted parts (`0012.4829173650`) reads the same.
    private static func isAmount(_ ns: NSString, _ range: NSRange) -> Bool {
        func isDigit(_ i: Int) -> Bool { i < ns.length && (0x30...0x39).contains(ns.character(at: i)) }
        let end = NSMaxRange(range)
        if end < ns.length, ".,".utf16.contains(ns.character(at: end)), isDigit(end + 1),
           !isDigit(end + 2) || !isDigit(end + 3) { return true }
        let before = ns.substring(with: NSRange(location: max(0, range.location - 6), length: min(6, range.location)))
        return currencyBefore.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
    }
}
