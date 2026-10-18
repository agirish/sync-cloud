import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The Files tab's folder menu: what the survey offers to step into, and how the trail turns a
/// pick into a place the pane can go.
@Suite struct EditorRailFolderMenuTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-rail-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func folder(_ name: String, in parent: URL) throws {
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(name),
                                                withIntermediateDirectories: true)
    }

    private func file(_ name: String, in parent: URL) throws {
        try Data("a".utf8).write(to: parent.appendingPathComponent(name))
    }

    private let nothingIsCloudOnly: (String) -> Bool = { _ in false }

    // MARK: What the survey offers

    /// **The folders inside, in Finder's order, and nothing else** — "Year 2" before "Year 10", no
    /// file, and a folder named like a text file offered as the folder it is. Asked of a folder that
    /// also lists rows, AND of one that lists none, since the two return through different exits.
    @Test func theSurveyNamesTheFoldersInsideInFindersOrder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Year 10", "Year 2", "archive.md"] { try folder(name, in: root) }
        try file("notes.md", in: root)
        try file("photo.jpg", in: root)

        let listed = EditorRail.survey(in: root.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly, links: [:])
        #expect(listed.rows.map(\.name) == ["notes.md"])
        #expect(listed.folders == ["archive.md", "Year 2", "Year 10"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.md"))
        let unlisted = EditorRail.survey(in: root.path, showsHidden: false,
                                         isCloudOnly: nothingIsCloudOnly, links: [:])
        #expect(unlisted.rows.isEmpty)
        #expect(unlisted.folders == ["archive.md", "Year 2", "Year 10"],
                "a folder with nothing to open listed no way into its subfolders")
    }

    /// The pane's rule for hidden — a leading dot — so the menu offers what the pane lists.
    @Test func hiddenFoldersFollowTheAppsOwnPreference() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try folder("Visible", in: root)
        try folder(".git", in: root)

        #expect(EditorRail.survey(in: root.path, showsHidden: false,
                                  isCloudOnly: nothingIsCloudOnly, links: [:]).folders == ["Visible"])
        #expect(EditorRail.survey(in: root.path, showsHidden: true,
                                  isCloudOnly: nothingIsCloudOnly, links: [:]).folders == [".git", "Visible"])
    }

    /// **A folder the root links in from outside is a folder** — iCloud Drive's `Documents` is a
    /// link to `~/Documents`, which lists as a link, not a directory; the pane shows it as a folder,
    /// so the menu must too. Mutation: drop the `linked` term and `Documents` vanishes.
    @Test func aLinkedFolderAtTheRootIsOffered() throws {
        let root = try scratch()
        let elsewhere = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        try folder("Photos", in: root)
        let documents = elsewhere.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents"),
                                                   withDestinationURL: documents)

        let survey = EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly,
                                       links: [root.path: ["Documents": documents.path]])
        #expect(survey.folders == ["Documents", "Photos"])
        // The control: the same link, unnamed by the table, is not taken for a folder.
        #expect(EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly,
                                  links: [:]).folders == ["Photos"])
    }

    /// Unreadable reports nothing to step into, as it reports nothing to open.
    @Test func anUnreadableFolderOffersNoFolders() {
        #expect(EditorRail.survey(in: "/nowhere/at/all", showsHidden: false,
                                  isCloudOnly: nothingIsCloudOnly, links: [:]).folders.isEmpty)
    }

    // MARK: Where a pick goes

    /// A subfolder's target is the folder's own plus its name — the bare name at the top of the
    /// source, where the folder's target is `""`.
    @Test func aSubfoldersTargetIsBuiltFromTheFolders() {
        let deep = EditorFolderTrail(levels: [], currentTarget: "Documents/Family", subfolders: [])
        #expect(deep.target(forSubfolder: "Anuraag") == "Documents/Family/Anuraag")
        let top = EditorFolderTrail(levels: [], currentTarget: "", subfolders: [])
        #expect(top.target(forSubfolder: "Documents") == "Documents")
        let outside = EditorFolderTrail(levels: [], currentTarget: nil, subfolders: ["X"])
        #expect(outside.target(forSubfolder: "X") == nil,
                "a folder outside the pane's source offered a subfolder the pane cannot reach")
    }

    /// **The path reads from the folder up**, Finder's order, so under the subfolders the whole
    /// menu walks one way.
    @Test func thePathReadsFromTheFolderUp() {
        let trail = EditorFolderTrail(levels: [.init(name: "iCloud", target: ""),
                                               .init(name: "Documents", target: "Documents"),
                                               .init(name: "Family", target: nil)],
                                      currentTarget: "Documents/Family", subfolders: [])
        #expect(trail.upward.map(\.name) == ["Family", "Documents", "iCloud"])
    }

    /// A trail with nowhere to go draws the plain line, not a menu of greyed rows; one door
    /// anywhere — a level up, or a subfolder of a folder the pane can reach — is enough for a menu.
    @Test func aMenuIsDrawnOnlyWhereThereIsSomewhereToGo() {
        let nowhere = EditorFolderTrail(levels: [.init(name: "Scratch", target: nil)],
                                        currentTarget: nil, subfolders: ["Inside"])
        #expect(!nowhere.offersAnything)
        let atTheTopWithNothingInside = EditorFolderTrail(levels: [.init(name: "iCloud", target: nil)],
                                                          currentTarget: "", subfolders: [])
        #expect(!atTheTopWithNothingInside.offersAnything)
        let atTheTop = EditorFolderTrail(levels: [.init(name: "iCloud", target: nil)],
                                         currentTarget: "", subfolders: ["Documents"])
        #expect(atTheTop.offersAnything)
        let below = EditorFolderTrail(levels: [.init(name: "iCloud", target: ""), .init(name: "A", target: nil)],
                                      currentTarget: "A", subfolders: [])
        #expect(below.offersAnything)
    }
}
