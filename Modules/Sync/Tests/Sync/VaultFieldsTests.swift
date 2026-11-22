import Foundation
import Testing
@testable import Sync

/// Fields added by hand to a read ID (More fields, Add a Field…). Every number is made up.
@MainActor
@Suite struct VaultFieldsTests {
    typealias Rig = VaultModelTests.Rig

    @Test func aPlanCodeShowsAsPrintedAndAnIDShapedValueIsHidden() {
        #expect(VaultModel.fieldValue(label: "RxBIN", value: "610502") == .text("610502"))
        #expect(VaultModel.fieldValue(label: "RxPCN", value: " ADV ") == .text("ADV"))
        #expect(VaultModel.fieldValue(label: "Dependent Code", value: "W2883-19115") == .number("W2883-19115"))
        #expect(VaultModel.fieldValue(label: "Plan", value: "PPO 2") == .text("PPO 2"))
    }

    /// Anna's dental ID saved from her card.
    static func saved(_ rig: Rig) async throws -> (model: VaultModel, id: UUID) {
        let model = rig.model()
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        await model.readDocuments(with: VaultReadAsTests.documents([VaultMergeTests.card: VaultMergeTests.page("1102462401")]))
        let find = try #require(model.finds.first)
        return (model, try #require(model.confirm(find.id, as: VaultModel.Draft(find))))
    }

    @Test func anAddedFieldShowsWithTheDetailsAndIsKeptApartFromWhatWasRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.saved(rig)
        let read = try #require(model.entries.first { $0.id == id }?.facts)
        #expect(await model.addField(id, label: "RxBIN", value: "610502"))
        #expect(await model.addField(id, label: "Payer ID", value: "60054", hidden: true))
        #expect(await model.addField(id, label: "RxBIN", value: "610502"), "the same field twice is one")
        let details = try #require(model.rows.first { $0.id == id }?.facts?.details)
        #expect(details.suffix(2) == [VaultDetail("RxBIN", .text("610502")), VaultDetail("Payer ID", .number("60054"))])
        #expect(model.entries.first { $0.id == id }?.facts == read, "an added field changed what was read")
        // Sealed with the ID.
        let next = rig.model()
        await next.opened()
        #expect(next.entries.first { $0.id == id }?.fields?.count == 2)

        #expect(await model.removeField(id, at: 0))
        #expect(model.entries.first { $0.id == id }?.fields == [VaultDetail("Payer ID", .number("60054"))])
        #expect(await model.removeField(id, at: 0))
        #expect(model.entries.first { $0.id == id }?.fields == nil)
        #expect(!(await model.removeField(id, at: 0)))
    }

    @Test func aTypedInIDTakesNoFieldsAndBlanksAreRefused() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        #expect(!(await model.addField(VaultModelTests.passport.id, label: "Book", value: "B000")))
        let other = try Rig(); defer { other.cleanUp() }
        let (read, id) = try await Self.saved(other)
        #expect(!(await read.addField(id, label: " ", value: "1")))
        #expect(!(await read.addField(id, label: "Note", value: "  ")))
    }

    @Test func moreFieldsLeavesOutTheIDAnotherHeldIDAndWhatTheDetailsShow() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, id) = try await Self.saved(rig)
        try rig.store.save(model.entries + [VaultModelTests.memberID])
        let fresh = rig.model()
        await fresh.opened()
        #expect(await fresh.addField(id, label: "RxBIN", value: "610502"))
        let values = [VaultCardValue(label: "Member ID", value: "1102462401"),
                      VaultCardValue(label: "Subscriber ID", value: VaultModelTests.memberID.value),
                      VaultCardValue(label: "RxBIN", value: "610502"),
                      VaultCardValue(label: "RxPCN", value: "ADV")]
        #expect(fresh.moreFields(values, for: id) == [VaultCardValue(label: "RxPCN", value: "ADV")])
    }
}
