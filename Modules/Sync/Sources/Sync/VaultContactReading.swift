import Foundation

/// A phone number a paper prints as someone's in People, and whose.
public struct VaultPrintedPhone: Codable, Equatable, Hashable, Sendable {
    /// Ten digits, the area code first: "4085550142".
    public var number: String
    /// "Mobile", "Home" or "Work", as the paper's label says; nil when it says only "Phone".
    public var label: String?
    /// Whose, by People's id: the name the paper prints it under.
    public var person: String
    /// The paper's own date, as an address's: what orders a person's phones, the newest leading.
    public var dated: Date?

    public init(number: String, label: String? = nil, person: String, dated: Date? = nil) {
        self.number = number
        self.label = label
        self.person = person
        self.dated = dated
    }
}

/// What one paper says of the household: the home it is mailed to, and the phones it prints
/// under a name in People.
struct VaultPrintedContacts: Equatable {
    var address: VaultAddress?
    var phones: [VaultPrintedPhone] = []
}

/// Home addresses and phones, read only where a paper prints them as a named person's: under a
/// name in People, with nothing between that makes them a company's. A business's own address
/// and phone (the letterhead, Customer Service, where to send a payment, the seller, the
/// provider) are never read, however near the name they are printed.
extension VaultReading {

    /// A page's line, as the contact reader weighs it: its words, and who in People it names.
    struct ContactLine {
        let text: String
        /// Lower case, letters and digits only, an email address left out.
        let words: [String]
        /// The words a People name spent, and whose name it was.
        let nameWords: Set<String>
        let people: Set<String>

        init(_ text: String, registry: PersonRegistry) {
            self.text = text
            let bare = VaultReading.withoutEmails(text)
            words = PersonRegistry.words(bare)
            let report = registry.explain(in: bare)
            nameWords = Set(report.matches.flatMap(\.words))
            people = Set(report.matches.map(\.personId))
        }

        /// The words left once the People names, numbers and months are taken out.
        var otherWords: [String] {
            words.filter { word in
                !nameWords.contains(word) && !word.allSatisfy(\.isNumber) && !VaultReading.monthWords.contains(word)
            }
        }

        /// Whether every word but a People name is one of `allowed`.
        func onlyNames(and allowed: Set<String>) -> Bool {
            otherWords.allSatisfy { allowed.contains($0) || VaultReading.isOrdinalOrCode($0) }
        }

        /// One person in People, and only them.
        var person: String? { people.count == 1 ? people.first : nil }

        /// Whether it names a business, or a business's part on the paper ("Seller", "Provider").
        var isBusiness: Bool { isCompany || namesRole }

        /// Whether it holds a word a company calls itself by: "LLC", "Bank", "Hospital".
        var isCompany: Bool { otherWords.contains(where: VaultReading.companyWords.contains) }

        /// Whether it says whose part the next lines are, and it is a business's: "Seller:",
        /// "Provider", "Sold by", "Return to".
        var namesRole: Bool {
            otherWords.contains(where: VaultReading.roleWords.contains)
                || VaultReading.rolePhrases.contains(where: { joinedWords.contains($0) })
        }

        /// A label of a business's part and nothing else, on a line of its own: "Seller:",
        /// "Sold By", "Dealer Information". One with a value ("Agent: Bob Smith") speaks only
        /// of its own line.
        var isRoleLabel: Bool {
            isBusiness && people.isEmpty && otherWords.allSatisfy {
                VaultReading.roleWords.contains($0) || VaultReading.companyWords.contains($0)
                    || VaultReading.labelFillers.contains($0)
            }
        }

        var joinedWords: String { " " + words.joined(separator: " ") + " " }
    }

    /// Words a business calls itself by, or ends its name with. A line holding one, beside a
    /// name or between it and the street, makes the block a company's.
    static let companyWords: Set<String> = [
        "inc", "incorporated", "llc", "corp", "corporation", "company", "ltd", "llp", "lp", "pllc", "pc", "plc", "fsb",
        "bank", "bancorp", "insurance", "assurance", "hospital", "hospitals", "medical", "clinic", "clinics", "health",
        "healthcare", "center", "services", "service", "group", "associates", "partners", "department", "dept",
        "university", "college", "school", "academy", "district", "store", "stores", "shop", "dealer", "dealership",
        "motors", "automotive", "homes", "builders", "realty", "realtor", "realtors", "title", "escrow", "mortgage",
        "lending", "financial", "finance", "pharmacy", "labs", "laboratory", "laboratories",
        "office", "offices", "law", "firm", "foundation", "agency", "dental", "dentistry", "orthodontics", "dds", "dmd",
        "md", "cpa", "esq", "utility", "utilities", "electric", "energy", "telecom", "wireless", "communications",
        "holdings", "enterprises", "industries", "international", "solutions", "systems", "technologies", "apartments",
        "management", "properties", "association", "hoa", "church", "county", "government", "irs", "uscis", "dmv",
        "treasury", "administration", "authority", "commission", "council", "support", "warehouse",
    ]
    /// Words that say the lines under them are a business's part on the paper, not the person's.
    static let roleWords: Set<String> = [
        "seller", "sellers", "vendor", "merchant", "lender", "servicer", "provider", "facility", "payee", "employer",
        "issuer", "insurer", "carrier", "broker", "landlord", "lessor", "manufacturer", "supplier", "contractor",
        "physician", "practice", "attorney", "preparer", "agent", "branch", "headquarters", "hq", "remit",
    ]
    /// What a role's label may say besides the role: "Seller's Name and Address", "Sold By".
    static let labelFillers: Set<String> = ["name", "address", "s", "the", "of", "and", "information", "info",
                                            "details", "by", "to", "from", "ship", "shipped", "sold", "return",
                                            "union", "credit", "city", "state"]
    /// The same, of two words.
    static let rolePhrases = [" credit union ", " city of ", " state of ", " sold by ", " ship from ",
                                  " shipped from ", " return to ", " return address ", " ups store ",
                                  " post office "]

    /// Words a paper puts beside a person's name, address or phone: its label ("Patient Name",
    /// "Bill To", "Home Address", "Cell Phone"), a title, and the fields a form prints in between
    /// (a date of birth, an email). Nothing else may stand beside them.
    static let personalWords: Set<String> = [
        // Whose it is.
        "name", "names", "to", "bill", "billed", "ship", "shipped", "sold", "mail", "mailed", "deliver", "buyer",
        "buyers", "purchaser", "purchasers", "borrower", "borrowers", "coborrower", "patient", "member", "subscriber",
        "insured", "policyholder", "policy", "holder", "holders", "named", "primary", "secondary", "applicant",
        "applicants", "petitioner", "beneficiary", "employee", "taxpayer", "spouse", "student", "parent", "parents",
        "guardian", "owner", "owners", "registered", "account", "resident", "tenant", "tenants", "lessee", "guarantor",
        "responsible", "party", "recipient", "addressee", "driver", "operator", "emergency", "contact", "relationship",
        "wife", "husband", "mother", "father", "self", "you", "your", "and", "or", "of", "the", "for", "s", "c", "o",
        "care", "mr", "mrs", "ms", "miss", "dr", "jr", "sr", "ii", "iii", "first", "last", "middle", "given", "family",
        "surname", "full", "legal", "ln", "fn", "customer", "billing", "attn", "attention",
        // The household's own trust, which papers are mailed to.
        "trust", "living", "revocable", "trustee", "trustees",
        // The address's labels.
        "address", "addresses", "home", "mailing", "residential", "residence", "street", "current", "present",
        "permanent", "physical", "city", "state", "zip", "zipcode", "code", "postal", "apt", "unit", "new", "old",
        // Fields printed between.
        "date", "birth", "dob", "born", "sex", "gender", "age", "female", "male", "f", "m", "id", "number", "no", "nbr",
        "email", "e", "language", "english", "marital", "status", "married", "single",
    ]

    /// Words a phone's label may hold besides ``personalWords``: "Cell Phone:", "H:", "Tel.", "ext 4".
    static let phoneWords: Set<String> = [
        "phone", "phones", "tel", "telephone", "cell", "cellular", "mobile", "mob", "work", "day", "daytime",
        "evening", "night", "alternate", "alt", "other", "best", "preferred", "ph", "h", "w", "ext", "x", "numbers",
    ]

    static let monthWords: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april", "may", "jun", "june", "jul", "july",
        "aug", "august", "sep", "sept", "september", "oct", "october", "nov", "november", "dec", "december",
    ]

    /// "1st", "a1b": a word holding a digit, which says nothing of whose a line is.
    static func isOrdinalOrCode(_ word: String) -> Bool { word.contains(where: \.isNumber) }

    /// Words that make a street a business's: a suite or a floor, a mail stop, a mailbox rented
    /// at a store. A home is an apartment or a unit.
    static let businessStreetWords: Set<String> = ["suite", "ste", "floor", "fl", "flr", "bldg", "building", "dept",
                                                    "room", "rm", "ms", "mailstop", "pmb", "tower"]

    private static let email = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    static func withoutEmails(_ text: String) -> String {
        email.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: " ")
    }

    /// The home a paper is mailed to and the phones it prints for people in People, read once
    /// per file. With nobody in People, nothing is read: whose they are is the whole point.
    static func contacts(in pages: [[String]], people: [Person]) -> VaultPrintedContacts {
        guard !people.isEmpty else { return .init() }
        let registry = PersonRegistry(people: people)
        var out = VaultPrintedContacts()
        var seen = Set<String>()
        for page in pages {
            let lines = page.map { ContactLine($0, registry: registry) }
            if out.address == nil { out.address = homeAddress(on: lines) }
            for phone in phones(on: lines) where seen.insert(phone.person + phone.number).inserted {
                out.phones.append(phone)
            }
        }
        return out
    }

    // MARK: The home address

    /// The first home address on the page: a street and its city line, under the name of someone
    /// in People. The name is on the line above, or a few lines up with only a second name,
    /// "c/o" someone in People, a label or a form's personal fields between; or it is on the
    /// street's own line. A block whose name line or in-between lines name a business, that a
    /// label marks as a seller's, a provider's, a service or payment address, or whose street
    /// is a suite or a P.O. Box, is passed over: a home address is never guessed.
    static func homeAddress(on lines: [ContactLine]) -> VaultAddress? {
        for index in lines.indices {
            guard let (address, street, label) = addressBlock(endingAt: index, in: lines) else { continue }
            if isHome(address, street: street, label: label, in: lines) { return address }
        }
        return nil
    }

    /// The address whose city line is `index`'s, or that `index` holds whole on one line
    /// ("Address: 2841 Larkspur Ln, San Jose, CA 95132"), with the street's line and the words
    /// printed before its house number.
    private static func addressBlock(endingAt index: Int, in lines: [ContactLine])
        -> (address: VaultAddress, street: Int, label: String)? {
        let text = lines[index].text
        let (label, rest) = labelSplit(text)
        if let whole = oneLineAddress(rest) { return (whole, index, label) }
        guard let city = cityLine(text), index >= 1 else { return nil }
        var at = index - 1
        var unit = unitLine(lines[at].text)
        if unit != nil { at -= 1 }
        guard at >= 0 else { return nil }
        let (streetLabel, streetText) = labelSplit(lines[at].text)
        guard let street = streetLine(streetText) else { return nil }
        unit = unit ?? street.unit
        return (VaultAddress(street: street.street, unit: unit, city: city.city, state: city.state, zip: city.zip),
                at, streetLabel)
    }

    /// The words before a line's first digit, and the rest from there: "Home Address: 2841 …" is
    /// ("Home Address:", "2841 …").
    static func labelSplit(_ line: String) -> (label: String, rest: String) {
        guard let digit = line.firstIndex(where: \.isNumber) else { return (line, "") }
        return (String(line[..<digit]), String(line[digit...]))
    }

    /// "2841 Larkspur Ln, Apt 6, San Jose, CA 95132": a street, perhaps a unit, a city, a state
    /// and a ZIP, parted by commas.
    static func oneLineAddress(_ text: String) -> VaultAddress? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let city: (city: String, state: String, zip: String)
        var streetParts: ArraySlice<String>
        if let c = cityLine(parts[parts.count - 1]) {
            city = c
            streetParts = parts.dropLast()
        } else if parts.count >= 3, let c = cityLine(parts[parts.count - 2] + " " + parts[parts.count - 1]) {
            city = c
            streetParts = parts.dropLast(2)
        } else {
            return nil
        }
        guard (1...2).contains(streetParts.count), let street = streetLine(streetParts.removeFirst()) else { return nil }
        var unit = street.unit
        if let more = streetParts.first {
            guard let u = unitLine(more) else { return nil }
            unit = u
        }
        return VaultAddress(street: street.street, unit: unit, city: city.city, state: city.state, zip: city.zip)
    }

    /// Whether the block found is a named person's home: see ``homeAddress(on:)``.
    private static func isHome(_ address: VaultAddress, street: Int, label: String, in lines: [ContactLine]) -> Bool {
        let streetWords = Set(PersonRegistry.words(address.street + " " + (address.unit ?? "")))
        guard streetWords.isDisjoint(with: businessStreetWords), !isPostBox(address.street) else { return false }
        // The name, on the street's line before its number, or above it.
        var anchor: Int?
        let before = ContactLine(label, registry: PersonRegistry(people: []))
        if !label.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).isEmpty {
            let named = lines[street]
            guard !before.words.contains(where: { !named.nameWords.contains($0) && !personalWords.contains($0) }) else {
                return false
            }
            if !named.people.isEmpty, !named.isBusiness { anchor = street }
        }
        if anchor == nil { anchor = nameAbove(street, in: lines) }
        guard let anchor else { return false }
        return !markedNotHome(anchor, in: lines)
    }

    /// The line naming someone in People at most four lines above `index`, with only a second
    /// name, "c/o" someone, a label or a personal field between. Nil when a line of any other
    /// kind comes first: a business's name, a heading, an account number.
    /// With `throughAddress`, the person's own street and city lines may stand between too, and
    /// the name may be five lines up: a phone printed under the address.
    private static func nameAbove(_ index: Int, in lines: [ContactLine], throughAddress: Bool = false) -> Int? {
        var at = index - 1
        while at >= 0, index - at <= (throughAddress ? 5 : 4) {
            let line = lines[at]
            if throughAddress, line.people.isEmpty, isAddressLine(line.text) {
                at -= 1
                continue
            }
            guard !line.isBusiness else { return nil }
            // The name nearest the street is whose it is; a second name above it ("and …") may be
            // there too. A name line may hold a word People does not know (a middle or a maiden
            // name); any other line only a label's or a personal field's words.
            if !line.people.isEmpty { return at }
            guard line.onlyNames(and: personalWords.union(phoneWords)) else { return nil }
            at -= 1
        }
        return nil
    }

    /// A street, a unit, a city line or a whole address, perhaps after a label of a person's.
    private static func isAddressLine(_ text: String) -> Bool {
        if cityLine(text) != nil || unitLine(text) != nil { return true }
        let (label, rest) = labelSplit(text)
        guard streetLine(rest) != nil || oneLineAddress(rest) != nil else { return false }
        let words = PersonRegistry.words(label)
        return words.allSatisfy(personalWords.contains)
            && Set(PersonRegistry.words(rest)).isDisjoint(with: businessStreetWords)
    }

    /// Words above a name that make its block someone else's address, or not the home: where a
    /// bill's service is, or where payments go.
    private static let notHomeCues = ["service address", "service location", "service for", "property address",
                                      "premises", "remit", "payment address", "pay to", "payable to",
                                      "send payment", "mail payment", "make checks"]

    /// Whether the name's line or the two above it say the block is not a home: a service or
    /// payment address, or a business's. The name's own line may name neither a company nor a
    /// business's part ("Seller: …", "Anna Eriksson DDS"); the line above may not name a part.
    /// A company's name alone above it is the letterhead, and says nothing of the block.
    private static func markedNotHome(_ anchor: Int, in lines: [ContactLine]) -> Bool {
        let above = lines[max(0, anchor - 2)...anchor].map(\.text).joined(separator: " ").lowercased()
        if notHomeCues.contains(where: above.contains) { return true }
        if lines[anchor].isBusiness { return true }
        guard anchor > 0 else { return false }
        // Mailed in care of someone not in People: their address, not the home.
        let over = lines[anchor - 1]
        if over.people.isEmpty, over.joinedWords.contains(" c o ") || over.joinedWords.contains(" care of ") { return true }
        return over.isRoleLabel
    }

    // MARK: Phones

    /// "(408) 555-0142", "408-555-0142", "408.555.0142", "+1 408 555 0142": ten digits in their
    /// three groups, never a run of digits alone (an account number).
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?:\+?1[ .-]?)?(?:\(([2-9][0-9]{2})\) ?|([2-9][0-9]{2})[ .-])([2-9][0-9]{2})[ .-]([0-9]{4})(?![0-9])"#)

    /// Area codes no household's own phone has: toll-free and pay-per-call numbers are a
    /// business's.
    static let businessAreaCodes: Set<String> = ["800", "833", "844", "855", "866", "877", "888", "900"]

    /// The phones a page prints for people in People, each with whose: a number whose line holds
    /// nothing but a phone's label ("Cell:", "Home Phone") and perhaps the name, on the name's
    /// line or at most four lines under it with only that person's address, labels and personal
    /// fields between. A number beside any other word ("Customer Service", "Call us", "Fax",
    /// "Questions?"), a toll-free number, or one under a business's name is never read.
    static func phones(on lines: [ContactLine]) -> [VaultPrintedPhone] {
        var out: [VaultPrintedPhone] = []
        for (index, line) in lines.enumerated() {
            let ns = line.text as NSString
            let matches = phonePattern.matches(in: line.text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // The words once the numbers are gone: a label, a name, or something that makes it not theirs.
            var rest = line.text
            for m in matches.reversed() { rest = (rest as NSString).replacingCharacters(in: m.range, with: " ") }
            let labelLine = ContactLine(rest, registry: PersonRegistry(people: []))
            let labelWords = labelLine.words.filter { !line.nameWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            guard labelWords.allSatisfy({ personalWords.contains($0) || phoneWords.contains($0) }),
                  !line.isBusiness else { continue }
            let owner: String?
            if !line.people.isEmpty {
                guard !markedNotHome(index, in: lines) else { continue }
                owner = line.person
            } else if let above = nameAbove(index, in: lines, throughAddress: true), !markedNotHome(above, in: lines) {
                owner = lines[above].person
            } else {
                owner = nil
            }
            guard let owner else { continue }
            // One label for every number on the line: "Home / Cell" says nothing of which is which.
            let label = matches.count == 1 ? phoneLabel(labelWords) : nil
            for m in matches {
                let area = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range(at: 2))
                let number = area + ns.substring(with: m.range(at: 3)) + ns.substring(with: m.range(at: 4))
                // A middle 9 is no area code: a misread, or another number.
                guard !businessAreaCodes.contains(area), area.dropFirst().first != "9" else { continue }
                out.append(VaultPrintedPhone(number: number, label: label, person: owner))
            }
        }
        return out
    }

    /// "Mobile", "Home" or "Work", as a phone's label words say it.
    static func phoneLabel(_ words: [String]) -> String? {
        let set = Set(words)
        if !set.isDisjoint(with: ["cell", "cellular", "mobile", "mob", "c", "m"]) { return "Mobile" }
        if !set.isDisjoint(with: ["work", "w"]) { return "Work" }
        if !set.isDisjoint(with: ["home", "h", "evening", "night"]) { return "Home" }
        return nil
    }
}
