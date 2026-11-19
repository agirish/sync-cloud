import Foundation

/// A number read from a document, waiting in To Confirm until it is added or set aside.
///
/// Sealed to disk with the Vault's key between reads (``VaultReadingState``), and let go from
/// memory when the Vault locks, like the entries. Like ``VaultEntry`` it never prints its number.
public struct VaultFind: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// What it is: "Passport", "US visa", "I-129 · H-1B extension".
    public var title: String
    /// The number in full, letters and digits only.
    public var value: String
    /// One line for search and the editor's note: who it names and when it runs out.
    public var note: String
    /// What the documents said besides the number, and every document that carries it.
    public var facts: VaultReadFacts
    /// Current or older, as the user chose. Later reads keep it.
    public var pin: VaultPin?
    /// Whose it is, as the user chose. Later reads keep it.
    public var assignment: VaultAssignment?

    public init(id: UUID = UUID(), title: String, value: String, note: String = "",
                facts: VaultReadFacts, pin: VaultPin? = nil, assignment: VaultAssignment? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.note = note
        self.facts = facts
        self.pin = pin
        self.assignment = assignment
    }

    /// The shape the earlier reader built, for tests and simple callers: a category worked out
    /// from the title, one source, and the dates given.
    public init(id: UUID = UUID(), title: String, value: String, kind: VaultEntry.Kind = .identity,
                note: String = "", holder: String? = nil, sourcePath: String,
                dated: Date? = nil, validUntil: Date? = nil, born: Date? = nil, issuer: String? = nil,
                form: String? = nil) {
        let category: VaultCategory = title.hasPrefix("Passport") ? .passport
            : title.hasPrefix("I-94") ? .i94 : title.contains("visa") ? .usVisa
            : title.contains("receipt") || title.hasPrefix("I-") ? .uscisCase : VaultCategory.from(kind: kind)
        self.init(id: id, title: title, value: value, note: note,
                  facts: VaultReadFacts(category: category, holder: holder, born: born, issuer: issuer, form: form,
                                        dated: dated ?? VaultReading.fileDate(sourcePath), validUntil: validUntil,
                                        sources: [VaultSource(path: sourcePath, role: "Document", rank: 1)]))
    }

    public var category: VaultCategory { facts.category }
    public var kind: VaultEntry.Kind { facts.category.kind }
    public var holder: String? { facts.holder }
    public var dated: Date? { facts.dated }
    public var validUntil: Date? { facts.validUntil }
    /// The document it was read from.
    public var sourcePath: String { facts.primary?.path ?? "" }
}

extension VaultFind: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultFind(\(title), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// A number named on a document that is not where it comes from: the passport number on an I-94
/// or a visa foil. It adds that document to the number's list; it never offers a number itself.
public struct VaultMention: Sendable, Equatable {
    public var value: String
    public var category: VaultCategory
    public var source: VaultSource
}

/// Reads the numbers a document states plainly enough to trust without a person checking each
/// character, tried on real scans:
///
/// - A passport's or a visa's machine-readable zone, every one on a page, kept only when its
///   check digits agree. Which it is comes from the line above the number (`P` or `V`); a zone
///   whose name line was not read counts as a passport only when its whole line and overall
///   check agree, which a visa's line has no room for.
/// - A USCIS receipt number: three letters naming the service center, then ten digits.
/// - An I-94 admission number, only beside its label.
///
/// Each takes a document as pages of recognised lines, so the rules are tested on text and the
/// app decides how a page is read. Recognition needs Vision's accurate level: on the same scans
/// the fast level, which filing uses, missed every one of these.
public enum VaultReading {

    /// Raised whenever a rule changes what is read, so the next Read Documents reads every file
    /// again rather than trusting what an older build made of it.
    public static let version = 7

    /// Every number on a document, once each, and the numbers it only names.
    public static func read(pages: [[String]], from path: String) -> (finds: [VaultFind], mentions: [VaultMention]) {
        var out: [VaultFind] = []
        var seen = Set<String>()
        func keep(_ find: VaultFind) {
            if seen.insert(normalized(find.value)).inserted { out.append(find) }
        }
        let text = pages.map { $0.joined(separator: "\n") }.joined(separator: "\n")
        var visaPassports: [VaultMention] = []
        for (index, page) in pages.enumerated() {
            let pageText = page.joined(separator: "\n")
            for zone in MachineZone.zones(in: page) {
                let pageLabel = pages.count > 1 ? index + 1 : nil
                switch zone.kind {
                case .passport:
                    keep(zone.passportFind(from: path, page: pageLabel))
                case .visa:
                    // A US visa's zone carries the passport's number, not the visa's own: the visa
                    // is a document of that passport, and is itself known by its Control Number.
                    visaPassports.append(VaultMention(value: zone.number, category: .passport,
                                                      source: VaultSource(path: path, role: "US visa", rank: Rank.mention)))
                    if let visa = zone.visaFind(from: path, page: pageLabel, text: pageText) { keep(visa) }
                }
            }
        }
        for find in receiptNumbers(in: text, from: path) { keep(find) }
        for find in admissionNumbers(in: text, from: path) { keep(find) }
        var mentions = visaPassports.filter { !seen.contains(normalized($0.value)) }
        let named = Set(mentions.map { normalized($0.value) })
        mentions += passportMentions(in: text, from: path).filter {
            !seen.contains(normalized($0.value)) && !named.contains(normalized($0.value))
        }
        return (out, mentions)
    }

    /// One page's numbers: what most tests hand in.
    public static func finds(in lines: [String], from path: String) -> [VaultFind] {
        read(pages: [lines], from: path).finds
    }

    /// Letters and digits only, upper case: how two readings of one number are compared, and how
    /// a find is matched against what the Vault already holds.
    public static func normalized(_ value: String) -> String {
        String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    // MARK: Document roles

    /// How far each kind of document is trusted as a number's source.
    enum Rank {
        static let passportPage = 40
        static let visaFoil = 40
        static let i94Printout = 30
        static let approval = 30
        static let tearOff = 25
        static let receiptNotice = 20
        static let mention = 10
    }

    /// An I-797A approval, an I-797C receipt notice, or neither.
    static func noticeKind(_ text: String) -> (role: String, rank: Int, pending: Bool)? {
        let lower = text.lowercased()
        if lower.contains("approval notice") || lower.contains("i-797a") || lower.contains("i-797 a") {
            return ("I-797A approval", Rank.approval, false)
        }
        if lower.contains("receipt notice") || lower.contains("i-797c") || lower.contains("i-797 c") {
            return ("I-797C receipt", Rank.receiptNotice, true)
        }
        return nil
    }

    // MARK: Receipt numbers

    /// The service centers that print receipt numbers, as of 2026. A prefix outside this list is
    /// more likely a misread word than a new center.
    static let receiptCenters = ["IOE", "EAC", "WAC", "LIN", "SRC", "MSC", "NBC", "YSC"]

    private static let receiptPattern = try! NSRegularExpression(
        pattern: #"\b(\#(receiptCenters.joined(separator: "|")))[\s-]?([0-9OQDILZSBG]{2}[\s-]?[0-9OQDILZSBG]{3}[\s-]?[0-9OQDILZSBG]{5})\b"#,
        options: [.caseInsensitive])

    /// A form named on the page other than the notice itself: "I-129" on an I-797 approval.
    private static let formPattern = try! NSRegularExpression(pattern: #"\bI-(\d{3}[A-Z]?)\b"#)
    /// "Valid from 10/01/2026 to 09/30/2029" on an approval notice.
    private static let validPattern = try! NSRegularExpression(
        pattern: #"valid\s*from\s*(\d{1,2})/(\d{1,2})/(\d{4})\s*to\s*(\d{1,2})/(\d{1,2})/(\d{4})"#,
        options: [.caseInsensitive])
    private static let noticeDatePattern = try! NSRegularExpression(
        pattern: #"notice\s*date\s*:?\s*(\d{1,2})/(\d{1,2})/(\d{4})"#, options: [.caseInsensitive])
    private static let receivedDatePattern = try! NSRegularExpression(
        pattern: #"received\s*date\s*:?\s*(\d{1,2})/(\d{1,2})/(\d{4})"#, options: [.caseInsensitive])
    /// The person a case is for: "Beneficiary ERIKSSON, ANNA" on an I-129, "Applicant" on others.
    /// Never the petitioner, who is the employer.
    private static let caseHolderPattern = try! NSRegularExpression(
        pattern: #"(?i:beneficiary|applicant)(?i:\s*name)?\s*:?\s*\n?\s*([A-Z][A-Z\x27\- ]+,\s*[A-Z][A-Z\x27\- ]+)"#)

    private static func slashDate(_ match: NSTextCheckingResult?, in ns: NSString, at first: Int) -> Date? {
        guard let match, let month = Int(ns.substring(with: match.range(at: first))),
              let day = Int(ns.substring(with: match.range(at: first + 1))),
              let year = Int(ns.substring(with: match.range(at: first + 2))) else { return nil }
        return calendarDate(year: year, month: month, day: day)
    }

    /// The end of "Valid from … to 09/30/2029", on an approval notice and its I-94 tear-off.
    static func validTo(in text: String) -> Date? {
        let ns = text as NSString
        return slashDate(validPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), in: ns, at: 4)
    }

    /// "ERIKSSON, ANNA MARIA" → "Anna Maria Eriksson".
    static func readingOrder(_ printed: String) -> String {
        let parts = printed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let ordered = parts.count == 2 ? parts[1] + " " + parts[0] : printed
        return ordered.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func receiptNumbers(in text: String, from path: String) -> [VaultFind] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let notice = noticeKind(text)
        let noticeDate = slashDate(noticeDatePattern.firstMatch(in: text, range: whole), in: ns, at: 1)
        let received = slashDate(receivedDatePattern.firstMatch(in: text, range: whole), in: ns, at: 1)
        let valid = validPattern.firstMatch(in: text, range: whole)
        let validFrom = slashDate(valid, in: ns, at: 1)
        let validUntil = slashDate(valid, in: ns, at: 4)
        let form = formPattern.matches(in: text, range: whole)
            .map { ns.substring(with: $0.range(at: 1)) }
            .first { !["797", "797A", "797C", "94"].contains($0) }
            .map { "I-" + $0 }
        let holder = caseHolderPattern.firstMatch(in: text, range: whole)
            .map { readingOrder(ns.substring(with: $0.range(at: 1))) }
        var details: [VaultDetail] = []
        if let form { details.append(VaultDetail("Form", .text(form))) }
        details.append(VaultDetail("Status", .text(notice?.pending == true ? "Pending, receipt notice only"
                                                   : notice != nil ? "Approved" : "Notice")))
        if let noticeDate { details.append(VaultDetail("Notice date", .date(noticeDate))) }
        if let received { details.append(VaultDetail("Received", .date(received))) }
        if let validFrom { details.append(VaultDetail("Valid from", .date(validFrom))) }
        if let validUntil { details.append(VaultDetail("Valid until", .date(validUntil))) }
        var notes: [String] = []
        if let form { notes.append("Form \(form)") }
        if let holder { notes.append(holder) }
        if let validUntil { notes.append("valid to \(spelled(validUntil))") }
        let source = VaultSource(path: path, role: notice?.role ?? "USCIS notice", rank: notice?.rank ?? Rank.mention)
        return receiptPattern.matches(in: text, range: whole).compactMap { match in
            let center = ns.substring(with: match.range(at: 1)).uppercased()
            let read = normalized(ns.substring(with: match.range(at: 2)))
            // Mostly digits as printed: look-alikes are forgiven a few at a time, and a run of
            // letters that only become digits once fixed is a word, not a number.
            guard read.filter(\.isNumber).count >= 7 else { return nil }
            let facts = VaultReadFacts(category: .uscisCase, holder: holder, form: form,
                                       dated: noticeDate ?? received ?? fileDate(path), validUntil: validUntil,
                                       pending: notice?.pending ?? false, details: details, sources: [source])
            return VaultFind(title: form.map { "\($0) case" } ?? "USCIS receipt number",
                             value: center + fixedDigits(read), note: sentence(notes), facts: facts)
        }
    }

    // MARK: Admission numbers

    /// "I-94", "Admission (I-94) Record Number", "Admission Number", then eleven characters: nine
    /// digits, a letter and a digit since 2013, or eleven digits before. The label is required, as
    /// eleven bare digits could be anything.
    ///
    /// Two things this learned from a real approval notice: Vision reads the label's I as a one
    /// ("1-94 # (if applicable):"), and runs the number into whatever is printed after it, so the
    /// number ends where the digits do rather than at a word boundary.
    ///
    /// And one from a folder of utility bills: the label has to stand on its own. "194" inside
    /// a payment line's run of digits once read as "1 94", and the next eleven digits on the page
    /// were offered as an I-94. So the label is never part of a longer number or word, the one-for-I
    /// form needs its hyphen, and nothing between the label and the number is a digit.
    ///
    /// The hyphen is any of them: CBP's older printouts write "I­94" with a soft hyphen.
    private static let admissionPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:I\#(hyphen)?94|[1l|]\#(hyphen)94|admission)(?![A-Za-z0-9])[^\n0-9]{0,40}?((?:[0-9OQDILZSBG]\s?){9}[A-Z0-9]\s?[0-9OQDILZSBG])(?![0-9])"#,
        options: [.caseInsensitive])

    /// A hyphen, a soft hyphen, the Unicode dashes, or a minus sign.
    private static let hyphen = #"[-\x{00AD}\x{2010}-\x{2015}\x{2212}]"#

    // CBP's web printout draws each label several times over ("Last/Surname:Last/Surname:…:
    // ERIKSSON"): a run of the label is skipped and the value after the last is taken, from the
    // same line only, so neither the next label nor the next line is ever read as the value.

    /// The printout's date of entry: "Arrival/Issued Date: 2026 April 12" since 2025, "Most Recent
    /// Date of Entry: 2015 Jan 12" before.
    private static let entryDatePattern = try! NSRegularExpression(
        pattern: #"(?:(?:arrival\s*/\s*issued\s*date|date\s*of\s*entry)[ \t]*:?[ \t]*)+(\d{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+(\d{1,2})"#,
        options: [.caseInsensitive])
    private static let admitUntilPattern = try! NSRegularExpression(
        pattern: #"(?:admit\s*until\s*date[ \t]*:?[ \t]*)+(\d{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+(\d{1,2})"#,
        options: [.caseInsensitive])
    private static let birthDatePattern = try! NSRegularExpression(
        pattern: #"(?:birth\s*date[ \t]*:?[ \t]*)+(\d{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+(\d{1,2})"#, options: [.caseInsensitive])
    private static let classPattern = try! NSRegularExpression(
        pattern: #"(?:class\s*of\s*admission[ \t]*:?[ \t]*)+([A-Z0-9]{1,3}(?:-?[0-9A-Z]{1,2})?)\b"#, options: [.caseInsensitive])
    private static let surnamePattern = try! NSRegularExpression(
        pattern: #"(?:(?:last\s*/\s*surname|family\s*name)[ \t]*:[ \t]*)+([A-Za-z][A-Za-z\x27 -]*)"#, options: [.caseInsensitive])
    private static let givenNamePattern = try! NSRegularExpression(
        pattern: #"(?:first\s*\(given\)\s*name[ \t]*:[ \t]*)+([A-Za-z][A-Za-z\x27 -]*)"#, options: [.caseInsensitive])

    /// Words that are a form's labels, never a name or a class: a value that is one was misread.
    static let labelWords: Set<String> = ["first", "last", "given", "name", "surname", "family", "class",
                                          "admission", "birth", "date", "document", "number", "country",
                                          "citizenship", "arrival", "issued", "admit", "until"]

    /// "2026 April 12" as printed on an I-94.
    private static func printedDate(_ pattern: NSRegularExpression, in text: String) -> Date? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let year = Int(ns.substring(with: match.range(at: 1))),
              let month = monthNumber(ns.substring(with: match.range(at: 2))),
              let day = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        return calendarDate(year: year, month: month, day: day)
    }

    private static func printedName(_ pattern: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // A label read where the name should be ("First", "Last") is no name.
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.contains(where: labelWords.contains) else { return nil }
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func admissionNumbers(in text: String, from path: String) -> [VaultFind] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // When the admission began: the printout's date of entry, or, on an approval notice's
        // tear-off (an extension without travel), the notice's own date.
        let entered = printedDate(entryDatePattern, in: text)
            ?? slashDate(noticeDatePattern.firstMatch(in: text, range: whole), in: ns, at: 1)
        // A printout's admit-until date; on an approval notice's tear-off, the notice's validity.
        let until = printedDate(admitUntilPattern, in: text) ?? validTo(in: text)
        let born = printedDate(birthDatePattern, in: text)
        let admittedAs = classPattern.firstMatch(in: text, range: whole).map { ns.substring(with: $0.range(at: 1)).uppercased() }
            .flatMap { labelWords.contains($0.lowercased()) ? nil : $0 }
        let holder = [printedName(givenNamePattern, in: text), printedName(surnamePattern, in: text)]
            .compactMap { $0 }.joined(separator: " ")
        let lower = text.lowercased()
        let source: VaultSource
        if lower.contains("admit until") || lower.contains("most recent i") || lower.contains("cbp") {
            source = VaultSource(path: path, role: "CBP I-94 printout", rank: Rank.i94Printout)
        } else if noticeKind(text) != nil {
            source = VaultSource(path: path, role: "I-797A tear-off", rank: Rank.tearOff)
        } else {
            source = VaultSource(path: path, role: "Names it", rank: Rank.mention)
        }
        var details: [VaultDetail] = []
        if let admittedAs { details.append(VaultDetail("Class of admission", .text(admittedAs))) }
        if let entered { details.append(VaultDetail("Entered", .date(entered))) }
        if let until { details.append(VaultDetail("Admitted until", .date(until))) }
        var notes: [String] = []
        if !holder.isEmpty { notes.append(holder) }
        if let entered { notes.append("entered \(spelled(entered))") }
        if let until { notes.append("admitted until \(spelled(until))") }
        return admissionPattern.matches(in: text, range: whole).compactMap { match in
            let raw = normalized(ns.substring(with: match.range(at: 1)))
            guard raw.count == 11, raw.prefix(9).filter(\.isNumber).count >= 6 else { return nil }
            let chars = Array(raw)
            let head = fixedDigits(String(chars[0..<9]))
            let tail = fixedDigits(String(chars[10]))
            // The tenth is a letter in the current format and a digit in the old one; either
            // is read as printed.
            let value = head + String(chars[9]) + tail
            guard value.prefix(9).allSatisfy(\.isNumber) else { return nil }
            // A filler such as 60000000000 or 11111111111 is a blank form's, not a person's.
            guard Set(value.prefix(9)).count >= 4 else { return nil }
            let facts = VaultReadFacts(category: .i94, holder: holder.isEmpty ? nil : holder, born: born,
                                       dated: entered ?? fileDate(path), validUntil: until,
                                       details: details, sources: [source])
            return VaultFind(title: "I-94 admission number", value: value, note: sentence(notes), facts: facts)
        }
    }

    // MARK: Passport numbers named elsewhere

    /// "Document Number: X1234567" on an I-94, "Passport Number" on a visa foil or a notice.
    private static let namedPassportPattern = try! NSRegularExpression(
        pattern: #"(?:passport|document|travel\s*document)\s*(?:number|no\.?|#)\s*:?\s*([A-Z0-9]{6,9})\b"#,
        options: [.caseInsensitive])

    static func passportMentions(in text: String, from path: String) -> [VaultMention] {
        let ns = text as NSString
        let role = text.lowercased().contains("i-94") || text.lowercased().contains("admission") ? "I-94"
            : noticeKind(text)?.role ?? "Names it"
        return namedPassportPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let value = normalized(ns.substring(with: match.range(at: 1)))
            guard value.filter(\.isNumber).count >= 5 else { return nil }
            return VaultMention(value: value, category: .passport,
                                source: VaultSource(path: path, role: role, rank: Rank.mention))
        }
    }

    // MARK: Dates

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Apr", "April", "Sept": a month's name or the start of one, three letters at least.
    static func monthNumber(_ word: String) -> Int? {
        let lower = word.lowercased()
        guard lower.count >= 3 else { return nil }
        return monthNames.firstIndex { fullMonth($0).hasPrefix(lower) }.map { $0 + 1 }
    }

    private static func fullMonth(_ short: String) -> String {
        ["jan": "january", "feb": "february", "mar": "march", "apr": "april", "may": "may",
         "jun": "june", "jul": "july", "aug": "august", "sep": "september", "oct": "october",
         "nov": "november", "dec": "december"][short] ?? short
    }

    private static let isoDateInName = try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})[-_.](\d{1,2})(?:[-_.](\d{1,2}))?(?!\d)"#)
    private static let monthYearInName = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-Za-z]{3,9})\.?[\s_-]*((?:19|20)\d{2})(?!\d)"#)
    private static let yearInName = try! NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})(?!\d)"#)

    /// A date in a file's name: "2024-07-15", "Jul 2024", "July 2025", or a year alone
    /// ("Form I-94 2015.pdf", read as that year's first day). Nil when the name has none.
    public static func fileDate(_ path: String) -> Date? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ns = name as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let m = isoDateInName.firstMatch(in: name, range: whole),
           let year = Int(ns.substring(with: m.range(at: 1))), let month = Int(ns.substring(with: m.range(at: 2))) {
            let day = m.range(at: 3).location == NSNotFound ? 1 : Int(ns.substring(with: m.range(at: 3))) ?? 1
            if let date = calendarDate(year: year, month: month, day: day) { return date }
        }
        for m in monthYearInName.matches(in: name, range: whole) {
            if let month = monthNumber(ns.substring(with: m.range(at: 1))),
               let year = Int(ns.substring(with: m.range(at: 2))) {
                return calendarDate(year: year, month: month, day: 1)
            }
        }
        if let m = yearInName.firstMatch(in: name, range: whole), let year = Int(ns.substring(with: m.range(at: 1))),
           year <= Calendar(identifier: .gregorian).component(.year, from: Date()) + 15 {
            return calendarDate(year: year, month: 1, day: 1)
        }
        return nil
    }

    static func calendarDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = DateComponents(year: year, month: month, day: day)
        guard parts.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: parts)
    }

    private static func utcParts(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// "15 April 2032", the same however the Mac is set, so a test can read it back. Spelled from
    /// the date's UTC parts, the zone every date here is made in (``calendarDate(year:month:day:)``).
    public static func spelled(_ date: Date) -> String {
        let parts = utcParts(date)
        let name = fullMonth(monthNames[max(0, min(11, (parts.month ?? 1) - 1))])
        return "\(parts.day ?? 1) \(name.prefix(1).uppercased() + name.dropFirst()) \(parts.year ?? 0)"
    }

    /// "Jan 2014", for a row. Empty for no date.
    public static func monthYear(_ date: Date?) -> String {
        guard let date else { return "" }
        let parts = utcParts(date)
        let short = monthNames[max(0, min(11, (parts.month ?? 1) - 1))]
        return "\(short.prefix(1).uppercased() + short.dropFirst()) \(parts.year ?? 0)"
    }

    /// "05/16/2032": what Copy gives for a date, the way US forms ask for it.
    public static func formDate(_ date: Date) -> String {
        let parts = utcParts(date)
        return String(format: "%02d/%02d/%04d", parts.month ?? 1, parts.day ?? 1, parts.year ?? 0)
    }

    /// Whether a document good until `validUntil` has run out by `now`. Good through the whole of
    /// its last day where the Mac is, not only until midnight in UTC, which in California is the
    /// afternoon before.
    public static func hasRunOut(_ validUntil: Date?, now: Date, timeZone: TimeZone = .current) -> Bool {
        guard let validUntil else { return false }
        let last = utcParts(validUntil)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let today = local.dateComponents([.year, .month, .day], from: now)
        let a = (last.year ?? 0, last.month ?? 0, last.day ?? 0)
        let b = (today.year ?? 0, today.month ?? 0, today.day ?? 0)
        return b > a
    }

    // MARK: Archive folders

    /// Whether `path` sits in an Archive folder (or Archived, Old, Expired) below the folder it was
    /// read from. A folder above that, such as all of `~/Documents/Archive` being read, says
    /// nothing about one copy against another.
    public static func isArchivePath(_ path: String, under readFolders: [String] = []) -> Bool {
        let root = readFolders.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        let below = root.map { String(path.dropFirst($0.count + 1)) } ?? path
        return (below as NSString).deletingLastPathComponent.split(separator: "/").contains { isArchiveName(String($0)) }
    }

    private static func isArchiveName(_ name: String) -> Bool {
        ["archive", "archived", "archives", "old", "older", "expired"].contains(name.lowercased())
    }

    // MARK: Shared

    /// Look-alikes Vision reads in a field that holds only digits.
    static let digitLookalikes: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6",
    ]

    static func fixedDigits(_ s: String) -> String {
        String(s.uppercased().map { digitLookalikes[$0] ?? $0 })
    }

    /// Notes joined, the first word capitalised.
    static func sentence(_ parts: [String]) -> String {
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// A machine-readable zone at the foot of a passport's photo page (ICAO Doc 9303 TD3, two lines
/// of 44) or on a visa foil (MRV-A of 44, MRV-B of 36).
public struct MachineZone: Equatable, Sendable {
    public enum Kind: Sendable { case passport, visa }

    public var kind: Kind
    public var number: String
    /// The issuing state from the name line, else the nationality on the number line.
    public var issuer: String
    public var nationality: String
    public var surname: String
    public var givenNames: String
    public var expires: Date
    public var born: Date
    /// Whether the name line above the number was read.
    public var nameRead: Bool

    /// The holder as printed, in reading order: "Anna Maria Eriksson".
    public var holder: String {
        [givenNames, surname].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func passportFind(from path: String, page: Int?) -> VaultFind {
        let where_ = page.map { " · page \($0)" } ?? ""
        var details = [VaultDetail("Issuing country", .text(issuer))]
        if nationality != issuer && !nationality.isEmpty { details.append(VaultDetail("Nationality", .text(nationality))) }
        details.append(VaultDetail(VaultReading.hasRunOut(expires, now: Date()) ? "Expired" : "Expires", .date(expires)))
        let facts = VaultReadFacts(category: .passport, holder: holder.isEmpty ? nil : holder, born: born,
                                   issuer: issuer, dated: expires, validUntil: expires, details: details,
                                   sources: [VaultSource(path: path, role: "Passport photo page" + where_,
                                                         rank: VaultReading.Rank.passportPage + (nameRead ? 1 : 0))])
        let note = [holder, "\(issuer) passport", "expires \(VaultReading.spelled(expires))"].filter { !$0.isEmpty }
        return VaultFind(title: "Passport", value: number, note: VaultReading.sentence(note), facts: facts)
    }

    /// A visa, known by the Control Number printed on its foil; nil when that was not read. Its
    /// zone's number is the passport it is in, kept as ``VaultReadFacts/inPassport``.
    func visaFind(from path: String, page: Int?, text: String) -> VaultFind? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let control = Self.controlNumberPattern.firstMatch(in: text, range: whole)
            .map({ VaultReading.normalized(ns.substring(with: $0.range(at: 1))) }),
              control.filter(\.isNumber).count >= 8 else { return nil }
        let where_ = page.map { " · page \($0)" } ?? ""
        let visaClass = Self.visaClassPattern.firstMatch(in: text, range: whole)
            .map { ns.substring(with: $0.range(at: 1)).uppercased() }
        let issued = Self.foilDate(Self.issueDatePattern, in: text)
        var details: [VaultDetail] = []
        if let visaClass { details.append(VaultDetail("Visa class", .text(visaClass))) }
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        details.append(VaultDetail(VaultReading.hasRunOut(expires, now: Date()) ? "Expired" : "Expires", .date(expires)))
        details.append(VaultDetail("In passport", .number(number)))
        let country = issuer == "USA" ? "US" : issuer
        let facts = VaultReadFacts(category: .usVisa, holder: holder.isEmpty ? nil : holder, born: born,
                                   issuer: issuer, dated: issued ?? expires, validUntil: expires,
                                   inPassport: number, details: details,
                                   sources: [VaultSource(path: path, role: "Visa foil" + where_, rank: VaultReading.Rank.visaFoil)])
        let title = "\(country) visa" + (visaClass.map { " · \($0)" } ?? "")
        let note = [holder, "expires \(VaultReading.spelled(expires))"].filter { !$0.isEmpty }
        return VaultFind(title: title, value: control, note: VaultReading.sentence(note), facts: facts)
    }

    private static let controlNumberPattern = try! NSRegularExpression(
        pattern: #"control\s*(?:number|no\.?)\s*:?\s*\n?\s*([0-9OIL]{8,14}[A-Z0-9]{0,4})\b"#, options: [.caseInsensitive])

    private static let visaClassPattern = try! NSRegularExpression(
        pattern: #"(?:visa\s*type\s*/?\s*class|class)\s*:?\s*\n?\s*([A-Z]-?[0-9][A-Z0-9]?)\b"#, options: [.caseInsensitive])
    private static let issueDatePattern = try! NSRegularExpression(
        pattern: #"issue\s*date\s*:?\s*\n?\s*(\d{2})\s*([A-Z]{3})\s*(\d{4})"#, options: [.caseInsensitive])

    /// "02OCT2024", as a visa foil prints its dates.
    private static func foilDate(_ pattern: NSRegularExpression, in text: String) -> Date? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let day = Int(ns.substring(with: match.range(at: 1))),
              let month = VaultReading.monthNumber(ns.substring(with: match.range(at: 2))),
              let year = Int(ns.substring(with: match.range(at: 3))) else { return nil }
        return VaultReading.calendarDate(year: year, month: month, day: day)
    }

    /// Every zone on one page whose check digits agree, each with the name line directly above
    /// its number line. Several passports scanned onto one page are several zones.
    public static func zones(in lines: [String]) -> [MachineZone] {
        let cleaned = lines.map(clean)
        var out: [MachineZone] = []
        // A number line may carry up to two characters Vision could not read ("~" for a digit):
        // ``readSecondLine`` tries each fill and keeps only one the check digits single out.
        for (index, line) in cleaned.enumerated()
        where line.count >= 28 && line.filter({ !allowed.contains($0) }).count <= 2 && line.filter(\.isNumber).count >= 10 {
            // The name line: the nearest line above that looks like one, skipping a blank.
            let above = cleaned[max(0, index - 2)..<index].reversed()
                .first { $0.count >= 30 && $0.contains("<") && $0.allSatisfy { allowed.contains($0) } }
            let first = above?.first
            let kind: Kind?
            switch first {
            case "P"?: kind = .passport
            case "V"?: kind = .visa
            case nil: kind = nil
            default: continue   // An identity card or residence permit: not a kind the Vault reads.
            }
            guard let zone = readSecondLine(line, nameLine: above, kind: kind),
                  !out.contains(where: { $0.number == zone.number }) else { continue }
            out.append(zone)
        }
        return out
    }

    /// The zone on a page, or nil: the first of ``zones(in:)``.
    public static func read(_ lines: [String]) -> MachineZone? { zones(in: lines).first }

    static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    /// Upper case, no spaces, and the shapes Vision gives the filler `<`.
    static func clean(_ line: String) -> String {
        var text = line.uppercased().replacingOccurrences(of: " ", with: "")
        for (seen, filler) in [("«", "<<"), ("‹", "<"), ("≤", "<"), ("〈", "<"), ("＜", "<")] {
            text = text.replacingOccurrences(of: seen, with: filler)
        }
        return text
    }

    /// The check digit of `field`: weights 7, 3, 1 over the characters' values, modulo 10.
    static func checkDigit<S: StringProtocol>(_ field: S) -> Int {
        let weights = [7, 3, 1]
        var sum = 0
        for (index, scalar) in field.unicodeScalars.enumerated() {
            let value: Int
            switch scalar.value {
            case 48...57: value = Int(scalar.value) - 48
            case 65...90: value = Int(scalar.value) - 55
            default: value = 0
            }
            sum += value * weights[index % 3]
        }
        return sum % 10
    }

    /// The number line as read, then with digit look-alikes fixed in the fields that hold only
    /// digits. A reading counts only when the number, birth and expiry checks all agree. A
    /// passport must also be whole, 44 characters, and pass the overall check; with no name line
    /// to say what it is, that is also what tells a passport from a visa.
    private static func readSecondLine(_ line: String, nameLine: String?, kind: Kind?) -> MachineZone? {
        var chars = Array(line)
        // A character Vision added between fields ("-" after the birth date's check digit) makes
        // the line one or two too long and shifts every field after it: drop it.
        let strays = chars.indices.filter { !allowed.contains(chars[$0]) }
        if chars.count > 44, chars.count - 44 <= 2, strays.count == chars.count - 44 {
            for index in strays.reversed() { chars.remove(at: index) }
        }
        // A letter in a field that holds only digits, which no look-alike explains ("A" for a 4),
        // is as unreadable as "~": filled the same way.
        let digitOnly = Set([9] + Array(13...19) + Array(21...27) + (chars.count == 44 ? [42, 43] : []))
        let unknown = chars.indices.filter { index in
            !allowed.contains(chars[index])
                || (digitOnly.contains(index) && chars[index].isLetter && VaultReading.digitLookalikes[chars[index]] == nil)
        }
        let line = String(chars)
        guard !unknown.isEmpty else {
            return readWholeSecondLine(line, nameLine: nameLine, kind: kind)
                ?? readWithSwaps(chars, nameLine: nameLine, kind: kind, digitOnly: digitOnly)
        }
        // More than two is too much guessing to trust a number by.
        guard unknown.count <= 2 else { return nil }
        // Each unreadable character tried as a digit or a filler. A check digit fixes one missing
        // character of its field, so a wrong fill fails a check; a reading counts only when one
        // fill alone passes every check.
        let fills = Array("0123456789<")
        var readings: [MachineZone] = []
        func fill(_ chars: [Character], _ at: Int) {
            guard at < unknown.count else {
                if let zone = readWholeSecondLine(String(chars), nameLine: nameLine, kind: kind),
                   !readings.contains(zone) { readings.append(zone) }
                return
            }
            for character in fills {
                var next = chars
                next[unknown[at]] = character
                fill(next, at + 1)
            }
        }
        fill(Array(line), 0)
        return readings.count == 1 ? readings[0] : nil
    }

    /// What a character in the number may really be: a digit read for the letter it resembles
    /// ("2" for "Z", as on a real scan), or the other way about.
    private static let numberSwaps: [Character: [Character]] = [
        "0": ["O", "Q", "D"], "1": ["I", "L"], "2": ["Z"], "5": ["S"], "6": ["G"], "8": ["B"],
        "O": ["0"], "Q": ["0"], "D": ["0"], "I": ["1"], "L": ["1"], "Z": ["2"], "S": ["5"], "G": ["6"], "B": ["8"],
    ]

    /// A second try for a line that failed its checks: any digit for a letter in a date, and one
    /// swap in the number only where its format leaves no doubt. Kept only when exactly one set of
    /// swaps passes every check.
    ///
    /// The number itself is guarded by a single check: its own digit and the overall one weigh its
    /// characters alike, so a swap in the number can cancel a real misread elsewhere in it and
    /// read a wrong number that passes. The only swap allowed there is an Indian passport's
    /// leading letter read as a digit ("2" for "Z"): those numbers are always a letter and seven
    /// digits, so eight digits is certainly a misread letter.
    private static func readWithSwaps(_ chars: [Character], nameLine: String?, kind: Kind?,
                                      digitOnly: Set<Int>) -> MachineZone? {
        var options: [(Int, [Character])] = []
        for index in chars.indices where digitOnly.contains(index) && chars[index].isLetter {
            options.append((index, Array("0123456789")))
        }
        let nationality = chars.count >= 13 ? String(chars[10..<13]) : ""
        if nationality == "IND", chars.count >= 9, chars[0..<8].allSatisfy(\.isNumber), chars[8] == "<",
           let letters = numberSwaps[chars[0]] {
            options.append((0, letters))
        }
        // The fewest swaps first: two changes can cancel out in a check where one cannot, so pairs
        // are tried only when no single swap reads, and either way the reading must be the only one.
        var singles: [MachineZone] = []
        for (i, swaps) in options {
            for x in swaps {
                var one = chars
                one[i] = x
                if let zone = readWholeSecondLine(String(one), nameLine: nameLine, kind: kind),
                   !singles.contains(zone) { singles.append(zone) }
            }
        }
        if !singles.isEmpty { return singles.count == 1 ? singles[0] : nil }
        var pairs: [MachineZone] = []
        for (a, (i, swapsI)) in options.enumerated() {
            for x in swapsI {
                for (j, swapsJ) in options.dropFirst(a + 1) {
                    for y in swapsJ {
                        var two = chars
                        two[i] = x
                        two[j] = y
                        if let zone = readWholeSecondLine(String(two), nameLine: nameLine, kind: kind),
                           !pairs.contains(zone) { pairs.append(zone) }
                    }
                }
            }
        }
        return pairs.count == 1 ? pairs[0] : nil
    }

    private static func readWholeSecondLine(_ line: String, nameLine: String?, kind: Kind?) -> MachineZone? {
        let digitFields = [9...9, 13...19, 21...27, 42...43]
        var fixed = Array(line)
        for range in digitFields {
            for index in range where index < fixed.count {
                if let digit = VaultReading.digitLookalikes[fixed[index]] { fixed[index] = digit }
            }
        }
        for chars in [Array(line), fixed] where chars.count >= 28 {
            let s = String(chars)
            func field(_ a: Int, _ b: Int) -> Substring {
                s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)]
            }
            func digit(_ i: Int) -> Int? { chars[i].wholeNumberValue }
            guard digit(9) == checkDigit(field(0, 9)),
                  digit(19) == checkDigit(field(13, 19)),
                  digit(27) == checkDigit(field(21, 27)) else { continue }
            let wholePassport = chars.count == 44
                && digit(43) == checkDigit(String(field(0, 10)) + String(field(13, 20)) + String(field(21, 43)))
            let resolved: Kind
            switch kind {
            case .passport?: guard wholePassport else { continue }; resolved = .passport
            case .visa?: resolved = .visa
            case nil: guard wholePassport else { continue }; resolved = .passport
            }
            guard let expires = date(field(21, 27), century: .future),
                  let born = date(field(13, 19), century: .past) else { continue }
            let number = field(0, 9).replacingOccurrences(of: "<", with: "")
            guard number.count >= 6 else { continue }
            let (surname, given) = names(from: nameLine)
            let nationality = String(field(10, 13)).replacingOccurrences(of: "<", with: "")
            let issuingState = nameLine.map { String($0.dropFirst(2).prefix(3)).replacingOccurrences(of: "<", with: "") }
            return MachineZone(kind: resolved, number: number,
                               issuer: (issuingState?.count == 3 ? issuingState : nil) ?? nationality,
                               nationality: nationality, surname: surname, givenNames: given,
                               expires: expires, born: born, nameRead: nameLine != nil)
        }
        return nil
    }

    private enum Century { case past, future }

    /// `YYMMDD`. An expiry is read as 20YY; a birth date as 19YY when 20YY would be in the future.
    private static func date(_ field: Substring, century: Century) -> Date? {
        guard field.count == 6, field.allSatisfy(\.isNumber), let yy = Int(field.prefix(2)),
              let mm = Int(field.dropFirst(2).prefix(2)), let dd = Int(field.suffix(2)) else { return nil }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date()) % 100
        let year = century == .future || yy <= thisYear ? 2000 + yy : 1900 + yy
        return VaultReading.calendarDate(year: year, month: mm, day: dd)
    }

    /// `P<UTOERIKSSON<<ANNA<MARIA<<<` → ("Eriksson", "Anna Maria").
    private static func names(from line: String?) -> (String, String) {
        guard let line, line.count > 5 else { return ("", "") }
        let body = line.dropFirst(5)
        let parts = body.components(separatedBy: "<<")
        func words(_ s: String) -> String {
            s.split(separator: "<").map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        let surname = words(parts.first ?? "")
        let given = parts.count > 1 ? words(parts[1]) : ""
        return (surname, given)
    }
}

/// The folders Read Documents looks in, chosen in Settings ▸ Vault. Paths, kept in UserDefaults
/// like the folders hidden from Claude: a folder's name says where to look, not what was found.
public enum VaultReadFolders {
    public static let key = "vaultReadFolders"

    public static func folders(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Adds `path` unless it, or a folder holding it, is already on the list; a folder that holds
    /// ones already listed takes their place, so nothing is read twice.
    public static func add(_ path: String, in defaults: UserDefaults = .standard) {
        let path = (path as NSString).standardizingPath
        var list = folders(in: defaults)
        guard !list.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        list.removeAll { $0.hasPrefix(path + "/") }
        list.append(path)
        defaults.set(list, forKey: key)
    }

    public static func remove(_ path: String, in defaults: UserDefaults = .standard) {
        defaults.set(folders(in: defaults).filter { $0 != path }, forKey: key)
    }
}

/// Numbers Read Documents should not offer again: set aside from To Confirm, or removed from the
/// Vault after being read. Fingerprints (``VaultStore/fingerprint(_:)``), never the numbers.
public enum VaultSetAside {
    public static let key = "vaultSetAside"

    public static func fingerprints(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public static func add(_ fingerprint: String, in defaults: UserDefaults = .standard) {
        var all = fingerprints(in: defaults)
        guard all.insert(fingerprint).inserted else { return }
        defaults.set(all.sorted(), forKey: key)
    }

    /// Settings ▸ Vault ▸ Forget: the next read offers everything again. That takes reading every
    /// file again, not only the new ones, so the record of what was read is let go too
    /// (``VaultReadingState/generation``).
    public static func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.set(generation(in: defaults) + 1, forKey: generationKey)
    }

    static let generationKey = "vaultReadGeneration"

    /// Raised by every Forget. A record of read files from another generation is not trusted.
    public static func generation(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: generationKey)
    }
}

/// What Read Documents keeps between reads, sealed with the Vault's key in a file of its own:
/// the numbers waiting in To Confirm, and which files have been read, so the next read opens only
/// new and changed ones.
///
/// Its own file, not the Vault's, so a damaged or outdated one is simply started again: nothing
/// in it is the user's own until it is confirmed into the Vault.
public struct VaultReadingState: Codable, Equatable, Sendable {
    /// ``VaultReading/version`` when the files were read. Another version reads everything again.
    public var version: Int
    /// ``VaultSetAside/generation(in:)`` when the files were read.
    public var generation: Int
    public var finds: [VaultFind]
    /// Each file read, by path, against its size and modification date when it was read.
    public var read: [String: String]
    /// Documents that name a number without being its source, by the number: kept so a passport
    /// read later still gets them, and so a saved one does.
    public var mentions: [String: [VaultSource]]

    public init(version: Int = VaultReading.version, generation: Int = 0,
                finds: [VaultFind] = [], read: [String: String] = [:], mentions: [String: [VaultSource]] = [:]) {
        self.version = version
        self.generation = generation
        self.finds = finds
        self.read = read
        self.mentions = mentions
    }
}

extension VaultReadingState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultReadingState(\(finds.count) finds, \(read.count) files read)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
