import AppKit
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The detail pane's answers and Tab row, drawn: no ⋯ menu, and a tab you chose says so.
@MainActor
@Suite struct VaultAnswersPanelTests {
    typealias Shelf = VaultRefreshPanelTests.Shelf

    /// A Vault with two health IDs read and waiting, the dental one chosen.
    static func waiting() async throws -> (rig: (model: VaultModel, defaults: UserDefaults, proof: VaultFakeAuthenticator, cleanUp: () -> Void), dental: UUID) {
        let rig = try await VaultPanelRenderTests.rig()
        VaultReadFolders.add(VaultRefreshPanelTests.root, in: rig.defaults)
        await rig.model.readDocuments(with: Shelf([
            VaultRefreshPanelTests.dental: VaultRefreshPanelTests.card("Delta Dental", id: "XZB123456789", group: "0012345"),
            VaultRefreshPanelTests.vision: VaultRefreshPanelTests.card("Clear Vision", id: "VSP99887766", group: "0044"),
        ]))
        let dental = try #require(rig.model.rows.first { $0.value == "XZB123456789" }?.id)
        rig.model.selection = dental
        return (rig, dental)
    }

    /// Edit says what a corrected ID's documents read for it.
    @Test func theEditorSaysWhatACorrectedIDsDocumentsRead() {
        #expect(VaultCard.readingsLine(["WZ88319122"]) == "Its document reads WZ88319122 for this ID.")
        #expect(VaultCard.readingsLine(["WZ88319122", "WZ8831912Z"])
                == "Its documents read WZ88319122 and WZ8831912Z for this ID.")
        #expect(VaultCard.readingsLine(["A", "B", "C"]) == "Its documents read A, B and C for this ID.")
        #expect(VaultCard.readingsLine([]).isEmpty)
    }

    /// Moving a waiting ID to Current by hand draws You moved it here under Tab; letting the Vault
    /// choose again draws the pane exactly as before, so the difference is the caption's.
    @Test func aTabYouChoseIsSaidUnderItAndLettingTheVaultChooseTakesItAway() async throws {
        let (rig, dental) = try await Self.waiting(); defer { rig.cleanUp() }
        let row = try #require(rig.model.rows.first { $0.id == dental })
        #expect(!row.isSaved && row.standing.tab == .current && row.standing.reason == nil)
        let vaults = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "answers-waiting")

        rig.model.pin(dental, .current)
        #expect(rig.model.rows.first { $0.id == dental }?.standing.reason == VaultStanding.movedByYou)
        let chosen = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "answers-moved-here")
        #expect(differingPixels(vaults, chosen) > 300, "the caption is drawn, and what is under it moves down")

        rig.model.pin(dental, nil)
        let again = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "answers-vault-chooses")
        #expect(differingPixels(vaults, again) == 0)
    }

    /// A saved ID moved to Archive by hand: the selection moves on, and the Archive tab shows it
    /// with its caption.
    @Test func aSavedIDMovedToArchiveLeavesTheListAndSaysWhyThere() async throws {
        let rig = try await VaultPanelRenderTests.rig(); defer { rig.cleanUp() }
        let passport = try #require(rig.model.rows.first { $0.value == "A38291647" }?.id)
        rig.model.selection = passport
        _ = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "answers-saved")
        rig.model.pin(passport, .older)
        #expect(rig.model.selection != passport, "the selection moved on")
        rig.model.tab = .archive
        rig.model.selection = passport
        #expect(rig.model.rows.first { $0.id == passport }?.standing.reason == VaultStanding.movedByYou)
        _ = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "answers-archived")
    }
}
