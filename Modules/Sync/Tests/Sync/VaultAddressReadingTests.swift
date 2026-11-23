import Foundation
import Testing
@testable import Sync

/// Home addresses read from papers (``VaultAddress``): a US license's barcode, and the mailing
/// block of an account paper. Every address and number here is made up.
@Suite struct VaultAddressReadingTests {
    static let anna = [Person(id: "anna", displayName: "Anna", fullNames: ["Anna Eriksson"])]
    static let bill = "/Users/anna/Documents/Home/Utilities/EBMUD/2025/Mar.pdf"

    static func read(_ lines: [String], at path: String = bill, people: [Person] = anna) -> [VaultFind] {
        VaultReading.read(pages: [lines], from: path, people: people).finds
    }

    static func address(_ lines: [String], at path: String = bill, people: [Person] = anna) -> VaultPrintedAddress? {
        read(lines, at: path, people: people).first?.facts.sources.first { $0.path == path }?.address
    }

    // MARK: The license

    static let barcode = [
        "@", "ANSI 636014090002DL00410278ZC03190024DLDAQD1234567", "DCSERIKSSON", "DACANNA",
        "DBD05162025", "DBB08121974", "DBA05162030", "DAG2841 LARKSPUR LN", "DAISAN JOSE", "DAJCA",
        "DAK951320000  ", "DCGUSA",
    ]

    @Test func aLicenseBarcodeGivesItsHomeAddressDatedItsIssue() throws {
        let find = try #require(VaultIDReadingTests.read(Self.barcode).first)
        #expect(find.value == "D1234567", "the number reads as before")
        let printed = try #require(find.facts.primary?.address)
        #expect(printed.address == VaultAddress(street: "2841 LARKSPUR LN", city: "SAN JOSE", state: "CA", zip: "95132"))
        #expect(printed.dated == VaultReadingTests.day(2025, 5, 16))
    }

    @Test func aLicenseBarcodeKeepsItsSecondStreetLineAsTheUnit() throws {
        let find = try #require(VaultIDReadingTests.read(Self.barcode + ["DAHAPT 6"]).first)
        #expect(find.facts.primary?.address?.address.unit == "APT 6")
    }

    @Test func aLicenseBarcodeGivesNoAddressItCannotStateWhole() {
        // No ZIP; a P.O. Box; a Canadian licence.
        let noZip = Self.barcode.filter { !$0.hasPrefix("DAK") }
        let box = Self.barcode.map { $0.hasPrefix("DAG") ? "DAGPO BOX 12" : $0 }
        let canadian = Self.barcode.map { $0 == "DCGUSA" ? "DCGCAN" : $0 }
        for lines in [noZip, box, canadian, VaultIDReadingTests.barcode] {
            let find = VaultIDReadingTests.read(lines).first
            #expect(find != nil && find?.facts.primary?.address == nil, "\(lines)")
        }
    }

    // MARK: Account papers

    static let mailed = ["EBMUD", "Account Number: 1234 5678 9012", "ANNA ERIKSSON", "2841 LARKSPUR LN APT 6",
                         "SAN JOSE CA 95132-1234", "Amount Due $86.20"]

    @Test func anAccountPapersMailingBlockIsItsAddressDatedThePaper() throws {
        let printed = try #require(Self.address(Self.mailed))
        #expect(printed.address == VaultAddress(street: "2841 LARKSPUR LN", unit: "APT 6", city: "SAN JOSE",
                                                state: "CA", zip: "95132"))
        #expect(printed.dated == VaultReadingTests.day(2025, 1, 1), "the year folder's date, as the number's")
    }

    @Test func eachAccountNumberOnThePaperGetsItsAddress() {
        let finds = Self.read(Self.mailed + ["Policy Number: 7788 9900 1122"])
        #expect(finds.count == 2)
        #expect(finds.allSatisfy { $0.facts.primary?.address?.address.zip == "95132" })
    }

    @Test func aUnitOnItsOwnLineAndACommaCityAreRead() throws {
        let lines = ["Account Number: 1234 5678 9012", "Anna Eriksson", "410 Alma Street", "Apt 6", "Palo Alto, CA 94301"]
        let printed = try #require(Self.address(lines))
        #expect(printed.address == VaultAddress(street: "410 Alma Street", unit: "Apt 6", city: "Palo Alto",
                                                state: "CA", zip: "94301"))
    }

    @Test func aBlockWithNobodyFromPeopleAboveItIsNotAHome() {
        // The utility's own address, under its name.
        let issuer = ["Account Number: 1234 5678 9012", "East Bay Municipal Utility District", "375 11th Street",
                      "Oakland, CA 94607"]
        #expect(Self.address(issuer) == nil)
        #expect(Self.address(Self.mailed, people: []) == nil, "with nobody in People, nothing is read")
    }

    @Test func aServiceOrPaymentAddressIsNotTheHome() {
        for cue in ["Service Address:", "Remit to:", "Make checks payable to"] {
            let lines = ["Account Number: 1234 5678 9012", cue, "ANNA ERIKSSON", "88 BROOKSIDE CT", "FREMONT CA 94538"]
            #expect(Self.address(lines) == nil, "\(cue)")
        }
    }

    @Test func aPostOfficeBoxIsNeverAHome() {
        for street in ["PO BOX 1234", "P.O. Box 1234"] {
            let lines = ["Account Number: 1234 5678 9012", "ANNA ERIKSSON", street, "SAN JOSE CA 95132"]
            #expect(Self.address(lines) == nil, "\(street)")
        }
    }

    @Test func aPaperOutsideTheAccountsAreasGivesNoAddress() {
        #expect(Self.read(Self.mailed, at: "/Users/anna/Documents/Immigration/H-1B/Petition.pdf").isEmpty)
    }

    // MARK: One address however printed

    @Test func twoPrintingsOfOneHomeShareAKey() {
        let caps = VaultAddress(street: "2841 LARKSPUR LN", city: "SAN JOSE", state: "CA", zip: "95132")
        let mixed = VaultAddress(street: "2841 Larkspur Lane", unit: "Apt 6", city: "San Jose", state: "CA", zip: "95132")
        #expect(caps.key == mixed.key)
        #expect(caps.key != VaultAddress(street: "2843 Larkspur Lane", city: "San Jose", state: "CA", zip: "95132").key)
        #expect(caps.key != VaultAddress(street: "2841 Larkspur Lane", city: "San Jose", state: "CA", zip: "95133").key)
        // A direction is not the street's name.
        #expect(VaultAddress(street: "12 N 1st St", city: "San Jose", state: "CA", zip: "95112").key == "12 1st 95112")
    }

    @Test func capitalsAreTidiedAndMixedCaseKept() {
        let caps = VaultAddress(street: "2841 LARKSPUR LN", unit: "APT 6", city: "SAN JOSE", state: "ca", zip: "95132")
        #expect(caps.tidied.oneLine == "2841 Larkspur Ln, Apt 6, San Jose, CA 95132")
        let mixed = VaultAddress(street: "2841 Larkspur Lane", city: "San Jose", state: "CA", zip: "95132")
        #expect(mixed.tidied == mixed)
        #expect(mixed.isTidier(than: caps) && !caps.isTidier(than: mixed))
    }

    @Test func aSourceSavedBeforeAddressesDecodes() throws {
        let old = #"{"path":"/a.pdf","role":"Account paper","rank":3}"#
        let source = try JSONDecoder().decode(VaultSource.self, from: Data(old.utf8))
        #expect(source.path == "/a.pdf" && source.address == nil)
    }
}

extension VaultAddressReadingTests {
    /// A saved ID's facts keep their sources; today's reading of the same file brings its address.
    @Test func aSavedSourceTakesTheAddressTodaysReadingOfTheFileGives() {
        let printed = VaultPrintedAddress(VaultAddress(street: "2841 Larkspur Lane", city: "San Jose", state: "CA",
                                                       zip: "95132"), dated: nil)
        var saved = VaultReadFacts(category: .utilities, sources: [VaultSource(path: "/a.pdf", role: "Account paper", rank: 3)])
        saved.add(VaultSource(path: "/a.pdf", role: "Account paper", rank: 3, address: printed))
        #expect(saved.sources.count == 1 && saved.sources[0].address == printed)
        // A better reading of the file that gives none keeps the one already known.
        saved.add(VaultSource(path: "/a.pdf", role: "ID card", rank: 9))
        #expect(saved.sources[0].role == "ID card" && saved.sources[0].address == printed)
    }
}
