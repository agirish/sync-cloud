import Foundation
import Testing
@testable import Sync

/// Whose a number is, and which of a person's numbers is current (``VaultStandings``).
@Suite struct VaultPeopleTests {
    @Test func aNameTwoPeopleShareIsNoKeyForAnUndatedDocument() {
        func i94(_ value: String, born: Date?, entered: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .i94,
                               facts: VaultReadFacts(category: .i94, holder: "Anna Eriksson", born: born, dated: entered,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "I-94", rank: 30)]),
                               pin: nil)
        }
        let mother = i94("11111111111", born: VaultFixtures.day(1960, 1, 1), entered: VaultFixtures.day(2024, 1, 1))
        let daughter = i94("22222222222", born: VaultFixtures.day(1990, 1, 1), entered: VaultFixtures.day(2024, 2, 1))
        let undated = i94("33333333333", born: nil, entered: VaultFixtures.day(2025, 1, 1))
        for order in [[mother, daughter, undated], [daughter, mother, undated]] {
            let out = VaultStandings.compute(order, now: VaultStandingsTests.today)
            #expect(out[mother.id]?.tab == .current, "one person's only I-94 was archived")
            #expect(out[daughter.id]?.tab == .current, "one person's only I-94 was archived")
        }
    }

    @Test func twinsShareABirthDateAndNothingElse() {
        let born = VaultReadingTests.day(2015, 3, 1)
        let s = VaultStandingsTests.self
        let liv = s.input("C1", .passport, born: born, holder: "Liv Eriksson", issuer: "SWE",
                          dated: s.day(2030, 9, 23), until: s.day(2030, 9, 23))
        let nils = s.input("C2", .passport, born: born, holder: "Nils Eriksson", issuer: "SWE",
                           dated: s.day(2029, 4, 2), until: s.day(2029, 4, 2))
        let nilsI94 = s.input("I1", .i94, born: born, holder: "Nils Eriksson", dated: s.day(2024, 6, 1), until: s.day(2027, 6, 1))
        // Read with no name: it could be either twin's, so it replaces neither one's.
        let unnamed = s.input("I2", .i94, born: born, dated: s.day(2025, 6, 1), until: s.day(2028, 6, 1))
        #expect(s.tabs([liv, nils, nilsI94, unnamed]) == [.current, .current, .current, .current])
    }

    @Test func aGoodVisaOfAnotherClassIsNotReplacedByANewerOne() {
        let anna = VaultFixtures.day(1974, 8, 12)
        func visa(_ value: String, _ visaClass: String, dated: Date, until: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .usVisa,
                               facts: VaultReadFacts(category: .usVisa, born: anna, issuer: "USA", dated: dated, validUntil: until,
                                                     details: [VaultDetail("Visa class", .text(visaClass))],
                                                     sources: [VaultSource(path: "/docs/v.pdf", role: "Visa foil", rank: 40)]),
                               pin: nil)
        }
        let visitor = visa("V1", "B1/B2", dated: VaultFixtures.day(2019, 3, 1), until: VaultFixtures.day(2029, 2, 28))
        let work = visa("V2", "H-1B", dated: VaultFixtures.day(2025, 10, 2), until: VaultFixtures.day(2028, 9, 30))
        let oldWork = visa("V0", "H-1B", dated: VaultFixtures.day(2022, 10, 2), until: VaultFixtures.day(2027, 9, 30))
        #expect(VaultStandingsTests.tabs([visitor, work, oldWork]) == [.current, .current, .archive])
    }

    @Test func oneVisaClassWrittenTwoWaysIsOneClass() {
        let anna = VaultFixtures.day(1974, 8, 12)
        func visa(_ value: String, _ visaClass: String, dated: Date, until: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .usVisa,
                               facts: VaultReadFacts(category: .usVisa, born: anna, issuer: "USA", dated: dated, validUntil: until,
                                                     details: [VaultDetail("Visa class", .text(visaClass))],
                                                     sources: [VaultSource(path: "/docs/v.pdf", role: "Visa foil", rank: 40)]),
                               pin: nil)
        }
        let old = visa("V0", "H1B", dated: VaultFixtures.day(2022, 10, 2), until: VaultFixtures.day(2027, 9, 30))
        let new = visa("V1", "H-1B", dated: VaultFixtures.day(2025, 10, 2), until: VaultFixtures.day(2028, 9, 30))
        #expect(VaultStandingsTests.tabs([old, new]) == [.archive, .current])
    }

    @Test func aFirstNameMisreadByOneLetterIsStillOnePerson() {
        let born = VaultFixtures.day(1988, 3, 4)
        let s = VaultStandingsTests.self
        let old = s.input("P0", .passport, born: born, holder: "Henrlk Lindqvist", issuer: "IND",
                          dated: s.day(2022, 5, 16), until: s.day(2022, 5, 16))
        let new = s.input("P1", .passport, born: born, holder: "Henrik Lindqvist", issuer: "IND",
                          dated: s.day(2032, 5, 16), until: s.day(2032, 5, 16))
        #expect(s.tabs([old, new]) == [.archive, .current])
        #expect(VaultPeopleClusters.sameFirstName("l", "lindqvist"))
        #expect(!VaultPeopleClusters.sameFirstName("liv", "nils"))
        #expect(!VaultPeopleClusters.sameFirstName("anna", "erik"))
    }
}

/// Whose a number is, as the model shows it: borrowed names, choices the user made.
@MainActor
@Suite struct VaultPeopleModelTests {
    typealias Rig = VaultModelTests.Rig
    typealias InterruptingProof = VaultFixtures.InterruptingProof

    @Test func oneNamesDocumentsAreWeighedTogetherWithAndWithoutABirthDate() {
        let anna = VaultIDReadingTests.day(1974, 8, 12)
        func i94(_ value: String, born: Date?, entered: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .i94,
                               facts: VaultReadFacts(category: .i94, holder: "Anna Eriksson", born: born, dated: entered,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "I-94", rank: 30)]),
                               pin: nil)
        }
        let printout = i94("11111111111", born: anna, entered: VaultIDReadingTests.day(2024, 4, 1))
        let tearOff = i94("22222222222", born: nil, entered: VaultIDReadingTests.day(2026, 1, 9))
        let out = VaultStandings.compute([printout, tearOff], now: VaultStandingsTests.today)
        #expect(out[tearOff.id]?.tab == .current)
        #expect(out[printout.id]?.tab == .archive)
    }

    @Test func twoPeopleWithOneNameAreNeverJoined() {
        func ssn(_ value: String, form: String, born: Date) -> VaultStandingInput {
            VaultStandingInput(id: UUID(), value: value, category: .ssn,
                               facts: VaultReadFacts(category: .ssn, holder: "Anna Eriksson", born: born, form: form,
                                                     sources: [VaultSource(path: "/r/\(value).pdf", role: "card", rank: 40)]),
                               pin: nil)
        }
        let mother = ssn("123456789", form: "SSN", born: VaultIDReadingTests.day(1950, 1, 1))
        let daughter = ssn("912701234", form: "ITIN", born: VaultIDReadingTests.day(1990, 1, 1))
        let out = VaultStandings.compute([mother, daughter], now: VaultStandingsTests.today)
        #expect(out[daughter.id]?.tab == .current, "an ITIN gave way to someone else's SSN")
    }

    @Test func aNumberTheUserMovedStaysWhereTheyPutIt() {
        let anna = VaultIDReadingTests.day(1974, 8, 12)
        let read = VaultStandingInput(id: UUID(), value: "X1", category: .passport,
                                      facts: VaultReadFacts(category: .passport, holder: "Anna Eriksson", born: anna,
                                                            issuer: "SWE", dated: VaultIDReadingTests.day(2032, 1, 1),
                                                            sources: [VaultSource(path: "/r/a.pdf", role: "p", rank: 40)]),
                                      pin: nil)
        var moved = read
        moved.id = UUID()
        moved.value = "X2"
        moved.facts?.dated = VaultIDReadingTests.day(2030, 1, 1)
        moved.assignment = .household
        moved.isChosen = true
        let out = VaultStandings.compute([read, moved], now: VaultStandingsTests.today)
        #expect(out[read.id]?.tab == .current)
        #expect(out[moved.id]?.tab == .current, "a number moved to the household was weighed against Anna's")
    }

    @Test func aDatedCopySpeaksOverAnUndatedOneOfTheSameKind() {
        func facts(_ until: Date?) -> VaultReadFacts {
            VaultReadFacts(category: .driversLicense, validUntil: until,
                           sources: [VaultSource(path: "/r/x.pdf", role: "card", rank: 40)])
        }
        #expect(VaultModel.supersedes(facts(VaultIDReadingTests.day(2030, 1, 1)), facts(nil)))
        #expect(!VaultModel.supersedes(facts(nil), facts(VaultIDReadingTests.day(2030, 1, 1))))
    }
}
