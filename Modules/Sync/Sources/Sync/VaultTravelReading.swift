import Foundation

/// Permits to travel that carry no machine-readable zone, filed with the Vault's visas: visas
/// granted online (an Indian e-Visa's ETA, an eTA, an ESTA, a visa grant notice), read by the
/// fields every such page labels; and the e-OCI, the PDF copy of an Overseas Citizen of India
/// card. The printed OCI card itself is read from its zone (``MachineZone/ociFind``).
extension VaultReading {

    static func travelPermits(on page: PrintedPage, from path: String) -> [VaultFind] {
        [onlineVisa(on: page, from: path), eOCICard(on: page, from: path)].compactMap { $0 }
    }

    // MARK: Visas granted online

    /// What a visa granted online is called, and where, by what its page says. The page names
    /// the holder's nationality too ("Nationality : UNITED STATES OF AMERICA"), so a country is
    /// known by its issuer's own words, never its bare name.
    private static let onlineVisaIssuers: [(cues: [String], code: String, name: String)] = [
        (["indian e-visa", "government of india", "indianvisaonline"], "IND", "India"),
        (["esta application", "u.s. customs and border protection"], "USA", "US"),
        (["uk visas and immigration", "home office"], "GBR", "UK"),
        (["immigration, refugees and citizenship canada"], "CAN", "Canada"),
        (["department of home affairs", "visa grant notice"], "AUS", "Australia"),
    ]

    /// The labels such pages print for each field, the most telling first.
    private enum OnlineVisaLabels {
        static let cues = ["electronic travel authorization", "electronic travel authorisation", "e-visa",
                           "esta application", "visa grant notice"]
        static let number = ["application id", "esta application number", "application number", "grant number",
                             "visa grant number", "reference number"]
        static let secondNumber = ["eta number", "authorization number", "authorisation number", "transaction number"]
        static let issued = ["date of issue of eta", "date of issue", "issue date", "date of grant", "grant date",
                             "authorization date", "date authorised"]
        static let expires = ["date of expiry of eta", "date of expiry", "expiry date", "expiration date",
                              "authorization expires", "valid until", "must not arrive after"]
        static let passport = ["passport number", "passport no"]
        static let kind = ["service name", "visa subclass", "visa name"]
        static let entries = ["no. of entries", "number of entries", "entries"]
        static let status = ["application status", "authorization status", "authorisation status", "eta status"]
        static let granted = ["granted", "approved", "authorized", "authorised", "issued"]
        static let refused = ["not ", "refused", "rejected", "denied", "cancelled", "canceled", "pending", "revoked"]
        /// What only the application, never the grant, says.
        static let application = ["temporary application", "application form", "applicant details", "regular application"]
        /// A line about the passport, whose own dates an e-Visa page or form also prints.
        static let otherDocument = ["passport"]
    }

    /// A reference number: six to twenty-five letters, digits and dashes, a digit among them, so
    /// a column's next label ("Passport number") is never taken for one.
    private static let referenceNumber = try! NSRegularExpression(
        pattern: #"(?=[A-Z-]*[0-9])[A-Z0-9][A-Z0-9-]{5,24}(?![A-Za-z0-9])"#, options: [.caseInsensitive])
    private static let word = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)
    private static let phrase = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z ]*"#)
    private static let visaName = try! NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9 ()-]*?visa\b|[A-Za-z0-9 ()-]+"#,
                                                           options: [.caseInsensitive])

    /// A visa granted online, known by the number its holder quotes to the issuer (the
    /// application's, else the grant's), with its dates, entries and the passport it is tied to.
    /// Not one: a page whose status is anything but granted, or the application form, which
    /// quotes the same number beside the passport's own dates.
    static func onlineVisa(on page: PrintedPage, from path: String) -> VaultFind? {
        typealias L = OnlineVisaLabels
        guard page.saysAny(L.cues),
              let value = page.value(preferring: L.number, referenceNumber).map(normalized),
              value.filter(\.isNumber).count >= 5 else { return nil }
        let status = page.value(preferring: L.status, phrase)?.lowercased()
        let granted = status.map { status in
            L.granted.contains(where: status.contains) && !L.refused.contains(where: status.contains)
        }
        if granted == false { return nil }
        if granted == nil, page.saysAny(L.application) { return nil }
        let issuer = onlineVisaIssuers.first { page.saysAny($0.cues) }
        // Dates in digits as the issuer writes them: the US month first, everyone else day first.
        let order: DateOrder = issuer?.code == "USA" ? .monthFirst : .dayFirst
        let issued = page.date(preferring: L.issued, order: order, unless: L.otherDocument)
        let until = page.date(preferring: L.expires, order: order, unless: L.otherDocument)
        guard issued != nil || until != nil else { return nil }
        let passport = page.value(L.passport, passportNumber).map(normalized)
        let kind = page.value(preferring: L.kind, visaName).map(visaKind)
        var details: [VaultDetail] = []
        if let kind { details.append(VaultDetail("Visa", .text(kind))) }
        if let second = page.value(preferring: L.secondNumber, referenceNumber).map(normalized), second != value {
            details.append(VaultDetail("ETA number", .number(second)))
        }
        if let entries = page.value(L.entries, word) { details.append(VaultDetail("Entries", .text(titleCased(entries)))) }
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        if let until { details.append(VaultDetail("Valid until", .date(until))) }
        if let passport { details.append(VaultDetail("In passport", .number(passport))) }
        let facts = VaultReadFacts(category: .usVisa, issuer: issuer?.code, form: "e-Visa", dated: issued ?? fileDate(path),
                                   validUntil: until, inPassport: passport, details: details,
                                   sources: [VaultSource(path: path, role: "e-Visa", rank: Rank.visaFoil)])
        let title = [issuer?.name, "e-Visa"].compactMap { $0 }.joined(separator: " ")
        return VaultFind(title: title, value: value, note: sentence([until.map { "valid until \(spelled($0))" }].compactMap { $0 }),
                         facts: facts)
    }

    /// A visa's name as its page prints it, in the case it is written in: "eTOURIST VISA" and
    /// "e-Tourist Visa" are both "e-Tourist Visa".
    static func visaKind(_ printed: String) -> String {
        let chars = Array(printed.trimmingCharacters(in: .whitespaces))
        // The e of an e-visa: "e-…" or "E-…", or a small e on capitals ("eTOURIST"), never the
        // start of a word ("Electronic").
        let electronic = chars.count > 2 && (chars[0] == "e" || chars[0] == "E")
            && (chars[1] == "-" || (chars[0] == "e" && chars[1].isUppercase))
        guard electronic else { return titleCased(String(chars).lowercased()) }
        return "e-" + titleCased(String(chars.dropFirst().drop { $0 == "-" || $0 == " " }).lowercased())
    }

    // MARK: e-OCI

    /// An OCI number alone on its line: a letter and seven digits ("A1234567"). A US passport,
    /// printed on the same page, has eight digits or nine.
    private static let ociNumberLine = try! NSRegularExpression(pattern: #"^\s*([A-Z])\s?([0-9]{7})\s*$"#)
    private static let passportLine = try! NSRegularExpression(pattern: #"^\s*([A-Z]?[0-9]{8,9})\s*$"#)

    /// The e-OCI prints its fields without labels, in a fixed order: the name, the nationality,
    /// the OCI number with its date of issue below, "LIFELONG", the passport, the date of birth,
    /// and a "Generated On" stamp. Read only on a page that says OCI and Lifelong and is not the
    /// card's application, and only the number in an OCI's shape.
    static func eOCICard(on page: PrintedPage, from path: String) -> VaultFind? {
        guard page.hasWord("oci"), page.says("lifelong"), !page.says("application"),
              !page.says("overseas citizen of india card holder") else { return nil }
        let lines = page.lines
        func match(_ pattern: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }
        guard let at = lines.firstIndex(where: { match(ociNumberLine, $0) != nil }),
              let m = match(ociNumberLine, lines[at]) else { return nil }
        let ns = lines[at] as NSString
        let value = ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2))
        // The card's own dates after its number, never the stamp of when the PDF was made.
        let dated = lines.indices.filter { $0 > at && !lines[$0].lowercased().contains(" on") }.compactMap { index in
            PrintedPage.dates(in: lines[index], order: .dayFirst).first.map { (index, $0.date) }
        }
        let issued = dated.first { $0.0 <= at + 3 }?.1
        let born = dated.map(\.1).first { issued == nil || $0 < issued! }
        let holder = lines[..<at].lazy.compactMap(nameOnly).first
        let passport = lines[at...].lazy.compactMap { line in
            match(passportLine, line).map { (line as NSString).substring(with: $0.range(at: 1)) }
        }.first
        var details: [VaultDetail] = []
        if let issued { details.append(VaultDetail("Issued", .date(issued))) }
        details.append(VaultDetail("Valid", .text("Lifelong")))
        if let passport { details.append(VaultDetail("Passport", .number(passport))) }
        let facts = VaultReadFacts(category: .usVisa, holder: holder, born: born, issuer: "IND", form: "OCI",
                                   dated: issued ?? fileDate(path), details: details,
                                   sources: [VaultSource(path: path, role: "e-OCI", rank: Rank.visaFoil)])
        return VaultFind(title: "OCI card", value: value, note: sentence([holder, "OCI for life"].compactMap { $0 }), facts: facts)
    }
}
