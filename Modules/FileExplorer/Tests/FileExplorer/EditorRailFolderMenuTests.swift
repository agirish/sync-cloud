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
                                       isCloudOnly: nothingIsCloudOnly)
        #expect(listed.rows.map(\.name) == ["notes.md"])
        #expect(listed.folders == ["archive.md", "Year 2", "Year 10"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.md"))
        let unlisted = EditorRail.survey(in: root.path, showsHidden: false,
                                         isCloudOnly: nothingIsCloudOnly)
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
                                  isCloudOnly: nothingIsCloudOnly).folders == ["Visible"])
        #expect(EditorRail.survey(in: root.path, showsHidden: true,
                                  isCloudOnly: nothingIsCloudOnly).folders == [".git", "Visible"])
    }

    /// **A link that leads to a folder is a folder** (TE205) — as the pane lists it, which follows
    /// the link. Out of the folder (iCloud Drive's `Documents` is a link to `~/Documents`) and to a
    /// sibling; while a link to a file, a dangling link and a hidden link to a folder are not
    /// offered. Asked of a folder that lists rows and of one that lists none, the two exits.
    /// Mutation: drop the link term and `Documents` and `Shortcut` vanish; drop the follow and
    /// `Readme` and `Gone` appear.
    @Test func aLinkToAFolderIsOfferedAndALinkToNothingIsNot() throws {
        let root = try scratch()
        let elsewhere = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let fm = FileManager.default
        try folder("Photos", in: root)
        try folder("Documents", in: elsewhere)
        try file("readme.md", in: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Documents"),
                                  withDestinationURL: elsewhere.appendingPathComponent("Documents"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Shortcut").path, withDestinationPath: "Photos")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent(".Hidden").path, withDestinationPath: "Photos")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Readme").path, withDestinationPath: "readme.md")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Gone").path, withDestinationPath: "nowhere")

        let listed = EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(listed.rows.map(\.name) == ["readme.md"])
        #expect(listed.folders == ["Documents", "Photos", "Shortcut"])
        #expect(EditorRail.survey(in: root.path, showsHidden: true, isCloudOnly: nothingIsCloudOnly).folders
                == [".Hidden", "Documents", "Photos", "Shortcut"])

        try fm.removeItem(at: root.appendingPathComponent("readme.md"))
        let unlisted = EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(unlisted.rows.isEmpty)
        #expect(unlisted.folders == ["Documents", "Photos", "Shortcut"])
        // Both links now lead nowhere, and neither is counted as a file the rail will not open.
        #expect(unlisted.otherFileCount == 0)
    }

    /// **A plain entry costs the folders nothing; a link costs one follow.** The survey runs after
    /// every autosave, so a folder of 300 files must not be `stat`ed 300 times for a menu: the
    /// listing names its links from the enumerator's prefetched answer, and only those are followed.
    /// Counted through the `FileManaging` the survey is handed — the one row is its own `stat`, the
    /// three links one each. The prefetch needs no pin of its own: the listing names no links unless
    /// it was asked with the key, so a survey that dropped it would lose `Linked` here and fail.
    @Test func onlyALinkIsFollowedAndTheListingPrefetchesTheAnswer() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for index in 0..<300 { try file("photo \(index).jpg", in: root) }
        try folder("Inside", in: root)
        try file("notes.md", in: root)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Linked").path, withDestinationPath: "Inside")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("ToFile").path, withDestinationPath: "notes.md")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Gone").path, withDestinationPath: "nowhere")

        let counting = CountingFileManager()
        let survey = EditorRail.survey(in: root.path, showsHidden: false, fileManager: counting,
                                       isCloudOnly: nothingIsCloudOnly)
        #expect(survey.folders == ["Inside", "Linked"])
        #expect(survey.rows.map(\.name) == ["notes.md"])
        #expect(counting.existenceAsks == 1 + 3, "the survey asked \(counting.existenceAsks) times")
    }

    /// **A pick of a linked folder lands the pane there, and the rail lists what is inside** — in
    /// Columns and in Tree, one level into the link and two, through the pane's own walk on a real
    /// folder. Two below a link is where the walk's ids go resolved (`contentsOfDirectory` follows
    /// the link), so it is the level that could miss. Under the root's canonical spelling and under
    /// `/var`, which the walk lists as `/private/var` from its first level down.
    @MainActor
    @Test(arguments: [false, true])
    func aPickedLinkLandsThePaneOnTheLinkedFolder(spelledThroughVar: Bool) async throws {
        let fm = FileManager.default
        let base = try scratch()
        defer { try? fm.removeItem(at: base) }
        let canonical = try base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? base.path
        try #require(canonical.hasPrefix("/private/var/"), "premise: the temp folder is not under /private/var")
        let baseSpelling = spelledThroughVar ? String(canonical.dropFirst("/private".count)) : canonical
        let root = URL(fileURLWithPath: baseSpelling).appendingPathComponent("R")
        let target = URL(fileURLWithPath: baseSpelling).appendingPathComponent("Elsewhere/Projects")
        let other = URL(fileURLWithPath: baseSpelling).appendingPathComponent("other")
        for dir in [root.appendingPathComponent("Photos"), target.appendingPathComponent("inner"), other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try file("plan.md", in: target)
        try file("deep.md", in: target.appendingPathComponent("inner"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Projects"), withDestinationURL: target)
        let pane = CloudProvider(id: "p", displayName: "P", imageName: "folder", rootPath: root.path, type: .localFolder)
        let right = CloudProvider(id: "o", displayName: "O", imageName: "folder", rootPath: other.path, type: .localFolder)

        // From the top of the source down the link, then down its subfolder: each step the survey
        // offers the folder, the trail builds its target, and the pane goes there.
        let top = EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(top.folders == ["Photos", "Projects"])
        let intoLink = try #require(EditorFolderTrail(levels: [.init(name: "P", target: nil)], currentTarget: "",
                                                      subfolders: top.folders).target(forSubfolder: "Projects"))
        let linkFolder = root.path + "/Projects"
        let inLink = EditorRail.survey(in: linkFolder, showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(inLink.rows.map(\.path) == [linkFolder + "/plan.md"], "the rail spelled \(inLink.rows.map(\.path))")
        #expect(inLink.folders == ["inner"])
        let belowLink = try #require(EditorFolderTrail(levels: [.init(name: "Projects", target: nil)],
                                                       currentTarget: intoLink, subfolders: inLink.folders)
            .target(forSubfolder: "inner"))
        #expect(belowLink == "Projects/inner")

        // Columns: a browse move, and the column lists the linked folder's contents.
        let columns = FileSyncManager()
        await columns.refreshTreesAndScan(left: pane, right: right, comparing: false)
        for (move, lists) in [(intoLink, ["inner", "plan.md"]), (belowLink, ["deep.md"])] {
            columns.navigatePane(isLeft: true, toCombinedPath: move, drawsColumns: true)
            let folder = columns.leftBrowsePath.currentDirectory(treeRoot: root.path)
            #expect(folder == root.path + "/" + move)
            let index = columns.leftChildrenIndex(treeRoot: root.path)
            #expect(index.children(atPath: folder)?.map(\.node.name).sorted() == lists,
                    "the column at \(move) listed \(index.children(atPath: folder)?.map(\.node.id) ?? [])")
        }

        // Tree: a re-root, and the walk at the new root lists the linked folder's contents.
        let tree = FileSyncManager()
        await tree.refreshTreesAndScan(left: pane, right: right, comparing: false)
        for (move, lists) in [(intoLink, ["inner", "plan.md"]), (belowLink, ["deep.md"])] {
            tree.navigatePane(isLeft: true, toCombinedPath: move, drawsColumns: false)
            #expect(tree.leftRelativePath == move)
            await tree.refreshTreesAndScan(left: pane, right: right, reloading: .leftOnly, comparing: false)
            #expect(tree.paneTreeFolder(isLeft: true) == root.path + "/" + move)
            #expect(tree.leftTree.map(\.name).sorted() == lists, "the tree at \(move) listed \(tree.leftTree.map(\.id))")
        }
    }

    /// Unreadable reports nothing to step into, as it reports nothing to open. **A real folder
    /// with a folder inside, made unreadable** — a path that does not exist answered "empty" too,
    /// whatever the survey did, so the test proved nothing. The control reads it first.
    @Test func anUnreadableFolderOffersNoFolders() throws {
        let root = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try folder("Inside", in: root)
        #expect(EditorRail.survey(in: root.path, showsHidden: false,
                                  isCloudOnly: nothingIsCloudOnly).folders == ["Inside"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        try #require((try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil,
                     "the folder is still readable, so this proves nothing")
        let survey = EditorRail.survey(in: root.path, showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(survey.folders.isEmpty && survey.otherFileCount == nil)
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

/// A real `FileManager` that counts what the survey asks of it — `is FileManager` still holds, so
/// the listing takes the real-disk path. The survey is synchronous and asks from one thread, so the
/// count needs no lock.
private final class CountingFileManager: FileManager, @unchecked Sendable {
    nonisolated(unsafe) private(set) var existenceAsks = 0

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        existenceAsks += 1
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }
}
