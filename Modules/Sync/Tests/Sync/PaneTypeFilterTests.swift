import Testing
import Foundation
@testable import Sync

/// RD70's type filter: the kind table, the filter value's editing rules, and the pass that prunes a
/// pane's tree. Every expectation is a literal — none compares the model to itself.
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

    @Test func untickingAKindFromNoFilterKeepsEveryOtherKind() {
        let next = PaneTypeFilter.toggling(.archives, in: nil, census: Self.census)
        #expect(next == PaneTypeFilter(families: [.images, .pdfs, .appsAndInstallers, .noExtension]))
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

    /// A selected folder carries its hidden contents, and this is the number the prompts say (FJ).
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

    /// A named reveal of a filtered-out file clears that pane's filter and says so (FM); a file the
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
