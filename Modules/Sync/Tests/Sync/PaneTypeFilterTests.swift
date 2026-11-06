import Testing
import Foundation
@testable import Sync

/// The pane's type filter: the kind table, the filter value's editing rules, and the pass that
/// prunes a pane's tree. Every expectation is a literal; none compares the model to itself.
@Suite struct FileTypeFamilyTests {

    @Test func extensionsLandInTheKindTheTypeListShows() {
        let table: [(String, FileTypeFamily)] = [
            ("jpg", .images), ("jpeg", .images), ("png", .images), ("heic", .images), ("webp", .images),
            ("svg", .images), ("gif", .images),
            ("pdf", .pdfs),
            ("docx", .documents), ("pages", .documents), ("rtf", .documents),
            ("xlsx", .spreadsheets), ("numbers", .spreadsheets), ("csv", .spreadsheets),
            ("pptx", .presentations), ("key", .presentations),
            ("mov", .movies), ("mp4", .movies),
            ("m4a", .audio), ("mp3", .audio), ("wav", .audio),
            ("dmg", .appsAndInstallers), ("pkg", .appsAndInstallers), ("app", .appsAndInstallers),
            ("iso", .appsAndInstallers), ("mpkg", .appsAndInstallers),
            ("zip", .archives), ("gz", .archives), ("tar", .archives), ("7z", .archives),
            ("md", .textAndCode), ("txt", .textAndCode), ("json", .textAndCode), ("swift", .textAndCode),
            ("", .noExtension), ("qqqzz", .other),
        ]
        for (ext, family) in table {
            #expect(FileTypeFamily.of(extension: ext) == family, "\(ext)")
        }
    }

    @Test func aNameIsFiledUnderItsLastLowercasedComponent() {
        #expect(FileTypeFamily.fileExtension(ofName: "IMG_3912.JPG") == "jpg")
        #expect(FileTypeFamily.fileExtension(ofName: "passport-renewal-form.PDF") == "pdf")
        #expect(FileTypeFamily.fileExtension(ofName: "backup.tar.gz") == "gz")
        #expect(FileTypeFamily.fileExtension(ofName: "README") == "")
        #expect(FileTypeFamily.fileExtension(ofName: ".DS_Store") == "")
        #expect(FileTypeFamily.fileExtension(ofName: "54607803 2.zip") == "zip")
    }

    /// Where `FileKind` (Automations) has an answer, the type list files the extension under the
    /// matching kind. Apps & installers is the one deliberate split: `FileKind` has no such kind.
    @Test func theTypeListAgreesWithAutomationsKinds() {
        let expected: [FileTypeFamily: Set<FileKind>] = [
            .images: [.image], .pdfs: [.pdf], .movies: [.video], .audio: [.audio], .archives: [.archive],
            .documents: [.document], .spreadsheets: [.document], .presentations: [.document],
            .textAndCode: [.document],
        ]
        let extensions = ["jpg", "png", "heic", "gif", "pdf", "mov", "mp4", "mp3", "m4a", "zip", "gz",
                          "docx", "rtf", "xlsx", "csv", "pptx", "txt", "md"]
        var checked = 0
        for ext in extensions {
            guard let kind = FileKind.of(fileName: "x.\(ext)") else { continue }
            let family = FileTypeFamily.of(extension: ext)
            #expect(expected[family]?.contains(kind) == true, "\(ext): \(family) vs \(kind)")
            checked += 1
        }
        #expect(checked >= 14, "FileKind answered for too few extensions to compare: \(checked)")
    }

    @Test func countPhrasesNameTheKind() {
        #expect(FileTypeFamily.images.countPhrase(1) == "1 image")
        #expect(FileTypeFamily.images.countPhrase(2) == "2 images")
        #expect(FileTypeFamily.pdfs.countPhrase(3) == "3 PDFs")
        #expect(FileTypeFamily.other.countPhrase(9) == "9 files")
    }
}

@Suite struct PaneTypeFilterValueTests {

    /// Downloads, as the mockup draws it: 23 images over five extensions, 12 PDFs, three installers.
    static let census: [String: Int] = ["jpg": 10, "png": 10, "heic": 1, "webp": 1, "svg": 1,
                                        "pdf": 12, "dmg": 1, "pkg": 1, "app": 1, "zip": 4, "": 1]

    @Test func onlyAKindShowsThatKindAndTakesInNewExtensions() {
        let filter = PaneTypeFilter.only(.images, census: Self.census)
        #expect(filter == PaneTypeFilter(families: [.images]))
        #expect(filter?.matches(extension: "gif") == true, "a .gif arriving later joins a whole kind")
        #expect(filter?.matches(extension: "pdf") == false)
    }

    @Test func untickingOneExtensionTurnsTheKindIntoItsExtensions() {
        let start = PaneTypeFilter(families: [.images])
        let next = PaneTypeFilter.toggling(extension: "png", in: start, census: Self.census)
        #expect(next == PaneTypeFilter(extensions: ["jpg", "heic", "webp", "svg"]))
        #expect(next?.matches(extension: "gif") == false, "a split kind no longer takes in arrivals")
        #expect(PaneTypeFilter.tick(of: .images, in: next, census: Self.census) == .mixed)
    }

    @Test func tickingEveryExtensionBackRestoresTheWholeKind() {
        let split = PaneTypeFilter(families: [.pdfs], extensions: ["jpg", "heic", "webp", "svg"])
        let next = PaneTypeFilter.toggling(extension: "png", in: split, census: Self.census)
        #expect(next == PaneTypeFilter(families: [.pdfs, .images]))
    }

    /// Every other kind, not every other kind present: a kind the walk hasn't reached yet, or one
    /// arriving later, still shows. Named by what it leaves out.
    @Test func untickingAKindFromNoFilterKeepsEveryOtherKind() {
        let next = PaneTypeFilter.toggling(.archives, in: nil, census: Self.census)
        #expect(next == PaneTypeFilter(families: Set(FileTypeFamily.allCases).subtracting([.archives])))
        #expect(next?.matches(extension: "docx") == true, "a document found later is hidden")
        #expect(next?.matches(extension: "zip") == false)
        #expect(next?.summary == "All but Archives")
        #expect(next?.showingPhrase == "all but Archives")
    }

    /// Unticking one extension from no filter leaves the rest of its kind ticked one by one, and
    /// every other kind whole.
    @Test func untickingAnExtensionFromNoFilterSaysWhichKindItSplit() {
        let next = PaneTypeFilter.toggling(extension: "png", in: nil, census: Self.census)
        #expect(next == PaneTypeFilter(families: Set(FileTypeFamily.allCases).subtracting([.images]),
                                       extensions: ["jpg", "heic", "webp", "svg"]))
        #expect(next?.matches(extension: "mp3") == true)
        #expect(next?.matches(extension: "png") == false)
        #expect(next?.summary == "All but some Images")
    }

    @Test func tickingEverythingIsNoFilter() {
        let one = PaneTypeFilter.toggling(.archives, in: nil, census: Self.census)
        #expect(one != nil)
        #expect(PaneTypeFilter.toggling(.archives, in: one, census: Self.census) == nil)
    }

    @Test func noneIsAFilterThatShowsNothing() {
        let none = PaneTypeFilter()
        #expect(none.isEmpty)
        #expect(!none.matches(extension: "pdf"))
        #expect(none.summary == "Nothing ticked")
    }

    @Test func summariesReadAsTheChipDoes() {
        #expect(PaneTypeFilter(families: [.images]).summary == "Images")
        #expect(PaneTypeFilter(families: [.pdfs, .images]).summary == "Images, PDFs")
        #expect(PaneTypeFilter(extensions: ["png", "jpg"]).summary == ".jpg, .png")
        #expect(PaneTypeFilter(families: [.images, .pdfs, .archives, .audio]).summary == "Images, PDFs +2")
        #expect(PaneTypeFilter(families: [.images]).showingPhrase == "only Images")
    }

    @Test func aFolderPillNamesTheKindOnlyWhenThereIsOne() {
        #expect(PaneTypeFilter(families: [.images]).countPhrase(2) == "2 images")
        #expect(PaneTypeFilter(extensions: ["jpg", "png"]).countPhrase(2) == "2 images")
        #expect(PaneTypeFilter(families: [.images, .pdfs]).countPhrase(9) == "9 files")
    }

    @Test func aTickedTypeMissingHereIsListedAtZero() {
        let filter = PaneTypeFilter(extensions: ["mp4", "jpg"])
        #expect(PaneTypeFilter.absentTickedExtensions(of: .movies, in: filter, census: Self.census) == ["mp4"])
        #expect(PaneTypeFilter.absentTickedExtensions(of: .images, in: filter, census: Self.census).isEmpty)
    }

    /// A kind whose only ticked type is missing here draws a dash, not an empty box: its row lists
    /// that type at 0, ticked.
    @Test func aKindTickedOnlyElsewhereDrawsMixed() {
        let filter = PaneTypeFilter(extensions: ["mp4"])
        #expect(PaneTypeFilter.tick(of: .movies, in: filter, census: Self.census) == .mixed)
        #expect(PaneTypeFilter.tick(of: .images, in: filter, census: Self.census) == .off)
    }

    /// With nothing counted yet there is nothing to compare against, so a choice stays a filter
    /// rather than reading as "everything".
    @Test func aChoiceOverNoCountsStaysAFilter() {
        #expect(PaneTypeFilter.only(.pdfs, census: [:]) == PaneTypeFilter(families: [.pdfs]))
    }

    @Test func extensionsListMostCommonFirst() {
        #expect(PaneTypeFilter.presentExtensions(of: .images, in: Self.census) == ["jpg", "png", "heic", "svg", "webp"])
        #expect(PaneTypeFilter.presentFamilies(in: Self.census)
                == [.images, .pdfs, .appsAndInstallers, .archives, .noExtension])
    }
}

@Suite struct PaneTypeFilterPassTests {

    static let root = "/Downloads"

    static func file(_ path: String) -> FileNode {
        FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    static func folder(_ path: String, _ children: [FileNode], unexplored: Bool = false, kind: String? = nil) -> FileNode {
        FileNode(id: "\(root)/\(path)", name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, kind: kind, isUnexplored: unexplored ? true : nil)
    }

    /// 64183111/{archive (unexplored), photos/{DSC_0091.JPG, DSC_0092.JPG}, receipt.pdf}
    /// images/{old/{readme.txt}, icon.png}
    /// Rectangle.app/{Contents/{Info.plist}} — a package
    /// W-2 2025.pdf, IMG_3912.jpg
    static let tree: [FileNode] = [
        folder("64183111", [
            folder("64183111/archive", [], unexplored: true),
            folder("64183111/photos", [file("64183111/photos/DSC_0091.JPG"), file("64183111/photos/DSC_0092.JPG")]),
            file("64183111/receipt.pdf"),
        ]),
        folder("images", [folder("images/old", [file("images/old/readme.txt")]), file("images/icon.png")]),
        folder("Rectangle.app", [folder("Rectangle.app/Contents", [file("Rectangle.app/Contents/Info.plist")])],
               kind: "com.apple.application-bundle"),
        file("W-2 2025.pdf"),
        file("IMG_3912.jpg"),
    ]

    static func ids(_ nodes: [FileNode]) -> [String] {
        nodes.flatMap { [String($0.id.dropFirst(root.count + 1))] + ids($0.children ?? []) }
    }

    @Test func aDeepMatchKeepsItsFoldersAndEmptyBranchesGo() {
        let (kept, facts) = PaneTypeFilterPass.apply(PaneTypeFilter(families: [.images]), to: Self.tree)
        #expect(Self.ids(kept) == [
            "64183111", "64183111/archive", "64183111/photos",
            "64183111/photos/DSC_0091.JPG", "64183111/photos/DSC_0092.JPG",
            "images", "images/icon.png",
            "IMG_3912.jpg",
        ])
        #expect(facts.matchCounts == ["\(Self.root)/64183111": 2, "\(Self.root)/64183111/photos": 2,
                                      "\(Self.root)/images": 1])
    }

    @Test func anUnexploredFolderIsNeverHidden() {
        // Nothing matches a PDF-only filter inside 64183111 except receipt.pdf — but `archive`
        // stays, because nothing can say what it holds.
        let (kept, facts) = PaneTypeFilterPass.apply(PaneTypeFilter(families: [.movies]), to: Self.tree)
        #expect(Self.ids(kept) == ["64183111", "64183111/archive"])
        #expect(facts.unexploredCount == 1)
    }

    @Test func aPackageIsOneFileJudgedByItsOwnExtension() {
        let (kept, facts) = PaneTypeFilterPass.apply(PaneTypeFilter(families: [.appsAndInstallers]), to: Self.tree)
        #expect(Self.ids(kept) == ["64183111", "64183111/archive",
                                   "Rectangle.app", "Rectangle.app/Contents", "Rectangle.app/Contents/Info.plist"])
        #expect(facts.census["app"] == 1)
        #expect(facts.census["plist"] == nil, "the walk does not count inside a package")
    }

    @Test func theCensusCountsEveryFileBeforeTheFilter() {
        let (_, facts) = PaneTypeFilterPass.apply(PaneTypeFilter(families: [.pdfs]), to: Self.tree)
        #expect(facts.census == ["jpg": 3, "pdf": 2, "png": 1, "txt": 1, "app": 1])
        #expect(facts.itemCountBeforeFilter == FileSyncManager.countItems(in: Self.tree))
        #expect(facts.itemCountBeforeFilter == 15)
        #expect(facts.fileCount == 8)
    }

    @Test func whatThePaneJustMadeSurvivesTheFilter() {
        let made = FileNode(id: "\(Self.root)/untitled folder", name: "untitled folder", isDirectory: true, children: [])
        let notes = FileNode(id: "\(Self.root)/notes.txt", name: "notes.txt", isDirectory: false)
        let tree = Self.tree + [made, notes]
        let filter = PaneTypeFilter(families: [.pdfs])
        let without = PaneTypeFilterPass.apply(filter, to: tree)
        #expect(!Self.ids(without.tree).contains("untitled folder"))
        let with = PaneTypeFilterPass.apply(filter, to: tree, keep: [made.id, notes.id])
        #expect(Self.ids(with.tree).contains("untitled folder"))
        #expect(Self.ids(with.tree).contains("notes.txt"))
    }

    /// A kept folder that held nothing before the filter is named, so its column says "Empty"
    /// rather than "No matching files"; a kept folder the filter emptied is not.
    @Test func aKeptFolderThatWasAlreadyEmptyIsNamed() {
        let made = FileNode(id: "\(Self.root)/untitled folder", name: "untitled folder", isDirectory: true, children: [])
        let (_, facts) = PaneTypeFilterPass.apply(PaneTypeFilter(families: [.images]), to: Self.tree + [made],
                                                  keep: [made.id, "\(Self.root)/images/old"])
        #expect(facts.keptEmptyFolders == [made.id])
        #expect(PaneTypeFilterPass.census(of: Self.tree + [made]).keptEmptyFolders.isEmpty, "no filter, nothing to tell apart")
    }

    @Test func noFilterPrunesNothingButStillCounts() {
        let facts = PaneTypeFilterPass.census(of: Self.tree)
        #expect(facts.census["jpg"] == 3)
        #expect(facts.matchCounts.isEmpty)
    }

    // MARK: - Through the published pass

    @Test func theFilterNarrowsOnePaneAndNeverTheDifferences() {
        let diff = FileDifference(relativePath: "W-2 2025.pdf", leftItemPath: "/Downloads/W-2 2025.pdf", rightItemPath: "/r/W-2 2025.pdf", type: .missingOnRight, action: .copyToRight, description: "")
        let plain = FileSyncManager.computeFilteredState(
            rawLeftTree: Self.tree, rawRightTree: Self.tree, rawDifferences: [diff], showHidden: false,
            ignoredPaths: [], verifiedSameDifferenceIds: [], dropDriveDateNoise: false)
        let filtered = FileSyncManager.computeFilteredState(
            rawLeftTree: Self.tree, rawRightTree: Self.tree, rawDifferences: [diff], showHidden: false,
            ignoredPaths: [], verifiedSameDifferenceIds: [], dropDriveDateNoise: false,
            leftTypeFilter: PaneTypeFilter(families: [.images]))
        #expect(Self.ids(filtered.leftTree).count == 8)
        #expect(filtered.leftItemCount == 8)
        #expect(filtered.rightTree == plain.rightTree, "a left filter leaves the right pane alone")
        #expect(filtered.differences.map(\.relativePath) == ["W-2 2025.pdf"])
        #expect(filtered.differences.map(\.relativePath) == plain.differences.map(\.relativePath))
        #expect(filtered.leftTreeBeforeTypeFilter == plain.leftTree)
        #expect(filtered.leftTypeFilterFacts?.itemCountBeforeFilter == 15)
        #expect(plain.leftTypeFilterFacts == nil && plain.rightTypeFilterFacts == nil,
                "no filter, no pass")
    }

    @Test func hiddenFilesStayOutOfTheCensusWhileHidden() {
        let tree = Self.tree + [FileNode(id: "\(Self.root)/.DS_Store", name: ".DS_Store", isDirectory: false)]
        let hidden = FileSyncManager.computeFilteredState(
            rawLeftTree: tree, rawRightTree: [], rawDifferences: [], showHidden: false,
            ignoredPaths: [], verifiedSameDifferenceIds: [], dropDriveDateNoise: false,
            leftTypeFilter: PaneTypeFilter(families: [.pdfs]))
        #expect(hidden.leftTypeFilterFacts?.census[""] == nil)
        let shown = FileSyncManager.computeFilteredState(
            rawLeftTree: tree, rawRightTree: [], rawDifferences: [], showHidden: true,
            ignoredPaths: [], verifiedSameDifferenceIds: [], dropDriveDateNoise: false,
            leftTypeFilter: PaneTypeFilter(families: [.pdfs]))
        #expect(shown.leftTypeFilterFacts?.census[""] == 1)
    }
}

@MainActor @Suite struct PaneTypeFilterManagerTests {

    @Test func aTabParksItsFilterAndAFreshOneStartsWithout() {
        let manager = FileSyncManager()
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        let parked = manager.captureTab(isLeft: true, providerId: "icloud")
        #expect(parked.typeFilter == PaneTypeFilter(families: [.pdfs]))
        manager.applyTab(PaneTab(providerId: "icloud"), isLeft: true, currentProviderId: "icloud")
        #expect(manager.leftTypeFilter == nil)
        manager.applyTab(parked, isLeft: true, currentProviderId: "icloud")
        #expect(manager.leftTypeFilter == PaneTypeFilter(families: [.pdfs]))
    }

    /// A folder open in the pane stays while open, matching or not, through a filter change too
    /// (which clears what the pane wrote), and goes once it is closed.
    @Test func anOpenFolderIsKeptUntilItCloses() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = PaneTypeFilterPassTests.tree
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        // images/old holds only readme.txt.
        #expect(manager.leftTree.findNodes(at: ["/Downloads/images/old"]).isEmpty)

        manager.setTypeFilterOpenFolders(["/Downloads/images/old"], isLeft: true)
        await manager.applyFilters()
        let kept = manager.leftTree.findNodes(at: ["/Downloads/images/old"]).first
        #expect(kept?.children == [], "the folder stays, and the filter still hides what is in it")
        #expect(manager.leftTypeFilterFacts?.matchCounts["/Downloads/images/old"] == nil, "no count for no match")

        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        await manager.applyFilters()
        #expect(!manager.leftTree.findNodes(at: ["/Downloads/images/old"]).isEmpty, "a filter change keeps it")

        manager.setTypeFilterOpenFolders([], isLeft: true)
        await manager.applyFilters()
        #expect(manager.leftTree.findNodes(at: ["/Downloads/images/old"]).isEmpty, "closed, it goes")
    }

    /// Turning a filter on from none keeps a folder already open. The host reports the open stack
    /// whatever the filter, so the filter's first pass (started by its didSet) already knows it;
    /// otherwise that pass would hide the folder and the republish would close the stack.
    @Test func aFolderOpenBeforeTheFilterIsKeptByItsFirstPass() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = PaneTypeFilterPassTests.tree
        await manager.applyFilters()
        manager.setTypeFilterOpenFolders(["/Downloads/images/old"], isLeft: true)
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        #expect(manager.leftTree.findNodes(at: ["/Downloads/images/old"]).first?.children == [])
    }

    /// A linked drill mirrors into a folder the other pane's filter hides: it is still on disk
    /// there. Pruned against the shown tree, the mirror would stop at the parent as if it were gone.
    @Test func aMirroredDrillWalksIntoAFolderTheFilterHides() async {
        let manager = FileSyncManager()
        manager.rawRightTree = PaneTypeFilterPassTests.tree
        manager.rightTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        #expect(manager.rightTree.findNodes(at: ["/Downloads/images/old"]).isEmpty, "premise: the filter hides it")

        manager.applyColumnNavigation(PaneBrowsePath(components: ["images", "old"]), isLeft: true, mirror: true,
                                      otherIndex: manager.mirrorChildrenIndex(isLeft: false, treeRoot: "/Downloads"),
                                      otherTreeRoot: "/Downloads")
        #expect(manager.rightBrowsePath.components == ["images", "old"])
    }

    /// A filter left on is never saved: the stored strip brings the tab back without it.
    @Test func aTabsFilterDoesNotSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "PaneTypeFilterManagerTests-\(UUID().uuidString)"))
        let tab = PaneTab(providerId: "icloud", relativePath: "Downloads", typeFilter: PaneTypeFilter(families: [.pdfs]))
        PaneTabsStore.save(tabs: [tab], selected: 0, isLeft: true, to: defaults)
        let stored = try #require(PaneTabsStore.load(isLeft: true, from: defaults))
        let restored = try #require(PaneTabsStore.restore(entries: stored.entries, selected: stored.selected,
                                                          isKnownProvider: { _ in true }, folderExists: { _, _ in true }))
        #expect(restored.list.tabs.map(\.relativePath) == ["Downloads"])
        #expect(restored.list.tabs.map(\.typeFilter) == [nil])
    }

    /// A row the new filter hides leaves the selection, so nothing acts on it unseen.
    @Test func aFilterChangeTakesHiddenRowsOutOfTheSelection() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = PaneTypeFilterPassTests.tree
        await manager.applyFilters()
        manager.selectedLeftPaths = ["/Downloads/W-2 2025.pdf", "/Downloads/IMG_3912.jpg"]
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await waitUntil("the hidden PDF to leave the selection") { manager.selectedLeftPaths.count == 1 }
        #expect(manager.selectedLeftPaths == ["/Downloads/IMG_3912.jpg"])
    }

    @Test func aWriteIsKeptOnlyWhileAFilterIsOnAndUntilThePaneMoves() {
        let manager = FileSyncManager()
        manager.noteOwnWrite(atPath: "/Downloads/a")
        #expect(manager.leftTypeFilterKeep.isEmpty, "nothing to keep visible without a filter")
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        manager.noteOwnWrite(atPath: "/Downloads/untitled folder")
        #expect(manager.leftTypeFilterKeep == ["/Downloads/untitled folder"])
        manager.leftRelativePath = "Downloads/images"
        #expect(manager.leftTypeFilterKeep.isEmpty)
        manager.noteOwnWrite(atPath: "/Downloads/images/x")
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        #expect(manager.leftTypeFilterKeep.isEmpty, "a new filter starts with nothing kept")
    }

    /// A selected folder carries its hidden contents, and this is the number the prompts say.
    @Test func aFolderCountsWhatTheFilterHidesInsideIt() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = PaneTypeFilterPassTests.tree
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        let shown = manager.leftTree.findNodes(at: ["/Downloads/64183111", "/Downloads/IMG_3912.jpg"])
        // 64183111 holds 6 items; the filter shows archive, photos and its two JPGs: receipt.pdf is hidden.
        #expect(manager.itemsHiddenByTypeFilter(inside: shown) == 1)
        manager.leftTypeFilter = nil
        await manager.applyFilters()
        #expect(manager.itemsHiddenByTypeFilter(inside: manager.leftTree.findNodes(at: ["/Downloads/64183111"])) == 0)
    }

    /// A folder picked together with a folder inside it goes to the Trash once, so what it hides is
    /// counted once; and a folder node not read off a pane (a Finder drop) has nothing to compare.
    @Test func aNestedPickCountsItsHiddenItemsOnce() async {
        let manager = FileSyncManager()
        typealias T = PaneTypeFilterPassTests
        // box/{sub/{x.jpg, y.pdf}, z.pdf}
        manager.rawLeftTree = [T.folder("box", [T.folder("box/sub", [T.file("box/sub/x.jpg"), T.file("box/sub/y.pdf")]),
                                                T.file("box/z.pdf")])]
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        let picked = manager.leftTree.findNodes(at: ["/Downloads/box", "/Downloads/box/sub"])
        #expect(picked.count == 2)
        // y.pdf and z.pdf, each once.
        #expect(manager.itemsHiddenByTypeFilter(inside: picked) == 2)
        #expect(manager.typeFilterHiddenCounts(inside: picked) == ["/Downloads/box": 2])
        let dropped = FileNode(id: "/Downloads/box", name: "box", isDirectory: true)
        #expect(manager.itemsHiddenByTypeFilter(inside: [dropped]) == 0)
    }

    /// New Folder and Rename land through the filter: the pane keeps what it just wrote.
    @Test func aNewFolderAndARenameAreKeptVisible() async throws {
        let manager = FileSyncManager()
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        disk.virtualDisk["/src/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.createFolder(named: "untitled folder", in: "/src", fileManager: disk)
        await manager.renameItem(at: "/src/report.pdf", to: "report.txt", fileManager: disk)
        #expect(manager.leftTypeFilterKeep == ["/src/untitled folder", "/src/report.txt"])
    }

    /// A named reveal of a filtered-out file clears that pane's filter and says so; a file the
    /// pane shows, or one it does not hold at all, leaves the filter alone.
    @Test func showingAHiddenFileClearsTheFilter() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = PaneTypeFilterPassTests.tree
        manager.leftTypeFilter = PaneTypeFilter(families: [.images])
        await manager.applyFilters()
        #expect(!manager.clearTypeFilterHiding("/Downloads/IMG_3912.jpg", isLeft: true), "it is shown")
        #expect(!manager.clearTypeFilterHiding("/Downloads/nowhere.pdf", isLeft: true), "it is not there at all")
        #expect(manager.leftTypeFilter != nil)
        #expect(manager.clearTypeFilterHiding("/Downloads/W-2 2025.pdf", isLeft: true))
        #expect(manager.leftTypeFilter == nil)
        #expect(manager.banner?.message == "Filter cleared to show “W-2 2025.pdf”")
    }

    @Test func aFolderTheFilterEmptiedIsNotOneOfHiddenItems() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = [FileNode(id: "/r/a.zip", name: "a.zip", isDirectory: false)]
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        await manager.applyFilters()
        #expect(manager.leftTree.isEmpty)
        #expect(!manager.leftTreeHasOnlyHiddenEntries)
        #expect(manager.leftTreeIsEmptiedByTypeFilter)
        #expect(manager.leftTypeFilterFacts?.census == ["zip": 1])
    }
}

@MainActor @Suite struct PaneTypeFilterSwapTests {

    /// ⇄ moves each pane's filter with its tree. Left behind, the left filter (PDFs) would run over
    /// the tree from the right and hide notes.txt, still selected and in reach of ⌘⌫, and the right
    /// pane's tab would park the wrong filter.
    @Test func aSwapCarriesEachPanesFilterWithItsTree() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = [FileNode(id: "/l/W-2.pdf", name: "W-2.pdf", isDirectory: false),
                               FileNode(id: "/l/photo.jpg", name: "photo.jpg", isDirectory: false)]
        manager.rawRightTree = [FileNode(id: "/r/notes.txt", name: "notes.txt", isDirectory: false),
                                FileNode(id: "/r/report.pdf", name: "report.pdf", isDirectory: false)]
        manager.leftTypeFilter = PaneTypeFilter(families: [.pdfs])
        manager.leftTypeFilterKeep = ["/l/untitled folder"]
        await manager.applyFilters()
        manager.selectedRightPaths = ["/r/notes.txt"]
        #expect(manager.leftTree.map(\.id) == ["/l/W-2.pdf"], "premise: the left filter hides photo.jpg")

        #expect(manager.swapPanes())
        #expect(manager.leftTypeFilter == nil)
        #expect(manager.rightTypeFilter == PaneTypeFilter(families: [.pdfs]))
        #expect(manager.rightTypeFilterKeep == ["/l/untitled folder"], "what the pane wrote travels too")
        #expect(manager.leftTypeFilterKeep.isEmpty)
        #expect(manager.rightTypeFilterFacts != nil && manager.leftTypeFilterFacts == nil)
        #expect(manager.captureTab(isLeft: false, providerId: "icloud").typeFilter == PaneTypeFilter(families: [.pdfs]))

        await manager.applyFilters()
        #expect(Set(manager.leftTree.map(\.id)) == ["/r/notes.txt", "/r/report.pdf"])
        #expect(manager.rightTree.map(\.id) == ["/l/W-2.pdf"])
        // Nothing selected is hidden: no row in reach of ⌘⌫ is off screen. Whether notes.txt stays
        // selected isn't asked: a pass from before the swap may publish once after it, and the
        // prune that follows can drop the row before the fresh pass puts it back.
        #expect(Set(manager.selectedLeftPaths).isSubset(of: Set(manager.leftTree.map(\.id))))
        #expect(Set(manager.selectedRightPaths).isSubset(of: Set(manager.rightTree.map(\.id))))
    }
}

@MainActor @Suite struct PaneTypeFilterSearchTests {

    /// Compare's search marks a hit "only on left" when the other pane has no such path. A file
    /// the other pane's filter hides is still there, so the check reads that pane's whole folder.
    @Test func aFileTheOtherPanesFilterHidesIsStillOnBothSides() async {
        let manager = FileSyncManager()
        manager.rawLeftTree = [FileNode(id: "/l/notes.txt", name: "notes.txt", isDirectory: false)]
        manager.rawRightTree = [FileNode(id: "/r/notes.txt", name: "notes.txt", isDirectory: false),
                                FileNode(id: "/r/report.pdf", name: "report.pdf", isDirectory: false)]
        manager.rightTypeFilter = PaneTypeFilter(families: [.pdfs])
        await manager.applyFilters()
        #expect(manager.rightTree.map(\.id) == ["/r/report.pdf"], "premise: the right filter hides notes.txt")

        let other = PaneTree(side: .right, version: 0, nodes: manager.searchSideAnnotationNodes(forPaneIsLeft: true))
        #expect(PaneTreeSearch.relativePaths(in: other) == ["notes.txt", "report.pdf"])
        let left = PaneTree(side: .left, version: 0, nodes: manager.searchSideAnnotationNodes(forPaneIsLeft: false))
        #expect(PaneTreeSearch.relativePaths(in: left) == ["notes.txt"])
    }
}
