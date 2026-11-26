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

/// Home addresses and phones, read only where a paper prints them as a named person's: under the
/// name of someone in People, with nothing between that makes them a company's. A business's own
/// address and phone (the letterhead, Customer Service or Care, where to send a payment, the
/// seller, the provider) are not read, however near the name they are printed.
extension VaultReading {

    /// Who in People a line names, and by which words: someone is named by two words of their
    /// names or more ("Anna Eriksson", "ANNA M ERIKSSON"), so a stranger sharing one ("Dr. Anna
    /// Lee", "Berq Plumbing") is not taken for them. One word names them only in a field of a
    /// name and nothing else ("FN ANNA", "LN ERIKSSON", "First Name: Anna"), as a license's
    /// front prints its names a line each.
    struct NameIndex {
        let people: [(id: String, words: Set<String>)]
        /// Every word of everyone's names.
        let allWords: Set<String>

        init(_ people: [Person]) {
            self.people = people.map { person in
                (person.id, Set(person.nameForms.flatMap(PersonRegistry.words).filter { $0.count >= 2 }))
            }
            allWords = self.people.reduce(into: Set<String>()) { $0.formUnion($1.words) }
        }

        /// Everyone the words name, and the words that named them.
        func named(in words: [String]) -> (people: Set<String>, words: Set<String>) {
            let present = Set(words)
            var ids = Set<String>()
            var spent = Set<String>()
            var partly: [(String, Set<String>)] = []
            for (id, theirs) in people where !theirs.isEmpty {
                let hit = theirs.intersection(present)
                if hit.count >= min(2, theirs.count) {
                    ids.insert(id)
                    spent.formUnion(hit)
                } else if !hit.isEmpty {
                    partly.append((id, hit))
                }
            }
            guard ids.isEmpty, !partly.isEmpty else { return (ids, spent) }
            // A name's field: its label, the name's words, and nothing else.
            let theirWords = partly.reduce(into: Set<String>()) { $0.formUnion($1.1) }
            let rest = words.filter { !theirWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            guard rest.contains(where: VaultReading.nameFieldWords.contains),
                  rest.allSatisfy({ VaultReading.nameFieldWords.contains($0) || VaultReading.roleLabelWords.contains($0) })
            else { return (ids, spent) }
            return (Set(partly.map(\.0)), theirWords)
        }
    }

    /// The words of a name's field: "FN", "Last Name", "Surname".
    static let nameFieldWords: Set<String> = ["name", "names", "fn", "ln", "first", "last", "middle", "given",
                                              "surname", "full", "legal"]

    /// A page's line, as the contact reader weighs it: its words, and who in People it names.
    struct ContactLine {
        let text: String
        /// Lower case, letters and digits only, an email address left out.
        let words: [String]
        /// The words People's names spent.
        let nameWords: Set<String>
        /// Everyone in People it names (``NameIndex``).
        let people: Set<String>

        init(_ text: String, names: NameIndex) {
            self.text = text
            words = VaultReading.contactWords(text)
            (people, nameWords) = names.named(in: words)
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

        /// "c/o" or "care of", and whether what follows it names someone in People: mail sent in
        /// care of anyone else goes to their address.
        func careOf(names: NameIndex) -> (marked: Bool, toPeople: Bool) {
            let joined = joinedWords
            guard let marker = [" c o ", " care of "].compactMap({ joined.range(of: $0) }).first else { return (false, false) }
            let after = joined[marker.upperBound...].split(separator: " ").map(String.init)
            return (true, !names.named(in: after).people.isEmpty)
        }

        var joinedWords: String { " " + words.joined(separator: " ") + " " }
    }

    /// A line's words, lower case, an email left out, and a form's record-number label made one
    /// word ("Medical Record Number" is a field, not a hospital's name).
    static func contactWords(_ text: String) -> [String] {
        var words = PersonRegistry.words(withoutEmails(text))
        for (index, word) in words.enumerated().reversed()
        where (word == "medical" || word == "health") && words.indices.contains(index + 1) && words[index + 1] == "record" {
            words.remove(at: index)
        }
        return words
    }

    /// Words a business calls itself by, or ends its name with. A line holding one, beside a
    /// name or between it and the street, makes the block a company's.
    static let companyWords: Set<String> = [
        "inc", "incorporated", "llc", "corp", "corporation", "company", "ltd", "llp", "lp", "pllc", "pc", "plc", "fsb",
        "bank", "bancorp", "insurance", "assurance", "hospital", "hospitals", "medical", "clinic", "clinics", "health",
        "healthcare", "center", "services", "service", "group", "associates", "partners", "department", "dept",
        "university", "college", "school", "academy", "district", "store", "stores", "shop", "dealer", "dealership",
        "motors", "automotive", "homes", "builders", "realty", "realtor", "realtors", "escrow", "mortgage",
        "lending", "financial", "finance", "pharmacy", "labs", "laboratory", "laboratories",
        "office", "offices", "law", "firm", "foundation", "agency", "dental", "dentistry", "orthodontics", "dds", "dmd",
        "md", "cpa", "esq", "utility", "utilities", "electric", "energy", "telecom", "wireless", "communications",
        "holdings", "enterprises", "industries", "international", "solutions", "systems", "technologies", "apartments",
        "management", "properties", "association", "hoa", "church", "government", "irs", "uscis", "dmv",
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
                              " shipped from ", " return to ", " return address ", " ups store ", " post office "]

    /// Words a paper puts beside a person's name: whose the block is ("Patient Name", "Bill To",
    /// "Named Insured"), a title, a suffix.
    static let roleLabelWords: Set<String> = [
        "name", "names", "to", "bill", "billed", "ship", "shipped", "sold", "mail", "mailed", "deliver", "buyer",
        "buyers", "purchaser", "purchasers", "borrower", "borrowers", "coborrower", "patient", "member", "subscriber",
        "insured", "policyholder", "policy", "holder", "holders", "named", "primary", "secondary", "applicant",
        "applicants", "petitioner", "beneficiary", "employee", "taxpayer", "spouse", "student", "parent", "parents",
        "guardian", "owner", "owners", "registered", "account", "resident", "tenant", "tenants", "lessee", "guarantor",
        "responsible", "party", "recipient", "addressee", "driver", "operator", "emergency", "contact", "relationship",
        "wife", "husband", "mother", "father", "self", "you", "your", "and", "or", "of", "the", "for", "s",
        "mr", "mrs", "ms", "miss", "dr", "jr", "sr", "ii", "iii", "first", "last", "middle", "given", "family",
        "surname", "full", "legal", "ln", "fn", "customer", "attn", "attention", "information", "info",
        // The household's own trust, which papers are mailed to.
        "trust", "living", "revocable", "trustee", "trustees",
    ]

    /// An address's label: "Home Address", "Current Residential Address", "Mailing Address".
    /// Never "Old" or "Previous": that is not where they live.
    static let addressLabelWords: Set<String> = [
        "address", "addresses", "home", "mailing", "residential", "residence", "street", "current", "present",
        "permanent", "physical", "city", "state", "zip", "zipcode", "code", "postal", "apt", "unit", "new", "mail", "billing",
        "to", "of", "the", "your", "s",
    ]

    /// A form's fields printed between a name and its address or phone: a date of birth, an ID
    /// number, an email.
    static let fieldWords: Set<String> = [
        "date", "birth", "dob", "born", "sex", "gender", "age", "female", "male", "f", "m", "id", "number", "no", "nbr",
        "email", "e", "language", "english", "marital", "status", "married", "single", "of", "record", "mrn",
        "member", "account", "policy", "patient", "student", "customer", "subscriber",
    ]

    /// A phone's label: "Cell Phone:", "H:", "Tel.", "Home", "Contact Number", "ext 4".
    static let phoneLabelWords: Set<String> = [
        "phone", "phones", "tel", "telephone", "cell", "cellular", "mobile", "mob", "ph", "home", "work", "day",
        "daytime", "evening", "night", "primary", "alternate", "alt", "other", "best", "preferred", "h", "c", "w", "m",
        "ext", "x", "number", "numbers", "no", "contact",
    ]
    /// The words that make a label a phone's whatever else it says.
    static let phoneCoreWords: Set<String> = ["phone", "phones", "tel", "telephone", "cell", "cellular", "mobile", "mob", "ph"]

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
    /// `origins`, as ``VaultReading/read(pages:from:under:people:origins:)`` takes them: a page read
    /// both ways is its text layer first, as for its numbers (VT88). Its picture gives a home only
    /// if no page before did, and phones only if its layer gave none: a misread digit is never a
    /// second phone beside the layer's (the second review).
    static func contacts(in pages: [[String]], people: [Person], origins: [VaultPageOrigin]? = nil) -> VaultPrintedContacts {
        guard !people.isEmpty else { return .init() }
        let names = NameIndex(people)
        var out = VaultPrintedContacts()
        var seen = Set<String>()
        let origins = origins.flatMap { $0.count == pages.count ? $0 : nil }
        // Each page's layer before its picture, the pages in the file's order.
        let order = pages.indices.sorted { a, b in
            guard let origins else { return a < b }
            let (pa, pb) = (origins[a].page, origins[b].page)
            if pa != pb { return pa < pb }
            let (ia, ib) = (origins[a].half == .picture, origins[b].half == .picture)
            return ia != ib ? !ia : a < b
        }
        var layerPhones: Set<Int> = []
        for index in order {
            let lines = pages[index].map { ContactLine($0, names: names) }
            if out.address == nil { out.address = homeAddress(on: lines, names: names) }
            let origin = origins?[index]
            if let origin, origin.half == .picture, layerPhones.contains(origin.page) { continue }
            for phone in phones(on: lines, names: names) where seen.insert(phone.person + phone.number).inserted {
                out.phones.append(phone)
                if let origin, origin.half == .textLayer { layerPhones.insert(origin.page) }
            }
        }
        return out
    }

    // MARK: The home address

    /// The first home address on the page: a street and its city line, under the name of someone
    /// in People. The name is on the line above, or a few lines up with only a second name,
    /// "c/o" someone in People, an address's label or a form's fields between; or it is on the
    /// street's own line. A block whose name line or in-between lines name a business, that a
    /// label marks as a seller's, a provider's, a service, payment or old address, that is
    /// mailed in care of anyone not in People, or whose street is a suite or a P.O. Box, is
    /// passed over: a home address is never guessed.
    static func homeAddress(on lines: [ContactLine], names: NameIndex) -> VaultAddress? {
        for index in lines.indices {
            guard let (address, street, label) = addressBlock(endingAt: index, in: lines) else { continue }
            if isHome(address, street: street, label: label, in: lines, names: names) { return address }
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

    /// What may stand between a name and its address: a second name, or a word of one wrapped to
    /// its own line; the household's trust; an address's label; a form's fields; a phone.
    private static let betweenNameAndAddress = addressLabelWords.union(fieldWords).union(phoneLabelWords)
        .union(["and", "or", "trust", "living", "revocable", "trustee", "trustees", "family"])
    /// What may stand between a name and its phone: their address (``isAddressLine(_:)``), a
    /// form's fields, another phone.
    private static let betweenNameAndPhone = fieldWords.union(phoneLabelWords)

    /// Whether the block found is a named person's home: see ``homeAddress(on:names:)``.
    private static func isHome(_ address: VaultAddress, street: Int, label: String, in lines: [ContactLine],
                               names: NameIndex) -> Bool {
        let streetWords = Set(PersonRegistry.words(address.street + " " + (address.unit ?? "")))
        guard streetWords.isDisjoint(with: businessStreetWords), !isPostBox(address.street) else { return false }
        // The name, on the street's line before its number, or above it. The label alone is
        // weighed, not the city after it ("…, Bethesda, MD").
        if !label.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)).isEmpty {
            let before = ContactLine(label, names: names)
            guard !before.isBusiness, before.onlyNames(and: roleLabelWords.union(addressLabelWords)) else { return false }
            if !before.people.isEmpty { return !markedNotHome(street, in: lines, names: names, named: before) }
        }
        guard let anchor = nameAbove(street, in: lines, names: names, between: betweenNameAndAddress, throughPast: true) else { return false }
        // A label between them that names the address another place's ("Work Address:", on a line
        // of its own): not their home, as the same label beside the street is not (the second
        // review). A work phone between them still is: only an address's label says so.
        if lines[(anchor + 1)..<street].contains(where: { isOtherPlacesAddressLabel($0.text) }) { return false }
        return !markedNotHome(anchor, in: lines, names: names)
    }

    /// The words that make an address's label another place's: "Work Address", "Office Address".
    static let otherPlaceWords: Set<String> = ["work", "office", "business", "employer", "company", "school"]

    /// Whether `text` is an address's label naming another place than home: "Work Address:".
    static func isOtherPlacesAddressLabel(_ text: String) -> Bool {
        let words = Set(PersonRegistry.words(text))
        return !words.isDisjoint(with: ["address", "addresses"]) && !words.isDisjoint(with: otherPlaceWords)
    }

    /// The line naming someone in People at most four lines above `index`, with only lines of
    /// `between`'s words, or naming someone else in People, between. Nil when a line of any
    /// other kind comes first: a business's name, a heading, "Customer Care". With
    /// `throughAddress`, the person's own street and city lines may stand between too, and the
    /// name may be five lines up: a phone printed under the address.
    /// With `throughPast`, an address a label marks as old ("Old Address: …", its city line
    /// under it) may stand between: a form's new address under it is still theirs.
    private static func nameAbove(_ index: Int, in lines: [ContactLine], names: NameIndex, between: Set<String>,
                                  throughAddress: Bool = false, throughPast: Bool = false) -> Int? {
        var at = index - 1
        while at >= 0, index - at <= (throughAddress || throughPast ? 5 : 4) {
            let line = lines[at]
            if throughAddress, line.people.isEmpty, isAddressLine(line.text) {
                at -= 1
                continue
            }
            if throughPast, line.people.isEmpty {
                if isPastAddressLine(line.text) {
                    at -= 1
                    continue
                }
                if at > 0, cityLine(line.text) != nil || unitLine(line.text) != nil, isPastAddressLine(lines[at - 1].text) {
                    at -= 2
                    continue
                }
            }
            guard !line.isBusiness else { return nil }
            // The name nearest the street is whose it is; a second name above it ("and …") may be
            // there too. A line naming someone may hold a word People does not know (a middle or
            // a maiden name); any other line only `between`'s.
            if !line.people.isEmpty { return at }
            guard line.onlyNames(and: between.union(names.allWords)) else { return nil }
            at -= 1
        }
        return nil
    }

    /// Words that mark an address as one they have left.
    static let pastWords: Set<String> = ["old", "previous", "former", "prior", "past"]

    /// "Old Address: 12 Elm St", "Previous Address: 12 Elm St, Oakland, CA 94607".
    private static func isPastAddressLine(_ text: String) -> Bool {
        let (label, rest) = labelSplit(text)
        let words = PersonRegistry.words(label)
        return !Set(words).isDisjoint(with: pastWords) && words.allSatisfy { addressLabelWords.contains($0) || pastWords.contains($0) }
            && (streetLine(rest) != nil || oneLineAddress(rest) != nil)
    }

    /// A street, a unit, a city line or a whole address, perhaps after an address's label.
    private static func isAddressLine(_ text: String) -> Bool {
        if cityLine(text) != nil || unitLine(text) != nil { return true }
        let (label, rest) = labelSplit(text)
        guard streetLine(rest) != nil || oneLineAddress(rest) != nil else { return false }
        return PersonRegistry.words(label).allSatisfy(addressLabelWords.contains)
            && Set(PersonRegistry.words(rest)).isDisjoint(with: businessStreetWords)
    }

    /// Words above a name that make its block someone else's address, or not the home: where a
    /// bill's service is, or where payments go.
    private static let notHomeCues = ["service address", "service location", "service for", "property address",
                                      "premises", "remit", "payment address", "pay to", "payable to",
                                      "send payment", "mail payment", "make checks"]

    /// Whether the name's line or the two above it say the block is not a home: a service or
    /// payment address, or a business's. The name's own line may name neither a company nor a
    /// business's part ("Seller: …", "Anna Eriksson DDS"), nor send it in care of anyone not in
    /// People; the line above may neither name a part nor send it in care of anyone not in
    /// People. A company's name alone above it is the letterhead, and says nothing of the block.
    /// `named` is the name's line when only part of `anchor`'s is (the words before a street on
    /// the same line, not the city after it).
    private static func markedNotHome(_ anchor: Int, in lines: [ContactLine], names: NameIndex,
                                      named: ContactLine? = nil) -> Bool {
        let named = named ?? lines[anchor]
        let above = (lines[max(0, anchor - 2)..<anchor].map(\.text) + [named.text]).joined(separator: " ").lowercased()
        if notHomeCues.contains(where: above.contains) { return true }
        if named.isBusiness { return true }
        let own = named.careOf(names: names)
        if own.marked, !own.toPeople { return true }
        guard anchor > 0 else { return false }
        let over = lines[anchor - 1]
        if over.people.isEmpty, over.careOf(names: names).marked { return true }
        return over.isRoleLabel
    }

    // MARK: Phones

    /// "(408) 555-0142", "408-555-0142", "408.555.0142", "+1 408 555 0142": ten digits in their
    /// three groups, never a run of digits alone (an account number), nor three groups cut from
    /// a longer run ("1234 567 890 1234").
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])(?<![0-9][ .-])(?:\+?1[ .-]?)?(?:\(([2-9][0-9]{2})\) ?|([2-9][0-9]{2})[ .-])([2-9][0-9]{2})[ .-]([0-9]{4})(?![0-9])(?![ .-][0-9])"#)

    /// Area codes no household's own phone has: toll-free and pay-per-call numbers are a
    /// business's.
    static let businessAreaCodes: Set<String> = ["800", "833", "844", "855", "866", "877", "888", "900"]

    /// "x12", "ext 4": an extension, which says nothing of whose the phone is.
    private static func isExtension(_ word: String) -> Bool {
        word.first == "x" && word.dropFirst().allSatisfy(\.isNumber) && word.count > 1
            || word.hasPrefix("ext") && word.dropFirst(3).allSatisfy(\.isNumber)
    }

    /// Whether `words` (a line's, its numbers and People names taken out) are a phone's label and
    /// nothing else: empty; or a phone's words ("Cell Phone", "Tel."); or "Contact Number"; or
    /// only which phone it is ("Home", "Work", "H:", "Evening").
    static func isPhoneLabel(_ words: [String]) -> Bool {
        let set = Set(words.filter { !isExtension($0) })
        guard set.isSubset(of: phoneLabelWords) else { return false }
        if set.isEmpty || !set.isDisjoint(with: phoneCoreWords) { return true }
        if set.contains("contact") { return !set.isDisjoint(with: ["number", "no"]) }
        return set.isDisjoint(with: ["number", "numbers", "no"])
    }

    /// The phones a page prints for people in People, each with whose: a number whose line holds
    /// nothing but a phone's label ("Cell:", "Home Phone") and perhaps the name, on the name's
    /// line or at most five lines under it with only that person's address, a form's fields and
    /// other phones between. A number on its own line takes its label from the line above, which
    /// must be the name, the address, or a phone's label. A number beside any other word
    /// ("Customer Care", "Billing", "Call us", "Fax", "Account Number"), a toll-free number, one
    /// under a business's name, or one under two people's names is not read.
    static func phones(on lines: [ContactLine], names: NameIndex) -> [VaultPrintedPhone] {
        var out: [VaultPrintedPhone] = []
        for (index, line) in lines.enumerated() {
            let ns = line.text as NSString
            let matches = phonePattern.matches(in: line.text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // The words once the numbers are gone: a label, a name, or something that makes it not theirs.
            var rest = line.text
            for m in matches.reversed() { rest = (rest as NSString).replacingCharacters(in: m.range, with: " ") }
            var labelWords = contactWords(rest).filter { !line.nameWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            guard isPhoneLabel(labelWords), !line.isBusiness else { continue }
            if labelWords.isEmpty, line.people.isEmpty, index > 0 {
                // On its own line: what the line above says it is.
                let over = lines[index - 1]
                if over.people.isEmpty, !isAddressLine(over.text) {
                    guard !over.text.contains(where: \.isNumber), isPhoneLabel(over.otherWords), !over.otherWords.isEmpty
                    else { continue }
                    labelWords = over.otherWords
                }
            }
            let anchor: Int
            if !line.people.isEmpty {
                anchor = index
            } else if let above = nameAbove(index, in: lines, names: names, between: betweenNameAndPhone, throughAddress: true) {
                anchor = above
            } else {
                continue
            }
            guard !markedNotHome(anchor, in: lines, names: names), let owner = lines[anchor].person else { continue }
            // Two people's names over one address ("ANNA ERIKSSON" over "BOB ERIKSSON"): whose phone
            // it is cannot be told. A labeled name ("Parent/Guardian: Bob Eriksson") says whose.
            if anchor > 0, Self.isBareName(lines[anchor]), Self.isBareName(lines[anchor - 1]),
               !lines[anchor - 1].people.subtracting([owner]).isEmpty { continue }
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

    /// A line naming someone in People and nothing else but "and" or "or": an addressee.
    private static func isBareName(_ line: ContactLine) -> Bool {
        !line.people.isEmpty && line.otherWords.allSatisfy { $0 == "and" || $0 == "or" }
    }

    /// "Mobile", "Home" or "Work", as a phone's label words say it. A letter alone ("C:", "H:")
    /// counts only as the whole label: "Sex: M" beside a phone is no mobile.
    static func phoneLabel(_ words: [String]) -> String? {
        let set = Set(words.filter { !isExtension($0) })
        let letter = set.count == 1 ? set.first : nil
        if !set.isDisjoint(with: ["cell", "cellular", "mobile", "mob"]) || letter == "c" || letter == "m" { return "Mobile" }
        if set.contains("work") || letter == "w" { return "Work" }
        if !set.isDisjoint(with: ["home", "evening", "night"]) || letter == "h" { return "Home" }
        return nil
    }
}
