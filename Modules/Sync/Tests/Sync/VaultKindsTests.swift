import Combine
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Kind: an account moved to another card or to a kind the household made, what its folder
/// learns from that, and what never moves. Every number is made up.
@MainActor
@Suite struct VaultKindsTests {
    typealias Rig = VaultModelTests.Rig
    typealias PlannedDocuments = VaultAccountModelTests.PlannedDocuments

    static let root = "/Users/anna/Documents"
    static let tesla = root + "/Vehicles/Tesla/Supercharging"

    /// Two papers of one folder, each with its own number, and a passport elsewhere.
    static let pages: [String: [String]] = [
        tesla + "/2026/Receipt.pdf": ["Account Number: 1234 5678 9012"],
        tesla + "/2026/Plan.pdf": ["Account Number: 5555 6666 7777"],
        root + "/Immigration/Passport/Anna/scan.pdf": VaultToConfirmTests.passportPage,
    ]

    static var documents: PlannedDocuments { PlannedDocuments(pages: pages) }

    static func model(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: documents)
        return model
    }

    static func row(_ model: VaultModel, _ value: String) -> VaultModel.Row? {
        model.rows.first { $0.value == value }
    }

    @Test func anAccountMovesToAnotherKindAndKeepsWhatItWasReadAs() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let id = try #require(Self.row(model, "1234 5678 9012")?.id)
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.other))

        model.setKind(id, to: .builtIn(.utilities))
        let moved = try #require(Self.row(model, "1234 5678 9012"))
        #expect(moved.card == .builtIn(.utilities) && moved.category == .utilities, "weighed as the kind it is on")
        #expect(moved.readAs == .other, "what it was read as is kept")
        #expect(moved.isHousehold, "a utility with no person is the household's, as one read as a utility is")
        #expect(model.cards.map(\.card).contains(.builtIn(.utilities)))

        model.setKind(id, to: nil)
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.other), "As Read puts it back")
    }

    @Test func anIdentityNumberNeverChangesKind() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let passport = try #require(model.rows.first { $0.category == .passport })
        model.setKind(passport.id, to: .builtIn(.other))
        #expect(model.rows.first { $0.id == passport.id }?.card == .builtIn(.passport))
        // Nor can an account be moved onto an identity kind's card.
        let account = try #require(Self.row(model, "1234 5678 9012")?.id)
        model.setKind(account, to: .builtIn(.passport))
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.other))
    }

    /// Kept in the document, a kind is added only with the Vault open: shut, none is answered,
    /// so no caller is handed a kind that was never kept.
    @Test func aKindIsNotAddedWhileTheVaultIsShut() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        #expect(model.addKind(named: "Charging") == nil)
        await model.opened()
        #expect(model.addKind(named: "Charging") != nil)
    }

    @Test func aCustomKindHasItsOwnCardAfterTheAppsAndGoesWhenRemoved() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let card = try #require(model.addKind(named: "  Charging  "))
        #expect(model.addKind(named: "charging") == card, "the same name is the same kind")
        #expect(model.addKind(named: "Utilities & Phone") == .builtIn(.utilities), "an app kind's name is that kind")
        let id = try #require(Self.row(model, "1234 5678 9012")?.id)
        model.setKind(id, to: card)
        #expect(model.cards.last?.card == card, "after the app's own kinds")
        #expect(model.kinds.title(of: card) == "Charging")
        let row = try #require(Self.row(model, "1234 5678 9012"))
        #expect(row.category == .other, "a custom kind is weighed as the account it was read as")

        // Kept for the next open, by name only.
        let next = rig.model()
        await next.opened()
        #expect(next.kinds.custom.map(\.name) == ["Charging"])
        next.closed()

        // Removed: its numbers go back to what they were read as.
        model.setKinds(VaultKinds())
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.other))
        #expect(!model.cards.map(\.card).contains(card))
    }

    @Test func aChoiceTeachesItsFolderAndLaterReadsFollow() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let card = try #require(model.addKind(named: "Charging"))
        model.setKind(try #require(Self.row(model, "1234 5678 9012")?.id), to: card)

        // The other paper of the same folder follows, saying where it learned it.
        let other = try #require(Self.row(model, "5555 6666 7777"))
        #expect(other.card == card && other.chosenCard == nil)
        #expect(other.learnedFrom == Self.tesla)

        // A new paper read there later goes on the same card.
        var pages = Self.pages
        pages[Self.tesla + "/2025/Statement.pdf"] = ["Account Number: 8888 9999 0000"]
        let later = PlannedDocuments(pages: pages)
        await model.readDocuments(with: later)
        #expect(Self.row(model, "8888 9999 0000")?.card == card)

        // As Read on one number moves that one alone.
        model.setKind(other.id, to: nil)
        #expect(Self.row(model, "5555 6666 7777")?.card == .builtIn(.other))
        #expect(Self.row(model, "8888 9999 0000")?.card == card)

        // Forgotten, the folder teaches nothing; the number chosen for keeps its own choice. The
        // panel hears of it at once: the lessons are not published themselves.
        var sends = 0
        let sink = model.objectWillChange.sink { _ in sends += 1 }
        model.forgetLesson(Self.tesla)
        sink.cancel()
        #expect(sends > 0, "the row stayed on the card it learned until something else redrew")
        #expect(Self.row(model, "8888 9999 0000")?.card == .builtIn(.other))
        #expect(Self.row(model, "1234 5678 9012")?.card == card)
    }

    @Test func aChoiceOutlivesTheNextReadAndConfirmingAndAReopen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let id = try #require(Self.row(model, "1234 5678 9012")?.id)
        model.setKind(id, to: .builtIn(.loans))
        await model.readDocuments(with: Self.documents, again: true)
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.loans), "read again from nothing, the choice is kept")

        let find = try #require(model.finds.first { $0.value == "1234 5678 9012" })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        #expect(model.entries.first { $0.id == saved }?.card == .builtIn(.loans))

        model.closed()
        await model.opened()
        #expect(model.rows.first { $0.value == "1234 5678 9012" }?.card == .builtIn(.loans))
        #expect(Self.row(model, "5555 6666 7777")?.card == .builtIn(.loans), "the folder's lesson was sealed")
    }

    @Test func twoPlansOfOnePersonAreBothCurrent() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        // Dated two years apart, so one would be the other's older copy were they one plan's.
        await model.readDocuments(with: PlannedDocuments(pages: [
            Self.root + "/Health/Dental/2024/card.pdf": ["Member Name: ANNA ERIKSSON", "Member ID: XZB123456789"],
            Self.root + "/Health/Vision/2022/card.pdf": ["Member Name: ANNA ERIKSSON", "Member ID: VSP99887766"],
            Self.root + "/Health/Vision/2025/card.pdf": ["Member Name: ANNA ERIKSSON", "Member ID: VSP11223344"],
        ]))
        let current = Set(model.rows.filter { $0.standing.tab == .current }.map(\.value))
        #expect(current == ["XZB123456789", "VSP11223344"],
                "a vision plan's member ID never sends a dental plan's to Archive; its own newer one does")
    }

    @Test func aVaultSealedBeforeKindsStillOpens() throws {
        // An entry as an older build sealed it: no card at all.
        let old = #"{"id":"6F2A0C2E-0D1B-4C5E-9E33-6A1B2C3D4E5F","title":"Gym","value":"12345678","note":"","kind":"other","addedAt":0,"updatedAt":0}"#
        let entry = try JSONDecoder().decode(VaultLegacyFormat.Entry.self, from: Data(old.utf8)).entry
        #expect(entry.card == nil)
        // A card this build does not know is kept, and drawn as read.
        let later = try JSONDecoder().decode(VaultCardID.self, from: Data(#""someLaterKind""#.utf8))
        #expect(!VaultKinds().exists(later))
        #expect(VaultCardID(key: "custom:abc") == .custom("abc") && VaultCardID(key: "health") == .builtIn(.health))
        let state = try JSONDecoder().decode(VaultReadingState.self,
                                             from: Data(#"{"version":1,"generation":0,"finds":[]}"#.utf8))
        #expect(state.lessons.isEmpty)
    }

    @Test func aCustomKindJoinsAGroupAndTheKindsChoiceFollows() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let card = try #require(model.addKind(named: "Memberships", group: "travel"))
        model.setKind(try #require(Self.row(model, "1234 5678 9012")?.id), to: card)
        model.kindFilter = "travel"
        #expect(model.visibleRows.contains { $0.value == "1234 5678 9012" })
        #expect(model.visibleRows.contains { $0.value == "5555 6666 7777" }, "its folder's other number follows")
        model.kindFilter = "home"
        #expect(!model.visibleRows.contains { $0.value == "1234 5678 9012" }, "no longer in Other's group")
        // Searching finds it by its kind's name, which its title does not hold.
        model.kindFilter = nil
        model.query = "member"
        #expect(model.visibleRows.contains { $0.value == "1234 5678 9012" })
    }

    @Test func choosingItsOwnKindTeachesNothingAndAsReadOutlastsALesson() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let card = try #require(model.addKind(named: "Charging"))
        let first = try #require(Self.row(model, "1234 5678 9012")?.id)
        let second = try #require(Self.row(model, "5555 6666 7777")?.id)
        // Its own kind is As Read: the folder learns nothing from it.
        model.setKind(first, to: .builtIn(.other))
        #expect(Self.row(model, "5555 6666 7777")?.learnedFrom == nil)
        // Put back As Read before the folder learns, it stays put when the folder does.
        model.setKind(second, to: card)
        #expect(Self.row(model, "1234 5678 9012")?.card == .builtIn(.other), "its own choice outlasts the lesson")
    }

    @Test func onlyAnAccountsOwnFolderTeaches() {
        let roots = [Self.root]
        #expect(VaultKinds.teaches(Self.root + "/Home/Utilities/EBMUD/2024/bill.pdf", under: roots))
        #expect(!VaultKinds.teaches(Self.root + "/Home/Utilities/bill.pdf", under: roots), "loose papers of many accounts")
        #expect(!VaultKinds.teaches(Self.root + "/Immigration/Passport/A/scan.pdf", under: roots))
        #expect(VaultKinds.lessonFolder(of: "/d/Health/Aetna/2023 - Anna/card.pdf") == "/d/Health/Aetna",
                "a year's folder named for a person is still a year")
    }

    @Test func anAppKindsNameIsThatKindAndACheckedOnesIsRefused() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.addKind(named: "Passports") == nil)
        #expect(model.addKind(named: "passport") == nil)
        #expect(model.addKind(named: "Health & Medical") == .builtIn(.health))
        #expect(model.kinds.custom.isEmpty)
    }

    @Test func storedKindsAndCardsSurviveWhatThisBuildCannotRead() throws {
        // A card a later build wrote is written back as it was found.
        let later = try JSONDecoder().decode(VaultCardID.self, from: Data(#""someLaterKind""#.utf8))
        #expect(String(decoding: try JSONEncoder().encode(later), as: UTF8.self) == #""someLaterKind""#)
        // One unreadable kind never costs the rest.
        let defaults = vaultScratchDefaults("vault-kinds")
        defaults.set(Data(#"[{"id":"a","name":"Memberships","group":"home"},{"name":42},{"id":"b","name":"School","group":"home"}]"#.utf8),
                     forKey: "vaultCustomKinds")
        #expect(VaultKinds.load(from: defaults).custom.map(\.name) == ["Memberships", "School"])
    }

    @Test func aCheckedIDsStoredCardIsNeverDrawn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        // An account whose stored card names a passport's, as no build writes but a damaged file might.
        var entry = VaultEntry(title: "Gym", value: "12345678", addedAt: VaultLockTests.t0, category: .other)
        entry.card = .builtIn(.passport)
        try rig.seed([entry])
        let model = rig.model()
        await model.opened()
        #expect(model.rows.first?.card == .builtIn(.other))
    }
}

/// What stays chosen when the chosen row leaves the list.
@MainActor
@Suite struct VaultSelectionTests {
    typealias Rig = VaultModelTests.Rig

    @Test func markingAnIDOlderChoosesTheOneAfterItNotTheFirst() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let loans = ["A", "B", "C"].map {
            VaultEntry(title: "\($0) loan", value: "12345678\($0)", addedAt: VaultLockTests.t0, category: .loans)
        }
        try rig.seed([VaultModelTests.passport] + loans)
        let model = rig.model()
        await model.opened()
        #expect(model.visibleRows.map(\.title).suffix(3) == ["A loan", "B loan", "C loan"])
        model.selection = loans[1].id
        model.pin(loans[1].id, .older)
        #expect(model.selectedRow?.title == "C loan", "the next one, never the first passport")
        model.pin(loans[2].id, .older)
        #expect(model.selectedRow?.title == "A loan", "the last one gone, the one before it")
    }
}

/// The year check that replaced a regex compiled per folder (VT66) answers as the regex did.
@Suite struct VaultYearFolderTests {
    @Test func theYearCheckAnswersAsThePatternDid() {
        let pattern = #"^(?:19|20)[0-9]{2}(?![0-9])"#
        var names = ["2024", "2024 Tax", "1999", "1899", "2100", "20245", "202", "20x4", "Tax 2024", "2024-25",
                     "19", "", "2", "20 24", "２０２４", "2024é", "1900s", "20a4", "1988Archive"]
        let alphabet = Array("012 9-aT.")
        var seed: UInt64 = 7
        for _ in 0..<4000 {
            var name = ""
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let length = Int(seed >> 60) % 7
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                name.append(alphabet[Int(seed >> 33) % alphabet.count])
            }
            names.append(["19", "20", ""][Int(seed >> 13) % 3] + name)
        }
        for name in names {
            let old = name.range(of: pattern, options: .regularExpression) != nil
            #expect(VaultKinds.isYear(Substring(name)) == old, "\(name)")
        }
    }
}
