import Foundation

/// Account numbers from a household's papers under Health, Home, Vehicles and School: a plan's
/// member ID, a utility's account number, a loan, a policy, a student ID. One reader for all of
/// them, by the labels such papers print beside the number (``PrintedPage``); who issued it comes
/// from the folder the household filed it in, which names it better than any logo the scan reads.
///
/// Read only for a file in one of those areas (``VaultReadPlan/area(of:)``): elsewhere an
/// "Account Number" is a bank's on a petition, or an employer's on a tax form.
extension VaultReading {

    /// The cards account numbers go on: what ``VaultModel`` weighs when it stops reading an
    /// account whose years agree.
    static let accountCategories: Set<VaultCategory> = [.health, .utilities, .loans, .other]

    /// What a number is called, with the labels papers print for it, the most telling first.
    struct AccountKind {
        let name: String
        let labels: [String]
    }

    static let accountKinds: [AccountKind] = [
        // A plan's number for its member: Delta Dental's enrollee, Kaiser's health record number.
        AccountKind(name: "Member ID", labels: ["member id", "member number", "member no", "member #",
                                                "subscriber id", "subscriber number", "subscriber no", "enrollee id",
                                                "patient id", "health record number", "health record no",
                                                "medical record number", "medical record no", "mrn"]),
        AccountKind(name: "Policy number", labels: ["policy number", "policy no", "policy #"]),
        AccountKind(name: "Loan number", labels: ["loan number", "loan no", "loan #"]),
        AccountKind(name: "Student ID", labels: ["student id", "student number", "student no", "student #"]),
        AccountKind(name: "VIN", labels: ["vehicle identification number", "vehicle id number", "vin"]),
        AccountKind(name: "Account number", labels: ["account number", "account no", "account #", "acct no", "acct. no",
                                                     "acct #", "acct number", "a/c no", "customer number", "customer no",
                                                     "cust. no", "cust no", "cust #", "customer id", "service account",
                                                     "account id"]),
    ]

    /// A number beside one of those labels: groups of letters and digits joined by a space or a
    /// dash, every group holding a digit but a short prefix a dash ties to the rest, so
    /// "1234 5678 9012", "XZB-45-1234" and "CA-123-4567-89" are read whole, "12345 Due" stops
    /// before the word, "12345678 01/02/1990" and "12345-67-89 01-01-2022" (a card's columns read
    /// as one line) stop before the date, and the words of "write your account number on your check" or "is 987654" are no
    /// number at all.
    private static let accountValue = try! NSRegularExpression(
        pattern: #"(?:(?=[A-Z]*[0-9])[A-Z0-9]+|[A-Z]{1,4}(?=-[A-Z]*[0-9]))(?:(?: (?![0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{2,4}(?![0-9]))|-)(?=[A-Z]*[0-9])[A-Z0-9]+(?![/.:][0-9])){0,6}(?![A-Za-z0-9])"#,
        options: [.caseInsensitive])
    /// What may stand between a label and its number: not `*`, so a mask's "****1234" is seen as
    /// masked and never read as "1234".
    private static let beforeNumber = PrintedPage.separators.subtracting(["*"])
    private static let groupLabels = ["group number", "group no", "group #", "group id"]
    /// Labels that name the person and nothing else: a bare "Member" or "Name" also heads "Member
    /// Services" and "Plan Name".
    private static let holderLabels = ["member name", "subscriber name", "student name", "patient name",
                                       "insured name", "name of insured", "account holder", "customer name"]
    private static let holderValue = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z .'-]*[A-Za-z]"#)

    /// The account numbers a page prints, each once: the main one beside its kind's label, with a
    /// plan's group number as a detail. Not a number shown only by its ending ("XXXX-1234",
    /// "****1234"), nor a date or a phone number read beside a label. `roots` are the read folders
    /// (``VaultReadPlan/area(of:under:)``); `people` keeps a person's folder from being taken for
    /// who issued the account.
    static func accountNumbers(on page: PrintedPage, from path: String, under roots: [String] = [],
                               people: [Person] = []) -> [VaultFind] {
        guard VaultReadPlan.area(of: path, under: roots) == .accounts else { return [] }
        var out: [VaultFind] = []
        var seen = Set<String>()
        for kind in accountKinds {
            let isVINKind = kind.name == "VIN"
            guard let value = page.value(preferring: kind.labels, accountValue, skipping: beforeNumber,
                                         keeping: { isVINKind ? vin($0) : accountNumber($0) }),
                  seen.insert(normalized(value)).inserted else { continue }
            out.append(accountFind(value, kind: kind.name, page: page, path: path, roots: roots, people: people))
        }
        // The group number is the plan's, shared by everyone on it: a detail of the member's, never
        // a number of its own.
        let group = groupNumber(on: page).map(normalized)
        return out.filter { normalized($0.value) != group }
    }

    private static func groupNumber(on page: PrintedPage) -> String? {
        page.value(preferring: groupLabels, accountValue, skipping: beforeNumber, keeping: accountNumber)
    }

    /// A printed number, if it is one: four digits at least, not masked, not a date, a phone
    /// number or a ZIP code.
    static func accountNumber(_ printed: String) -> String? {
        let value = printed.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber).count
        guard digits >= 4, (5...25).contains(normalized(value).count) else { return nil }
        let upper = value.uppercased()
        guard !upper.contains("XXX"), !upper.contains("***") else { return nil }
        // A date read beside the label ("Account opened 01-02-2020"), either way round.
        if [DateOrder.monthFirst, .dayFirst].contains(where: { PrintedPage.leadingDate(value, order: $0) != nil }) {
            return nil
        }
        // A phone number, toll-free or not, however it is spaced; a ZIP+4.
        if value.range(of: #"^(?:1[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-][0-9]{4}$"#, options: .regularExpression) != nil
            || value.range(of: #"^[0-9]{5}[ -][0-9]{4}$"#, options: .regularExpression) != nil {
            return nil
        }
        return value
    }

    /// A VIN beside its label, even with more printed after it on the line ("1HGCM82633A004352
    /// 2019 HONDA" on a registration): its first seventeen letters and digits, when they check.
    static func vin(_ printed: String) -> String? {
        let letters = normalized(printed)
        guard letters.count >= 17 else { return nil }
        let candidate = String(letters.prefix(17))
        return isVIN(candidate) ? candidate : nil
    }

    /// A vehicle identification number, as North America writes it: seventeen letters and digits,
    /// never I, O or Q, its ninth a check digit over the rest. A scan's misread letter fails it.
    static func isVIN(_ value: String) -> Bool {
        let vin = Array(normalized(value))
        guard vin.count == 17, !vin.contains(where: { "IOQ".contains($0) }) else { return false }
        let letters: [Character: Int] = ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "J": 1,
                                         "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9, "S": 2, "T": 3, "U": 4,
                                         "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (index, character) in vin.enumerated() {
            guard let worth = character.wholeNumberValue ?? letters[character] else { return false }
            sum += worth * weights[index]
        }
        let check = sum % 11
        return vin[8] == (check == 10 ? "X" : Character(String(check)))
    }

    private static let bareLine = try! NSRegularExpression(pattern: #"^[A-Z0-9](?:[A-Z0-9]|[ -](?=[A-Z0-9])){4,22}$"#,
                                                           options: [.caseInsensitive])

    /// Numbers standing alone on a line of an account's paper, with no label beside them: a phone
    /// bill's account number in its header, between the date and the page count. Candidates only:
    /// ``VaultModel`` keeps one when two years of the same account print it, which an invoice
    /// number, changing every bill, never does. Six digits at least; never a date, a phone number,
    /// an amount or a ZIP code.
    ///
    /// Only for a utility's, a phone's or a loan's statements, which print an account number alone
    /// in their header; a registration or a policy repeats other numbers year to year.
    static func bareAccountNumbers(on page: PrintedPage, from path: String, under roots: [String] = []) -> Set<String> {
        guard VaultReadPlan.area(of: path, under: roots) == .accounts,
              [.utilities, .loans].contains(accountCategory(path, kind: "Account number", under: roots)) else { return [] }
        var out = Set<String>()
        for line in page.lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard bareLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil,
                  text.filter(\.isNumber).count >= 6,
                  let value = accountNumber(text) else { continue }
            out.insert(normalized(value))
        }
        return out
    }

    /// An account's number read without its label, from the paper it was seen on.
    static func bareAccountFind(_ value: String, on page: PrintedPage, from path: String, under roots: [String] = [],
                                people: [Person] = []) -> VaultFind {
        accountFind(value, kind: "Account number", page: page, path: path, roots: roots, people: people)
    }

    private static func accountFind(_ value: String, kind: String, page: PrintedPage, path: String,
                                    roots: [String], people: [Person]) -> VaultFind {
        let issuer = accountIssuer(path, under: roots, people: people)
        let category = accountCategory(path, kind: kind, under: roots)
        let holder = page.value(preferring: holderLabels, holderValue, keeping: nameOnly)
        var details: [VaultDetail] = []
        if let issuer { details.append(VaultDetail("Issued by", .text(issuer))) }
        if let group = groupNumber(on: page) {
            details.append(VaultDetail("Group number", .number(group)))
        }
        let card = page.says("id card") || path.lowercased().contains("id card")
        let facts = VaultReadFacts(category: category, holder: holder, form: kind, dated: fileDate(path) ?? yearOf(path),
                                   details: details,
                                   sources: [VaultSource(path: path, role: card ? "ID card" : "Account paper",
                                                         rank: card ? IDRank.card : IDRank.letter)])
        let title = issuer.map { "\($0) · \(kind)" } ?? kind
        return VaultFind(title: title, value: value, note: sentence([holder].compactMap { $0 }), facts: facts)
    }

    // MARK: From the folder

    /// Folder names that say what a paper is, or group papers, not who issued them.
    private static let paperFolders: Set<String> = [
        "id cards", "id card", "id", "cards", "statements", "statement", "lease statements", "policy", "policies",
        "insurance", "plans & coverage", "coverage", "registration", "payments", "payment", "loan", "extension",
        "papers", "car papers", "account", "todo", "us", "in", "utilities", "documents",
    ]

    /// Who issued the account, as the household's folders name it: the last folder below the
    /// area that is neither a year (or a year's folder, "2023 - Girish"), a kind of paper, nor one
    /// of the household's people ("EBMUD" in `Home/Utilities/EBMUD/2024`, "Twin Creeks" in
    /// `School/US/Twin Creeks/Liv`, "Medical" in `Health/Medical/Shweta/ID Cards`). With none,
    /// the folder just below the area ("Insurance" in `Home/Insurance/Policy`); nil when the paper
    /// sits in the area itself.
    static func accountIssuer(_ path: String, under roots: [String] = [], people: [Person] = []) -> String? {
        let place = VaultReadPlan.place(of: path, under: roots)
        guard place.count > 1 else { return nil }
        let below = place.dropFirst()
        let registry = people.isEmpty ? nil : PersonRegistry(people: people)
        let notAPerson = below.filter { registry?.detect(in: $0).isEmpty ?? true }
        let named = notAPerson.filter { folder in
            !paperFolders.contains(folder.lowercased())
                && folder.range(of: #"^(?:19|20)[0-9]{2}(?![0-9])"#, options: .regularExpression) == nil
        }
        return named.last ?? notAPerson.first
    }

    /// The card a number goes on: a loan's on Loans & Mortgage; under Health, Health & Medical;
    /// a utility's or a phone's on Utilities & Phone; the rest on Other.
    static func accountCategory(_ path: String, kind: String, under roots: [String] = []) -> VaultCategory {
        let folders = Set(VaultReadPlan.place(of: path, under: roots).map { $0.lowercased() })
        if kind == "Loan number" || folders.contains("mortgage") { return .loans }
        if folders.contains("health") { return .health }
        if folders.contains("utilities") || folders.contains("phone") || folders.contains("internet") { return .utilities }
        return .other
    }

    /// The year folder a file is filed under, as that year's first day.
    private static func yearOf(_ path: String) -> Date? {
        (path as NSString).deletingLastPathComponent.split(separator: "/").reversed()
            .compactMap { Int($0) }.first { (1990...2100).contains($0) }
            .flatMap { calendarDate(year: $0, month: 1, day: 1) }
    }
}
