import Foundation
import Testing
@testable import Sync

/// Where a number is never printed: logs, file names, descriptions of a type.
@Suite struct VaultPrivacyTests {
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
        // And those that were held in full and printed so (VT28).
        let value = VaultDetail.Value.number("A38291647")
        let change = VaultChange(label: "In passport", was: .number("A38291640"), now: value)
        let find = VaultFind(title: "Passport", value: "A38291647", facts: facts)
        let state = VaultReadingState(finds: [find], read: [path: "1 2"], mentions: ["A38291647": [source]],
                                      names: ["ANNAERIKSSON": "Anna Eriksson"])
        let choice = VaultChoice(id: find.id, pin: .current, assignment: .household, source: path)
        let printed: [String] = [
            "\(facts)", String(reflecting: facts), "\(source)", "\(facts.details[0])", "\(mention)", "\(input)",
            "\(draft)", String(reflecting: draft), "\(value)", String(reflecting: value), "\(change)",
            "\(state)", "\(choice)", "\(find)", String(reflecting: choice), String(reflecting: find),
            String(reflecting: state), String(reflecting: change), "\(VaultDetail.Value.text("Anna Eriksson"))",
            "\(choice.choices)", String(reflecting: choice.choices),
        ]
        var dumped = ""
        dump(facts, to: &dumped)
        dump(input, to: &dumped)
        dump(change, to: &dumped)
        dump(state, to: &dumped)
        dump([value], to: &dumped)
        dump(choice, to: &dumped)
        dump(choice.choices, to: &dumped)
        dump(find, to: &dumped)
        dump(VaultDetail.Value.text("Anna Eriksson"), to: &dumped)
        for line in printed + [dumped] {
            #expect(!line.contains("38291647"), "\(line) shows the number")
            #expect(!line.contains("Eriksson"), "\(line) shows the holder")
            #expect(!line.contains("/Docs"), "\(line) shows the path")
        }
    }

    /// A card's values, a number corrected by hand and the household's contact details print
    /// none of them (the 2026-11-23 review).
    @Test func contactDetailsAndCardValuesPrintNothingTheyHold() {
        let address = VaultAddress(street: "100 Example Street", unit: "Apt 6", city: "Testville", state: "CA", zip: "00001")
        let typed = VaultContacts.Typed("(408) 555-0142", label: "Mobile", added: Date(timeIntervalSince1970: 0))
        let contacts = VaultContacts(phones: [typed], emails: [VaultContacts.Typed("anna@example.com", added: Date(timeIntervalSince1970: 0))],
                                     addresses: [VaultContacts.TypedAddress(address, added: Date(timeIntervalSince1970: 0))])
        let card = VaultCardValue(label: "Member ID", value: "XZB123456789")
        let readAs = VaultReadAs(contents: "1 abc", reads: "A38291647")
        let backup = VaultBackupContents(madeAt: Date(timeIntervalSince1970: 0), entries: [], contacts: ["anna": contacts])
        let item = VaultContactCard.Item(id: "phone:0", kind: .phones, people: ["Anna"], value: "(408) 555-0142")
        let contactCard = VaultContactCard(kind: .phones, items: [item])
        let phone = VaultPersonSection.Phone(value: "(408) 555-0142", label: "Mobile")
        let home = VaultPersonSection.Address(address: address, dated: nil, rows: [], typed: true)
        let printed: [String] = ["\(address)", String(reflecting: address), "\(typed)", "\(contacts)", String(reflecting: contacts),
                                 "\(contacts.addresses[0])", "\(card)", String(reflecting: card), "\(readAs)", "\(backup)",
                                 "\(item)", "\(contactCard)", String(reflecting: item), "\(phone)", "\(home)"]
        var dumped = ""
        dump(contacts, to: &dumped)
        dump(card, to: &dumped)
        dump(readAs, to: &dumped)
        dump(backup, to: &dumped)
        dump(contactCard, to: &dumped)
        dump(phone, to: &dumped)
        dump(home, to: &dumped)
        for line in printed + [dumped] {
            for secret in ["2841", "Larkspur", "Testville", "00001", "555-0142", "anna@", "123456789", "38291647"] {
                #expect(!line.contains(secret), "\(line) shows \(secret)")
            }
        }
    }

    /// A person's section, its names and dates of birth (VT28), as People builds it.
    @Test @MainActor func aPersonsSectionPrintsNoNameOrDate() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        let model = await VaultPeopleViewTests.model(rig)
        let section = try #require(model.peopleSections.first { !$0.births.isEmpty })
        var dumped = ""
        dump(section, to: &dumped)
        dump(section.names, to: &dumped)
        dump(section.births, to: &dumped)
        #expect("\(section)" == "VaultPersonSection(\(section.rows.count) ID(s), \(section.names.count) name(s), \(section.births.count) date(s) of birth)")
        for line in ["\(section)", String(reflecting: section), "\(section.names)", "\(section.births)", dumped] {
            #expect(!line.contains("ERIKSSON") && !line.contains("Eriksson"), "\(line) shows a name")
            #expect(!line.contains("1974") && !line.contains("Aug"), "\(line) shows a date of birth")
        }
    }
}
