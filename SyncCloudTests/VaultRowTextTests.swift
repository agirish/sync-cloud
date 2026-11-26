import Foundation
import Sync
import Testing
@testable import SyncCloud

/// What a row says in the panel (VT8), pinned on the view's own functions before they moved to
/// Sync and passing unchanged after (Large Type's heading was pinned after). Every number is made up.
@MainActor
@Suite struct VaultRowTextTests {
    static let root = "/Users/anna/Documents"

    /// A Vault holding a read passport, a dental card, a receipt notice, an I-94, and two typed in.
    static func rows() async throws -> (rows: [VaultModel.Row], model: VaultModel, rig: VaultRig) {
        let rig = try VaultRig()
        VaultReadFolders.add(root, in: rig.defaults)
        rig.defaults.set(VaultLockSettings.Relock.whenClosed.rawValue, forKey: VaultLockSettings.relockKey)
        let model = rig.model()
        model.people = [Person(id: "anna", displayName: "Anna")]
        await model.opened()
        let shelf = VaultShelf([
            root + "/Immigration/Passport/Anna/scan.pdf": VaultFolderReaderTests.passport,
            root + "/Health/Dental/ID Cards/card.pdf": ["Delta Dental", "Member Name: ANNA ERIKSSON", "Member ID: XZB123456789", "Group Number: 0012345"],
            root + "/Immigration/Notices/receipt.pdf": ["Receipt Number WAC2412345678", "I-94 Number 123456789A1"],
        ])
        await model.readDocuments(with: shelf)
        _ = model.add(.init(title: "Library card", value: "LIB7702913", note: "Main branch", category: .other))
        var household = VaultModel.Draft(title: "Gate code", value: "GATE48213", note: "", category: .other)
        household.isHousehold = true
        _ = model.add(household)
        return (model.rows.sorted { $0.value < $1.value }, model, rig)
    }

    @Test func eachRowSaysWhatThePanelShowsOfIt() async throws {
        let (rows, model, rig) = try await Self.rows()
        defer { rig.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func line(_ row: VaultModel.Row) -> String {
            [row.value, row.idLabel, row.kindTitle, row.kindNote(shown: true) ?? "nil",
             row.spoken(title: "T"), VaultAssignment.tag(row.assignment),
             row.listTitle, row.listSubtitle(now: now), row.detailLede].joined(separator: " | ")
        }
        #expect(rows.map(line) == [
            "123456789A1 | Admission number | I-94 admission number | nil | T, I-94 admission number, ending 8 9 A 1, to confirm | document | I-94 admission number |  | Unknown · To confirm",
            "GATE48213 | Number | Gate code | nil | T, Other ID, ending 8 2 1 3, in Vault | household | Gate code | Household · Typed in | Household",
            "L898902C3 | Passport number | Passport | nil | T, Passport, ending 0 2 C 3, expired, to confirm | document | Anna · UTO | Expired Apr 2012 | Anna Maria Eriksson · To confirm",
            "LIB7702913 | Number | Library card | nil | T, Other ID, ending 2 9 1 3, in Vault | document | Library card | Household · Main branch · Typed in | Household",
            "WAC2412345678 | Receipt number | USCIS receipt number | nil | T, USCIS receipt number, ending 5 6 7 8, older | document | USCIS case | Decided | Unknown",
            "XZB123456789 | Member ID | Dental · Member ID | nil | T, Health or medical ID, ending 6 7 8 9, to confirm | document | Anna · Dental · Member ID |  | Anna Eriksson · To confirm",
        ])
        #expect(VaultModel.Row.foldedSummary(rows) == "3 people · 1 expired · 3 to confirm")
        #expect(rows.map(\.largeTypeHeading) == ["Unknown · I-94 admission number", "Household · Gate code",
                                                  "Anna Maria Eriksson · Passport", "Household · Library card",
                                                  "Unknown · USCIS receipt number", "Anna Eriksson · Dental · Member ID"])
        #expect(VaultAssignment.tag(.person("anna")) == "person:anna")
        // Moved to another card: its note says what it was typed in as.
        let library = try #require(rows.first { $0.value == "LIB7702913" })
        model.setKind(library.id, to: .builtIn(.health))
        let moved = try #require(model.rows.first { $0.value == "LIB7702913" })
        let note = moved.kindNote(shown: true) ?? "nil"
        #expect(note == "Typed in as Other")
    }
}
