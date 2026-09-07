import Foundation
import Testing
@testable import Sync

/// The disk-reading half of person-name learning.
///
/// `PersonNameLearning` — the pure rule over `folder → filenames` — is covered by
/// ``PersonLearningTests``. This covers the part that stages a real tree and reads it, and in
/// particular the two rules that only exist here because they are about the filesystem: an
/// unreadable folder must not cost the sweep, and a subfolder's *name* is not a document's name.
@Suite struct PeopleNameScannerTests {

    // Same household shape the learning suite uses, so a form that reaches the rule from here is
    // one that suite would recognise: Granny deliberately lacks "Granny Elder".
    //
    // **Father is load-bearing, not padding.** A run is a name only when every word in it is one
    // somebody in the household answers to, and the household's only source of "Elder" is his
    // full name — drop him and "Granny Elder" stops being a name at all, which is how the first
    // draft of this fixture silently offered nothing for the sweep tests to find.
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

    /// **A subfolder's name is not a document's name.** Without the directory check a folder called
    /// "Granny Elder" sitting inside Granny's folder would vouch for the very form the sweep is
    /// trying to learn — the folder naming itself as evidence about itself.
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

    /// An empty folder is absent from the map rather than present-and-empty — the rule downstream
    /// counts folders it read something from.
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

    /// **One unreadable folder must not cost the other four hundred.** A person's folder on an
    /// evicted iCloud path is an ordinary state; the documented promise is that the sweep skips it
    /// and keeps going. Staged as a folder that simply is not there, which is what a `contentsOfDirectory`
    /// on an unreachable path reports.
    ///
    /// The fixture is arranged so the assertion cannot pass by accident: the *first* folder in
    /// sorted order is the missing one, so a sweep that gave up on failure would return nothing at
    /// all rather than a smaller map.
    @Test func anUnreadableFolderIsSkippedAndTheRestStillRead() throws {
        let root = try Self.stage(["Family/Granny": ["Granny Elder - 2015.pdf"],
                                   "School/Daughter": ["Report.pdf"]])
        defer { try? FileManager.default.removeItem(at: root) }
        // Named in the profile, absent from the tree — "Archive" sorts before both real folders.
        let profile = Self.profile(folders: [("Archive/Gone", "Granny"), ("Family/Granny", "Granny"),
                                             ("School/Daughter", "Daughter")])

        let names = PeopleNameScanner.fileNames(registry: Self.household, profile: profile, root: root)

        #expect(names["Archive/Gone"] == nil, "invented contents for a folder it could not read")
        #expect(names["Family/Granny"] == ["Granny Elder - 2015.pdf"],
                "an unreadable folder stopped the sweep reaching the readable ones")
        #expect(names["School/Daughter"] == ["Report.pdf"])
    }

    /// The whole sweep, end to end: read the tree, then learn from it. Pins that `suggestions`
    /// actually feeds what it read into the rule — the seam where a wiring slip would leave the
    /// rule correct and the feature dead.
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

    /// A dismissed form is not offered again — the parameter is threaded, not dropped on the floor.
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
