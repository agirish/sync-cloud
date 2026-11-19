import Foundation

/// The identity cards a household files under Legal: driver's licenses (US and India), Social
/// Security cards and ITIN notices, PAN cards, Aadhaar and voter IDs. Each reader takes one
/// page's lines and keeps a number only where its kind can be checked, tried on real scans:
///
/// - A US license's PDF417 barcode, which states the number, name, birth date and dates outright.
///   The printed front is read too, beside its "DL" label, as a second source.
/// - An Indian license number: state, office, year and serial, beside its label.
/// - A Social Security number only on the card or its stub, alone on its line in its exact
///   shape, within the ranges SSA assigns. A scan that ran a digit in or dropped one is skipped,
///   never mended: nothing on the card checks a guess.
/// - A PAN in its fixed shape, on a page that is about one.
/// - An Aadhaar number only when its Verhoeff check digit agrees, never inside a VID.
/// - A voter ID (EPIC) on an Election Commission page.
extension VaultReading {

    static func identityNumbers(on page: [String], from path: String) -> [VaultFind] {
        licenseBarcodes(on: page, from: path) + usLicenseFronts(on: page, from: path)
            + indianLicenses(on: page, from: path) + socialSecurityNumbers(on: page, from: path)
            + panNumbers(on: page, from: path) + aadhaarNumbers(on: page, from: path)
            + voterIDs(on: page, from: path)
    }

    /// Ranks for identity documents, beside ``Rank``.
    enum IDRank {
        /// The card itself, its barcode, or a government's digital copy of it. A barcode ranks with
        /// its card, so where the scan is filed decides between an old card's back in Archive
        /// and the renewed card's front: a US license keeps its number through renewals.
        static let card = 40
        /// A letter that assigns the number: an ITIN notice, a voter information slip.
        static let letter = 30
        /// A form, a receipt or an acknowledgement that quotes it.
        static let quoted = 10
    }

    // MARK: Shared

    /// The page's text with spaces dropped and lower-cased, for finding a cue a scan broke up:
    /// "Permanent Account Numbe r", "ESTABLISHED FOR".
    static func squeezed(_ lines: [String]) -> String {
        lines.joined(separator: " ").lowercased().filter { !$0.isWhitespace }
    }

    /// "05/06/1990" or "05-06-1990" as India prints it: the day first.
    static func dayFirst(_ text: String) -> Date? {
        guard let parts = dateParts(text) else { return nil }
        return calendarDate(year: parts.2, month: parts.1, day: parts.0)
    }

    /// "06/05/1990" as the US prints it: the month first.
    static func monthFirst(_ text: String) -> Date? {
        guard let parts = dateParts(text) else { return nil }
        return calendarDate(year: parts.2, month: parts.0, day: parts.1)
    }

    private static let datePattern = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\s*[/.-]\s*(\d{1,2})\s*[/.-]\s*((?:19|20)\d{2})(?!\d)"#)

    private static func dateParts(_ text: String) -> (Int, Int, Int)? {
        let ns = text as NSString
        guard let m = datePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let a = Int(ns.substring(with: m.range(at: 1))), let b = Int(ns.substring(with: m.range(at: 2))),
              let y = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        return (a, b, y)
    }

    /// The date printed after `label` on its line, or alone on the next line: "DOB : 05-06-1990",
    /// "ISS" then "06/05/2021".
    static func labelledDate(_ labels: [String], in lines: [String], dayFirst: Bool) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z])(?:"# + labels.joined(separator: "|") + #")(?![A-Za-z])"#, options: [.caseInsensitive])
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let after = ns.substring(from: m.range.location + m.range.length)
            let candidates = [after] + (index + 1 < lines.count ? [lines[index + 1]] : [])
            for text in candidates {
                // The date has to start the text after the label: "Date of Issue : 01-02-2010
                // Date of Expiry …" gives the first, not a later one.
                let trimmed = text.drop { " \t:.-".contains($0) }
                guard trimmed.first?.isNumber == true else { continue }
                if let date = dayFirst ? self.dayFirst(String(trimmed)) : monthFirst(String(trimmed)) { return date }
            }
        }
        return nil
    }

    /// Words that are a card's printing, never part of a name.
    static let cardWords: Set<String> = [
        "income", "tax", "department", "govt", "government", "india", "permanent", "account", "number",
        "card", "signature", "name", "father", "mother", "husband", "address", "date", "birth", "male",
        "female", "gender", "union", "driving", "license", "driver", "election", "commission", "unique",
        "identification", "authority", "social", "security", "valid", "work", "only", "authorization",
        "established", "for", "your", "stub", "aadhaar", "enrolment", "enrollment", "download", "issue",
        "state", "voter", "information", "digitally", "signed", "application", "verified", "record", "of",
        "the", "this", "has", "been", "with", "dhs", "usa", "class", "none", "rstr", "end", "exp", "dob",
    ]

    /// A line that is a person's name and nothing else: letters, at least two words of two letters,
    /// none of them a card's printing. Title-cased: "SHWETA RAVINDRA DANI" → "Shweta Ravindra Dani".
    static func nameOnly(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ ($0.isLetter && $0.isASCII) || $0 == " " || $0 == "." }) else { return nil }
        let words = trimmed.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        guard words.filter({ $0.count >= 2 }).count >= 2,
              !words.contains(where: { cardWords.contains($0.lowercased()) }) else { return nil }
        return titleCased(words.joined(separator: " "))
    }

    static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    // MARK: US driver's licenses: the barcode

    /// AAMVA's element ids for what the Vault keeps.
    private static let aamvaElements = ["DAQ", "DCS", "DAC", "DAD", "DBB", "DBA", "DBD", "DAJ", "DCG", "DCA"]

    /// The license's PDF417 barcode, which the app appends to a page's lines as decoded
    /// (``VaultDocumentReading``): its header ("ANSI 636014…DLDAQ…") and one element per line.
    static func licenseBarcodes(on page: [String], from path: String) -> [VaultFind] {
        guard let header = page.firstIndex(where: { $0.range(of: #"ANSI ?\d{6}"#, options: .regularExpression) != nil }) else {
            return []
        }
        var fields: [String: String] = [:]
        for line in page[header...] {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{1e}\u{1d}")))
            if fields["DAQ"] == nil, let range = text.range(of: "DAQ"),
               text.distance(from: text.startIndex, to: range.lowerBound) > 0 {
                // The first element rides on the header line, after the subfile's "DL".
                fields["DAQ"] = String(text[range.upperBound...])
                continue
            }
            let id = String(text.prefix(3))
            if aamvaElements.contains(id), fields[id] == nil { fields[id] = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        }
        let value = normalized(fields["DAQ"] ?? "")
        guard value.count >= 4, value.filter(\.isNumber).count >= 4 else { return [] }
        let canadian = fields["DCG"]?.uppercased() == "CAN"
        func date(_ id: String) -> Date? {
            guard let raw = fields[id], raw.count == 8, raw.allSatisfy(\.isNumber) else { return nil }
            let digits = Array(raw).map { Int(String($0))! }
            func number(_ r: Range<Int>) -> Int { r.reduce(0) { $0 * 10 + digits[$1] } }
            // MMDDCCYY in the US, CCYYMMDD in Canada.
            if canadian || number(0..<4) > 1900 { return calendarDate(year: number(0..<4), month: number(4..<6), day: number(6..<8)) }
            return calendarDate(year: number(4..<8), month: number(0..<2), day: number(2..<4))
        }
        let given = [fields["DAC"], fields["DAD"]].compactMap { $0 }.filter { !$0.isEmpty && $0.uppercased() != "NONE" }
        let holder = ([given.first].compactMap { $0 } + [fields["DCS"]].compactMap { $0 }).joined(separator: " ")
        let state = fields["DAJ"].map { $0.uppercased() }.flatMap { $0.count == 2 ? $0 : nil }
        let issued = date("DBD"), until = date("DBA")
        var details: [VaultDetail] = []
        if let state { details.append(VaultDetail("State", .text(state))) }
        if let cls = fields["DCA"], !cls.isEmpty { details.append(VaultDetail("Class", .text(cls.uppercased()))) }
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        if let until { details.append(VaultDetail("Valid until", .date(until))) }
        var notes: [String] = []
        if !holder.isEmpty { notes.append(titleCased(holder)) }
        if let until { notes.append("valid until \(spelled(until))") }
        let facts = VaultReadFacts(category: .driversLicense, holder: holder.isEmpty ? nil : titleCased(holder),
                                   born: date("DBB"), issuer: canadian ? "CAN" : "USA", dated: issued ?? fileDate(path),
                                   validUntil: until, details: details,
                                   sources: [VaultSource(path: path, role: "Driver’s license barcode", rank: IDRank.card)])
        return [VaultFind(title: "Driver’s license" + (state.map { " · " + $0 } ?? ""), value: value,
                          note: sentence(notes), facts: facts)]
    }

    // MARK: US driver's licenses: the front

    private static let usStates: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA", "colorado": "CO",
        "connecticut": "CT", "delaware": "DE", "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
        "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS", "kentucky": "KY", "louisiana": "LA",
        "maine": "ME", "maryland": "MD", "massachusetts": "MA", "michigan": "MI", "minnesota": "MN",
        "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV",
        "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY", "north carolina": "NC",
        "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR", "pennsylvania": "PA",
        "rhode island": "RI", "south carolina": "SC", "south dakota": "SD", "tennessee": "TN", "texas": "TX",
        "utah": "UT", "vermont": "VT", "virginia": "VA", "washington": "WA", "west virginia": "WV",
        "wisconsin": "WI", "wyoming": "WY",
    ]

    /// "DL D1234567" or "DLN D1234567": one or two letters at most, then digits. The label is
    /// required, so a card's other numbers (the document discriminator, a barcode's digits) never are.
    private static let usLicensePattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])DLN?\s*[:#]?\s*([A-Z]{0,2}\d{5,14})(?![A-Za-z0-9])"#)
    private static let givenLine = try! NSRegularExpression(pattern: #"^\s*(?:\d\s*)?FN\s+([A-Z][A-Z\x27 -]*[A-Z])\s*$"#)
    private static let familyLine = try! NSRegularExpression(pattern: #"^\s*(?:\d\s*)?LN\s+([A-Z][A-Z\x27 -]*[A-Z])\s*$"#)

    static func usLicenseFronts(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        guard squeezed.contains("driverlicense") || squeezed.contains("driver\u{27}slicense")
                || squeezed.contains("driver’slicense") else { return [] }
        // A page an Indian license is on is read by its own rule.
        guard !squeezed.contains("unionofindia") else { return [] }
        func first(_ pattern: NSRegularExpression) -> String? {
            for line in page {
                let ns = line as NSString
                if let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    return ns.substring(with: m.range(at: 1))
                }
            }
            return nil
        }
        let holder = [first(givenLine), first(familyLine)].compactMap { $0 }.joined(separator: " ")
        let lower = page.joined(separator: " ").lowercased()
        let state = usStates.first { lower.contains($0.key) }?.value
        let until = labelledDate(["EXP"], in: page, dayFirst: false)
        let issued = labelledDate(["ISS"], in: page, dayFirst: false)
        let born = labelledDate(["DOB"], in: page, dayFirst: false)
        let application = squeezed.contains("application") || squeezed.contains("appointment")
        var out: [VaultFind] = []
        var seen = Set<String>()
        for line in page {
            let ns = line as NSString
            for m in usLicensePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                guard seen.insert(value).inserted else { continue }
                var details: [VaultDetail] = []
                if let state { details.append(VaultDetail("State", .text(state))) }
                if let issued { details.append(VaultDetail("Issued", .date(issued))) }
                if let until { details.append(VaultDetail("Valid until", .date(until))) }
                var notes: [String] = []
                if !holder.isEmpty { notes.append(titleCased(holder)) }
                if let until { notes.append("valid until \(spelled(until))") }
                let facts = VaultReadFacts(
                    category: .driversLicense, holder: holder.isEmpty ? nil : titleCased(holder), born: born,
                    issuer: "USA", dated: issued ?? fileDate(path), validUntil: until, details: details,
                    sources: [VaultSource(path: path, role: application ? "Names it" : "Driver’s license",
                                          rank: application ? IDRank.quoted : IDRank.card)])
                out.append(VaultFind(title: "Driver’s license" + (state.map { " · " + $0 } ?? ""), value: value,
                                     note: sentence(notes), facts: facts))
            }
        }
        return out
    }

    // MARK: Indian driving licenses

    /// The codes India's states and union territories print first on a license number.
    private static let indianStates: Set<String> = [
        "AN", "AP", "AR", "AS", "BR", "CH", "CG", "DD", "DL", "DN", "GA", "GJ", "HR", "HP", "JK", "JH", "KA",
        "KL", "LA", "LD", "MP", "MH", "MN", "ML", "MZ", "NL", "OD", "OR", "PY", "PB", "RJ", "SK", "TN", "TS",
        "TR", "UP", "UK", "UA", "WB",
    ]

    /// "KA05 20090001234": state, office, year of issue, a seven-digit serial.
    private static let indianLicensePattern = try! NSRegularExpression(
        pattern: #"(?<![A-Z0-9])([A-Z]{2})[- ]?(\d{2})[- ]?((?:19|20)\d{2})[- ]?(\d{7})(?!\d)"#)
    private static let printedName = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])Name\s*:\s*([A-Za-z][A-Za-z .]*[A-Za-z])"#)

    static func indianLicenses(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        guard squeezed.contains("drivinglicen") || squeezed.contains("parivahan") || squeezed.contains("sarathi")
                || squeezed.contains("dlnumber") || squeezed.contains("dlservices") else { return [] }
        let text = page.joined(separator: "\n")
        let ns = text as NSString
        var holder: String?
        for line in page where !["father", "husband", "mother", "s/o", "d/o", "c/o", "s/w/d"].contains(where: line.lowercased().contains) {
            let lns = line as NSString
            if let m = printedName.firstMatch(in: line, range: NSRange(location: 0, length: lns.length)) {
                let name = lns.substring(with: m.range(at: 1))
                if !name.lowercased().split(separator: " ").contains(where: { cardWords.contains(String($0)) }) {
                    holder = titleCased(name)
                    break
                }
            }
        }
        let issued = labelledDate(["Date of Issue", "DL Issue Date", "D\\.O\\.I\\."], in: page, dayFirst: true)
        let until = labelledDate(["Date of Expiry", "Valid upto", "Valid up to"], in: page, dayFirst: true)
            ?? ntValidity(in: text)
        let born = labelledDate(["DOB", "D\\.O\\.B\\.?", "Date of Birth"], in: page, dayFirst: true)
        let quoted = squeezed.contains("acknowledgement") || squeezed.contains("applicationno")
            || squeezed.contains("applicationnumber")
        let role = quoted ? "Application" : squeezed.contains("digilocker") ? "Driver’s license, DigiLocker" : "Driver’s license"
        var seen = Set<String>()
        return indianLicensePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let state = ns.substring(with: m.range(at: 1))
            guard indianStates.contains(state) else { return nil }
            let value = (1...4).map { ns.substring(with: m.range(at: $0)) }.joined()
            guard seen.insert(value).inserted else { return nil }
            var details: [VaultDetail] = [VaultDetail("State", .text(state))]
            if let issued { details.append(VaultDetail("Issued", .date(issued))) }
            if let until { details.append(VaultDetail("Valid until", .date(until))) }
            var notes: [String] = []
            if let holder { notes.append(holder) }
            if let until { notes.append("valid until \(spelled(until))") }
            let facts = VaultReadFacts(category: .driversLicense, holder: holder, born: born, issuer: "IND",
                                       dated: issued ?? fileDate(path), validUntil: until, details: details,
                                       sources: [VaultSource(path: path, role: role, rank: quoted ? IDRank.quoted : IDRank.card)])
            return VaultFind(title: "Driver’s license · India", value: value, note: sentence(notes), facts: facts)
        }
    }

    /// The end of "NT Validity : 01-02-2010 to 31-01-2030".
    private static func ntValidity(in text: String) -> Date? {
        guard let range = text.range(of: #"validity\s*:?\s*[\d/.-]+\s*to\s*[\d/.-]+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let found = String(text[range])
        guard let to = found.range(of: "to", options: [.caseInsensitive, .backwards]) else { return nil }
        return dayFirst(String(found[to.upperBound...]))
    }

    // MARK: Social Security numbers and ITINs

    /// What only a Social Security card, or its stub, prints.
    private static let cardCues = ["establishedfor", "socialsecuritycard", "validforworkonly", "workonlywith",
                                   "dhsauthorization", "notvalidforemployment"]
    private static let ssnLine = try! NSRegularExpression(pattern: #"^\s*(\d{3})[- ](\d{2})[- ](\d{4})\s*$"#)
    private static let itinInText = try! NSRegularExpression(pattern: #"(?<!\d)(9\d{2})-(\d{2})-(\d{4})(?!\d)"#)

    /// A Social Security number SSA could have assigned: never area 000, 666 or 900 and up, group
    /// 00 or serial 0000.
    static func isAssignableSSN(_ area: Int, _ group: Int, _ serial: Int) -> Bool {
        area != 0 && area != 666 && area < 900 && group != 0 && serial != 0
    }

    /// An ITIN: 9, then a middle pair in the ranges the IRS assigns.
    static func isITIN(_ area: Int, _ group: Int) -> Bool {
        area >= 900 && ((50...65).contains(group) || (70...88).contains(group) || (90...92).contains(group)
                        || (94...99).contains(group))
    }

    /// Whether a page is worth reading again from a sharper render, which the app does at about
    /// 4000 pixels. On real scans, each read true there and not at 2400:
    ///
    /// - a Social Security card with no number read cleanly: its small type ran a digit in;
    /// - the back of a US license whose barcode did not decode.
    public static func wantsSharperRead(_ page: [String]) -> Bool {
        let squeezed = squeezed(page)
        if cardCues.contains(where: squeezed.contains) {
            return socialSecurityNumbers(on: page, from: "").isEmpty
        }
        let licenseBack = squeezed.contains("licensetodrive") || squeezed.contains("issuedasalicense")
            || (squeezed.contains("endorsements") && squeezed.contains("restrictions"))
        return licenseBack && !page.contains { $0.range(of: #"ANSI ?\d{6}"#, options: .regularExpression) != nil }
    }

    static func socialSecurityNumbers(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        let isCard = cardCues.contains(where: squeezed.contains)
        let isITINNotice = squeezed.contains("individualtaxpayeridentificationnumber")
        guard isCard || isITINNotice else { return [] }
        let holder = mailedTo(page) ?? cardName(page)
        var out: [VaultFind] = []
        var seen = Set<String>()
        if isCard {
            for line in page {
                let ns = line as NSString
                guard let m = ssnLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                      let area = Int(ns.substring(with: m.range(at: 1))), let group = Int(ns.substring(with: m.range(at: 2))),
                      let serial = Int(ns.substring(with: m.range(at: 3))),
                      isAssignableSSN(area, group, serial) else { continue }
                let value = (1...3).map { ns.substring(with: m.range(at: $0)) }.joined()
                guard seen.insert(value).inserted else { continue }
                let issued = issueDate(page)
                var details: [VaultDetail] = []
                if let issued { details.append(VaultDetail("Card issued", .date(issued))) }
                let facts = VaultReadFacts(category: .ssn, holder: holder, form: "SSN", dated: issued ?? fileDate(path),
                                           details: details,
                                           sources: [VaultSource(path: path, role: "Social Security card", rank: IDRank.card)])
                out.append(VaultFind(title: "Social Security number", value: value, note: holder ?? "", facts: facts))
            }
        }
        if isITINNotice {
            let text = page.joined(separator: "\n")
            let ns = text as NSString
            let dates = spelledDates(in: text).sorted()
            let noticeDate = dates.last
            // The birth date is the earliest the notice prints, years before the notice.
            let born = dates.first.flatMap { first in
                noticeDate.map { $0.timeIntervalSince(first) > 10 * 365 * 86_400 } == true ? first : nil
            }
            for m in itinInText.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let area = Int(ns.substring(with: m.range(at: 1))), let group = Int(ns.substring(with: m.range(at: 2))),
                      isITIN(area, group) else { continue }
                let value = (1...3).map { ns.substring(with: m.range(at: $0)) }.joined()
                guard seen.insert(value).inserted else { continue }
                var details: [VaultDetail] = []
                if let noticeDate { details.append(VaultDetail("Assigned", .date(noticeDate))) }
                let facts = VaultReadFacts(category: .ssn, holder: holder, born: born, form: "ITIN",
                                           dated: noticeDate ?? fileDate(path), details: details,
                                           sources: [VaultSource(path: path, role: "IRS ITIN notice", rank: IDRank.letter)])
                out.append(VaultFind(title: "ITIN", value: value, note: holder ?? "", facts: facts))
            }
        }
        return out
    }

    /// The name a card's stub or a notice is mailed to: the line above the street address.
    static func mailedTo(_ page: [String]) -> String? {
        for index in page.indices.dropFirst() where page[index].range(of: #"^\s*\d{1,6}\s+[A-Za-z]"#, options: .regularExpression) != nil {
            if let name = nameOnly(page[index - 1]), page[index - 1] == page[index - 1].uppercased() { return name }
        }
        return nil
    }

    /// The name printed under "This number has been established for": its lines of capitals, up
    /// to the first line that is anything else (the signature, or a misread of it). A name that
    /// comes out as one word was cut short by a misread, and is not taken.
    static func cardName(_ page: [String]) -> String? {
        guard let start = page.firstIndex(where: { $0.lowercased().filter { !$0.isWhitespace }.contains("stablishedfor") }) else {
            return nil
        }
        var words: [String] = []
        for line in page[(start + 1)...].prefix(4) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.allSatisfy({ ($0.isLetter && $0.isASCII && $0.isUppercase) || $0 == " " }),
                  !trimmed.lowercased().contains("signature") else { break }
            words.append(trimmed)
        }
        return nameOnly(words.joined(separator: " "))
    }

    /// The date below a card's signature line, which is when the card was issued.
    private static func issueDate(_ page: [String]) -> Date? {
        guard let signature = page.firstIndex(where: { $0.lowercased().contains("signature") }) else { return nil }
        for line in page[(signature + 1)...].prefix(2) {
            if let date = monthFirst(line) { return date }
        }
        return nil
    }

    private static let spelledDatePattern = try! NSRegularExpression(
        pattern: #"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s+((?:19|20)\d{2})\b"#)

    /// "November 12, 2019" anywhere in the text.
    static func spelledDates(in text: String) -> [Date] {
        let ns = text as NSString
        return spelledDatePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let month = monthNumber(ns.substring(with: m.range(at: 1))), let day = Int(ns.substring(with: m.range(at: 2))),
                  let year = Int(ns.substring(with: m.range(at: 3))) else { return nil }
            return calendarDate(year: year, month: month, day: day)
        }
    }

    // MARK: PAN

    /// Five letters, four digits, a letter. The fourth letter says whose (P for a person), and a
    /// person's fifth is their surname's first letter.
    private static let panPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z])(?![A-Za-z0-9])"#)

    static func panNumbers(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        guard squeezed.contains("permanentaccountnumber") || squeezed.contains("incometaxdepartment")
                || squeezed.contains("e-pan") || squeezed.contains("panverification") else { return [] }
        // An e-PAN prints neither the department nor "card", only that it is one.
        let card = squeezed.contains("permanentaccountnumbercard") || squeezed.contains("e-pan")
            || squeezed.contains("epan") || squeezed.contains("cardnotvalidunless")
            || squeezed.contains("panverificationrecord") || squeezed.contains("incometaxdepartment")
        let request = squeezed.contains("requestfornewpan") || squeezed.contains("acknowledgement")
            || squeezed.contains("invoice")
        let role = request ? "PAN request" : squeezed.contains("panverificationrecord") ? "PAN, DigiLocker"
            : card ? "PAN card" : "Names it"
        let rank = request ? IDRank.quoted : card ? IDRank.card : IDRank.quoted
        // Only the card says whose it is: a form quoting a PAN has its own dates and names.
        let own = rank == IDRank.card
        let born = !own ? nil : labelledDate(["DOB", "Date of Birth"], in: page, dayFirst: true)
            ?? page.lazy.compactMap { line -> Date? in
                line.trimmingCharacters(in: .whitespaces).range(of: #"^\d{2}/\d{2}/\d{4}$"#, options: .regularExpression) != nil
                    ? dayFirst(line) : nil
            }.first
        var out: [VaultFind] = []
        var seen = Set<String>()
        for line in page {
            let ns = line as NSString
            for m in panPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                guard seen.insert(value).inserted else { continue }
                let holder = own && value.dropFirst(3).first == "P" ? panHolder(page, initial: Array(value)[4]) : nil
                let facts = VaultReadFacts(category: .pan, holder: holder, born: born, issuer: "IND",
                                           dated: fileDate(path), sources: [VaultSource(path: path, role: role, rank: rank)])
                out.append(VaultFind(title: "PAN", value: value, note: holder ?? "", facts: facts))
            }
        }
        return out
    }

    /// The first name on the page whose surname starts with the PAN's fifth letter: the card holder,
    /// before the father's name printed below it.
    private static func panHolder(_ page: [String], initial: Character) -> String? {
        for line in page {
            var text = line
            if let range = text.range(of: #"^\s*Name\s+"#, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(range)
            }
            guard let name = nameOnly(text), let last = name.split(separator: " ").last,
                  last.uppercased().first == initial else { continue }
            return name
        }
        return nil
    }

    // MARK: Aadhaar

    private static let aadhaarPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])(?<![0-9][ -])([2-9]\d{3})[ -]?(\d{4})[ -]?(\d{4})(?![ -]?\d)"#)

    /// Verhoeff's check, which every Aadhaar number's last digit satisfies.
    static func passesVerhoeff(_ digits: String) -> Bool {
        let d: [[Int]] = [
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
            [3, 4, 0, 1, 2, 8, 9, 5, 6, 7], [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
            [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3], [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
            [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
        ]
        let p: [[Int]] = [
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
            [8, 9, 1, 6, 0, 4, 3, 5, 2, 7], [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
            [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
        ]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
        var c = 0
        for (i, ch) in digits.reversed().enumerated() {
            c = d[c][p[i % 8][Int(String(ch))!]]
        }
        return c == 0
    }

    static func aadhaarNumbers(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        let uidai = squeezed.contains("uniqueidentificationauthority") || squeezed.contains("enrolmentno")
            || squeezed.contains("enrollmentno") || squeezed.contains("uidai")
        guard uidai || squeezed.contains("aadhaar") || squeezed.contains("aadhar") else { return [] }
        let receipt = squeezed.contains("paymentreceipt") || squeezed.contains("acknowledgement") || squeezed.contains("invoice")
        let role = receipt ? "Aadhaar receipt" : uidai ? "Aadhaar letter" : squeezed.contains("digilocker") ? "Aadhaar, DigiLocker" : "Names it"
        let rank = receipt ? IDRank.quoted : (uidai || squeezed.contains("digilocker")) ? IDRank.card : IDRank.quoted
        // On a page only mentioning Aadhaar, the number has to be beside its name.
        let labelled = try! NSRegularExpression(pattern: #"aadha+r"#, options: [.caseInsensitive])
        func nearLabel(_ index: Int) -> Bool {
            page[max(0, index - 1)...index].contains { labelled.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        }
        // Only the letter itself says whose it is and when it was issued. A form that quotes the
        // number has its own "Issue Date" and its own names: a police clearance form's is not
        // the Aadhaar's.
        let own = rank == IDRank.card
        let born = own ? labelledDate(["DOB"], in: page, dayFirst: true) : nil
        let issued = own ? labelledDate(["Issue Date"], in: page, dayFirst: true) : nil
        var holder: String?
        if own, let dob = page.firstIndex(where: { $0.contains("DOB") || $0.lowercased().contains("year of birth") }), dob > 0 {
            holder = nameOnly(page[dob - 1])
        }
        if own, holder == nil, let to = page.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("to") && $0.count <= 4 }) {
            holder = page[(to + 1)...].prefix(3).lazy.compactMap(nameOnly).first
        }
        var out: [VaultFind] = []
        var seen = Set<String>()
        for (index, line) in page.enumerated() where !line.uppercased().contains("VID") {
            let ns = line as NSString
            for m in aadhaarPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = (1...3).map { ns.substring(with: m.range(at: $0)) }.joined()
                guard passesVerhoeff(value), uidai || nearLabel(index), seen.insert(value).inserted else { continue }
                var details: [VaultDetail] = []
                if let issued { details.append(VaultDetail("Issued", .date(issued))) }
                let facts = VaultReadFacts(category: .aadhaar, holder: holder, born: born, issuer: "IND",
                                           dated: issued ?? fileDate(path), details: details,
                                           sources: [VaultSource(path: path, role: role, rank: rank)])
                out.append(VaultFind(title: "Aadhaar", value: value, note: holder ?? "", facts: facts))
            }
        }
        return out
    }

    // MARK: Voter IDs

    private static let epicPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Z]{3}\d{7})(?![A-Za-z0-9])"#)

    static func voterIDs(on page: [String], from path: String) -> [VaultFind] {
        let squeezed = squeezed(page)
        let epic = page.contains { $0.range(of: #"\bEPIC\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
        guard squeezed.contains("electioncommission") || epic else { return [] }
        let slip = squeezed.contains("voterinformation")
        let role = slip ? "Voter information slip" : "Voter ID"
        var holder: String?
        for line in page {
            let ns = line as NSString
            if let m = printedName.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               !line.lowercased().contains("father") {
                holder = nameOnly(ns.substring(with: m.range(at: 1)))
                if holder != nil { break }
            }
        }
        if holder == nil, let gender = page.firstIndex(where: { $0.lowercased().contains("gender") }) {
            holder = page[(gender + 1)...].prefix(2).lazy.compactMap(nameOnly).first
        }
        let born = labelledDate(["Date of Birth / Age:", "Date of Birth"], in: page, dayFirst: true)
        var out: [VaultFind] = []
        var seen = Set<String>()
        for line in page {
            let ns = line as NSString
            for m in epicPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                guard seen.insert(value).inserted else { continue }
                let facts = VaultReadFacts(category: .voterID, holder: holder, born: born, issuer: "IND",
                                           dated: fileDate(path),
                                           sources: [VaultSource(path: path, role: role, rank: slip ? IDRank.letter : IDRank.card)])
                out.append(VaultFind(title: "Voter ID", value: value, note: holder ?? "", facts: facts))
            }
        }
        return out
    }
}
