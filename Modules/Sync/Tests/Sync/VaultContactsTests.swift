import Foundation
import Testing
@testable import Sync

/// A person's contact details in People: home addresses read from papers and typed, phones and
/// emails typed, where each is kept, and what a backup brings back. Every address and number is
/// made up.
@MainActor
@Suite struct VaultContactsTests {
    typealias Rig = VaultModelTests.Rig
    static let root = VaultPeopleViewTests.root
    static let people = VaultPeopleViewTests.people
    static let license = root + "/Legal/US/Driver License/Anna/dl.pdf"
    static let water = root + "/Home/Utilities/Bay Water/2026/bill.pdf"
    static let water28 = root + "/Home/Utilities/Bay Water/2028/bill.pdf"

    static let alma = VaultAddress(street: "410 Alma St", unit: "Apt 6", city: "Palo Alto", state: "CA", zip: "94301")
    static let larkspur = VaultAddress(street: "2841 Larkspur Ln", city: "San Jose", state: "CA", zip: "95132")
    static let brookside = VaultAddress(street: "88 Brookside Ct", city: "Fremont", state: "CA", zip: "94538")

    /// Anna's license (issued 2021, good to 2030) printing Alma Street, and a 2026 water bill,
    /// nobody's in particular, mailed to Larkspur Lane.
    static let barcode = [
        "@", "ANSI 636014090002DL00410278ZC03190024DLDAQD1234567", "DCSERIKSSON", "DACANNA",
        "DBD05162021", "DBB08121974", "DBA05162030", "DAG410 ALMA ST", "DAHAPT 6", "DAIPALO ALTO", "DAJCA",
        "DAK94301", "DCGUSA",
    ]
    static func bill(_ street: String, _ city: String) -> [String] {
        ["Account Number: 58210 44719 00", "ANNA ERIKSSON", street, city, "Amount Due $41.10"]
    }

    static func model(_ rig: Rig, extra: [String: [String]] = [:]) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = people
        await model.opened()
        var pages = [license: barcode, water: bill("2841 LARKSPUR LN", "SAN JOSE CA 95132")]
        pages.merge(extra) { $1 }
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: pages))
        // Erik's only ID is typed: he has a section, and no paper of his prints an address.
        _ = model.add(VaultModel.Draft(title: "Car loan", value: "0044918853", personID: "erik", category: .loans))
        return model
    }

    static func section(_ model: VaultModel, _ id: String) throws -> VaultPersonSection {
        try #require(model.peopleSections.first { $0.id == .person(id) })
    }

    // MARK: Addresses read

    @Test func theNewestPaperLeadsAndTheHouseholdsBillCountsForEveryone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.rows.first { $0.category == .utilities }?.isHousehold == true, "the bill is the household's")
        let anna = try Self.section(model, "anna")
        #expect(anna.addresses.map(\.address) == [Self.larkspur, Self.alma],
                "the 2026 bill before the 2021 license")
        #expect(anna.home?.rows.map(\.category) == [.utilities])
        #expect(anna.pastAddresses.first?.rows.map(\.category) == [.driversLicense])
        #expect(anna.home?.dated == VaultReadingTests.day(2026, 1, 1))
        // Erik has no papers that print an address; the household's is his home too.
        #expect(try Self.section(model, "erik").addresses.map(\.address) == [Self.larkspur])
    }

    @Test func aLicenseOnCurrentStillPrintingAPastAddressIsFlagged() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(try Self.section(model, "anna").licenseDiffers?.address == Self.alma)
        // A license printing where they live now is not.
        let fresh = Self.barcode.map { $0.hasPrefix("DAG") ? "DAG2841 LARKSPUR LN" : $0.hasPrefix("DAI") ? "DAISAN JOSE" : $0.hasPrefix("DAK") ? "DAK95132" : $0 }
            .filter { !$0.hasPrefix("DAH") }
        let rig2 = try Rig(); defer { rig2.cleanUp() }
        let model2 = await Self.model(rig2, extra: [Self.license: fresh])
        let anna = try Self.section(model2, "anna")
        #expect(anna.licenseDiffers == nil && anna.addresses.count == 1)
        #expect(anna.home?.rows.count == 2, "the license and the bill print one address, however each spells it")
    }

    @Test func anAddressSaidNotTheirsIsLeftOutAndForEveryoneWhenTheHouseholdsPapersGaveIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.removeAddress(Self.alma.key, for: "anna", read: true)
        #expect(try Self.section(model, "anna").addresses.map(\.address) == [Self.larkspur])
        model.removeAddress(Self.larkspur.key, for: "anna", read: true, everyone: true)
        #expect(try Self.section(model, "anna").addresses.isEmpty)
        #expect(try Self.section(model, "erik").addresses.isEmpty, "a Household paper's address goes for everyone")
    }

    // MARK: Typed

    @Test func aTypedAddressLeadsUntilALaterPaperPrintsAnother() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        // Typed on the rig's day, in 2027: after the 2026 bill.
        #expect(model.setAddress(Self.brookside, for: "anna"))
        var anna = try Self.section(model, "anna")
        #expect(anna.home?.address == Self.brookside && anna.home?.typed == true)
        #expect(anna.home.map { VaultPersonText.sourceLine($0.rows, typed: $0.typed, dated: $0.dated) } == "From you · Jan 2027")
        #expect(anna.pastAddresses.map(\.address) == [Self.larkspur, Self.alma])
        // A 2028 bill mailed elsewhere is newer still: it leads, and the typed one is past.
        let rig2 = try Rig(); defer { rig2.cleanUp() }
        let later = await Self.model(rig2, extra: [Self.water28: Self.bill("12 N 1ST ST", "SAN JOSE CA 95112")])
        later.setAddress(Self.brookside, for: "anna")
        anna = try Self.section(later, "anna")
        #expect(anna.home?.address.street == "12 N 1st St", "\(anna.addresses.map(\.address))")
        #expect(anna.addresses.dropFirst().first?.address == Self.brookside)
    }

    @Test func aNewAddressIsOfferedForOthersAndCorrectingOneSetsTheReadOneAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.setAddress(Self.brookside, for: "anna", alsoFor: ["erik"]))
        #expect(try Self.section(model, "erik").home?.address == Self.brookside, "Same for: Erik")
        // Edit… on the license's address: what was read is set aside, the corrected one typed.
        let fixed = VaultAddress(street: "410 Alma Street", unit: "Apt 8", city: "Palo Alto", state: "CA", zip: "94306")
        #expect(model.setAddress(fixed, for: "anna", replacing: Self.alma.key))
        let keys = try Self.section(model, "anna").addresses.map(\.address.key)
        #expect(!keys.contains(Self.alma.key) && keys.contains(fixed.key))
        #expect(model.contacts["anna"]?.notTheirs == [Self.alma.key])
        // An incomplete address is refused.
        #expect(!model.setAddress(VaultAddress(street: "Larkspur", city: "San Jose", state: "CA", zip: "95132"), for: "anna"))
        #expect(!model.setAddress(VaultAddress(street: "1 Main St", city: "San Jose", state: "ZZ", zip: "95132"), for: "anna"))
    }

    @Test func phonesAndEmailsAreTypedEditedAndRemovedAndShowAtOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = model.peopleSections
        #expect(model.setPhone("408 555 0142", label: "Mobile", for: "anna"))
        #expect(try Self.section(model, "anna").phones.map(\.value) == ["408 555 0142"], "the cached sections see it at once")
        #expect(model.setPhone("+91 98450 12345", label: "Home", for: "anna"))
        #expect(model.setPhone("(650) 555-0199", label: "Work", for: "anna", replacing: 1))
        #expect(try Self.section(model, "anna").phones.map(\.label) == ["Mobile", "Work"])
        model.removePhone(at: 0, for: "anna")
        #expect(try Self.section(model, "anna").phones.map(\.value) == ["(650) 555-0199"])
        #expect(!model.setPhone("call me", label: nil, for: "anna"), "not a number")
        #expect(model.setEmail("anna@example.com", label: "Personal", for: "anna"))
        #expect(!model.setEmail("anna at example", label: nil, for: "anna"))
        #expect(try Self.section(model, "anna").emails.map(\.value) == ["anna@example.com"])
        #expect(try Self.section(model, "erik").phones.isEmpty)
    }

    @Test func typedContactsAreSealedWithWhatWasReadAndOutliveAChangeOfRules() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.setPhone("408 555 0142", label: "Mobile", for: "anna")
        model.setAddress(Self.brookside, for: "erik")
        let again = rig.model()
        again.people = Self.people
        await again.opened()
        #expect(try Self.section(again, "anna").phones.map(\.value) == ["408 555 0142"], "read back from the sealed file")
        #expect(again.contacts["erik"]?.addresses.map(\.address) == [Self.brookside])
        #expect(!rig.defaults.dictionaryRepresentation().values.contains { "\($0)".contains("555") || "\($0)".contains("Brookside") },
                "nothing typed goes to preferences")
        // A reading file of another build's rules lets what was read go, never what was typed.
        var state = try #require(rig.store.readingOnDisk())
        state.version = VaultReading.version - 1
        try rig.store.writeReadingOnDisk(state)
        let older = rig.model()
        older.people = Self.people
        await older.opened()
        #expect(older.contacts["anna"]?.phones.map(\.value) == ["408 555 0142"])
    }

    @Test func nothingIsTypedWhileTheVaultIsShut() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        #expect(!model.setPhone("408 555 0142", label: nil, for: "anna"))
        #expect(model.contacts.isEmpty)
    }

    // MARK: Archive

    @Test func archiveShowsSomeoneWithPastAddressesThoughNoIDOfTheirsIsThere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.setAddress(Self.brookside, for: "erik")
        model.tab = .archive
        let erik = try Self.section(model, "erik")
        #expect(erik.rows.isEmpty && erik.pastAddresses.map(\.address) == [Self.larkspur])
        model.query = "license"
        #expect(!model.peopleSections.contains { $0.id == .person("erik") }, "not under a search")
        model.query = ""
        model.personFilter = .person("anna")
        #expect(!model.peopleSections.contains { $0.id == .person("erik") }, "nor when the filter is someone else")
    }

    // MARK: A backup

    @Test func aBackupKeepsWhatWasTypedAndAReplacePutsItBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultBackupTests.mortgage])
        let folder = VaultBackupTests.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = VaultBackupTests.backup(rig, folder: folder)
        try backup.setPassphrase(VaultBackupTests.phrase)
        let typed = ["anna": VaultContacts(phones: [.init("408 555 0142", label: "Mobile", added: VaultLockTests.t0)],
                                            addresses: [.init(Self.brookside, added: VaultLockTests.t0)],
                                            notTheirPhones: ["6505550100"])]
        let url = try await backup.write([VaultBackupTests.mortgage], contacts: typed)
        let contents = try await backup.read(url).get()
        #expect(contents.contacts == typed)
        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(rig.store.readingOnDisk()?.contacts == typed, "beside what will be read again")
        // Add Missing keeps what is here and adds what the backup has that is not.
        var here = try #require(rig.store.readingOnDisk())
        here.contacts = ["anna": VaultContacts(emails: [.init("anna@example.com", added: VaultLockTests.t0)])]
        try rig.store.writeReadingOnDisk(here)
        #expect(await backup.restore(contents, mode: .addMissing) == .success(1))
        let merged = try #require(rig.store.readingOnDisk()?.contacts?["anna"])
        #expect(merged.emails.map(\.value) == ["anna@example.com"] && merged.phones.map(\.value) == ["408 555 0142"])
        #expect(merged.notTheirPhones == ["6505550100"], "a phone set aside stays set aside")
        // Add Missing takes a phone typed here however it is written: one phone, not two.
        var spaced = try #require(rig.store.readingOnDisk())
        spaced.contacts = ["anna": VaultContacts(phones: [.init("(408) 555-0142", added: VaultLockTests.t0)])]
        try rig.store.writeReadingOnDisk(spaced)
        #expect(await backup.restore(contents, mode: .addMissing) == .success(1))
        #expect(rig.store.readingOnDisk()?.contacts?["anna"]?.phones.map(\.value) == ["(408) 555-0142"])
    }

    @Test func aBackupMadeBeforeContactsStillOpens() throws {
        let old = #"{"version":1,"madeAt":0,"entries":[]}"#
        let contents = try JSONDecoder().decode(VaultBackupContents.self, from: Data(old.utf8))
        #expect(contents.contacts == nil && contents.entries.isEmpty)
    }

    // MARK: Words

    @Test func phonesAreShownTheUSWayAndAnythingElseAsTyped() {
        #expect(VaultContacts.phoneShown("4085550142") == "(408) 555-0142")
        #expect(VaultContacts.phoneShown("+1 408-555-0142") == "(408) 555-0142")
        #expect(VaultContacts.phoneShown("+91 98450 12345") == "+91 98450 12345")
        #expect(VaultContacts.phoneShown("555-0142") == "555-0142")
        #expect(VaultContacts.phoneShown("408 555 0142 ext 9") == "408 555 0142 ext 9")
    }

    @Test func everySourceLineIsFromWhereAndWhen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let anna = try Self.section(model, "anna")
        #expect(VaultPersonText.sourceLine(anna.names[0].rows) == "From Driver’s license")
        let past = try #require(anna.pastAddresses.first)
        #expect(VaultPersonText.sourceLine(past.rows, typed: past.typed, dated: past.dated) == "From Driver’s license · May 2021")
        let home = try #require(anna.home)
        #expect(VaultPersonText.sourceLine(home.rows + past.rows, dated: home.dated) == "From 2 IDs · Jan 2026")
        #expect(VaultPersonText.sourceLine([], typed: true) == "From you")
        #expect(VaultPersonText.sourceLine([]) == "From People")
    }
}

// MARK: Phones read

extension VaultContactsTests {
    /// The household's water bill, mailed to Anna, printing her cell phone and the utility's own.
    static let billWithPhones = ["Account Number: 58210 44719 00", "ANNA ERIKSSON", "2841 LARKSPUR LN", "SAN JOSE CA 95132",
                                 "Cell: (408) 555-0142", "Customer Service: (408) 555-0199"]

    @Test func aPhoneReadUnderTheirNameIsTheirsWhoeverOwnsThePaper() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        let phone = try #require(try Self.section(model, "anna").phones.first)
        #expect(try Self.section(model, "anna").phones.count == 1, "never the utility's own")
        #expect(phone.shown == "(408) 555-0142" && phone.label == "Mobile" && !phone.typed)
        #expect(phone.rows.map(\.category) == [.utilities] && phone.rows.allSatisfy(\.isHousehold),
                "the bill is the household's; the phone is hers, by the name it is printed under")
        #expect(try Self.section(model, "erik").phones.isEmpty)
        let card = try #require(VaultContactCardsTests.card(model, .phones))
        #expect(card.items.map(\.value) == ["(408) 555-0142"] && card.items.first?.phone?.rows.count == 1)
    }

    @Test func typingAPhoneTheirPapersPrintIsOnePhone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        #expect(model.setPhone("408.555.0142", label: "Work", for: "anna"))
        let phones = try Self.section(model, "anna").phones
        #expect(phones.count == 1 && phones[0].typed && phones[0].label == "Work" && phones[0].rows.count == 1)
    }

    @Test func notTheirPhoneSetsAReadPhoneAsideAndTypingItBringsItBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        let phone = try #require(try Self.section(model, "anna").phones.first)
        model.removePhone(at: phone.typedIndex, read: phone.key, for: "anna")
        #expect(try Self.section(model, "anna").phones.isEmpty)
        #expect(model.contacts["anna"]?.notTheirPhones == ["4085550142"])
        #expect(VaultContactCardsTests.card(model, .phones) == nil)
        model.setPhone("(408) 555-0142", label: "Mobile", for: "anna")
        #expect(try Self.section(model, "anna").phones.map(\.rows.count) == [1], "typed, and printed on the bill again")
        #expect(model.contacts["anna"]?.notTheirPhones == [])
    }

    @Test func correctingAReadPhoneSetsTheMisreadAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        #expect(model.setPhone("(408) 555-0143", label: "Mobile", for: "anna", correcting: "4085550142"))
        #expect(try Self.section(model, "anna").phones.map(\.shown) == ["(408) 555-0143"])
    }

    @Test func givingAReadPhoneALabelKeepsThePapersPhone() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        #expect(model.setPhone("408-555-0142", label: "Home", for: "anna", correcting: "4085550142"))
        #expect(model.contacts["anna"]?.notTheirPhones == [])
        let phones = try Self.section(model, "anna").phones
        #expect(phones.count == 1 && phones[0].typed && phones[0].label == "Home" && phones[0].rows.count == 1)
    }

    @Test func contactsSavedBeforePhonesWereReadDecode() throws {
        let old = try JSONDecoder().decode(VaultContacts.self, from: Data(#"{"phones":[]}"#.utf8))
        #expect(old.notTheirPhones.isEmpty && old.isEmpty)
    }

    @Test func onePhoneHoweverWritten() {
        #expect(VaultContacts.phoneKey("+1 (408) 555-0142") == VaultContacts.phoneKey("408.555.0142"))
        #expect(VaultContacts.phoneKey("+91 98450 12345") == "919845012345")
    }
}

// MARK: The review of 19bd3fa90

extension VaultContactsTests {
    @Test func aNumberTypedTwiceIsOnePhoneThatRemoveTakesOut() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        model.setPhone("(408) 555-0142", label: "Mobile", for: "anna")
        model.setPhone("408.555.0142", label: "Work", for: "anna")
        #expect(model.contacts["anna"]?.phones.map(\.label) == ["Work"], "typed again, it takes the first one's place")
        model.setPhone("(650) 555-0199", label: "Home", for: "anna")
        // Edited into the number of another typed phone: one phone.
        model.setPhone("(408) 555-0142", label: "Home", for: "anna", replacing: 1)
        #expect(model.contacts["anna"]?.phones.map(\.value) == ["(408) 555-0142"])
        let phone = try #require(try Self.section(model, "anna").phones.first)
        model.removePhone(at: phone.typedIndex, read: nil, for: "anna")
        #expect(try Self.section(model, "anna").phones.isEmpty)
    }

    @Test func typedPhonesLeadInTheOrderTypedAndAnEditMovesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // A paper dated long after anything typed: it still comes after what was typed.
        let later = Self.root + "/Home/Utilities/Bay Water/2099/bill.pdf"
        let model = await Self.model(rig, extra: [later: Self.billWithPhones])
        model.setPhone("(650) 555-0101", label: "Mobile", for: "anna")
        model.setPhone("(650) 555-0102", label: "Work", for: "anna")
        let read = try #require(try Self.section(model, "anna").phones.last)
        #expect(read.dated.map { $0 > model.contacts["anna"]!.phones[1].added } == true, "the paper is the newest")
        #expect(try Self.section(model, "anna").phones.map(\.shown) == ["(650) 555-0101", "(650) 555-0102", "(408) 555-0142"],
                "typed first, in the order typed; the paper's after")
        model.setPhone("(650) 555-0102", label: "Home", for: "anna", replacing: 1)
        model.setPhone("(650) 555-0101", label: "Work", for: "anna", replacing: 0)
        #expect(try Self.section(model, "anna").phones.map(\.shown) == ["(650) 555-0101", "(650) 555-0102", "(408) 555-0142"])
    }

    @Test func notTheirPhoneOnATypedAndPrintedPhoneTakesBothOut() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        model.setPhone("(408) 555-0142", label: "Mobile", for: "anna")
        let phone = try #require(try Self.section(model, "anna").phones.first)
        #expect(phone.typed && phone.rows.count == 1)
        model.removePhone(at: phone.typedIndex, read: phone.key, for: "anna")
        #expect(try Self.section(model, "anna").phones.isEmpty)
    }

    @Test func aTypedPhoneEditedToAnotherNumberSetsThePapersAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        model.setPhone("(408) 555-0142", label: "Mobile", for: "anna")
        let phone = try #require(try Self.section(model, "anna").phones.first)
        // The panel's Edit… on a phone papers print passes its key (VaultPanel.startContactEdit).
        model.setPhone("(408) 555-0143", label: "Mobile", for: "anna", replacing: phone.typedIndex, correcting: phone.key)
        #expect(try Self.section(model, "anna").phones.map(\.shown) == ["(408) 555-0143"])
    }

    @Test func aTypedExtensionIsTheSamePhoneThePaperPrints() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig, extra: [Self.water: Self.billWithPhones])
        model.setPhone("408-555-0142 x23", label: "Work", for: "anna")
        let phones = try Self.section(model, "anna").phones
        #expect(phones.count == 1 && phones[0].rows.count == 1 && phones[0].value == "408-555-0142 x23")
        #expect(VaultContacts.phoneKey("408-555-0142 ext. 23") == "4085550142")
    }
}
