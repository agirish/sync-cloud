import Foundation
import Testing
@testable import Sync

/// **A folder that lives outside a root and is linked into it by name** — iCloud Drive's `Desktop`
/// and `Documents` — and the one table (`PathBoundary.LinkedFolders`) that lets root-relative
/// paths reach it under its real spelling.
///
/// Every function that consults the table takes it as a parameter, so nothing here reads the
/// machine's own links; the fixture root `/r` links `Documents` to `/home/Documents`, which exists
/// nowhere. The walk tests are the exception and build a real link in a temp directory, because
/// the substitution they pin happens at a real listing.
@Suite struct LinkedFoldersTests {

    static let root = "/r"
    static let links: PathBoundary.LinkedFolders = ["/r": ["Documents": "/home/Documents",
                                                            "Desktop": "/home/Desktop"]]

    // MARK: - PathBoundary

    @Test func aPathUnderTheLinkedFolderRelativizesThroughTheLinkName() {
        #expect(PathBoundary.relativize("/home/Documents/Family", under: Self.root, links: Self.links)
                == "Documents/Family")
        #expect(PathBoundary.relativize("/home/Documents", under: Self.root, links: Self.links) == "Documents")
        #expect(PathBoundary.relativize("/home/Desktop/a.txt", under: Self.root, links: Self.links) == "Desktop/a.txt")
    }

    /// Both spellings of one folder give one relative path — the link-side one by prefix math, so a
    /// caller holding either cannot be told two different things.
    @Test func theLinkSideSpellingRelativizesTheSameWay() {
        #expect(PathBoundary.relativize("/r/Documents/Family", under: Self.root, links: Self.links)
                == "Documents/Family")
    }

    /// A sibling of the linked folder that merely shares its prefix is still outside — the table
    /// does not loosen the boundary rule.
    @Test func theLinkedFolderKeepsTheComponentBoundary() {
        #expect(PathBoundary.relativize("/home/DocumentsBackup/x", under: Self.root, links: Self.links) == nil)
        #expect(PathBoundary.relativize("/home/other", under: Self.root, links: Self.links) == nil)
    }

    @Test func anEmptyTableIsThePlainPrefixMath() {
        #expect(PathBoundary.relativize("/home/Documents/x", under: Self.root, links: [:]) == nil)
        #expect(PathBoundary.join(root: Self.root, relative: "Documents/x", links: [:]) == "/r/Documents/x")
        #expect(PathBoundary.contains("/home/Documents/x", under: Self.root, links: [:]) == false)
    }

    @Test func joinComposesAFirstComponentThatNamesALinkOntoItsTarget() {
        #expect(PathBoundary.join(root: Self.root, relative: "Documents/Family", links: Self.links)
                == "/home/Documents/Family")
        #expect(PathBoundary.join(root: Self.root, relative: "Documents", links: Self.links) == "/home/Documents")
        // Not a link: plain composition, exactly as before the table existed.
        #expect(PathBoundary.join(root: Self.root, relative: "Word/x", links: Self.links) == "/r/Word/x")
        #expect(PathBoundary.join(root: Self.root, relative: "", links: Self.links) == "/r")
        // Only the FIRST component is a link name; a deeper `Documents` is an ordinary folder.
        #expect(PathBoundary.join(root: Self.root, relative: "Word/Documents/x", links: Self.links)
                == "/r/Word/Documents/x")
    }

    @Test func joinAndRelativizeAreInverses() {
        for relative in ["", "Documents", "Documents/Family/2026", "Desktop/a.txt", "Word", "Word/Documents"] {
            let absolute = PathBoundary.join(root: Self.root, relative: relative, links: Self.links)
            #expect(PathBoundary.relativize(absolute, under: Self.root, links: Self.links) == relative,
                    "\(relative) → \(absolute) did not come back")
        }
    }

    /// The table is keyed by the normalized root, so the spelling a caller happens to hold — a
    /// trailing slash, a tilde — still finds it.
    @Test func theTableIsFoundUnderAnyNormalizedSpellingOfTheRoot() {
        #expect(PathBoundary.join(root: "/r/", relative: "Documents/x", links: Self.links) == "/home/Documents/x")
        #expect(PathBoundary.relativize("/home/Documents/x", under: "/r/", links: Self.links) == "Documents/x")
        #expect(PathBoundary.linkedFolders(atRoot: "/r/", in: Self.links)["Desktop"] == "/home/Desktop")
        #expect(PathBoundary.linkedFolders(atRoot: "/elsewhere", in: Self.links).isEmpty)
    }

    @Test func containsFollowsRelativize() {
        #expect(PathBoundary.contains("/home/Documents/x", under: Self.root, links: Self.links))
        #expect(!PathBoundary.contains("/home/Pictures/x", under: Self.root, links: Self.links))
    }

    // MARK: - Discovery

    @Test func discoveryRecordsOnlyTheNamedLinksAndResolvesARelativeTarget() {
        let table = PathBoundary.discoverLinkedFolders(atRoot: "/r/", names: ["Desktop", "Documents", "Word"]) { path in
            switch path {
            case "/r/Desktop": return "/home/Desktop"
            case "/r/Documents": return "../home/Documents"    // relative to the root, as readlink gives it
            default: return nil                               // Word is a real folder, not a link
            }
        }
        #expect(table == ["/r": ["Desktop": "/home/Desktop", "Documents": "/home/Documents"]])
    }

    /// A link that points back INTO the root is not a folder kept outside it, and recording it
    /// would make one folder reachable by two relative paths.
    @Test func discoveryIgnoresALinkThatResolvesInsideTheRoot() {
        let table = PathBoundary.discoverLinkedFolders(atRoot: "/r", names: ["Documents"]) { _ in "/r/Real/Documents" }
        #expect(table.isEmpty)
    }

    /// The walk names a row after the folder it lists, so a link whose target is named differently
    /// would draw a row reading one name under a crumb reading another. Not recorded — and then the
    /// walk lists it as the link it is, exactly as before the table existed.
    @Test func discoveryIgnoresALinkWhoseTargetDoesNotKeepItsName() {
        let table = PathBoundary.discoverLinkedFolders(atRoot: "/r", names: ["Documents"]) { _ in "/home/Docs" }
        #expect(table.isEmpty)
    }

    @Test func dotsCollapseLexicallyAndNothingElseIsTouched() {
        #expect(PathBoundary.collapsingDots("/r/../home/./Documents") == "/home/Documents")
        #expect(PathBoundary.collapsingDots("/private/var/x/../y") == "/private/var/y")
        #expect(PathBoundary.collapsingDots("/a/b/../../..") == "/")
    }

    @Test func aRootWithNoLinksHasNoEntryAtAll() {
        #expect(PathBoundary.discoverLinkedFolders(atRoot: "/r", names: ["Desktop", "Documents"]) { _ in nil }.isEmpty)
        #expect(PathBoundary.discoverLinkedFolders(atRoot: "", names: ["Desktop"]) { _ in "/x" }.isEmpty)
    }

    // MARK: - The browse path

    @Test func theFirstColumnUnderALinkedNameOpensWhereTheFolderReallyIs() {
        let path = PaneBrowsePath(components: ["Documents", "Invoices"])
        #expect(path.columnDirectories(treeRoot: Self.root, links: Self.links)
                == ["/r", "/home/Documents", "/home/Documents/Invoices"])
        #expect(path.currentDirectory(treeRoot: Self.root, links: Self.links) == "/home/Documents/Invoices")
        // An unlinked first component, and a linked NAME deeper down, compose lexically.
        #expect(PaneBrowsePath(components: ["Word", "Documents"]).columnDirectories(treeRoot: Self.root, links: Self.links)
                == ["/r", "/r/Word", "/r/Word/Documents"])
        // A root the table does not name is untouched.
        #expect(path.columnDirectories(treeRoot: "/other", links: Self.links)
                == ["/other", "/other/Documents", "/other/Documents/Invoices"])
    }

    // MARK: - Coverage, recents, the name check

    @Test func aLinkedFolderIsCoveredGround() {
        #expect(FileLocation.coveredPaths(ofRootPath: Self.root, links: Self.links)
                == ["/r", "/home/desktop", "/home/documents"])
        #expect(FileLocation.coveredPaths(ofRootPath: Self.root, links: [:]) == ["/r"])
    }

    @Test func aDestinationUnderTheLinkedFolderIsRememberedForItsProvider() throws {
        let suite = "LinkedFoldersTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // `load` keeps only folders that exist, so the linked target is a real temp folder here.
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "LinkedFoldersTests")
        defer { try? fm.removeItem(at: base) }
        let target = base.appendingPathComponent("Documents")
        let inbox = target.appendingPathComponent("Inbox")
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let links: PathBoundary.LinkedFolders = ["/r": ["Documents": target.path]]

        DestinationRecents.record(inbox.path, providerRoot: Self.root, in: defaults, links: links)
        #expect(DestinationRecents.load(providerRoot: Self.root, in: defaults) == [inbox.path])
        // Outside the provider, and not through a link: not remembered, as before.
        DestinationRecents.record(base.path, providerRoot: Self.root, in: defaults, links: links)
        #expect(DestinationRecents.load(providerRoot: Self.root, in: defaults) == [inbox.path])
    }

    @Test func theNameCheckAttributesALinkedFolderToItsProvider() {
        let icloud = CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                                   rootPath: Self.root, openAt: "Documents", type: .iCloud)
        let other = CloudProvider(id: "D", displayName: "Dropbox", imageName: "dropbox",
                                  rootPath: "/d", type: .dropBox)
        let found = FileSyncManager.destinationProvider(forPath: "/home/Documents/x.txt",
                                                        providers: (left: icloud, right: other),
                                                        links: Self.links)
        #expect(found?.id == "iCloud")
        #expect(FileSyncManager.destinationProvider(forPath: "/home/Documents/x.txt",
                                                    providers: (left: icloud, right: other), links: [:]) == nil)
    }

    /// `landingPath` composes through the table by default — the seam every pane, the CLI and the
    /// lens anchor read. Pinned with the machine's own table left out, on a root nothing links.
    @Test func aLandingFolderThatIsNotLinkedComposesLexically() {
        let provider = CloudProvider(id: "x", displayName: "x", imageName: "icloud",
                                     rootPath: "/nowhere/container", openAt: "Documents", type: .iCloud)
        #expect(provider.landingPath == "/nowhere/container/Documents")
    }

    // MARK: - The walk

    /// A real link in a temp directory: with the table, the walk lists the linked folder AS the
    /// folder it points at — real id, a real directory, children walked; without it, the link.
    @Test func theWalkListsALinkedFolderAsTheFolderItPointsAt() async throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "LinkedFoldersTests")
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("container")
        let real = base.appendingPathComponent("outside").appendingPathComponent("Documents")
        try fm.createDirectory(at: container.appendingPathComponent("Word"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try "hello".write(to: real.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        let table: PathBoundary.LinkedFolders = [container.path: ["Documents": real.path]]

        let substituted = await FileSyncManager.buildTree(url: container, sortOption: .name, linkedFolders: table)
        let documents = try #require(substituted.first { $0.name == "Documents" })
        #expect(documents.id == real.path, "the node carries the link's spelling, not the folder's")
        #expect(documents.isDirectory)
        #expect(documents.isSymbolicLink != true)
        #expect(documents.children?.map(\.name) == ["note.txt"])
        #expect(substituted.map(\.name) == ["Documents", "Word"])

        // The substitution is the table's doing, not the walk's own symlink handling.
        let plain = await FileSyncManager.buildTree(url: container, sortOption: .name, linkedFolders: [:])
        let link = try #require(plain.first { $0.name == "Documents" })
        #expect(link.id == container.appendingPathComponent("Documents").path)
        #expect(link.isSymbolicLink == true)
    }

    /// Discovery against a real link, end to end: the production reader sees the link the test
    /// made and records where it points.
    @Test func discoveryReadsARealLink() throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "LinkedFoldersTests")
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("container")
        let real = base.appendingPathComponent("outside").appendingPathComponent("Documents")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        let table = PathBoundary.discoverLinkedFolders(atRoot: container.path, names: ["Desktop", "Documents"])
        #expect(table == [container.path: ["Documents": real.path]])
    }
}
