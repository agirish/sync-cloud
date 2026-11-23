import Foundation
import Testing
@testable import Sync

/// The kinds and places as data (VT2, VT4): one row per kind, the lists made from the rows, a
/// household's kind as a row, and a place as a country's code or anywhere.
@Suite struct VaultKindSpecTests {
    @Test func everyKindHasOneRowAndTheMainViewDrawsThemInTheirOrder() {
        let kinds = VaultKindSpec.all.map(\.category)
        #expect(kinds.count == Set(kinds).count)
        #expect(Set(kinds) == Set(VaultCategory.allCases))
        #expect(VaultCategory.mainView == [.passport, .usVisa, .i94, .uscisCase, .driversLicense, .ssn, .pan, .aadhaar,
                                           .voterID, .health, .utilities, .loans, .other])
        for category in VaultCategory.allCases { #expect(category.spec.category == category) }
    }

    /// Each row's words, pinned as the switches they replaced said them.
    @Test func eachKindsRowSaysWhatItAlwaysSaid() {
        typealias Words = (title: String, singular: String, symbol: String, paper: String?, group: String, label: String)
        let words: [VaultCategory: Words] = [
            .passport: ("Passports", "Passport", "globe", "passport", "travel", "Passport number"),
            .usVisa: ("Visas", "Visa", "airplane", "visa", "travel", "Visa number"),
            .i94: ("I-94 Records", "I-94 admission number", "airplane.arrival", "I-94", "travel", "Admission number"),
            .uscisCase: ("USCIS Cases", "USCIS receipt number", "doc.text", "USCIS notice", "travel", "Receipt number"),
            .driversLicense: ("Driver’s Licenses", "Driver’s license", "car", "driver’s license", "legal", "License number"),
            .ssn: ("Social Security & ITIN", "Social Security number or ITIN", "person.text.rectangle",
                   "Social Security card", "legal", "Social Security number"),
            .pan: ("PAN Cards", "PAN (India)", "indianrupeesign.circle", "PAN card", "legal", "PAN"),
            .aadhaar: ("Aadhaar", "Aadhaar number", "person.crop.rectangle", "Aadhaar", "legal", "Aadhaar number"),
            .voterID: ("Voter IDs", "Voter ID (EPIC)", "checkmark.seal", "voter ID", "legal", "EPIC number"),
            .health: ("Health & Medical", "Health or medical ID", "heart", nil, "health", "Member ID"),
            .utilities: ("Utilities & Phone", "Utility or phone account", "bolt", nil, "home", "Account number"),
            .loans: ("Loans & Mortgage", "Loan or mortgage account", "house", nil, "home", "Account number"),
            .other: ("Other", "Other ID", "number", nil, "home", "Number"),
        ]
        for category in VaultCategory.allCases {
            let spec = category.spec
            let expected = words[category]!
            #expect(spec.title == expected.title)
            #expect(spec.singular == expected.singular)
            #expect(spec.symbol == expected.symbol)
            #expect(spec.paper == expected.paper)
            #expect(spec.group == expected.group)
            #expect(spec.idLabel(nil, "") == expected.label)
            #expect(VaultGroups.default.group(of: category) == expected.group)
        }
        #expect(VaultCategory.usVisa.spec.idLabel(VaultReadFacts(category: .usVisa, form: "OCI"), "") == "OCI number")
        #expect(VaultCategory.usVisa.spec.idLabel(VaultReadFacts(category: .usVisa, form: "e-Visa"), "") == "Application number")
        #expect(VaultCategory.usVisa.spec.idLabel(VaultReadFacts(category: .usVisa), "") == "Control Number")
        #expect(VaultCategory.ssn.spec.idLabel(VaultReadFacts(category: .ssn, form: "ITIN"), "") == "ITIN")
        #expect(VaultCategory.driversLicense.spec.idLabel(nil, "State ID card") == "ID number")
        #expect(VaultCategory.health.spec.idLabel(VaultReadFacts(category: .health, form: "Policy number"), "") == "Policy number")
        #expect(VaultCategory.uscisCase.spec.which(nil, "", nil) == "USCIS case")
        #expect(VaultCategory.uscisCase.spec.which(nil, "", "Anna") == nil)
        #expect(VaultCategory.i94.spec.goodUntil == "Admitted until")
        #expect(VaultKindSpec.all.filter { $0.goodUntil != nil }.map(\.category) == [.i94])
        #expect(VaultKindSpec.all.filter { $0.endedWord == "Expired " }.map(\.category) == [.passport, .usVisa, .driversLicense])
    }

    /// Where a kind is used, by its document: the words its row gives each answer.
    @Test func eachKindsRowSaysWhereItIsUsed() {
        func place(_ category: VaultCategory, issuer: String? = nil, form: String? = nil) -> String {
            let read = VaultGeo.read(category, facts: VaultReadFacts(category: category, issuer: issuer, form: form))
            return "\(read.geo.rawValue): \(read.reason)"
        }
        #expect(place(.usVisa, issuer: "IND", form: "OCI") == "india: An OCI card")
        #expect(place(.usVisa, issuer: "IND", form: "e-Visa") == "india: An Indian visa")
        #expect(place(.usVisa, issuer: "GBR", form: "e-Visa") == "anywhere: Another country’s visa")
        #expect(place(.usVisa) == "us: A US visa")
        #expect(place(.driversLicense, issuer: "CAN") == "anywhere: A Canadian license")
        #expect(place(.driversLicense) == "anywhere: Its country was not read")
        #expect(place(.ssn, form: "ITIN") == "us: An IRS number")
        #expect(place(.voterID) == "india: An Election Commission card")
        #expect(VaultGeo.read(.loans, facts: nil).geo == .anywhere)
        #expect(VaultGeo.read(.loans, facts: nil).reason == "Typed in; no country chosen yet")
    }

    /// What a kind's row says becomes of the newest of its group, and of one replaced.
    @Test func eachKindsRowSaysHowANewerOneReplacesIt() {
        let now = VaultReading.calendarDate(year: 2024, month: 3, day: 1)!
        func day(_ year: Int) -> Date { VaultReading.calendarDate(year: year, month: 6, day: 15)! }
        func item(_ category: VaultCategory, _ value: String, dated: Int, until: Int?, pending: Bool = false) -> VaultStandingInput {
            var facts = VaultReadFacts(category: category, holder: "Anna Test", issuer: "USA", dated: day(dated),
                                       validUntil: until.map(day), pending: pending)
            facts.add(VaultSource(path: "/R/\(value).pdf", role: "x", rank: 1))
            return VaultStandingInput(id: UUID(), value: value, category: category, facts: facts, pin: nil)
        }
        let old = item(.health, "H1", dated: 2015, until: 2020), new = item(.health, "H2", dated: 2019, until: 2030)
        let license = item(.driversLicense, "L1", dated: 2015, until: 2019), newLicense = item(.driversLicense, "L2", dated: 2020, until: 2021)
        let decided = item(.uscisCase, "C1", dated: 2021, until: nil)
        let pending = item(.uscisCase, "C2", dated: 2021, until: nil, pending: true)
        let visa = item(.usVisa, "V1", dated: 2018, until: 2022)
        let out = VaultStandings.compute([old, new, license, newLicense, decided, pending, visa], now: now)
        #expect(out[old.id]?.reason == "Ran out Jun 2020 · replaced")
        #expect(out[new.id]?.tab == .current)
        #expect(out[license.id]?.reason == "Expired Jun 2019 · replaced")
        // The newest license, run out, stays current and is marked expired.
        #expect(out[newLicense.id]?.tab == .current && out[newLicense.id]?.expired == true)
        #expect(out[decided.id]?.tab == .archive && out[decided.id]?.reason == "Decided · Jun 2021")
        #expect(out[pending.id]?.tab == .current)
        #expect(out[visa.id]?.tab == .archive && out[visa.id]?.reason == "Expired Jun 2022")
    }

    @Test func onlyAnAccountsKindCanChange() {
        let accounts: [VaultCategory] = [.health, .utilities, .loans, .other]
        #expect(VaultKinds.changeable == accounts)
        #expect(VaultReading.accountCategories == Set(accounts))
        for category in VaultCategory.allCases {
            #expect(VaultKinds.canChange(from: category) == accounts.contains(category))
            // An account's paper is never named in People's "On …", an identity paper's always is.
            #expect((category.spec.paper == nil) == accounts.contains(category))
        }
        // A utility's or a loan's account read with no name is the household's; a member ID is not.
        #expect(VaultKindSpec.all.filter(\.isHouseholdsWhenNameless).map(\.category) == [.utilities, .loans])
    }

    @Test func theAppsGroupsKeepTheirNamesAndColors() {
        #expect(VaultGroups.default.order == ["travel", "legal", "health", "home", VaultGroups.contact])
        #expect(VaultGroups.default.order.map(VaultGroups.default.name)
                == ["Travel & Immigration", "Legal & IDs", "Health", "Home & Money", "Contact"])
        #expect(VaultGroups.default.order.map { VaultColors.appGroups[$0] } == [.blue, .violet, .rose, .green, .clay])
    }

    @Test func aKindTheHouseholdMadeIsDrawnWithItsOwnNameAndATag() {
        let kinds = VaultKinds(custom: [VaultCustomKind(id: "k1", name: "Memberships", group: "health")])
        #expect(kinds.title(of: .custom("k1")) == "Memberships")
        #expect(kinds.symbol(of: .custom("k1")) == "tag")
        #expect(kinds.group(of: .custom("k1"), in: .default) == "health")
        // One no longer kept is titled Other, with a household kind's tag, in whatever group
        // Other is in now.
        var groups = VaultGroups.default
        groups.groupOf[.other] = "legal"
        #expect(kinds.title(of: .custom("k2")) == "Other")
        #expect(kinds.symbol(of: .custom("k2")) == "tag")
        #expect(kinds.group(of: .custom("k2"), in: groups) == "legal")
        #expect(kinds.title(of: .builtIn(.passport)) == "Passports")
        #expect(kinds.symbol(of: .builtIn(.passport)) == "globe")
    }

    @Test func aKindsRowPrintsAndHidesItsNumber() {
        #expect(VaultMask.printed("123456789", as: .ssn) == ["123", "45", "6789"])
        #expect(VaultMask.printed("ABCDE1234F", as: .pan) == ["ABCDE", "1234", "F"])
        // A kind with no pattern of its own, or a length its pattern does not fit, goes in fours.
        #expect(VaultMask.printed("123456789", as: .passport) == VaultMask.printed("123456789", as: nil))
        #expect(VaultMask.printed("12345678", as: .ssn) == VaultMask.printed("12345678", as: nil))
        #expect(VaultKindSpec.all.filter(\.hidesEnding).map(\.category) == [.ssn, .aadhaar])
    }

    @Test func aPlaceIsACountrysCodeOrAnywhere() throws {
        #expect(VaultGeo.anywhere.code == nil)
        let codes = VaultGeo.countries.compactMap(\.code)
        #expect(codes.count == VaultGeo.countries.count)
        #expect(Set(codes).count == codes.count)
        for country in VaultGeo.countries {
            #expect(country.code?.count == 2)
            #expect(VaultGeo(code: country.code!) == country)
            #expect(VaultGeo(rawValue: country.rawValue) == country)
        }
        #expect(VaultGeo(code: "XX") == nil)
        #expect(VaultGeo(code: "US")?.title == "United States")
        #expect(VaultGeo(code: "IN")?.title == "India")
        #expect(VaultGeo.allCases == [.us, .india, .anywhere])
        #expect(VaultGeo.home == .us)
    }

    /// The names the first builds stored stay the names written and read; one this build does
    /// not know fails to decode, as an enum's did, so the record goes back untouched (VT30).
    @Test func aPlaceIsStoredByTheNameTheFirstBuildsWrote() throws {
        struct Box: Codable, Equatable { var geo: VaultGeo? }
        for (geo, name) in [(VaultGeo.us, "us"), (.india, "india"), (.anywhere, "anywhere")] {
            let data = try JSONEncoder().encode(Box(geo: geo))
            #expect(String(decoding: data, as: UTF8.self) == "{\"geo\":\"\(name)\"}")
            #expect(try JSONDecoder().decode(Box.self, from: data) == Box(geo: geo))
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Box.self, from: Data("{\"geo\":\"gb\"}".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Box.self, from: Data("{\"geo\":\"US\"}".utf8)) }
    }

    @Test func theWhereChoiceListsEachCountryThenAll() {
        #expect(VaultGeoFilter.allCases.map(\.rawValue) == ["us", "india", "all"])
        #expect(VaultGeoFilter(rawValue: "all") == .all)
        #expect(VaultGeoFilter(rawValue: "anywhere") == nil)
        #expect(VaultGeoFilter.all.title == "Every Country")
        #expect(VaultGeoFilter.india.title == "India")
        #expect(VaultGeoFilter.us.shows(.anywhere) && VaultGeoFilter.us.shows(.us) && !VaultGeoFilter.us.shows(.india))
        #expect(VaultGeo.allCases.allSatisfy(VaultGeoFilter.all.shows))
    }
}
