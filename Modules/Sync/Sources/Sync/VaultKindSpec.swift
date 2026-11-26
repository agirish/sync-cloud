import Foundation

/// What the Vault knows about one kind of ID, in one row (VT2): what it is called, how its
/// number is printed and hidden, where its papers are filed, the group it starts in, whose it is
/// when no name was read, where it is used, and how a newer one replaces it. ``VaultCategory`` is
/// a kind's stored id, and a new kind is a case there, a row here and a reader; ``of(_:)``'s
/// switch makes a case with no row a compile error.
/// Left in code: the readers' own kinds, and the rules that join two kinds (a visa in an older
/// passport, an ITIN given way to an SSN, a license's address).
public struct VaultKindSpec: Sendable {
    public let category: VaultCategory
    /// The card's title: "Passports".
    public let title: String
    /// What one number of the kind is called, in the editor's picker and a row's title.
    public let singular: String
    public let symbol: String
    /// What its paper is called in People's "On …"; nil for an account's papers.
    public let paper: String?
    /// Whether even its ending is a secret while it is hidden: the last four of a Social Security
    /// number are what a bank asks to check who is calling, and an Aadhaar number's are what its
    /// masked form prints. Its row then shows no ending until the number may be shown.
    public let hidesEnding: Bool
    /// The groups its number is printed in, where the kind has its own (a Social Security number
    /// 3-2-4, a PAN 5-4-1); nil for fours (``VaultMask/printed(_:as:)``).
    public let printed: [Int]?
    /// The folders it is filed in when it is the original (``VaultSource/placement(for:)``).
    public let homes: [String]
    /// The group the Kinds choice starts it in (``VaultGroups/default``).
    public let group: VaultGroups.ID
    /// An account: read by the account reader, and the only kind an ID can be moved to or from
    /// (``VaultKinds/changeable``). What a reader checks the number of stays where it was read.
    public let isAccount: Bool
    /// Read with no name and given to nobody, it is the household's: a utility's or a loan's
    /// account is the home's, a member ID is someone's not yet known.
    public let isHouseholdsWhenNameless: Bool
    /// The word before the date it is good to, in its row's line ("Admitted until"); nil for
    /// "Valid to", or "Expired" once it has run out.
    let goodUntil: String?
    /// The word before the date a replaced one ran out: "Expired" for a document carried, "Ran
    /// out" for the rest.
    let endedWord: String
    /// What its number is called in Large Type, from its document's facts and the row's title.
    let idLabel: @Sendable (_ facts: VaultReadFacts?, _ title: String) -> String
    /// What tells one apart from others of its kind in a row's title, beside whose it is (nil
    /// when no name was read): a passport's country, a visa's class.
    let which: @Sendable (_ facts: VaultReadFacts?, _ title: String, _ whose: String?) -> String?
    /// Where it is used, as its document says, and how that is known (``VaultGeo/read(_:facts:)``).
    let place: @Sendable (_ facts: VaultReadFacts?) -> (geo: VaultGeo, reason: String)
    /// What it is weighed against, besides the same person (``VaultStandings``): a kind and its
    /// part of the key. Nil weighs it as an account, against the same card's from the same issuer.
    let weighing: (@Sendable (_ facts: VaultReadFacts, _ value: String) -> (kind: String, by: String))?
    /// The newest of its group, outside an Archive folder: Current, marked expired once it has
    /// run out, unless its rule sends it to Archive with a reason.
    let newest: @Sendable (_ facts: VaultReadFacts, _ ranOut: Bool) -> Newest

    enum Newest: Equatable {
        case current(expired: Bool)
        case archive(String)
    }

    /// The kind's row: a case with none does not compile.
    public static func of(_ category: VaultCategory) -> VaultKindSpec {
        switch category {
        case .passport: return .passport
        case .usVisa: return .usVisa
        case .i94: return .i94
        case .uscisCase: return .uscisCase
        case .driversLicense: return .driversLicense
        case .ssn: return .ssn
        case .pan: return .pan
        case .aadhaar: return .aadhaar
        case .voterID: return .voterID
        case .health: return .health
        case .utilities: return .utilities
        case .loans: return .loans
        case .other: return .other
        }
    }

    /// A card the household made, as its title and symbol are drawn: Other's row with the kind's
    /// own name and a tag. One no longer kept is titled Other. Its group is the kind's own
    /// (``VaultKinds/group(of:in:)``), and an ID on it keeps the rules of the kind it was read as.
    static func custom(_ kind: VaultCustomKind?) -> VaultKindSpec {
        let other = of(.other)
        return other.with(title: kind?.name ?? other.title, symbol: "tag")
    }

    private func with(title: String, symbol: String) -> VaultKindSpec {
        VaultKindSpec(category: category, title: title, singular: singular, symbol: symbol, paper: paper,
                      hidesEnding: hidesEnding, printed: printed, homes: homes, group: group, isAccount: isAccount,
                      isHouseholdsWhenNameless: isHouseholdsWhenNameless, goodUntil: goodUntil,
                      endedWord: endedWord, idLabel: idLabel, which: which, place: place, weighing: weighing,
                      newest: newest)
    }

    // MARK: The rules several kinds share

    /// An account read from a paper is told apart by who issued it and what the number is:
    /// "EBMUD · Account number", which is its title.
    static let accountWhich: @Sendable (VaultReadFacts?, String, String?) -> String? = { facts, title, _ in
        facts == nil ? nil : title
    }
    static let noWhich: @Sendable (VaultReadFacts?, String, String?) -> String? = { _, _, _ in nil }
    static let markedExpired: @Sendable (VaultReadFacts, Bool) -> Newest = { _, ranOut in .current(expired: ranOut) }
    /// Where a kind with no country of its own is used: anywhere until one is chosen.
    static let noCountry: @Sendable (VaultReadFacts?) -> (geo: VaultGeo, reason: String) = { facts in
        (.anywhere, facts == nil ? "Typed in; no country chosen yet" : "Its country was not read")
    }
    static func fixed(_ label: String) -> @Sendable (VaultReadFacts?, String) -> String { { _, _ in label } }
    static func fixedPlace(_ geo: VaultGeo, _ reason: String) -> @Sendable (VaultReadFacts?) -> (geo: VaultGeo, reason: String) {
        { _ in (geo, reason) }
    }

    // MARK: The app's kinds, in the order the main view draws their cards

    /// In the order the kinds are declared (``VaultCategory``), which the main view draws in.
    public static let all: [VaultKindSpec] = VaultCategory.allCases.map(of)

    static let passport = VaultKindSpec(
        category: .passport, title: "Passports", singular: "Passport", symbol: "globe", paper: "passport",
        hidesEnding: false, printed: nil, homes: ["passport", "passports"], group: "travel", isAccount: false, isHouseholdsWhenNameless: false,
        goodUntil: nil, endedWord: "Expired ", idLabel: fixed("Passport number"),
        which: { facts, _, _ in facts?.issuer },
        place: fixedPlace(.anywhere, "A passport is carried in every country"),
        // A dual citizen keeps both passports: they are weighed by issuing country.
        weighing: { facts, _ in ("passport", facts.issuer ?? "") },
        newest: markedExpired)

    static let usVisa = VaultKindSpec(
        category: .usVisa, title: "Visas", singular: "Visa", symbol: "airplane", paper: "visa",
        hidesEnding: false, printed: nil, homes: ["visa", "visas"], group: "travel", isAccount: false, isHouseholdsWhenNameless: false,
        goodUntil: nil, endedWord: "Expired ",
        idLabel: { facts, _ in
            switch facts?.form {
            case "OCI"?: return "OCI number"
            case "e-Visa"?: return "Application number"
            case nil where facts == nil: return "Visa number"
            default: return "Control Number"
            }
        },
        // An OCI card or an e-Visa by what it is ("OCI card", "India e-Visa"); a US visa by its class.
        which: { facts, title, _ in
            facts?.form != nil ? title
                : facts?.details.first { $0.label == "Visa class" }.map { $0.drawn(shown: true) } ?? "US visa"
        },
        // Where the visa lets its holder in: the country that issued it.
        place: { facts in
            switch facts?.issuer {
            case "USA"?: return (.us, "A US visa")
            case "IND"?: return (.india, facts?.form == "OCI" ? "An OCI card" : "An Indian visa")
            case nil where facts == nil || facts?.form == nil: return (.us, "A US visa")
            default: return (.anywhere, "Another country’s visa")
            }
        },
        // A US visa, an Indian e-Visa and an OCI card are each weighed only against their kind,
        // and a US visa only against its class: a B1/B2 still good beside a newer H-1B is
        // still a visa its holder can use.
        weighing: { facts, _ in
            // As letters and digits, so "H-1B" on one foil and "H1B" on the next are one class.
            let visaClass = facts.details.first { $0.label == "Visa class" }
                .map { VaultReading.normalized($0.drawn(shown: true)) } ?? ""
            return ("visa", "\(facts.issuer ?? "")|\(facts.form ?? "")|\(visaClass)")
        },
        // An expired visa is not carried; it is kept for reference.
        newest: { facts, ranOut in
            ranOut ? .archive("Expired " + VaultReading.monthYear(facts.validUntil)) : .current(expired: false)
        })

    static let i94 = VaultKindSpec(
        category: .i94, title: "I-94 Records", singular: "I-94 admission number", symbol: "airplane.arrival",
        paper: "I-94", hidesEnding: false, printed: nil, homes: ["form i-94", "i-94", "i94", "form i94"],
        group: "travel", isAccount: false, isHouseholdsWhenNameless: false, goodUntil: "Admitted until", endedWord: "Ran out ",
        idLabel: fixed("Admission number"), which: noWhich,
        place: fixedPlace(.us, "A US admission record"), weighing: nil, newest: markedExpired)

    static let uscisCase = VaultKindSpec(
        category: .uscisCase, title: "USCIS Cases", singular: "USCIS receipt number", symbol: "doc.text",
        paper: "USCIS notice", hidesEnding: false, printed: nil,
        homes: ["approval", "approvals", "approval notice", "receipt", "receipts", "notices"],
        group: "travel", isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil, endedWord: "Ran out ",
        idLabel: fixed("Receipt number"),
        which: { facts, _, whose in facts?.form ?? (whose == nil ? "USCIS case" : nil) },
        place: fixedPlace(.us, "A US immigration case"),
        weighing: { facts, value in ("case", facts.form ?? VaultReading.normalized(value)) },
        // A case is current while it is pending or still good; a decided case with no end
        // date, or one that ran out, is history.
        newest: { facts, ranOut in
            guard !facts.pending else { return .current(expired: ranOut) }
            if ranOut { return .archive("Ran out " + VaultReading.monthYear(facts.validUntil)) }
            if facts.validUntil == nil {
                return .archive("Decided" + (facts.dated.map { " · " + VaultReading.monthYear($0) } ?? ""))
            }
            return .current(expired: false)
        })

    static let driversLicense = VaultKindSpec(
        category: .driversLicense, title: "Driver’s Licenses", singular: "Driver’s license", symbol: "car",
        paper: "driver’s license", hidesEnding: false, printed: nil,
        homes: ["driver license", "driver licenses", "drivers license", "driver’s license",
                "driving license", "dl", "license", "licenses"],
        group: "legal", isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil, endedWord: "Expired ",
        idLabel: { _, title in title.hasPrefix("State ID") ? "ID number" : "License number" }, which: noWhich,
        place: { facts in
            switch facts?.issuer {
            case "USA": return (.us, "A US license")
            case "IND": return (.india, "An Indian license")
            case "CAN": return (.anywhere, "A Canadian license")
            default: return (.anywhere, facts == nil ? "Typed in; no country chosen yet" : "Its country was not read")
            }
        },
        // A US license and an Indian one are both kept; a new state's replaces the old.
        weighing: { facts, _ in ("license", facts.issuer ?? "") },
        newest: markedExpired)

    static let ssn = VaultKindSpec(
        category: .ssn, title: "Social Security & ITIN", singular: "Social Security number or ITIN",
        symbol: "person.text.rectangle", paper: "Social Security card", hidesEnding: true, printed: [3, 2, 4],
        homes: ["ssn", "social security", "itin"], group: "legal", isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil,
        endedWord: "Ran out ", idLabel: { facts, _ in facts?.form == "ITIN" ? "ITIN" : "Social Security number" },
        which: noWhich,
        place: { facts in (.us, facts?.form == "ITIN" ? "An IRS number" : "A Social Security card") },
        // An SSN and an ITIN are weighed apart; an ITIN gives way to an SSN (``VaultStandings``).
        weighing: { facts, _ in ("ssn", facts.form ?? "") },
        newest: markedExpired)

    static let pan = VaultKindSpec(
        category: .pan, title: "PAN Cards", singular: "PAN (India)", symbol: "indianrupeesign.circle",
        paper: "PAN card", hidesEnding: false, printed: [5, 4, 1], homes: ["pan", "pan card"], group: "legal",
        isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil, endedWord: "Ran out ", idLabel: fixed("PAN"), which: noWhich,
        place: fixedPlace(.india, "An Indian PAN"), weighing: nil, newest: markedExpired)

    static let aadhaar = VaultKindSpec(
        category: .aadhaar, title: "Aadhaar", singular: "Aadhaar number", symbol: "person.crop.rectangle",
        paper: "Aadhaar", hidesEnding: true, printed: nil, homes: ["aadhaar", "aadhar"], group: "legal",
        isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil, endedWord: "Ran out ", idLabel: fixed("Aadhaar number"), which: noWhich,
        place: fixedPlace(.india, "An Aadhaar number"), weighing: nil, newest: markedExpired)

    static let voterID = VaultKindSpec(
        category: .voterID, title: "Voter IDs", singular: "Voter ID (EPIC)", symbol: "checkmark.seal",
        paper: "voter ID", hidesEnding: false, printed: nil, homes: ["voter id", "voter ids", "voter", "epic"],
        group: "legal", isAccount: false, isHouseholdsWhenNameless: false, goodUntil: nil, endedWord: "Ran out ", idLabel: fixed("EPIC number"),
        which: noWhich, place: fixedPlace(.india, "An Election Commission card"), weighing: nil,
        newest: markedExpired)

    // A read account's number as its paper calls it: "Member ID", "Policy number", "Student ID".
    static let health = VaultKindSpec(
        category: .health, title: "Health & Medical", singular: "Health or medical ID", symbol: "heart",
        paper: nil, hidesEnding: false, printed: nil, homes: [], group: "health", isAccount: true, isHouseholdsWhenNameless: false,
        goodUntil: nil, endedWord: "Ran out ", idLabel: { facts, _ in facts?.form ?? "Member ID" },
        which: accountWhich, place: noCountry, weighing: nil, newest: markedExpired)

    static let utilities = VaultKindSpec(
        category: .utilities, title: "Utilities & Phone", singular: "Utility or phone account", symbol: "bolt",
        paper: nil, hidesEnding: false, printed: nil, homes: [], group: "home", isAccount: true, isHouseholdsWhenNameless: true,
        goodUntil: nil, endedWord: "Ran out ", idLabel: { facts, _ in facts?.form ?? "Account number" },
        which: accountWhich, place: noCountry, weighing: nil, newest: markedExpired)

    static let loans = VaultKindSpec(
        category: .loans, title: "Loans & Mortgage", singular: "Loan or mortgage account", symbol: "house",
        paper: nil, hidesEnding: false, printed: nil, homes: [], group: "home", isAccount: true, isHouseholdsWhenNameless: true,
        goodUntil: nil, endedWord: "Ran out ", idLabel: { facts, _ in facts?.form ?? "Account number" },
        which: accountWhich, place: noCountry, weighing: nil, newest: markedExpired)

    static let other = VaultKindSpec(
        category: .other, title: "Other", singular: "Other ID", symbol: "number",
        paper: nil, hidesEnding: false, printed: nil, homes: [], group: "home", isAccount: true, isHouseholdsWhenNameless: false,
        goodUntil: nil, endedWord: "Ran out ", idLabel: { facts, _ in facts?.form ?? "Number" },
        which: accountWhich, place: noCountry, weighing: nil, newest: markedExpired)
}

/// One of the app's groups: its id, the name it starts with and the color its cards start in.
public struct VaultGroupSpec: Sendable {
    public let id: VaultGroups.ID
    public let name: String
    public let tint: VaultTint

    /// In the order the Kinds choice lists them. Contact last: its cards come after every ID's
    /// (``VaultContactCard``).
    public static let all: [VaultGroupSpec] = [
        VaultGroupSpec(id: "travel", name: "Travel & Immigration", tint: .blue),
        VaultGroupSpec(id: "legal", name: "Legal & IDs", tint: .violet),
        VaultGroupSpec(id: "health", name: "Health", tint: .rose),
        VaultGroupSpec(id: "home", name: "Home & Money", tint: .green),
        VaultGroupSpec(id: VaultGroups.contact, name: "Contact", tint: .clay),
    ]
}
