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
    /// The page lower-cased, and its first 1,000 characters: the header an institution is read from.
    let text: String
    let header: String

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
        ownNumbers = Self.ownNumbers(in: page)
        kind = Self.kind(of: lower)
        period = kind == .taxForm ? Self.taxYear(in: lower).map { Period(year: $0, month: 12, day: 31) }
                                  : Self.statementPeriod(in: page)
    }

    // MARK: Own numbers

    private static let label = try! NSRegularExpression(pattern:
        #"\b(?:(?:account|acct|loan|card|policy|member|contract)\b[^|\n]{0,12}?\b(?:number|no\.?|#)(?:\s*ending\s*in)?|account\s*(?:ending(?:\s*in)?|#)|ending\s+in)[\s:#.]*"#,
        options: [.caseInsensitive])
    private static let numberAfterLabel = try! NSRegularExpression(pattern: #"^[Xx\*•]{0,24}[\dXx\*•][\dXx\*• \-]{1,24}\d"#)
    /// A masked run (`XXXX XXXX XXXX 1768`, `******4121`, `XXXX-XXXXX6-22002`), bounded so a page of
    /// asterisks can't make the match backtrack for seconds.
    private static let maskedAnywhere = try! NSRegularExpression(pattern:
        #"(?<![\w*•])[Xx\*•]{3,24}+(?:[ \-]{0,2}+[Xx\*•\d]{1,8}+){0,6}+"#)
    private static let ssnMask = try! NSRegularExpression(pattern: #"[Xx\*•]{3}-[Xx\*•]{2}-\d{4}"#)
    private static let routingLabel = try! NSRegularExpression(pattern: #"\b(?:routing|aba|rtn|transit)\b"#, options: [.caseInsensitive])

    static func ownNumbers(in page: String) -> [OwnNumber] {
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
            if before.contains("tin") || before.contains("ssn") || before.contains("social") || before.contains("taxpayer") { continue }
            let end = m.range.location + m.range.length
            var after = ns.substring(with: NSRange(location: end, length: min(60, ns.length - end)))
            // The value may sit on the next line (`Account Number\n3841-7863`) or carry one letter
            // of prefix (`Z26-141750`).
            after = String(after.drop(while: { $0.isWhitespace || $0 == "|" || $0 == ":" }))
            if let first = after.first, first.isLetter, first.isASCII,
               after.dropFirst().first?.isNumber == true { after = String(after.dropFirst()) }
            let a = after as NSString
            if let n = numberAfterLabel.firstMatch(in: after, range: NSRange(location: 0, length: a.length)) {
                add(a.substring(with: n.range).trimmingCharacters(in: .whitespaces), at: m.range.location, labelled: true)
            }
        }
        let head = String(page.prefix(2500)) as NSString
        for m in maskedAnywhere.matches(in: head as String, range: NSRange(location: 0, length: head.length)) {
            var s = head.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            // A taxpayer mask (`XXX-XX-7396`) inside the run is the person's: cut it out.
            s = ssnMask.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            guard (s.reversed().prefix { $0.isNumber }).count >= 3 || s.filter(\.isNumber).count >= 3 else { continue }
            add(s, at: m.range.location, labelled: false)
        }
        return out
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
    private static let dateRE = #"(?:\d{1,2}/\d{1,2}/\d{2,4}|"# + monthRE + #"[a-z]*\.? \d{1,2}(?:\s*-\s*\d{1,2})?,? \d{4})"#
    private static let taxRE = try! NSRegularExpression(pattern: #"form\s*(1099|1098|5498|w-2)|tax year \d{4}"#)
    private static let statementWordsRE = try! NSRegularExpression(pattern:
        #"statement period|billing period|statement date|closing date|opening/closing|statement closing|account summary|summary of your account"#)
    private static let rangeRE = try! NSRegularExpression(pattern: dateRE + #"[\s|]*(?:to|through|-|–)[\s|]*"# + dateRE)
    private static let monthDayRangeRE = try! NSRegularExpression(pattern: #"\b"# + monthRE + #"[a-z]* \d{1,2}\s*-\s*\d{1,2}, \d{4}"#)

    static func kind(of lower: String) -> Kind {
        let head = String(lower.prefix(800))
        if matches(taxRE, head) { return .taxForm }
        if matches(statementWordsRE, lower) || matches(rangeRE, lower) || matches(monthDayRangeRE, lower) { return .statement }
        return .other
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
    /// in "investment").
    private static let nonPeriodLabel = try! NSRegularExpression(pattern:
        #"\b(?:due|payments?|maturity|vest(?:ed|ing)?|dtd|dated|expir\w*|born|since)\b"#, options: [.caseInsensitive])
    private static let labelledDateRE = try! NSRegularExpression(pattern:
        #"(?:closing date|statement date|statement closing date|period ending|period end|through|as of)[\s:|]*("# + dateRE + ")")
    private static let numericDateRE = try! NSRegularExpression(pattern: #"^(\d{1,2})/(\d{1,2})/(\d{2,4})"#)

    /// The period end: the end of a labelled range, else a date after a period label. Every
    /// candidate is checked against the few words before it.
    static func statementPeriod(in page: String) -> Period? {
        let lower = page.lowercased()
        let ns = lower as NSString
        func labelBefore(_ loc: Int) -> String { ns.substring(with: NSRange(location: max(0, loc - 30), length: min(30, loc))) }
        func rejected(_ loc: Int) -> Bool {
            let l = labelBefore(loc)
            return nonPeriodLabel.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil
        }
        // `March 1-31, 2026`: a month with a day range.
        for m in monthDayRangeRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            if let p = parseDate(ns.substring(with: m.range), endOfRange: true) { return p }
        }
        // `February 26, 2026 to March 27, 2026`, `12/28/2025 - 01/27/2026`: the second date.
        for m in rangeRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            // The range's second date, whatever joins them (`to`, `through`, a dash).
            let s = ns.substring(with: m.range)
            if let last = matchesOf(dateRE, in: s).last, let p = parseDate(last, endOfRange: true) { return p }
        }
        // `Closing Date 01/27/2026`, `Statement Date: 10/15/2026`, `through October 31, 2026`.
        for m in labelledDateRE.matches(in: lower, range: NSRange(location: 0, length: ns.length)) where !rejected(m.range.location) {
            if let p = parseDate(ns.substring(with: m.range(at: 1))) { return p }
        }
        return nil
    }

    private static func matchesOf(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// `03/31/2026`, `03/31/26`, `March 31, 2026`, `March 1-31, 2026` (the range's end).
    static func parseDate(_ raw: String, endOfRange: Bool = false) -> Period? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sn = s as NSString
        if let m = numericDateRE.firstMatch(in: s, range: NSRange(location: 0, length: sn.length)) {
            let n = sn.substring(with: m.range)
            let p = n.split(separator: "/").compactMap { Int($0) }
            guard p.count == 3, (1...12).contains(p[0]), (1...31).contains(p[1]) else { return nil }
            let year = p[2] < 100 ? 2000 + p[2] : p[2]
            return (1990...2100).contains(year) ? Period(year: year, month: p[0], day: p[1]) : nil
        }
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first, let month = FilingPeriod.month(of: first) else { return nil }
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
    static func accountDigits(inFolderNamed name: String) -> [String] {
        if name.range(of: #"^\d{1,2}\. "#, options: .regularExpression) != nil { return [] }
        let lower = name.lowercased()
        var out: [String] = []
        let ns = lower as NSString
        let re = try! NSRegularExpression(pattern: #"\d+"#)
        for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let run = ns.substring(with: m.range)
            // A year-like run is a year (`Statements 2024`), even where it might be an account.
            guard run.count >= 3, !DocumentFacts.isYear(run) else { continue }
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 5), length: min(5, m.range.location)))
            if before.hasSuffix("form ") || before.hasSuffix("form") { continue }
            out.append(run)
        }
        return out
    }

    static func isArchiveName(_ name: String) -> Bool { name.lowercased() == "archive" }

    /// Builds the index from a walked tree. `isArchived` answers from the survey's profile (role or
    /// lifecycle axis); a folder named `Archive` counts either way.
    public static func build(tree: [FileNode],
                             isArchived: (String) -> Bool = { _ in false },
                             isInbox: (String) -> Bool = { FolderProfile.isInboxPath($0) }) -> AccountIndex {
        var named: [(path: String, digits: [String])] = []
        func visit(_ node: FileNode, _ rel: String) {
            guard node.isDirectory else { return }
            if !rel.isEmpty, !isInbox(rel) {
                let digits = accountDigits(inFolderNamed: node.name)
                if !digits.isEmpty, StatementFamily.hasRegularFamily(below: node) {
                    named.append((rel, digits))
                    return   // the highest such folder is the account; below it are its years
                }
            }
            for child in node.children ?? [] where child.isDirectory {
                visit(child, rel.isEmpty ? child.name : rel + "/" + child.name)
            }
        }
        for node in tree { visit(node, node.name) }
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
        for (path, digits) in named {
            guard let (institutionFolder, archived) = institutionFolder(of: path, isArchived: isArchived) else { continue }
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
    public func headerInstitution(_ facts: DocumentFacts) -> String? {
        let counts = institutionTokens.keys.map { ($0, mentions($0, in: facts.header)) }.filter { $0.1 > 0 }
        guard let top = counts.max(by: { $0.1 < $1.1 }) else { return nil }
        return counts.filter { $0.1 == top.1 }.count == 1 ? top.0 : nil
    }

    public func match(_ facts: DocumentFacts) -> Match {
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
        if own == 0 { return .medium(account, number: number, why: .institutionSilent) }
        guard facts.kind == .statement else { return .medium(account, number: number, why: .notAStatement) }
        return .high(account, number: number)
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
        if let r = s.range(of: #"(20\d\d)[-_]?(\d\d)[-_]?(\d\d)"#, options: .regularExpression) {
            let d = String(s[r]).filter(\.isNumber)
            let y = Int(d.prefix(4))!, m = Int(d.dropFirst(4).prefix(2))!, day = Int(d.suffix(2))!
            if (1...12).contains(m), (1...31).contains(day) { return .init(year: y, month: m, day: day) }
        }
        if let r = s.range(of: #"(?<!\d)(\d\d)(\d\d)(20\d\d)(?!\d)"#, options: .regularExpression) {
            let d = String(s[r])
            let m = Int(d.prefix(2))!, day = Int(d.dropFirst(2).prefix(2))!, y = Int(d.suffix(4))!
            if (1...12).contains(m), (1...31).contains(day) { return .init(year: y, month: m, day: day) }
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
            for e in Set(f.ownNumbers.map(\.ending)) { byEnding[e, default: []].append((s, f)) }
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
            let known = institutionTokens.keys.filter { name in
                hits.filter { mentions(name, in: $0.1.header) > 0 }.count * 2 > hits.count
            }
            if known.count == 1 { institution = known[0] }
            // ...else the deepest segment of its path the headers name, skipping words common to
            // many folder names (`Statements`, a household name): `Citi`, `ScholarShare`.
            if institution == nil {
                for (i, seg) in segments.enumerated().reversed() {
                    guard !AccountIndex.isArchiveName(seg), !seg.contains(where: { $0.isNumber }) else { continue }
                    let words = AccountIndex.words(seg).filter {
                        $0.count >= 4 && !AccountIndex.stopWords.contains($0) && !genericWords.contains($0)
                    }
                    guard !words.isEmpty else { continue }
                    let naming = hits.filter { h in words.contains { AccountIndex.wordCount($0, in: h.1.header) > 0 } }.count
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
