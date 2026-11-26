import Events
import Foundation
import os

/// A number read from a document, waiting in To Confirm until it is added or set aside.
///
/// Sealed to disk with the Vault's key between reads (``VaultReadingState``), and let go from
/// memory as the entries are: when the Vault closes locked, and when the Mac sleeps or its
/// screen locks. An open panel that locks keeps them, drawn with only their ending. Like
/// ``VaultEntry`` it never prints its number.
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
    /// What the user chose about it (``VaultChoices``). Later reads keep them.
    public var choices: VaultChoices
    /// Current or older, as the user chose.
    public var pin: VaultPin? { get { choices.pin } set { choices.pin = newValue } }
    /// Whose it is, as the user chose.
    public var assignment: VaultAssignment? { get { choices.assignment } set { choices.assignment = newValue } }
    /// Where it is used, as the user chose.
    public var geo: VaultGeo? { get { choices.geo } set { choices.geo = newValue } }
    /// The card it goes on, as the user chose (``VaultCardID``); nil goes by what it was read as.
    public var card: VaultCardID? { get { choices.card } set { choices.card = newValue } }
    /// The copy of its document the user chose to read it from (Read from This Copy), by path;
    /// nil lets the Vault choose.
    public var chosenSource: String? { get { choices.source } set { choices.source = newValue } }

    public init(id: UUID = UUID(), title: String, value: String, note: String = "",
                facts: VaultReadFacts, choices: VaultChoices) {
        self.id = id
        self.title = title
        self.value = value
        self.note = note
        self.facts = facts
        self.choices = choices
    }

    public init(id: UUID = UUID(), title: String, value: String, note: String = "",
                facts: VaultReadFacts, pin: VaultPin? = nil, assignment: VaultAssignment? = nil,
                geo: VaultGeo? = nil, card: VaultCardID? = nil, chosenSource: String? = nil) {
        self.init(id: id, title: title, value: value, note: note, facts: facts,
                  choices: VaultChoices(pin: pin, assignment: assignment, geo: geo, card: card, source: chosenSource))
    }

    /// This reading under `kept`'s id, with the choices made about it: what a re-read of a
    /// number, or a rebuild from its other documents, keeps.
    public func keepingChoices(of kept: VaultChoice) -> VaultFind {
        VaultFind(id: kept.id, title: title, value: value, note: note, facts: facts, choices: kept.choices)
    }

    private enum CodingKeys: String, CodingKey { case id, title, value, note, facts }

    /// The choices sit beside its own fields, as they always have.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        value = try c.decode(String.self, forKey: .value)
        note = try c.decode(String.self, forKey: .note)
        facts = try c.decode(VaultReadFacts.self, forKey: .facts)
        choices = try VaultChoices(from: decoder, sourceKey: "chosenSource")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(value, forKey: .value)
        try c.encode(note, forKey: .note)
        try c.encode(facts, forKey: .facts)
        try choices.encode(to: encoder, sourceKey: "chosenSource")
    }

    public var category: VaultCategory { facts.category }
    public var holder: String? { facts.holder }
    public var dated: Date? { facts.dated }
    public var validUntil: Date? { facts.validUntil }
    /// The document it was read from.
    public var sourcePath: String { facts.primary?.path ?? "" }
}

extension VaultFind: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultFind(\(title), \(VaultMask.described(value, as: facts.category)))" }
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
    public static let version = 29

    /// Every number on a document, once each, and the numbers it only names.
    /// `roots` are the read folders and `people` the household's, for account numbers: which area
    /// a paper is in, and which of its folders names who issued it (``accountNumbers(on:from:under:people:)``).
    /// `origins` says which page of the file each of `pages` is, and which reading of a page read
    /// both ways (``VaultPageSource/filePages(_:)``); nil when each is the page of its place.
    public static func read(pages: [[String]], from path: String, under roots: [String] = [],
                            people: [Person] = [], origins: [VaultPageOrigin]? = nil)
        -> (finds: [VaultFind], mentions: [VaultMention]) {
        let origins = origins.flatMap { $0.count == pages.count ? $0 : nil } ?? pages.indices.map { VaultPageOrigin(page: $0 + 1) }
        var out: [VaultFind] = []
        var seen = Set<String>()
        // Each number kept, by the page of the file: the reading of `pages` that page first gave
        // it from. Per page, so a page read both ways holds its layer over its picture wherever
        // in the file the number was first read (the second review: only that first page did).
        var readOn: [String: [Int: Int]] = [:]
        func keep(_ find: VaultFind, on page: Int) {
            let key = normalized(find.value)
            let filePage = origins[page].page
            if seen.insert(key).inserted {
                out.append(find)
                readOn[key] = [filePage: page]
            } else if let index = out.firstIndex(where: { normalized($0.value) == key }),
                      let held = readOn[key]?[filePage],
                      Set([origins[held].half, origins[page].half]) == [.textLayer, .picture] {
                // One page's text layer and its picture: the layer speaks, as typed (VT88).
                let heldIsLayer = origins[held].half == .textLayer
                let both = heldIsLayer ? VaultCopies.filled(out[index], from: find) : VaultCopies.filled(find, from: out[index])
                out[index] = VaultFind(id: out[index].id, title: both.title, value: both.value, note: both.note, facts: both.facts)
                readOn[key]?[filePage] = heldIsLayer ? held : page
            } else if let index = out.firstIndex(where: { normalized($0.value) == key }),
                      let both = VaultCopies.merged([out[index], find]) {
                // The same number on two pages of one file (a receipt notice, then its approval):
                // the better page speaks, and what it is silent on comes from the other.
                out[index] = VaultFind(id: out[index].id, title: both.title, value: out[index].value,
                                       note: both.note, facts: both.facts)
                if readOn[key]?[filePage] == nil { readOn[key]?[filePage] = page }
            }
        }
        let file = PrintedPage(pages.flatMap { $0 })
        let text = file.text
        // Each page as every reader questions it, made once: its text, lowered and squeezed.
        let printedPages = pages.map(PrintedPage.init)
        var visaPassports: [VaultMention] = []
        var allZones: [MachineZone] = []
        let paged = origins.contains { $0.page > 1 }
        for (index, page) in printedPages.enumerated() {
            let zones = MachineZone.zones(in: page.lines)
            allZones += zones
            for (zone, printed) in zip(zones, MachineZone.sections(of: page, for: zones)) {
                // A visa foil's zone carries the passport's number, not the visa's own: the visa is
                // a document of that passport, and is itself known by its Control Number.
                if zone.document(in: file, section: printed) == .visaFoil {
                    visaPassports.append(VaultMention(value: zone.number, category: .passport,
                                                      source: VaultSource(path: path, role: "US visa", rank: Rank.mention)))
                }
                // Its page of the file, when the file has more than one: a second reading of a
                // page (``VaultPageSource/filePages(_:)``) is that page, never one past the last.
                if let find = zone.find(from: path, page: paged ? origins[index].page : nil, printed: printed, file: file) {
                    keep(find, on: index)
                }
            }
        }
        if let line = MachineZone.recoveryLine(allZones) { Events.Logger.shared.debug(line) }
        // Page by page: one PDF can hold two notices, each for its own person, form and dates.
        for (index, printed) in printedPages.enumerated() {
            for find in receiptNumbers(in: printed.text, from: path) { keep(find, on: index) }
            for find in admissionNumbers(in: printed.text, from: path) { keep(find, on: index) }
            for find in travelPermits(on: printed, from: path) { keep(find, on: index) }
            for find in accountNumbers(on: printed, from: path, under: roots, people: people) { keep(find, on: index) }
        }
        // A license's barcode before its printed front, wherever each is in the file: it states
        // what the front's print can only suggest.
        let identity = printedPages.indices.flatMap { index in
            identityNumbers(on: printedPages[index], from: path, under: roots).map { (index, $0) }
        }
            .enumerated().sorted { a, b in
                let (ba, bb) = (a.element.1.facts.primary?.role.hasSuffix("barcode") == true,
                                b.element.1.facts.primary?.role.hasSuffix("barcode") == true)
                return ba != bb ? ba : a.offset < b.offset
            }
        for (_, (index, find)) in identity { keep(find, on: index) }
        // The home the paper is mailed to and the phones it prints under a name in People, as of
        // the paper's date: read once for the file, and given to each number it holds. A
        // license's barcode keeps the address it states.
        let printedContacts = contacts(in: pages, people: people, origins: origins)
        if printedContacts != VaultPrintedContacts() {
            for index in out.indices {
                let dated = out[index].facts.dated
                for s in out[index].facts.sources.indices where out[index].facts.sources[s].path == path {
                    if out[index].facts.sources[s].address == nil, let address = printedContacts.address {
                        out[index].facts.sources[s].address = VaultPrintedAddress(address, dated: dated)
                    }
                    if !printedContacts.phones.isEmpty {
                        out[index].facts.sources[s].phones = printedContacts.phones.map {
                            var phone = $0
                            phone.dated = dated
                            return phone
                        }
                    }
                }
            }
        }
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

    /// A name as two readings of it are compared: its words, letters only, lower case. "SIGRID
    /// LINNEA BERQ" and "Sigrid Linnea Berq" are one reading; "…Berg" is another.
    public static func spellingKey(_ name: String) -> String {
        letterWords(name).joined(separator: " ")
    }

    /// A name's words, letters only, lower case: "O'Brien-Berq, Anna" is o, brien, berq, anna.
    static func letterWords(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
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

    /// An I-797A approval, an I-797C receipt notice, or neither. `lower` is the text lower-cased,
    /// as each caller already has it.
    static func noticeKind(lowered lower: String) -> (role: String, rank: Int, pending: Bool)? {
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
        pattern: #"\b(?-i:(\#(receiptCenters.joined(separator: "|"))))[\s-]?([0-9OQDILZSBG]{2}[\s-]?[0-9OQDILZSBG]{3}[\s-]?[0-9OQDILZSBG]{5})\b"#,
        options: [.caseInsensitive])

    /// A form named on the page other than the notice itself: "I-129" on an I-797 approval.
    private static let formPattern = try! NSRegularExpression(pattern: #"\bI-([0-9]{3}[A-Z]?)\b"#)
    /// "Valid from 10/01/2026 to 09/30/2029" on an approval notice.
    private static let validPattern = try! NSRegularExpression(
        pattern: #"valid\s*from\s*([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})\s*to\s*([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})"#,
        options: [.caseInsensitive])
    private static let noticeDatePattern = try! NSRegularExpression(
        pattern: #"notice\s*date\s*:?\s*([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})"#, options: [.caseInsensitive])
    private static let receivedDatePattern = try! NSRegularExpression(
        pattern: #"received\s*date\s*:?\s*([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})"#, options: [.caseInsensitive])
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
        return titleCased(parts.count == 2 ? parts[1] + " " + parts[0] : printed)
    }

    static func receiptNumbers(in text: String, from path: String) -> [VaultFind] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let lower = text.lowercased()
        let notice = noticeKind(lowered: lower)
        let noticeDate = slashDate(noticeDatePattern.firstMatch(in: text, range: whole), in: ns, at: 1)
        let received = slashDate(receivedDatePattern.firstMatch(in: text, range: whole), in: ns, at: 1)
        let valid = validPattern.firstMatch(in: text, range: whole)
        let validFrom = slashDate(valid, in: ns, at: 1)
        let validUntil = slashDate(valid, in: ns, at: 4)
        // A notice's own kind (I-797, I-797A…E) is never the case's form.
        let forms = formPattern.matches(in: text, range: whole)
            .filter { !ns.substring(with: $0.range(at: 1)).hasPrefix("797") }
            .map { (range: $0.range, value: "I-" + ns.substring(with: $0.range(at: 1))) }
        let holders = caseHolderPattern.matches(in: text, range: whole)
            .map { (range: $0.range, value: readingOrder(ns.substring(with: $0.range(at: 1)))) }
        let source = VaultSource(path: path, role: notice?.role ?? "USCIS notice", rank: notice?.rank ?? Rank.mention)
        // A center's letters set apart from the digits ("LIN 4155551234") are as likely a surname
        // and a phone number: taken only on a page about a case. Run together, they are a receipt.
        let aboutACase = notice != nil
            || ["receipt number", "receipt #", "uscis", "i-797", "immigration services", "case status"].contains(where: lower.contains)
        // The receipt numbers the page gives, each as read: its range, and its number.
        let receipts: [(range: NSRange, value: String)] = receiptPattern.matches(in: text, range: whole).compactMap { match in
            let center = ns.substring(with: match.range(at: 1)).uppercased()
            let joined = match.range(at: 2).location == match.range(at: 1).location + match.range(at: 1).length
            guard joined || aboutACase else { return nil }
            let read = normalized(ns.substring(with: match.range(at: 2)))
            // Mostly digits as printed: look-alikes are forgiven a few at a time, and a run of
            // letters that only become digits once fixed is a word, not a number.
            guard read.filter(\.isNumber).count >= 7 else { return nil }
            return (match.range, center + fixedDigits(read))
        }
        // A page of one case names its form and its person anywhere on it: the first is taken. A
        // page of several (a case list, a family's notices) prints each with its own, in its
        // section: after its number as a rule, each number taking the first printed between it and
        // the next number, else the last before it (VT93; the 2026-11-25 review: counted in
        // characters, the previous section's person, ending a line above, was nearer than the
        // receipt's own below it). A page that prints one above every number and none after the
        // last prints them before: each number takes the last above it. A number with none of its
        // own, before or after, takes the page's first, as every number did before VT93 (the final
        // review: a linked petition's number took a notice's only applicant from the one above).
        let several = Set(receipts.map(\.value)).count > 1
        func own(_ found: [(range: NSRange, value: String)], for index: Int) -> String? {
            guard several, let last = receipts.last else { return found.first?.value }
            let printedAbove = receipts.indices.allSatisfy { receipt in
                let from = receipt == 0 ? 0 : NSMaxRange(receipts[receipt - 1].range)
                let to = receipts[receipt].range.location
                return found.contains { $0.range.location >= from && NSMaxRange($0.range) <= to }
            } && !found.contains { $0.range.location >= NSMaxRange(last.range) }
            let before = found.last { NSMaxRange($0.range) <= receipts[index].range.location }
            if printedAbove { return before?.value }
            let start = NSMaxRange(receipts[index].range)
            let end = index + 1 < receipts.count ? receipts[index + 1].range.location : ns.length
            if let after = found.first(where: { $0.range.location >= start && $0.range.location < end }) { return after.value }
            return (before ?? found.first)?.value
        }
        return receipts.indices.map { index in
            let form = own(forms, for: index), holder = own(holders, for: index)
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
            let facts = VaultReadFacts(category: .uscisCase, holder: holder, form: form,
                                       dated: noticeDate ?? received ?? fileDate(path), validUntil: validUntil,
                                       pending: notice?.pending ?? false, details: details, sources: [source])
            return VaultFind(title: form.map { "\($0) case" } ?? "USCIS receipt number",
                             value: receipts[index].value, note: sentence(notes), facts: facts)
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
    ///
    /// The number's letters are upper case, as printed, though the label's are not: a word's last
    /// lower-case letter ("records 1234567890") is no look-alike digit.
    private static let admissionPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:I\#(hyphen)?94|[1l|]\#(hyphen)94|admission)(?![A-Za-z0-9])[^\n0-9]{0,40}?(?<![A-Za-z])(?-i:((?:[0-9OQDILZSBG]\s?){9}[A-Z0-9]\s?[0-9OQDILZSBG]))(?![0-9])"#,
        options: [.caseInsensitive])

    /// A hyphen, a soft hyphen, the Unicode dashes, or a minus sign.
    private static let hyphen = #"[-\x{00AD}\x{2010}-\x{2015}\x{2212}]"#

    // CBP's web printout draws each label several times over ("Last/Surname:Last/Surname:…:
    // ERIKSSON"): a run of the label is skipped and the value after the last is taken, from the
    // same line only, so neither the next label nor the next line is ever read as the value.

    /// The printout's date of entry: "Arrival/Issued Date: 2026 April 12" since 2025, "Most Recent
    /// Date of Entry: 2015 Jan 12" before.
    private static let entryDatePattern = try! NSRegularExpression(
        pattern: #"(?:(?:arrival\s*/\s*issued\s*date|date\s*of\s*entry)[ \t]*:?[ \t]*)+([0-9]{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+([0-9]{1,2})"#,
        options: [.caseInsensitive])
    private static let admitUntilPattern = try! NSRegularExpression(
        pattern: #"(?:admit\s*until\s*date[ \t]*:?[ \t]*)+([0-9]{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+([0-9]{1,2})"#,
        options: [.caseInsensitive])
    private static let birthDatePattern = try! NSRegularExpression(
        pattern: #"(?:birth\s*date[ \t]*:?[ \t]*)+([0-9]{4})[ \t]+([A-Za-z]{3,9})\.?[ \t]+([0-9]{1,2})"#, options: [.caseInsensitive])
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
        guard !letterWords(name).contains(where: labelWords.contains) else { return nil }
        return titleCased(name)
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
        } else if noticeKind(lowered: lower) != nil {
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
        // "Admission" alone labels a hospital's admission number as readily as CBP's: it counts
        // only on a page that is about an I-94.
        let aboutAnI94 = ["i-94", "i94", "i\u{00AD}94", "1-94", "cbp", "admit until", "arrival/departure", "class of admission"]
            .contains(where: lower.contains)
        return admissionPattern.matches(in: text, range: whole).compactMap { match in
            let label = ns.substring(with: NSRange(location: match.range.location,
                                                   length: match.range(at: 1).location - match.range.location))
            guard label.contains("94") || aboutAnI94 else { return nil }
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
        let lower = text.lowercased()
        let role = lower.contains("i-94") || lower.contains("admission") ? "I-94"
            : noticeKind(lowered: lower)?.role ?? "Names it"
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

    private static let isoDateInName = try! NSRegularExpression(pattern: #"(?<![0-9])((?:19|20)[0-9]{2})[-_.]([0-9]{1,2})(?:[-_.]([0-9]{1,2}))?(?![0-9])"#)
    private static let monthYearInName = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])([A-Za-z]{3,9})\.?[\s_-]*((?:19|20)[0-9]{2})(?![0-9])"#)
    private static let yearInName = try! NSRegularExpression(pattern: #"(?<![0-9])((?:19|20)[0-9]{2})(?![0-9])"#)
    /// The furthest a year alone in a file's name may be past this one and still be its date.
    private static let yearsAheadInName = 15

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
           year <= Calendar(identifier: .gregorian).component(.year, from: Date()) + yearsAheadInName {
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
        utc.dateComponents([.year, .month, .day], from: date)
    }

    /// The Gregorian calendar in `timeZone`, kept for the zone last asked: a `Calendar` is costly
    /// to build, and the panel asks per row per draw (VT102).
    private static func calendar(in timeZone: TimeZone) -> Calendar {
        localCalendar.withLock { held in
            if let held, held.timeZone == timeZone { return held }
            var calendar = utc
            calendar.timeZone = timeZone
            held = calendar
            return calendar
        }
    }
    private static let localCalendar = OSAllocatedUnfairLock<Calendar?>(initialState: nil)

    /// Made once: a `Calendar` is costly to build, and the panel asks per row per draw (VT102).
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

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
        return daysLeft(validUntil, now: now, timeZone: timeZone) < 0
    }

    /// Days from today (by the Mac's clock, in `timeZone`) to a document's last valid day (as
    /// printed, kept in UTC): 0 on that day, negative once it has run out. The one rule
    /// ``hasRunOut(_:now:timeZone:)`` and the panel's "Expires in N days" share (VT102).
    public static func daysLeft(_ validUntil: Date, now: Date, timeZone: TimeZone = .current) -> Int {
        let today = calendar(in: timeZone).dateComponents([.year, .month, .day], from: now)
        guard let end = utc.date(from: utcParts(validUntil)), let start = utc.date(from: today) else { return 0 }
        return utc.dateComponents([.day], from: start, to: end).day ?? 0
    }

    // MARK: Archive folders

    /// Whether `path` sits in an Archive folder (or Archived, Old, Expired, Backup) below the folder
    /// it was read from. A folder above that, such as all of `~/Documents/Archive` being read, says
    /// nothing about one copy against another. Given no read folder that holds `path`, an Archive
    /// folder anywhere counts, as it always has, but a Backup folder does not: a whole drive or
    /// folder called Backup is often where everything lives (VT50, the 2026-11-25 review).
    public static func isArchivePath(_ path: String, under readFolders: [String] = []) -> Bool {
        let root = readFolders.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        let below = root.map { String(path.dropFirst($0.count + 1)) } ?? path
        return (below as NSString).deletingLastPathComponent.split(separator: "/").contains {
            let name = $0.lowercased()
            return archiveNames.contains(name) || (root != nil && backupNames.contains(name))
        }
    }

    /// Whether `path` sits in an Archive or Backup folder anywhere: for ranking one copy against
    /// another (``VaultReadFacts/supersedes(_:_:)``), where a folder above both copies weighs on
    /// each alike.
    static func isOldCopyPath(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.split(separator: "/").contains {
            let name = $0.lowercased()
            return archiveNames.contains(name) || backupNames.contains(name)
        }
    }

    /// The folder names that file an old copy, in lower case: what ``isArchivePath(_:under:)``,
    /// a copy's placement, a read's file order and an account's papers all go by.
    static let archiveNames: Set<String> = ["archive", "archived", "archives", "old", "older", "expired"]

    /// Backup folders count as Archive (owner, 2026-11-25), but only below the folder read
    /// (``isArchivePath(_:under:)``).
    static let backupNames: Set<String> = ["backup", "backups"]

    /// Whether a folder name puts a copy below a filed one: Archive and Backup, and folders that
    /// hold papers not yet filed or set down for a while. Those last two rank lower but are not
    /// archived (owner, 2026-11-25): SyncCloud's own inbox rule (TODO anywhere in the name, Inbox,
    /// Unfiled; ``FolderProfile/isInboxPath(_:)``), and TMP or Temp.
    static func ranksBelowFiled(_ folder: String) -> Bool {
        let name = folder.lowercased()
        return archiveNames.contains(name) || backupNames.contains(name)
            || FolderProfile.isInboxPath(name) || name == "tmp" || name == "temp"
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
    /// The index of the number line on its page, so the fields printed with this document are
    /// told from another's on the same page.
    public var line: Int = 0
    /// Whether ``issuer`` was read from the name line. When that was garbled the issuer is only
    /// the holder's nationality, which says nothing about who issued the document.
    public var issuerRead = false
    /// How the number line was read (VT51).
    public var recovery: Recovery = .asRead

    /// How a number line that failed as Vision read it was recovered, if it was. Only
    /// ``printedNumber`` has a witness of its own. With check weights 7-3-1, one unknown digit in a
    /// checked field always has exactly one digit that passes that field's check, and the overall
    /// check weighs the same characters again, so "only one fill passes" is mostly the check
    /// digits answering themselves, not a second reading of the paper.
    public enum Recovery: String, CaseIterable, Sendable {
        /// Every check passed as read: look-alike letters in the date and check fields ("O" for
        /// 0) put back, and on a line too long by one or two, that many characters no zone holds
        /// dropped.
        case asRead
        /// One or two characters Vision could not read, or letters in a field of digits that no
        /// look-alike explains ("A" for a 4), filled so that one reading alone passes. Also
        /// counted when the character is in no checked field (the sex, a visa's optional data):
        /// every fill there reads the same, so nothing was recovered.
        case fill
        /// A look-alike letter in a field of digits that its usual digit does not fit ("B" for a
        /// 6, not an 8) swapped for another, or an Indian passport's leading letter read as a
        /// digit swapped back: after a failed check (``readWithSwaps(_:nameLine:kind:digitOnly:)``),
        /// or one that passed as G, L or U read as 6, 1 or 0 (VT46).
        case swap
        /// A visa's passport number taken from the number the foil prints beside its zone.
        case printedNumber
    }

    /// The holder as printed, in reading order: "Anna Maria Eriksson".
    public var holder: String {
        [givenNames, surname].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What a zone's document is. Its first letter says passport or visa; a visa's zone is also
    /// how India prints an OCI card, whose number is the card's own where a visa's is the passport's.
    enum Document { case passport, visaFoil, ociCard }

    /// A visa zone is an OCI card's in a file that says OCI, unless its own part of the page is a
    /// US visa's: it prints a Control Number, or its name line says the US issued it. Not "issued
    /// by India" alone: a card's name line read as "VI…" for "V<…" (one of the household's cards)
    /// shifts the issuing state out of place, and with none read the issuer is only the holder's
    /// nationality, often the US.
    func document(in file: PrintedPage, section: PrintedPage) -> Document {
        switch kind {
        case .passport: return .passport
        case .visa:
            let usVisa = section.says("control number") || (issuerRead && issuer == "USA")
            return !usVisa && file.saysAny(["overseas citizen of india", "oci card holder"]) ? .ociCard : .visaFoil
        }
    }

    /// Each zone's own part of `page`: the lines after the zone before it, through to its own
    /// number line, as a photo page or a foil prints its fields above its zone. The last zone also
    /// takes what follows it. One zone alone takes the whole page.
    ///
    /// Not when the zones were read one after another, as Vision reads two documents scanned side
    /// by side: every field first, then both zones. A part holding nothing but its own zone (its
    /// name and number lines) says whose fields are whose no better than the page, so then each
    /// zone takes the whole page.
    static func sections(of printed: PrintedPage, for zones: [MachineZone]) -> [PrintedPage] {
        let page = printed.lines
        let whole = Array(repeating: printed, count: zones.count)
        guard zones.count > 1 else { return whole }
        let ordered = zones.map(\.line)
        let parts = zones.map { zone -> ArraySlice<String> in
            let start = ordered.filter { $0 < zone.line }.max().map { $0 + 1 } ?? 0
            let end = zone.line == ordered.max() ? page.count - 1 : zone.line
            return page[start...max(start, end)]
        }
        guard parts.allSatisfy({ $0.count > 2 }) else { return whole }
        return parts.map { PrintedPage(Array($0)) }
    }

    /// The find for this zone's document: `printed` is the zone's page, `file` the whole file
    /// (an OCI card's back, with its issue date, is a page of its own).
    func find(from path: String, page: Int?, printed: PrintedPage, file: PrintedPage) -> VaultFind? {
        switch document(in: file, section: printed) {
        case .passport: return passportFind(from: path, page: page, printed: printed)
        case .visaFoil: return visaFind(from: path, page: page, printed: printed)
        case .ociCard: return ociFind(from: path, page: page, printed: file)
        }
    }

    func passportFind(from path: String, page: Int?, printed: PrintedPage = PrintedPage([])) -> VaultFind {
        let where_ = page.map { " · page \($0)" } ?? ""
        var details = [VaultDetail("Issuing country", .text(issuer))]
        if nationality != issuer && !nationality.isEmpty { details.append(VaultDetail("Nationality", .text(nationality))) }
        if let issued = printed.issueDate(born: born, expires: expires) { details.append(VaultDetail("Issued", .date(issued))) }
        details.append(VaultDetail("Valid until", .date(expires)))
        let facts = VaultReadFacts(category: .passport, holder: holder.isEmpty ? nil : holder, born: born,
                                   issuer: issuer, dated: expires, validUntil: expires, details: details,
                                   sources: [VaultSource(path: path, role: "Passport photo page" + where_,
                                                         rank: VaultReading.Rank.passportPage + (nameRead ? 1 : 0))])
        let note = [holder, "\(issuer) passport", "expires \(VaultReading.spelled(expires))"].filter { !$0.isEmpty }
        return VaultFind(title: "Passport", value: number, note: VaultReading.sentence(note), facts: facts)
    }

    /// A visa, known by the Control Number printed on its foil; nil when that was not read. Its
    /// zone's number is the passport it is in, kept as ``VaultReadFacts/inPassport``.
    func visaFind(from path: String, page: Int?, printed: PrintedPage) -> VaultFind? {
        guard let read = printed.value(["control number", "control no"], Self.controlNumber).map(VaultReading.normalized),
              read.filter(\.isNumber).count >= 8 else { return nil }
        // The digits Vision read as look-alike letters (2O24… for 2024…), put back; the letters a
        // Control Number may end with are kept.
        let digitsRun = read.prefix { $0.isNumber || "OIL".contains($0) }
        let control = String(digitsRun.map { $0 == "O" ? "0" : $0 == "I" || $0 == "L" ? "1" : $0 })
            + read.dropFirst(digitsRun.count)
        let where_ = page.map { " · page \($0)" } ?? ""
        // The type letter may be read on its own line between the label and the class.
        let visaClass = printed.value(["visa type / class", "visa type", "class"], Self.visaClass, below: 2)?.uppercased()
        let issued = printed.issueDate(born: born, expires: expires)
        var details: [VaultDetail] = []
        if let visaClass { details.append(VaultDetail("Visa class", .text(visaClass))) }
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        details.append(VaultDetail("Valid until", .date(expires)))
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

    /// An OCI card, known by its own number. It is for life, so it has no Valid until: the date
    /// in its zone's expiry field is not one (a card printed "LIFELONG" carried a 2019 date
    /// there). India prints dates day first. The passport it was issued against is a detail,
    /// never the visa's ``VaultReadFacts/inPassport``, so it does not keep an expired passport
    /// in use.
    func ociFind(from path: String, page: Int?, printed: PrintedPage) -> VaultFind {
        let where_ = page.map { " · page \($0)" } ?? ""
        let issued = printed.issueDate(born: born, expires: nil, order: .dayFirst)
        let passport = printed.value(["passport no", "passport number"], VaultReading.passportNumber)
            .map(VaultReading.normalized)
            .flatMap { $0 == VaultReading.normalized(number) ? nil : $0 }
        var details: [VaultDetail] = []
        if !nationality.isEmpty { details.append(VaultDetail("Nationality", .text(nationality))) }
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        details.append(VaultDetail("Valid", .text("Lifelong")))
        if let passport { details.append(VaultDetail("Passport", .number(passport))) }
        let facts = VaultReadFacts(category: .usVisa, holder: holder.isEmpty ? nil : holder, born: born, issuer: "IND",
                                   form: "OCI", dated: issued, details: details,
                                   sources: [VaultSource(path: path, role: "OCI card" + where_, rank: VaultReading.Rank.visaFoil)])
        let note = [holder, "OCI for life"].filter { !$0.isEmpty }
        return VaultFind(title: "OCI card", value: number, note: VaultReading.sentence(note), facts: facts)
    }

    /// A Control Number: eight to fourteen digits (Vision may read 0 and 1 as O, I or L), up to
    /// four letters or digits after. It ends at anything but a letter or digit: a scan can leave
    /// a mark straight after it ("…0001ź"), where a word boundary would not end it.
    private static let controlNumber = try! NSRegularExpression(
        pattern: #"[0-9OIL]{8,14}[A-Z0-9]{0,4}(?![A-Za-z0-9])"#, options: [.caseInsensitive])
    /// A visa's class: "H-1B", "B1/B2", "F1", after the foil's one-letter visa type when it is read
    /// on the same line ("R H1B").
    private static let visaClass = try! NSRegularExpression(
        pattern: #"(?:[A-Z][ \t]+)?([A-Z]-?[0-9][A-Z0-9]?(?:/[A-Z]-?[0-9][A-Z0-9]?)?)(?![A-Za-z0-9])"#,
        options: [.caseInsensitive])

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
            guard let zone = readSecondLine(line, nameLine: above, kind: kind)
                    ?? (kind == .visa ? readWithPrintedNumber(line, nameLine: above, page: lines.map { $0.uppercased() })
                        .map { $0.recovered(.printedNumber) } : nil),
                  // The same zone read twice is one; a passport and the visa in it, scanned onto one
                  // page, share a number and are two.
                  !out.contains(where: { $0.number == zone.number && $0.kind == zone.kind }) else { continue }
            var placed = zone
            placed.line = index
            out.append(placed)
        }
        return out
    }

    /// The zone on a page, or nil: the first of ``zones(in:)``.
    public static func read(_ lines: [String]) -> MachineZone? { zones(in: lines).first }

    static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

    /// Upper case, no spaces, and the shapes Vision gives the filler `<`.
    static func clean(_ line: String) -> String {
        // A letter Vision gave an accent ("Ž" for Z, "Š" for S) is that letter: no zone holds an
        // accent (VT47). "Ø" is no accent and stays unreadable, as a slashed zero should.
        var text = line.uppercased().replacingOccurrences(of: " ", with: "")
            .folding(options: .diacriticInsensitive, locale: nil)
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
            if let whole = readWholeSecondLine(line, nameLine: nameLine, kind: kind) {
                return readWithIndianLetter(chars, nameLine: nameLine, kind: kind)?.recovered(.swap) ?? whole
            }
            return readWithSwaps(chars, nameLine: nameLine, kind: kind, digitOnly: digitOnly).map { $0.recovered(.swap) }
        }
        // More than two is too much guessing to trust a number by.
        guard unknown.count <= 2 else { return nil }
        // A character of the number unreadable: the check passes a digit and every letter worth ten,
        // twenty or thirty more alike (5, F, P, Z), so no one reading can be told, and the number is
        // not guessed: a Z once came back as 5 (VT47; VT46 for an Indian number's first letter). A
        // visa's foil may still print it (``readWithPrintedNumber(_:nameLine:page:)``).
        if unknown.contains(where: { $0 < 9 }) { return nil }
        // Each unreadable character tried as a digit or a filler. A check digit fixes one missing
        // character of its field, so a wrong fill fails a check; a reading counts only when one
        // fill alone passes every check.
        let fills = Array("0123456789<")
        var readings: [MachineZone] = []
        func fill(_ chars: [Character], _ at: Int) {
            guard at < unknown.count else {
                if let zone = readWholeOrLetter(chars, nameLine: nameLine, kind: kind),
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
        return readings.count == 1 ? readings[0].recovered(.fill) : nil
    }

    /// This zone, marked as recovered `how`. Marked once the one reading is chosen, so readings
    /// are told apart by what they read alone.
    private func recovered(_ how: Recovery) -> MachineZone {
        var zone = self
        zone.recovery = how
        return zone
    }

    /// The log line for the zones one reading of a document found, a count per kind of
    /// recovery; nil with none. Counts only: never a number, nor the file's name, which can hold
    /// one. Said once per reading, not per document: a page is tried several ways (its text
    /// layer, its picture, its ink alone) before the reading kept, and each says its line.
    static func recoveryLine(_ zones: [MachineZone]) -> String? {
        guard !zones.isEmpty else { return nil }
        let counts = Recovery.allCases.map { how in "\(how.rawValue) \(zones.filter { $0.recovery == how }.count)" }
        return "Vault: \(zones.count) machine-readable zone(s) read: " + counts.joined(separator: ", ")
    }

    /// The letters a digit in the number may really be, read for the letter it resembles ("2"
    /// for "Z", as on a real scan): asked only of an Indian passport's leading character, read as
    /// a digit (``readWithSwaps(_:nameLine:kind:digitOnly:)``).
    private static let numberSwaps: [Character: [Character]] = [
        "0": ["O", "Q", "D"], "1": ["I", "L"], "2": ["Z"], "5": ["S"], "6": ["G"], "8": ["B"],
    ]

    /// The letters a leading digit of an Indian passport's number may be though the line passed:
    /// each is worth ten more than the digit (G 16, L 21, U 30), so in the 7-3-1 checks it adds
    /// the same and no check can fail (VT46). Only these look-alikes: the other letters ten, twenty
    /// or thirty up (Q, B, V, A, K) look nothing like their digits.
    private static let passingLetters: [Character: Character] = ["6": "G", "1": "L", "0": "U"]

    /// An Indian passport's line that passed with eight digits and a filler for its number: those
    /// numbers are always a letter and seven digits, so the first was a letter read as a digit,
    /// and when it is one that passes as its look-alike, the number is read with the letter.
    /// Kept only when the line with it passes every check too, as it must.
    private static func readWithIndianLetter(_ chars: [Character], nameLine: String?, kind: Kind?) -> MachineZone? {
        guard isIndianNumber(chars, nameLine: nameLine, kind: kind), chars[0..<8].allSatisfy(\.isNumber),
              chars[8] == "<", let letter = passingLetters[chars[0]] else { return nil }
        var read = chars
        read[0] = letter
        return readWholeSecondLine(String(read), nameLine: nameLine, kind: kind)
    }

    /// Whether a number line's number is an Indian passport's: an Indian holder's passport, or
    /// the passport number a US visa's zone carries for one. Another country's visa carries its
    /// own number, whatever its holder's nationality.
    private static func isIndianNumber(_ chars: [Character], nameLine: String?, kind: Kind?) -> Bool {
        guard chars.count >= 13, String(chars[10..<13]) == "IND" else { return false }
        guard kind == .visa else { return true }
        let issuer = nameLine.map { Array($0) }.flatMap { $0.count >= 5 ? String($0[2..<5]) : nil }
        return issuer == "USA"
    }

    /// A line read whole, with an Indian passport's leading letter put back when it passed as a
    /// digit (``readWithIndianLetter(_:nameLine:kind:)``): how every filled or swapped line is read.
    private static func readWholeOrLetter(_ chars: [Character], nameLine: String?, kind: Kind?) -> MachineZone? {
        readWithIndianLetter(chars, nameLine: nameLine, kind: kind)
            ?? readWholeSecondLine(String(chars), nameLine: nameLine, kind: kind)
    }

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
        if isIndianNumber(chars, nameLine: nameLine, kind: kind), chars[0..<8].allSatisfy(\.isNumber), chars[8] == "<",
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
                if let zone = readWholeOrLetter(one, nameLine: nameLine, kind: kind),
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
                        if let zone = readWholeOrLetter(two, nameLine: nameLine, kind: kind),
                           !pairs.contains(zone) { pairs.append(zone) }
                    }
                }
            }
        }
        return pairs.count == 1 ? pairs[0] : nil
    }

    private static let printedNumberPattern = try! NSRegularExpression(pattern: #"(?<![A-Z0-9])([A-Z]{0,2}[0-9]{6,8})(?![A-Z0-9])"#)

    /// A visa's number line whose passport number failed its check, read again with the number
    /// the foil prints as "Passport Number": a second reading of the same characters. Kept only
    /// when that number passes the line's own check digit, differs from the line's reading in two
    /// characters at most, and is the only one that does; the birth and expiry checks still apply.
    private static func readWithPrintedNumber(_ line: String, nameLine: String?, page: [String]) -> MachineZone? {
        let chars = Array(line)
        guard chars.count >= 28 else { return nil }
        let read = Array(chars[0..<9])
        var printed = Set<String>()
        for text in page where !text.contains("<") {
            let ns = text as NSString
            for m in printedNumberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                printed.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        var readings: [MachineZone] = []
        for number in printed {
            let field = Array(number.padding(toLength: 9, withPad: "<", startingAt: 0))
            let differences = zip(field, read).filter { $0 != $1 }.count
            guard differences > 0, differences <= 2 else { continue }
            if let zone = readWholeOrLetter(field + chars[9...], nameLine: nameLine, kind: .visa),
               !readings.contains(zone) { readings.append(zone) }
        }
        return readings.count == 1 ? readings[0] : nil
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
            let issuerRead = issuingState?.count == 3
            var zone = MachineZone(kind: resolved, number: number,
                                   issuer: (issuerRead ? issuingState : nil) ?? nationality,
                                   nationality: nationality, surname: surname, givenNames: given,
                                   expires: expires, born: born, nameRead: nameLine != nil)
            zone.issuerRead = issuerRead
            return zone
        }
        return nil
    }

    private enum Century { case past, future }

    /// How far ahead a zone's expiry may be and still be read as 20YY: further than any passport
    /// runs (``PrintedPage/longestTerm``), with room.
    private static let zoneYearsAhead = 15

    /// `YYMMDD`. A birth date is 19YY when 20YY would be in the future. An expiry is 20YY unless
    /// that is further ahead than any passport runs (ten years, with room): a passport that ran
    /// out in 1999 is not good until 2099.
    private static func date(_ field: Substring, century: Century) -> Date? {
        guard field.count == 6, field.allSatisfy({ $0.isASCII && $0.isNumber }), let yy = Int(field.prefix(2)),
              let mm = Int(field.dropFirst(2).prefix(2)), let dd = Int(field.suffix(2)) else { return nil }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date()) % 100
        let year = century == .future ? (yy <= thisYear + zoneYearsAhead ? 2000 + yy : 1900 + yy)
            : (yy <= thisYear ? 2000 + yy : 1900 + yy)
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
///
/// Every caller names its settings: the Vault's panel goes through its model's
/// (``VaultModel/readFolders``), so a panel drawn in a test never reads or changes the owner's
/// list (VT74).
public enum VaultReadFolders {
    public static let key = "vaultReadFolders"

    public static func folders(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Adds `path` unless it, or a folder holding it, is already on the list; a folder that holds
    /// ones already listed takes their place, so nothing is read twice.
    public static func add(_ path: String, in defaults: UserDefaults) {
        let path = (path as NSString).standardizingPath
        var list = folders(in: defaults)
        guard !list.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        list.removeAll { $0.hasPrefix(path + "/") }
        list.append(path)
        defaults.set(list, forKey: key)
    }

    public static func remove(_ path: String, in defaults: UserDefaults) {
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
/// Its own file, not the Vault's. Most of it a read finds again: what is waiting, the read
/// index, mentions and copies. Some of it is the user's own and no read brings back: ``names``,
/// ``nameRoles`` and ``lessons``. So a file that does not open is set aside, never started again
/// over (``VaultStore/setAsideReading()``).
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
    /// What each document said about each number, by number and then by file, which a waiting
    /// number is rebuilt from when a file changes or goes (``VaultModel/merged(_:)``).
    public var copies: [String: [String: VaultFind]]
    /// Choices made about waiting numbers under an older build's rules, by number: carried onto
    /// what the next read finds, since that read starts again from nothing.
    public var choices: [String: VaultChoice]
    /// What an older build read was let go, and no read since has finished: the panel asks for one.
    public var needsReadAgain: Bool
    /// What choosing a kind for a read number taught (``VaultKinds/lessonFolder(of:)``): an
    /// account's folder, and the card its numbers go on. Kept across a change of rules: it is the
    /// user's, not the reader's.
    public var lessons: [String: VaultCardID]
    /// Documents an older build read IDs from, kept when what it read is let go with its rules,
    /// so Refresh can read those first. Nil once a refresh has.
    public var staleSources: [String]?
    /// Documents an ID was read from that were not where they had been at the last look.
    public var notFound: [String]?
    /// A refresh has followed a change of rules, and the other files have not been read with
    /// the new ones: the panel offers Discover More.
    public var needsDiscover: Bool?
    /// What raised ``needsDiscover``: copies Refresh found changed, not a change of rules.
    public var copiesChanged: Bool?
    public var lastRefreshed: Date?
    public var lastDiscovered: Date?
    /// Names the user corrected everywhere (Edit's Name, for every ID read so): the name as read,
    /// by ``VaultReading/spellingKey(_:)``, and as it should be. Kept across a change of rules.
    public var names: [String: String]
    /// The roles chosen for each person's spellings, by person: their legal name, the name they
    /// go by, and spellings kept as real ones. Kept across a change of rules.
    public var nameRoles: [String: VaultNameRoles]?
    /// What the user typed for each person, by person: phones, emails and home addresses, and
    /// addresses read that are not theirs. Kept across a change of rules.
    public var contacts: [String: VaultContacts]?
    /// What each copy filed in a packet gave when last read whole, by its size and date: kept
    /// across a change of rules, so a copy whose numbers are all held from their own folders is
    /// known before it is opened (VT107 step 3, ``VaultCopyNumbers``).
    public var copyNumbers: [String: VaultCopyNumbers]?

    /// `version` nil is this build's: resolved here, never as a default argument, which a
    /// caller's object file keeps from when it was compiled, so a cached build of an unchanged
    /// test went red after a bump (docs/flaky-tests.md, "A bumped constant…").
    public init(version: Int? = nil, generation: Int = 0,
                finds: [VaultFind] = [], read: [String: String] = [:], mentions: [String: [VaultSource]] = [:],
                copies: [String: [String: VaultFind]] = [:], choices: [String: VaultChoice] = [:],
                needsReadAgain: Bool = false, lessons: [String: VaultCardID] = [:],
                staleSources: [String]? = nil, notFound: [String]? = nil, needsDiscover: Bool? = nil,
                copiesChanged: Bool? = nil, lastRefreshed: Date? = nil, lastDiscovered: Date? = nil, names: [String: String] = [:],
                nameRoles: [String: VaultNameRoles]? = nil, contacts: [String: VaultContacts]? = nil,
                copyNumbers: [String: VaultCopyNumbers]? = nil) {
        self.copyNumbers = copyNumbers
        self.nameRoles = nameRoles
        self.contacts = contacts
        self.staleSources = staleSources
        self.notFound = notFound
        self.needsDiscover = needsDiscover
        self.copiesChanged = copiesChanged
        self.lastRefreshed = lastRefreshed
        self.lastDiscovered = lastDiscovered
        self.version = version ?? VaultReading.version
        self.generation = generation
        self.finds = finds
        self.read = read
        self.mentions = mentions
        self.copies = copies
        self.choices = choices
        self.needsReadAgain = needsReadAgain
        self.lessons = lessons
        self.names = names
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, generation, finds, read, mentions, copies, choices, needsReadAgain, lessons
        case staleSources, notFound, needsDiscover, copiesChanged, lastRefreshed, lastDiscovered, names, nameRoles, contacts
        case copyNumbers
    }

    /// Every key this build reads. One outside it is a later build's, kept as it came
    /// (``laterFields``).
    static let storedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    /// What a later build stored that this one does not read, as a JSON object: never encoded
    /// as a field, but merged back in when the state is sealed, so a file a newer SyncCloud wrote
    /// keeps what it holds when this one seals it (VT30). Set by ``VaultStore/openReading()``.
    public var laterFields: Data?
    /// The user's own fields (`names`, `nameRoles`, `contacts`) as stored, when this build could not read
    /// them (a later build's shape) and holds them empty: sealed back while still empty here.
    public var unreadFields: Data?

    /// A state sealed by an older build lacks the newer fields: it opens with them empty, so its
    /// finds' choices can still be carried over.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generation = try c.decode(Int.self, forKey: .generation)
        finds = try c.decode([VaultFind].self, forKey: .finds)
        read = try c.decodeIfPresent([String: String].self, forKey: .read) ?? [:]
        mentions = try c.decodeIfPresent([String: [VaultSource]].self, forKey: .mentions) ?? [:]
        copies = try c.decodeIfPresent([String: [String: VaultFind]].self, forKey: .copies) ?? [:]
        choices = try c.decodeIfPresent([String: VaultChoice].self, forKey: .choices) ?? [:]
        needsReadAgain = try c.decodeIfPresent(Bool.self, forKey: .needsReadAgain) ?? false
        lessons = try c.decodeIfPresent([String: VaultCardID].self, forKey: .lessons) ?? [:]
        // Lenient: none of these is worth losing To Confirm over.
        staleSources = try? c.decodeIfPresent([String].self, forKey: .staleSources)
        notFound = try? c.decodeIfPresent([String].self, forKey: .notFound)
        needsDiscover = try? c.decodeIfPresent(Bool.self, forKey: .needsDiscover)
        copiesChanged = try? c.decodeIfPresent(Bool.self, forKey: .copiesChanged)
        lastRefreshed = try? c.decodeIfPresent(Date.self, forKey: .lastRefreshed)
        lastDiscovered = try? c.decodeIfPresent(Date.self, forKey: .lastDiscovered)
        names = (try? c.decodeIfPresent([String: String].self, forKey: .names)) ?? [:]
        nameRoles = try? c.decodeIfPresent([String: VaultNameRoles].self, forKey: .nameRoles)
        contacts = try? c.decodeIfPresent([String: VaultContacts].self, forKey: .contacts)
        copyNumbers = try? c.decodeIfPresent([String: VaultCopyNumbers].self, forKey: .copyNumbers)
    }
}

/// A copy filed in a packet (a petition's, an application's) and the numbers it gave, as it
/// was when read whole (VT107 step 3, owner). While it stays as it was and every one of those
/// numbers is held from a document in its own kind's folder, a read passes it over.
public struct VaultCopyNumbers: Codable, Equatable, Sendable {
    /// Its size and date then (``VaultDocumentReading/stamp(of:)``).
    public var stamp: String
    /// What it gave, normalized (``VaultReading/normalized(_:)``).
    public var numbers: [String]

    public init(stamp: String, numbers: [String]) {
        self.stamp = stamp
        self.numbers = numbers
    }
}

/// What the user chose about one waiting number: kept across a change of rules.
public struct VaultChoice: Codable, Equatable, Sendable {
    public var id: UUID
    public var choices: VaultChoices
    public var pin: VaultPin? { get { choices.pin } set { choices.pin = newValue } }
    public var assignment: VaultAssignment? { get { choices.assignment } set { choices.assignment = newValue } }
    public var geo: VaultGeo? { get { choices.geo } set { choices.geo = newValue } }
    public var card: VaultCardID? { get { choices.card } set { choices.card = newValue } }
    public var source: String? { get { choices.source } set { choices.source = newValue } }

    public init(id: UUID, choices: VaultChoices) {
        self.id = id
        self.choices = choices
    }

    public init(id: UUID, pin: VaultPin?, assignment: VaultAssignment?, geo: VaultGeo? = nil, card: VaultCardID? = nil,
                source: String? = nil) {
        self.init(id: id, choices: VaultChoices(pin: pin, assignment: assignment, geo: geo, card: card, source: source))
    }

    /// What the user chose about `find`.
    public init(_ find: VaultFind) {
        self.init(id: find.id, choices: find.choices)
    }

    /// Whether the user chose anything about it.
    public var isChosen: Bool { choices.isChosen }

    private enum CodingKeys: String, CodingKey { case id }

    /// Stored flat, with the copy chosen under `source`.
    public init(from decoder: Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .id)
        choices = try VaultChoices(from: decoder, sourceKey: "source")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try choices.encode(to: encoder, sourceKey: "source")
    }
}

extension VaultReadingState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultReadingState(\(finds.count) finds, \(read.count) files read)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
