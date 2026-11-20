import Foundation
import Testing
@testable import Sync

/// Which copy of a number speaks for it, and what the others lend it (``VaultCopies``).
@Suite struct VaultCopiesTests {
    @Test func aReceiptAndItsApprovalInOneFileReadAsTheApproval() throws {
        let receipt = ["I-797C Receipt Notice", "Receipt Number WAC2690123456", "Form I-129",
                       "Beneficiary ERIKSSON, ANNA", "Received Date 01/05/2026"]
        let approval = ["I-797A Approval Notice", "Receipt Number WAC2690123456", "Form I-129",
                        "Notice Date 07/10/2026", "Valid from 10/01/2026 to 09/30/2029"]
        let find = try #require(VaultReading.read(pages: [receipt, approval], from: "/n.pdf").finds.first)
        #expect(find.facts.primary?.role == "I-797A approval")
        #expect(!find.facts.pending)
        #expect(find.validUntil == VaultFixtures.day(2029, 9, 30))
        #expect(find.holder == "Anna Eriksson", "the receipt's name was not kept")
    }

    @Test func aRenewedCardNeverBorrowsTheExpiryOrDetailsOfTheOneItReplaced() throws {
        func find(_ details: [VaultDetail], dated: Date, until: Date?, path: String) -> VaultFind {
            VaultFind(title: "Driver’s license · CA", value: "D1234567", note: "",
                      facts: VaultReadFacts(category: .driversLicense, issuer: "USA", dated: dated, validUntil: until,
                                            details: details, sources: [VaultSource(path: path, role: "Driver’s license", rank: 40)]))
        }
        let renewed = find([VaultDetail("State", .text("CA")), VaultDetail("Issued", .date(VaultFixtures.day(2024, 12, 1)))],
                           dated: VaultFixtures.day(2024, 12, 1), until: nil, path: "/DL/new front.pdf")
        // The old card, from its barcode in Archive, ran out before the renewal was issued.
        let old = find([VaultDetail("Class", .text("C")), VaultDetail("Issued", .date(VaultFixtures.day(2019, 1, 3))),
                        VaultDetail("Valid until", .date(VaultFixtures.day(2024, 6, 30)))],
                       dated: VaultFixtures.day(2019, 1, 3), until: VaultFixtures.day(2024, 6, 30), path: "/DL/Archive/old back.pdf")
        let merged = try #require(VaultCopies.merged([old, renewed]))
        #expect(merged.facts.dated == VaultFixtures.day(2024, 12, 1), "the renewal speaks")
        #expect(merged.validUntil == nil, "the renewal took the old card's expiry, and showed as expired")
        #expect(merged.facts.details.map(\.label) == ["State", "Issued"])
    }

    @Test func aNewerExtensionStillLendsItsAdmitUntilToThePrintout() throws {
        // As read from the household's files on 2026-11-19: the printout speaks for the number but
        // prints no admit-until; the I-797A tear-offs that extended it carry one and no entry date.
        let printout = VaultFind(title: "I-94 admission number", value: "12345678901", note: "",
                                 facts: VaultReadFacts(category: .i94, dated: VaultFixtures.day(2015, 6, 1),
                                                       details: [VaultDetail("Class of admission", .text("F2")),
                                                                 VaultDetail("Entered", .date(VaultFixtures.day(2015, 6, 1)))],
                                                       sources: [VaultSource(path: "/I-94/printout.pdf", role: "CBP I-94 printout",
                                                                             rank: VaultReading.Rank.i94Printout)]))
        let tearOff = VaultFind(title: "I-94 admission number", value: "12345678901", note: "",
                                facts: VaultReadFacts(category: .i94, validUntil: VaultFixtures.day(2019, 8, 25),
                                                      details: [VaultDetail("Admitted until", .date(VaultFixtures.day(2019, 8, 25)))],
                                                      sources: [VaultSource(path: "/I-797/approval.pdf", role: "I-797A tear-off",
                                                                            rank: VaultReading.Rank.tearOff)]))
        let merged = try #require(VaultCopies.merged([printout, tearOff]))
        #expect(merged.validUntil == VaultFixtures.day(2019, 8, 25))
        #expect(merged.facts.details.map(\.label) == ["Admitted until", "Class of admission", "Entered"])
    }

    @Test func anEarlyRenewalSpeaksOverTheCardFiledInArchive() throws {
        let renewed = VaultFixtures.license([VaultDetail("State", .text("CA")), VaultDetail("Issued", .date(VaultFixtures.day(2024, 12, 1)))],
                                   dated: VaultFixtures.day(2024, 12, 1), until: nil, path: "/Legal/DL/front.pdf")
        // Renewed early: the old card runs out after the renewal was issued.
        let old = VaultFixtures.license([VaultDetail("Class", .text("C")), VaultDetail("Valid until", .date(VaultFixtures.day(2025, 3, 31)))],
                               dated: VaultFixtures.day(2019, 1, 3), until: VaultFixtures.day(2025, 3, 31), path: "/Legal/DL/Archive/old.pdf")
        let merged = try #require(VaultCopies.merged([old, renewed]))
        #expect(merged.facts.dated == VaultFixtures.day(2024, 12, 1))
        #expect(merged.validUntil == nil, "the renewal showed the old card's expiry")
        #expect(merged.facts.details.map(\.label) == ["State", "Issued"])
    }

    @Test func anUndatedScanOfTheOldCardLendsTheRenewalNothing() throws {
        let renewed = VaultFixtures.license([VaultDetail("Issued", .date(VaultFixtures.day(2024, 12, 1))),
                                    VaultDetail("Valid until", .date(VaultFixtures.day(2029, 12, 1)))],
                                   dated: VaultFixtures.day(2024, 12, 1), until: VaultFixtures.day(2029, 12, 1), path: "/Legal/DL/new.pdf")
        let old = VaultFixtures.license([VaultDetail("Restrictions", .text("Lenses")), VaultDetail("Valid until", .date(VaultFixtures.day(2025, 3, 31)))],
                               dated: nil, until: VaultFixtures.day(2025, 3, 31), path: "/Legal/DL/scan.pdf")
        let merged = try #require(VaultCopies.merged([renewed, old]))
        #expect(merged.facts.details.map(\.label) == ["Issued", "Valid until"])
    }
}
