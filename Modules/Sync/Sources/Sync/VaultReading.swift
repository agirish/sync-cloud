import Foundation

/// A number read from a document, waiting in To Confirm until it is added or set aside.
///
/// Sealed to disk with the Vault's key between reads (``VaultReadingState``), and let go from
/// memory when the Vault locks, like the entries. Like ``VaultEntry`` it never prints its number.
public struct VaultFind: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// What it is: "Passport", "USCIS receipt number".
    public var title: String
    /// The number in full, letters and digits only.
    public var value: String
    public var kind: VaultEntry.Kind
    /// A line worth keeping beside it: who a passport names and when it expires.
    public var note: String
    /// The name the document is made out to, as printed, for suggesting whose it is.
    public var holder: String?
    /// The file it was read from.
    public var sourcePath: String
    /// The document's own date, for telling a current number from an older one: a passport's
    /// expiry, an I-94's date of entry, a notice's date, else a month and year in the file's name.
    public var dated: Date?
    /// When the document stops being good: a passport's expiry, an I-94's admit-until date, a
    /// notice's "valid to". Past it, the number is older whatever else was read.
    public var validUntil: Date?
    /// A newer one of its kind was read for the same person, it was filed in an Archive folder,
    /// or its document has run out. Still offered: a form sometimes asks for a past number.
    public var isOlder: Bool

    public init(id: UUID = UUID(), title: String, value: String, kind: VaultEntry.Kind,
                note: String = "", holder: String? = nil, sourcePath: String,
                dated: Date? = nil, validUntil: Date? = nil, isOlder: Bool = false) {
        self.id = id
        self.title = title
        self.value = value
        self.kind = kind
        self.note = note
        self.holder = holder
        self.sourcePath = sourcePath
        self.dated = dated ?? VaultReading.fileDate(sourcePath)
        self.validUntil = validUntil
        self.isOlder = isOlder
    }

    /// Filed in a folder named Archive (or Archived, or Old) somewhere along its path: where people
    /// put the copies they have replaced.
    public var isArchived: Bool { VaultReading.isArchivePath(sourcePath) }
}

extension VaultFind: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultFind(\(title), \(VaultMask.masked(value)))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Reads the numbers a document states plainly enough to trust without a person checking each
/// character: the kinds tried on real scans on 2026-11-18.
///
/// - A passport's machine-readable zone, kept only when its three check digits agree, so a
///   misread character is caught rather than offered.
/// - A USCIS receipt number: three letters naming the service center, then ten digits.
/// - An I-94 admission number, only beside the words "I-94" or "Admission".
///
/// Each takes the page as recognised lines and nothing else, so the rules are tested on text and
/// the app decides how a page is read. Recognition needs Vision's accurate level: on the same
/// scans the fast level, which filing uses, missed every one of these.
public enum VaultReading {

    /// Raised whenever a rule changes what is read, so the next Read Documents reads every file
    /// again rather than trusting what an older build made of it.
    public static let version = 3

    /// Every number on one document's pages, once each.
    public static func finds(in lines: [String], from path: String) -> [VaultFind] {
        var out: [VaultFind] = []
        var seen = Set<String>()
        func keep(_ find: VaultFind) {
            if seen.insert(normalized(find.value)).inserted { out.append(find) }
        }
        if let passport = PassportMRZ.read(lines) { keep(passport.find(from: path)) }
        let text = lines.joined(separator: "\n")
        for find in receiptNumbers(in: text, from: path) { keep(find) }
        for find in admissionNumbers(in: text, from: path) { keep(find) }
        return out
    }

    /// Letters and digits only, upper case: how two readings of one number are compared, and how
    /// a find is matched against what the Vault already holds.
    public static func normalized(_ value: String) -> String {
        String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
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
    private static let validToPattern = try! NSRegularExpression(
        pattern: #"valid\s*from\s*\d{1,2}/\d{1,2}/\d{4}\s*to\s*(\d{1,2})/(\d{1,2})/(\d{4})"#,
        options: [.caseInsensitive])
    /// "Notice Date 06/01/2026" on a notice of action.
    private static let noticeDatePattern = try! NSRegularExpression(
        pattern: #"notice\s*date\s*:?\s*(\d{1,2})/(\d{1,2})/(\d{4})"#, options: [.caseInsensitive])

    /// The end of "Valid from … to 09/30/2029", on an approval notice and its I-94 tear-off.
    static func validTo(in text: String) -> Date? {
        let ns = text as NSString
        guard let valid = validToPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let month = Int(ns.substring(with: valid.range(at: 1))),
              let day = Int(ns.substring(with: valid.range(at: 2))),
              let year = Int(ns.substring(with: valid.range(at: 3))) else { return nil }
        return calendarDate(year: year, month: month, day: day)
    }

    static func receiptNumbers(in text: String, from path: String) -> [VaultFind] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var dated: Date?
        if let notice = noticeDatePattern.firstMatch(in: text, range: whole),
           let month = Int(ns.substring(with: notice.range(at: 1))),
           let day = Int(ns.substring(with: notice.range(at: 2))),
           let year = Int(ns.substring(with: notice.range(at: 3))) {
            dated = calendarDate(year: year, month: month, day: day)
        }
        var notes: [String] = []
        if let form = formPattern.matches(in: text, range: whole)
            .map({ ns.substring(with: $0.range(at: 1)) })
            .first(where: { $0 != "797" && $0 != "94" && $0 != "797A" && $0 != "797C" }) {
            notes.append("Form I-\(form)")
        }
        let validTo = validTo(in: text)
        if let validTo { notes.append("valid to \(spelled(validTo))") }
        return receiptPattern.matches(in: text, range: whole).compactMap { match in
            let center = ns.substring(with: match.range(at: 1)).uppercased()
            let read = normalized(ns.substring(with: match.range(at: 2)))
            // Mostly digits as printed: look-alikes are forgiven a few at a time, and a run of
            // letters that only become digits once fixed is a word, not a number.
            guard read.filter(\.isNumber).count >= 7 else { return nil }
            let digits = fixedDigits(read)
            return VaultFind(title: "USCIS receipt number", value: center + digits, kind: .identity,
                             note: sentence(notes), sourcePath: path, dated: dated, validUntil: validTo)
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

    /// The printout's date of entry: "Arrival/Issued Date: 2026 April 12" since 2025, "Most Recent
    /// Date of Entry: 2015 Jan 12" before.
    private static let entryDatePattern = try! NSRegularExpression(
        pattern: #"(?:arrival\s*/\s*issued\s*date|date\s*of\s*entry)\s*:?\s*(\d{4})\s+([A-Za-z]{3,9})\.?\s+(\d{1,2})"#,
        options: [.caseInsensitive])
    private static let admitUntilPattern = try! NSRegularExpression(
        pattern: #"admit\s*until\s*date\s*:?\s*(\d{4})\s+([A-Za-z]{3,9})\.?\s+(\d{1,2})"#,
        options: [.caseInsensitive])
    private static let surnamePattern = try! NSRegularExpression(
        pattern: #"(?:last\s*/\s*surname|family\s*name)\s*:\s*([A-Za-z][A-Za-z\x27 -]*)"#, options: [.caseInsensitive])
    private static let givenNamePattern = try! NSRegularExpression(
        pattern: #"first\s*\(given\)\s*name\s*:\s*([A-Za-z][A-Za-z\x27 -]*)"#, options: [.caseInsensitive])

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
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func admissionNumbers(in text: String, from path: String) -> [VaultFind] {
        let ns = text as NSString
        let entered = printedDate(entryDatePattern, in: text)
        // A printout's admit-until date; on an approval notice's tear-off, the notice's validity.
        let until = printedDate(admitUntilPattern, in: text) ?? validTo(in: text)
        let holder = [printedName(givenNamePattern, in: text), printedName(surnamePattern, in: text)]
            .compactMap { $0 }.joined(separator: " ")
        var notes: [String] = []
        if !holder.isEmpty { notes.append(holder) }
        if let entered { notes.append("entered \(spelled(entered))") }
        if let until { notes.append("admitted until \(spelled(until))") }
        return admissionPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
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
                return VaultFind(title: "I-94 admission number", value: value, kind: .identity,
                                 note: sentence(notes), holder: holder.isEmpty ? nil : holder,
                                 sourcePath: path, dated: entered, validUntil: until)
            }
    }

    // MARK: Current and older

    /// Marks every find that is not the current one of its kind for its person.
    ///
    /// A group is one kind of number ("Passport") for one holder, or, with no holder printed, for
    /// the folder it was filed under. In each, the newest by the document's own date is current.
    /// A copy in an Archive folder is older, unless its date is later than every copy outside one
    /// (the date wins); a group filed only in Archive folders is all older. A find already marked
    /// older stays so: the current one leaving To Confirm, added to the Vault, does not promote
    /// the next.
    ///
    /// Whatever its group, a number whose document has run out by `now` is older: an expired
    /// passport, an I-94 past its admit-until date, a notice past its "valid to".
    public static func markingOlder(_ finds: [VaultFind], now: Date = Date()) -> [VaultFind] {
        let groups = Dictionary(grouping: finds.indices) { groupKey(finds[$0]) }
        var out = finds
        for index in out.indices where (out[index].validUntil ?? .distantFuture) < now {
            out[index].isOlder = true
        }
        for indices in groups.values {
            let sorted = indices.sorted { a, b in
                let (da, db) = (finds[a].dated ?? .distantPast, finds[b].dated ?? .distantPast)
                if da != db { return da > db }
                return !finds[a].isArchived && finds[b].isArchived
            }
            guard let top = sorted.first else { continue }
            var current = Set<Int>()
            if finds[top].dated == nil {
                // Nothing dated: whatever is outside an Archive folder is current.
                current = Set(sorted.filter { !finds[$0].isArchived })
            } else if sorted.contains(where: { !finds[$0].isArchived }) {
                // The newest, and any dated the same day: two passports expiring on one date are
                // two people's, issued together, not one replacing the other.
                current = Set(sorted.filter { finds[$0].dated == finds[top].dated })
            }
            for index in indices where !current.contains(index) { out[index].isOlder = true }
        }
        return out
    }

    /// Whose number of which kind: the holder's name in lower case, or the folder above the file
    /// with any Archive folder skipped ("Form I-94/Shweta/Archive/…" files under "shweta").
    static func groupKey(_ find: VaultFind) -> String {
        // A receipt number is one case. Cases for the same form (an H-1B's I-129 each time it is
        // extended) replace one another; a notice that names no form is a case on its own. Two
        // filed together (an I-129 and its I-539) name different forms and both stay current.
        if find.title == "USCIS receipt number" {
            if let form = formNamed(in: find.note) { return find.title + "|form:" + form }
            return find.title + "|" + normalized(find.value)
        }
        if let holder = find.holder?.lowercased().filter({ $0.isLetter }), !holder.isEmpty {
            return find.title + "|" + holder
        }
        let folders = (find.sourcePath as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        let owner = folders.last { !isArchiveName($0) } ?? ""
        return find.title + "|folder:" + owner.lowercased()
    }

    /// "I-129" from a receipt's note, "Form I-129, valid to …".
    static func formNamed(in note: String) -> String? {
        let ns = note as NSString
        guard let match = notedFormPattern.firstMatch(in: note, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).uppercased()
    }

    private static let notedFormPattern = try! NSRegularExpression(pattern: #"\bForm (I-\d{3}[A-Z]?)\b"#)

    static func isArchivePath(_ path: String) -> Bool {
        (path as NSString).deletingLastPathComponent.split(separator: "/").contains { isArchiveName(String($0)) }
    }

    private static func isArchiveName(_ name: String) -> Bool {
        ["archive", "archived", "archives", "old", "older", "expired"].contains(name.lowercased())
    }

    // MARK: Dates in file names

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

    // MARK: Shared

    /// Look-alikes Vision reads in a field that holds only digits.
    static let digitLookalikes: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8", "G": "6",
    ]

    static func fixedDigits(_ s: String) -> String {
        String(s.uppercased().map { digitLookalikes[$0] ?? $0 })
    }

    static func calendarDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = DateComponents(year: year, month: month, day: day)
        guard parts.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: parts)
    }

    /// "15 April 2032", the same however the Mac is set, so a test can read it back. Spelled from
    /// the date's UTC parts, the zone every date here is made in (``calendarDate(year:month:day:)``).
    static func spelled(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = (parts.month ?? 1) - 1
        let name = fullMonth(monthNames[max(0, min(11, month))])
        return "\(parts.day ?? 1) \(name.prefix(1).uppercased() + name.dropFirst()) \(parts.year ?? 0)"
    }

    /// Notes joined, the first word capitalised.
    static func sentence(_ parts: [String]) -> String {
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// A passport's machine-readable zone: two lines of 44 characters at the foot of the photo page
/// (ICAO Doc 9303, format TD3).
public struct PassportMRZ: Equatable, Sendable {
    public var number: String
    /// Three letters: `USA`, `IND`, `GBR`.
    public var issuer: String
    public var surname: String
    public var givenNames: String
    public var expires: Date
    public var born: Date

    /// The holder as printed, in reading order: "Anna Maria Eriksson".
    public var holder: String {
        [givenNames, surname].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func find(from path: String) -> VaultFind {
        let expiry = VaultReading.spelled(expires)
        let lapsed = expires < Date()
        var note = [holder, (lapsed ? "expired " : "expires ") + expiry]
        if !issuer.isEmpty { note.append("issued by \(issuer)") }
        return VaultFind(title: "Passport", value: number, kind: .identity,
                         note: VaultReading.sentence(note.filter { !$0.isEmpty }),
                         holder: holder.isEmpty ? nil : holder, sourcePath: path, dated: expires,
                         validUntil: expires)
    }

    /// The zone on a page of recognised lines, or nil when there is none whose check digits agree.
    public static func read(_ lines: [String]) -> PassportMRZ? {
        let candidates = lines.map(clean).filter {
            $0.count >= 28 && $0.allSatisfy { allowed.contains($0) }
        }
        let nameLine = candidates.first { $0.hasPrefix("P") && $0.contains("<<") }
        for candidate in candidates where candidate.filter(\.isNumber).count >= 10 {
            if let read = readSecondLine(candidate, nameLine: nameLine) { return read }
        }
        return nil
    }

    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<")

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

    /// The second line as read, then with digit look-alikes fixed in the fields that hold only
    /// digits. A reading counts only when the number, birth and expiry checks all agree, and the
    /// overall check too when the line is whole.
    private static func readSecondLine(_ line: String, nameLine: String?) -> PassportMRZ? {
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
            if chars.count == 44 {
                let composite = String(field(0, 10)) + String(field(13, 20)) + String(field(21, 43))
                guard digit(43) == checkDigit(composite) else { continue }
            }
            guard let expires = date(field(21, 27), century: .future),
                  let born = date(field(13, 19), century: .past) else { continue }
            let number = field(0, 9).replacingOccurrences(of: "<", with: "")
            guard number.count >= 6 else { continue }
            let (surname, given) = names(from: nameLine)
            return PassportMRZ(number: number,
                               issuer: String(field(10, 13)).replacingOccurrences(of: "<", with: ""),
                               surname: surname, givenNames: given, expires: expires, born: born)
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

    public init(version: Int = VaultReading.version, generation: Int = 0,
                finds: [VaultFind] = [], read: [String: String] = [:]) {
        self.version = version
        self.generation = generation
        self.finds = finds
        self.read = read
    }
}

extension VaultReadingState: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultReadingState(\(finds.count) finds, \(read.count) files read)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
