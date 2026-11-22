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

    /// Adding a waiting ID with one character fixed draws the note under it; once the selection
    /// moves off, the same pane is drawn without it.
    @Test func aCorrectionIsSaidUnderTheIDUntilTheNoteGoes() async throws {
        let (rig, dental) = try await Self.waiting(); defer { rig.cleanUp() }
        let find = try #require(rig.model.finds.first { $0.id == dental })
        var draft = VaultModel.Draft(find)
        draft.value = "XZB123456780"
        let id = try #require(rig.model.confirm(dental, as: draft))
        #expect(rig.model.lastCorrection?.id == id && rig.model.selection == id)
        let noted = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "corrected-note")
        rig.model.dismissCorrection()
        let plain = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "corrected-plain")
        #expect(differingPixels(noted, plain) > 300, "the note and its Undo are drawn")
    }

    /// An EOB read one character off Anna's saved dental ID draws Close to … with Merge… under it.
    @Test func aReadingCloseToASavedIDOffersMerge() async throws {
        let (rig, dental) = try await Self.waiting(); defer { rig.cleanUp() }
        let find = try #require(rig.model.finds.first { $0.id == dental })
        let saved = try #require(rig.model.confirm(dental, as: VaultModel.Draft(find)))
        let eob = VaultRefreshPanelTests.root + "/Health/Dental/EOB/EOB.pdf"
        await rig.model.readDocuments(with: Shelf([
            VaultRefreshPanelTests.dental: VaultRefreshPanelTests.card("Delta Dental", id: "XZB123456789", group: "0012345"),
            eob: VaultRefreshPanelTests.card("Delta Dental", id: "XZB123450789", group: "0012345"),
        ]))
        let waiting = try #require(rig.model.finds.first { $0.value == "XZB123450789" })
        rig.model.selection = waiting.id
        #expect(rig.model.mergeSuggestion(for: waiting.id)?.id == saved)
        _ = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "merge-offered")
    }

    /// A field added to a saved dental ID is among the details the pane draws (below this
    /// picture's bottom edge, so the row says so), and the pane draws with it.
    @Test func anAddedFieldIsAmongTheDetailsThePaneDraws() async throws {
        let (rig, dental) = try await Self.waiting(); defer { rig.cleanUp() }
        let find = try #require(rig.model.finds.first { $0.id == dental })
        let saved = try #require(rig.model.confirm(dental, as: VaultModel.Draft(find)))
        #expect(await rig.model.addField(saved, label: "RxBIN", value: "610502"))
        #expect(rig.model.rows.first { $0.id == saved }?.facts?.details.last == VaultDetail("RxBIN", .text("610502")))
        _ = try VaultPanelRenderTests.render(rig.model, defaults: rig.defaults, name: "fields-added")
    }

    @Test func aCorrectionAndAnIDAlreadySavedAreSaidInWords() {
        let id = UUID()
        #expect(VaultCard.correctionLine(.init(id: id, file: "card.pdf", changed: 1)) == "Corrected one character of what card.pdf reads.")
        #expect(VaultCard.correctionLine(.init(id: id, file: "card.pdf", changed: 3)) == "Corrected 3 characters of what card.pdf reads.")
        #expect(VaultCard.correctionLine(.init(id: id, file: "card.pdf", changed: nil)) == "Corrected what card.pdf reads.")
        #expect(VaultCard.alreadySavedLine(title: "Aetna · Member ID", whose: "Abhishek", as: "Shweta")
                == "This is Abhishek’s Aetna · Member ID, already in the Vault. It can’t be added as Shweta’s too.")
        #expect(VaultCard.alreadySavedLine(title: "Aetna · Member ID", whose: "Abhishek", as: nil)
                == "This ID is already in the Vault: Abhishek’s Aetna · Member ID.")
        #expect(VaultCard.correctionLine(.init(id: id, file: "EOB.pdf", changed: nil, merged: true))
                == "Merged the reading from EOB.pdf into this ID.")
        #expect(VaultCard.mergeLine(title: "Dental · Member ID", whose: "Anna", ending: "●●●●2401", differ: 2)
                == "Close to Anna’s saved Dental · Member ID ●●●●2401: 2 characters differ.")
        #expect(VaultCard.mergeLine(title: "Dental · Member ID", whose: nil, ending: "●●●●2401", differ: 1)
                == "Close to the saved Dental · Member ID ●●●●2401: one character differs.")
        #expect(VaultCard.notAnIDMessage(printedForSubscriber: false).hasPrefix("It comes off the Vault"))
        #expect(VaultCard.notAnIDMessage(printedForSubscriber: true).hasPrefix("The card prints this as the subscriber’s ID"))
        let values = [VaultCardValue(label: "Member ID", value: "W288319122"), VaultCardValue(label: "Subscriber ID", value: "W288319115")]
        #expect(VaultCard.otherValues(values, excluding: ["w2883-19122"]) == [values[1]])
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

    /// How tall the answers lie at `width` across, and how wide `view` is at its own size.
    static func height(at width: CGFloat) -> CGFloat {
        NSHostingView(rootView: VaultAnswers(hue: .blue, add: {}, correct: {}, notAnID: {})
            .frame(width: width, alignment: .leading)).fittingSize.height
    }

    static func size(_ view: some View) -> CGSize { NSHostingView(rootView: view.fixedSize()).fittingSize }

    /// Add to Vault…, Correct the ID… and Not an ID… lie on one line in the detail pane: at the
    /// small size there, which fits, never with Not an ID… under the other two. A pane narrower
    /// still moves it down rather than cutting a name short.
    @Test func theThreeAnswersLieOnOneLineInTheDetailPane() {
        let answers = VaultAnswers(hue: .blue, add: {}, correct: {}, notAnID: {})
        let small = Self.size(answers.oneLine.controlSize(.small))
        let regular = Self.size(answers.oneLine.controlSize(.regular))
        #expect(small.width <= VaultCardSize.detailContentWidth,
                "small: \(small.width) across, the pane has \(VaultCardSize.detailContentWidth)")
        #expect(small.width < regular.width)

        // Pinned by each layout's own width, so a squeezed line can't pass for one that fits.
        #expect(Self.height(at: regular.width) == regular.height, "regular, where it fits")
        #expect(Self.height(at: VaultCardSize.detailContentWidth) <= regular.height, "one line in the pane")
        #expect(Self.height(at: small.width) == small.height, "small, where only it fits")
        #expect(Self.height(at: small.width - 20) > 1.5 * small.height, "narrower: Not an ID… goes under")
    }
}
