import Foundation
import Testing
@testable import Sync

/// The activity list: what was done and to which ID by name, sealed, and never a number.
@MainActor
@Suite struct VaultActivityTests {
    typealias Rig = VaultModelTests.Rig
    static let mortgage = VaultModelTests.mortgage
    static let passport = VaultModelTests.passport

    static func rig() throws -> (rig: Rig, activity: VaultActivityStore, model: VaultModel) {
        let rig = try Rig()
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        let clock = rig.clock, box = rig.box
        let model = VaultModel(store: rig.store, authenticator: rig.auth, defaults: rig.defaults, clock: { clock.now },
                               activity: activity, copyToPasteboard: { box.copied.append($0) })
        return (rig, activity, model)
    }

    @Test func whatIsDoneIsListedNewestFirstByNameAndOwner() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        model.people = [Person(id: "abhishek", displayName: "Anna")]
        await model.opened()
        rig.clock.advance(1)
        #expect(await model.copy(Self.passport.id))
        rig.clock.advance(1)
        var draft = VaultModel.Draft(Self.mortgage)
        draft.note = "Refinanced"
        #expect(await model.update(Self.mortgage.id, to: draft))
        rig.clock.advance(1)
        #expect(await model.delete(Self.passport.id))

        #expect(activity.load().map(\.line) == ["Removed Passport · Anna", "Edited Mortgage loan number · Household",
                                                "Copied Passport · Anna", "Unlocked"])
    }

    /// VT34: a number written into a title is cut to its ending, but a Social Security number's
    /// ending is itself a secret, so it is hidden whole, as its row hides it.
    @Test func aSocialSecurityNumbersEndingIsNeverListed() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        let ssn = VaultEntry(title: "SSN 123-45-6789", value: "123-45-6789", addedAt: VaultRig.t0, category: .ssn)
        let loan = VaultEntry(title: "Loan 0482917365", value: "0482917365", addedAt: VaultRig.t0, category: .loans)
        try rig.seed([ssn, loan])
        await model.opened()
        #expect(await model.copy(ssn.id))
        #expect(await model.copy(loan.id))
        #expect(await model.delete(ssn.id))

        let lines = activity.load().map(\.line)
        #expect(!lines.contains { $0.contains("6789") }, "\(lines.count) lines, one with the ending")
        // The SSN's lines: its copy and its removal, each with no digit left.
        let ssnLines = lines.filter { ($0.hasPrefix("Copied") || $0.hasPrefix("Removed")) && !$0.contains("Loan") }
        #expect(ssnLines.count == 2 && ssnLines.allSatisfy { !$0.contains(where: \.isNumber) })
        #expect(lines.contains { $0.hasPrefix("Copied Loan") && $0.contains("7365") }, "another kind keeps its ending")
    }

    /// macOS's prompt draws the reason over the screen: a number in a title is masked there too.
    @Test func thePromptNeverCarriesANumberInFull() async throws {
        let (rig, _, model) = try Self.rig(); defer { rig.cleanUp() }
        let ssn = VaultEntry(title: "SSN 123-45-6789", value: "123-45-6789", addedAt: VaultRig.t0, category: .ssn)
        let loan = VaultEntry(title: "Loan 0482917365", value: "0482917365", addedAt: VaultRig.t0, category: .loans)
        try rig.seed([ssn, loan])
        VaultFixtures.everyNumber(rig)
        await model.opened()
        _ = await model.copy(ssn.id)
        _ = await model.copy(loan.id)
        let asked = rig.auth.reasons.joined(separator: " | ")
        #expect(!asked.contains("6789") && !asked.contains("123-45"), "a Social Security number's ending was asked with")
        #expect(asked.contains("7365") && !asked.contains("048291"), "another kind's ending, and no more")
    }

    /// A refused proof's line names the ID as the others do: a Social Security number, no ending.
    @Test func aRefusedProofForASocialSecurityNumberListsNoEnding() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        let ssn = VaultEntry(title: "SSN 123-45-6789", value: "123-45-6789", addedAt: VaultRig.t0, category: .ssn)
        try rig.seed([ssn])
        VaultFixtures.everyNumber(rig)
        await model.opened()
        rig.auth.answer = .cancelled
        #expect(await model.copy(ssn.id) == false)
        let refused = activity.load().map(\.line).filter { $0.hasPrefix("Proof refused") }
        let digitLeft = refused.contains { $0.contains(where: \.isNumber) }
        #expect(refused.count == 1 && !digitLeft)
    }

    /// Kept to nothing, the last four written alone are a number too; and a document's name is
    /// masked the same way.
    @Test func theLastFourWrittenAloneAreHiddenForASecretEnding() {
        for title in ["SSN xxx-xx-6789", "Anna (6789)", "SSN ***-**-6789"] {
            #expect(!VaultMask.text(title, keep: 0).contains("6789"), "\(title)")
        }
        #expect(VaultMask.text("Anna (6789)").contains("6789"), "another kind's ending is not a number on its own")
        #expect(!VaultMask.fileName("/Scans/SSN 123-45-6789.pdf", keep: 0).contains("6789"))
        #expect(VaultMask.fileName("/Scans/Loan 0482917365.pdf").contains("7365"))
        #expect(!VaultMask.folder("/Scans/SSN 123-45-6789", keep: 0).contains("6789"))
    }

    @Test func aTitleCanHideANumberWhole() {
        let whole = VaultMask.text("SSN 123-45-6789", keep: 0), ending = VaultMask.text("SSN 123-45-6789")
        // "SSN" is a short capital prefix, judged part of the number, so it goes too.
        let digitLeft = whole.contains(where: \.isNumber)
        #expect(!digitLeft)
        #expect(ending.hasSuffix("6789") && !ending.contains("123"))
    }

    /// VT23: each choice made about an ID is listed, by its name, as the ID now stands; a choice
    /// already in force adds nothing.
    @Test func eachChoiceAboutAnIDIsListed() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        model.people = [Person(id: "abhishek", displayName: "Anna"), Person(id: "erik", displayName: "Erik")]
        await model.opened()
        model.pin(Self.mortgage.id, .older)
        model.assign(Self.mortgage.id, to: .person("erik"))
        model.assign(Self.mortgage.id, to: .person("erik"))
        model.setGeo(Self.mortgage.id, to: .india)
        model.setGeo(Self.mortgage.id, to: nil)
        model.setKind(Self.mortgage.id, to: .builtIn(.other))
        model.setKind(Self.mortgage.id, to: nil)
        model.pin(Self.mortgage.id, nil)

        let lines = activity.load().map(\.line).reversed().filter { $0 != "Unlocked" }
        #expect(Array(lines) == [
            "Moved Mortgage loan number to Archive · Household",
            "Gave Mortgage loan number to Erik",
            "Marked Mortgage loan number used in India · Erik",
            "Marked Mortgage loan number used in every country · Erik",
            "Set Mortgage loan number’s kind to Other · Erik",
            "Set Mortgage loan number’s kind back to As Typed · Erik",
            "Let the Vault choose Current or Archive for Mortgage loan number · Erik",
        ], "\(lines)")
    }

    /// VT23: a misread name corrected, and taken back, each listed as whose, never the spelling.
    @Test func aNameCorrectionIsListedAsWhoseNeverTheSpelling() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(VaultPeopleViewTests.root, in: rig.defaults)
        model.people = VaultPeopleViewTests.people
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            VaultPeopleViewTests.passport: VaultToConfirmTests.passportPage,
            VaultPeopleViewTests.notice: ["I-797A Approval Notice", "Receipt Number WAC2412345678",
                                          "Beneficiary ERICSSON, ANNA MARIA", "Received Date 01/05/2026"],
        ]))
        for row in model.rows where row.personID != "anna" && row.facts?.holder != nil { model.assign(row.id, to: .person("anna")) }
        #expect(model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna") == 1)
        model.setRole(.misread, of: "Anna Maria Ericsson", for: "anna")
        model.undoMisread("Anna Maria Ericsson", for: "anna")
        let lines = activity.load().map(\.line)
        #expect(lines.filter { $0 == "Corrected a misread name · Anna" }.count == 1, "\(lines)")
        #expect(lines.contains("Undid a misread name’s correction · Anna"))
        #expect(!lines.contains { $0.contains("Ericsson") || $0.contains("Eriksson") }, "never a spelling")
    }

    /// VT23: a person's IDs copied in full, and their birth date, each listed as theirs.
    @Test func copyingAPersonsIDsOrBirthDateIsListedAsTheirs() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.passport])
        model.people = [Person(id: "abhishek", displayName: "Anna")]
        await model.opened()
        let section = try #require(model.peopleSections.first { $0.id == .person("abhishek") })
        #expect(await model.copyPerson(section.id, numbers: false))
        #expect(await model.copyPerson(section.id, numbers: true))
        #expect(await model.copyBirth(Date(timeIntervalSince1970: 0), in: section))
        let lines = activity.load().map(\.line)
        #expect(lines.filter { $0.hasPrefix("Copied every ID in full") } == ["Copied every ID in full · Anna"], "only with numbers")
        #expect(lines.contains("Copied date of birth · Anna"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Copied A detail") })
    }

    @Test func aRefusedProofIsListedThoughNothingOpened() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.auth.answer = .cancelled
        await model.opened()
        #expect(model.isSealedShut)
        #expect(activity.load().map(\.line) == ["Proof refused: unlock your Vault"])
    }

    @Test func theListIsSealedAndHoldsNoNumberEvenFromATitleTypedWithOne() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        await model.opened()
        let id = try #require(model.add(VaultModel.Draft(title: "Chase card 4417 9921 0038 5512", value: "4417 9921 0038 5512", category: .other)))
        #expect(await model.copy(id))
        let events = activity.load()
        #expect(events.count == 2, "\(events.map(\.line))")
        for event in events {
            #expect(!event.what.contains("4417") && !event.what.contains("9921"), "a number typed into a title is cut to its ending: \(event.what)")
        }
        let sealed = try Data(contentsOf: activity.fileURL)
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(sealed.prefix(8) == Data("SCVACTV1".utf8))
        #expect(!text.contains("Chase") && !text.contains("Copied"), "which IDs were used is private too")
    }

    /// A title is not a path (VT72): a slash in it is part of it, and a number on either side of
    /// it is still cut to its ending.
    @Test func aTitleWithASlashIsListedWholeAndStillMasked() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        await model.opened()
        let plain = try #require(model.add(VaultModel.Draft(title: "Chase / Mortgage", value: "0482917365", category: .other)))
        let form = try #require(model.add(VaultModel.Draft(title: "Form 1040 / 2023", value: "4417992100385512", category: .other)))
        let tight = try #require(model.add(VaultModel.Draft(title: "Loan 4417/9921/0038", value: "441799210038", category: .other)))
        let plate = try #require(model.add(VaultModel.Draft(title: "Plate MH12/AB/4417", value: "MH12AB4417", category: .other)))
        rig.clock.advance(1)
        #expect(await model.copy(plain))
        #expect(await model.copy(form))
        #expect(await model.copy(tight))
        #expect(await model.copy(plate))
        let titles = ["Plate ••••/••/4417", "Loan ••••/••••/0038", "Form 1040 / 2023", "Chase / Mortgage"]
        let events = activity.load()
        #expect(events.map(\.line) == ["Copied", "Added"].flatMap { did in titles.map { "\(did) \($0) · Household" } })
        for event in events {
            #expect(!event.what.contains("4417/") && !event.what.contains("9921") && !event.what.contains("MH12"), "no number in full")
        }
    }

    @Test func turnedOffNothingIsListed() async throws {
        let (rig, activity, model) = try Self.rig(); defer { rig.cleanUp() }
        rig.defaults.set(false, forKey: VaultActivitySettings.keepsKey)
        try rig.seed([Self.mortgage])
        await model.opened()
        #expect(await model.copy(Self.mortgage.id))
        #expect(activity.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: activity.fileURL.path))
    }

    @Test func theListIsBoundedInCountAndAge() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])   // makes the key the list is sealed with
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        let now = VaultLockTests.t0
        let old = VaultActivityEvent(at: now.addingTimeInterval(-91 * 86_400), kind: .copied, what: "Old")
        let many = (0..<(VaultActivityStore.limit + 20)).map { VaultActivityEvent(at: now.addingTimeInterval(Double(-$0)), kind: .copied, what: "\($0)") }
        activity.append([old] + many, now: now)
        let kept = activity.load()
        #expect(kept.count == VaultActivityStore.limit)
        #expect(kept.first?.what == "0" && !kept.contains { $0.what == "Old" }, "the newest, and nothing past ninety days")
        // Each bound alone (VT95): under the count, one past ninety days goes and one within stays.
        activity.clear()
        activity.append([VaultActivityEvent(at: now.addingTimeInterval(-91 * 86_400), kind: .copied, what: "Past"),
                         VaultActivityEvent(at: now.addingTimeInterval(-86_400), kind: .copied, what: "Within")], now: now)
        #expect(activity.load().map(\.what) == ["Within"], "the age bound held only because the count did")
        // And on what was stored: ninety-one days on, "Within" is past it.
        let later = now.addingTimeInterval(91 * 86_400)
        activity.append([VaultActivityEvent(at: later, kind: .unlocked)], now: later)
        #expect(activity.load().map(\.what) == [""], "a stored event outlived ninety days")
        activity.clear()
        #expect(activity.load().isEmpty)
    }

    @Test func aVaultWithNoKeyKeepsNoListAndMakesNoKey() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        activity.append([VaultActivityEvent(at: VaultLockTests.t0, kind: .unlocked)], now: VaultLockTests.t0)
        #expect(rig.keychain.itemData == nil, "listing activity never makes the Vault's key")
        #expect(activity.load().isEmpty)
    }

    @Test func aKindALaterBuildWroteIsKeptAndListedByItsWords() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-000000000001","at":"2026-11-20T10:00:00Z","kind":"teleported","what":"Moved somewhere new"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try decoder.decode([VaultActivityEvent].self, from: Data(json.utf8))
        #expect(events.first?.kind == .other && events.first?.line == "Moved somewhere new")
    }
}
