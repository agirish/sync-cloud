import Foundation
import Testing
@testable import Sync

/// One read of a tree, and everything the setup sheet asks of it. The sheet's counts (folders,
/// files, loose files, documents a survey would read) must agree with what the profile and the
/// document survey do with the same tree; these pin that on fixtures. The guards at the top of
/// ``FileSyncManager/walkForSetup(root:known:)`` are pinned against a real directory, since what
/// they guard against is a filesystem answering unhelpfully.
@MainActor
@Suite struct SetupWalkTests {

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manager(profiles: URL?) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingProfilesDirectory = profiles
        return m
    }

    /// The failure side of a result, so a `Result<SetupWalk, _>` need not be `Equatable` just to
    /// let a test say which refusal it got.
    private static func failure(_ result: Result<SetupWalk, FileSyncManager.FolderWalkFailure>)
        -> FileSyncManager.FolderWalkFailure? {
        if case .failure(let why) = result { return why }
        return nil
    }

    private static func summary(folders: [String], files: [String],
                                known: Set<String> = []) -> SetupWalk {
        SetupWalk.summarising(tree: FixtureTree.of(folders: folders, files: files),
                              root: URL(fileURLWithPath: "/root"), recordedRoot: "/root",
                              known: known)
    }

    // MARK: - The counts

    /// The counting is the survey's, not a second opinion. Dot-directories, symlinks and unexplored
    /// subtrees get no profile entry, so counting them would promise folders the profile won't
    /// describe (the reason ``FolderSurveyBuilder/isSurveyedFolder(_:)`` is public).
    @Test func whatTheSurveyWillNotDescribeIsNotCounted() {
        let tree = [
            FileNode(id: "/root/Finance", name: "Finance", isDirectory: true, children: []),
            FileNode(id: "/root/.git", name: ".git", isDirectory: true, children: []),
            FileNode(id: "/root/Link", name: "Link", isDirectory: true, children: [],
                     isSymbolicLink: true),
            FileNode(id: "/root/Deep", name: "Deep", isDirectory: true, children: [],
                     isUnexplored: true),
        ]
        let walk = SetupWalk.summarising(tree: tree, root: URL(fileURLWithPath: "/root"),
                                         recordedRoot: "/root", known: [])
        #expect(walk.folderCount == 1)
    }

    // MARK: - Loose files

    /// Loose means depth 0. A file inside a folder already has a home; the Structure screen offers
    /// to route only the ones that don't.
    @Test func looseFilesAreTheRootsOwnFilesOnly() {
        let walk = Self.summary(folders: ["Finance"],
                                files: ["statement.pdf", "notes.txt", "Finance/filed.pdf"])
        #expect(walk.looseFileNames == ["notes.txt", "statement.pdf"], "sorted, and depth 0 only")
    }

    /// `.DS_Store` is Finder's bookkeeping; offering to file it would invent work.
    @Test func dotFilesAreNotLoose() {
        let walk = Self.summary(folders: [], files: [".DS_Store", "real.pdf"])
        #expect(walk.looseFileNames == ["real.pdf"])
        #expect(walk.fileCount == 1)
    }

    // MARK: - The document count

    /// The number setup shows before offering to read documents is the survey's own list length,
    /// so the offer cannot promise a different amount of work than the survey does.
    @Test func onlyReadableExtensionsCountAsDocuments() {
        let walk = Self.summary(folders: ["Finance"],
                                files: ["a.pdf", "b.txt", "c.csv", "d.jpg",
                                        "e.sparsebundle", "f.key", "Finance/g.png"])
        #expect(walk.documentCount == 5, "pdf, txt, csv, jpg and the nested png; not key or sparsebundle")
        #expect(walk.documentCount == FilingSurvey.documentsToRead(
            tree: FilingSurvey.flatten(FixtureTree.of(folders: ["Finance"],
                                                      files: ["a.pdf", "b.txt", "c.csv", "d.jpg",
                                                              "e.sparsebundle", "f.key",
                                                              "Finance/g.png"])),
            corpus: nil).count)
    }

    // MARK: - The proposals

    /// Somebody already on the roster is not offered back.
    @Test func knownNamesAreNotProposedAgain() {
        let walk = Self.summary(folders: ["Family/Mother", "Family/Father"], files: [],
                                known: ["Mother"])
        #expect(walk.people.map(\.name) == ["Father"])
    }

    // MARK: - The preview

    /// The preview is the profile, minus the writing. If the two could disagree, the Structure
    /// screen would describe a tree that Save then files differently.
    @Test func thePreviewSaysWhatTheWrittenProfileSays() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        for path in ["Finance/US/Income Tax/2024", "Finance/TODO", "Family/Mother"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        let m = manager(profiles: profiles)
        let walk = try #require(try? (await m.walkForSetup(root: root)).get())
        let registry = PersonRegistry(people: [Person(id: "p1", displayName: "Mother",
                                                      relationship: "mother")])

        let preview = FileSyncManager.previewProfile(walk: walk, registry: registry,
                                                     jurisdictionValues: ["US"])
        let report = try #require(try? (await m.writeWalkProfile(tree: walk.tree, root: root,
                                                                 jurisdictionValues: ["US"],
                                                                 registry: registry)).get())
        let written = try #require(FilingProfileStore.profile(id: report.profileId, in: profiles))

        #expect(preview.folders.count == written.folders.count)
        for (path, entry) in written.folders {
            let shown = try #require(preview.folders[path], "the preview omitted \(path)")
            #expect(shown.role == entry.role)
            #expect(shown.axes == entry.axes)
            #expect(shown.anchors == entry.anchors)
            #expect(shown.fileCount == entry.fileCount)
            #expect(shown.subfolderCount == entry.subfolderCount)
        }
    }

    /// A preview writes nothing, not a directory, not an index entry. Back on Structure rebuilds the
    /// preview each time; a preview that made a profile would leave a directory per press, and
    /// `writeProfile` refuses over an id that already exists.
    @Test func aPreviewLeavesNothingOnDisk() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Finance"),
                                                withIntermediateDirectories: true)
        let walk = try #require(try? (await manager(profiles: profiles).walkForSetup(root: root)).get())
        for _ in 0..<3 {
            _ = FileSyncManager.previewProfile(walk: walk, registry: nil, jurisdictionValues: [])
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
        #expect(left.isEmpty, "a preview left \(left) behind")
    }

    // MARK: - The guards

    /// Nowhere to write is reported on the screen that offered to read, not four screens later.
    @Test func noProfilesDirectoryFailsBeforeTouchingTheDisk() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await manager(profiles: nil).walkForSetup(root: root)
        #expect(Self.failure(result) == .noProfilesDirectory)
    }

    /// A missing path reads as one folder to `buildTree`, so the filesystem is asked instead, as in
    /// `deriveFolderProfile`.
    @Test func aMissingRootIsUnreadableRatherThanAOneFolderTree() async throws {
        let profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: profiles) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-there-\(UUID().uuidString)")
        let result = await manager(profiles: profiles).walkForSetup(root: missing)
        #expect(Self.failure(result) == .rootUnreadable(missing.path))
    }

    /// A readable folder with no folders under it can't make a profile worth writing, and the place
    /// to say so is Learn, where the user can pick another folder.
    @Test func aFolderWithNoFoldersFailsAtLearnNotAtSave() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        try "x".write(to: root.appendingPathComponent("alone.pdf"), atomically: true, encoding: .utf8)
        let result = await manager(profiles: profiles).walkForSetup(root: root)
        #expect(Self.failure(result) == .nothingToLearn(root.path))
    }

    /// End to end: one call returns every list the sheet needs.
    @Test func oneWalkAnswersEveryScreen() async throws {
        let root = try Self.scratch(), profiles = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: profiles) }
        for path in ["Family/Mother", "Family/Father", "Finance/US/Tax", "Legal/US", "School/US"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("loose.pdf"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Finance/US/Tax/filed.pdf"),
                      atomically: true, encoding: .utf8)

        let walk = try #require(try? (await manager(profiles: profiles).walkForSetup(root: root)).get())
        #expect(walk.root == root)
        #expect(walk.folderCount == 10, "Family, Mother, Father, Finance, US, Tax, Legal, US, School, US")
        #expect(walk.fileCount == 2)
        #expect(walk.looseFileNames == ["loose.pdf"])
        #expect(walk.documentCount == 2)
        #expect(Set(walk.people.map(\.name)) == ["Mother", "Father"])
        #expect(walk.places.map(\.value) == ["US"])
        #expect(!walk.tree.isEmpty, "the tree is retained, which is the point of walking once")
    }
}
