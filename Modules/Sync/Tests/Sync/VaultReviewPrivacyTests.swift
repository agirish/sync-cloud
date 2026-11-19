import Foundation
import Testing
@testable import Sync

/// What the review of the whole Vault on 2026-11-19 found about what reaches the screen and the
/// log: file names whose number came through the mask, and types that printed what they hold.
@Suite struct VaultReviewPrivacyTests {
    @Test func aNumberWrittenWithOtherSeparatorsIsMaskedInAFileName() {
        // Only the last four stay, as everywhere a number is drawn hidden.
        let expected = [
            "SSN 123 - 45 - 6789.pdf": "••• ••• - •• - 6789.pdf",
            "Aadhaar 2345  6789  0123.pdf": "Aadhaar ••••  ••••  0123.pdf",
            "Aadhaar 2345,6789,0123.pdf": "Aadhaar ••••,••••,0123.pdf",
            "SSN 123+45+6789.pdf": "••• •••+••+6789.pdf",
            "Phone (123) 45 6789.pdf": "Phone (•••) •• 6789.pdf",
            "DL D123 4567 8901.pdf": "DL •••• •••• 8901.pdf",
        ]
        for (name, masked) in expected {
            #expect(VaultMask.fileName("/Docs/" + name) == masked)
        }
        // What was kept before still is.
        #expect(VaultMask.fileName("/Docs/I-797A WAC2412345678 approval.pdf") == "I-797A •••••••••5678 approval.pdf")
        #expect(VaultMask.fileName("/Docs/Form I-94 - Anna - Apr 2026.pdf") == "Form I-94 - Anna - Apr 2026.pdf")
        #expect(VaultMask.fileName("/Docs/Driver License - Anna (2019).pdf") == "Driver License - Anna (2019).pdf")
    }

    @Test func nothingThatHoldsANumberPrintsIt() {
        let path = "/Docs/Passport A38291647/scan.pdf"
        let source = VaultSource(path: path, role: "Passport photo page", rank: 40)
        let facts = VaultReadFacts(category: .passport, holder: "Anna Eriksson", inPassport: "A38291647",
                                   details: [VaultDetail("In passport", .number("A38291647"))], sources: [source])
        let mention = VaultMention(value: "A38291647", category: .passport, source: source)
        let input = VaultStandingInput(id: UUID(), value: "A38291647", category: .passport, facts: facts, pin: nil)
        let draft = VaultModel.Draft(title: "Passport", value: "A38291647")
        let printed: [String] = [
            "\(facts)", String(reflecting: facts), "\(source)", "\(facts.details[0])", "\(mention)", "\(input)",
            "\(draft)", String(reflecting: draft),
        ]
        var dumped = ""
        dump(facts, to: &dumped)
        dump(input, to: &dumped)
        for line in printed + [dumped] {
            #expect(!line.contains("38291647"), "\(line) shows the number")
            #expect(!line.contains("Eriksson"), "\(line) shows the holder")
            #expect(!line.contains("/Docs"), "\(line) shows the path")
        }
    }
}
