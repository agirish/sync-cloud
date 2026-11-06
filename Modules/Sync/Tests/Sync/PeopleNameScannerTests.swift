import Foundation
import Testing
@testable import Sync

/// The disk-reading half of person-name learning; the pure rule, `PersonNameLearning`, is covered
/// by ``PersonLearningTests``. This stages real trees, and guards the two filesystem rules: an
/// unreadable folder must not cost the sweep, and a subfolder's name is not a document's name.
@Suite struct PeopleNameScannerTests {

    // The learning suite's household shape: Granny deliberately lacks "Granny Elder". Father is
    // needed: a run is a name only if every word is one somebody answers to, and his full name is
    // the only source of "Elder". Without him the sweep tests have nothing to find.
    static let household = PersonRegistry(people: [
        Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
        Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        Person(id: "granny", displayName: "Granny", aliases: ["Mom"]),
    ])

    static func profile(folders: [(String, String)]) -> FolderProfile {
        var entries: [String: FolderProfileEntry] = [:]
        for (path, person) in folders {
            entries[path] = FolderProfileEntry(path: path, role: .personBucket, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 3,
                                               subfolderCount: 0, axes: ["person": person])
        }
        return FolderProfile(profileId: "t", root: "~", folders: entries,
                             personTokens: ["granny", "daughter", "father"])
    }

    /// Stages a tree under a fresh temporary root and hands back the root.
    static func stage(_ tree: [String: [String]]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PeopleNameScannerTests-\(UUID().uuidString)")
        for (folder, names) in tree {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                try Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }
        }
        return root
    }

    // MARK: - What it reads

    @Test func itListsTheFilesOfEveryPersonFolder() throws {
        let root = try Self.stage(["Family/Granny": ["Granny Elder - 2015.pdf", "Old.pdf"],
                                   "School/Daughter": ["Report.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = PeopleNameScanner.fileNames(
            registry: Self.household,
            profile: Self.profile(folders: [("Family/Granny", "Granny"), ("School/Daughter", "Daughter")]),
            root: root)

        #expect(names["Family/Granny"]?.sorted() == ["Granny Elder - 2015.pdf", "Old.pdf"])
        #expect(names["School/Daughter"] == ["Report.pdf"])
    }

    /// A subfolder's name is not a document's name. Without the directory check, a folder called
    /// "Granny Elder" inside Granny's would vouch for the very form the sweep is trying to learn.
    @Test func aSubfolderNameIsNotReadAsAFileName() throws {
        let root = try Self.stage(["Family/Granny": ["Statement.pdf"],
                                   "Family/Granny/Granny Elder": ["Inner.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = PeopleNameScanner.fileNames(registry: Self.household,
                                                profile: Self.profile(folders: [("Family/Granny", "Granny")]),
                                                root: root)

        #expect(names["Family/Granny"] == ["Statement.pdf"])
        #expect(names["Family/Granny"]?.contains("Granny Elder") != true,
                "read a subfolder's name as a document's")
    }

    @Test func dotFilesAreNotDocuments() throws {
        let root = try Self.stage(["Family/Granny": ["Real.pdf", ".DS_Store"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = PeopleNameScanner.fileNames(registry: Self.household,
                                                profile: Self.profile(folders: [("Family/Granny", "Granny")]),
                                                root: root)
        #expect(names["Family/Granny"] == ["Real.pdf"])
    }

    /// An empty folder is absent from the map, not present and empty: the rule downstream counts
    /// folders it read something from.
    @Test func aFolderWithNoFilesIsOmitted() throws {
        let root = try Self.stage(["Family/Granny": [], "School/Daughter": ["Report.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let names = PeopleNameScanner.fileNames(
            registry: Self.household,
            profile: Self.profile(folders: [("Family/Granny", "Granny"), ("School/Daughter", "Daughter")]),
            root: root)

        #expect(names["Family/Granny"] == nil)
        #expect(names.count == 1)
    }

    // MARK: - The rule this type exists to keep

    /// One unreadable folder must not cost the rest. A person's folder on an evicted iCloud path is
    /// ordinary, and the sweep skips it and keeps going. Staged as a missing folder, which is what
    /// `contentsOfDirectory` reports for an unreachable path. It sorts first, so a sweep that gave
    /// up on failure would return nothing.
    @Test func anUnreadableFolderIsSkippedAndTheRestStillRead() throws {
        let root = try Self.stage(["Family/Granny": ["Granny Elder - 2015.pdf"],
                                   "School/Daughter": ["Report.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }
        // Named in the profile, absent from the tree; "Archive" sorts before both real folders.
        let profile = Self.profile(folders: [("Archive/Gone", "Granny"), ("Family/Granny", "Granny"),
                                             ("School/Daughter", "Daughter")])

        let names = PeopleNameScanner.fileNames(registry: Self.household, profile: profile, root: root)

        #expect(names["Archive/Gone"] == nil, "invented contents for a folder it could not read")
        #expect(names["Family/Granny"] == ["Granny Elder - 2015.pdf"],
                "an unreadable folder stopped the sweep reaching the readable ones")
        #expect(names["School/Daughter"] == ["Report.pdf"])
    }

    /// The whole sweep, end to end: `suggestions` must feed what it read into the rule, or the rule
    /// stays correct and the feature dead.
    @Test func theSweepLearnsFromWhatItRead() throws {
        let root = try Self.stage(["Family/Granny": ["Granny Elder - Old.pdf",
                                                     "Granny Elder - 2015.pdf"],
                                   "Immigration/Passport/Granny": ["Granny Elder passport.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Self.profile(folders: [("Family/Granny", "Granny"),
                                             ("Immigration/Passport/Granny", "Granny")])

        let found = PeopleNameScanner.suggestions(registry: Self.household, profile: profile,
                                                  root: root, dismissed: [])

        let suggestion = try #require(found.first)
        #expect(suggestion.personId == "granny")
        #expect(suggestion.form == "Granny Elder")
        #expect(suggestion.occurrences == 3)
    }

    /// A dismissed form is not offered again: the parameter reaches the rule.
    @Test func aDismissedFormIsNotOffered() throws {
        let root = try Self.stage(["Family/Granny": ["Granny Elder - Old.pdf",
                                                     "Granny Elder - 2015.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Self.profile(folders: [("Family/Granny", "Granny")])

        let offered = PeopleNameScanner.suggestions(registry: Self.household, profile: profile,
                                                    root: root, dismissed: [])
        let ids = Set(offered.map(\.id))
        #expect(!ids.isEmpty, "fixture offered nothing, so dismissing it proves nothing")

        let after = PeopleNameScanner.suggestions(registry: Self.household, profile: profile,
                                                  root: root, dismissed: ids)
        #expect(after.isEmpty)
    }
}
