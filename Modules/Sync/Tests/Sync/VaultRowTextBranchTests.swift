import Foundation
import Testing
@testable import Sync

/// Branches of what a row says (VT8) the app's literal test does not reach: four more kinds'
/// number labels, a visa's and a case's titles, the dates under a row, and VoiceOver's marks. Read
/// from real fixture pages, so a reader change can move these too.
/// Every number is made up.
@MainActor
@Suite struct VaultRowTextBranchTests {
    static let root = "/Users/anna/Documents"

    @Test func eachKindSaysWhatItIs() async throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let pages: [String: [String]] = [
            Self.root + "/Legal/Driver License/front.pdf": VaultFixtures.licensePage,
            Self.root + "/Legal/SSN/card.pdf": VaultIDReadingTests.ssnCard,
            Self.root + "/Immigration/Visa/foil.pdf": ["Visa Type/Class R/B1/B2", "Control Number 20241234560001"]
                + VaultReadingTests.zone("V", number: "H1234567", born: "740812", expires: "290930", country: "USA"),
            Self.root + "/Immigration/Approvals/i797.pdf": ["I-797C, Notice of Action", "Receipt Number WAC2412345678", "Case Type I-129 - Petition for a Nonimmigrant Worker"],
        ]
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: pages))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = model.rows.sorted { $0.value < $1.value }.map { row in
            [row.value, row.idLabel, row.kindTitle, row.listTitle, row.listSubtitle(now: now), row.spoken(title: "T"),
             row.kindNote ?? "nil"].joined(separator: " | ")
        }
        #expect(lines == [
            // A Social Security card: its ending is itself a secret, so not spoken; dated by the card.
            "123456789 | Social Security number | Social Security number | Anna | May 2025 | T, Social Security number or ITIN, to confirm | nil",
            "20241234560001 | Control Number | US visa | Anna · US visa | Valid to Sep 2029 | T, Visa, ending 0 0 0 1, to confirm | nil",
            "D1234567 | License number | Driver’s license · CA | Anna | Valid to May 2030 | T, Driver’s license, ending 4 5 6 7, to confirm | nil",
            // "I-129 case" without " case"; a receipt with no decision yet is pending.
            "WAC2412345678 | Receipt number | I-129 | I-129 |  | T, USCIS receipt number, ending 5 6 7 8, pending, to confirm | nil",
        ])
    }


    /// What VoiceOver says of a row adds the badges the panel works out itself, as words.
    @Test func aRowSaysTheBadgesThePanelWorksOut() {
        let row = VaultModel.Row(id: UUID(), title: "Passport", value: "A38291647", note: "", category: .passport, facts: nil,
                                 standing: VaultStanding(tab: .current), isSaved: true, personID: nil, whose: "Anna",
                                 pin: nil, assignment: nil, isHousehold: false)
        let plain = row.spoken(title: "Anna")
        #expect(row.spoken(title: "Anna", also: []) == plain)
        #expect(row.spoken(title: "Anna", also: ["Updated", "Expires in 12 days"])
                == plain.replacingOccurrences(of: ", in Vault", with: ", updated, expires in 12 days, in Vault"))
    }

    /// The activity list and a person's copied text name a case as its title does, without
    /// " case": the same rule as the panel (``VaultModel/Row/kindTitle``).
    @Test func theActivityListAndPeoplesTextNameACaseWithoutCase() async throws {
        let (rig, activity, model) = try VaultActivityTests.rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        await model.opened()
        let notice = ["I-797C, Notice of Action", "Receipt Number WAC2412345678", "Case Type I-129 - Petition for a Nonimmigrant Worker"]
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [Self.root + "/Immigration/Approvals/i797.pdf": notice]))
        let row = try #require(model.rows.first { $0.value == "WAC2412345678" })
        #expect(row.title == "I-129 case", "the fixture's title still carries \" case\"")
        #expect(await model.copy(row.id))
        #expect(activity.load().first?.line.hasPrefix("Copied I-129") == true && activity.load().first?.line.contains("case") == false,
                "\(activity.load().first?.line ?? "")")
        let section = try #require(model.peopleSections.first { $0.rows.contains { $0.id == row.id } })
        let text = VaultPersonText.text(section, numbers: false)
        #expect(text.contains("I-129: ") && !text.contains("I-129 case"), "\(text)")
    }
}
