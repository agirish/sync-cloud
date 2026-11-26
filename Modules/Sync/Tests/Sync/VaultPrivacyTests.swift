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

    /// A title is masked whole, as a file's name is, its slash kept (VT72): a slash with a space
    /// beside it parts the title unless digits stand either side and no year follows, one without
    /// joins a number as a dash does, and a date stays one.
    @Test func aTitleIsMaskedWholeWithItsSlash() {
        for title in ["Chase / Mortgage", "show H-1B / I-797", "Form 1040 / 2023", "W-2 / 2024", "I-94 / 2024",
                      "DS-160 / 2024", "Tax 2023 / 2024", "H-1B\u{00A0}/\u{00A0}I-797", "Chase/Mortgage",
                      "Lease 03/01/2024", "Statement 08/2024", "Lease 2024/2025", "24/7 Fitness", "1/2 share", ""] {
            #expect(VaultMask.text(title) == title)
        }
        #expect(VaultMask.text("Passport A38291647 / Anna") == "Passport •••••1647 / Anna")
        #expect(VaultMask.text("Loan 4417/9921/0038") == "Loan ••••/••••/0038")
        #expect(VaultMask.text("Loan 4417//9921//0038") == "Loan ••••//••••//0038")
        #expect(VaultMask.text("Loan 4417-/9921") == "Loan ••••-/9921")
        #expect(VaultMask.text("SSN 123 / 45 / 6789") == "••• ••• / •• / 6789")
        #expect(VaultMask.text("Card 4417 / 9921 / 0038 / 5512") == "Card •••• / •••• / •••• / 5512")
        #expect(VaultMask.text("Card 4417 9921 / 0038 5512") == "Card •••• •••• / •••• 5512")
        #expect(VaultMask.text("Card 4417 /9921") == "Card •••• /9921")
        // A slash without spaces masks as a space does in a file's name: "WAC" goes too.
        #expect(VaultMask.text("PAN ABCDE/1234/F") == "••• •••••/•234/F")
        #expect(VaultMask.text("Plate MH12/AB/1234") == "Plate ••••/••/1234")
        #expect(VaultMask.text("Passport 1234/A5678") == "Passport ••••/•5678")
        #expect(VaultMask.text("Receipt WAC/26/901/23456") == "Receipt •••/••/•••/•3456")
        // Without a slash, a title is masked exactly as a file of that name.
        for name in ["SSN 123 - 45 - 6789", "Aadhaar 2345,6789,0123", "DL D123 4567 8901", "I-797A WAC2412345678 approval",
                     "Form I-94 - Anna - Apr 2026", "Scan 2024-03-01", "Mortgage loan number"] {
            #expect(VaultMask.text(name) == VaultMask.fileName("/Docs/" + name))
        }
    }

    /// A kind whose ending is itself a secret prints none of it, as its row draws it locked
    /// (VT34): a Social Security number's last four are what a form asks for to prove who you are.
    @Test func aSecretEndingIsNeverPrinted() {
        let source = VaultSource(path: "/Docs/card.pdf", role: "Social Security card", rank: 40)
        let facts = VaultReadFacts(category: .ssn, sources: [source])
        let row = VaultModel.Row(id: UUID(), title: "SSN", value: "123-45-6789", note: "", category: .ssn, facts: facts,
                                 standing: VaultStanding(tab: .current), isSaved: true, personID: nil, whose: "Anna",
                                 pin: nil, assignment: nil, isHousehold: false)
        var dumped = ""
        dump(VaultModel.Correction(id: UUID(), file: "SSN 123456789.pdf", changed: 1), to: &dumped)
        dump(VaultPageSource.Reading(lines: ["123-45-6789"]), to: &dumped)
        dump(PrintedPage(["123-45-6789"]), to: &dumped)
        let printed = [
            "\(VaultEntry(title: "SSN", value: "123-45-6789", addedAt: Date(), facts: facts))",
            "\(VaultFind(title: "SSN", value: "123-45-6789", facts: facts))",
            "\(VaultMention(value: "123456789", category: .ssn, source: source))",
            "\(VaultStandingInput(id: UUID(), value: "123-45-6789", category: .ssn, facts: facts, pin: nil))",
            "\(VaultFind(title: "Aadhaar", value: "2345 6789 0123", facts: VaultReadFacts(category: .aadhaar, sources: [source])))",
            "\(row)",
            "\(VaultModel.Draft(title: "SSN", value: "123-45-6789", category: .ssn))",
            // Those that know no kind, which can hold one too.
            "\(VaultReadAs(contents: "1 2", reads: "123456789"))",
            "\(VaultDetail.Value.number("123456789"))",
            "\(VaultModel.Correction(id: UUID(), file: "SSN 123456789.pdf", changed: nil))",
            String(reflecting: VaultModel.Correction(id: UUID(), file: "SSN 123456789.pdf", changed: nil)),
            "\(VaultCardValue(label: "SSN", value: "123456789"))",
            "\(VaultPageSource.Reading(lines: ["SOCIAL SECURITY", "123-45-6789"]))",
            String(reflecting: PrintedPage(["SOCIAL SECURITY", "123-45-6789"])),
            dumped,
        ]
        for line in printed {
            // Its counts may print ("2 line(s)"); none of the number's own runs of digits.
            for secret in ["6789", "0123", "789", "123"] {
                #expect(!line.contains(secret), "\(line) shows the ending")
            }
        }
        // A passport's ending is not a secret: it is what the row shows locked.
        #expect("\(VaultFind(title: "Passport", value: "A38291647", facts: VaultReadFacts(category: .passport, sources: [source])))"
                .hasSuffix("•••••1647)"))
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
            // The address's own street and unit (the final review: the list named another's).
            for secret in ["Example Street", "Apt 6", "Testville", "00001", "555-0142", "anna@", "123456789", "38291647"] {
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

    /// The editor draws a number in full whatever the lock says: Add while the Vault is locked,
    /// and Edit "For every ID" once the list selects another row, keep the window out of
    /// capture (the final review).
    @Test @MainActor func theEditorKeepsTheWindowOutOfCaptureLockedOrNot() async throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        let entry = VaultEntry(title: "Passport", value: "Z0000009", addedAt: VaultRig.t0)
        try rig.seed([entry])
        let locked = rig.model()
        #expect(locked.contents != .loaded)
        #expect(locked.drawsAnIDInFull(layout: .cards, editing: true), "Add beside the lock")
        #expect(!locked.drawsAnIDInFull(layout: .cards, editing: false))

        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        let each = rig.model()
        await each.opened()
        try #require(each.contents == .loaded && !each.isOpen)
        each.selection = nil
        #expect(each.drawsAnIDInFull(layout: .cards, editing: true), "Edit with no row selected")
        #expect(!each.drawsAnIDInFull(layout: .cards, editing: false))
    }

    /// Every end of access takes a number copied from the Vault off the clipboard: a close as
    /// much as Lock Now or the Mac locking (the final review: a close left it until its timer).
    @Test @MainActor func everyEndOfAccessClearsACopiedNumber() async throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        try rig.seed([VaultEntry(title: "Passport", value: "Z0000009", addedAt: VaultRig.t0)])
        let model = rig.model()
        await model.opened()
        #expect(await model.unlock())
        let before = rig.box.cleared
        model.closed()
        #expect(rig.box.cleared == before + 1, "closing the Vault")
        await model.opened()
        #expect(await model.unlock())
        model.lockNow()
        #expect(rig.box.cleared == before + 2, "Lock Now")
        model.systemLocked()
        #expect(rig.box.cleared == before + 3, "the Mac locking")
    }
}
