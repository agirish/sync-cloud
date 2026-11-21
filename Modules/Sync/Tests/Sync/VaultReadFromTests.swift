import Foundation
import Testing
@testable import Sync

/// "Read from": the document an ID's dates and details come from is the one its pill names, and
/// among copies of one document the user may choose which it is read from. A choice changes the
/// name and details shown and the file that opens, never the dates, the tab or the card. Every
/// number, name and folder is made up.
@MainActor
@Suite struct VaultReadFromTests {
    typealias Rig = VaultModelTests.Rig
    typealias PlannedDocuments = VaultAccountModelTests.PlannedDocuments

    static let root = "/Users/anna/Documents"
    static let day = Date(timeIntervalSince1970: 1_700_000_000)

    /// One document's reading of a passport, filed at `path`.
    static func passport(_ path: String, holder: String = "Anna Example", until: Date = day, dated: Date? = day,
                         details: Int = 1, rank: Int = VaultReading.Rank.passportPage) -> VaultFind {
        VaultFind(title: "Passport", value: "X1234567", facts: VaultReadFacts(
            category: .passport, holder: holder, dated: dated, validUntil: until,
            details: (0..<details).map { VaultDetail("Detail \($0)", .text("\($0)")) },
            sources: [VaultSource(path: path, role: "Passport photo page", rank: rank)]))
    }

    static let home = root + "/Immigration/Passport/Anna/passport.pdf"
    static let petition = root + "/Immigration/H-1B/Petition/passport.pdf"

    // MARK: Which document speaks, and the pill

    /// The pill used to be worked out apart from the merge: the first statement by name, while
    /// the dates came from the newest.
    @Test func thePillNamesTheDocumentTheDatesComeFrom() throws {
        let older = VaultFind(title: "Account", value: "1234567890", facts: VaultReadFacts(
            category: .utilities, dated: Self.day,
            sources: [VaultSource(path: Self.root + "/Home/A Water/bill.pdf", role: "Account paper", rank: 30)]))
        var newer = older
        newer.facts.dated = Self.day.addingTimeInterval(86_400 * 30)
        newer.facts.sources = [VaultSource(path: Self.root + "/Home/B Water/bill.pdf", role: "Account paper", rank: 30)]
        let merged = try #require(VaultCopies.merged([older, newer]))
        #expect(merged.facts.dated == newer.facts.dated)
        #expect(merged.facts.primary?.path == Self.root + "/Home/B Water/bill.pdf", "named by the one that spoke")
        #expect(merged.facts.spokenBy == merged.facts.primary?.path)
        #expect(merged.facts.orderedSources.count == 2)
    }

    /// Between copies of one document that say as much, the one filed where passports live
    /// speaks: by name alone, the petition's copy did.
    @Test func thePassportsOwnFolderSpeaksOverAPetitionsCopy() throws {
        let merged = try #require(VaultCopies.merged([Self.passport(Self.petition), Self.passport(Self.home)]))
        #expect(merged.facts.spokenBy == Self.home)
        // A copy that says more still speaks, as before.
        let fuller = try #require(VaultCopies.merged([Self.passport(Self.petition, details: 2), Self.passport(Self.home)]))
        #expect(fuller.facts.spokenBy == Self.petition)
    }

    /// The later order keys only settle copies alike in everything before them, so no copy with
    /// other dates is put ahead by where it is filed.
    @Test func whereACopyIsFiledNeverOutranksItsDates() throws {
        let later = Self.passport(Self.petition, dated: Self.day.addingTimeInterval(86_400))
        let merged = try #require(VaultCopies.merged([later, Self.passport(Self.home)]))
        #expect(merged.facts.spokenBy == Self.petition, "the later notice of two good as long")
        #expect(merged.facts.dated == later.facts.dated)
        // And the order is one order: every pair agrees with the sort.
        let copies = [later, Self.passport(Self.home), Self.passport(Self.root + "/Immigration/Passport/Anna/b.pdf", details: 2)]
        let ordered = VaultCopies.ordered(copies)
        for (i, a) in ordered.enumerated() { for b in ordered.dropFirst(i + 1) {
            #expect(!VaultCopies.supersedes(b.facts, a.facts))
        } }
    }

    // MARK: What can be chosen

    @Test func onlyCopiesOfTheSameDocumentCanBeChosen() {
        let renewal = Self.passport(Self.root + "/Immigration/Passport/Anna/renewed.pdf", until: Self.day.addingTimeInterval(86_400 * 3650))
        let mention = Self.passport(Self.root + "/Immigration/I-94/i94.pdf", rank: VaultReading.Rank.mention)
        let archived = Self.passport(Self.root + "/Immigration/Passport/Archive/passport.pdf")
        let lesser = Self.passport(Self.root + "/Immigration/Passport/Anna/photo.pdf", rank: VaultReading.Rank.i94Printout)
        let choices = VaultCopies.choices([Self.passport(Self.home), Self.passport(Self.petition), mention, archived, lesser])
        #expect(choices == [Self.petition], "not a mention, an Archive copy or a lesser kind of document")
        // Beside a renewal, the renewal speaks, and the copies of the card it replaced are not choices.
        #expect(VaultCopies.choices([renewal, Self.passport(Self.home), Self.passport(Self.petition)]).isEmpty)
    }

    @Test func aChosenCopySpeaksWithTheSameDatesAndARenewalPassesItOver() throws {
        let copies = [Self.passport(Self.home, holder: "Anna Exarnple"), Self.passport(Self.petition)]
        let chosen = try #require(VaultCopies.merged(copies, speaking: Self.petition))
        #expect(chosen.facts.spokenBy == Self.petition && chosen.facts.holder == "Anna Example")
        let auto = try #require(VaultCopies.merged(copies))
        #expect(chosen.facts.dated == auto.facts.dated && chosen.facts.validUntil == auto.facts.validUntil)
        let renewal = Self.passport(Self.root + "/Immigration/Passport/Anna/renewed.pdf", until: Self.day.addingTimeInterval(86_400 * 3650))
        let later = try #require(VaultCopies.merged(copies + [renewal], speaking: Self.petition))
        #expect(later.facts.spokenBy == renewal.sourcePath, "a renewal speaks over a choice among the old card's copies")
    }

    // MARK: Where it sits

    /// Filed in Archive only when every copy of its best kind of document is: not because the
    /// copy it is read from (the Vault's, or the user's) sits there.
    @Test func archiveGoesByEveryCopyNotTheOneReadFrom() {
        let inArchive = Self.root + "/Immigration/Passport/Archive/passport.pdf"
        var facts = Self.passport(Self.home).facts
        facts.add(VaultSource(path: inArchive, role: "Passport photo page", rank: 40))
        facts.spokenBy = inArchive
        let id = UUID()
        let input = VaultStandingInput(id: id, value: "X1234567", category: .passport, facts: facts, pin: nil)
        #expect(VaultStandings.compute([input], now: Self.day.addingTimeInterval(-86_400), readFolders: [Self.root])[id]?.tab == .current)
        var all = facts
        all.sources = [VaultSource(path: inArchive, role: "Passport photo page", rank: 40),
                       VaultSource(path: Self.root + "/Immigration/Archive/x.pdf", role: "Passport photo page", rank: 40),
                       VaultSource(path: Self.root + "/Immigration/I-94/i94.pdf", role: "Names it", rank: 10)]
        let alone = VaultStandingInput(id: id, value: "X1234567", category: .passport, facts: all, pin: nil)
        #expect(VaultStandings.compute([alone], now: Self.day.addingTimeInterval(-86_400), readFolders: [Self.root])[id]?.tab == .archive,
                "every copy of the passport page is in Archive; a mention elsewhere does not count")
    }

    /// A Kind lesson is looked for in the folder of the document the Vault reads it from, then in
    /// those of its other papers of that kind, so it still holds when the newest statement is
    /// filed elsewhere.
    @Test func aKindLessonIsLookedForInEveryFolderOfItsKindOfPaper() {
        var facts = VaultReadFacts(category: .utilities, sources: [
            VaultSource(path: "/d/Home/Water/2026/a.pdf", role: "Account paper", rank: 30),
            VaultSource(path: "/d/Home/Utilities/EBMUD/2025/a.pdf", role: "Account paper", rank: 30),
            VaultSource(path: "/d/Money/Bank/statement.pdf", role: "Names it", rank: 10),
        ])
        facts.spokenBy = "/d/Home/Water/2026/a.pdf"
        #expect(VaultModel.lessonPaths(facts, app: nil) == ["/d/Home/Water/2026/a.pdf", "/d/Home/Utilities/EBMUD/2025/a.pdf"])
        #expect(VaultModel.lessonPaths(facts, app: "/d/Home/Utilities/EBMUD/2025/a.pdf").first == "/d/Home/Utilities/EBMUD/2025/a.pdf")
    }

    // MARK: The model

    static let dental = root + "/Health/Dental/ID Cards/card.pdf"
    static let scan = root + "/Health/Dental/ID Cards/scan.pdf"
    static let pages: [String: [String]] = [
        dental: ["Member Name: DLVIT GIRISH", "Member ID: XZB123456789"],
        scan: ["Member Name: DIVIT GIRISH", "Member ID: XZB123456789"],
    ]

    static func model(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "divit", displayName: "Divit")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: pages))
        return model
    }

    static func row(_ model: VaultModel) throws -> VaultModel.Row {
        try #require(model.rows.first { $0.value == "XZB123456789" })
    }

    @Test func aWaitingIDIsReadFromTheCopyChosenAndKeepsItThroughConfirm() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let before = try Self.row(model)
        #expect(before.appSource == Self.dental && before.facts?.primary?.path == Self.dental)
        #expect(before.sourceChoices == [Self.scan] && before.chosenSource == nil)
        model.readFrom(before.id, copy: Self.scan)
        let chosen = try Self.row(model)
        #expect(chosen.chosenSource == Self.scan && chosen.facts?.primary?.path == Self.scan)
        #expect(chosen.facts?.holder == "Divit Girish" && chosen.personID == "divit", "the chosen copy's name, and whose it matches")
        #expect(chosen.appSource == Self.dental, "the Vault's own pick is kept for where it is filed")
        #expect(chosen.standing == before.standing && chosen.card == before.card && chosen.facts?.dated == before.facts?.dated)
        // Read again: kept.
        await model.readDocuments(with: PlannedDocuments(pages: Self.pages), again: true)
        #expect(try Self.row(model).chosenSource == Self.scan)
        // Confirmed: kept, and Edit compares against the name it shows as read.
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let draft = model.prepared(VaultModel.Draft(find), for: find.id)
        #expect(draft.facts?.holder == "Divit Girish")
        let saved = try #require(model.confirm(find.id, as: draft))
        #expect(model.entries.first { $0.id == saved }?.chosenSource == Self.scan)
        let row = try Self.row(model)
        #expect(row.chosenSource == Self.scan && row.facts?.holder == "Divit Girish" && row.ownHolderName == nil,
                "saved unchanged, no name of its own")
        // Closed and opened: kept.
        model.closed()
        await model.opened()
        #expect(try Self.row(model).chosenSource == Self.scan)
        // Let the App Choose.
        model.readFrom(saved, copy: nil)
        let back = try Self.row(model)
        #expect(back.chosenSource == nil && back.facts?.primary?.path == Self.dental && back.sourceChoices == [Self.scan])
    }

    @Test func onlyAnOfferedCopyCanBeChosen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let row = try Self.row(model)
        model.readFrom(row.id, copy: Self.root + "/Elsewhere/other.pdf")
        #expect(try Self.row(model).chosenSource == nil)
        model.readFrom(row.id, copy: Self.dental)
        #expect(model.finds.first { $0.id == row.id }?.chosenSource == nil, "the Vault's own pick is no choice")
        // Chosen, then the Vault's own copy chosen again: back to letting it choose.
        model.readFrom(row.id, copy: Self.scan)
        model.readFrom(row.id, copy: Self.dental)
        #expect(model.finds.first { $0.id == row.id }?.chosenSource == nil)
        #expect(try Self.row(model).facts?.primary?.path == Self.dental)
    }

    /// A saved ID's Edit opens with the name its chosen copy reads, and saving it unchanged gives
    /// it no name of its own.
    @Test func editingASavedIDReadFromAChosenCopyKeepsItsName() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: model.prepared(VaultModel.Draft(find), for: find.id)))
        model.readFrom(saved, copy: Self.scan)
        let entry = try #require(model.entries.first { $0.id == saved })
        var draft = model.prepared(VaultModel.Draft(entry), for: saved)
        #expect(draft.facts?.holder == "Divit Girish" && draft.holderName == nil)
        draft.note = "Dental"
        #expect(await model.update(saved, to: draft))
        #expect(model.entries.first { $0.id == saved }?.holderName == nil)
        #expect(try Self.row(model).facts?.holder == "Divit Girish")
    }

    // MARK: Kept across a change of rules and an older build's files

    @Test func aChoiceIsCarriedAndOlderStatesStillOpen() throws {
        let find = VaultFind(title: "Dental", value: "XZB123456789", facts: VaultReadFacts(category: .health),
                             chosenSource: Self.scan)
        #expect(VaultChoice(find).source == Self.scan && VaultChoice(find).isChosen)
        #expect(!VaultChoice(VaultFind(title: "Dental", value: "1", facts: VaultReadFacts(category: .health))).isChosen)
        let old = try JSONDecoder().decode(VaultChoice.self, from: Data(#"{"id":"\#(UUID().uuidString)"}"#.utf8))
        #expect(old.source == nil)
        let facts = try JSONDecoder().decode(VaultReadFacts.self,
                                             from: Data(#"{"category":"passport","pending":false,"details":[],"sources":[]}"#.utf8))
        #expect(facts.spokenBy == nil)
    }
}
