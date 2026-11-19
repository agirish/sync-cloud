import Foundation

// Account identity: which account folder a statement belongs to, from the number the statement
// prints for itself, matched by its ending to digits in the account folder's own name. Learned from
// the tree, never from a list of banks. Measured on a real tree before it was written (design §3):
// on 194 downloaded statements, 18 of 29 accounts placed at High with none wrong; on 957 filed
// PDFs, the Highs that disagree with where a document sits are inboxes and misfiles.

/// What page 1 says about itself, read without a model. Generic English labels only (`Account
/// Number`, `Statement Period`, `Form 1099`): no institution or document is named anywhere here.
public struct DocumentFacts: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case statement, taxForm, other }

    /// A number the page prints as its own account's: after an account-number label, or masked.
    public struct OwnNumber: Sendable, Equatable, Hashable {
        public let digits: String
        public let masked: Bool
        /// Printed after an account-number label, rather than found masked somewhere on the page.
        public var labelled: Bool = true
        /// The last four digits, as printed: what a card shows (••7863) and what is learned.
        public var ending: String { String(digits.suffix(4)) }
    }

    public let ownNumbers: [OwnNumber]
    public let kind: Kind
    /// The statement's period end, when page 1 labels one (`Statement Period March 1-31, 2026`,
    /// `Closing Date 01/27/2026`, `through`). Due, payment, maturity, vest and trust dates are not
    /// periods. `day` is nil when only a month is known.
    public let period: Period?
    /// Where that period began, when page 1 prints it as a range (`02/01/2026 - 02/28/2026`): what
    /// tells a quarterly statement (`Jan-Mar 2026`) from a monthly one. nil for a single date.
    public let periodStart: Period?
    /// The page lower-cased, and its first 1,000 characters: the header an institution is read from.
    let text: String
    let header: String
    /// Page 1's first line of words, as printed, at most 80 characters: what a card shows for a
    /// document whose kind and date it can't name. nil for a page with no words.
    public let firstLine: String?

    public struct Period: Sendable, Equatable, Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int?
        public init(year: Int, month: Int, day: Int? = nil) { self.year = year; self.month = month; self.day = day }
        public static func < (a: Period, b: Period) -> Bool {
            (a.year, a.month, a.day ?? 0) < (b.year, b.month, b.day ?? 0)
        }
        var monthIndex: Int { year * 12 + month }
    }

    public init(page: String) {
        let lower = page.lowercased()
        text = lower
        header = String(lower.prefix(1000))
        firstLine = Self.firstLine(of: page)
        ownNumbers = Self.ownNumbers(in: page)
        kind = Self.kind(of: lower)
        let range = kind == .taxForm ? nil : Self.statementRange(in: page)
        period = kind == .taxForm ? Self.taxYear(in: lower).map { Period(year: $0, month: 12, day: 31) } : range?.end
        periodStart = range?.start
    }

    /// The first line holding a letter, its spaces collapsed, cut at a word near 80 characters.
    static func firstLine(of page: String) -> String? {
        for raw in page.split(whereSeparator: \.isNewline).prefix(40) {
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard line.contains(where: \.isLetter) else { continue }
            guard line.count > 80 else { return line }
            let cut = line.prefix(80)
            return String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut) + "…"
        }
        return nil
    }

    // MARK: Own numbers

    private static let label = try! NSRegularExpression(pattern:
        #"\b(?:(?:account|acct|loan|card|policy|member|contract)\b(?:[^|\n]{0,12}?|[ \t]*\n[ \t]*)(?:\bnumber|\bno\b\.?|#)(?:\s*ending\s*in)?|account\s*(?:ending(?:\s*in)?|#)|ending\s+in|(?:account|acct)\s*(?=:))[\s:#.()]*"#,
        options: [.caseInsensitive])
    private static let numberAfterLabel = try! NSRegularExpression(pattern: #"^[Xx\*•]{0,24}[\dXx\*•][\dXx\*• \-]{1,24}\d"#)
    /// A masked run (`XXXX XXXX XXXX 1768`, `******4121`, `XXXX-XXXXX6-22002`), bounded so a page of
    /// asterisks can't make the match backtrack for seconds.
    private static let maskedAnywhere = try! NSRegularExpression(pattern:
        #"(?<![\w*•])[Xx\*•]{3,24}+(?:[ \-]{0,2}+[Xx\*•\d]{1,8}+){0,6}+"#)
    private static let ssnMask = try! NSRegularExpression(pattern: #"[Xx\*•]{3}[- ][Xx\*•]{2}[- ]\d{4}"#)
    private static let routingLabel = try! NSRegularExpression(pattern: #"\b(?:routing|aba|rtn|transit)\b"#, options: [.caseInsensitive])
    /// The person's number, not an account's.
    private static let taxpayerWords = try! NSRegularExpression(pattern: #"\b(?:tin|ssn|social|taxpayer)\b"#, options: [.caseInsensitive])
    /// A number named on a payment or transfer line belongs to the other account
    /// (`AutoPay from account ending in 5696`, `Transfer to account number 4121`).
    /// Payment and transfer phrases, not a bare "from" (`Statement From 01/01 To 01/31`).
    private static let otherAccountWords = try! NSRegularExpression(pattern:
        #"\b(?:auto[- ]?pay|transfer(?:red|s)?|linked|(?:paid|payments?|debit(?:ed)?|deposit(?:ed)?|fund(?:ed|ing)?|draft(?:ed)?)\s+(?:from|to|into)|from\s+(?:your\s+)?(?:account|acct|checking|savings))\b"#,
        options: [.caseInsensitive])

    static func ownNumbers(in page: String) -> [OwnNumber] {
        // A Unicode minus or other dash (`711840407−01`) reads as the hyphen it stands for, so a
        // number splits the same way however the bank's PDF printed it. One UTF-16 unit each, so
        // offsets are unchanged.
        let page = page.replacingOccurrences(of: "[\u{2010}-\u{2015}\u{2212}\u{FE58}\u{FE63}\u{FF0D}]", with: "-",
                                             options: .regularExpression)
        let ns = page as NSString
        var out: [OwnNumber] = []
        var seen = Set<String>()
        func add(_ raw: String, at location: Int, labelled: Bool) {
            let masked = raw.contains(where: { "Xx*•".contains($0) })
            let digits = raw.filter(\.isNumber)
            // A masked ending that reads like a year (`**** 1917`) is still an ending.
            guard digits.count >= 3, masked || !isYear(digits), !seen.contains(digits) else { return }
            // A routing number is printed with its label; an unlabelled nine digits may well be the
            // account's own.
            if !labelled, passesRoutingChecksum(digits) {
                let before = ns.substring(with: NSRange(location: max(0, location - 40), length: min(40, location)))
                if routingLabel.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { return }
            }
            seen.insert(digits)
            out.append(OwnNumber(digits: digits, masked: masked, labelled: labelled))
        }
        for m in label.matches(in: page, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 12),
                                                    length: min(12, m.range.location))).lowercased()
            // A taxpayer number is the person's, not the account's.
            if taxpayerWords.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
            // The same line, before the label: a payment or transfer names another account.
            if onPaymentLine(ns, before: m.range.location) { continue }
            let end = m.range.location + m.range.length
            var after = ns.substring(with: NSRange(location: end, length: min(60, ns.length - end)))
            // The value may sit on the next line (`Account Number\n3841-7863`) or carry one letter
            // of prefix (`Z26-141750`).
            after = String(after.drop(while: { $0.isWhitespace || $0 == "|" || $0 == ":" }))
            let raw0 = ns.substring(with: NSRange(location: end, length: min(60, ns.length - end)))
            // The label's own trailing whitespace may hold the line break (`Account Number:\n…`).
            let labelTail = ns.substring(with: m.range).reversed().prefix { !$0.isLetter && $0 != "#" && $0 != ")" }
            let crossedLine = labelTail.contains("\n") || raw0.prefix { $0.isWhitespace || $0 == "|" || $0 == ":" }.contains("\n")
            if let first = after.first, first.isLetter, first.isASCII,
               after.dropFirst().first?.isNumber == true { after = String(after.dropFirst()) }
            let a = after as NSString
            if let n = numberAfterLabel.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) {
                var groups = a.substring(with: n.range).split(separator: " ").map(String.init)
                let next = n.range.location + n.range.length
                let nextChar = next < a.length ? a.substring(with: NSRange(location: next, length: 1)) : ""
                // The last group ran into what follows: a date (`03/31/2026`, `2026-03-31`), an
                // amount's first digits (`1,234.56`), a page count (`2 of 6`).
                if groups.count > 1, let last = groups.last {
                    let digits = last.filter(\.isNumber)
                    let intoDate = nextChar == "/" || last.range(of: #"^\d{4}-\d{2}"#, options: .regularExpression) != nil
                        || (DocumentFacts.isYear(digits) && nextChar == "-")
                    let following = next + 1 < a.length ? a.substring(with: NSRange(location: next + 1, length: 1)) : ""
                    let intoAmount = (nextChar == "," || nextChar == ".") && following.first?.isNumber == true && digits.count <= 3
                    if intoDate || intoAmount || digits.count < 3 { groups.removeLast() }
                }
                // Then any stray short run left at the end (`3841-7863 2`).
                while groups.count > 1, let last = groups.last, last.filter(\.isNumber).count < 3 { groups.removeLast() }
                let raw = groups.joined(separator: " ")
                // A value on the next line must be the line's own (`Account Number\n3841-7863`),
                // not the start of an address (`73210 VIA VICENZA`).
                // A short number with words after it on its own line is a street address; an account
                // number is longer (`000012345678 DRE …` is still the account's).
                if crossedLine, raw.filter(\.isNumber).count <= 6 {
                    let rest = a.substring(from: n.range.location + n.range.length)
                    let restOfLine = rest.prefix { $0 != "\n" }
                    if restOfLine.trimmingCharacters(in: .whitespaces).first?.isLetter == true { continue }
                }
                // `Account: 401(k) Plan`: a plan's name, not a number.
                if let c = (a.length > next ? a.substring(with: NSRange(location: next, length: 1)) : "").first,
                   c == "(" || c.isLetter { continue }
                add(raw.trimmingCharacters(in: .whitespaces), at: m.range.location, labelled: true)
            }
        }
        let head = String(page.prefix(2500)) as NSString
        for m in maskedAnywhere.matches(in: head as String, range: NSRange(location: 0, length: head.length)) {
            var s = head.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            // A taxpayer mask (`XXX-XX-7396`) inside the run is the person's: cut it out.
            s = ssnMask.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            guard (s.reversed().prefix { $0.isNumber }).count >= 3 || s.filter(\.isNumber).count >= 3 else { continue }
            // `AutoPay from account ending in ****4121`: another account's, masked or not.
            if onPaymentLine(head, before: m.range.location) { continue }
            add(s, at: m.range.location, labelled: false)
        }
        return out
    }

    /// Whether the line holding `location`, up to 60 characters before it, is a payment or
    /// transfer line naming another account.
    static func onPaymentLine(_ ns: NSString, before location: Int) -> Bool {
        let lineStart = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location)).location
        let from = lineStart == NSNotFound ? max(0, location - 60) : max(lineStart + 1, location - 60)
        let line = ns.substring(with: NSRange(location: from, length: location - from))
        return otherAccountWords.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// The numbers to match an account by: the labelled ones when the page has any, since a page
    /// that names its own account number and also a masked one is naming that other account in
    /// passing (`transfer to DISCOVER BANK SAV account ******4121`).
    var matchingNumbers: [OwnNumber] {
        let labelled = ownNumbers.filter(\.labelled)
        return labelled.isEmpty ? ownNumbers : labelled
    }

    static func isYear(_ digits: String) -> Bool {
        digits.count == 4 && (digits.hasPrefix("19") || digits.hasPrefix("20"))
    }

    /// A US bank routing number: nine digits passing the ABA checksum. Printed on checking
    /// statements, never the account's own number.
    static func passesRoutingChecksum(_ d: String) -> Bool {
        guard d.count == 9 else { return false }
        let w = [3, 7, 1, 3, 7, 1, 3, 7, 1]
        return zip(d, w).reduce(0) { $0 + (Int(String($1.0)) ?? 0) * $1.1 } % 10 == 0
    }

    // MARK: Kind and period

    private static let monthRE = #"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    /// `03/31/2026`, `31/03/2026`, `2026-03-31`, `04-26-13`, `March 31, 2026`, `March 1-31, 2026`,
    /// `31 March 2026`, `31-Mar-2026`.
    static let dateRE = #"(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}-\d{1,2}-\d{2,4}(?!\d)|\d{1,2}[ -]"# + monthRE + #"[a-z]*\.?[ -]\d{4}|"# + monthRE + #"[a-z]*\.? \d{1,2}(?:\s*-\s*\d{1,2})?,? \d{4})"#
    private static let taxRE = try! NSRegularExpression(pattern: #"form\s*(1099|1098|5498|w-2)|tax year \d{4}"#)
    private static let statementWordsRE = try! NSRegularExpression(pattern:
        #"statement period|billing period|statement date|closing date|opening/closing|statement closing|account summary|summary of your account"#)
    private static let rangeRE = try! NSRegularExpression(pattern: dateRE + #"[\s|]*(?:to|through|thru|-|–|—|ending)[\s|:]*"# + dateRE)
    private static let monthDayRangeRE = try! NSRegularExpression(pattern: #"\b"# + monthRE + #"[a-z]* \d{1,2}\s*-\s*\d{1,2}, \d{4}"#)
    /// `May 29 - June 28, 2016`: two months and days, the year printed once, at the end.
    private static let monthToMonthRE = try! NSRegularExpression(pattern:
        #"\b("# + monthRE + #")[a-z]*\.? (\d{1,2})\s*[-–—]\s*("# + monthRE + #")[a-z]*\.? (\d{1,2}),? (\d{4})"#)

    static func kind(of lower: String) -> Kind {
        // A form names itself at the top; a statement saying "your 2025 Form 1099 is available"
        // further down is still a statement.
        if namesItselfATaxForm(String(lower.prefix(300))) { return .taxForm }
        let statement = matches(statementWordsRE, lower) || matches(rangeRE, lower) || matches(monthDayRangeRE, lower)
        if statement { return .statement }
        // A page printing what it opened and closed at (Apple Card names neither a period nor a
        // closing date: `Dec 1 — Dec 31, 2025`, `Previous Total Balance`, `Total Balance`).
        let balances = BalanceChain.balances(in: lower)
        if !balances.opening.isEmpty, !balances.closing.isEmpty { return .statement }
        if namesItselfATaxForm(String(lower.prefix(800))) { return .taxForm }
        return .other
    }

    /// A tax form's own title, not a notice that one is ready (`Your 2025 Form 1099 is now
    /// available`).
    static func namesItselfATaxForm(_ text: String) -> Bool {
        let ns = text as NSString
        for m in taxRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let after = ns.substring(with: NSRange(location: m.range.location, length: min(60, ns.length - m.range.location)))
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 20), length: min(20, m.range.location)))
            _ = before
            if after.range(of: #"\b(?:is|are)\s+(?:now\s+)?(?:available|ready|online)\b"#, options: .regularExpression) != nil { continue }
            return true
        }
        return false
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static let taxYearRE = try! NSRegularExpression(pattern: #"tax year (\d{4})|(\d{4})\s*form\s*(?:1099|1098|5498|w-2)|form\s*(?:1099|1098|5498|w-2)[^0-9]{0,40}(\d{4})"#)

    static func taxYear(in lower: String) -> Int? {
        let ns = lower as NSString
        for m in taxYearRE.matches(in: lower, range: NSRange(location: 0, length: min(ns.length, 1500))) {
            for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
                if let y = Int(ns.substring(with: m.range(at: i))), (1990...2100).contains(y) { return y }
            }
        }
        return nil
    }

    /// Dates the page labels as something other than the period, matched as words ("vest" is not
    /// in "investment"). An insurer's policy term runs a year ahead of the bill it is printed on. A
    /// year-to-date range is the year's, never the statement's, whatever it is printed beside.
    private static let nonPeriodLabel = try! NSRegularExpression(pattern:
        #"\b(?:due|payments?|year[\s-]+to[\s-]+date|ytd|(?:policy|coverage)\s+(?:term|period)|maturity|vest(?:ed|ing)?|dtd|dated|expir\w*|born|since|previous|prior|(?:beginning|opening)(?:\s+\w+)?\s+(?:balance|value))\b"#, options: [.caseInsensitive])
    private static let periodLabel = try! NSRegularExpression(pattern:
        #"\b(?:statement|billing|period|cycle)\b"#, options: [.caseInsensitive])
    /// A date the page names as its statement's (`Closing Date`, `Statement Date`, `Period Ending`).
    /// Whole words: a bare `ending` inside `pending` or `spending` labels nothing.
    private static let labelledDateRE = try! NSRegularExpression(pattern:
        #"\b(?:closing date|statement date|statement closing date|period ending|period end|ending)[\s:|]*("# + dateRE + ")")
    /// A date after a weaker word (`through October 31, 2026`, `as of 01/31/2026`): tried after
    /// every range, since a balance's date is printed "as of" too.
    private static let weakDateRE = try! NSRegularExpression(pattern:
        #"(?:through|thru|as of)[\s:|]*("# + dateRE + ")")
    /// What joins a range's two dates.
    private static let rangeJoiner = try! NSRegularExpression(pattern: #"^[\s|]*(?:to|through|thru|-|–|—)[\s|:]*"#)
    private static let numericDateRE = try! NSRegularExpression(pattern: #"^(\d{1,2})([/-])(\d{1,2})\2(\d{2,4})"#)

    /// The period end: the end of a labelled range, else a date after a period label. Every
    /// candidate is checked against the few words before it.
    static func statementPeriod(in page: String) -> Period? { statementRange(in: page)?.end }

    /// The period, with its start when the page prints one: the first range it prints wins.
    static func statementRange(in page: String) -> (start: Period?, end: Period)? {
        let lower = page.lowercased()
        let ns = lower as NSString
        func labelBefore(_ loc: Int) -> String { ns.substring(with: NSRange(location: max(0, loc - 30), length: min(30, loc))) }
        func rejected(_ loc: Int) -> Bool {
            let l = labelBefore(loc)
            return nonPeriodLabel.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        func labelled(_ loc: Int) -> Bool {
            let l = labelBefore(loc)
            return periodLabel.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        // A range the page labels as its period (`Statement Period 02/01/2026 - 02/28/2026`), first.
        for m in rangeRE.matches(in: lower, range: NSRange(location: 0, length: ns.length))
        where labelled(m.range.location) && !rejected(m.range.location) {
            let s = ns.substring(with: m.range)
            let dates = matchesOf(dateRE, in: s)
            if let last = dates.last, let p = parseDate(last, endOfRange: true) {
                return (dates.first.flatMap { parseDate($0) }, p)
            }
        }
        // A date the page labels (`Closing Date 01/27/2026`, `Statement Date: 10/15/2026`) next:
        // ahead of any range it merely prints (`0% APR 01/15/2025 through 01/15/2027`).
        for m in labelledDateRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            // A labelled range (`Opening/Closing Date 12/29/25 - 01/28/26`): its end.
            let end = m.range(at: 1).location + m.range(at: 1).length
            let rest = ns.substring(from: end)
            if let j = rangeJoiner.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                let afterJoiner = (rest as NSString).substring(from: j.range.length)
                if let second = matchesOf("^" + dateRE, in: afterJoiner).first, let p = parseDate(second, endOfRange: true) {
                    return (parseDate(ns.substring(with: m.range(at: 1))), p)
                }
            }
            if let p = parseDate(ns.substring(with: m.range(at: 1))) { return (nil, p) }
        }
        // `March 1-31, 2026`: a month with a day range.
        for m in monthDayRangeRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            let raw = ns.substring(with: m.range)
            if let p = parseDate(raw, endOfRange: true) { return (parseDate(raw), p) }
        }
        // `May 29 - June 28, 2016`: the year once, at the end; a start month after the end month
        // is the year before.
        for m in monthToMonthRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            func int(_ i: Int) -> Int? { Int(ns.substring(with: m.range(at: i))) }
            guard let m1 = FilingPeriod.month(of: ns.substring(with: m.range(at: 1))),
                  let m2 = FilingPeriod.month(of: ns.substring(with: m.range(at: 3))),
                  let d1 = int(2), let d2 = int(4), let year = int(5), (1990...2100).contains(year),
                  (1...31).contains(d1), (1...31).contains(d2) else { continue }
            return (Period(year: m1 > m2 ? year - 1 : year, month: m1, day: d1), Period(year: year, month: m2, day: d2))
        }
        // `February 26, 2026 to March 27, 2026`, `12/28/2025 - 01/27/2026`: the second date.
        for m in rangeRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            // The range's second date, whatever joins them (`to`, `through`, a dash).
            let s = ns.substring(with: m.range)
            let dates = matchesOf(dateRE, in: s)
            if let last = dates.last, let p = parseDate(last, endOfRange: true) {
                return (dates.first.flatMap { parseDate($0) }, p)
            }
        }
        // `through October 31, 2026`, `as of 01/31/2026`: last, behind any range.
        for m in weakDateRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            if let p = parseDate(ns.substring(with: m.range(at: 1))) { return (nil, p) }
        }
        return nil
    }

    private static let compiled = RegexCache()
    private static func matchesOf(_ pattern: String, in s: String) -> [String] {
        let re = compiled.regex(pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// `03/31/2026`, `03/31/26`, `March 31, 2026`, `March 1-31, 2026` (the range's end).
    static func parseDate(_ raw: String, endOfRange: Bool = false) -> Period? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sn = s as NSString
        if let iso = s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let p = s[iso].split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, (1990...2100).contains(p[0]), (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
            return Period(year: p[0], month: p[1], day: p[2])
        }
        if let m = numericDateRE.firstMatch(in: s, range: NSRange(location: 0, length: sn.length)) {
            let n = sn.substring(with: m.range)
            var p = n.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            // Month first, as US statements print it; day first when that is the only reading
            // (`31/03/2026`).
            if !(1...12).contains(p[0]), (1...12).contains(p[1]) { p.swapAt(0, 1) }
            guard (1...12).contains(p[0]), (1...31).contains(p[1]) else { return nil }
            let year = p[2] < 100 ? 2000 + p[2] : p[2]
            return (1990...2100).contains(year) ? Period(year: year, month: p[0], day: p[1]) : nil
        }
        var words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // `31 March 2026`, `31-Mar-2026`: the day first.
        var leadingDay: Int?
        if words.count >= 3, let d = Int(words[0]), (1...31).contains(d), FilingPeriod.month(of: words[1]) != nil {
            leadingDay = d
            words.removeFirst()
        }
        guard let first = words.first, let month = FilingPeriod.month(of: first) else { return nil }
        if let leadingDay, let year = words.dropFirst().compactMap({ Int($0) }).last, (1990...2100).contains(year) {
            return Period(year: year, month: month, day: leadingDay)
        }
        let numbers = words.dropFirst().compactMap { Int($0) }
        guard let year = numbers.last, (1990...2100).contains(year) else { return nil }
        let days = numbers.dropLast().filter { (1...31).contains($0) }
        return Period(year: year, month: month, day: endOfRange ? days.last : days.first)
    }
}

// MARK: - The account index

/// Every account folder in a walked tree, what identifies it, and the institution it belongs to.
/// Built once per scan from folder and file names alone (tier 2 of design §3); identities learned
/// from filed statements and from his corrections (tiers 1 and 3) are added by the caller.
public struct AccountIndex: Sendable {

    public struct Account: Sendable, Equatable {
        /// Relative to the walked root.
        public let root: String
        /// Endings that identify it: the digit runs of its own name, or endings learned.
        public let identities: [String]
        /// The institution's normalized name (`charles schwab`), merged across categories.
        public let institution: String
        /// The institution folder's own name, for display (`Charles Schwab`, `HDFC Bank`).
        public var institutionName: String = ""
        /// Under an archive folder (`…/Charles Schwab/Archive/Roth IRA Automated 2336`).
        public let archived: Bool
    }

    public let accounts: [Account]
    /// Institution name → the words that name it on a page.
    public let institutionTokens: [String: [String]]
    /// Words in many of the tree's folder names (`statements`, `credit`, `2026`): never what names
    /// an institution.
    var genericWords: Set<String> = []

    init(accounts: [Account], institutionTokens: [String: [String]], genericWords: Set<String> = []) {
        self.accounts = accounts
        self.institutionTokens = institutionTokens
        self.genericWords = genericWords
    }

    public var isEmpty: Bool { accounts.isEmpty }

    /// A digit run naming an account in a folder's own name: three or more digits, not a year, not
    /// a `NN.` month prefix, not a form number (`Form 1099-B`).
    /// A folder named like an account (`Credit 4321`, `Credit 4321 (Shweta)`) beside one that
    /// already is one, before it holds statements of its own: the card he made a folder for when
    /// it arrived. Its own name says what it is, and a sibling account says where accounts live.
    static func isNewAccountFolder(_ node: FileNode, siblings: [FileNode]) -> Bool {
        guard node.name.range(of: #"^[A-Za-z][A-Za-z0-9&'. ]* \d{3,6}(?: \([^()]+\))?$"#, options: .regularExpression) != nil,
              !node.name.hasPrefix("Form ") else { return false }
        return siblings.contains { s in
            s.id != node.id && !accountDigits(inFolderNamed: s.name).isEmpty && StatementFamily.hasRegularFamily(below: s)
        }
    }

    static func accountDigits(inFolderNamed name: String) -> [String] {
        if name.range(of: #"^\d{1,2}\. "#, options: .regularExpression) != nil { return [] }
        let lower = name.lowercased()
        var out: [String] = []
        let ns = lower as NSString
        for m in digitRuns.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: m.range)
            // A year-like run is a year (`Statements 2024`), even where it might be an account.
            guard run.count >= 3, !DocumentFacts.isYear(run) else { continue }
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 5), length: min(5, m.range.location)))
            if before.hasSuffix("form ") || before.hasSuffix("form") { continue }
            out.append(run)
        }
        return out
    }

    private static let digitRuns = try! NSRegularExpression(pattern: #"\d+"#)

    /// `Archive`, `Archives`, `Archived`.
    static func isArchiveName(_ name: String) -> Bool { ["archive", "archives", "archived"].contains(name.lowercased()) }

    /// A folder below `node`, not a year or month, whose own name carries account digits and that
    /// holds a regular statement family.
    static func hasNamedAccountBelow(_ node: FileNode) -> Bool {
        for child in node.children ?? [] where child.isDirectory {
            if FolderProfileEntry.looksLikeYear(child.name) || FilingPeriod.monthSlot(ofFolderNamed: child.name) != nil { continue }
            if !accountDigits(inFolderNamed: child.name).isEmpty, StatementFamily.hasRegularFamily(below: child) { return true }
            if hasNamedAccountBelow(child) { return true }
        }
        return false
    }

    /// Builds the index from a walked tree. `isArchived` answers from the survey's profile (role or
    /// lifecycle axis); a folder named `Archive` counts either way.
    public static func build(tree: [FileNode],
                             isArchived: (String) -> Bool = { _ in false },
                             isInbox: (String) -> Bool = { FolderProfile.isInboxPath($0) }) -> AccountIndex {
        var named: [(path: String, digits: [String])] = []
        func visit(_ node: FileNode, _ rel: String, siblings: [FileNode]) {
            guard node.isDirectory else { return }
            if !rel.isEmpty, !isInbox(rel) {
                let digits = accountDigits(inFolderNamed: node.name)
                // The highest such folder is the account; below it are its years. Unless a folder
                // below carries account digits of its own (`401k/Fidelity 4138`): then this one is
                // a category, and the accounts are below it.
                if !digits.isEmpty, StatementFamily.hasRegularFamily(below: node) || isNewAccountFolder(node, siblings: siblings),
                   !Self.hasNamedAccountBelow(node) {
                    named.append((rel, digits))
                    return
                }
            }
            let children = (node.children ?? []).filter(\.isDirectory)
            for child in children {
                visit(child, rel.isEmpty ? child.name : rel + "/" + child.name, siblings: children)
            }
        }
        for node in tree { visit(node, node.name, siblings: tree.filter(\.isDirectory)) }
        // How many folder names each word appears in.
        var df: [String: Int] = [:]
        func count(_ nodes: [FileNode]) {
            for n in nodes where n.isDirectory {
                for w in Set(words(n.name)) { df[w, default: 0] += 1 }
                count(n.children ?? [])
            }
        }
        count(tree)
        let generic = Set(df.filter { $0.value >= 8 }.keys)
        var accounts: [Account] = []
        var categoryWords: [String: Set<String>] = [:]
        var flatWords: [String: Set<String>] = [:]
        for (path, digits) in named {
            // A flat tree names the bank in the account folder itself (`Chase Checking 1234`):
            // its own words, less the generic ones (`checking`), when no bank folder is above it
            // or the only one is a top-level category (`Finance`).
            let leaf = (path as NSString).lastPathComponent
            let ownWords = words(leaf).filter { !$0.contains(where: \.isNumber) && !generic.contains($0) && !stopWords.contains($0) && $0.count >= 3 }
            let found = institutionFolder(of: path, isArchived: isArchived)
            // No bank folder above it at all (`Documents/Chase Checking 1234`): its own words.
            if !ownWords.isEmpty, found == nil {
                let name = ownWords.joined(separator: " ")
                var account = Account(root: path, identities: digits, institution: name, archived: false)
                account.institutionName = leaf.split(separator: " ").filter { w in ownWords.contains(w.lowercased()) }.joined(separator: " ")
                accounts.append(account)
                categoryWords[name, default: []].formUnion(path.split(separator: "/").dropLast().flatMap { words(String($0)) })
                continue
            }
            // Only a top-level folder above it (`Finance/Chase Checking 1234`, or a bank at the top,
            // `Chase/Sapphire Reserve 1234`): which is the bank, the page decides. The folder stays
            // the account's bank, and the account folder's own words name it too.
            let leafWords = words(leaf).filter { !$0.contains(where: \.isNumber) }
            if !ownWords.isEmpty, let (top, archived) = found, !top.contains("/"), leafWords.count >= 2 {
                let name = top.lowercased()
                flatWords[name, default: []].formUnion(ownWords)
                var account = Account(root: path, identities: digits, institution: name, archived: archived)
                account.institutionName = top
                accounts.append(account)
                continue
            }
            guard let (institutionFolder, archived) = found else { continue }
            let components = institutionFolder.split(separator: "/").map(String.init)
            let name = components.last!.lowercased()
            categoryWords[name, default: []].formUnion(components.dropLast().flatMap(words))
            var account = Account(root: path, identities: digits, institution: name, archived: archived)
            account.institutionName = components.last!
            accounts.append(account)
        }
        var tokens: [String: [String]] = [:]
        for (name, cats) in categoryWords {
            tokens[name] = words(name).filter { !cats.contains($0) && !stopWords.contains($0) && !generic.contains($0) && $0.count >= 3 }
        }
        for (name, extra) in flatWords {
            let own = words(name).filter { !stopWords.contains($0) && !generic.contains($0) && $0.count >= 3 }
            tokens[name] = Array(Set((tokens[name] ?? own) + extra)).sorted()
        }
        return AccountIndex(accounts: accounts, institutionTokens: tokens, genericWords: generic)
    }

    static let stopWords: Set<String> = ["the", "of", "and", "by", "co"]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// The nearest ancestor of an account root with no digits that isn't an archive, and whether
    /// an archive lies between them.
    static func institutionFolder(of root: String, isArchived: (String) -> Bool) -> (String, Bool)? {
        var parts = root.split(separator: "/").map(String.init)
        var archived = false
        parts.removeLast()
        while let last = parts.last {
            let path = parts.joined(separator: "/")
            if isArchiveName(last) || isArchived(path) { archived = true; parts.removeLast(); continue }
            if last.contains(where: \.isNumber) { parts.removeLast(); continue }
            // Archived anywhere above, too (`HDFC Bank/Archive/HDFC Forex/HDFC Forex 9055`).
            let above = parts.dropLast()
            let archivedAbove = above.contains(where: isArchiveName)
                || (1...max(1, above.count)).contains { isArchived(above.prefix($0).joined(separator: "/")) }
            return (path, archived || archivedAbove)
        }
        return nil
    }

    // MARK: Matching

    public enum Match: Sendable, Equatable {
        /// A statement printing one account's own number, from that account's institution.
        case high(Account, number: DocumentFacts.OwnNumber)
        /// One account matched, but the page is a tax form or letter, or names no institution.
        case medium(Account, number: DocumentFacts.OwnNumber, why: Why)
        /// Two or more accounts end in the printed number.
        case ambiguous([Account])
        /// A statement printing the own numbers of two or more accounts, each matched to one
        /// account at a bank the page names (a combined brokerage and IRA statement), in page order.
        case several([Account], numbers: [DocumentFacts.OwnNumber])
        case none

        public enum Why: String, Sendable { case notAStatement, institutionSilent }

        public var account: Account? {
            switch self {
            case .high(let a, _), .medium(let a, _, _): return a
            default: return nil
            }
        }
    }

    func ends(_ number: DocumentFacts.OwnNumber, identity: String) -> Bool {
        let d = number.digits
        if identity.count >= 4, d.hasSuffix(identity) { return true }
        if d.count >= 3, identity.hasSuffix(d), number.masked || d.count >= 4 { return true }
        return false
    }

    /// How many times `name`'s tokens appear in `text`, on word boundaries ("chase" isn't in
    /// "purchases").
    func mentions(_ name: String, in text: String) -> Int {
        (institutionTokens[name] ?? []).reduce(0) { $0 + Self.wordCount($1, in: text) }
    }

    static func wordCount(_ word: String, in text: String) -> Int {
        var count = 0
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: word, options: [], range: search) {
            let beforeOK = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
            if beforeOK && afterOK { count += 1 }
            search = r.upperBound..<text.endIndex
        }
        return count
    }

    /// The one institution the page's header names most, or nil for none or a tie.
    public func headerInstitution(_ facts: DocumentFacts) -> String? { institution(namedIn: facts.header) }

    /// The one institution `text` (lower-cased) names most, or nil for none or a tie.
    public func institution(namedIn text: String) -> String? {
        let counts = institutionTokens.keys.map { ($0, mentions($0, in: text)) }.filter { $0.1 > 0 }
        guard let top = counts.max(by: { $0.1 < $1.1 }) else { return nil }
        return counts.filter { $0.1 == top.1 }.count == 1 ? top.0 : nil
    }

    public func match(_ facts: DocumentFacts) -> Match {
        if let several = severalAccounts(facts) { return .several(several.map(\.0), numbers: several.map(\.1)) }
        var hits: [(Account, DocumentFacts.OwnNumber)] = []
        for account in accounts {
            for number in facts.matchingNumbers where account.identities.contains(where: { ends(number, identity: $0) }) {
                hits.append((account, number))
                break
            }
        }
        // Nested matches collapse to the highest folder.
        var roots = hits.filter { h in !hits.contains { o in o.0.root != h.0.root && h.0.root.hasPrefix(o.0.root + "/") } }
        guard !roots.isEmpty else { return .none }
        // The same ending at two accounts: the bank the page names decides, then a live account
        // over an archived one.
        if roots.count > 1 {
            let named = roots.filter { mentions($0.0.institution, in: facts.header) > 0 }
            if !named.isEmpty { roots = named }
        }
        if roots.count > 1 {
            let live = roots.filter { !$0.0.archived }
            if live.count == 1 { roots = live }
        }
        if roots.count > 1 { return .ambiguous(roots.map(\.0)) }
        let (account, number) = roots[0]
        let own = mentions(account.institution, in: facts.header)
        // Another bank heads the page (a Marcus statement naming a Discover transfer): not this one.
        let rival = institutionTokens.keys.filter { $0 != account.institution }
            .map { mentions($0, in: facts.header) }.max() ?? 0
        if rival > own { return .none }
        // A header naming no bank at all: the rest of page 1 may (a 529 plan in its footnote, a
        // mortgage servicer near the 1,000th character), when it names no other bank as often.
        if own == 0, institution(namedIn: facts.text) != account.institution {
            return .medium(account, number: number, why: .institutionSilent)
        }
        guard facts.kind == .statement else { return .medium(account, number: number, why: .notAStatement) }
        return .high(account, number: number)
    }
}

extension AccountIndex {
    /// Each own number on a statement, in page order, matched to exactly one account (nested
    /// matches collapse to the highest folder), when two or more distinct accounts result and
    /// every one is at a bank the page names, with no other bank heading it more. nil otherwise:
    /// one number at two accounts is ``Match/ambiguous(_:)``, not this.
    func severalAccounts(_ facts: DocumentFacts) -> [(Account, DocumentFacts.OwnNumber)]? {
        guard facts.kind == .statement else { return nil }
        var pairs: [(Account, DocumentFacts.OwnNumber)] = []
        var seen: Set<String> = []
        for number in facts.matchingNumbers where seen.insert(number.ending).inserted {
            let hit = accounts.filter { $0.identities.contains { ends(number, identity: $0) } }
            let top = hit.filter { a in !hit.contains { o in o.root != a.root && a.root.hasPrefix(o.root + "/") } }
            guard !top.isEmpty else { continue }
            guard top.count == 1 else { return nil }
            if pairs.contains(where: { $0.0.root == top[0].root }) { continue }
            pairs.append((top[0], number))
        }
        guard pairs.count >= 2 else { return nil }
        let banks = Set(pairs.map(\.0.institution))
        let own = banks.map { mentions($0, in: facts.header) }
        guard own.allSatisfy({ $0 > 0 }) else { return nil }
        let rival = institutionTokens.keys.filter { !banks.contains($0) }.map { mentions($0, in: facts.header) }.max() ?? 0
        guard rival <= (own.max() ?? 0) else { return nil }
        return pairs
    }
}

// MARK: - Statement families

/// Files whose names share a template once digits and month words are abstracted, with periods
/// readable from the name or its year folder. Regular: at least 3 distinct periods with a median
/// gap of 3 months or less, judged on the family's own newest 12 periods.
public enum StatementFamily {

    public struct Member: Sendable, Equatable {
        public let name: String
        /// Relative to the account root.
        public let folder: String
        public let period: DocumentFacts.Period
    }

    /// The template, extension included: a CSV export and the PDF statements it mirrors are two
    /// families, never one.
    static func key(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        var s = (name as NSString).deletingPathExtension.lowercased() + "." + ext
        s = s.replacingOccurrences(of: #"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*"#, with: "M",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        return s
    }

    /// The period a file name names, using its year folder when the name has a month but no year.
    static func period(ofName name: String, folder: String) -> DocumentFacts.Period? {
        let s = (name as NSString).deletingPathExtension.lowercased()
        func ints(_ m: [String]) -> [Int] { m.compactMap { Int($0) } }
        // ASCII digits only: `\d` also matches other scripts' digits, which `Int` won't read.
        if let r = s.range(of: #"(20[0-9][0-9])[-_]?([0-9][0-9])[-_]?([0-9][0-9])"#, options: .regularExpression) {
            let d = String(s[r]).filter { $0.isASCII && $0.isNumber }
            if let y = Int(d.prefix(4)), let m = Int(d.dropFirst(4).prefix(2)), let day = Int(d.suffix(2)),
               (1...12).contains(m), (1...31).contains(day) { return .init(year: y, month: m, day: day) }
        }
        if let r = s.range(of: #"(?<![0-9])([0-9][0-9])([0-9][0-9])(20[0-9][0-9])(?![0-9])"#, options: .regularExpression) {
            let d = String(s[r])
            if let m = Int(d.prefix(2)), let day = Int(d.dropFirst(2).prefix(2)), let y = Int(d.suffix(4)),
               (1...12).contains(m), (1...31).contains(day) { return .init(year: y, month: m, day: day) }
        }
        // `Statement 2026-11`: a year and a month, no day.
        if let r = s.range(of: #"(?<!\d)(20\d\d|19\d\d)[-_.](\d\d)(?!\d)"#, options: .regularExpression) {
            let d = String(s[r]).filter(\.isNumber)
            if let y = Int(d.prefix(4)), let m = Int(d.suffix(2)), (1...12).contains(m) { return .init(year: y, month: m) }
        }
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let month = words.compactMap({ FilingPeriod.month(of: $0) }).first else { return nil }
        let year = words.compactMap { Int($0) }.first { (1990...2100).contains($0) }
            ?? folder.split(separator: "/").reversed().compactMap { Int($0) }.first { (1990...2100).contains($0) }
        return year.map { .init(year: $0, month: month) }
    }

    /// The families below `node`, keyed by template, each member with its folder relative to
    /// `node`.
    public static func families(below node: FileNode) -> [String: [Member]] {
        var out: [String: [Member]] = [:]
        func visit(_ n: FileNode, _ rel: String) {
            for c in n.children ?? [] {
                if c.isDirectory {
                    visit(c, rel.isEmpty ? c.name : rel + "/" + c.name)
                } else if let p = period(ofName: c.name, folder: rel) {
                    out[key(c.name), default: []].append(Member(name: c.name, folder: rel, period: p))
                }
            }
        }
        visit(node, "")
        return out
    }

    public static func isRegular(_ members: [Member]) -> Bool {
        let months = Array(Set(members.map(\.period.monthIndex))).sorted().suffix(12)
        guard months.count >= 3 else { return false }
        let gaps = zip(months, months.dropFirst()).map { $1 - $0 }.sorted()
        return gaps[gaps.count / 2] <= 3
    }

    static func hasRegularFamily(below node: FileNode) -> Bool {
        families(below: node).values.contains(where: isRegular)
    }
}

// MARK: - Accounts named without digits (tier 3)

extension AccountIndex {

    /// A file to read for tier 3: its folder's candidate account, and the file, both relative to
    /// the walked root.
    public struct Sample: Sendable, Equatable {
        public let candidate: String
        public let file: String
    }

    /// Folders holding statements but no digits to name an account by (`Credit Accounts/Citi`,
    /// `Investments/Fidelity/Statements`, `Investments/ScholarShare`): the highest folder with a
    /// regular statement family that neither holds nor sits inside a named account, and isn't an
    /// inbox. For each, the newest two statements of each of its families, at most `perFolder` files
    /// and `limit` in all: what a few filed statements print is what identifies the account.
    public func unnamedSamples(tree: [FileNode], isInbox: (String) -> Bool = { FolderProfile.isInboxPath($0) },
                               perFolder: Int = 4, limit: Int = 150) -> [Sample] {
        let named = accounts.map(\.root)
        func touchesNamed(_ rel: String) -> Bool {
            named.contains { $0 == rel || $0.hasPrefix(rel + "/") || rel.hasPrefix($0 + "/") }
        }
        var out: [Sample] = []
        func visit(_ node: FileNode, _ rel: String) {
            guard node.isDirectory, out.count < limit, !isInbox(rel) else { return }
            if !touchesNamed(rel) {
                let families = StatementFamily.families(below: node).values.filter(StatementFamily.isRegular)
                if !families.isEmpty {
                    let newest = families.flatMap { $0.sorted { $0.period > $1.period }.prefix(2) }
                        .sorted { $0.period > $1.period }.prefix(perFolder)
                    for m in newest where out.count < limit {
                        let file = [rel, m.folder, m.name].filter { !$0.isEmpty }.joined(separator: "/")
                        out.append(Sample(candidate: rel, file: file))
                    }
                    return   // the highest such folder; what's below it is its own
                }
            }
            for c in node.children ?? [] where c.isDirectory {
                visit(c, rel.isEmpty ? c.name : rel + "/" + c.name)
            }
        }
        for n in tree { visit(n, n.name) }
        return out
    }

    /// This index with the accounts that `read` statements identify (design §3.0, tier 3):
    /// - an ending recurring in two sampled statements of one candidate (or its only one) is an
    ///   identity; one seen under two candidates is noise (an address, a phone number) and dropped;
    /// - its account is the deepest folder holding every statement that prints it, lifted out of
    ///   year folders;
    /// - its institution is the path segment the statements' headers name.
    public func adding(read: [(sample: Sample, facts: DocumentFacts)],
                       isArchived: (String) -> Bool = { _ in false }) -> AccountIndex {
        let statements = read.filter { $0.facts.kind == .statement }
        var byEnding: [String: [(Sample, DocumentFacts)]] = [:]
        for (s, f) in statements {
            // The page's own numbers, as matching uses: a pay-from account printed every month
            // isn't this account's identity.
            for e in Set(f.matchingNumbers.map(\.ending)) { byEnding[e, default: []].append((s, f)) }
        }
        let perCandidate = Dictionary(grouping: statements, by: { $0.sample.candidate }).mapValues(\.count)
        var learned: [String: (endings: Set<String>, institution: String, archived: Bool)] = [:]
        var categoryWords: [String: Set<String>] = [:]
        for (ending, hits) in byEnding {
            // A number a folder already names is that account's: a loan statement printing the
            // checking account it is paid from must not make that account ambiguous.
            let number = DocumentFacts.OwnNumber(digits: ending, masked: false)
            if accounts.contains(where: { a in a.identities.contains { ends(number, identity: $0) } }) { continue }
            let candidates = Set(hits.map { $0.0.candidate })
            guard candidates.count == 1, let candidate = candidates.first else { continue }
            guard hits.count >= 2 || perCandidate[candidate] == 1 else { continue }
            // The deepest folder holding them all, out of year folders.
            var root = Self.commonFolder(hits.map { ($0.0.file as NSString).deletingLastPathComponent })
            while let last = root.split(separator: "/").last.map(String.init),
                  FolderProfileEntry.looksLikeYear(last) || FilingPeriod.monthSlot(ofFolderNamed: last) != nil {
                root = (root as NSString).deletingLastPathComponent
            }
            guard root.hasPrefix(candidate) || candidate.hasPrefix(root), !root.isEmpty else { continue }
            let segments = root.split(separator: "/").map(String.init)
            // The bank its own statements name, when it is one the tree already knows (a
            // `Home/Mortgage/Statements` of Chase statements is Chase's)...
            var institution: String?
            // A bank the tree knows, named by these pages: by most of them, or by any when it is
            // the only one any of them names (a mortgage page names its servicer once, low down).
            // Read from the header first; when it names none, from the rest of page 1, where a
            // mortgage statement names its servicer (`JPMorgan Chase Bank`) near the 1,000th
            // character. Judged on the header alone, that one line fell in or out of range from
            // page to page, and the account was learned as the bank one run and `Mortgage` the next.
            func naming(_ text: (DocumentFacts) -> String) -> (named: [String], known: [String]) {
                let named = institutionTokens.keys.filter { name in hits.contains { mentions(name, in: text($0.1)) > 0 } }
                let known = institutionTokens.keys.filter { name in
                    hits.filter { mentions(name, in: text($0.1)) > 0 }.count * 2 > hits.count
                }
                return (named, known)
            }
            var (named, known) = naming(\.header)
            if named.isEmpty { (named, known) = naming(\.text) }
            if known.count == 1 { institution = known[0] } else if known.isEmpty, named.count == 1 { institution = named[0] }
            // ...else the deepest segment of its path the headers name, skipping words common to
            // many folder names (`Statements`, a household name): `Citi`, `ScholarShare`. When no
            // header names one, the rest of page 1: a ScholarShare 529 statement names its plan
            // only in a footnote, while its header's boilerplate says "your investments".
            for read in [\DocumentFacts.header, \DocumentFacts.text] where institution == nil {
                for (i, seg) in segments.enumerated().reversed() {
                    // Not the top level of a deep path: that is a category (`Investments`). In a
                    // shallow one (`Citi/Statements`) it is the bank.
                    guard i > 0 || segments.count <= 2, !AccountIndex.isArchiveName(seg), !seg.contains(where: { $0.isNumber }) else { continue }
                    // Nor a folder holding another account: that is a category too, at any depth
                    // (`Finance/US/Investments` over Schwab's and Fidelity's).
                    let prefix = segments[...i].joined(separator: "/") + "/"
                    guard !accounts.contains(where: { $0.root.hasPrefix(prefix) }) else { continue }
                    let words = AccountIndex.words(seg).filter {
                        $0.count >= 4 && !AccountIndex.stopWords.contains($0) && !genericWords.contains($0)
                    }
                    guard !words.isEmpty else { continue }
                    let naming = hits.filter { h in words.contains { AccountIndex.wordCount($0, in: h.1[keyPath: read]) > 0 } }.count
                    if naming * 2 > hits.count {
                        institution = seg.lowercased()
                        categoryWords[seg.lowercased(), default: []].formUnion(segments[..<i].flatMap(AccountIndex.words))
                        break
                    }
                }
            }
            guard let institution else { continue }
            let archived = segments.contains { AccountIndex.isArchiveName($0) } || isArchived(root)
            learned[root, default: ([], institution, archived)].endings.insert(ending)
        }
        var tokens = institutionTokens
        for (name, cats) in categoryWords where tokens[name] == nil {
            tokens[name] = AccountIndex.words(name).filter {
                !cats.contains($0) && !AccountIndex.stopWords.contains($0) && !genericWords.contains($0) && $0.count >= 3
            }
        }
        let added = learned.map { entry -> Account in
            var a = Account(root: entry.key, identities: entry.value.endings.sorted(),
                            institution: entry.value.institution, archived: entry.value.archived)
            a.institutionName = entry.key.split(separator: "/").map(String.init)
                .last { $0.lowercased() == entry.value.institution } ?? entry.value.institution
            return a
        }
        return AccountIndex(accounts: accounts + added.sorted { $0.root < $1.root }, institutionTokens: tokens,
                            genericWords: genericWords)
    }

    /// The deepest folder every path in `folders` is at or under.
    static func commonFolder(_ folders: [String]) -> String {
        guard var common = folders.first?.split(separator: "/").map(String.init) else { return "" }
        for f in folders.dropFirst() {
            let parts = f.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return common.joined(separator: "/")
    }
}


/// Compiled regular expressions by pattern, for helpers handed a pattern string.
final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]
    func regex(_ pattern: String) -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[pattern] { return r }
        let r = try! NSRegularExpression(pattern: pattern)
        cache[pattern] = r
        return r
    }
}
