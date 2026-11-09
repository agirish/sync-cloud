import Foundation
import Testing
@testable import Sync

/// "Copy Log for Sharing" masks what identifies the owner, and nothing a reader needs.
@Suite struct LogSharingTests {
    static let people = [
        Person(id: "anna-smith", displayName: "Anna", fullNames: ["Anna Smith"], aliases: ["Mom"]),
        Person(id: "bo", displayName: "Bo"),
    ]

    func mask(_ text: String) -> String {
        LogSharing.mask(text, home: "/Users/jdoe", people: Self.people)
    }

    @Test func emailsGoKeepingTheProviderPrefix() {
        #expect(mask("x@y.com wrote") == "<account> wrote")
        #expect(mask("~/Library/CloudStorage/GoogleDrive-a.b@gmail.com/My Drive")
                == "~/Library/CloudStorage/GoogleDrive-<account>/My Drive")
        #expect(mask("OneDrive-j.d@outlook.com") == "OneDrive-<account>")
    }

    @Test func theHomeFolderGoesInEachForm() {
        #expect(mask("Copied /Users/jdoe/Documents/a.pdf") == "Copied ~/Documents/a.pdf")
        #expect(mask("-Users-jdoe-Projects-x") == "-Users-<you>-Projects-x")
        #expect(mask("account JDoe signed in") == "account <you> signed in")
        // Not a different account's home, and not letters around the name.
        #expect(mask("/Users/jdoely/x") == "/Users/jdoely/x")
    }

    @Test func namesGoWholeAndNumberedInRosterOrder() {
        #expect(mask("Filed into Anna Smith/Taxes") == "Filed into <person 1>/Taxes")
        #expect(mask("anna, Mom and Bo") == "<person 1>, <person 1> and <person 2>")
        #expect(mask("axes.person=anna-smith") == "axes.person=<person 1>")
        // `_`, digits and punctuation are edges; letters aren't.
        #expect(mask("Anna_2024.pdf") == "<person 1>_2024.pdf")
        #expect(mask("Annabel and Bob and Mommy") == "Annabel and Bob and Mommy")
        // Short forms match only their own case: "mom" in prose stays.
        #expect(mask("mom") == "mom")
    }

    /// An account named for its owner, who is also on the roster: the full name is masked whole,
    /// so no surname is left beside a masked first name.
    @Test func anAccountThatIsAlsoAPersonLeavesNoSurname() {
        let masked = LogSharing.mask("Filed for Anna Smith in /Users/anna/Taxes; -Users-anna-x; anna signed in",
                                     home: "/Users/anna", people: Self.people)
        #expect(!masked.contains("Smith"), "\(masked)")
        #expect(masked == "Filed for <person 1> in ~/Taxes; -Users-<you>-x; <person 1> signed in")
        // An account that isn't a name is still masked, last.
        #expect(LogSharing.mask("anna and jdoe", home: "/Users/jdoe", people: Self.people) == "<person 1> and <you>")
    }

    @Test func theFallbackIdPersonIsNeverMasked() {
        let people = [Person(id: "person", displayName: "Ωμέγα")]
        #expect(LogSharing.mask("person Ωμέγα", home: "/Users/jdoe", people: people) == "person <person 1>")
    }

    /// NFD in the log, NFC in the roster: still one name.
    @Test func decomposedAccentsStillMatch() {
        let people = [Person(id: "zoe", displayName: "Zo\u{00E9}")]
        #expect(LogSharing.mask("Zoe\u{0301} filed", home: "/Users/jdoe", people: people) == "<person 1> filed")
    }

    @Test func theRosterReadsEveryProfileOnceById() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogSharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ profile: String, _ json: String) throws {
            let folder = dir.appendingPathComponent(profile)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("people.json"))
        }
        try write("a", #"{"schemaVersion":1,"people":[{"id":"anna","displayName":"Anna"}]}"#)
        try write("b", #"{"schemaVersion":1,"people":[{"id":"anna","displayName":"Anna"},{"id":"bo","displayName":"Bo"}]}"#)
        try write("c", "not json")
        #expect(LogSharing.roster(profilesDirectory: dir).map(\.id) == ["anna", "bo"])
        #expect(LogSharing.roster(profilesDirectory: nil).isEmpty)
    }

    /// With no `people.json`, Settings ▸ People shows a list suggested from the folder survey;
    /// those names are masked too.
    @Test func aSuggestedListIsMaskedToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogSharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("father")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(FilingProfileStoreTests.profileJSON.utf8).write(to: folder.appendingPathComponent("folder-profile.json"))
        let roster = LogSharing.roster(profilesDirectory: dir)
        #expect(!roster.isEmpty)
        let masked = LogSharing.mask("Filed for Father, Mother; Mom and Granny", home: "/Users/jdoe", people: roster)
        for name in ["Father", "Mother", "Mom", "Granny"] { #expect(!masked.contains(name), "\(masked)") }
    }

    /// One id in two profiles: the forms either gives go, not only the first profile's.
    @Test func theSameIdInTwoProfilesKeepsEveryForm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogSharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ profile: String, _ json: String) throws {
            let folder = dir.appendingPathComponent(profile)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appendingPathComponent("people.json"))
        }
        try write("a", #"{"schemaVersion":1,"people":[{"id":"anna","displayName":"Anna","fullNames":[],"aliases":[]}]}"#)
        try write("b", #"{"schemaVersion":1,"people":[{"id":"anna","displayName":"Anna","fullNames":["Anna Kowalczyk"],"aliases":["Mutti"]}]}"#)
        let roster = LogSharing.roster(profilesDirectory: dir)
        #expect(roster.map(\.id) == ["anna"])
        let masked = LogSharing.mask("Mutti and Anna Kowalczyk", home: "/Users/jdoe", people: roster)
        #expect(masked == "<person 1> and <person 1>")
    }

    /// A surname goes however it is joined to the first name, or on its own.
    @Test func aSurnameGoesInAnySpelling() {
        for text in ["Anna_Smith_W2.pdf", "Smith, Anna", "Anna  Smith", "Anna\u{00A0}Smith", "Anna%20Smith", "SMITH ANNA"] {
            #expect(!mask(text).localizedCaseInsensitiveContains("smith"), "\(text) → \(mask(text))")
        }
        // Words of a name are still whole words: "Smithson" stays.
        #expect(mask("Smithson") == "Smithson")
    }

    @Test func anEmailWithAccentsGoesWhole() {
        #expect(mask("anna@müller.de wrote") == "<account> wrote")
        #expect(mask("zoé.x@exemple.fr") == "<account>")
    }

    @Test func theCopyOpensWithItsHeaderAndHoldsTheMaskedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LogSharing-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("[INFO] Copied /Users/jdoe/a.pdf for x@y.com\n".utf8).write(to: file)
        var drained = false
        let copy = try #require(LogSharing.sharedCopy(of: file, drainWriter: { drained = true },
                                                      home: "/Users/jdoe", profilesDirectory: nil))
        #expect(drained)
        #expect(copy.hasPrefix(LogSharing.header + "\n\n"))
        #expect(copy.hasSuffix("[INFO] Copied ~/a.pdf for <account>\n"))
        #expect(LogSharing.sharedCopy(of: file.appendingPathExtension("gone"), drainWriter: {},
                                      home: "/Users/jdoe", profilesDirectory: nil) == nil)
    }
}
