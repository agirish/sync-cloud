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

    /// One page's identity numbers. `page` is the page as every reader questions it, made once
    /// for all of them.
    /// `roots` are the read folders, which say whether the paper is a school's
    /// (``aadhaarNumbers(on:from:under:)``).
    static func identityNumbers(on page: PrintedPage, from path: String, under roots: [String] = []) -> [VaultFind] {
        licenseBarcodes(on: page, from: path) + usLicenseFronts(on: page, from: path)
            + indianLicenses(on: page, from: path) + socialSecurityNumbers(on: page, from: path)
            + panNumbers(on: page, from: path) + aadhaarNumbers(on: page, from: path, under: roots)
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

    private static func dateParts(_ text: String) -> (Int, Int, Int)? {
        let ns = text as NSString
        guard let m = PrintedPage.numeric.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let a = Int(ns.substring(with: m.range(at: 1))), let b = Int(ns.substring(with: m.range(at: 2))),
              let y = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        return (a, b, y)
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
    /// The address's elements: street, second street line, city, ZIP. Kept apart from
    /// ``aamvaElements``, which also mark where a run-together number ends.
    private static let addressElements = ["DAG", "DAH", "DAI", "DAK"]

    /// The license's PDF417 barcode, which the app appends to a page's lines as decoded
    /// (``VaultDocumentReading``): its header ("ANSI 636014…DLDAQ…") and one element per line.
    static func licenseBarcodes(on printed: PrintedPage, from path: String) -> [VaultFind] {
        let page = printed.lines
        guard let header = page.firstIndex(where: { $0.range(of: #"ANSI ?[0-9]{6}"#, options: .regularExpression) != nil }) else {
            return []
        }
        var fields: [String: String] = [:]
        var isIDCard = false
        for line in page[header...] {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{1e}\u{1d}")))
            if fields["DAQ"] == nil, let range = text.range(of: "DAQ"),
               text[..<range.lowerBound].hasSuffix("DL") || text[..<range.lowerBound].hasSuffix("ID")
                || text[..<range.lowerBound].last?.isNumber == true {
                // The first element rides on the header line (or the line the header wraps to),
                // right after the subfile's type: "DL" for a license, "ID" for a state ID card, or
                // straight after the header's own digits. Only there: "DAQ" inside another element
                // ("DACDAQUAN", a first name) is not it.
                isIDCard = text[..<range.lowerBound].hasSuffix("ID")
                fields["DAQ"] = Self.licenseNumber(String(text[range.upperBound...]))
                continue
            }
            let id = String(text.prefix(3))
            guard aamvaElements.contains(id) || addressElements.contains(id), fields[id] == nil else { continue }
            let rest = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            fields[id] = id == "DAQ" ? Self.licenseNumber(rest) : rest
        }
        let value = normalized(fields["DAQ"] ?? "")
        guard value.count >= 4, value.filter(\.isNumber).count >= 4 else { return [] }
        let canadian = fields["DCG"]?.uppercased() == "CAN"
        func date(_ id: String) -> Date? {
            guard let raw = fields[id], raw.count == 8,
                  case let digits = raw.compactMap({ $0.isASCII ? $0.wholeNumberValue : nil }), digits.count == 8 else { return nil }
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
                                   sources: [VaultSource(path: path, role: "Driver’s license barcode", rank: IDRank.card,
                                                         address: canadian ? nil : licenseAddress(fields, state: state)
                                                            .map { VaultPrintedAddress($0, dated: issued ?? fileDate(path)) })])
        return [VaultFind(title: (isIDCard ? "State ID" : "Driver’s license") + (state.map { " · " + $0 } ?? ""),
                          value: value, note: sentence(notes), facts: facts)]
    }

    /// The home address a US license's barcode states, when it states one whole: street, city,
    /// state and a ZIP of five digits or more ("951320000" is 95132).
    static func licenseAddress(_ fields: [String: String], state: String?) -> VaultAddress? {
        func field(_ id: String) -> String? {
            fields[id].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.uppercased() == "NONE" ? nil : $0 }
        }
        guard let street = field("DAG"), let city = field("DAI"), let state, postalStates.contains(state),
              let zip = field("DAK").map({ String($0.prefix { $0.isNumber }) }), zip.count >= 5,
              !isPostBox(street) else { return nil }
        return VaultAddress(street: street, unit: field("DAH"), city: city, state: state, zip: String(zip.prefix(5)))
    }

    /// A license number as the barcode gives it, ending where the number does: at a space, or at
    /// the next element when a payload arrived with its separators lost
    /// ("D1234567DCSSMITHDAC…" is D1234567). AAMVA allows 25 characters at most.
    static func licenseNumber(_ raw: String) -> String {
        var number = String(raw.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(25))
        for element in aamvaElements where element != "DAQ" {
            if let range = number.range(of: element), number.distance(from: number.startIndex, to: range.lowerBound) >= 4 {
                number = String(number[..<range.lowerBound])
            }
        }
        return number
    }

    // MARK: US driver's licenses: the front

    static let usStates: [String: String] = [
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

    /// The state a license front names in its header, "California USA DRIVER LICENSE": whole
    /// words, the longest name first, so "West Virginia" is not Virginia; never the address
    /// below, where "123 Michigan Ave" is a street.
    static func issuingState(_ page: [String]) -> String? {
        let header = page.prefix(4).filter { !$0.contains(where: \.isNumber) }.joined(separator: " ").lowercased()
        let words = " " + header.split(whereSeparator: { !$0.isLetter }).joined(separator: " ") + " "
        return usStates.keys.sorted { $0.count > $1.count }.first { words.contains(" \($0) ") }.flatMap { usStates[$0] }
    }

    /// "DL D1234567" or "DLN D1234567": one or two letters at most, then digits. The label is
    /// required, so a card's other numbers (the document discriminator, a barcode's digits) never are.
    private static let usLicensePattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])DLN?\s*[:#]?\s*([A-Z]{0,2}[0-9]{5,14})(?![A-Za-z0-9])(?! ?[0-9]{3})"#)
    private static let givenLine = try! NSRegularExpression(pattern: #"^\s*(?:[0-9]\s*)?FN\s+([A-Z][A-Z\x27 -]*[A-Z])\s*$"#)
    private static let familyLine = try! NSRegularExpression(pattern: #"^\s*(?:[0-9]\s*)?LN\s+([A-Z][A-Z\x27 -]*[A-Z])\s*$"#)

    static func usLicenseFronts(on printed: PrintedPage, from path: String) -> [VaultFind] {
        let page = printed.lines
        let squeezed = printed.spacedSqueezed
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
        let state = issuingState(page)
        let until = printed.date(["EXP"], order: .monthFirst)
        let issued = printed.date(["ISS"], order: .monthFirst)
        let born = printed.date(["DOB"], order: .monthFirst)
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
        pattern: #"(?<![A-Z0-9])([A-Z]{2})[- ]?([0-9]{2})[- ]?((?:19|20)[0-9]{2})[- ]?([0-9]{7})(?![0-9])"#)
    private static let printedName = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])Name\s*:\s*([A-Za-z][A-Za-z .]*[A-Za-z])"#)

    static func indianLicenses(on printed: PrintedPage, from path: String) -> [VaultFind] {
        let page = printed.lines
        let squeezed = printed.spacedSqueezed
        guard squeezed.contains("drivinglicen") || squeezed.contains("parivahan") || squeezed.contains("sarathi")
                || squeezed.contains("dlnumber") || squeezed.contains("dlservices") else { return [] }
        let text = printed.text
        let ns = text as NSString
        var holder: String?
        for line in page where !relativeLabels.contains(where: line.lowercased().contains) {
            if let name = labelledName(line) {
                holder = name
                break
            }
        }
        // "D.O.I" and "D.O.B" with or without the last dot.
        let issued = printed.date(["Date of Issue", "DL Issue Date", "D.O.I.", "D.O.I"], order: .dayFirst)
        let until = printed.date(["Date of Expiry", "Valid upto", "Valid up to"], order: .dayFirst)
            ?? ntValidity(in: text)
        let born = printed.date(["DOB", "D.O.B.", "D.O.B", "Date of Birth"], order: .dayFirst)
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

    /// A line naming a relative, whose name is never the holder's: "Father's Name", "S/O", "W/O".
    static let relativeLabels = ["father", "husband", "mother", "guardian", "spouse", "s/o", "d/o", "c/o", "w/o", "s/w/d"]

    /// The words that end a labelled name: a card's own words and the labels printed after a name.
    private static let labelledNameStops: Set<String> = cardWords.union(["blood", "group", "gender", "sex", "age", "dob", "relation"])

    /// The name after "Name :" on a line, up to the next label: "Name : RAVI KUMAR Blood Group :
    /// O+" is Ravi Kumar. Nil when what follows is a label, or not two words.
    static func labelledName(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = printedName.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let words = ns.substring(with: m.range(at: 1)).split(separator: " ").map(String.init)
        let name = words.prefix { !labelledNameStops.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        guard name.filter({ $0.count >= 2 }).count >= 2 else { return nil }
        return titleCased(name.joined(separator: " "))
    }

    /// The end of "NT Validity : 01-02-2010 to 31-01-2030".
    private static func ntValidity(in text: String) -> Date? {
        guard let range = text.range(of: #"validity\s*:?\s*[0-9/.-]+\s*to\s*[0-9/.-]+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let found = String(text[range])
        guard let to = found.range(of: "to", options: [.caseInsensitive, .backwards]) else { return nil }
        return dayFirst(String(found[to.upperBound...]))
    }

    // MARK: Social Security numbers and ITINs

    /// What only a Social Security card prints. "Established for" is said of accounts and trusts
    /// too, so it counts with the rest of the card's sentence, or with the card's name or its
    /// signature line read somewhere on the page (``isSocialSecurityCard(_:)``).
    private static let cardCues = ["numberhasbeenestablishedfor", "validforworkonly", "workonlywith", "dhsauthorization",
                                   "notvalidforemployment"]
    private static let ssnLine = try! NSRegularExpression(pattern: #"^\s*([0-9]{3})[- ]([0-9]{2})[- ]([0-9]{4})\s*$"#)
    private static let itinInText = try! NSRegularExpression(pattern: #"(?<![0-9])(9[0-9]{2})-([0-9]{2})-([0-9]{4})(?![0-9])"#)

    /// What the sheet a card is mailed on, and the card's back, tell its holder, in sentences
    /// no other paper prints: one is enough.
    static let sheetCues = ["signthiscardinink", "thiscardbelongstothesocialsecurityadministration",
                            "improperuseofthiscard", "donotcarrythiscard"]
    /// What they also say in words other papers use of other cards ("Do not laminate your
    /// badge", Medicare's "Keep your card in a safe place"): two of these, never one.
    static let looseSheetCues = ["donotlaminate", "keepyourcardinasafeplace", "keepyoursocialsecuritycardinasafeplace",
                                 "donotcarryitwithyou", "donotsignuntilage"]
    /// That sheet's heading, when it is all a line says.
    static let sheetHeadings: Set<String> = ["socialsecuritycard", "yoursocialsecuritycard",
                                                     "yournewsocialsecuritycard", "newsocialsecuritycard",
                                                     "replacementsocialsecuritycard", "yourreplacementsocialsecuritycard"]
    /// A form's own number as a line prints it ("Form W-4", "Form I–765", "Form N-400", "Form
    /// 1040", whichever dash a scan read), or its OMB number. Not the "Form SSA-3000" on a card's
    /// back, a "Form" that only ends the line above a number, or the word before a number
    /// written out ("in the form 123-45-6789").
    private static let formLine = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(?:form\s*(?!ssa|oa)(?![0-9]{3}-[0-9]{2}-[0-9]{4})(?:[a-z0-9]{1,3}[-\u2010-\u2014][0-9]|[a-z]{1,3}[0-9]|[0-9]{3,4}(?![0-9]))|[o0]mb\s*(?:no|n0|#|control|approval|number))"#,
        options: [.caseInsensitive])

    /// A card, or the sheet it came on, and not a form that prints the card's words.
    ///
    /// The card's own print settles it, unless the page is the application for one (SSA's SS-5)
    /// or the I-9's list of documents ("valid for work only with DHS authorization").
    ///
    /// "Social Security card" alone is also what a form asks about: "the name on your social
    /// security card" (W-4, W-2), "issue you a Social Security card" (I-765, N-400). With none of
    /// the card's print read, those words count only on the sheet itself: a page with the
    /// sheet's heading on a line of its own, or what it tells the holder to do with the card
    /// ("Sign this card in ink"; "Do not laminate" with "Keep your card in a safe place"), and
    /// with no form's number on it.
    static func isSocialSecurityCard(_ printed: PrintedPage) -> Bool {
        let (page, squeezed) = (printed.lines, printed.spacedSqueezed)
        let forms = ["applicationforasocialsecuritycard", "formss-5", "ss-5", "employmenteligibilityverification",
                     "formi-9", "listsofacceptabledocuments"]
        guard !forms.contains(where: squeezed.contains) else { return false }
        if cardCues.contains(where: squeezed.contains) { return true }
        if squeezed.contains("establishedfor"), squeezed.contains("socialsecurity") || squeezed.contains("signature") {
            return true
        }
        guard squeezed.contains("socialsecuritycard") else { return false }
        let heading = page.contains { line in
            // A colon may end a heading; a full stop or a question mark ends a sentence that
            // wrapped ("Do you want the SSA to issue you a / Social Security card?").
            let words = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
            return words.allSatisfy { $0.isLetter || $0 == " " } && sheetHeadings.contains(words.lowercased().filter(\.isLetter))
        }
        guard heading || sheetCues.contains(where: squeezed.contains)
                || looseSheetCues.filter(squeezed.contains).count >= 2 else { return false }
        return !page.contains { formLine.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }

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
        let printed = PrintedPage(page)
        let squeezed = printed.spacedSqueezed
        if isSocialSecurityCard(printed) {
            return socialSecurityNumbers(on: printed, from: "", isCard: true).isEmpty
        }
        let licenseBack = squeezed.contains("licensetodrive") || squeezed.contains("issuedasalicense")
            || (squeezed.contains("endorsements") && squeezed.contains("restrictions"))
        return licenseBack && !page.contains { $0.range(of: #"ANSI ?[0-9]{6}"#, options: .regularExpression) != nil }
    }

    static func socialSecurityNumbers(on printed: PrintedPage, from path: String) -> [VaultFind] {
        socialSecurityNumbers(on: printed, from: path, isCard: isSocialSecurityCard(printed))
    }

    /// ``socialSecurityNumbers(on:from:)`` for a caller that has already asked whether the page
    /// is a card.
    private static func socialSecurityNumbers(on printed: PrintedPage, from path: String, isCard: Bool) -> [VaultFind] {
        let (page, squeezed) = (printed.lines, printed.spacedSqueezed)
        let isITINNotice = squeezed.contains("individualtaxpayeridentificationnumber")
        guard isCard || isITINNotice else { return [] }
        // Two cards scanned on one page: which name goes with which number is not printed in a
        // way to trust, so neither is given one.
        let numbersOnPage = page.filter { ssnLine.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        let holder = Set(numbersOnPage.map(normalized)).count > 1 ? nil : mailedTo(page) ?? cardName(page)
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
            let text = printed.text
            let ns = text as NSString
            let dates = PrintedPage.fullMonthDates(in: text).sorted()
            let noticeDate = dates.last
            // The birth date is the earliest the notice prints, years before the notice.
            let born = dates.first.flatMap { first in
                noticeDate.map { $0.timeIntervalSince(first) > bornBeforeNotice } == true ? first : nil
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

    /// How far before an ITIN notice's own date the earliest date it prints must be to be read as
    /// the holder's birth date: ten years.
    private static let bornBeforeNotice: TimeInterval = 10 * 365 * 86_400

    /// The name a card's stub or a notice is mailed to: the line above the street address.
    static func mailedTo(_ page: [String]) -> String? {
        for index in page.indices.dropFirst() where page[index].range(of: #"^\s*[0-9]{1,6}\s+[A-Za-z]"#, options: .regularExpression) != nil {
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
                  !trimmed.lowercased().contains("signature"), !holdsMisreadCardWord(trimmed) else { break }
            words.append(trimmed)
        }
        return nameOnly(words.joined(separator: " "))
    }

    /// The card's own long words, which its background prints over and over in small type.
    private static let printedWords = ["social", "security", "administration", "america", "united", "states",
                                       "signature", "established"]

    /// Whether `line` holds one of the card's own words as a scan misreads it ("SDCIAL SEGURITY",
    /// a line of the background's small print): a word of five letters or more, one letter from
    /// one of them. No name is: a name that close to "Social" is a misread of it.
    static func holdsMisreadCardWord(_ line: String) -> Bool {
        line.lowercased().split(whereSeparator: { !$0.isLetter }).contains { word in
            word.count >= 5 && printedWords.contains { VaultPeopleClusters.editDistance(Array(word), Array($0)) <= 1 }
        }
    }

    /// The date below a card's signature line, which is when the card was issued.
    private static func issueDate(_ page: [String]) -> Date? {
        guard let signature = page.firstIndex(where: { $0.lowercased().contains("signature") }) else { return nil }
        for line in page[(signature + 1)...].prefix(2) {
            if let date = monthFirst(line) { return date }
        }
        return nil
    }

    // MARK: PAN

    /// Five letters, four digits, a letter. The fourth letter says whose (P for a person), and a
    /// person's fifth is their surname's first letter.
    private static let panPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z]{3}[PCHFATBLJG][A-Z][0-9]{4}[A-Z])(?![A-Za-z0-9])"#)

    /// "e-PAN" as the card and its cover note print it, however a scan spaces it:
    ///
    /// - a small e tied to PAN by a dash, whichever dash: "e-PAN", "e–PAN Card", "e-P AN",
    ///   "e-PANCard", or the dash ending one line and PAN starting the next;
    /// - either e, spaced any way, with the dash or without, when "card" follows or the line ends
    ///   there: "e - PAN", "e PAN Card", "E-PAN CARD", "INSTANT E-PAN", "ePANcard";
    /// - "ePAN" run together.
    ///
    /// Never the end of another word ("Employee PAN", "the PAN", "i.e - PAN of the deductor"),
    /// the start of one ("e-Panchayat", "e-panel"), or a list's lettered item ("E - PAN of the
    /// deductor", "PART E-PAN DETAILS").
    private static let ePANWord: NSRegularExpression = {
        let dash = #"[-\u2010-\u2014]"#
        let pan = #"[Pp][ \t]*[Aa][ \t]*[Nn]"#
        let card = #"[ \t]*[Cc][Aa][Rr][Dd]"#
        let start = #"(?<![A-Za-z.])"#
        let end = #"(?![A-Za-z])"#
        let tied = "\(start)e\(dash)\\s*\(pan)(?:\(card))?\(end)"
        let named = "\(start)[eE][ \\t]*\(dash)?[ \\t]*\(pan)(?:\(card)\(end)|[ \\t]*$)"
        let together = "\(start)ePAN\(end)"
        return try! NSRegularExpression(pattern: "(?m)(?:\(tied)|\(named)|\(together))")
    }()

    /// The e-PAN's own heading, "e-Permanent Account Number Card" or "e - Permanent Account Number
    /// (e-PAN) Card": a small e, so never the end of "the" or "i.e", nor a list's lettered item.
    private static let ePANHeading = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z.])e[ \t]*[-\u2010-\u2014]?[ \t]*[Pp](?i:ermanent\s+account\s+number)"#)

    /// The label over a PAN card's holder or father, alone on its line, after its Hindi and a
    /// slash or without: "Name", "नाम / Name", "Father's Name". A form's field carries its value or
    /// more words beside it ("Name of applicant: …").
    private static let holderLabel = try! NSRegularExpression(
        pattern: #"(?i)^(?:[^A-Za-z/]*/)?[ \t]*(?:father['’]?s[ \t]*)?name[ \t]*:?[ \t]*$"#)

    /// Whether a page naming the e-PAN is the e-PAN: its heading, or the holder's block under it.
    /// A form asking for a copy of one only names it.
    private static func isEPAN(_ printed: PrintedPage) -> Bool {
        let text = printed.text
        guard ePANHeading.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) == nil else {
            return true
        }
        return printed.lines.contains { line in
            holderLabel.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
    }

    static func panNumbers(on printed: PrintedPage, from path: String) -> [VaultFind] {
        let page = printed.lines
        let squeezed = printed.spacedSqueezed
        let text = printed.text
        let ePAN = ePANWord.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        guard squeezed.contains("permanentaccountnumber") || squeezed.contains("incometaxdepartment")
                || ePAN || squeezed.contains("panverification") else { return [] }
        // An e-PAN prints neither the department nor "card", only that it is one, and its holder's
        // block. The department's name alone is on every tax notice too: the older card also
        // prints "GOVT. OF INDIA" and the holder's father, which a notice does not.
        let card = squeezed.contains("permanentaccountnumbercard") || (ePAN && isEPAN(printed))
            || squeezed.contains("cardnotvalidunless")
            || squeezed.contains("panverificationrecord")
            || (squeezed.contains("incometaxdepartment") && squeezed.contains("govt")
                && squeezed.contains("permanentaccountnumber")
                && !["intimation", "section", "assessment", "refund", "demand", "notice"].contains(where: squeezed.contains))
        let request = squeezed.contains("requestfornewpan") || squeezed.contains("acknowledgement")
            || squeezed.contains("invoice")
        let role = request ? "PAN request" : squeezed.contains("panverificationrecord") ? "PAN, DigiLocker"
            : card ? "PAN card" : "Names it"
        let rank = request ? IDRank.quoted : card ? IDRank.card : IDRank.quoted
        // Only the card says whose it is: a form quoting a PAN has its own dates and names.
        let own = rank == IDRank.card
        let born = !own ? nil : printed.date(["DOB", "Date of Birth"], order: .dayFirst)
            ?? page.lazy.compactMap { line -> Date? in
                line.trimmingCharacters(in: .whitespaces).range(of: #"^[0-9]{2}/[0-9]{2}/[0-9]{4}$"#, options: .regularExpression) != nil
                    ? dayFirst(line) : nil
            }.first
        var out: [VaultFind] = []
        var seen = Set<String>()
        for line in page {
            let ns = line as NSString
            for m in panPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                // Off a card, only a person's PAN: a tax notice also prints the employer's, a
                // company's (its fourth letter C), which is nobody's in the household.
                guard own || value.dropFirst(3).first == "P", seen.insert(value).inserted else { continue }
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
        for (index, line) in page.enumerated() {
            // The line under "Father's Name" is the father's, who shares the surname's letter.
            if index > 0, relativeLabels.contains(where: page[index - 1].lowercased().contains) { continue }
            if relativeLabels.contains(where: line.lowercased().contains) { continue }
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
        pattern: #"(?<![0-9])(?<![0-9][ -])([2-9][0-9]{3})[ -]?([0-9]{4})[ -]?([0-9]{4})(?![ -]?[0-9])"#)

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
        // ASCII digits only: another script's digit is a number to Swift but has no place here.
        let values = digits.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        guard !digits.isEmpty, values.count == digits.count else { return false }
        var c = 0
        for (i, value) in values.reversed().enumerated() {
            c = d[c][p[i % 8][value]]
        }
        return c == 0
    }

    /// The label of an Aadhaar letter's enrolment number, on a line with its spaces dropped;
    /// the group is the second l of the American spelling.
    private static let enrolmentLabel = try! NSRegularExpression(pattern: #"enrol(l?)ment(?:no|number)"#)
    /// UIDAI's three groups after "Enrolment No." in its own spelling, which few other papers
    /// use: four digits, five and five, whatever a scan made of the two slashes (a bar, an I, a
    /// 1, a 7, a dash, a gap, nothing).
    private static let enrolmentGroups = try! NSRegularExpression(
        pattern: #"^[^0-9]{0,30}[0-9o]{4}(?:[^0-9a-z]?[0-9o]{5}[^0-9a-z]?|.[0-9o]{5}.)[0-9o]{5}(?![0-9])"#)
    /// The same after the American "Enrollment", which health plans and schools print over
    /// numbers of their own: only with both slashes read as a slash or a bar.
    private static let enrollmentGroups = try! NSRegularExpression(
        pattern: #"^[^0-9]{0,30}[0-9o]{4}[/|][0-9o]{5}[/|][0-9o]{5}(?![0-9])"#)

    /// Whether the page prints an Aadhaar letter's enrolment number: its label with UIDAI's
    /// three groups after it ("Enrolment No.: 1234/12345/12345"), on the label's line or, when
    /// that line holds no digit, the one below. Read line by line, so the digits a page prints
    /// next (a helpline, a postcode) never complete a school's "2024/00123". The label alone is
    /// also the start of "Open Enrollment Notice".
    ///
    /// `slashedOnly`, for a school's paper, takes only the groups with both slashes read as a
    /// slash or a bar, as for the American spelling: an Indian school or university prints its
    /// own fourteen or sixteen digits in one run under the same label (VT91).
    static func saysEnrolmentNumber(_ page: [String], slashedOnly: Bool = false) -> Bool {
        let lines = page.map(PrintedPage.squeeze)
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            guard let label = enrolmentLabel.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            var after = ns.substring(from: label.range.upperBound)
            if !after.contains(where: { $0.isASCII && $0.isNumber }), index + 1 < lines.count { after = lines[index + 1] }
            let groups = label.range(at: 1).length == 0 && !slashedOnly ? enrolmentGroups : enrollmentGroups
            if groups.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) != nil { return true }
        }
        return false
    }

    /// UIDAI's name for itself, as a word, however a scan runs it into its address or spaces it
    /// out (help@uidai.gov.in, "www.uidaigov.in", "U I D A I"): the letters are also the middle
    /// of "Liquid Aid".
    private static let uidaiWord = try! NSRegularExpression(pattern: #"(?<![A-Za-z])u ?i ?d ?a ?i(?:gov)?(?![A-Za-z])"#,
                                                            options: [.caseInsensitive])

    /// Whether the page prints UIDAI's name, in full or as its word.
    static func namesUIDAI(_ printed: PrintedPage) -> Bool {
        let text = printed.text
        return printed.spacedSqueezed.contains("uniqueidentificationauthority")
            || uidaiWord.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Whether a paper is filed under School, where "Enrolment No" is the student's number
    /// (``accountNumbers(on:from:under:people:)``) unless the page names UIDAI.
    static func isSchoolPaper(_ path: String, under roots: [String]) -> Bool {
        VaultReadPlan.place(of: path, under: roots).first?.lowercased() == "school"
    }

    static func aadhaarNumbers(on printed: PrintedPage, from path: String, under roots: [String] = []) -> [VaultFind] {
        let page = printed.lines
        let squeezed = printed.spacedSqueezed
        let uidai = namesUIDAI(printed) || saysEnrolmentNumber(page, slashedOnly: isSchoolPaper(path, under: roots))
        guard uidai || squeezed.contains("aadhaar") || squeezed.contains("aadhar") else { return [] }
        let receipt = squeezed.contains("paymentreceipt") || squeezed.contains("acknowledgement") || squeezed.contains("invoice")
        let role = receipt ? "Aadhaar receipt" : uidai ? "Aadhaar letter" : squeezed.contains("digilocker") ? "Aadhaar, DigiLocker" : "Names it"
        let rank = receipt ? IDRank.quoted : (uidai || squeezed.contains("digilocker")) ? IDRank.card : IDRank.quoted
        // On a page only mentioning Aadhaar, the number has to be beside its label: on the label's
        // line, or alone under a line that is only the label. "Aadhaar seeding: Linked" over a
        // twelve-digit account number is neither; nor is any line about an account.
        func nearLabel(_ index: Int) -> Bool {
            let line = page[index].lowercased()
            guard !["a/c", "account", "acct", "ifsc"].contains(where: line.contains) else { return false }
            if line.range(of: #"aadha+r"#, options: .regularExpression) != nil { return true }
            guard index > 0 else { return false }
            let above = page[index - 1].lowercased().trimmingCharacters(in: .whitespaces)
            return above.range(of: #"^[^a-z0-9]*aadha+r\s*(no\.?|number|#|uid)?\s*:?$"#, options: .regularExpression) != nil
                && line.filter { !$0.isNumber && !$0.isWhitespace && $0 != "-" }.isEmpty
        }
        // Only the letter itself says whose it is and when it was issued. A form that quotes the
        // number has its own "Issue Date" and its own names: a police clearance form's is not
        // the Aadhaar's.
        let own = rank == IDRank.card
        let born = own ? printed.date(["DOB"], order: .dayFirst) : nil
        let issued = own ? printed.date(["Issue Date"], order: .dayFirst) : nil
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

    private static let epicPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Z]{3}[0-9]{7})(?![A-Za-z0-9])"#)

    static func voterIDs(on printed: PrintedPage, from path: String) -> [VaultFind] {
        let page = printed.lines
        let squeezed = printed.spacedSqueezed
        // "EPIC No", in capitals, beside its label: the word "epic" alone is in plain English, on
        // a game store's receipt and in a hospital's records.
        let epic = page.contains { $0.range(of: #"\bEPIC\s*(No|Number|NO)\b"#, options: .regularExpression) != nil }
        let slip = squeezed.contains("voterinformation")
        guard squeezed.contains("electioncommission") || squeezed.contains("electorsphotoidentitycard") || epic
              || (slip && squeezed.contains("pollingstation")) else { return [] }
        let role = slip ? "Voter information slip" : "Voter ID"
        var holder: String?
        for line in page where !relativeLabels.contains(where: line.lowercased().contains) {
            let ns = line as NSString
            if let m = printedName.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                holder = nameOnly(ns.substring(with: m.range(at: 1)))
                if holder != nil { break }
            }
        }
        if holder == nil, let gender = page.firstIndex(where: { $0.lowercased().contains("gender") }) {
            holder = page[(gender + 1)...].prefix(2).lazy.compactMap(nameOnly).first
        }
        let born = printed.date(["Date of Birth / Age:", "Date of Birth"], order: .dayFirst)
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
