import Testing
import Foundation
import Sync
@testable import SyncCloudCLICore

/// Minimal FileManaging stub: only fileExists(atPath:isDirectory:) is consulted by provider
/// resolution. Directories and plain files are tracked separately so root validation
/// (exists AND is a directory) can be exercised for both failure shapes.
private struct StubFileManager: FileManaging {
    let directories: Set<String>
    var files: Set<String> = []

    func fileExists(atPath path: String) -> Bool {
        directories.contains(path) || files.contains(path)
    }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = ObjCBool(directories.contains(path))
        return fileExists(atPath: path)
    }
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] { [:] }
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {}
    func copyItem(at srcURL: URL, to dstURL: URL) throws {}
    func moveItem(at srcURL: URL, to dstURL: URL) throws {}
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {}
    func removeItem(at URL: URL) throws {}
    func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? { nil }
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? { nil }
}

private let providers = [
    CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud", rootPath: "/icloud/docs", type: .iCloud),
    CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive", rootPath: "/od/docs", type: .oneDrive),
]

@Suite struct ProviderResolutionTests {

    @Test func testMatchesById() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive-Personal", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/od/docs"]))
        #expect(resolved.id == "OneDrive-Personal")
        #expect(resolved.landingPath == "/od/docs")
    }

    /// `-L <source>` scans that source's LANDING folder, not the account above it. The one fixture
    /// with an `openAt`, so the only case that tells `rootPath` and `landingPath` apart: reading
    /// `rootPath` would silently point every provider-addressed run at the entire account.
    @Test func testAProviderAddressedRootResolvesToItsLandingFolderNotItsRoot() throws {
        let withOpenAt = [
            CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)",
                          imageName: "onedrive", rootPath: "/od", openAt: "Documents",
                          type: .oneDrive),
        ]
        let resolved = try resolveProviderOrPath(
            value: "OneDrive-Personal", label: "Left", providers: withOpenAt,
            fileManager: StubFileManager(directories: ["/od", "/od/Documents"]))
        #expect(resolved.landingPath == "/od/Documents")
        #expect(resolved.rootPath == "/od", "the root is still the whole account")
    }

    /// The check is about the folder that gets scanned: a mounted account whose landing folder was
    /// renamed or deleted is refused here, naming that folder, rather than passing a check on the
    /// root and failing deeper.
    @Test func testAMissingLandingFolderIsRefusedEvenWhenTheAccountIsMounted() throws {
        let withOpenAt = [
            CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)",
                          imageName: "onedrive", rootPath: "/od", openAt: "Documents",
                          type: .oneDrive),
        ]
        // The message names the landing folder, not the root, so it points at the thing to fix.
        let error = try #require(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(
                value: "OneDrive-Personal", label: "Left", providers: withOpenAt,
                // The account IS there — only the folder it opens at is gone.
                fileManager: StubFileManager(directories: ["/od"]))
        }
        #expect(error.message.contains("Documents"), "the message does not name the landing folder")
        #expect(!error.message.contains("unmounted"), "it blames the account, which is mounted")
    }

    @Test func testMatchesByDisplayName() throws {
        let resolved = try resolveProviderOrPath(
            value: "OneDrive (Personal)", label: "Right", providers: providers,
            fileManager: StubFileManager(directories: ["/od/docs"]))
        #expect(resolved.id == "OneDrive-Personal")
    }

    @Test func testFallsBackToExistingPath() throws {
        let resolved = try resolveProviderOrPath(
            value: "/some/dir", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["/some/dir"]))
        #expect(resolved.id == "/some/dir")
        #expect(resolved.landingPath == "/some/dir")
        #expect(resolved.displayName == "Left")
    }

    @Test func testExpandsTildeInPathFallback() throws {
        let home = NSHomeDirectory()
        let resolved = try resolveProviderOrPath(
            value: "~/somewhere", label: "Left", providers: providers,
            fileManager: StubFileManager(directories: ["\(home)/somewhere"]))
        #expect(resolved.landingPath == "\(home)/somewhere")
    }

    /// `~/iCloud` symlinked to iCloud Drive is a common convention with no hazard in it: both
    /// readings are one folder, so the guard must not fire. Compared after resolving symlinks,
    /// which is what makes the two identical rather than merely similar.
    @Test func testAProviderWhoseRootIsTheSameFolderAsThePathStillResolves() throws {
        // The provider's root IS what the relative value canonicalises to, which is the shape the
        // symlink convention produces on a real machine.
        let sameTree = canonicalPath("iCloud")
        let shadowing = [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                                       rootPath: sameTree, type: .iCloud)]
        let resolved = try resolveProviderOrPath(
            value: "iCloud", label: "Left", providers: shadowing,
            fileManager: StubFileManager(directories: [sameTree, "iCloud"]))
        #expect(resolved.id == "iCloud", "one folder named two ways was refused as an ambiguity")
    }

    // MARK: Root validation
    // A missing or non-directory root scans as an empty side (getFilesInDirectory yields an
    // empty map), which sync would "correct" by mass-copying into a dead tree — so resolution
    // must refuse both shapes for provider matches and ad-hoc paths alike.

    @Test(arguments: [("iCloud", "/icloud/docs"), ("/some/file.txt", "/some/file.txt")])
    func aRootThatIsAFileIsRefused(value: String, file: String) {
        #expect {
            try resolveProviderOrPath(
                value: value, label: "Left", providers: providers,
                fileManager: StubFileManager(directories: [], files: [file]))
        } throws: { error in
            let message = (error as? ProviderResolutionError)?.message ?? ""
            return message.contains(file) && message.contains("not a directory")
        }
    }

    // MARK: Provider type of a path-addressed root
    // A `-R <path>` takes its type from the discovered provider that contains it. The destination
    // name check and the Google Drive date-noise filter key off it, so with a fixed type the same
    // OneDrive folder would skip `CON.txt` when named by id and copy it when named by path.

    private static let cloudProviders = [
        CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                      rootPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud),
        CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive (Personal)", imageName: "onedrive",
                      rootPath: "/Users/u/Library/CloudStorage/OneDrive-Personal/Documents", type: .oneDrive),
        CloudProvider(id: "GoogleDrive-me", displayName: "Google Drive (me)", imageName: "googledrive",
                      rootPath: "/Users/u/Library/CloudStorage/GoogleDrive-me/My Drive/Documents", type: .googleDrive),
    ]

    @Test(arguments: [
        ("/Users/u/Library/CloudStorage/OneDrive-Personal/Documents", CloudProvider.ProviderType.oneDrive),
        // A sibling of the discovered root (…/Documents) belongs to the same account.
        ("/Users/u/Library/CloudStorage/OneDrive-Personal/Photos", .oneDrive),
        // DifferenceProcessing drops Drive's date-only noise only when this is `.googleDrive`.
        ("/Users/u/Library/CloudStorage/GoogleDrive-me/My Drive", .googleDrive),
        // No provider claims it, so the rule-free type stands: an ordinary folder must not
        // inherit some other provider's name restrictions.
        ("/Users/u/inbox", .iCloud),
        // Shares only a string prefix with "…/OneDrive-Personal", so it is not inside it.
        ("/Users/u/Library/CloudStorage/OneDrive-Personal-old", .iCloud),
    ])
    func aPathAddressedRootTakesTheTypeOfTheProviderHoldingIt(path: String, expected: CloudProvider.ProviderType) throws {
        let resolved = try resolveProviderOrPath(
            value: path, label: "Right", providers: Self.cloudProviders,
            fileManager: StubFileManager(directories: [path]))
        #expect(resolved.type == expected)
        // The name guard the type gates is live exactly for the OneDrive roots.
        #expect((ProviderNameRules.violation(inRelativePath: "CON.txt", for: resolved.type) != nil)
                == (expected == .oneDrive))
    }

    @Test func testProviderRootWithTildeIsExpandedBeforeValidation() throws {
        let home = NSHomeDirectory()
        let tilded = [CloudProvider(
            id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
            rootPath: "~/Dropbox", type: .dropBox)]
        let resolved = try resolveProviderOrPath(
            value: "Dropbox", label: "Left", providers: tilded,
            fileManager: StubFileManager(directories: ["\(home)/Dropbox"]))
        #expect(resolved.id == "Dropbox")
    }

    // MARK: - An argument that names both is refused, not guessed

    /// `-L Dropbox` beside a local folder called `Dropbox` is refused, not resolved to either, and
    /// the refusal has to be usable: it names both readings and the spelling that picks each.
    @Test func testTheAmbiguityMessageOffersBothWaysOut() throws {
        let fm = StubFileManager(directories: ["/icloud/docs", "iCloud"])
        let error = try #require(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(value: "iCloud", label: "Left", providers: providers,
                                      fileManager: fm)
        }
        #expect(error.message.contains("/icloud/docs"), "the provider reading is not named")
        #expect(error.message.contains("./iCloud"), "the message does not say how to mean the directory")
    }

    /// And the way out works: a provider id never contains a slash, so `./name` misses the
    /// provider branch and resolves as a path. A refusal that pointed at a spelling which also
    /// failed would be worse than the guess it replaced.
    @Test func testTheDotSlashSpellingResolvesToTheDirectory() throws {
        let fm = StubFileManager(directories: ["/icloud/docs", "./iCloud"])
        let resolved = try resolveProviderOrPath(value: "./iCloud", label: "Left",
                                                 providers: providers, fileManager: fm)
        #expect(resolved.landingPath == "./iCloud", "the escape hatch the refusal offers does not work")
    }

    // MARK: Which provider a value names

    /// An exact id outranks another provider's display name. The first provider here carries the
    /// display name "Dropbox"; the second's id IS "Dropbox". The name-matching provider is listed
    /// first, where an order-dependent "first whose id or name matches" lookup would land.
    @Test func anExactIdWinsOverAnEarlierProvidersDisplayName() throws {
        let renamed = [
            CloudProvider(id: "folder-1", displayName: "Dropbox", imageName: "folder",
                          rootPath: "/renamed/folder", type: .iCloud),
            CloudProvider(id: "Dropbox", displayName: "Dropbox (Personal)", imageName: "dropbox",
                          rootPath: "/dropbox", type: .dropBox),
        ]
        let resolved = try resolveProviderOrPath(
            value: "Dropbox", label: "Left", providers: renamed,
            fileManager: StubFileManager(directories: ["/renamed/folder", "/dropbox"]))
        #expect(resolved.id == "Dropbox")
        #expect(resolved.landingPath == "/dropbox")
    }

    /// A display name two providers share is refused, naming both ids and roots. Two folder
    /// sources whose folders end in the same component get the same default display name, and
    /// taking whichever was discovered first would let `sync --yes` write into the wrong one.
    @Test func aDisplayNameTwoProvidersShareIsRefusedNamingEachId() throws {
        let twins = [
            CloudProvider(id: "folder-a", displayName: "Photos", imageName: "folder",
                          rootPath: "/a/Photos", type: .iCloud),
            CloudProvider(id: "folder-b", displayName: "Photos", imageName: "folder",
                          rootPath: "/b/Photos", type: .iCloud),
        ]
        let fm = StubFileManager(directories: ["/a/Photos", "/b/Photos"])
        let error = try #require(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(value: "Photos", label: "Right", providers: twins, fileManager: fm)
        }
        #expect(error.message == "'Photos' for Right matches 2 providers by name: "
            + "'folder-a' (/a/Photos), 'folder-b' (/b/Photos). "
            + "Pass one of those ids (see `synccloud providers`) or the folder's path to say which.")
        // And the way out the refusal offers works: each id picks its own tree.
        #expect((try? resolveProviderOrPath(value: "folder-b", label: "Right",
                                            providers: twins, fileManager: fm))?.landingPath == "/b/Photos")
    }

    /// The refusal names the folder each candidate would SCAN (its landing folder), not the
    /// account root above it. With an `openAt` the two differ, and the roots are folders the run
    /// would never read.
    @Test func theAmbiguityRefusalNamesTheFoldersTheRunWouldScan() throws {
        let twins = [
            CloudProvider(id: "od-a", displayName: "OneDrive", imageName: "onedrive",
                          rootPath: "/a", openAt: "Documents", type: .oneDrive),
            CloudProvider(id: "od-b", displayName: "OneDrive", imageName: "onedrive",
                          rootPath: "/b", openAt: "Documents", type: .oneDrive),
        ]
        let fm = StubFileManager(directories: ["/a", "/b", "/a/Documents", "/b/Documents"])
        let error = try #require(throws: ProviderResolutionError.self) {
            try resolveProviderOrPath(value: "OneDrive", label: "Left", providers: twins, fileManager: fm)
        }
        #expect(error.message.contains("'od-a' (/a/Documents), 'od-b' (/b/Documents)."), "\(error.message)")
    }
}
