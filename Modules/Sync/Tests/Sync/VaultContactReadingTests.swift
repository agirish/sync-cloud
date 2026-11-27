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

    /// "Work Address:" on a line of its own between the name and the street: the employer's, not
    /// their home, as the same label beside the street already was (the second review). A work
    /// phone between them leaves the home theirs.
    @Test func aWorkAddressLabelOnItsOwnLineIsNotTheHome() {
        let work = [Self.account, "Anna Eriksson", "Work Address:", "1 Example Loop", "Cupertino, CA 95014"]
        #expect(Self.address(work) == nil)
        let phone = [Self.account, "ANNA ERIKSSON", "Work Phone: (408) 555-0142", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(phone) == Self.home)
    }

    /// A page read both ways: its layer's phone and home speak, and its picture's misread digit is
    /// no second phone (the second review). A picture whose layer has none still gives its own.
    @Test func aPageReadBothWaysGivesItsLayersPhoneAlone() throws {
        let layer = [Self.account, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132", "Cell: (408) 555-0142"]
        let picture = [Self.account, "ANNA ERIKSSON", "2847 LARKSPUR LN", "SAN JOSE CA 95132", "Cell: (408) 555-0148"]
        func source(_ pages: [[String]], _ origins: [VaultPageOrigin]) -> VaultSource? {
            VaultReading.read(pages: pages, from: Self.bill, people: Self.people, origins: origins)
                .finds.first?.facts.sources.first { $0.path == Self.bill }
        }
        // The picture as the page, the layer as its second reading: the layer still speaks.
        let read = try #require(source([picture, layer], [VaultPageOrigin(page: 1, half: .picture),
                                                          VaultPageOrigin(page: 1, half: .textLayer)]))
        #expect(read.phones?.map(\.number) == ["4085550142"])
        #expect(read.address?.address == Self.home)
        let bare = [Self.account, "Statement"]
        let pictureOnly = try #require(source([bare, picture], [VaultPageOrigin(page: 1, half: .textLayer),
                                                                VaultPageOrigin(page: 1, half: .picture)]))
        #expect(pictureOnly.phones?.map(\.number) == ["4085550148"], "a layer with no phone leaves the picture's")
        // Page 2's layer repeats page 1's phone: its picture's misread still is not added (the
        // third review).
        let first = [Self.account, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132", "Cell: (408) 555-0142"]
        let repeated = try #require(source([first, layer, picture],
                                           [VaultPageOrigin(page: 1, half: .textLayer), VaultPageOrigin(page: 2, half: .textLayer),
                                            VaultPageOrigin(page: 2, half: .picture)]))
        #expect(repeated.phones?.map(\.number) == ["4085550142"])
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
        // Each names Anna in full, so only the business word turns the block away.
        for name in ["ANNA ERIKSSON DDS", "ANNA ERIKSSON DENTAL GROUP", "ANNA ERIKSSON LLC"] {
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
        // A form's fields may stand between, five lines at most.
        let fields = ["Member ID: 12345", "Account Number: 6789", "Policy Number: 1111", "Date of Birth: 01/02/1990",
                      "Email: anna@example.com"]
        #expect(Self.phones([Self.account, "ANNA ERIKSSON"] + fields.prefix(4) + ["Phone: (408) 555-0142"]).count == 1)
        #expect(Self.phones([Self.account, "ANNA ERIKSSON"] + fields + ["Phone: (408) 555-0142"]).isEmpty)
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

// MARK: The review of 19bd3fa90

extension VaultContactReadingTests {
    static let block = [Self.account, "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]

    @Test func aPhoneBesideAnyWordButAPhonesLabelIsNotRead() {
        for line in ["Customer Care: (408) 555-0199", "Billing: (408) 555-0199", "Contact: (408) 555-0199",
                     "Customer Care, day or night: (408) 555-0199", "Account Number: 408-555-0199",
                     "Number: 408-555-0199", "Sex: M  Phone: (408) 555-0142"] {
            #expect(Self.phones(Self.block + [line]).isEmpty, "\(line)")
        }
        // A number on its own line under a heading that is not a phone's.
        for heading in ["Customer Care", "Account Number:", "Billing"] {
            #expect(Self.phones(Self.block + [heading, "(408) 555-0199"]).isEmpty, "\(heading)")
        }
        // Still read: a phone's own heading, a contact number, an extension.
        #expect(Self.phones(Self.block + ["Phone", "(408) 555-0142"]).count == 1)
        #expect(Self.phones(Self.block + ["Contact Number: (408) 555-0142"]).count == 1)
        #expect(Self.phones(Self.block + ["Phone: 408-555-0142 x123"]).map(\.number) == ["4085550142"])
    }

    @Test func threeGroupsCutFromALongerNumberAreNoPhone() {
        for line in ["Phone: 1234 567 890 1234", "Phone: 567 890 1234 5", "Account Number: 1234 567 890 1234"] {
            #expect(Self.phones(Self.block + [line]).isEmpty, "\(line)")
        }
    }

    @Test func aStrangerSharingOneNameWordIsNotThem() {
        #expect(Self.phones([Self.account, "Anna Lee, Customer Care", "Phone: (408) 555-0100"]).isEmpty)
        #expect(Self.phones([Self.account, "Anna Lee", "Phone: (408) 555-0100"]).isEmpty)
        #expect(Self.address([Self.account, "Dr. Anna Lee", "3600 Broadway", "Oakland, CA 94611"]) == nil)
        // A middle initial between their two names still names them.
        #expect(Self.address([Self.account, "ANNA M ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]) == Self.home)
    }

    @Test func careOfOnTheNamesOwnLineIsSomeoneElsesAddress() {
        for name in ["ANNA ERIKSSON C/O JOHN DOE", "ANNA ERIKSSON C/O FRAGOMEN", "ANNA ERIKSSON IN CARE OF J SMITH"] {
            #expect(Self.address([Self.account, name, "100 MAIN ST", "OAKLAND CA 94607"]) == nil, "\(name)")
        }
        #expect(Self.address([Self.account, "ANNA ERIKSSON C/O BOB ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"])
            == Self.home)
    }

    @Test func anOldAddressIsNotTheHome() {
        let lines = [Self.account, "Name: Anna Eriksson", "Old Address: 12 Elm St, Oakland, CA 94607",
                     "New Address: 2841 Larkspur Ln, San Jose, CA 95132"]
        #expect(Self.address(lines)?.zip == "95132")
        for label in ["Previous Address:", "Former Address:", "Prior Address:"] {
            #expect(Self.address([Self.account, "Name: Anna Eriksson", label + " 12 Elm St, Oakland, CA 94607"]) == nil, "\(label)")
        }
    }

    @Test func aPhoneUnderTwoNamesIsNobodysToTell() {
        let joint = [Self.account, "ANNA ERIKSSON", "BOB ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132",
                     "Phone: (408) 555-0142"]
        #expect(Self.phones(joint).isEmpty)
        #expect(Self.address(joint) == Self.home, "the address is theirs both")
    }

    @Test func aBusinessWordBetweenTheNameAndTheStreetTurnsTheBlockAway() {
        // "Member" may stand between; "Services" makes the line a business's.
        let lines = [Self.account, "Patient: Anna Eriksson", "Member Services", "3600 Broadway", "Oakland, CA 94611"]
        #expect(Self.address(lines) == nil)
    }

    @Test func homesAFormPrintsAmongItsFieldsAreKept() {
        // A state that is also a business word, on the name's own line.
        #expect(Self.address([Self.account, "ANNA ERIKSSON 12 Main St, Bethesda, MD 20814"])?.state == "MD")
        // A medical record number between the name and the street.
        let record = [Self.account, "Patient Name: Anna Eriksson", "Medical Record Number: 1234567",
                      "Address: 2841 Larkspur Ln, San Jose, CA 95132"]
        #expect(Self.address(record)?.zip == "95132")
    }

    @Test func aLetterAloneLabelsAPhoneOnlyAsTheWholeLabel() {
        #expect(VaultReading.phoneLabel(["m"]) == "Mobile" && VaultReading.phoneLabel(["c"]) == "Mobile")
        #expect(VaultReading.phoneLabel(["sex", "m", "phone"]) == nil)
        #expect(VaultReading.phoneLabel(["h"]) == "Home" && VaultReading.phoneLabel(["w"]) == "Work")
    }

    /// A saved ID keeps what an older build read until the file is read again; today's reading
    /// then speaks for it, finding nothing included.
    @Test func todaysReadingOfAFileReplacesWhatASavedIDKept() {
        let stale = VaultPrintedAddress(VaultAddress(street: "100 N First St", city: "San Jose", state: "CA", zip: "95112"),
                                        dated: nil)
        let phone = VaultPrintedPhone(number: "4085550199", person: "anna")
        let saved = VaultSource(path: "/a.pdf", role: "I-797C receipt", rank: 20, address: stale, phones: [phone])
        let today = VaultSource(path: "/a.pdf", role: "I-797C receipt", rank: 20)
        var kept = VaultReadFacts(category: .uscisCase, sources: [saved])
        kept.add(today, contacts: .incoming)
        #expect(kept.sources[0].address == nil && kept.sources[0].phones == nil)
        // Today's reading first, the saved ID's source added into it.
        var newer = VaultReadFacts(category: .uscisCase, sources: [today])
        newer.add(saved, contacts: .existing)
        #expect(newer.sources[0].address == nil && newer.sources[0].phones == nil)
        // Two readings of one build: whichever gave them.
        var either = VaultReadFacts(category: .uscisCase, sources: [today])
        either.add(saved)
        #expect(either.sources[0].address == stale)
    }
}

extension VaultContactReadingTests {
    /// Homes the stricter naming first lost on his papers (the count-only harness).
    @Test func aLicenseFrontsNameFieldsNameThemALineEach() {
        let front = [Self.account, "4d DLN D1234567", "LN ERIKSSON", "FN ANNA", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(front) == Self.home)
        #expect(Self.address([Self.account, "First Name: Anna", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]) == Self.home)
        // A name's field holding a word People does not know is someone else's name.
        #expect(Self.address([Self.account, "Name: Anna Lee", "3600 Broadway", "Oakland, CA 94611"]) == nil)
    }

    @Test func aSurnameWrappedOrTheFamilyTrustBetweenKeepsTheHome() {
        let wrapped = [Self.account, "Named Insured", "ANNA ERIKSSON AND BOB", "ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132"]
        #expect(Self.address(wrapped) == Self.home)
        let trust = [Self.account, "ANNA ERIKSSON AND BOB ERIKSSON", "TRUSTEES ERIKSSON FAMILY TRUST", "2841 LARKSPUR LN",
                     "SAN JOSE CA 95132"]
        #expect(Self.address(trust) == Self.home)
    }
}

