import Foundation
import Testing
@testable import Sync

/// A family's ID card: one row per person, each with its own number and birth date, as a
/// health plan's travel card prints them. Every number is made up.
@MainActor
@Suite struct VaultFamilyCardTests {
    typealias Rig = VaultModelTests.Rig
    typealias PlannedDocuments = VaultAccountModelTests.PlannedDocuments

    static let root = "/Users/anna/Documents"
    static let card = root + "/Health/Medical/Insurance/ID Cards/Travel Card - Family.pdf"
    /// As a text layer gives the card: each row's label line, then its number and birth date.
    static let page = ["Peace of mind when you travel",
                       "Pref x Medical Record No./ID Date o Birth", "11 0012345678 02/03/1980", "Region", "Northern California",
                       "Pref x Medical Record No./ID Date o Birth", "11 0012345690 08/12/1974", "Region", "Northern California"]

    static func read(_ lines: [String]) -> [VaultFind] { VaultReading.finds(in: lines, from: card) }

    @Test func everyRowIsReadWithItsOwnBirthDate() throws {
        let finds = Self.read(Self.page)
        #expect(finds.map(\.value) == ["11 0012345678", "11 0012345690"], "the second person's row is read too")
        #expect(finds.map(\.facts.born) == [VaultReadingTests.day(1980, 2, 3), VaultReadingTests.day(1974, 8, 12)])
        #expect(finds.allSatisfy { $0.holder == nil }, "no one name is every row's")
    }

    @Test func oneRowWithABirthDateKeepsIt() throws {
        let find = try #require(Self.read(["Medical Record No. Date of Birth", "12345678 07/11/1988"]).first)
        #expect(find.value == "12345678" && find.facts.born == VaultReadingTests.day(1988, 7, 11))
        // A row whose label names no birth date takes none from a date beside the number.
        let other = try #require(Self.read(["Member ID: 87654321 01/09/2025"]).first)
        #expect(other.facts.born == nil)
    }

    @Test func aNumberPrintedTwiceWithoutBirthDatesIsReadOnce() {
        // The same label twice, as a statement prints the account at its head and foot.
        let finds = VaultReading.finds(in: ["Member ID: XZB123456789", "Questions?", "Member ID: XZB999999999"],
                                       from: Self.root + "/Health/Dental/ID Cards/card.pdf")
        #expect(finds.map(\.value) == ["XZB123456789"])
    }

    @Test func eachRowGoesToThePersonBornThatDay() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        // Anna's passport, born 12 August 1974, and the family card.
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.root + "/Immigration/Passport/Anna/scan.pdf": VaultToConfirmTests.passportPage,
            Self.card: Self.page,
        ]))
        let anna = try #require(model.rows.first { $0.value == "11 0012345690" })
        #expect(anna.facts?.holder?.hasPrefix("Anna") == true, "the row born on Anna's birthday is Anna's")
        let other = try #require(model.rows.first { $0.value == "11 0012345678" })
        #expect(other.facts?.holder == nil, "the other row is nobody's the Vault knows yet")
    }
}
