import Foundation
import Testing
@testable import Sync

/// Home addresses and phones read only as a named person's (``VaultReading/contacts(in:people:)``):
/// a business's own (the letterhead, the provider, the seller, Customer Service) never.
/// Every address, name and number here is made up.
@Suite struct VaultContactReadingTests {
    static let people = [Person(id: "anna", displayName: "Anna", fullNames: ["Anna Eriksson"]),
                         Person(id: "bob", displayName: "Bob", fullNames: ["Bob Eriksson"])]
    static let bill = VaultAddressReadingTests.bill
    static let account = "Account Number: 1234 5678 9012"
    static let home = VaultAddress(street: "2841 LARKSPUR LN", city: "SAN JOSE", state: "CA", zip: "95132")

    static func source(_ lines: [String], at path: String = bill, people: [Person] = people) -> VaultSource? {
        VaultReading.read(pages: [lines], from: path, people: people).finds.first?.facts.sources.first { $0.path == path }
    }

    static func address(_ lines: [String]) -> VaultAddress? { source(lines)?.address?.address }
    static func phones(_ lines: [String]) -> [VaultPrintedPhone] { source(lines)?.phones ?? [] }

    // MARK: Addresses: a business's is never the home

    @Test func theLetterheadAboveTheNameLeavesTheHomeRead() {
        let lines = [Self.account, "Pacific Gas and Electric Company", "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(lines) == Self.home)
    }

    @Test func aBusinessBetweenTheNameAndTheStreetIsNotTheHome() {
        // An EOB: the patient's name, then the provider's address.
        let provider = [Self.account, "Patient: Anna Eriksson", "Kaiser Permanente", "3600 Broadway", "Oakland, CA 94611"]
        let labelled = [Self.account, "Patient: Anna Eriksson", "Provider:", "3600 Broadway", "Oakland, CA 94611"]
        let firm = [Self.account, "ANNA ERIKSSON", "C/O LAW OFFICES OF R. SMITH LLP", "100 MAIN ST", "OAKLAND CA 94607"]
        for lines in [provider, labelled, firm] { #expect(Self.address(lines) == nil, "\(lines[2])") }
    }

    @Test func aNameLineMayHoldAWordPeopleDoesNotKnow() {
        let maiden = [Self.account, "ANNA ERIKSSON", "OR BOB ERIKSSON-LARSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        let trust = [Self.account, "ERIKSSON FAMILY TRUST", "ATTENTION ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        for lines in [maiden, trust] { #expect(Self.address(lines) == Self.home, "\(lines[2])") }
    }

    @Test func careOfAFirmAboveTheNameIsTheFirmsAddress() {
        let lines = [Self.account, "C/O SMITH LAW GROUP LLP", "ATTN ANNA ERIKSSON", "100 N FIRST ST", "SAN JOSE CA 95112"]
        #expect(Self.address(lines) == nil)
    }

    @Test func careOfSomeoneInPeopleIsTheirHome() {
        let lines = [Self.account, "ANNA ERIKSSON", "C/O BOB ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(lines) == Self.home)
    }

    @Test func aSellersOrAProvidersBlockIsNotTheHome() {
        for label in ["Seller:", "Sold By", "Vendor", "Ship From:", "Return Address", "Dealer Information"] {
            let lines = [Self.account, label, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
            #expect(Self.address(lines) == nil, "\(label)")
        }
        // A label with its own value speaks only of its line.
        let agent = [Self.account, "Agent: Bob Smith", "Named Insured: ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(agent) == Self.home)
    }

    @Test func aNameWithABusinessWordIsNotTheHome() {
        for name in ["ANNA ERIKSSON DDS", "ERIKSSON DENTAL GROUP", "ANNA ERIKSSON LLC"] {
            let lines = [Self.account, name, "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
            #expect(Self.address(lines) == nil, "\(name)")
        }
    }

    @Test func aSuiteOrAFloorIsAnOfficeNotAHome() {
        for street in ["2841 LARKSPUR LN STE 200", "2841 Larkspur Ln Suite 200", "2841 LARKSPUR LN FL 3"] {
            let lines = [Self.account, "ANNA ERIKSSON", street, "SAN JOSE CA 95132"]
            #expect(Self.address(lines) == nil, "\(street)")
        }
    }

    @Test func theIssuersBlockFirstThenTheHomeReadsTheHome() {
        let lines = [Self.account, "East Bay Municipal Utility District", "375 11th Street", "Oakland, CA 94607", "",
                     "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(lines) == Self.home)
    }

    // MARK: Addresses: a form's labelled field

    @Test func aFormsHomeAddressOnOneLineIsRead() {
        let lines = [Self.account, "Patient Name: Anna Eriksson", "Date of Birth: 08/12/1974",
                     "Home Address: 2841 Larkspur Ln, Apt 6, San Jose, CA 95132"]
        #expect(Self.address(lines) == VaultAddress(street: "2841 Larkspur Ln", unit: "Apt 6", city: "San Jose",
                                                    state: "CA", zip: "95132"))
    }

    @Test func aBusinessesAddressOnOneLineIsNot() {
        for line in ["Provider Address: 3600 Broadway, Oakland, CA 94611",
                     "Kaiser Permanente, 3600 Broadway, Oakland, CA 94611"] {
            #expect(Self.address([Self.account, "Patient Name: Anna Eriksson", line]) == nil, "\(line)")
        }
    }

    @Test func anAddressNeedsSomeoneFromPeopleAboveIt() {
        #expect(Self.address([Self.account, "Home Address: 2841 Larkspur Ln, San Jose, CA 95132"]) == nil)
    }

    @Test func aNoticeMailedHomeGivesItsAddressToo() throws {
        let page = ["I-797C, Notice of Action", "Receipt Notice", "Receipt Number WAC-24-123-45678",
                    "Notice Date 07/10/2026", "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        let find = try #require(VaultReading.read(pages: [page], from: "/Immigration/notice.pdf", people: Self.people)
            .finds.first { $0.category == .uscisCase })
        #expect(find.facts.primary?.address?.address == Self.home)
    }

    // MARK: Phones: only a named person's

    @Test func aPhoneUnderTheNamesAddressIsTheirs() throws {
        let lines = [Self.account, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132", "Phone: (408) 555-0142"]
        let phone = try #require(Self.phones(lines).first)
        #expect(phone.number == "4085550142" && phone.person == "anna" && phone.label == nil)
        #expect(phone.dated == VaultReadingTests.day(2025, 1, 1), "the paper's date, as its address")
    }

    @Test func aPhonesLabelSaysWhatKindItIs() {
        let lines = [Self.account, "Patient Name: Anna Eriksson", "Cell: 408-555-0142", "Home Phone: 408.555.0143",
                     "Work: +1 408 555 0144"]
        #expect(Self.phones(lines).map(\.label) == ["Mobile", "Home", "Work"])
    }

    @Test func aPhoneOnTheNamesLineIsTheirs() {
        #expect(Self.phones([Self.account, "ANNA ERIKSSON (408) 555-0142"]).map(\.number) == ["4085550142"])
    }

    @Test func aPhoneIsWhoeversNameItIsPrintedUnder() {
        // A child's school form: the parent's phone.
        let lines = [Self.account, "Student Name: Anna Eriksson", "Parent/Guardian: Bob Eriksson", "Phone: (408) 555-0177"]
        #expect(Self.phones(lines).map(\.person) == ["bob"])
    }

    @Test func aBusinesssPhoneIsNeverRead() {
        let named = [Self.account, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        for line in ["Customer Service: (408) 555-0199", "Questions? Call us at 408-555-0199", "Fax: (408) 555-0199",
                     "Member Services 408-555-0199", "To report an outage call (408) 555-0199",
                     "Phone: 1-800-555-0199", "Phone: (888) 555-0199"] {
            #expect(Self.phones(named + [line]).isEmpty, "\(line)")
        }
    }

    @Test func aPhoneUnderABusinesssBlockIsNotTheNamedPersons() {
        let lines = [Self.account, "Patient: Anna Eriksson", "Kaiser Permanente", "3600 Broadway", "Oakland, CA 94611",
                     "Phone: (510) 555-0100"]
        #expect(Self.phones(lines).isEmpty)
        let seller = [Self.account, "Seller:", "ANNA ERIKSSON", "Phone: (408) 555-0142"]
        #expect(Self.phones(seller).isEmpty)
    }

    @Test func aPhoneWithNobodyFromPeopleNearIsNotRead() {
        #expect(Self.phones([Self.account, "Phone: (408) 555-0142"]).isEmpty)
        let far = [Self.account, "ANNA ERIKSSON", "Your bill this month", "Amount due $86.20", "Due date 03/15/2025",
                   "Phone: (408) 555-0142"]
        #expect(Self.phones(far).isEmpty)
        let lines = [Self.account, "ANNA ERIKSSON", "Phone: (408) 555-0142"]
        #expect(Self.source(lines, people: [])?.phones == nil, "with nobody in People, nothing is read")
    }

    @Test func tenDigitsRunTogetherAreNotReadAsAPhone() {
        #expect(Self.phones([Self.account, "ANNA ERIKSSON", "Phone: 4085550142"]).isEmpty)
    }

    // MARK: Kept on the source

    @Test func aSourceSavedBeforePhonesDecodesAndTakesTodaysPhones() throws {
        let old = #"{"path":"/a.pdf","role":"Account paper","rank":3}"#
        let source = try JSONDecoder().decode(VaultSource.self, from: Data(old.utf8))
        #expect(source.phones == nil)
        var saved = VaultReadFacts(category: .utilities, sources: [source])
        let phone = VaultPrintedPhone(number: "4085550142", person: "anna")
        saved.add(VaultSource(path: "/a.pdf", role: "Account paper", rank: 3, phones: [phone]))
        #expect(saved.sources[0].phones == [phone])
        saved.add(VaultSource(path: "/a.pdf", role: "ID card", rank: 9))
        #expect(saved.sources[0].role == "ID card" && saved.sources[0].phones == [phone])
    }
}

