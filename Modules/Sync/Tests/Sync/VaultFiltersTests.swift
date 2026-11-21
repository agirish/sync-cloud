import Foundation
import Testing
@testable import Sync

/// Where, Whose and Kinds (``VaultModel/geoFilter``, ``VaultModel/personFilter``,
/// ``VaultModel/kindFilter``): a number's country from its document, the user's choice over it,
/// the groups the app starts with and the user's own.
@MainActor
@Suite struct VaultFiltersTests {
    typealias Rig = VaultModelTests.Rig

    static let usLicense = ["California USA DRIVER LICENSE", "DL D1234567", "EXP 05/16/2030", "LN ERIKSSON", "FN ANNA"]
    static let indianLicense = VaultIDReadingTests.indianLicense
    static let pan = VaultIDReadingTests.panCard
    static let passport = VaultToConfirmTests.passportPage

    static var documents: VaultFakeDocuments {
        VaultFakeDocuments(pages: ["/r/us.pdf": usLicense, "/r/in.pdf": indianLicense, "/r/pan.pdf": pan,
                                   "/r/passport.pdf": passport])
    }

    static func values(_ model: VaultModel) -> Set<String> { Set(model.visibleRows.map(\.value)) }

    @Test func eachNumbersCountryComesFromItsDocument() {
        func geo(_ category: VaultCategory, issuer: String? = nil) -> VaultGeo {
            VaultGeo.read(category, facts: VaultReadFacts(category: category, issuer: issuer)).geo
        }
        #expect(geo(.passport, issuer: "IND") == .anywhere)
        #expect(geo(.usVisa) == .us && geo(.i94) == .us && geo(.uscisCase) == .us && geo(.ssn) == .us)
        #expect(geo(.pan) == .india && geo(.aadhaar) == .india && geo(.voterID) == .india)
        #expect(geo(.driversLicense, issuer: "USA") == .us)
        #expect(geo(.driversLicense, issuer: "IND") == .india)
        #expect(VaultGeo.read(.health, facts: nil).geo == .anywhere)
    }

    @Test func aCountryShowsItsOwnNumbersAndEveryPassport() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        #expect(model.spansCountries)

        model.geoFilter = .us
        #expect(Self.values(model) == ["D1234567", "L898902C3"])
        model.geoFilter = .india
        #expect(Self.values(model) == ["KA0520090001234", "ABCPE1234F", "L898902C3"])
        model.geoFilter = .all
        #expect(Self.values(model).count == 4)
    }

    @Test func aCardSaysHowManyMoreTheOtherCountryHas() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        model.geoFilter = .us

        let elsewhere = try #require(model.elsewhere(.builtIn(.driversLicense)))
        #expect(elsewhere.filter == .india && elsewhere.count == 1)
        #expect(model.elsewhere(.builtIn(.passport)) == nil, "a passport is in every country already")
        model.geoFilter = .all
        #expect(model.elsewhere(.builtIn(.driversLicense)) == nil)
    }

    @Test func usedInWinsOverTheDocumentAndOutlivesARead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        let license = try #require(model.finds.first { $0.value == "KA0520090001234" })

        model.setGeo(license.id, to: .us)
        model.geoFilter = .us
        #expect(Self.values(model).contains("KA0520090001234"))
        #expect(model.rows.first { $0.id == license.id }?.geoReason == "You chose it")

        // Read again from scratch: the choice is kept.
        await model.readDocuments(with: Self.documents, again: true)
        #expect(model.finds.first { $0.value == "KA0520090001234" }?.geo == .us)

        model.setGeo(license.id, to: nil)
        #expect(!Self.values(model).contains("KA0520090001234"))
    }

    @Test func aSavedNumbersCountryIsSealedWithIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        let id = try #require(model.add(VaultModel.Draft(title: "Home loan", value: "4410552233")))
        model.setGeo(id, to: .india)
        #expect(try rig.store.load().first?.geo == .india)
    }

    @Test func kindsFollowTheAppsGroupsAndTheUsersOwn() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)

        model.kindFilter = "travel"
        #expect(Self.values(model) == ["L898902C3"])
        model.kindFilter = "legal"
        #expect(Self.values(model) == ["D1234567", "KA0520090001234", "ABCPE1234F"])

        // Customize Groups: licenses moved to Travel, and Travel renamed.
        var groups = model.groups
        groups.groupOf[.driversLicense] = "travel"
        groups.names["travel"] = "Getting Around"
        model.setGroups(groups)
        model.kindFilter = "travel"
        #expect(Self.values(model) == ["L898902C3", "D1234567", "KA0520090001234"])

        let reopened = rig.model()
        #expect(reopened.groups.name("travel") == "Getting Around")
        #expect(reopened.groups.group(of: .driversLicense) == "travel")
        reopened.setGroups(.default)
        #expect(rig.model().groups == .default)
    }

    @Test func theChoicesAreKeptForTheNextOpen() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.geoFilter = .india
        model.personFilter = .person("anna")
        model.kindFilter = "legal"
        model.closed()

        let reopened = rig.model()
        #expect(reopened.geoFilter == .india)
        #expect(reopened.personFilter == .person("anna"))
        #expect(reopened.kindFilter == "legal")
    }

    @Test func aSearchLooksPastEveryChoice() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: Self.documents)
        model.geoFilter = .us
        model.kindFilter = "travel"
        model.query = "PAN"
        #expect(Self.values(model) == ["ABCPE1234F"])
    }
}

/// The filters as the model applies them to what is added and chosen.
@MainActor
@Suite struct VaultFilterModelTests {
    typealias Rig = VaultModelTests.Rig
    typealias InterruptingProof = VaultFixtures.InterruptingProof

    @Test func aNumberAddedUnderAFilterThatHidesItIsShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.kindFilter = "health"
        let id = try #require(model.add(VaultModel.Draft(title: "Loan", value: "4410552233", category: .loans)))
        #expect(model.visibleRows.contains { $0.id == id })
        #expect(model.kindFilter == nil)
    }

    @Test func emptyingTheChosenGroupGoesBackToAllKinds() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        model.kindFilter = "health"
        var groups = model.groups
        groups.groupOf[.health] = "home"
        model.setGroups(groups)
        #expect(model.kindFilter == nil)
    }

    @Test func kindsOnlyTheOtherCountryHasAreCountedForTheLineUnderTheCards() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/r/us.pdf": VaultFixtures.licensePage,
                                                                    "/r/pan.pdf": VaultIDReadingTests.panCard]))
        model.geoFilter = .us
        let elsewhere = try #require(model.elsewhereKinds)
        #expect(elsewhere.filter == .india && elsewhere.count == 1)
    }

    @Test func aNumberAddedForSomeoneTheFilterHidesIsShown() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        await model.opened()
        model.personFilter = .person("anna")
        let id = try #require(model.add(VaultModel.Draft(title: "Loan", value: "1234567890", personID: "bob",
                                                         category: .loans)))
        #expect(model.personFilter == .everyone)
        #expect(model.visibleRows.contains { $0.id == id })
        #expect(model.selection == id)
    }
}
