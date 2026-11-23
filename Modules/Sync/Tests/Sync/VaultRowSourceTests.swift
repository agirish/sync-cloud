import Foundation
import Testing
@testable import Sync

/// The rows as a plain value works them out (VT7 d): no model, store, settings or clock, so each
/// rule is seen from exactly what it is given. Every number and name is made up.
@Suite struct VaultRowSourceTests {
    static let root = "/Users/anna/Documents"
    static let day = Date(timeIntervalSince1970: 1_800_000_000)
    static let born = Date(timeIntervalSince1970: 150_000_000)
    static let anna = Person(id: "anna", displayName: "Anna", fullNames: ["Anna Maria Eriksson"])

    static func source(entries: [VaultEntry] = [], finds: [VaultFind] = [], copies: [String: [String: VaultFind]] = [:],
                       names: [String: String] = [:], lessons: [String: VaultCardID] = [:],
                       now: Date = day) -> VaultRowSource {
        VaultRowSource(entries: entries, finds: finds, copies: copies, mentions: [:], missingDocuments: [],
                       holders: VaultHolders(names: names, people: [anna]), lessons: lessons, kinds: VaultKinds(),
                       folders: [root], now: now)
    }

    static func find(_ value: String, _ category: VaultCategory, holder: String? = nil, born: Date? = nil,
                     until: Date? = nil, at path: String) -> VaultFind {
        VaultFind(title: category.singular, value: value,
                  facts: VaultReadFacts(category: category, holder: holder, born: born, validUntil: until,
                                        sources: [VaultSource(path: root + path, role: category.singular, rank: 2)]))
    }

    static func row(_ source: VaultRowSource, _ value: String) throws -> VaultModel.Row {
        try #require(source.rows().rows.first { $0.value == value })
    }

    @Test func theSameSourceGivesTheSameRows() throws {
        // A card read from three copies of one file, which the rows weigh by merging: the copies
        // are a table, so the same source must give the same rows whatever order it yields them.
        let paths = ["/Health/Medical/Anna/card.pdf", "/Health/Medical/Anna/card copy.pdf", "/Health/Medical/Anna/card 2.pdf"]
        let copies = paths.map { Self.find("XZB123456789", .health, at: $0) }
        let saved = VaultEntry(title: "Medical", value: "XZB123456789", addedAt: Self.day, facts: copies[0].facts)
        let source = Self.source(entries: [saved], copies: ["XZB123456789": Dictionary(uniqueKeysWithValues: zip(paths.map { Self.root + $0 }, copies))],
                                 lessons: [Self.root + "/Health/Medical/Anna": .builtIn(.other)])
        let (first, second) = (source.rows(), source.rows())
        #expect(first.rows == second.rows)
        #expect(first.merges == second.merges)
        #expect(first.merges > 0, "the copies were weighed")
        let row = try #require(first.rows.first)
        #expect(Set(row.documents.map(\.path)) == Set(paths.map { Self.root + $0 }))
        #expect(row.card == .builtIn(.other), "its folder's lesson")
        #expect(row.learnedFrom == Self.root + "/Health/Medical/Anna")
    }

    @Test func aPaperWithNoNameBorrowsTheNameOfOneBornTheSameDay() throws {
        let source = Self.source(finds: [
            Self.find("X1234567", .passport, holder: "Anna Maria Eriksson", born: Self.born, at: "/Immigration/Passport/scan.pdf"),
            Self.find("XZB123456789", .health, born: Self.born, at: "/Health/Insurance/card.pdf"),
        ])
        let card = try Self.row(source, "XZB123456789")
        #expect(card.personID == "anna")
        #expect(card.facts?.holder == "Anna Maria Eriksson")
        #expect(card.whose == "Anna")
    }

    @Test func aPaperWithNoNameIsWhoeverFolderItIsFiledIn() throws {
        let filed = try Self.row(Self.source(finds: [Self.find("XZB123456789", .health, at: "/Health/Medical/Anna/card.pdf")]), "XZB123456789")
        #expect(filed.personID == "anna")
        let elsewhere = try Self.row(Self.source(finds: [Self.find("XZB123456789", .health, at: "/Health/Medical/card.pdf")]), "XZB123456789")
        #expect(elsewhere.personID == nil)
        #expect(elsewhere.whose == "Unknown")
    }

    @Test func aNameCorrectedEverywhereIsTheNameMatched() throws {
        let misread = "Amna Svensdotter"
        let found = [Self.find("X1234567", .passport, holder: misread, at: "/Immigration/Passport/scan.pdf")]
        let asRead = try Self.row(Self.source(finds: found), "X1234567")
        #expect(asRead.personID == nil)
        let fixed = try Self.row(Self.source(finds: found, names: [VaultReading.spellingKey(misread): "Anna Maria Eriksson"]), "X1234567")
        #expect(fixed.personID == "anna")
        #expect(fixed.facts?.holder == "Anna Maria Eriksson")
        #expect(fixed.readHolder == misread)
    }

    @Test func aFoldersLessonMovesAnAccountAndKeepsWhatItWasReadAs() throws {
        let path = "/Vehicles/Tesla/2026/Receipt.pdf"
        let folder = VaultKinds.lessonFolder(of: Self.root + path)
        let source = Self.source(finds: [Self.find("1234 5678 9012", .utilities, at: path),
                                         Self.find("X1234567", .passport, holder: "Anna Maria Eriksson", at: "/Vehicles/Tesla/2026/scan.pdf")],
                                 lessons: [folder: .builtIn(.loans)])
        let account = try Self.row(source, "1234 5678 9012")
        #expect(account.card == .builtIn(.loans))
        #expect(account.category == .loans)
        #expect(account.readAs == .utilities)
        #expect(account.learnedFrom == folder)
        // A passport is known by its reader, and no lesson moves it.
        #expect(try Self.row(source, "X1234567").card == .builtIn(.passport))
    }

    @Test func theDayItIsWorkedOutForIsAnInput() throws {
        let found = [Self.find("X1234567", .passport, holder: "Anna Maria Eriksson", until: Self.day.addingTimeInterval(86_400),
                               at: "/Immigration/Passport/scan.pdf")]
        #expect(try Self.row(Self.source(finds: found), "X1234567").standing.expired == false)
        #expect(try Self.row(Self.source(finds: found, now: Self.day.addingTimeInterval(3 * 86_400)), "X1234567").standing.expired)
    }

    @Test func aNumberTypedInForNobodyIsTheHouseholds() throws {
        let typed = VaultEntry(title: "Gym card", value: "GYM5550001", addedAt: Self.day)
        let row = try Self.row(Self.source(entries: [typed]), "GYM5550001")
        #expect(row.isSaved)
        #expect(row.isHousehold)
        #expect(row.whose == "Household")
    }
}
